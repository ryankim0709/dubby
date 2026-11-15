import { type Infer, v } from "convex/values";
import OpenAI from "openai";
import { internal } from "./_generated/api";
import { type ActionCtx, internalMutation } from "./_generated/server";
import { ConfigurationError } from "./lib/env";
import { appError } from "./lib/errors";
import { logEvent } from "./lib/log";
import { createOpenAIClient } from "./lib/openai";
import { sceneTranscriptV, timedWordV, transcribeScene, TranscriptionResponseError } from "./lib/transcription";

const requestV = { slug: v.string(), sha256: v.string(), locale: v.string() };
const processingV = v.object({ status: v.literal("processing") });
const resultV = v.union(sceneTranscriptV, processingV);
const claimV = v.union(resultV, v.object({
  status: v.literal("claimed"),
  transcriptId: v.id("sceneTranscripts"),
  leaseId: v.string(),
  videoId: v.id("_storage"),
  contentType: v.string(),
}));
type Claim = Infer<typeof claimV>;
type TranscriptResult = Infer<typeof resultV>;
type TranscriptionRequest = { slug: string; sha256: string; locale: string };

/** A public request can spend credit only on the exact video of an already-published scene. */
export const claim = internalMutation({
  args: requestV,
  returns: claimV,
  handler: async (ctx, { slug, sha256, locale }): Promise<Claim> => {
    const scene = await ctx.db.query("scenes").withIndex("by_slug", (q) => q.eq("slug", slug)).unique();
    if (scene === null || !scene.published || scene.videoId === undefined) throw appError("NOT_FOUND", "This clip isn't a published library scene. Use an iPhone to transcribe local clips.");
    if (scene.locale !== locale) throw appError("INVALID_ARGUMENT", "Choose the library scene's spoken language before transcribing.");
    const video = await ctx.db.system.get("_storage", scene.videoId);
    if (video === null || video.sha256 !== sha256) throw appError("CONFLICT", "The library scene has changed. Reopen it from Discover and try again.");
    if (video.size > 24_000_000 || scene.durationSeconds > 120) throw appError("INVALID_ARGUMENT", "This library scene is too large for backend transcription. Use an iPhone to transcribe it.");
    if (video.contentType === undefined || !["video/mp4", "video/quicktime", "video/x-m4v"].includes(video.contentType)) throw appError("INVALID_ARGUMENT", "The library scene has an unsupported video format.");

    const cached = await ctx.db.query("sceneTranscripts").withIndex("by_video_locale", (q) => q.eq("videoId", scene.videoId!).eq("locale", locale)).unique();
    if (cached?.status === "ready") {
      if (cached.words === undefined || cached.durationSeconds === undefined) throw new Error("The cached scene transcript is incomplete");
      return { status: "ready", locale, durationSeconds: cached.durationSeconds, words: cached.words };
    }
    if (cached?.status === "processing" && cached.leaseExpiresAt > Date.now()) return { status: "processing" };
    if (cached?.status === "failed" && cached.leaseExpiresAt > Date.now()) throw appError("INVALID_STATE", "The scene couldn't be transcribed. Try again in two minutes.");
    const leaseId = crypto.randomUUID();
    const fields = { videoId: scene.videoId, locale, status: "processing" as const, leaseId, leaseExpiresAt: Date.now() + 120_000 };
    const transcriptId = cached === null ? await ctx.db.insert("sceneTranscripts", fields) : cached._id;
    if (cached !== null) await ctx.db.patch("sceneTranscripts", cached._id, fields);
    return { status: "claimed", transcriptId, leaseId, videoId: scene.videoId, contentType: video.contentType };
  },
});

export const complete = internalMutation({
  args: { transcriptId: v.id("sceneTranscripts"), leaseId: v.string(), durationSeconds: v.number(), words: v.array(timedWordV) },
  returns: v.null(),
  handler: async (ctx, { transcriptId, leaseId, durationSeconds, words }) => {
    const transcript = await ctx.db.get("sceneTranscripts", transcriptId);
    if (transcript === null || transcript.leaseId !== leaseId || transcript.status !== "processing") throw appError("CONFLICT", "The scene transcription request expired. Try again.");
    await ctx.db.patch("sceneTranscripts", transcriptId, { status: "ready", durationSeconds, words });
    return null;
  },
});

export const fail = internalMutation({
  args: { transcriptId: v.id("sceneTranscripts"), leaseId: v.string() },
  returns: v.null(),
  handler: async (ctx, { transcriptId, leaseId }) => {
    const transcript = await ctx.db.get("sceneTranscripts", transcriptId);
    if (transcript === null || transcript.leaseId !== leaseId || transcript.status !== "processing") throw appError("CONFLICT", "The scene transcription request expired. Try again.");
    await ctx.db.patch("sceneTranscripts", transcriptId, { status: "failed" });
    return null;
  },
});

/** The lease also bounds retries after a provider outage or an interrupted Convex action. */
export async function transcribePublishedScene(ctx: ActionCtx, args: TranscriptionRequest): Promise<TranscriptResult> {
  const claimed: Claim = await ctx.runMutation(internal.sceneTranscription.claim, args);
  if (claimed.status !== "claimed") return claimed;
  try {
    const client = createOpenAIClient();
    const video = await ctx.storage.get(claimed.videoId);
    if (video === null) throw appError("NOT_FOUND", "The scene's stored video is missing.");
    const transcript = await transcribeScene(client, new File([video], "scene.mp4", { type: claimed.contentType }), args.locale);
    await ctx.runMutation(internal.sceneTranscription.complete, {
      transcriptId: claimed.transcriptId,
      leaseId: claimed.leaseId,
      durationSeconds: transcript.durationSeconds,
      words: transcript.words,
    });
    logEvent({ operation: "scenes.transcribe", status: "ok", count: transcript.words.length });
    return transcript;
  } catch (error) {
    if (!(error instanceof OpenAI.APIError || error instanceof ConfigurationError || error instanceof TranscriptionResponseError)) throw error;
    await ctx.runMutation(internal.sceneTranscription.fail, { transcriptId: claimed.transcriptId, leaseId: claimed.leaseId });
    throw error;
  }
}
