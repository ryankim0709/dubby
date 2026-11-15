import { v } from "convex/values";
import { internalMutation } from "./_generated/server";

/** Whop's docs say to refuse deliveries more than five minutes off the server clock, which also blocks replays. */
const maxSkewSeconds = 5 * 60;

function base64(bytes: ArrayBuffer): string {
  let binary = "";
  for (const byte of new Uint8Array(bytes)) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i += 1) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/**
 * Checks a Whop webhook. Whop follows Standard Webhooks: HMAC-SHA256 over
 * `{webhook-id}.{webhook-timestamp}.{raw body}`, keyed with the `ws_…` secret as given, sent base64 in
 * `webhook-signature` as one or more space-separated `v1,<signature>` entries.
 */
export async function verifyWhopSignature(input: {
  secret: string;
  id: string | null;
  timestamp: string | null;
  signatureHeader: string | null;
  body: string;
  nowSeconds: number;
}): Promise<boolean> {
  const { secret, id, timestamp, signatureHeader, body, nowSeconds } = input;
  if (!id || !timestamp || !signatureHeader) return false;
  const sentAt = Number(timestamp);
  if (!Number.isFinite(sentAt) || Math.abs(nowSeconds - sentAt) > maxSkewSeconds) return false;

  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const expected = base64(await crypto.subtle.sign("HMAC", key, encoder.encode(`${id}.${timestamp}.${body}`)));
  return signatureHeader
    .split(" ")
    .map((entry) => entry.split(",", 2))
    .some(([version, signature]) => version === "v1" && signature !== undefined && constantTimeEqual(signature, expected));
}

export type PaidSignup = { email: string; paymentId: string };

/**
 * Reads the buyer from a payment.succeeded event. The landing page puts the waitlist email in the checkout's
 * metadata, since the email typed into Whop's checkout can differ; `customer_email` is the fallback.
 */
export function paidSignupFromEvent(event: unknown): PaidSignup | null {
  if (typeof event !== "object" || event === null) return null;
  const { type, data } = event as { type?: unknown; data?: unknown };
  if (type !== "payment.succeeded" || typeof data !== "object" || data === null) return null;
  const payment = data as { id?: unknown; metadata?: unknown; customer_email?: unknown };
  const metadataEmail =
    typeof payment.metadata === "object" && payment.metadata !== null ? (payment.metadata as { email?: unknown }).email : undefined;
  const email = typeof metadataEmail === "string" ? metadataEmail : payment.customer_email;
  if (typeof email !== "string" || email.trim() === "" || typeof payment.id !== "string") return null;
  return { email: email.trim().toLowerCase(), paymentId: payment.id };
}

/** Marks the founding plan paid. Whop delivers at least once, so a repeat of the same payment changes nothing. */
export const markPaid = internalMutation({
  args: { email: v.string(), paymentId: v.string() },
  handler: async (ctx, { email, paymentId }): Promise<{ created: boolean }> => {
    const now = Date.now();
    const existing = await ctx.db
      .query("waitlist")
      .withIndex("by_email", (q) => q.eq("email", email))
      .unique();
    if (existing === null) {
      // Someone can pay through a shared checkout link without joining first; they still belong on the list.
      await ctx.db.insert("waitlist", { email, plan: "founding", source: "whop", paidAt: now, whopPaymentId: paymentId, createdAt: now, updatedAt: now });
      return { created: true };
    }
    if (existing.whopPaymentId !== paymentId) {
      await ctx.db.patch(existing._id, { plan: "founding", paidAt: now, whopPaymentId: paymentId, updatedAt: now });
    }
    return { created: false };
  },
});
