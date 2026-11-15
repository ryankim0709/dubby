import { v } from "convex/values";
import { mutation } from "./_generated/server";
import { requireLearner, requireUser } from "./lib/auth";
import { appError } from "./lib/errors";
import { logEvent } from "./lib/log";
import { isValidTimeZone } from "./lib/timeZone";

/** Registers the signed-in learner on first call; later calls return the same row. */
export const ensure = mutation({
  args: {},
  returns: v.object({ userId: v.id("users"), created: v.boolean() }),
  handler: async (ctx) => {
    const { subject } = await requireLearner(ctx);
    const identity = await ctx.auth.getUserIdentity();
    const accountId = identity !== null && identity.issuer === process.env.CONVEX_SITE_URL ? ctx.db.normalizeId("passwordAccounts", identity.subject) : null;
    const account = accountId === null ? null : await ctx.db.get(accountId);
    const username = account?.username;
    const existing = await ctx.db
      .query("users")
      .withIndex("by_token_identifier", (q) => q.eq("tokenIdentifier", subject))
      .unique();
    if (existing !== null) {
      if (username !== undefined && existing.username !== username) await ctx.db.patch(existing._id, { username });
      return { userId: existing._id, created: false };
    }
    const userId = await ctx.db.insert("users", { tokenIdentifier: subject, username, createdAt: Date.now() });
    logEvent({ operation: "users.ensure", status: "ok", userId });
    return { userId, created: true };
  },
});

export const setTimeZone = mutation({
  args: { timeZone: v.string() },
  returns: v.null(),
  handler: async (ctx, { timeZone }) => {
    const user = await requireUser(ctx);
    if (!isValidTimeZone(timeZone)) throw appError("INVALID_ARGUMENT", "timeZone must be an IANA zone such as America/Los_Angeles");
    await ctx.db.patch(user._id, { timeZone });
    return null;
  },
});
