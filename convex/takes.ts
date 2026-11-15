import { v } from "convex/values";
import { mutation } from "./_generated/server";
import { getOwned, requireUser } from "./lib/auth";
import { appError } from "./lib/errors";
import { logEvent } from "./lib/log";

/**
 * Makes an attempt the kept take for its line. Only the pointer moves: the earlier attempt and its
 * assessments stay in history.
 */
export const accept = mutation({
  args: { attemptId: v.id("attempts") },
  returns: v.object({ acceptedTakeId: v.id("acceptedTakes"), replacedAttemptId: v.union(v.id("attempts"), v.null()) }),
  handler: async (ctx, { attemptId }) => {
    const user = await requireUser(ctx);
    const attempt = await getOwned(ctx, "attempts", attemptId, user);
    if (attempt === null) throw appError("NOT_FOUND", "That attempt doesn't exist");
    const project = await getOwned(ctx, "projects", attempt.projectId, user);
    if (project === null) throw appError("NOT_FOUND", "That attempt doesn't exist");
    if (project.status === "completed") throw appError("INVALID_STATE", "The dub is already complete");

    const now = Date.now();
    const current = await ctx.db
      .query("acceptedTakes")
      .withIndex("by_project_line", (q) => q.eq("projectId", project._id).eq("lineId", attempt.lineId))
      .unique();
    let acceptedTakeId;
    let replacedAttemptId = null;
    if (current === null) {
      acceptedTakeId = await ctx.db.insert("acceptedTakes", {
        ownerId: user._id,
        projectId: project._id,
        lineId: attempt.lineId,
        attemptId,
        acceptedAt: now,
      });
    } else {
      acceptedTakeId = current._id;
      if (current.attemptId !== attemptId) replacedAttemptId = current.attemptId;
      await ctx.db.patch(current._id, { attemptId, acceptedAt: now });
    }
    await ctx.db.patch(project._id, { updatedAt: now });
    logEvent({ operation: "takes.accept", status: "ok", userId: user._id, projectId: project._id, attemptId });
    return { acceptedTakeId, replacedAttemptId };
  },
});
