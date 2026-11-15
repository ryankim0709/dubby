import { makeFunctionReference } from "convex/server";
import type { IngestResult, MemoryItem } from "./tutoring";
import type { NextExercise } from "./tutoringExercise";
import type { LearnerPreferences } from "./tutoringPreferences";
import type { TutoringReport } from "./tutoringProgress";
import type { EvidencePack } from "./tutoringReply";

/** Typed handles to the tutoring functions, so other modules can call them without Convex codegen. */
export const tutoringRefs = {
  // Called by Convex Backend.
  ingestAssessment: makeFunctionReference<"mutation", { assessment: unknown; attempt: unknown; provenance: unknown }, IngestResult>("tutoring:ingestAssessment"),
  ingestDubbingSession: makeFunctionReference<"mutation", { subject: string; session: unknown }, IngestResult>("tutoring:ingestDubbingSession"),
  removeAssessment: makeFunctionReference<"mutation", { subject: string; assessmentId: string }, { removed: number }>("tutoring:removeAssessment"),
  removeAttempt: makeFunctionReference<"mutation", { subject: string; attemptId: string }, { removed: number }>("tutoring:removeAttempt"),
  removeLearner: makeFunctionReference<"mutation", { subject: string }, { removed: number }>("tutoring:removeLearner"),
  // Called by the HTTP routes with the caller's auth.
  progress: makeFunctionReference<"query", { locale?: string }, TutoringReport>("tutoring:progress"),
  nextExercise: makeFunctionReference<"query", { locale?: string }, NextExercise>("tutoring:nextExercise"),
  replyContext: makeFunctionReference<"query", { locale?: string }, { pack: EvidencePack; memory: "on" | "off" }>("tutoring:replyContext"),
  getPreferences: makeFunctionReference<"query", Record<string, never>, { preferences: LearnerPreferences; version: number }>("tutoring:getPreferences"),
  setPreferences: makeFunctionReference<"mutation", { preferences: unknown; expectedVersion: number }, { preferences: LearnerPreferences; version: number }>("tutoring:setPreferences"),
  memoryItems: makeFunctionReference<"query", Record<string, never>, MemoryItem[]>("tutoring:memoryItems"),
  memoryStatus: makeFunctionReference<"query", Record<string, never>, { pending: number; failed: number; done: number }>("tutoring:memoryStatus"),
  forgetMemory: makeFunctionReference<"mutation", Record<string, never>, { scheduled: number }>("tutoring:forgetMemory"),
  searchMemory: makeFunctionReference<"action", { query: string }, string[]>("tutoring:searchMemory"),
  // Internal plumbing for the memory outbox.
  dueOutbox: makeFunctionReference<"query", { now: number }, never[]>("tutoring:dueOutbox"),
  recordOutboxResult: makeFunctionReference<"mutation", { id: string; expectedHash: string; outcome: unknown; error?: string }, null>("tutoring:recordOutboxResult"),
  retryFailedMemory: makeFunctionReference<"mutation", Record<string, never>, { retried: number }>("tutoring:retryFailedMemory"),
  drainMemoryOutbox: makeFunctionReference<"action", Record<string, never>, { sent: number; failed: number }>("tutoring:drainMemoryOutbox"),
};
