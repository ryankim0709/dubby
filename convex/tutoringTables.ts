import { defineSchema, defineTable, type DataModelFromSchemaDefinition } from "convex/server";
import { v } from "convex/values";

// Backend adds this to its schema: defineSchema({ ...backendTables, ...tutoringTables }).
// Every row carries the authenticated learner's subject and every index starts with it, so a query can't read across learners.

export const tutoringTables = {
  /** One row per ingested assessment: a read model for progress. Backend's attempt and assessment tables stay authoritative. */
  tutoringAssessments: defineTable({
    subject: v.string(),
    assessmentId: v.string(),
    attemptId: v.string(),
    payloadHash: v.string(),
    /** The validated TutoringRecord; parsed again with its zod schema on every read. */
    record: v.any(),
  })
    .index("by_subject_assessment", ["subject", "assessmentId"])
    .index("by_subject_attempt", ["subject", "attemptId"]),

  tutoringPreferences: defineTable({
    subject: v.string(),
    /** Starts at 1 and rises on every save, so a stale writer can be detected. */
    version: v.number(),
    preferences: v.any(),
    updatedAt: v.number(),
  }).index("by_subject", ["subject"]),

  /** The desired state of each derived memory document, drained to Supermemory with bounded retries. */
  tutoringMemoryOutbox: defineTable({
    subject: v.string(),
    docId: v.string(),
    op: v.union(v.literal("upsert"), v.literal("delete")),
    /** Changes whenever the document's content or backing records change; "delete" for a delete. */
    contentHash: v.string(),
    document: v.optional(v.any()),
    state: v.union(v.literal("pending"), v.literal("done"), v.literal("failed")),
    attempts: v.number(),
    nextAttemptAt: v.number(),
    lastError: v.optional(v.string()),
    updatedAt: v.number(),
  })
    .index("by_subject_doc", ["subject", "docId"])
    .index("by_state_due", ["state", "nextAttemptAt"]),
};

/** The data model of the tutoring tables alone; tutoring functions are typed against it, whatever else the deployment's schema holds. */
export type TutoringDataModel = DataModelFromSchemaDefinition<ReturnType<typeof tutoringSchema>>;
const tutoringSchema = () => defineSchema(tutoringTables);
