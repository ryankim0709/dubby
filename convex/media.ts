import { v } from "convex/values";
import { internalQuery } from "./_generated/server";
import { getOwned, requireUser } from "./lib/auth";
import { nullable } from "./lib/validators";

/**
 * Resolves a recording for its owner. Another user's attempt, an unknown id, and a malformed id all
 * look the same: null. The HTTP route calls this with the caller's own identity.
 */
export const attemptAudio = internalQuery({
  args: { rawAttemptId: v.string() },
  returns: nullable(v.object({ storageId: v.id("_storage"), contentType: v.string(), byteSize: v.number() })),
  handler: async (ctx, { rawAttemptId }) => {
    const user = await requireUser(ctx);
    const attemptId = ctx.db.normalizeId("attempts", rawAttemptId);
    if (attemptId === null) return null;
    const attempt = await getOwned(ctx, "attempts", attemptId, user);
    if (attempt === null) return null;
    return { storageId: attempt.audioStorageId, contentType: attempt.contentType, byteSize: attempt.byteSize };
  },
});
