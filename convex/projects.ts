import { v } from "convex/values";
import { mutation, query } from "./_generated/server";
import { getOwned, requireUser } from "./lib/auth";
import { latestLines } from "./lib/catalog";
import { appError } from "./lib/errors";
import { logEvent } from "./lib/log";
import { nullable } from "./lib/validators";

const projectViewV = v.object({
  projectId: v.id("projects"),
  sceneId: v.id("scenes"),
  characterId: v.id("characters"),
  status: v.union(v.literal("active"), v.literal("completed")),
  createdAt: v.number(),
  updatedAt: v.number(),
  completedAt: nullable(v.number()),
  acceptedTakes: v.array(v.object({ lineId: v.id("referenceLines"), attemptId: v.id("attempts"), acceptedAt: v.number() })),
});

/** Starts dubbing one character of a published scene. Repeating the call while the project is active returns it. */
export const start = mutation({
  args: { sceneId: v.id("scenes"), characterId: v.id("characters") },
  returns: v.object({ projectId: v.id("projects"), created: v.boolean() }),
  handler: async (ctx, { sceneId, characterId }) => {
    const user = await requireUser(ctx);
    const scene = await ctx.db.get("scenes", sceneId);
    const character = await ctx.db.get("characters", characterId);
    if (scene === null || !scene.published || character === null || character.sceneId !== sceneId) {
      throw appError("NOT_FOUND", "That scene or character doesn't exist");
    }
    const existing = await ctx.db
      .query("projects")
      .withIndex("by_owner_scene_character", (q) =>
        q.eq("ownerId", user._id).eq("sceneId", sceneId).eq("characterId", characterId).eq("status", "active"),
      )
      .first();
    if (existing !== null) return { projectId: existing._id, created: false };
    const now = Date.now();
    const projectId = await ctx.db.insert("projects", {
      ownerId: user._id,
      sceneId,
      characterId,
      status: "active",
      createdAt: now,
      updatedAt: now,
    });
    logEvent({ operation: "projects.start", status: "ok", userId: user._id, projectId });
    return { projectId, created: true };
  },
});

export const get = query({
  args: { projectId: v.id("projects") },
  returns: nullable(projectViewV),
  handler: async (ctx, { projectId }) => {
    const user = await requireUser(ctx);
    const project = await getOwned(ctx, "projects", projectId, user);
    if (project === null) return null;
    const takes = await ctx.db
      .query("acceptedTakes")
      .withIndex("by_project", (q) => q.eq("projectId", project._id))
      .collect();
    return {
      projectId: project._id,
      sceneId: project.sceneId,
      characterId: project.characterId,
      status: project.status,
      createdAt: project.createdAt,
      updatedAt: project.updatedAt,
      completedAt: project.completedAt ?? null,
      acceptedTakes: takes.map((t) => ({ lineId: t.lineId, attemptId: t.attemptId, acceptedAt: t.acceptedAt })),
    };
  },
});

/** Marks the dub finished once every line of the character has an accepted take. Completing twice is a no-op. */
export const complete = mutation({
  args: { projectId: v.id("projects") },
  returns: v.object({ projectId: v.id("projects"), completedAt: v.number() }),
  handler: async (ctx, { projectId }) => {
    const user = await requireUser(ctx);
    const project = await getOwned(ctx, "projects", projectId, user);
    if (project === null) throw appError("NOT_FOUND", "That project doesn't exist");
    if (project.status === "completed" && project.completedAt !== undefined) {
      return { projectId, completedAt: project.completedAt };
    }
    const lines = await latestLines(ctx, project.characterId);
    const takes = await ctx.db
      .query("acceptedTakes")
      .withIndex("by_project", (q) => q.eq("projectId", project._id))
      .collect();
    const accepted = new Set(takes.map((t) => t.lineId));
    const missing = lines.filter((line) => !accepted.has(line._id)).map((line) => line.lineKey);
    if (lines.length === 0 || missing.length > 0) {
      throw appError("INCOMPLETE_TAKES", "Every line needs an accepted take before the dub is complete", { missingLineKeys: missing });
    }
    const now = Date.now();
    await ctx.db.patch(project._id, { status: "completed", completedAt: now, updatedAt: now });
    logEvent({ operation: "projects.complete", status: "ok", userId: user._id, projectId });
    return { projectId, completedAt: now };
  },
});
