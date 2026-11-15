import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";
import { tutoringTables } from "./tutoringTables";
import { assessmentContentFields, jobErrorV, jobStageV, jobStatusV, outcomeV } from "./lib/validators";

/** Tables follow docs/convex-backend.md and contract v1 section 4. Ids are Convex ids; times are epoch milliseconds. */
export default defineSchema({
  ...tutoringTables,

  users: defineTable({
    tokenIdentifier: v.string(),
    timeZone: v.optional(v.string()),
    createdAt: v.number(),
  }).index("by_token_identifier", ["tokenIdentifier"]),

  scenes: defineTable({
    slug: v.string(),
    title: v.string(),
    synopsis: v.optional(v.string()),
    locale: v.string(),
    durationSeconds: v.number(),
    published: v.boolean(),
    /** The scene manifest's provenance object, stored as supplied. */
    provenance: v.any(),
    /** The scene's video in Convex file storage; `_storage` holds its SHA-256, size, and content type. */
    videoId: v.optional(v.id("_storage")),
  })
    .index("by_slug", ["slug"])
    .index("by_published", ["published"]),

  characters: defineTable({
    sceneId: v.id("scenes"),
    slug: v.string(),
    name: v.string(),
  })
    .index("by_scene", ["sceneId"])
    .index("by_scene_slug", ["sceneId", "slug"]),

  /** Immutable: a text or timing change inserts a new row with the next referenceVersion. */
  referenceLines: defineTable({
    sceneId: v.id("scenes"),
    characterId: v.id("characters"),
    lineKey: v.string(),
    order: v.number(),
    text: v.string(),
    startSeconds: v.number(),
    endSeconds: v.number(),
    locale: v.string(),
    referenceVersion: v.number(),
  })
    .index("by_scene_line_key", ["sceneId", "lineKey", "referenceVersion"])
    .index("by_character", ["characterId", "order"]),

  projects: defineTable({
    ownerId: v.id("users"),
    sceneId: v.id("scenes"),
    characterId: v.id("characters"),
    status: v.union(v.literal("active"), v.literal("completed")),
    createdAt: v.number(),
    updatedAt: v.number(),
    completedAt: v.optional(v.number()),
    exportStorageId: v.optional(v.id("_storage")),
  })
    .index("by_owner_updated", ["ownerId", "updatedAt"])
    .index("by_owner_scene_character", ["ownerId", "sceneId", "characterId", "status"]),

  /** Immutable. The audio storage id is claimed by exactly one attempt. */
  attempts: defineTable({
    ownerId: v.id("users"),
    projectId: v.id("projects"),
    lineId: v.id("referenceLines"),
    clientAttemptId: v.string(),
    audioStorageId: v.id("_storage"),
    contentType: v.string(),
    byteSize: v.number(),
    durationMs: v.number(),
    capturedAt: v.number(),
    receivedAt: v.number(),
    timeZone: v.string(),
  })
    .index("by_owner_client", ["ownerId", "clientAttemptId"])
    .index("by_audio_storage", ["audioStorageId"])
    .index("by_project_line", ["projectId", "lineId", "receivedAt"]),

  acceptedTakes: defineTable({
    ownerId: v.id("users"),
    projectId: v.id("projects"),
    lineId: v.id("referenceLines"),
    attemptId: v.id("attempts"),
    acceptedAt: v.number(),
  })
    .index("by_project_line", ["projectId", "lineId"])
    .index("by_project", ["projectId"]),

  assessmentJobs: defineTable({
    ownerId: v.id("users"),
    attemptId: v.id("attempts"),
    kind: v.union(v.literal("initial"), v.literal("reassessment")),
    status: jobStatusV,
    stage: jobStageV,
    tries: v.number(),
    leaseExpiresAt: v.optional(v.number()),
    error: v.optional(jobErrorV),
    /** The validated engine output, kept so a coaching retry never re-spends the engine. */
    outcome: v.optional(outcomeV),
    assessmentId: v.optional(v.id("assessments")),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_attempt", ["attemptId"])
    .index("by_status_lease", ["status", "leaseExpiresAt"]),

  /** Immutable, one per successful job. The latest per attempt is the applicable one. */
  assessments: defineTable({
    ownerId: v.id("users"),
    ...assessmentContentFields,
  })
    .index("by_attempt", ["attemptId"])
    .index("by_job", ["jobId"]),
});
