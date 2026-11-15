import { type Infer, v } from "convex/values";
import OpenAI from "openai";
import { ZodError } from "zod";
import { internal } from "./_generated/api";
import type { Doc, Id } from "./_generated/dataModel";
import { type ActionCtx, internalAction, internalMutation, internalQuery, mutation, query } from "./_generated/server";
import { inspectWav, tokenize } from "./assessment";
import { roundHalfUp } from "./assessment/assess";
import { assessTranscript, TRANSCRIPT_LOCALES, unsupportedLocaleOutcome } from "./assessment/transcript";
import { AssessmentError } from "./assessment/types";
import { assessmentOutcomeSchema, CoachingError, coachingSchema, toEngineProvenance } from "./integrations/contracts";
import { getCoachingProvider } from "./integrations/providers";
import { requireUser } from "./lib/auth";
import {
  ACCEPTED_AUDIO_TYPES,
  CAPTURED_AT_FUTURE_SKEW_MS,
  CAPTURED_AT_MAX_AGE_MS,
  MAX_RECORDING_MS,
  MAX_UPLOAD_BYTES,
  RUBRIC_VERSION,
  SCHEMA_VERSION,
} from "./lib/config";
import { computeLineScore, DUB_SHEET_VERSION, summarizeSheet } from "./lib/dubScoreSheet";
import { ConfigurationError } from "./lib/env";
import { appError } from "./lib/errors";
import { logEvent } from "./lib/log";
import { createOpenAIClient } from "./lib/openai";
import { InvalidOutputError, validateCoaching, validateOutcome } from "./lib/outcome";
import { isValidTimeZone } from "./lib/timeZone";
import { TranscriptionResponseError, transcribeScene } from "./lib/transcription";
import { dubLineResultV, dubScoreSheetV, nullable } from "./lib/validators";
import { sha256Hex } from "./tutoringMemory";
import { tutoringRefs } from "./tutoringRefs";

// The dub scoring pipeline (docs/grading-contract.md, "Dub score sheet (dub-v1)"): the app uploads a finished
// dub's takes, each take is graded on its own, and the completed sheet is handed to tutoring for progress and
// memory.

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_TAKES_PER_DUB = 50;
const MAX_LINE_TEXT_LENGTH = 500;
const MAX_NAME_LENGTH = 200;
/** Every line keeps reference version 1: a changed line text is a different line key, not a revision. */
const REFERENCE_VERSION = 1;

const takeV = v.object({
  lineIndex: v.number(),
  referenceText: v.string(),
  startMs: v.number(),
  endMs: v.number(),
  storageId: v.id("_storage"),
});

/** Stable, identifier-safe keys: the same scene title, character name, or line text always maps to the same key. */
async function keyFor(prefix: string, parts: readonly string[]): Promise<string> {
  return `${prefix}-${(await sha256Hex(parts.join("\u0000"))).slice(0, 24)}`;
}

const normalizedName = (name: string) => name.trim().toLocaleLowerCase("en-US");

export const generateUploadUrl = mutation({
  args: {},
  returns: v.string(),
  handler: async (ctx) => {
    await requireUser(ctx);
    return await ctx.storage.generateUploadUrl();
  },
});

/** Records a finished dub and queues each take for grading. Idempotent by the app's dub id. */
export const submit = mutation({
  args: {
    clientDubId: v.string(),
    sceneTitle: v.string(),
    characterName: v.string(),
    locale: v.string(),
    timeZone: v.string(),
    capturedAt: v.number(),
    takes: v.array(takeV),
  },
  returns: v.object({ dubId: v.id("dubs"), created: v.boolean() }),
  handler: async (ctx, args) => {
    const user = await requireUser(ctx);
    if (!UUID.test(args.clientDubId)) throw appError("INVALID_ARGUMENT", "clientDubId must be a UUID");
    const existing = await ctx.db
      .query("dubs")
      .withIndex("by_owner_client", (q) => q.eq("ownerId", user._id).eq("clientDubId", args.clientDubId))
      .unique();
    if (existing !== null) return { dubId: existing._id, created: false };

    const sceneTitle = args.sceneTitle.trim();
    const characterName = args.characterName.trim();
    if (sceneTitle === "" || sceneTitle.length > MAX_NAME_LENGTH) throw appError("INVALID_ARGUMENT", "sceneTitle must be 1 to 200 characters");
    if (characterName === "" || characterName.length > MAX_NAME_LENGTH) throw appError("INVALID_ARGUMENT", "characterName must be 1 to 200 characters");
    if (!/^[a-z]{2,3}-[A-Z]{2}$/.test(args.locale)) throw appError("INVALID_ARGUMENT", "locale must look like en-US");
    if (!isValidTimeZone(args.timeZone)) throw appError("INVALID_ARGUMENT", "timeZone must be an IANA time zone");
    const now = Date.now();
    if (!Number.isFinite(args.capturedAt) || args.capturedAt > now + CAPTURED_AT_FUTURE_SKEW_MS || args.capturedAt < now - CAPTURED_AT_MAX_AGE_MS) {
      throw appError("INVALID_ARGUMENT", "capturedAt isn't a plausible capture time");
    }
    if (args.takes.length === 0 || args.takes.length > MAX_TAKES_PER_DUB) throw appError("INVALID_ARGUMENT", "A dub has 1 to 50 takes");
    if (new Set(args.takes.map((take) => take.lineIndex)).size !== args.takes.length) throw appError("INVALID_ARGUMENT", "Each line is sent once");
    if (new Set(args.takes.map((take) => take.storageId)).size !== args.takes.length) throw appError("INVALID_UPLOAD", "Each take has its own upload");

    const sceneKey = await keyFor("scene", [normalizedName(sceneTitle)]);
    const characterKey = await keyFor("character", [sceneKey, normalizedName(characterName)]);
    const prepared: (Infer<typeof takeV> & { lineKey: string })[] = [];
    for (const take of args.takes) {
      const referenceText = take.referenceText.trim();
      if (!Number.isInteger(take.lineIndex) || take.lineIndex < 0) throw appError("INVALID_ARGUMENT", "lineIndex must be a whole number from 0");
      if (referenceText === "" || referenceText.length > MAX_LINE_TEXT_LENGTH) throw appError("INVALID_ARGUMENT", "A line's text must be 1 to 500 characters");
      const tokens = tokenize(referenceText);
      if (tokens.length === 0) throw appError("INVALID_ARGUMENT", "A line's text needs at least one word");
      const { startMs, endMs } = take;
      if (!Number.isInteger(startMs) || !Number.isInteger(endMs) || startMs < 0 || endMs <= startMs || endMs - startMs > MAX_RECORDING_MS) {
        throw appError("INVALID_ARGUMENT", "A line's window is whole milliseconds, up to 30000 long");
      }
      const file = await ctx.db.system.get("_storage", take.storageId);
      const claimed = await ctx.db
        .query("dubTakes")
        .withIndex("by_storage", (q) => q.eq("storageId", take.storageId))
        .first();
      if (file === null || claimed !== null) throw appError("INVALID_UPLOAD", "A take's upload is missing or already used");
      if (!(ACCEPTED_AUDIO_TYPES as readonly (string | undefined)[]).includes(file.contentType)) {
        throw appError("INVALID_UPLOAD", "Takes must be audio/wav (16 kHz mono 16-bit PCM)");
      }
      if (file.size <= 0 || file.size > MAX_UPLOAD_BYTES) throw appError("INVALID_UPLOAD", "A take must be between 1 byte and 10 MB");
      const lineKey = await keyFor("line", [sceneKey, args.locale, tokens.map((token) => token.norm).join(" ")]);
      prepared.push({ ...take, referenceText, lineKey });
    }

    const dubId = await ctx.db.insert("dubs", {
      ownerId: user._id,
      clientDubId: args.clientDubId,
      sceneKey,
      sceneTitle,
      characterKey,
      characterName,
      locale: args.locale,
      timeZone: args.timeZone,
      capturedAt: args.capturedAt,
      createdAt: now,
      status: "scoring",
    });
    for (const take of prepared) {
      const takeId = await ctx.db.insert("dubTakes", {
        dubId,
        ownerId: user._id,
        lineIndex: take.lineIndex,
        lineKey: take.lineKey,
        referenceText: take.referenceText,
        windowStartMs: take.startMs,
        windowEndMs: take.endMs,
        storageId: take.storageId,
        status: "queued",
      });
      await ctx.scheduler.runAfter(0, internal.dubs.scoreTake, { takeId });
    }
    logEvent({ operation: "dubs.submit", status: "ok", userId: user._id, count: prepared.length });
    return { dubId, created: true };
  },
});

/** The learner's score sheet for one of their dubs, or null when they have no dub with that id. */
export const scoreSheet = query({
  args: { clientDubId: v.string() },
  returns: nullable(dubScoreSheetV),
  handler: async (ctx, { clientDubId }) => {
    const user = await requireUser(ctx);
    const dub = await ctx.db
      .query("dubs")
      .withIndex("by_owner_client", (q) => q.eq("ownerId", user._id).eq("clientDubId", clientDubId))
      .unique();
    if (dub === null) return null;
    const takes = (await ctx.db
      .query("dubTakes")
      .withIndex("by_dub", (q) => q.eq("dubId", dub._id))
      .collect()).sort((a, b) => a.lineIndex - b.lineIndex);
    const summary = summarizeSheet(takes.map(sheetLineInput));
    return {
      sheetVersion: DUB_SHEET_VERSION,
      dubId: dub._id,
      sceneTitle: dub.sceneTitle,
      characterName: dub.characterName,
      locale: dub.locale,
      ...summary,
      lines: takes.map((take) => {
        const result = take.result;
        const lineScore = result?.lineScoreRaw ?? null;
        return {
          lineIndex: take.lineIndex,
          referenceText: take.referenceText,
          status: take.status,
          recognizedText: result?.recognizedText ?? null,
          lineScore: lineScore === null ? null : roundHalfUp(lineScore),
          wordAccuracy: result?.scores?.wordAccuracy ?? null,
          timingFit: result?.scores?.timingFit ?? null,
          reason: result?.reason ?? take.failure?.code ?? null,
          coachingSummary: result?.coaching.summary ?? null,
          words: (result?.wordResults ?? []).map((word) => ({ expected: word.expected, recognized: word.recognized, textStatus: word.textStatus })),
        };
      }),
    };
  },
});

const historyItemV = v.object({
  clientDubId: v.string(),
  capturedAt: v.number(),
  sceneTitle: v.string(),
  characterName: v.string(),
  locale: v.string(),
  /** Which evaluator scored the dub, so a chart only joins dubs from the same progress series; null when no take was graded. */
  evaluator: nullable(v.object({ rubricVersion: v.string(), provider: v.string(), configVersion: v.string() })),
  dubScore: nullable(v.number()),
  wordAccuracy: nullable(v.number()),
  timingFit: nullable(v.number()),
});

/** The learner's completed dubs, oldest first, with each one's score card totals: what the Progress charts plot. */
export const history = query({
  args: {},
  returns: v.array(historyItemV),
  handler: async (ctx) => {
    const user = await requireUser(ctx);
    const dubs = await ctx.db
      .query("dubs")
      .withIndex("by_owner_client", (q) => q.eq("ownerId", user._id))
      .collect();
    const items = [];
    for (const dub of dubs) {
      if (dub.status !== "complete") continue;
      const takes = await ctx.db
        .query("dubTakes")
        .withIndex("by_dub", (q) => q.eq("dubId", dub._id))
        .collect();
      const { dubScore, wordAccuracy, timingFit } = summarizeSheet(takes.map(sheetLineInput));
      const engine = takes.find((take) => take.result !== undefined)?.result?.provenance.engine;
      items.push({
        clientDubId: dub.clientDubId,
        capturedAt: dub.capturedAt,
        sceneTitle: dub.sceneTitle,
        characterName: dub.characterName,
        locale: dub.locale,
        evaluator: engine === undefined ? null : { rubricVersion: RUBRIC_VERSION, provider: engine.provider, configVersion: engine.configVersion },
        dubScore,
        wordAccuracy,
        timingFit,
      });
    }
    return items.sort((a, b) => a.capturedAt - b.capturedAt);
  },
});

// ---- Grading ------------------------------------------------------------------------------------------------

export const takeForScoring = internalQuery({
  args: { takeId: v.id("dubTakes") },
  handler: async (ctx, { takeId }) => {
    const take = await ctx.db.get("dubTakes", takeId);
    if (take === null) return null;
    const dub = await ctx.db.get("dubs", take.dubId);
    if (dub === null) throw new Error(`Take ${takeId} belongs to a missing dub`);
    return { take, dub };
  },
});

const gradedResultV = v.object({ kind: v.literal("graded"), result: dubLineResultV });
const failedResultV = v.object({ kind: v.literal("failed"), code: v.string(), message: v.string() });

/** Stores one take's grade. Exactly one call sees the dub's last take finish and marks the dub complete. */
export const recordTakeResult = internalMutation({
  args: { takeId: v.id("dubTakes"), outcome: v.union(gradedResultV, failedResultV) },
  returns: v.object({ completed: v.boolean() }),
  handler: async (ctx, { takeId, outcome }) => {
    const take = await ctx.db.get("dubTakes", takeId);
    if (take === null || take.status !== "queued") return { completed: false };
    if (outcome.kind === "graded") {
      await ctx.db.patch(takeId, { status: outcome.result.status, result: outcome.result });
    } else {
      await ctx.db.patch(takeId, { status: "failed", failure: { code: outcome.code, message: outcome.message } });
    }
    const dub = await ctx.db.get("dubs", take.dubId);
    if (dub === null || dub.status === "complete") return { completed: false };
    const takes = await ctx.db
      .query("dubTakes")
      .withIndex("by_dub", (q) => q.eq("dubId", dub._id))
      .collect();
    if (takes.some((other) => other.status === "queued")) return { completed: false };
    await ctx.db.patch(dub._id, { status: "complete", completedAt: Date.now() });
    return { completed: true };
  },
});

export const completedDub = internalQuery({
  args: { dubId: v.id("dubs") },
  handler: async (ctx, { dubId }) => {
    const dub = await ctx.db.get("dubs", dubId);
    if (dub === null) throw new Error(`Dub ${dubId} is missing`);
    const owner = await ctx.db.get("users", dub.ownerId);
    if (owner === null) throw new Error(`Dub ${dubId} has no owner row`);
    const takes = await ctx.db
      .query("dubTakes")
      .withIndex("by_dub", (q) => q.eq("dubId", dubId))
      .collect();
    return { dub, takes, ownerSubject: owner.tokenIdentifier };
  },
});

/** A take's unrounded values on the score sheet. */
function sheetLineInput(take: Doc<"dubTakes">) {
  return {
    status: take.status,
    lineScore: take.result?.lineScoreRaw ?? null,
    wordAccuracy: take.result?.wordAccuracyRaw ?? null,
    timingFit: take.result?.scores?.timingFit ?? null,
  };
}

type TakeForScoring = { take: Doc<"dubTakes">; dub: Doc<"dubs"> };
type LineResult = Infer<typeof dubLineResultV>;
type TakeOutcome = Infer<typeof gradedResultV> | Infer<typeof failedResultV>;

class GradingFailure extends Error {
  constructor(
    readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = "GradingFailure";
  }
}

/** Names a grading failure for the take's record. Provider error bodies are never copied, since they can echo request content. */
function toGradingFailure(error: unknown): GradingFailure {
  if (error instanceof GradingFailure) return error;
  if (error instanceof InvalidOutputError) return new GradingFailure(error.code, error.message);
  if (error instanceof AssessmentError) return new GradingFailure(error.kind, error.message.slice(0, 300));
  if (error instanceof CoachingError) return new GradingFailure(error.code, error.message.slice(0, 300));
  if (error instanceof ConfigurationError) return new GradingFailure("not_configured", error.message);
  if (error instanceof TranscriptionResponseError) return new GradingFailure("invalid_provider_response", error.message);
  if (error instanceof ZodError) return new GradingFailure("invalid_engine_output", "The transcript evaluator's outcome didn't match the contract");
  if (error instanceof OpenAI.APIError) {
    const status = error.status;
    if (status === undefined) return new GradingFailure("provider_unavailable", "OpenAI didn't respond");
    const code = status === 429 || status >= 500 ? "provider_unavailable" : "provider_rejected";
    return new GradingFailure(code, `OpenAI transcription failed with status ${status}`);
  }
  if (error instanceof Error) return new GradingFailure("internal_error", error.message.slice(0, 300));
  return new GradingFailure("internal_error", "Grading stopped with a non-Error value");
}

async function gradeTake(ctx: ActionCtx, { take, dub }: TakeForScoring): Promise<LineResult> {
  const blob = await ctx.storage.get(take.storageId);
  if (blob === null) throw new GradingFailure("recording_missing", "The take's recording is no longer stored");
  const bytes = new Uint8Array(await blob.arrayBuffer());
  const { durationMs: recordingDurationMs } = inspectWav(bytes);
  const recordedAt = new Date(dub.capturedAt).toISOString();
  const input = {
    assessmentId: take._id,
    attemptId: take._id,
    lineId: take.lineKey,
    referenceVersion: REFERENCE_VERSION,
    locale: dub.locale,
    recordedAt,
    referenceText: take.referenceText,
    targetWindowMs: { startMs: take.windowStartMs, endMs: take.windowEndMs },
    recordingDurationMs,
  };
  const raw = TRANSCRIPT_LOCALES.includes(dub.locale)
    ? assessTranscript(input, (await transcribeScene(createOpenAIClient(), new File([bytes], "take.wav", { type: "audio/wav" }), dub.locale)).words)
    : unsupportedLocaleOutcome(input);
  const outcome = assessmentOutcomeSchema.parse(raw);
  const referenceWordCount = validateOutcome(outcome, input);

  const provider = getCoachingProvider();
  if (provider === null) throw new GradingFailure("coach_not_configured", "No coaching provider is configured on this deployment");
  const { response, evidence } = outcome;
  const coaching = coachingSchema.parse(
    await provider.coach({
      locale: dub.locale,
      referenceText: take.referenceText,
      recognizedText: response.recognizedText,
      status: response.status,
      reason: response.status === "unscorable" ? response.reason : null,
      scores: response.scores,
      wordResults: response.wordResults,
      evidence,
      learner: { userId: take.ownerId },
    }),
  );
  validateCoaching(coaching, response.status, referenceWordCount);

  return {
    status: response.status,
    ...(response.status === "unscorable" ? { reason: response.reason } : {}),
    recognizedText: response.recognizedText,
    scores: response.scores,
    unavailableMetrics: response.unavailableMetrics,
    wordResults: response.wordResults,
    coaching: { summary: coaching.summary, strengths: coaching.strengths, focus: coaching.focus },
    wordAccuracyRaw: evidence.rawScores.wordAccuracy,
    lineScoreRaw: computeLineScore(evidence.rawScores.wordAccuracy, evidence.rawScores.timingFit),
    speakingDurationMs: evidence.timing?.spokenDurationMs ?? null,
    recordingDurationMs,
    provenance: {
      engine: toEngineProvenance(outcome.provenance),
      coaching: { provider: coaching.provider, configVersion: coaching.configVersion },
    },
    completedAt: Date.now(),
  };
}

/** The completed dub as one tutoring session; failed takes have no grade and are left out. */
function tutoringSession(dub: Doc<"dubs">, takes: readonly Doc<"dubTakes">[]) {
  const graded = takes.flatMap((take) => (take.result === undefined ? [] : [{ take, result: take.result }]));
  const first = graded[0];
  if (first === undefined) return null;
  const engine = first.result.provenance.engine;
  const { dubScore, wordAccuracy, timingFit, linesDubbed, linesScored, linesUnscorable, linesFailed } = summarizeSheet(takes.map(sheetLineInput));
  return {
    dub: {
      sheetVersion: DUB_SHEET_VERSION,
      sceneTitle: dub.sceneTitle,
      characterName: dub.characterName,
      scoreCard: { dubScore, wordAccuracy, timingFit, linesDubbed, linesScored, linesUnscorable, linesFailed },
    },
    sessionId: dub._id,
    sceneId: dub.sceneKey,
    characterId: dub.characterKey,
    timeZone: dub.timeZone,
    evaluator: {
      provider: engine.provider,
      modelVersion: engine.providerModelVersion,
      configVersion: engine.configVersion,
      completedAt: new Date(dub.completedAt ?? first.result.completedAt).toISOString(),
      measurement: engine.measurement,
    },
    assessments: graded.map(({ take, result }) => ({
      assessment: {
        schemaVersion: SCHEMA_VERSION,
        rubricVersion: RUBRIC_VERSION,
        assessmentId: take._id,
        attemptId: take._id,
        lineId: take.lineKey,
        referenceVersion: REFERENCE_VERSION,
        locale: dub.locale,
        recordedAt: new Date(dub.capturedAt).toISOString(),
        status: result.status,
        ...(result.reason === undefined ? {} : { reason: result.reason }),
        referenceText: take.referenceText,
        recognizedText: result.recognizedText,
        scores: result.scores,
        unavailableMetrics: result.unavailableMetrics,
        wordResults: result.wordResults,
        coaching: result.coaching,
      },
      speakingDurationMs: Math.round(result.speakingDurationMs ?? 0),
      recordingDurationMs: result.recordingDurationMs,
      sheet: { version: DUB_SHEET_VERSION, lineScore: result.lineScoreRaw, wordAccuracy: result.wordAccuracyRaw, timingFit: result.scores?.timingFit ?? null },
    })),
  };
}

async function ingestIntoTutoring(ctx: ActionCtx, dubId: Id<"dubs">): Promise<void> {
  const { dub, takes, ownerSubject } = await ctx.runQuery(internal.dubs.completedDub, { dubId });
  const session = tutoringSession(dub, takes);
  if (session === null) {
    logEvent({ operation: "dubs.ingest", status: "skipped", errorCode: "no_graded_takes" });
    return;
  }
  const result = await ctx.runMutation(tutoringRefs.ingestDubbingSession, { subject: ownerSubject, session });
  if (result.outcome === "rejected") {
    // The sheet and tutoring disagree about the contract, which is a bug: the grades stay stored, and the action fails loudly.
    logEvent({ operation: "dubs.ingest", status: "failed", errorCode: "tutoring_rejected", count: result.issues.length });
    throw new Error(`Tutoring rejected dub ${dubId}: ${result.issues.map((issue) => `${issue.path}: ${issue.message}`).join("; ")}`);
  }
  logEvent({ operation: "dubs.ingest", status: "ok", count: result.results.length });
}

export const scoreTake = internalAction({
  args: { takeId: v.id("dubTakes") },
  returns: v.null(),
  handler: async (ctx, { takeId }) => {
    const loaded = await ctx.runQuery(internal.dubs.takeForScoring, { takeId });
    if (loaded === null || loaded.take.status !== "queued") return null;
    let outcome: TakeOutcome;
    try {
      outcome = { kind: "graded", result: await gradeTake(ctx, loaded) };
    } catch (error) {
      const failure = toGradingFailure(error);
      logEvent({ operation: "dubs.scoreTake", status: "failed", errorCode: failure.code });
      outcome = { kind: "failed", code: failure.code, message: failure.message };
    }
    const { completed } = await ctx.runMutation(internal.dubs.recordTakeResult, { takeId, outcome });
    if (completed) await ingestIntoTutoring(ctx, loaded.dub._id);
    return null;
  },
});
