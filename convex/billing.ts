import { ConvexError, v } from "convex/values";
import { WhopError } from "@whop/sdk";
import { z } from "zod";
import { action, internalMutation, internalQuery, query } from "./_generated/server";
import { internal } from "./_generated/api";
import { requireUser } from "./lib/auth";
import { appError } from "./lib/errors";
import { ConfigurationError, requiredEnv } from "./lib/env";
import { createWhopClient, whopRequest } from "./lib/whop";

const statusV = v.object({ isPremium: v.boolean(), expiresAt: v.union(v.number(), v.null()) });

export const status = query({
  args: {},
  returns: statusV,
  handler: async (ctx) => {
    const user = await requireUser(ctx);
    const memberships = await ctx.db.query("premiumMemberships").withIndex("by_owner", (q) => q.eq("ownerId", user._id)).collect();
    const active = memberships.filter((membership) => membership.active && (membership.expiresAt === null || membership.expiresAt > Date.now()));
    const expirations = active.flatMap((membership) => membership.expiresAt === null ? [] : [membership.expiresAt]);
    return {
      isPremium: active.length > 0,
      expiresAt: active.length === 0 || expirations.length !== active.length ? null : Math.max(...expirations),
    };
  },
});

export const checkoutOwner = internalQuery({
  args: {},
  returns: v.id("users"),
  handler: async (ctx) => (await requireUser(ctx))._id,
});

export const beginCheckout = internalMutation({
  args: { planId: v.string() },
  returns: v.id("premiumCheckouts"),
  handler: async (ctx, { planId }) => {
    const user = await requireUser(ctx);
    return await ctx.db.insert("premiumCheckouts", { ownerId: user._id, planId, createdAt: Date.now() });
  },
});

const planSchema = z.object({
  id: z.string(),
  currency: z.literal("usd"),
  billing_type: z.literal("renewal"),
  billing_period: z.literal(30),
  initial_price: z.literal(0),
  renewal_price: z.literal(4.99),
  trial_period_days: z.union([z.literal(0), z.null()]),
});
const checkoutSchema = z.object({
  purchase_url: z.url().refine((value) => {
    const url = new URL(value);
    return url.protocol === "https:" && (url.hostname === "whop.com" || url.hostname === "sandbox.whop.com");
  }),
});

export const createCheckout = action({
  args: {},
  returns: v.object({ url: v.string() }),
  handler: async (ctx): Promise<{ url: string }> => {
    // Authenticate before touching provider configuration or making an external call.
    await ctx.runQuery(internal.billing.checkoutOwner, {});
    try {
      const client = createWhopClient();
      const planId = requiredEnv("WHOP_PLAN_ID");
      const plan = await whopRequest("billing.plan", () => client.variants.retrieve({ id: planId }));
      if (!planSchema.safeParse(plan).success || plan.id !== planId) {
        throw new ConfigurationError("WHOP_PLAN_ID must be a USD $4.99 recurring variant with a 30-day period, no setup fee, and no trial");
      }
      const checkoutId = await ctx.runMutation(internal.billing.beginCheckout, { planId });
      const checkout = await whopRequest("billing.checkout", () => client.checkoutConfigurations.create({
        variant_id: planId,
        metadata: { dubbyCheckoutId: checkoutId },
      }, { idempotencyKey: checkoutId }));
      return { url: checkoutSchema.parse(checkout).purchase_url };
    } catch (error) {
      if (error instanceof ConfigurationError) throw new ConvexError({ code: "not_configured", message: error.message });
      if (error instanceof WhopError) throw new ConvexError({ code: "checkout_unavailable", message: "Whop couldn't open checkout. Try again shortly." });
      throw error;
    }
  },
});

export const markPremium = internalMutation({
  args: {
    checkoutId: v.string(), planId: v.string(), membershipId: v.string(),
    active: v.boolean(), expiresAt: v.union(v.number(), v.null()), updatedAt: v.number(),
  },
  returns: v.null(),
  handler: async (ctx, args) => {
    const checkoutId = ctx.db.normalizeId("premiumCheckouts", args.checkoutId);
    if (checkoutId === null) throw appError("INVALID_ARGUMENT", "The Whop checkout reference is invalid");
    const checkout = await ctx.db.get(checkoutId);
    if (checkout === null || checkout.planId !== args.planId) throw appError("INVALID_ARGUMENT", "The Whop membership doesn't match a Dubby checkout and plan");
    const existing = await ctx.db.query("premiumMemberships").withIndex("by_membership", (q) => q.eq("membershipId", args.membershipId)).unique();
    if (existing !== null && existing.checkoutId !== checkoutId) throw appError("CONFLICT", "The Whop membership is already linked to another checkout");
    // Membership timestamps, rather than delivery order, make retries and late webhooks harmless.
    if (existing !== null && (existing.updatedAt > args.updatedAt || (existing.updatedAt === args.updatedAt && (!existing.active || args.active)))) return null;
    const membership = { ownerId: checkout.ownerId, checkoutId, membershipId: args.membershipId, active: args.active, expiresAt: args.expiresAt, updatedAt: args.updatedAt };
    if (existing === null) await ctx.db.insert("premiumMemberships", membership);
    else await ctx.db.patch(existing._id, membership);
    return null;
  },
});
