import { v } from "convex/values";
import { internal } from "./_generated/api";
import type { Doc, Id } from "./_generated/dataModel";
import { internalAction, internalMutation, mutation, query } from "./_generated/server";
import type { MutationCtx } from "./_generated/server";
import {
  type Coaching,
  AssessmentError,
  CoachingError,
  assessmentOutcomeSchema,
  coachingSchema,
  toEngineProvenance,
} from "./integrations/contracts";
import { getAssessmentEngine, getCoachingProvider } from "./integrations/providers";
import { getOwned, requireUser } from "./lib/auth";
import { BACKOFF_BASE_MS, LEASE_MS, MAX_JOB_TRIES, RUBRIC_VERSION, SCHEMA_VERSION } from "./lib/config";
import { appError } from "./lib/errors";
import { logEvent } from "./lib/log";
import { InvalidOutputError, validateCoaching, validateOutcome } from "./lib/outcome";
import { assessmentBodyFields, assessmentViewV, jobViewV, nullable, outcomeV } from "./lib/validators";

/** How a job try ended. autoRetry spends another try after a backoff; retryable lets the owner retry once tries run out. */
class PipelineFailure extends Error {
  constructor(
    readonly code: string,
    message: string,
    readonly retryable: boolean,
    readonly autoRetry: boolean,
  ) {
    super(message);
    this.name = "PipelineFailure";
  }
}

const failureV = v.object({ code: v.string(), message: v.string(), retryable: v.boolean(), autoRetry: v.boolean() });

function toFailure(error: unknown, stage: "measure" | "coach"): PipelineFailure {
  if (error instanceof PipelineFailure) return error;
  if (error instanceof InvalidOutputError) return new PipelineFailure(error.code, error.message, false, false);
  if (error instanceof AssessmentError) {
    return new PipelineFailure(error.kind, error.message.slice(0, 300), error.retryable, error.retryable);
  }
  if (error instanceof CoachingError) {
    return new PipelineFailure(error.code, error.message.slice(0, 300), error.retryable, error.retryable);
  }
  const code = stage === "measure" ? "engine_unexpected_error" : "coach_unexpected_error";
  return new PipelineFailure(code, "An unexpected error interrupted the assessment", true, true);
}

function jobView(job: Doc<"assessmentJobs">) {
  return {
    jobId: job._id,
    kind: job.kind,
    status: job.status,
    stage: job.stage,
    tries: job.tries,
    error: job.error ?? null,
    assessmentId: job.assessmentId ?? null,
    updatedAt: job.updatedAt,
  };
}

function viewOf(assessment: Doc<"assessments">) {
  const { _id, _creationTime, ownerId, ...rest } = assessment;
  return { assessmentId: _id, ...rest };
}

/** The job state and the latest result for one attempt, or null when it isn't the caller's. */
export const forAttempt = query({
  args: { attemptId: v.id("attempts") },
  returns: nullable(v.object({ job: nullable(jobViewV), assessment: nullable(assessmentViewV) })),
  handler: async (ctx, { attemptId }) => {
    const user = await requireUser(ctx);
    const attempt = await getOwned(ctx, "attempts", attemptId, user);
    if (attempt === null) return null;
    const job = await ctx.db.query("assessmentJobs").withIndex("by_attempt", (q) => q.eq("attemptId", attemptId)).order("desc").first();
    const assessment = await ctx.db.query("assessments").withIndex("by_attempt", (q) => q.eq("attemptId", attemptId)).order("desc").first();
    return { job: job === null ? null : jobView(job), assessment: assessment === null ? null : viewOf(assessment) };
  },
});

/** Re-queues the same failed job. It adds no attempt, keeps a stored measurement, and never yields a second assessment for the job. */
export const retry = mutation({
  args: { jobId: v.id("assessmentJobs") },
  returns: v.object({ jobId: v.id("assessmentJobs") }),
  handler: async (ctx, { jobId }) => {
    const user = await requireUser(ctx);
    const job = await getOwned(ctx, "assessmentJobs", jobId, user);
    if (job === null) throw appError("NOT_FOUND", "That job doesn't exist");
    if (job.status !== "failed") throw appError("INVALID_STATE", "Only a failed job can be retried");
    if (job.error?.retryable !== true) throw appError("INVALID_STATE", "Retrying can't fix this failure; record the line again");
    await ctx.db.patch(jobId, {
      status: "queued",
      stage: job.outcome === undefined ? "measure" : "coach",
      tries: 0,
      error: undefined,
      leaseExpiresAt: undefined,
      updatedAt: Date.now(),
    });
    await ctx.scheduler.runAfter(0, internal.assessments.run, { jobId });
    logEvent({ operation: "assessments.retry", status: "ok", userId: user._id, attemptId: job.attemptId, jobId });
    return { jobId };
  },
});

/** A deliberate regrade of an existing recording: a new job that produces a new assessment id for the same attempt. */
export const reassess = internalMutation({
  args: { attemptId: v.id("attempts") },
  returns: v.object({ jobId: v.id("assessmentJobs") }),
  handler: async (ctx, { attemptId }) => {
    const attempt = await ctx.db.get("attempts", attemptId);
    if (attempt === null) throw appError("NOT_FOUND", "That attempt doesn't exist");
    const jobs = await ctx.db.query("assessmentJobs").withIndex("by_attempt", (q) => q.eq("attemptId", attemptId)).collect();
    if (jobs.some((job) => job.status === "queued" || job.status === "processing")) {
      throw appError("INVALID_STATE", "The attempt already has a job in progress");
    }
    const now = Date.now();
    const jobId = await ctx.db.insert("assessmentJobs", {
      ownerId: attempt.ownerId,
      attemptId,
      kind: "reassessment",
      status: "queued",
      stage: "measure",
      tries: 0,
      createdAt: now,
      updatedAt: now,
    });
    await ctx.scheduler.runAfter(0, internal.assessments.run, { jobId });
    logEvent({ operation: "assessments.reassess", status: "ok", userId: attempt.ownerId, attemptId, jobId });
    return { jobId };
  },
});

async function failJob(ctx: MutationCtx, job: Doc<"assessmentJobs">, failure: { code: string; message: string; retryable: boolean }) {
  await ctx.db.patch(job._id, {
    status: "failed",
    error: { code: failure.code, message: failure.message, retryable: failure.retryable },
    leaseExpiresAt: undefined,
    updatedAt: Date.now(),
  });
  logEvent({
    operation: "assessments.job",
    status: "failed",
    errorCode: failure.code,
    retryable: failure.retryable,
    attemptId: job.attemptId,
    jobId: job._id,
    stage: job.stage,
    tries: job.tries,
  });
}

/** Takes the lease for a queued job and loads everything the action needs. Null means there is nothing to do. */
export const claim = internalMutation({
  args: { jobId: v.id("assessmentJobs") },
  returns: nullable(
    v.object({
      lease: v.number(),
      tries: v.number(),
      stage: v.union(v.literal("measure"), v.literal("coach")),
      ownerId: v.id("users"),
      attemptId: v.id("attempts"),
      lineId: v.id("referenceLines"),
      audioStorageId: v.id("_storage"),
      contentType: v.string(),
      recordingDurationMs: v.number(),
      capturedAt: v.number(),
      locale: v.string(),
      referenceText: v.string(),
      referenceVersion: v.number(),
      windowStartMs: v.number(),
      windowEndMs: v.number(),
      outcome: nullable(outcomeV),
    }),
  ),
  handler: async (ctx, { jobId }) => {
    const job = await ctx.db.get("assessmentJobs", jobId);
    if (job === null || job.status !== "queued") return null;
    const attempt = await ctx.db.get("attempts", job.attemptId);
    const line = attempt === null ? null : await ctx.db.get("referenceLines", attempt.lineId);
    if (attempt === null || line === null) {
      await failJob(ctx, job, { code: "attempt_missing", message: "The recording or its line no longer exists", retryable: false });
      return null;
    }
    const now = Date.now();
    const lease = now + LEASE_MS;
    const stage: "measure" | "coach" = job.outcome === undefined ? "measure" : "coach";
    await ctx.db.patch(jobId, { status: "processing", stage, tries: job.tries + 1, leaseExpiresAt: lease, error: undefined, updatedAt: now });
    return {
      lease,
      tries: job.tries + 1,
      stage,
      ownerId: job.ownerId,
      attemptId: attempt._id,
      lineId: line._id,
      audioStorageId: attempt.audioStorageId,
      contentType: attempt.contentType,
      recordingDurationMs: attempt.durationMs,
      capturedAt: attempt.capturedAt,
      locale: line.locale,
      referenceText: line.text,
      referenceVersion: line.referenceVersion,
      windowStartMs: Math.round(line.startSeconds * 1000),
      windowEndMs: Math.round(line.endSeconds * 1000),
      outcome: job.outcome ?? null,
    };
  },
});

async function heldJob(ctx: MutationCtx, jobId: Id<"assessmentJobs">, lease: number) {
  const job = await ctx.db.get("assessmentJobs", jobId);
  return job !== null && job.status === "processing" && job.leaseExpiresAt === lease ? job : null;
}

/** Stores the validated engine outcome so a coaching retry never calls the engine again. False means the lease was lost. */
export const saveOutcome = internalMutation({
  args: { jobId: v.id("assessmentJobs"), lease: v.number(), outcome: outcomeV },
  returns: v.boolean(),
  handler: async (ctx, { jobId, lease, outcome }) => {
    const job = await heldJob(ctx, jobId, lease);
    if (job === null) return false;
    await ctx.db.patch(jobId, { outcome, stage: "coach", updatedAt: Date.now() });
    return true;
  },
});

export const complete = internalMutation({
  args: { jobId: v.id("assessmentJobs"), lease: v.number(), assessment: v.object(assessmentBodyFields) },
  returns: nullable(v.id("assessments")),
  handler: async (ctx, { jobId, lease, assessment }) => {
    const job = await heldJob(ctx, jobId, lease);
    if (job === null) return null;
    const duplicate = await ctx.db.query("assessments").withIndex("by_job", (q) => q.eq("jobId", jobId)).first();
    if (duplicate !== null) return duplicate._id;
    const now = Date.now();
    const assessmentId = await ctx.db.insert("assessments", { ownerId: job.ownerId, jobId, completedAt: now, ...assessment });
    await ctx.db.patch(jobId, { status: "succeeded", assessmentId, error: undefined, leaseExpiresAt: undefined, updatedAt: now });
    logEvent({
      operation: "assessments.job",
      status: "ok",
      attemptId: job.attemptId,
      jobId,
      assessmentId,
      tries: job.tries,
      stage: job.stage,
    });
    return assessmentId;
  },
});

/** Ends a try: another try after a backoff while tries remain, otherwise an explicit failed state. */
export const recordFailure = internalMutation({
  args: { jobId: v.id("assessmentJobs"), lease: v.number(), failure: failureV },
  returns: v.union(v.literal("queued"), v.literal("failed"), v.literal("stale")),
  handler: async (ctx, { jobId, lease, failure }) => {
    const job = await heldJob(ctx, jobId, lease);
    if (job === null) return "stale";
    if (failure.autoRetry && job.tries < MAX_JOB_TRIES) {
      await ctx.db.patch(jobId, { status: "queued", leaseExpiresAt: undefined, updatedAt: Date.now() });
      await ctx.scheduler.runAfter(BACKOFF_BASE_MS * 2 ** (job.tries - 1), internal.assessments.run, { jobId });
      logEvent({
        operation: "assessments.job",
        status: "retrying",
        errorCode: failure.code,
        retryable: failure.retryable,
        attemptId: job.attemptId,
        jobId,
        stage: job.stage,
        tries: job.tries,
      });
      return "queued";
    }
    await failJob(ctx, job, failure);
    return "failed";
  },
});

/** Cron target: a job whose action died keeps its lease until it expires, then gets another try or fails visibly. */
export const reclaimStale = internalMutation({
  args: {},
  returns: v.number(),
  handler: async (ctx) => {
    const now = Date.now();
    const stale = await ctx.db
      .query("assessmentJobs")
      .withIndex("by_status_lease", (q) => q.eq("status", "processing").lt("leaseExpiresAt", now))
      .take(100);
    for (const job of stale) {
      if (job.tries < MAX_JOB_TRIES) {
        await ctx.db.patch(job._id, { status: "queued", leaseExpiresAt: undefined, updatedAt: now });
        await ctx.scheduler.runAfter(0, internal.assessments.run, { jobId: job._id });
        logEvent({ operation: "assessments.reclaim", status: "retrying", errorCode: "lease_expired", jobId: job._id, tries: job.tries });
        continue;
      }
      await failJob(ctx, job, { code: "lease_expired", message: "The assessment stopped responding", retryable: true });
    }
    return stale.length;
  },
});

/** Runs one try of a job: assess with the engine, coach, then store the assessment. */
export const run = internalAction({
  args: { jobId: v.id("assessmentJobs") },
  returns: v.null(),
  handler: async (ctx, { jobId }) => {
    const claim = await ctx.runMutation(internal.assessments.claim, { jobId });
    if (claim === null) return null;
    let stage: "measure" | "coach" = claim.stage;
    try {
      const recordedAt = new Date(claim.capturedAt).toISOString();
      let outcome = claim.outcome;
      if (outcome === null) {
        const engine = getAssessmentEngine();
        if (engine === null) throw new PipelineFailure("engine_not_configured", "No assessment engine is configured on this deployment", true, false);
        const audio = await ctx.storage.get(claim.audioStorageId);
        if (audio === null) throw new PipelineFailure("audio_missing", "The recording is no longer in storage", false, false);
        const raw = await engine.assess(
          {
            assessmentId: jobId,
            attemptId: claim.attemptId,
            lineId: claim.lineId,
            referenceVersion: claim.referenceVersion,
            locale: claim.locale,
            recordedAt,
            referenceText: claim.referenceText,
            targetWindowMs: { startMs: claim.windowStartMs, endMs: claim.windowEndMs },
            recordingDurationMs: claim.recordingDurationMs,
          },
          audio,
        );
        const parsed = assessmentOutcomeSchema.safeParse(raw);
        if (!parsed.success) throw new InvalidOutputError("invalid_engine_output", "The engine outcome didn't match the contract");
        validateOutcome(parsed.data, {
          attemptId: claim.attemptId,
          lineId: claim.lineId,
          referenceVersion: claim.referenceVersion,
          locale: claim.locale,
          recordedAt,
          referenceText: claim.referenceText,
          recordingDurationMs: claim.recordingDurationMs,
        });
        outcome = { response: parsed.data.response, evidence: parsed.data.evidence, provenance: toEngineProvenance(parsed.data.provenance) };
        if (!(await ctx.runMutation(internal.assessments.saveOutcome, { jobId, lease: claim.lease, outcome }))) return null;
      }

      stage = "coach";
      const { response, evidence } = outcome;
      const referenceWordCount = response.wordResults.filter((word: { referenceWordIndex: number | null }) => word.referenceWordIndex !== null).length;
      const provider = getCoachingProvider();
      if (provider === null) throw new PipelineFailure("coach_not_configured", "No coaching provider is configured on this deployment", true, false);
      const rawCoaching = await provider.coach({
        locale: claim.locale,
        referenceText: claim.referenceText,
        recognizedText: response.recognizedText,
        status: response.status,
        reason: response.status === "unscorable" ? response.reason : null,
        scores: response.scores,
        wordResults: response.wordResults,
        evidence,
        learner: { userId: claim.ownerId },
      });
      const parsedCoaching = coachingSchema.safeParse(rawCoaching);
      if (!parsedCoaching.success) throw new InvalidOutputError("invalid_coaching_output", "The coaching response didn't match the contract");
      const coaching: Coaching = parsedCoaching.data;
      validateCoaching(coaching, response.status, referenceWordCount);

      await ctx.runMutation(internal.assessments.complete, {
        jobId,
        lease: claim.lease,
        assessment: {
          schemaVersion: SCHEMA_VERSION,
          rubricVersion: RUBRIC_VERSION,
          attemptId: claim.attemptId,
          lineId: claim.lineId,
          referenceVersion: claim.referenceVersion,
          locale: claim.locale,
          recordedAt,
          status: response.status,
          ...(response.status === "unscorable" ? { reason: response.reason } : {}),
          referenceText: claim.referenceText,
          recognizedText: response.recognizedText,
          scores: response.scores,
          unavailableMetrics: response.unavailableMetrics,
          wordResults: response.wordResults,
          coaching: { summary: coaching.summary, strengths: coaching.strengths, focus: coaching.focus },
          speakingDurationMs: evidence.timing?.spokenDurationMs ?? null,
          provenance: {
            engine: outcome.provenance,
            coaching: { provider: coaching.provider, configVersion: coaching.configVersion },
          },
        },
      });
      return null;
    } catch (error) {
      const failure = toFailure(error, stage);
      await ctx.runMutation(internal.assessments.recordFailure, {
        jobId,
        lease: claim.lease,
        failure: { code: failure.code, message: failure.message, retryable: failure.retryable, autoRetry: failure.autoRetry },
      });
      return null;
    }
  },
});
