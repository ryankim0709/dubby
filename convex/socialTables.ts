import { defineTable } from "convex/server";
import { v } from "convex/values";

export const socialSpanV = v.object({ start: v.number(), end: v.number() });
export const socialScriptV = v.object({
  title: v.string(), duration: v.number(), locale: v.string(),
  speakers: v.array(v.object({ id: v.number(), name: v.string() })),
  lines: v.array(v.object({ id: v.number(), speakerId: v.number(), text: v.string(), start: v.number(), end: v.number() })),
  protectedSpans: v.array(socialSpanV),
  ownerCharacterId: v.number(), guestCharacterId: v.number(), ownerLinesRecorded: v.number(),
});
export const roomStateV = v.union(v.literal("invited"), v.literal("accepted"), v.literal("completed"), v.literal("declined"), v.literal("cancelled"));

export const socialTables = {
  friendships: defineTable({
    senderId: v.id("users"), recipientId: v.id("users"), pair: v.string(),
    status: v.union(v.literal("pending"), v.literal("accepted"), v.literal("declined")), createdAt: v.number(),
  }).index("by_pair", ["pair"]).index("by_sender", ["senderId"]).index("by_recipient", ["recipientId"]),
  socialAssets: defineTable({ ownerId: v.id("users"), storageId: v.optional(v.id("_storage")), createdAt: v.number() })
    .index("by_storage", ["storageId"]),
  coDubs: defineTable({
    ownerId: v.id("users"), recipientId: v.optional(v.id("users")), code: v.string(), clientId: v.string(), sourceAssetId: v.id("socialAssets"),
    script: socialScriptV, joinOnly: v.optional(v.boolean()), status: roomStateV, resultAssetId: v.optional(v.id("socialAssets")),
    guestLinesRecorded: v.optional(v.number()), ownerApproved: v.boolean(), guestApproved: v.boolean(), createdAt: v.number(), updatedAt: v.number(),
  }).index("by_owner", ["ownerId"]).index("by_owner_client", ["ownerId", "clientId"]).index("by_recipient", ["recipientId"]).index("by_code", ["code"])
    .index("by_source", ["sourceAssetId"]).index("by_result", ["resultAssetId"]),
  socialPosts: defineTable({
    ownerId: v.id("users"), assetId: v.id("socialAssets"), title: v.string(), characterName: v.string(),
    linesRecorded: v.number(), coDubId: v.optional(v.id("coDubs")), guestId: v.optional(v.id("users")), visible: v.boolean(), createdAt: v.number(),
  }).index("by_owner", ["ownerId"]).index("by_guest", ["guestId"]).index("by_asset", ["assetId"]).index("by_co_dub", ["coDubId"]),
};
