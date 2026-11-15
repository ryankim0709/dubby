import { afterEach, expect, test, vi } from "vitest";
import { api, internal } from "./_generated/api";
import { alice, bob, newBackend } from "./test.helpers";

const webhookSecret = "ws_synthetic_test_secret";
const planId = "plan_synthetic_coach";

async function signedRequest(body: string, secret: string): Promise<RequestInit> {
  const id = crypto.randomUUID();
  const timestamp = Math.floor(Date.now() / 1000).toString();
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const signature = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${id}.${timestamp}.${body}`)));
  return {
    method: "POST", body,
    headers: { "webhook-id": id, "webhook-timestamp": timestamp, "webhook-signature": `v1,${btoa(String.fromCharCode(...signature))}` },
  };
}

function membershipEvent(checkoutId: string, status: string, updatedAt: number): string {
  return JSON.stringify({ type: "membership.updated", data: {
    id: "mem_synthetic_coach", variant_id: planId, status,
    metadata: { dubbyCheckoutId: checkoutId },
    current_period_end: new Date(Date.now() + 30 * 86400000).toISOString(),
    updated_at: new Date(updatedAt).toISOString(),
  } });
}

afterEach(() => { vi.unstubAllEnvs(); });

test("a signed Whop membership unlocks only the checkout owner; duplicate and stale events cannot resurrect canceled access", async () => {
  vi.stubEnv("WHOP_COACH_WEBHOOK_SECRET", webhookSecret);
  const t = newBackend();
  const a = t.withIdentity(alice);
  const b = t.withIdentity(bob);
  await a.mutation(api.users.ensure, {});
  await b.mutation(api.users.ensure, {});
  const checkoutId = await a.mutation(internal.billing.beginCheckout, { planId });
  expect((await a.query(api.billing.status, {})).isPremium).toBe(false);
  const activatedAt = Date.now() - 1000;
  const activation = membershipEvent(checkoutId, "active", activatedAt);
  for (let delivery = 0; delivery < 2; delivery += 1) {
    expect((await t.fetch("/webhooks/whop", await signedRequest(activation, webhookSecret))).status).toBe(200);
  }
  expect((await a.query(api.billing.status, {})).isPremium).toBe(true);
  expect((await b.query(api.billing.status, {})).isPremium).toBe(false);
  const cancellation = membershipEvent(checkoutId, "canceled", activatedAt);
  expect((await t.fetch("/webhooks/whop", await signedRequest(cancellation, webhookSecret))).status).toBe(200);
  expect((await t.fetch("/webhooks/whop", await signedRequest(activation, webhookSecret))).status).toBe(200);
  expect((await a.query(api.billing.status, {})).isPremium).toBe(false);
  expect(await t.run(async (ctx) => (await ctx.db.query("premiumMemberships").collect()).length)).toBe(1);
});

test("webhook signature verification rejects tampering, missing headers and stale signatures in the Convex runtime", async () => {
  vi.stubEnv("WHOP_COACH_WEBHOOK_SECRET", webhookSecret);
  const t = newBackend();
  const body = JSON.stringify({ type: "unrelated.event", data: {} });
  expect((await t.fetch("/webhooks/whop", await signedRequest(body, "ws_wrong_secret"))).status).toBe(401);
  expect((await t.fetch("/webhooks/whop", { method: "POST", body })).status).toBe(401);
  const signed = await signedRequest(body, webhookSecret);
  expect((await t.fetch("/webhooks/whop", { ...signed, body: body + " " })).status).toBe(401);
  expect((await t.fetch("/webhooks/whop", { ...signed, headers: { ...signed.headers, "webhook-timestamp": "1" } })).status).toBe(401);
  expect((await t.fetch("/webhooks/whop", signed)).status).toBe(200);
});

test("coach spending routes reject unpaid and expired learners; checkout and entitlement require authentication", async () => {
  const t = newBackend();
  expect((await t.fetch("/billing/checkout", { method: "POST" })).status).toBe(401);
  await expect(t.query(api.billing.status, {})).rejects.toThrow("Sign in");
  const a = t.withIdentity(alice);
  await a.mutation(api.users.ensure, {});
  vi.stubEnv("WHOP_API_KEY", "");
  expect((await a.fetch("/billing/checkout", { method: "POST" })).status).toBe(503);
  for (const path of ["/coach/session-token", "/coach/reply"]) {
    const response = await a.fetch(path, { method: "POST", body: JSON.stringify({ characterId: "anakin", languageName: "Spanish", turns: [{ role: "learner", text: "Hola" }] }) });
    expect(response.status).toBe(403);
    expect(await response.json()).toMatchObject({ code: "premium_required" });
  }
  const checkoutId = await a.mutation(internal.billing.beginCheckout, { planId });
  await t.mutation(internal.billing.markPremium, { checkoutId, planId, membershipId: "mem_expired", active: true, expiresAt: Date.now() - 1, updatedAt: Date.now() });
  expect((await a.query(api.billing.status, {})).isPremium).toBe(false);
  expect((await a.fetch("/coach/reply", { method: "POST", body: JSON.stringify({ characterId: "anakin", languageName: "Spanish", turns: [{ role: "learner", text: "Hola" }] }) })).status).toBe(403);
  await expect(t.mutation(internal.billing.markPremium, { checkoutId, planId: "plan_wrong", membershipId: "mem_wrong", active: true, expiresAt: null, updatedAt: Date.now() })).rejects.toThrow("doesn't match");
});
