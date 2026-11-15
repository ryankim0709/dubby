import type { Auth } from "convex/server";

export class UnauthenticatedError extends Error {
  constructor() {
    super("The request has no authenticated learner");
  }
}

/**
 * The learner behind this call, taken only from the verified auth token and never from client input. The
 * subject is the token identifier (issuer plus subject), so IDs from two issuers can't collide.
 * Same contract as Convex Backend's requireLearner; swap this body for an import when it lands.
 */
export async function requireLearner(ctx: { auth: Auth }): Promise<{ subject: string }> {
  const identity = await ctx.auth.getUserIdentity();
  if (identity === null) throw new UnauthenticatedError();
  return { subject: identity.tokenIdentifier };
}
