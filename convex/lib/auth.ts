import type { Auth } from "convex/server";
import type { Doc, Id } from "../_generated/dataModel";
import type { MutationCtx, QueryCtx } from "../_generated/server";
import { appError } from "./errors";

type OwnedTable = "projects" | "attempts" | "acceptedTakes" | "assessmentJobs" | "assessments";

/**
 * The authenticated learner. `subject` is identity.tokenIdentifier (issuer plus subject), the same
 * key as users.tokenIdentifier; it is the only source of identity, never a client argument.
 * Tutoring consumes this helper.
 */
export async function requireLearner(ctx: { auth: Auth }): Promise<{ subject: string }> {
  const identity = await ctx.auth.getUserIdentity();
  if (identity === null) throw appError("UNAUTHENTICATED", "Sign in to continue");
  return { subject: identity.tokenIdentifier };
}

/** The caller's users row, or null when unauthenticated or not yet registered with users.ensure. */
export async function currentUser(ctx: QueryCtx): Promise<Doc<"users"> | null> {
  const identity = await ctx.auth.getUserIdentity();
  if (identity === null) return null;
  return await ctx.db
    .query("users")
    .withIndex("by_token_identifier", (q) => q.eq("tokenIdentifier", identity.tokenIdentifier))
    .unique();
}

export async function requireUser(ctx: QueryCtx): Promise<Doc<"users">> {
  const { subject } = await requireLearner(ctx);
  const user = await ctx.db
    .query("users")
    .withIndex("by_token_identifier", (q) => q.eq("tokenIdentifier", subject))
    .unique();
  if (user === null) throw appError("USER_NOT_FOUND", "Call users.ensure after signing in");
  return user;
}

/** Another user's row is indistinguishable from a missing row, so ids never leak existence. */
export async function getOwned<T extends OwnedTable>(
  ctx: QueryCtx | MutationCtx,
  table: T,
  id: Id<T>,
  user: Doc<"users">,
): Promise<Doc<T> | null> {
  const doc = await ctx.db.get(table, id);
  if (doc === null) return null;
  return (doc as unknown as { ownerId: Id<"users"> }).ownerId === user._id ? doc : null;
}
