import {
  actionGeneric,
  internalActionGeneric,
  internalMutationGeneric as untypedInternalMutation,
  internalQueryGeneric as untypedInternalQuery,
  mutationGeneric as untypedMutation,
  queryGeneric as untypedQuery,
  type GenericMutationCtx,
  type GenericQueryCtx,
  type MutationBuilder,
  type QueryBuilder,
} from "convex/server";
import { ConvexError, v } from "convex/values";
import { ConfigurationError, requiredEnv } from "./lib/env";
import { requireLearner } from "./lib/auth";
import { selectNextExercise } from "./tutoringExercise";
import {
  createMemoryStore,
  deriveMemoryDocuments,
  documentHash,
  learnerNamespace,
  outboxOutcomeAfterFailure,
  sha256Hex,
  type OutboxOutcome,
} from "./tutoringMemory";
import { defaultPreferences, learnerPreferences, type LearnerPreferences } from "./tutoringPreferences";
import { buildTutoringReport, type TutoringReport } from "./tutoringProgress";
import { dubbingSessionResults, recordsForSession, tutoringRecord, type IngestIssue, type TutoringRecord } from "./tutoringRecords";
import { tutoringRefs } from "./tutoringRefs";
import { buildEvidencePack } from "./tutoringReply";

import type { TutoringDataModel } from "./tutoringTables";

type QueryCtx = GenericQueryCtx<TutoringDataModel>;
type MutationCtx = GenericMutationCtx<TutoringDataModel>;

// The generic builders are typed against the tutoring tables, so index names and fields are checked.
const queryGeneric = untypedQuery as unknown as QueryBuilder<TutoringDataModel, "public">;
const internalQueryGeneric = untypedInternalQuery as unknown as QueryBuilder<TutoringDataModel, "internal">;
const mutationGeneric = untypedMutation as unknown as MutationBuilder<TutoringDataModel, "public">;
const internalMutationGeneric = untypedInternalMutation as unknown as MutationBuilder<TutoringDataModel, "internal">;

const outboxBatchSize = 25;

// ---- Storage helpers ---------------------------------------------------------------------------------------

async function loadRecords(ctx: QueryCtx, subject: string): Promise<TutoringRecord[]> {
  const rows = await ctx.db
    .query("tutoringAssessments")
    .withIndex("by_subject_assessment", (q) => q.eq("subject", subject))
    .collect();
  return rows.map((row) => tutoringRecord.parse(row.record));
}

async function loadPreferences(ctx: QueryCtx, subject: string): Promise<{ preferences: LearnerPreferences; version: number }> {
  const row = await ctx.db
    .query("tutoringPreferences")
    .withIndex("by_subject", (q) => q.eq("subject", subject))
    .unique();
  if (row === null) return { preferences: defaultPreferences, version: 0 };
  return { preferences: learnerPreferences.parse(row.preferences), version: row.version as number };
}

/**
 * Brings the memory outbox in line with what should exist for this learner: new or changed documents are
 * queued for upsert, documents whose source is gone (or whose learner turned memory off) for deletion.
 * Convex is the source of truth, so the desired set is always re-derived from the stored records.
 */
async function reconcileMemory(ctx: MutationCtx, subject: string): Promise<void> {
  const records = await loadRecords(ctx, subject);
  const { preferences, version } = await loadPreferences(ctx, subject);
  const report = buildTutoringReport(records, [], new Date(0).toISOString());
  const desired =
    preferences.memory === "off" ? [] : await deriveMemoryDocuments(records, report, version === 0 ? null : preferences);
  const rows = await ctx.db
    .query("tutoringMemoryOutbox")
    .withIndex("by_subject_doc", (q) => q.eq("subject", subject))
    .collect();
  const rowById = new Map(rows.map((row) => [row.docId as string, row]));
  const now = Date.now();
  let queued = false;
  for (const document of desired) {
    const contentHash = await documentHash(document);
    const row = rowById.get(document.id);
    if (row?.op === "upsert" && row.contentHash === contentHash) continue;
    const next = { op: "upsert" as const, contentHash, document, state: "pending" as const, attempts: 0, nextAttemptAt: now, lastError: undefined, updatedAt: now };
    if (row === undefined) await ctx.db.insert("tutoringMemoryOutbox", { subject, docId: document.id, ...next });
    else await ctx.db.patch(row._id, next);
    queued = true;
  }
  const desiredIds = new Set(desired.map((document) => document.id));
  for (const row of rows) {
    if (desiredIds.has(row.docId as string) || row.op === "delete") continue;
    await ctx.db.patch(row._id, { op: "delete", contentHash: "delete", document: undefined, state: "pending", attempts: 0, nextAttemptAt: now, lastError: undefined, updatedAt: now });
    queued = true;
  }
  if (queued) await ctx.scheduler.runAfter(0, tutoringRefs.drainMemoryOutbox, {});
}

// ---- Ingestion (called by Backend after it persists an assessment) ---------------------------------------

export type IngestOutcome = "inserted" | "duplicate" | "conflict";
export type IngestResult =
  | { outcome: "rejected"; issues: IngestIssue[] }
  | { outcome: "ok"; results: { assessmentId: string; outcome: IngestOutcome }[] };

async function ingestSession(ctx: MutationCtx, subject: string, input: unknown): Promise<IngestResult> {
  const session = dubbingSessionResults.safeParse(input);
  if (!session.success) {
    return { outcome: "rejected", issues: session.error.issues.map((issue) => ({ path: issue.path.join("."), message: issue.message })) };
  }
  const built = recordsForSession(session.data, new Date().toISOString());
  if (!built.ok) return { outcome: "rejected", issues: built.issues };
  const results: { assessmentId: string; outcome: IngestOutcome }[] = [];
  for (const record of built.records) {
    const { assessmentId, attemptId } = record.assessment;
    // ingestedAt differs on every retry, so the identity of a payload excludes it.
    const payloadHash = await sha256Hex(JSON.stringify({ ...record, ingestedAt: null }));
    const existing = await ctx.db
      .query("tutoringAssessments")
      .withIndex("by_subject_assessment", (q) => q.eq("subject", subject).eq("assessmentId", assessmentId))
      .unique();
    if (existing !== null) {
      results.push({ assessmentId, outcome: existing.payloadHash === payloadHash ? "duplicate" : "conflict" });
      continue;
    }
    // A regrade keeps its attempt's line, reference revision and locale; anything else is a different attempt.
    const siblings = await ctx.db
      .query("tutoringAssessments")
      .withIndex("by_subject_attempt", (q) => q.eq("subject", subject).eq("attemptId", attemptId))
      .collect();
    const mismatched = siblings.some((row) => {
      const other = tutoringRecord.parse(row.record).assessment;
      return other.lineId !== record.assessment.lineId || other.referenceVersion !== record.assessment.referenceVersion || other.locale !== record.assessment.locale;
    });
    if (mismatched) {
      results.push({ assessmentId, outcome: "conflict" });
      continue;
    }
    await ctx.db.insert("tutoringAssessments", { subject, assessmentId, attemptId, payloadHash, record });
    results.push({ assessmentId, outcome: "inserted" });
  }
  if (results.some((result) => result.outcome === "inserted")) await reconcileMemory(ctx, subject);
  return { outcome: "ok", results };
}

/**
 * One assessment, as Backend schedules it right after storing the assessment: Backend's own payload, whose
 * attempt block carries the owner (taken from the verified user row, never from a client). Idempotent by
 * (subject, assessmentId). The project stands in for the dubbing session.
 */
export const ingestAssessment = internalMutationGeneric({
  args: { assessment: v.any(), attempt: v.any(), provenance: v.any() },
  handler: async (ctx, args): Promise<IngestResult> => {
    const attempt = (typeof args.attempt === "object" && args.attempt !== null ? args.attempt : {}) as Record<string, unknown>;
    const { ownerSubject, projectId, speakingDurationMs, recordingDurationMs, sceneId, characterId, timeZone } = attempt;
    if (typeof ownerSubject !== "string" || ownerSubject.length === 0) {
      return { outcome: "rejected", issues: [{ path: "attempt.ownerSubject", message: "the owner is required" }] };
    }
    return ingestSession(ctx, ownerSubject, {
      sessionId: projectId,
      sceneId,
      characterId,
      timeZone,
      evaluator: args.provenance,
      assessments: [{ assessment: args.assessment, speakingDurationMs, recordingDurationMs }],
    });
  },
});

/** A whole dubbing session at once, for callers that grade several lines together. */
export const ingestDubbingSession = internalMutationGeneric({
  args: { subject: v.string(), session: v.any() },
  handler: async (ctx, args): Promise<IngestResult> => ingestSession(ctx, args.subject, args.session),
});

// ---- Deletion hooks (Backend calls these when it deletes source rows) -------------------------------------

export const removeAssessment = internalMutationGeneric({
  args: { subject: v.string(), assessmentId: v.string() },
  handler: async (ctx, { subject, assessmentId }): Promise<{ removed: number }> => {
    const rows = await ctx.db
      .query("tutoringAssessments")
      .withIndex("by_subject_assessment", (q) => q.eq("subject", subject).eq("assessmentId", assessmentId))
      .collect();
    for (const row of rows) await ctx.db.delete(row._id);
    if (rows.length > 0) await reconcileMemory(ctx, subject);
    return { removed: rows.length };
  },
});

export const removeAttempt = internalMutationGeneric({
  args: { subject: v.string(), attemptId: v.string() },
  handler: async (ctx, { subject, attemptId }): Promise<{ removed: number }> => {
    const rows = await ctx.db
      .query("tutoringAssessments")
      .withIndex("by_subject_attempt", (q) => q.eq("subject", subject).eq("attemptId", attemptId))
      .collect();
    for (const row of rows) await ctx.db.delete(row._id);
    if (rows.length > 0) await reconcileMemory(ctx, subject);
    return { removed: rows.length };
  },
});

/** Account deletion: removes the learner's records and preferences and queues deletion of every memory document. */
export const removeLearner = internalMutationGeneric({
  args: { subject: v.string() },
  handler: async (ctx, { subject }): Promise<{ removed: number }> => {
    const assessments = await ctx.db
      .query("tutoringAssessments")
      .withIndex("by_subject_assessment", (q) => q.eq("subject", subject))
      .collect();
    for (const row of assessments) await ctx.db.delete(row._id);
    const preferences = await ctx.db
      .query("tutoringPreferences")
      .withIndex("by_subject", (q) => q.eq("subject", subject))
      .collect();
    for (const row of preferences) await ctx.db.delete(row._id);
    await reconcileMemory(ctx, subject);
    return { removed: assessments.length };
  },
});

// ---- Learner-facing functions: identity comes only from ctx.auth ------------------------------------------

async function reportFor(ctx: QueryCtx, subject: string): Promise<TutoringReport> {
  return buildTutoringReport(await loadRecords(ctx, subject), [], new Date().toISOString());
}

export const progress = queryGeneric({
  args: { locale: v.optional(v.string()) },
  handler: async (ctx, { locale }): Promise<TutoringReport> => {
    const { subject } = await requireLearner(ctx);
    const report = await reportFor(ctx, subject);
    return locale === undefined ? report : { ...report, series: report.series.filter((series) => series.locale === locale) };
  },
});

export const nextExercise = queryGeneric({
  args: { locale: v.optional(v.string()) },
  handler: async (ctx, { locale }) => {
    const { subject } = await requireLearner(ctx);
    const { preferences } = await loadPreferences(ctx, subject);
    return selectNextExercise(await reportFor(ctx, subject), preferences, locale);
  },
});

/** What a coach reply may talk about: the evidence pack for this learner, without memory notes. */
export const replyContext = queryGeneric({
  args: { locale: v.optional(v.string()) },
  handler: async (ctx, { locale }) => {
    const { subject } = await requireLearner(ctx);
    const { preferences } = await loadPreferences(ctx, subject);
    const report = await reportFor(ctx, subject);
    const pack = buildEvidencePack(report, selectNextExercise(report, preferences, locale));
    return { pack, memory: preferences.memory };
  },
});

export const getPreferences = queryGeneric({
  args: {},
  handler: async (ctx) => loadPreferences(ctx, (await requireLearner(ctx)).subject),
});

export const setPreferences = mutationGeneric({
  args: { preferences: v.any(), expectedVersion: v.number() },
  handler: async (ctx, args): Promise<{ preferences: LearnerPreferences; version: number }> => {
    const { subject } = await requireLearner(ctx);
    const parsed = learnerPreferences.safeParse(args.preferences);
    if (!parsed.success) throw new ConvexError({ code: "invalid_request", message: parsed.error.message });
    const row = await ctx.db
      .query("tutoringPreferences")
      .withIndex("by_subject", (q) => q.eq("subject", subject))
      .unique();
    const current = row === null ? 0 : (row.version as number);
    if (current !== args.expectedVersion) {
      throw new ConvexError({ code: "version_conflict", message: `Preferences are at version ${current}, not ${args.expectedVersion}` });
    }
    const next = { version: current + 1, preferences: parsed.data, updatedAt: Date.now() };
    if (row === null) await ctx.db.insert("tutoringPreferences", { subject, ...next });
    else await ctx.db.patch(row._id, next);
    await reconcileMemory(ctx, subject);
    return { preferences: parsed.data, version: next.version };
  },
});

export const memoryStatus = queryGeneric({
  args: {},
  handler: async (ctx): Promise<{ pending: number; failed: number; done: number }> => {
    const { subject } = await requireLearner(ctx);
    const rows = await ctx.db
      .query("tutoringMemoryOutbox")
      .withIndex("by_subject_doc", (q) => q.eq("subject", subject))
      .collect();
    const count = (state: string) => rows.filter((row) => row.state === state).length;
    return { pending: count("pending"), failed: count("failed"), done: count("done") };
  },
});

export type MemoryItem = {
  docId: string;
  kind: "preference" | "attempt_note" | "dub_note" | "trend" | "difficulty";
  text: string;
  /** The Convex attempt or assessment IDs this note was derived from; empty for preferences. */
  sourceIds: string[];
  /** "pending" and "failed" mean Supermemory doesn't hold this note (yet); "done" means it does. */
  state: "pending" | "done" | "failed";
};

const itemKind = { preferences: "preference", attempt: "attempt_note", dub: "dub_note", trend: "trend", difficulty: "difficulty" } as const;

/** What the tutor remembers about the caller, served from Convex's outbox rather than from a Supermemory read. */
export const memoryItems = queryGeneric({
  args: {},
  handler: async (ctx): Promise<MemoryItem[]> => {
    const { subject } = await requireLearner(ctx);
    const rows = await ctx.db
      .query("tutoringMemoryOutbox")
      .withIndex("by_subject_doc", (q) => q.eq("subject", subject))
      .collect();
    return rows
      .flatMap((row) => {
        if (row.op !== "upsert" || row.document === undefined) return [];
        const document = row.document as { kind: keyof typeof itemKind; content: string; metadata: Record<string, string | string[]> };
        const ids = [document.metadata.attemptId, document.metadata.assessmentId, document.metadata.attemptIds].flat().filter((id): id is string => typeof id === "string");
        return [{ docId: row.docId as string, kind: itemKind[document.kind], text: document.content, sourceIds: [...new Set(ids)].sort(), state: row.state as MemoryItem["state"] }];
      })
      .sort((a, b) => (a.docId < b.docId ? -1 : 1));
  },
});

/** Turns memory off and queues deletion of every derived document. Practice history in Convex is untouched. */
export const forgetMemory = mutationGeneric({
  args: {},
  handler: async (ctx): Promise<{ scheduled: number }> => {
    const { subject } = await requireLearner(ctx);
    const row = await ctx.db
      .query("tutoringPreferences")
      .withIndex("by_subject", (q) => q.eq("subject", subject))
      .unique();
    const preferences = learnerPreferences.parse({ ...(row === null ? {} : (row.preferences as object)), memory: "off" });
    const next = { version: (row === null ? 0 : (row.version as number)) + 1, preferences, updatedAt: Date.now() };
    if (row === null) await ctx.db.insert("tutoringPreferences", { subject, ...next });
    else await ctx.db.patch(row._id, next);
    await reconcileMemory(ctx, subject);
    const rows = await ctx.db
      .query("tutoringMemoryOutbox")
      .withIndex("by_subject_doc", (q) => q.eq("subject", subject))
      .collect();
    return { scheduled: rows.filter((outbox) => outbox.op === "delete" && outbox.state === "pending").length };
  },
});

// ---- Memory outbox drain -----------------------------------------------------------------------------------

export const dueOutbox = internalQueryGeneric({
  args: { now: v.number() },
  handler: async (ctx, { now }) =>
    ctx.db
      .query("tutoringMemoryOutbox")
      .withIndex("by_state_due", (q) => q.eq("state", "pending").lte("nextAttemptAt", now))
      .take(outboxBatchSize),
});

const outcomeValidator = v.union(
  v.object({ state: v.literal("done") }),
  v.object({ state: v.literal("pending"), attempts: v.number(), nextAttemptAt: v.number() }),
  v.object({ state: v.literal("failed"), attempts: v.number() }),
);

/**
 * Records one send. If the row changed while the call was in flight (a newer desired state), the result is
 * dropped and the row stays pending, so a stale success can never mark newer content as delivered.
 */
export const recordOutboxResult = internalMutationGeneric({
  args: { id: v.id("tutoringMemoryOutbox"), expectedHash: v.string(), outcome: outcomeValidator, error: v.optional(v.string()) },
  handler: async (ctx, args): Promise<void> => {
    const row = await ctx.db.get(args.id);
    if (row === null || row.contentHash !== args.expectedHash) return;
    const outcome = args.outcome as OutboxOutcome;
    const now = Date.now();
    if (outcome.state === "done") {
      await ctx.db.patch(row._id, { state: "done", lastError: undefined, updatedAt: now });
      return;
    }
    await ctx.db.patch(row._id, { ...outcome, lastError: args.error, updatedAt: now });
    if (outcome.state === "pending") await ctx.scheduler.runAfter(Math.max(0, outcome.nextAttemptAt - now), tutoringRefs.drainMemoryOutbox, {});
  },
});

/** Operator hook: gives failed documents a fresh set of attempts, for example after a Supermemory outage. */
export const retryFailedMemory = internalMutationGeneric({
  args: {},
  handler: async (ctx): Promise<{ retried: number }> => {
    const failed = await ctx.db
      .query("tutoringMemoryOutbox")
      .withIndex("by_state_due", (q) => q.eq("state", "failed"))
      .collect();
    for (const row of failed) await ctx.db.patch(row._id, { state: "pending", attempts: 0, nextAttemptAt: Date.now(), updatedAt: Date.now() });
    if (failed.length > 0) await ctx.scheduler.runAfter(0, tutoringRefs.drainMemoryOutbox, {});
    return { retried: failed.length };
  },
});

export const drainMemoryOutbox = internalActionGeneric({
  args: {},
  handler: async (ctx): Promise<{ sent: number; failed: number }> => {
    const now = Date.now();
    const due: { _id: string; subject: string; docId: string; op: "upsert" | "delete"; contentHash: string; attempts: number; document?: unknown }[] =
      await ctx.runQuery(tutoringRefs.dueOutbox, { now });
    if (due.length === 0) return { sent: 0, failed: 0 };
    let store;
    let secret: string;
    try {
      store = createMemoryStore();
      secret = requiredEnv("TUTOR_MEMORY_NAMESPACE_SECRET");
    } catch (error) {
      if (!(error instanceof ConfigurationError)) throw error;
      // Not a delivery failure: the rows stay pending until the deployment has its keys.
      console.warn("learner memory isn't configured; documents stay queued", { error: error.message });
      return { sent: 0, failed: 0 };
    }
    let sent = 0;
    let failed = 0;
    for (const row of due) {
      let outcome: OutboxOutcome = { state: "done" };
      let message: string | undefined;
      try {
        const namespace = await learnerNamespace(row.subject, secret);
        if (row.op === "delete") await store.remove(namespace, [row.docId]);
        else await store.upsert(namespace, row.document as Parameters<typeof store.upsert>[1]);
        sent += 1;
      } catch (error) {
        outcome = outboxOutcomeAfterFailure(row.attempts, error, Date.now());
        // Provider error text carries no learner content or credentials, but it is capped anyway.
        message = String(error instanceof Error ? error.message : error).slice(0, 300);
        console.warn("learner memory delivery failed", { docId: row.docId, attempts: row.attempts + 1, outcome: outcome.state, error: message });
        failed += 1;
      }
      await ctx.runMutation(tutoringRefs.recordOutboxResult, { id: row._id, expectedHash: row.contentHash, outcome, error: message });
    }
    // A full batch can leave due rows behind (a new dub can queue more than one batch of notes), so keep going.
    if (due.length === outboxBatchSize) await ctx.scheduler.runAfter(0, tutoringRefs.drainMemoryOutbox, {});
    return { sent, failed };
  },
});

/** Memory snippets relevant to a learner's chat turn, or none when memory is off, unconfigured, or failing. */
export const searchMemory = actionGeneric({
  args: { query: v.string() },
  handler: async (ctx, { query }): Promise<string[]> => {
    const { subject } = await requireLearner(ctx);
    try {
      const namespace = await learnerNamespace(subject, requiredEnv("TUTOR_MEMORY_NAMESPACE_SECRET"));
      return await createMemoryStore().search(namespace, query.slice(0, 500), 3);
    } catch (error) {
      console.warn("learner memory search unavailable, replying without it", { error: String(error instanceof Error ? error.message : error) });
      return [];
    }
  },
});
