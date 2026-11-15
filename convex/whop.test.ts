import { afterEach, describe, expect, it, vi } from "vitest";
import { newBackend } from "./test.helpers";

// A synthetic secret and payment; nothing here is a real Whop credential or charge.
const secret = "ws_fixture_secret";

async function sign(id: string, timestamp: string, body: string, key = secret): Promise<string> {
  const encoder = new TextEncoder();
  const hmac = await crypto.subtle.importKey("raw", encoder.encode(key), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const bytes = new Uint8Array(await crypto.subtle.sign("HMAC", hmac, encoder.encode(`${id}.${timestamp}.${body}`)));
  return "v1," + btoa(String.fromCharCode(...bytes));
}

const paymentEvent = (email: string, paymentId = "pay_fixture_1") =>
  JSON.stringify({ type: "payment.succeeded", data: { id: paymentId, metadata: { email }, customer_email: "other@example.test" } });

async function deliver(t: ReturnType<typeof newBackend>, body: string, overrides: { key?: string; timestamp?: string } = {}) {
  const timestamp = overrides.timestamp ?? String(Math.floor(Date.now() / 1000));
  const signature = await sign("msg_fixture", timestamp, body, overrides.key);
  return t.fetch("/whop/webhook", {
    method: "POST",
    headers: { "webhook-id": "msg_fixture", "webhook-timestamp": timestamp, "webhook-signature": signature },
    body,
  });
}

const rows = (t: ReturnType<typeof newBackend>) => t.run(async (ctx) => await ctx.db.query("waitlist").collect());

describe("POST /whop/webhook", () => {
  afterEach(() => vi.unstubAllEnvs());

  it("marks the waitlist row paid once, keyed by the metadata email", async () => {
    vi.stubEnv("WHOP_WEBHOOK_SECRET", secret);
    const t = newBackend();
    await t.fetch("/waitlist", { method: "POST", body: JSON.stringify({ email: "Founder@Example.test", plan: "free" }) });

    expect((await deliver(t, paymentEvent("founder@example.test"))).status).toBe(200);
    expect((await deliver(t, paymentEvent("founder@example.test"))).status).toBe(200);

    const [row, ...rest] = await rows(t);
    expect(rest).toEqual([]);
    expect(row).toMatchObject({ email: "founder@example.test", plan: "founding", whopPaymentId: "pay_fixture_1", paidAt: expect.any(Number) });
  });

  it("adds a paying buyer who never joined the waitlist", async () => {
    vi.stubEnv("WHOP_WEBHOOK_SECRET", secret);
    const t = newBackend();
    await deliver(t, paymentEvent("walkin@example.test", "pay_fixture_2"));
    expect(await rows(t)).toMatchObject([{ email: "walkin@example.test", plan: "founding", source: "whop" }]);
  });

  it("rejects a wrong signature or a stale timestamp, and ignores other events", async () => {
    vi.stubEnv("WHOP_WEBHOOK_SECRET", secret);
    const t = newBackend();
    expect((await deliver(t, paymentEvent("a@example.test"), { key: "ws_wrong" })).status).toBe(401);
    const stale = String(Math.floor(Date.now() / 1000) - 600);
    expect((await deliver(t, paymentEvent("a@example.test"), { timestamp: stale })).status).toBe(401);
    expect((await deliver(t, JSON.stringify({ type: "membership.activated", data: {} }))).status).toBe(200);
    expect(await rows(t)).toEqual([]);
  });

  it("answers 503 until the secret is configured", async () => {
    const response = await deliver(newBackend(), paymentEvent("a@example.test"));
    expect(response.status).toBe(503);
  });
});
