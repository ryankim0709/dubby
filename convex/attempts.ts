import { v } from "convex/values";
import { mutation, query } from "./_generated/server";
import { getOwned, requireLearner, requireUser } from "./lib/auth";
import {
  ACCEPTED_AUDIO_TYPES,
  CAPTURED_AT_FUTURE_SKEW_MS,
  CAPTURED_AT_MAX_AGE_MS,
  MAX_RECORDING_MS,
  MAX_UPLOAD_BYTES,
} from "./lib/config";
import { appError } from "./lib/errors";
import { logEvent } from "./lib/log";
import { isValidTimeZone } from "./lib/timeZone";
import { jobViewV, nullable } from "./lib/validators";
import { internal } from "./_generated/api";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** A one-time URL for POSTing the original recording. The upload alone grants nothing until attempts.create claims it. */
export const generateUploadUrl = mutation({
  args: {},
  returns: v.string(),
  handler: async (ctx) => {
    await requireLearner(ctx);
    return await ctx.storage.generateUploadUrl();
  },
});

/**
 * Records one uploaded take and queues its assessment. Repeating the call with the same
 * clientAttemptId returns the existing attempt and job.
 */
export const create = mutation({
  args: {
    projectId: v.id("projects"),
    lineId: v.id("referenceLines"),
    clientAttemptId: v.string(),
    storageId: v.id("_storage"),
    durationMs: v.number(),
    capturedAt: v.number(),
    /** IANA zone in force when the take was captured; falls back to the profile zone. */
    timeZone: v.optional(v.string()),
  },
  returns: v.object({ attemptId: v.id("attempts"), jobId: v.id("assessmentJobs") }),
  handler: async (ctx, args) => {
    const user = await requireUser(ctx);
    if (!UUID.test(args.clientAttemptId)) throw appError("INVALID_ARGUMENT", "clientAttemptId must be a UUID");

    const existing = await ctx.db
      .query("attempts")
      .withIndex("by_owner_client", (q) => q.eq("ownerId", user._id).eq("clientAttemptId", args.clientAttemptId))
      .unique();
    if (existing !== null) {
      if (existing.projectId !== args.projectId || existing.lineId !== args.lineId || existing.audioStorageId !== args.storageId) {
        throw appError("CONFLICT", "clientAttemptId was already used for a different recording");
      }
      const job = await ctx.db
        .query("assessmentJobs")
        .withIndex("by_attempt", (q) => q.eq("attemptId", existing._id))
        .first();
      if (job === null) throw appError("INVALID_STATE", "The attempt has no job");
      return { attemptId: existing._id, jobId: job._id };
    }

    const project = await getOwned(ctx, "projects", args.projectId, user);
    if (project === null) throw appError("NOT_FOUND", "That project doesn't exist");
    if (project.status === "completed") throw appError("INVALID_STATE", "The dub is already complete");
    const line = await ctx.db.get("referenceLines", args.lineId);
    if (line === null || line.characterId !== project.characterId || line.sceneId !== project.sceneId) {
      throw appError("INVALID_ARGUMENT", "That line doesn't belong to the project's character");
    }

    const file = await ctx.db.system.get("_storage", args.storageId);
    const claimed = await ctx.db
      .query("attempts")
      .withIndex("by_audio_storage", (q) => q.eq("audioStorageId", args.storageId))
      .first();
    if (file === null || claimed !== null) throw appError("INVALID_UPLOAD", "The upload is missing or already used");
    if (!(ACCEPTED_AUDIO_TYPES as readonly (string | undefined)[]).includes(file.contentType)) {
      throw appError("INVALID_UPLOAD", "Recordings must be audio/wav (16 kHz mono 16-bit PCM)");
    }
    if (file.size <= 0 || file.size > MAX_UPLOAD_BYTES) throw appError("INVALID_UPLOAD", "The recording must be between 1 byte and 10 MB");

    if (!Number.isInteger(args.durationMs) || args.durationMs <= 0 || args.durationMs > MAX_RECORDING_MS) {
      throw appError("INVALID_ARGUMENT", "durationMs must be a whole number of milliseconds up to 30000");
    }
    const now = Date.now();
    if (!Number.isFinite(args.capturedAt) || args.capturedAt > now + CAPTURED_AT_FUTURE_SKEW_MS || args.capturedAt < now - CAPTURED_AT_MAX_AGE_MS) {
      throw appError("INVALID_ARGUMENT", "capturedAt isn't a plausible capture time");
    }
    const timeZone = args.timeZone ?? user.timeZone;
    if (timeZone === undefined || !isValidTimeZone(timeZone)) {
      throw appError("INVALID_ARGUMENT", "Send a valid IANA timeZone, or set one with users.setTimeZone");
    }

    const attemptId = await ctx.db.insert("attempts", {
      ownerId: user._id,
      projectId: project._id,
      lineId: line._id,
      clientAttemptId: args.clientAttemptId,
      audioStorageId: args.storageId,
      contentType: file.contentType as string,
      byteSize: file.size,
      durationMs: args.durationMs,
      capturedAt: args.capturedAt,
      receivedAt: now,
      timeZone,
    });
    const jobId = await ctx.db.insert("assessmentJobs", {
      ownerId: user._id,
      attemptId,
      kind: "initial",
      status: "queued",
      stage: "measure",
      tries: 0,
      createdAt: now,
      updatedAt: now,
    });
    await ctx.db.patch(project._id, { updatedAt: now });
    await ctx.scheduler.runAfter(0, internal.assessments.run, { jobId });
    logEvent({ operation: "attempts.create", status: "ok", userId: user._id, projectId: project._id, attemptId, jobId });
    return { attemptId, jobId };
  },
});

/** Every take of one line, newest first, with its job state and latest result. */
export const listForLine = query({
  args: { projectId: v.id("projects"), lineId: v.id("referenceLines") },
  returns: nullable(
    v.array(
      v.object({
        attemptId: v.id("attempts"),
        clientAttemptId: v.string(),
        durationMs: v.number(),
        capturedAt: v.number(),
        receivedAt: v.number(),
        accepted: v.boolean(),
        job: nullable(jobViewV),
        assessment: nullable(
          v.object({
            assessmentId: v.id("assessments"),
            status: v.union(v.literal("scored"), v.literal("unscorable")),
            languageOverall: nullable(v.number()),
          }),
        ),
      }),
    ),
  ),
  handler: async (ctx, { projectId, lineId }) => {
    const user = await requireUser(ctx);
    const project = await getOwned(ctx, "projects", projectId, user);
    if (project === null) return null;
    const attempts = await ctx.db
      .query("attempts")
      .withIndex("by_project_line", (q) => q.eq("projectId", projectId).eq("lineId", lineId))
      .order("desc")
      .collect();
    const take = await ctx.db
      .query("acceptedTakes")
      .withIndex("by_project_line", (q) => q.eq("projectId", projectId).eq("lineId", lineId))
      .unique();
    return await Promise.all(
      attempts.map(async (attempt) => {
        const job = await ctx.db.query("assessmentJobs").withIndex("by_attempt", (q) => q.eq("attemptId", attempt._id)).order("desc").first();
        const assessment = await ctx.db.query("assessments").withIndex("by_attempt", (q) => q.eq("attemptId", attempt._id)).order("desc").first();
        return {
          attemptId: attempt._id,
          clientAttemptId: attempt.clientAttemptId,
          durationMs: attempt.durationMs,
          capturedAt: attempt.capturedAt,
          receivedAt: attempt.receivedAt,
          accepted: take?.attemptId === attempt._id,
          job: job === null ? null : {
            jobId: job._id,
            kind: job.kind,
            status: job.status,
            stage: job.stage,
            tries: job.tries,
            error: job.error ?? null,
            assessmentId: job.assessmentId ?? null,
            updatedAt: job.updatedAt,
          },
          assessment: assessment === null ? null : {
            assessmentId: assessment._id,
            status: assessment.status,
            languageOverall: assessment.scores?.languageOverall ?? null,
          },
        };
      }),
    );
  },
});
