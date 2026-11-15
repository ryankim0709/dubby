import { type Infer, v } from "convex/values";
import OpenAI from "openai";
import { internal } from "./_generated/api";
import { type ActionCtx, internalMutation } from "./_generated/server";
import { ConfigurationError } from "./lib/env";
import { appError } from "./lib/errors";
import { logEvent } from "./lib/log";
import { createOpenAIClient } from "./lib/openai";
import { type CastFrame, castCharacterV, castScene, castSegmentV, CastResponseError, diarizeScene, sceneCastV } from "./lib/sceneCast";

const leaseMs = 300_000;
const processingV = v.object({ status: v.literal("processing") });
/** No cast is stored yet and the request brought no frames, so the app must sample them and ask again. */
const framesNeededV = v.object({ status: v.literal("framesNeeded") });
const resultV = v.union(sceneCastV, processingV, framesNeededV);
const claimV = v.union(resultV, v.object({
  status: v.literal("claimed"),
  castId: v.id("sceneCasts"),
  leaseId: v.string(),
  videoId: v.id("_storage"),
  contentType: v.string(),
  title: v.string(),
}));
type Claim = Infer<typeof claimV>;
type CastResult = Infer<typeof resultV>;
type CastRequest = { slug: string; sha256: string; locale: string; frames: CastFrame[] };

/**
 * A public request can spend credit only on the exact video of an already-published scene, and only once per
 * video and language: every later request is served the stored cast. Frames are checked against the scene's
 * length before any work is reserved.
 */
export const claim = internalMutation({
  args: { slug: v.string(), sha256: v.string(), locale: v.string(), frameSeconds: v.array(v.number()) },
  returns: claimV,
  handler: async (ctx, { slug, sha256, locale, frameSeconds }): Promise<Claim> => {
    const scene = await ctx.db.query("scenes").withIndex("by_slug", (q) => q.eq("slug", slug)).unique();
    if (scene === null || !scene.published || scene.videoId === undefined) throw appError("NOT_FOUND", "This clip isn't a published library scene, so it has no shared cast.");
    if (scene.locale !== locale) throw appError("INVALID_ARGUMENT", "Choose the library scene's spoken language before finding its speakers.");
    const video = await ctx.db.system.get("_storage", scene.videoId);
    if (video === null || video.sha256 !== sha256) throw appError("CONFLICT", "The library scene has changed. Reopen it from Discover and try again.");
    if (video.size > 24_000_000 || scene.durationSeconds > 120) throw appError("INVALID_ARGUMENT", "This library scene is too large to find its speakers on the backend.");
    if (video.contentType === undefined || !["video/mp4", "video/quicktime", "video/x-m4v"].includes(video.contentType)) throw appError("INVALID_ARGUMENT", "The library scene has an unsupported video format.");
    if (frameSeconds.some((seconds) => !Number.isFinite(seconds) || seconds < 0 || seconds > scene.durationSeconds + 0.5)) {
      throw appError("INVALID_ARGUMENT", "The frames must come from within the library scene.");
    }

    const cached = await ctx.db.query("sceneCasts").withIndex("by_video_locale", (q) => q.eq("videoId", scene.videoId!).eq("locale", locale)).unique();
    if (cached?.status === "ready") {
      if (cached.characters === undefined || cached.segments === undefined) throw new Error("The cached scene cast is incomplete");
      return { status: "ready", characters: cached.characters, segments: cached.segments };
    }
    if (cached?.status === "processing" && cached.leaseExpiresAt > Date.now()) return { status: "processing" };
    if (cached?.status === "failed" && cached.leaseExpiresAt > Date.now()) throw appError("INVALID_STATE", "The scene's speakers couldn't be found. Try again in five minutes.");
    if (frameSeconds.length === 0) return { status: "framesNeeded" };
    const leaseId = crypto.randomUUID();
    const fields = { videoId: scene.videoId, locale, status: "processing" as const, leaseId, leaseExpiresAt: Date.now() + leaseMs };
    const castId = cached === null ? await ctx.db.insert("sceneCasts", fields) : cached._id;
    if (cached !== null) await ctx.db.patch("sceneCasts", cached._id, fields);
    return { status: "claimed", castId, leaseId, videoId: scene.videoId, contentType: video.contentType, title: scene.title };
  },
});

export const complete = internalMutation({
  args: { castId: v.id("sceneCasts"), leaseId: v.string(), characters: v.array(castCharacterV), segments: v.array(castSegmentV) },
  returns: v.null(),
  handler: async (ctx, { castId, leaseId, characters, segments }) => {
    const cast = await ctx.db.get("sceneCasts", castId);
    if (cast === null || cast.leaseId !== leaseId || cast.status !== "processing") throw appError("CONFLICT", "The scene cast request expired. Try again.");
    await ctx.db.patch("sceneCasts", castId, { status: "ready", characters, segments });
    return null;
  },
});

export const fail = internalMutation({
  args: { castId: v.id("sceneCasts"), leaseId: v.string() },
  returns: v.null(),
  handler: async (ctx, { castId, leaseId }) => {
    const cast = await ctx.db.get("sceneCasts", castId);
    if (cast === null || cast.leaseId !== leaseId || cast.status !== "processing") throw appError("CONFLICT", "The scene cast request expired. Try again.");
    await ctx.db.patch("sceneCasts", castId, { status: "failed" });
    return null;
  },
});

/** Diarizes the whole video, then has a vision model name each voice and pick its frame. The lease bounds retries. */
export async function castPublishedScene(ctx: ActionCtx, { slug, sha256, locale, frames }: CastRequest): Promise<CastResult> {
  const claimed: Claim = await ctx.runMutation(internal.sceneCasts.claim, { slug, sha256, locale, frameSeconds: frames.map((frame) => frame.seconds) });
  if (claimed.status !== "claimed") return claimed;
  try {
    const client = createOpenAIClient();
    const video = await ctx.storage.get(claimed.videoId);
    if (video === null) throw appError("NOT_FOUND", "The scene's stored video is missing.");
    const segments = await diarizeScene(client, new File([video], "scene.mp4", { type: claimed.contentType }), locale);
    const cast = await castScene(client, claimed.title, segments, frames);
    await ctx.runMutation(internal.sceneCasts.complete, { castId: claimed.castId, leaseId: claimed.leaseId, characters: cast.characters, segments: cast.segments });
    logEvent({ operation: "scenes.cast", status: "ok", count: cast.characters.length });
    return cast;
  } catch (error) {
    if (!(error instanceof OpenAI.APIError || error instanceof ConfigurationError || error instanceof CastResponseError)) throw error;
    await ctx.runMutation(internal.sceneCasts.fail, { castId: claimed.castId, leaseId: claimed.leaseId });
    throw error;
  }
}
