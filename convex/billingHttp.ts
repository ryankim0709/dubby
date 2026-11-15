import { unwrapWebhook, WebhookVerificationError } from "@whop/sdk/helpers";
import type { HttpRouter } from "convex/server";
import { ConvexError } from "convex/values";
import { z } from "zod";
import { httpAction } from "./_generated/server";
import { api, internal } from "./_generated/api";
import { ConfigurationError, requiredEnv } from "./lib/env";

const eventType = z.object({ type: z.string(), data: z.json() });
const membershipEvent = z.object({
  data: z.object({
    id: z.string().startsWith("mem_"),
    variant_id: z.string().startsWith("plan_"),
    metadata: z.object({ dubbyCheckoutId: z.string().optional() }),
    status: z.enum(["active", "trialing", "past_due", "completed", "canceled", "expired", "unresolved", "drafted", "canceling"]),
    current_period_end: z.iso.datetime({ offset: true }).nullable(),
    updated_at: z.iso.datetime({ offset: true }),
  }),
});

export function registerBillingRoutes(http: HttpRouter): void {
  http.route({
    path: "/billing/checkout",
    method: "POST",
    handler: httpAction(async (ctx) => {
      if ((await ctx.auth.getUserIdentity()) === null) return Response.json({ error: "Sign in before upgrading", code: "unauthenticated" }, { status: 401 });
      try {
        return Response.json(await ctx.runAction(api.billing.createCheckout, {}));
      } catch (error) {
        if (!(error instanceof ConvexError)) throw error;
        const data = z.object({ code: z.string(), message: z.string() }).parse(error.data);
        const status = data.code === "not_configured" ? 503 : data.code === "checkout_unavailable" ? 502 : data.code === "UNAUTHENTICATED" ? 401 : 400;
        return Response.json({ error: data.message, code: data.code }, { status });
      }
    }),
  });
  http.route({
    path: "/webhooks/whop",
    method: "POST",
    handler: httpAction(async (ctx, request) => {
      let key: string;
      try {
        key = requiredEnv("WHOP_COACH_WEBHOOK_SECRET");
      } catch (error) {
        if (!(error instanceof ConfigurationError)) throw error;
        return Response.json({ error: error.message }, { status: 503 });
      }
      const rawBody = await request.text();
      try {
        const event = eventType.parse(unwrapWebhook(rawBody, { headers: Object.fromEntries(request.headers), key }));
        const { type } = event;
        if (!["membership.activated", "membership.deactivated", "membership.updated"].includes(type)) return new Response("OK");
        const { data } = membershipEvent.parse(event);
        if (data.metadata.dubbyCheckoutId === undefined) return new Response("OK");
        const active = data.status === "active" || data.status === "trialing";
        if (active && data.current_period_end === null) return Response.json({ error: "An active coach subscription requires a billing period end" }, { status: 400 });
        await ctx.runMutation(internal.billing.markPremium, {
          checkoutId: data.metadata.dubbyCheckoutId,
          planId: data.variant_id,
          membershipId: data.id,
          active,
          expiresAt: data.current_period_end === null ? null : Date.parse(data.current_period_end),
          updatedAt: Date.parse(data.updated_at),
        });
        // Only signature verification and a single transaction run before the five-second acknowledgement.
        return new Response("OK");
      } catch (error) {
        if (error instanceof WebhookVerificationError) return Response.json({ error: "Invalid Whop signature" }, { status: 401 });
        if (error instanceof SyntaxError || error instanceof z.ZodError) return Response.json({ error: "Invalid Whop event" }, { status: 400 });
        throw error;
      }
    }),
  });
}
