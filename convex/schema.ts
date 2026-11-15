import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";
import { tutoringTables } from "./tutoringTables";
import { assessmentContentFields, dubLineResultV, dubTakeStatusV, jobErrorV, jobStageV, jobStatusV, outcomeV } from "./lib/validators";
import { castCharacterV, castSegmentV } from "./lib/sceneCast";
import { timedWordV } from "./lib/transcription";

/** Tables follow docs/convex-backend.md and contract v1 section 4. Ids are Convex ids; times are epoch milliseconds. */
export default defineSchema({
  ...tutoringTables,

  /** Landing-page signups. Emails are stored lowercased, so `by_email` finds repeat signups. */
  waitlist: defineTable({
    email: v.string(),
    plan: v.union(v.literal("free"), v.literal("founding")),
    language: v.optional(v.string()),
    source: v.optional(v.string()),
    /** Set by the Whop payment.succeeded webhook once the founding price is paid. */
    paidAt: v.optional(v.number()),
    whopPaymentId: v.optional(v.string()),
    createdAt: v.number(),
    updatedAt: v.number(),
  }).index("by_email", ["email"]),

  users: defineTable({
    tokenIdentifier: v.string(),
    timeZone: v.optional(v.string()),
    createdAt: v.number(),
  }).index("by_token_identifier", ["tokenIdentifier"]),

  clubMembers: defineTable({
    ownerId: v.id("users"),
    whopUserId: v.string(),
    displayName: v.string(),
  }).index("by_owner", ["ownerId"]),

  clubUploads: defineTable({
    ownerId: v.id("users"),
    requestId: v.string(),
    fileId: v.string(),
    kind: v.union(v.literal("video"), v.literal("voice")),
    byteSize: v.number(),
    createdAt: v.number(),
    caption: v.optional(v.string()),
    replyToMessageId: v.optional(v.union(v.string(), v.null())),
    messageId: v.optional(v.string()),
  }).index("by_owner_request", ["ownerId", "requestId"]),

  premiumCheckouts: defineTable({
    ownerId: v.id("users"),
    planId: v.string(),
    createdAt: v.number(),
  }),

  premiumMemberships: defineTable({
    ownerId: v.id("users"),
    checkoutId: v.id("premiumCheckouts"),
    membershipId: v.string(),
    active: v.boolean(),
    expiresAt: v.union(v.number(), v.null()),
    updatedAt: v.number(),
  })
    .index("by_owner", ["ownerId"])
    .index("by_membership", ["membershipId"]),

  /** Username and password logins (passwordAuth.ts). A users row links to one through its token's subject, the account id. */
  passwordAccounts: defineTable({
    username: v.string(),
    passwordHash: v.string(),
    createdAt: v.number(),
  }).index("by_username", ["username"]),

  /** A finished dub sent for scoring (dubs.ts). Keys are derived on the server; see docs/grading-contract.md. */
  dubs: defineTable({
    ownerId: v.id("users"),
    clientDubId: v.string(),
    sceneKey: v.string(),
    sceneTitle: v.string(),
    characterKey: v.string(),
    characterName: v.string(),
    locale: v.string(),
    timeZone: v.string(),
    capturedAt: v.number(),
    createdAt: v.number(),
    status: v.union(v.literal("scoring"), v.literal("complete")),
    completedAt: v.optional(v.number()),
  }).index("by_owner_client", ["ownerId", "clientDubId"]),

  /** One recorded line of a dub and its grade. */
  dubTakes: defineTable({
    dubId: v.id("dubs"),
    ownerId: v.id("users"),
    lineIndex: v.number(),
    lineKey: v.string(),
    referenceText: v.string(),
    windowStartMs: v.number(),
    windowEndMs: v.number(),
    storageId: v.id("_storage"),
    status: dubTakeStatusV,
    result: v.optional(dubLineResultV),
    failure: v.optional(v.object({ code: v.string(), message: v.string() })),
  })
    .index("by_dub", ["dubId"])
    .index("by_storage", ["storageId"]),

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

  /** Shared script timing for a published video, independent of any learner's recordings. */
  sceneTranscripts: defineTable({
    videoId: v.id("_storage"),
    locale: v.string(),
    status: v.union(v.literal("processing"), v.literal("ready"), v.literal("failed")),
    leaseId: v.string(),
    leaseExpiresAt: v.number(),
    durationSeconds: v.optional(v.number()),
    words: v.optional(v.array(timedWordV)),
  }).index("by_video_locale", ["videoId", "locale"]),

  /** Who speaks when in a published video, and each character's name and best frame, shared by every learner. */
  sceneCasts: defineTable({
    videoId: v.id("_storage"),
    locale: v.string(),
    status: v.union(v.literal("processing"), v.literal("ready"), v.literal("failed")),
    leaseId: v.string(),
    leaseExpiresAt: v.number(),
    characters: v.optional(v.array(castCharacterV)),
    segments: v.optional(v.array(castSegmentV)),
  }).index("by_video_locale", ["videoId", "locale"]),

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
