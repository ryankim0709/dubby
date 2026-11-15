import { v } from "convex/values";
import { query } from "./_generated/server";
import { requireUser } from "./lib/auth";
import { latestLines } from "./lib/catalog";
import { nullable } from "./lib/validators";

/** The learner's dubs, newest activity first: My Dubs. */
export const list = query({
  args: { status: v.optional(v.union(v.literal("active"), v.literal("completed"))), limit: v.optional(v.number()) },
  returns: v.array(
    v.object({
      projectId: v.id("projects"),
      sceneId: v.id("scenes"),
      sceneTitle: nullable(v.string()),
      characterId: v.id("characters"),
      characterName: nullable(v.string()),
      status: v.union(v.literal("active"), v.literal("completed")),
      createdAt: v.number(),
      updatedAt: v.number(),
      completedAt: nullable(v.number()),
      acceptedLineCount: v.number(),
      lineCount: v.number(),
    }),
  ),
  handler: async (ctx, { status, limit }) => {
    const user = await requireUser(ctx);
    const take = Math.min(Math.max(Math.trunc(limit ?? 50), 1), 100);
    const projects = await ctx.db
      .query("projects")
      .withIndex("by_owner_updated", (q) => q.eq("ownerId", user._id))
      .order("desc")
      .filter((q) => (status === undefined ? true : q.eq(q.field("status"), status)))
      .take(take);
    return await Promise.all(
      projects.map(async (project) => {
        const scene = await ctx.db.get("scenes", project.sceneId);
        const character = await ctx.db.get("characters", project.characterId);
        const lines = await latestLines(ctx, project.characterId);
        const takes = await ctx.db.query("acceptedTakes").withIndex("by_project", (q) => q.eq("projectId", project._id)).collect();
        const accepted = new Set(takes.map((t) => t.lineId));
        return {
          projectId: project._id,
          sceneId: project.sceneId,
          sceneTitle: scene?.title ?? null,
          characterId: project.characterId,
          characterName: character?.name ?? null,
          status: project.status,
          createdAt: project.createdAt,
          updatedAt: project.updatedAt,
          completedAt: project.completedAt ?? null,
          acceptedLineCount: lines.filter((line) => accepted.has(line._id)).length,
          lineCount: lines.length,
        };
      }),
    );
  },
});
