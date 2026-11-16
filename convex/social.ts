import { v } from "convex/values";
import type { Infer } from "convex/values";
import type { Doc, Id } from "./_generated/dataModel";
import { internalQuery, mutation, query, type QueryCtx } from "./_generated/server";
import { requireUser } from "./lib/auth";
import { appError } from "./lib/errors";
import { roomStateV, socialScriptV } from "./socialTables";

const okV = v.object({ ok: v.boolean() });
const personV = v.object({ id: v.id("users"), username: v.string() });
const roomV = v.object({
  id: v.id("coDubs"), owner: personV, guest: v.union(personV, v.null()), code: v.string(), script: socialScriptV,
  joinOnly: v.boolean(), status: roomStateV, sourceAssetId: v.id("socialAssets"), resultAssetId: v.union(v.id("socialAssets"), v.null()),
  guestLinesRecorded: v.union(v.number(), v.null()), approvedByMe: v.boolean(), published: v.boolean(), createdAt: v.number(),
});
const postV = v.object({
  id: v.id("socialPosts"), owner: personV, guest: v.union(personV, v.null()), title: v.string(), characterName: v.string(),
  guestCharacterName: v.union(v.string(), v.null()), linesRecorded: v.number(), guestLinesRecorded: v.union(v.number(), v.null()),
  assetId: v.id("socialAssets"), coDubId: v.union(v.id("coDubs"), v.null()), createdAt: v.number(),
});
type Person = Infer<typeof personV>;
type Room = Infer<typeof roomV>;
type Post = Infer<typeof postV>;

function friendshipPair(a: Id<"users">, b: Id<"users">): string { return [a, b].sort().join(":"); }

async function person(ctx: QueryCtx, id: Id<"users">): Promise<Person> {
  const user = await ctx.db.get(id);
  if (user?.username === undefined) throw appError("INVALID_STATE", "Social sharing requires a Dubby username. Sign in again to refresh your account.");
  return { id, username: user.username };
}

async function friends(ctx: QueryCtx, id: Id<"users">): Promise<Doc<"friendships">[]> {
  const [sent, received] = await Promise.all([
    ctx.db.query("friendships").withIndex("by_sender", (q) => q.eq("senderId", id)).take(200),
    ctx.db.query("friendships").withIndex("by_recipient", (q) => q.eq("recipientId", id)).take(200),
  ]);
  return [...sent, ...received];
}

async function areFriends(ctx: QueryCtx, a: Id<"users">, b: Id<"users">): Promise<boolean> {
  const edge = await ctx.db.query("friendships").withIndex("by_pair", (q) => q.eq("pair", friendshipPair(a, b))).unique();
  return edge?.status === "accepted";
}

async function ownedAsset(ctx: QueryCtx, id: Id<"socialAssets">, ownerId: Id<"users">): Promise<Doc<"socialAssets">> {
  const asset = await ctx.db.get(id);
  if (asset === null || asset.ownerId !== ownerId || asset.storageId === undefined) throw appError("NOT_FOUND", "The uploaded video isn't available to this account");
  return asset;
}

async function memberRoom(ctx: QueryCtx, id: Id<"coDubs">, userId: Id<"users">): Promise<Doc<"coDubs">> {
  const room = await ctx.db.get(id);
  if (room === null || (room.ownerId !== userId && room.recipientId !== userId)) throw appError("NOT_FOUND", "This co-dub isn't available to your account");
  return room;
}

async function roomSummary(ctx: QueryCtx, room: Doc<"coDubs">, viewer: Id<"users">): Promise<Room> {
  return {
    id: room._id, owner: await person(ctx, room.ownerId), guest: room.recipientId === undefined ? null : await person(ctx, room.recipientId),
    code: room.code, script: room.script, joinOnly: room.joinOnly === true, status: room.status, sourceAssetId: room.sourceAssetId, resultAssetId: room.resultAssetId ?? null,
    guestLinesRecorded: room.guestLinesRecorded ?? null, approvedByMe: viewer === room.ownerId ? room.ownerApproved : room.guestApproved,
    published: room.ownerApproved && room.guestApproved, createdAt: room.createdAt,
  };
}

async function canReadPost(ctx: QueryCtx, post: Doc<"socialPosts">, viewer: Id<"users">): Promise<boolean> {
  if (!post.visible) return false;
  if (post.coDubId === undefined) return post.ownerId === viewer || await areFriends(ctx, post.ownerId, viewer);
  const room = await ctx.db.get(post.coDubId);
  return room !== null && room.status === "completed" && room.ownerApproved && room.guestApproved &&
    (room.ownerId === viewer || room.recipientId === viewer || await areFriends(ctx, room.ownerId, viewer) ||
      (room.recipientId !== undefined && await areFriends(ctx, room.recipientId, viewer)));
}

function validateScript(script: Infer<typeof socialScriptV>): void {
  if (!Number.isFinite(script.duration) || script.duration <= 0 || script.title.trim().length === 0 || script.title.length > 200 || script.lines.length > 100 || script.speakers.length < 2 || script.speakers.length > 12) {
    throw appError("INVALID_ARGUMENT", "A co-dub needs a titled scene with valid timing and at least two characters");
  }
  const ids = new Set(script.speakers.map((speaker) => speaker.id));
  if (ids.size !== script.speakers.length || script.speakers.some((speaker) => !Number.isSafeInteger(speaker.id) || speaker.id < 0 || speaker.name.trim().length === 0 || speaker.name.length > 80) ||
      script.ownerCharacterId === script.guestCharacterId || !ids.has(script.ownerCharacterId) || !ids.has(script.guestCharacterId)) throw appError("INVALID_ARGUMENT", "Choose two different characters from this scene");
  const lineIds = new Set(script.lines.map((line) => line.id));
  if (lineIds.size !== script.lines.length || script.lines.some((line) => !Number.isSafeInteger(line.id) || line.id < 0 || !ids.has(line.speakerId) || !Number.isFinite(line.start) || !Number.isFinite(line.end) || line.start < 0 || line.start >= line.end || line.end > script.duration || line.text.trim().length === 0 || line.text.length > 2000)) throw appError("INVALID_ARGUMENT", "The co-dub script contains an invalid line or timestamp");
  const guestLines = script.lines.filter((line) => line.speakerId === script.guestCharacterId);
  const ownerLines = script.lines.filter((line) => line.speakerId === script.ownerCharacterId);
  if (guestLines.length === 0 || !Number.isSafeInteger(script.ownerLinesRecorded) || script.ownerLinesRecorded < 0 || script.ownerLinesRecorded > ownerLines.length || script.protectedSpans.length !== script.ownerLinesRecorded || new Set(script.protectedSpans.map((span) => span.start)).size !== script.ownerLinesRecorded || script.protectedSpans.some((span) => !Number.isFinite(span.start) || !Number.isFinite(span.end) || span.start < 0 || span.start >= span.end || span.end > script.duration || !ownerLines.some((line) => line.start === span.start) || guestLines.some((line) => line.start < span.end && line.end > span.start))) {
    throw appError("INVALID_ARGUMENT", "The invited role must have lines that don't overlap your kept performance. Choose another role or scene.");
  }
  if (!/^[a-z]{2,3}-[A-Z]{2}$/.test(script.locale)) throw appError("INVALID_ARGUMENT", "The scene needs a supported speech locale");
}

export const snapshot = query({
  args: {},
  returns: v.object({ me: personV, friends: v.array(personV), requests: v.array(v.object({ id: v.id("friendships"), person: personV, incoming: v.boolean() })), rooms: v.array(roomV), posts: v.array(postV) }),
  handler: async (ctx) => {
    const user = await requireUser(ctx);
    const me = await person(ctx, user._id);
    const edges = await friends(ctx, user._id);
    const friendIds = edges.filter((edge) => edge.status === "accepted").map((edge) => edge.senderId === user._id ? edge.recipientId : edge.senderId);
    const contacts = await Promise.all(friendIds.map((id) => person(ctx, id)));
    const requests = await Promise.all(edges.filter((edge) => edge.status === "pending").map(async (edge) => ({ id: edge._id, person: await person(ctx, edge.senderId === user._id ? edge.recipientId : edge.senderId), incoming: edge.recipientId === user._id })));
    const [owned, invited] = await Promise.all([
      ctx.db.query("coDubs").withIndex("by_owner", (q) => q.eq("ownerId", user._id)).order("desc").take(40),
      ctx.db.query("coDubs").withIndex("by_recipient", (q) => q.eq("recipientId", user._id)).order("desc").take(40),
    ]);
    const rooms = await Promise.all([...owned, ...invited].sort((a, b) => b.updatedAt - a.updatedAt).map((room) => roomSummary(ctx, room, user._id)));
    const candidateGroups = await Promise.all([user._id, ...friendIds].map((id) => Promise.all([
      ctx.db.query("socialPosts").withIndex("by_owner", (q) => q.eq("ownerId", id)).order("desc").take(20),
      ctx.db.query("socialPosts").withIndex("by_guest", (q) => q.eq("guestId", id)).order("desc").take(20),
    ])));
    const candidates = [...new Map(candidateGroups.flat(2).map((post) => [post._id, post])).values()].sort((a, b) => b.createdAt - a.createdAt);
    const posts: Post[] = [];
    for (const post of candidates) {
      if (!(await canReadPost(ctx, post, user._id))) continue;
      const room = post.coDubId === undefined ? null : await ctx.db.get(post.coDubId);
      posts.push({ id: post._id, owner: await person(ctx, post.ownerId), guest: room?.recipientId === undefined ? null : await person(ctx, room.recipientId), title: post.title, characterName: post.characterName, guestCharacterName: room?.script.speakers.find((speaker) => speaker.id === room.script.guestCharacterId)?.name ?? null, linesRecorded: post.linesRecorded, guestLinesRecorded: room?.guestLinesRecorded ?? null, assetId: post.assetId, coDubId: post.coDubId ?? null, createdAt: post.createdAt });
      if (posts.length === 30) break;
    }
    return { me, friends: contacts.sort((a, b) => a.username.localeCompare(b.username)), requests, rooms, posts };
  },
});

export const requestFriend = mutation({
  args: { username: v.string() }, returns: okV,
  handler: async (ctx, { username }) => {
    const user = await requireUser(ctx);
    await person(ctx, user._id);
    const recipient = await ctx.db.query("users").withIndex("by_username", (q) => q.eq("username", username.trim().toLowerCase())).unique();
    if (recipient === null) throw appError("NOT_FOUND", "No signed-in Dubby learner has that username yet");
    if (recipient._id === user._id) throw appError("INVALID_ARGUMENT", "Choose someone else's username");
    const pair = friendshipPair(user._id, recipient._id);
    const existing = await ctx.db.query("friendships").withIndex("by_pair", (q) => q.eq("pair", pair)).unique();
    if (existing !== null && existing.status !== "declined") return { ok: true };
    if ((await friends(ctx, user._id)).length >= 200 || (await friends(ctx, recipient._id)).length >= 200) throw appError("INVALID_STATE", "One of these accounts has reached the current 200-connection limit");
    if (existing === null) await ctx.db.insert("friendships", { senderId: user._id, recipientId: recipient._id, pair, status: "pending", createdAt: Date.now() });
    else await ctx.db.patch(existing._id, { senderId: user._id, recipientId: recipient._id, status: "pending", createdAt: Date.now() });
    return { ok: true };
  },
});

export const acceptFriend = mutation({
  args: { id: v.id("friendships") }, returns: okV,
  handler: async (ctx, { id }) => {
    const user = await requireUser(ctx);
    const edge = await ctx.db.get(id);
    if (edge === null || edge.recipientId !== user._id) throw appError("NOT_FOUND", "This friend request isn't addressed to you");
    if (edge.status !== "pending" && edge.status !== "accepted") throw appError("INVALID_STATE", "This request is no longer pending");
    await ctx.db.patch(id, { status: "accepted" });
    return { ok: true };
  },
});

export const removeFriend = mutation({
  args: { personId: v.id("users") }, returns: okV,
  handler: async (ctx, { personId }) => {
    const user = await requireUser(ctx);
    const edge = await ctx.db.query("friendships").withIndex("by_pair", (q) => q.eq("pair", friendshipPair(user._id, personId))).unique();
    if (edge === null) throw appError("NOT_FOUND", "This connection isn't available");
    await ctx.db.patch(edge._id, { status: "declined" });
    return { ok: true };
  },
});

export const prepareUpload = mutation({
  args: {}, returns: v.object({ ticketId: v.id("socialAssets"), url: v.string() }),
  handler: async (ctx) => {
    const user = await requireUser(ctx);
    await person(ctx, user._id);
    return { ticketId: await ctx.db.insert("socialAssets", { ownerId: user._id, createdAt: Date.now() }), url: await ctx.storage.generateUploadUrl() };
  },
});

export const finishUpload = mutation({
  args: { ticketId: v.id("socialAssets"), storageId: v.id("_storage") }, returns: okV,
  handler: async (ctx, { ticketId, storageId }) => {
    const user = await requireUser(ctx);
    const asset = await ctx.db.get(ticketId);
    if (asset === null || asset.ownerId !== user._id) throw appError("NOT_FOUND", "This upload ticket isn't yours");
    if (asset.storageId === storageId) return { ok: true };
    if (asset.storageId !== undefined) throw appError("CONFLICT", "This upload ticket already contains a video");
    const file = await ctx.db.system.get(storageId);
    const claimed = await ctx.db.query("socialAssets").withIndex("by_storage", (q) => q.eq("storageId", storageId)).unique();
    if (file === null || file.contentType !== "video/mp4" || file.size < 1 || file.size > 80 * 1024 * 1024 || claimed !== null) throw appError("INVALID_UPLOAD", "Upload an unclaimed MP4 of at most 80 MB");
    await ctx.db.patch(ticketId, { storageId });
    return { ok: true };
  },
});

export const invite = mutation({
  args: { assetId: v.id("socialAssets"), script: socialScriptV, recipientId: v.optional(v.id("users")), clientId: v.string() },
  returns: v.object({ id: v.id("coDubs"), code: v.string() }),
  handler: async (ctx, args) => {
    const user = await requireUser(ctx);
    if (args.clientId.length < 1 || args.clientId.length > 100) throw appError("INVALID_ARGUMENT", "The invitation needs a client operation identifier");
    const existing = await ctx.db.query("coDubs").withIndex("by_owner_client", (q) => q.eq("ownerId", user._id).eq("clientId", args.clientId)).unique();
    if (existing !== null) return { id: existing._id, code: existing.code };
    await ownedAsset(ctx, args.assetId, user._id);
    validateScript(args.script);
    if (args.script.ownerLinesRecorded < 1) throw appError("INVALID_ARGUMENT", "The invitation needs a kept performance");
    if (args.recipientId !== undefined && !(await areFriends(ctx, user._id, args.recipientId))) throw appError("INVALID_ARGUMENT", "Choose an accepted friend, or create a private invite link");
    const code = crypto.randomUUID();
    const id = await ctx.db.insert("coDubs", { ownerId: user._id, recipientId: args.recipientId, code, clientId: args.clientId, sourceAssetId: args.assetId, script: args.script, status: "invited", ownerApproved: false, guestApproved: false, createdAt: Date.now(), updatedAt: Date.now() });
    return { id, code };
  },
});

export const inviteToJoin = mutation({
  args: { sceneSlug: v.string(), sectionStart: v.number(), script: socialScriptV, recipientId: v.optional(v.id("users")), clientId: v.string() },
  returns: v.object({ id: v.id("coDubs"), code: v.string() }),
  handler: async (ctx, args) => {
    const user = await requireUser(ctx);
    await person(ctx, user._id);
    if (args.clientId.length < 1 || args.clientId.length > 100) throw appError("INVALID_ARGUMENT", "The invitation needs an operation identifier");
    const existing = await ctx.db.query("coDubs").withIndex("by_owner_client", (q) => q.eq("ownerId", user._id).eq("clientId", args.clientId)).unique();
    if (existing !== null) return { id: existing._id, code: existing.code };
    const scene = await ctx.db.query("scenes").withIndex("by_slug", (q) => q.eq("slug", args.sceneSlug)).unique();
    if (scene === null || !scene.published || scene.videoId === undefined) throw appError("NOT_FOUND", "This scene isn't available for your friend to join");
    if (!Number.isFinite(args.sectionStart) || args.sectionStart < 0 || args.sectionStart + args.script.duration > scene.durationSeconds + 0.1) throw appError("INVALID_ARGUMENT", "The invitation's section is outside the scene");
    if (args.recipientId !== undefined && !(await areFriends(ctx, user._id, args.recipientId))) throw appError("INVALID_ARGUMENT", "Choose an accepted friend or send an open invitation");
    const script = { ...args.script, duration: scene.durationSeconds, protectedSpans: [], ownerLinesRecorded: 0, lines: args.script.lines.map((line) => ({ ...line, start: line.start + args.sectionStart, end: line.end + args.sectionStart })) };
    validateScript(script);
    const sourceAssetId = await ctx.db.insert("socialAssets", { ownerId: user._id, storageId: scene.videoId, createdAt: Date.now() });
    const code = crypto.randomUUID();
    const id = await ctx.db.insert("coDubs", { ownerId: user._id, recipientId: args.recipientId, code, clientId: args.clientId, sourceAssetId, script, joinOnly: true, status: "invited", ownerApproved: false, guestApproved: false, createdAt: Date.now(), updatedAt: Date.now() });
    return { id, code };
  },
});

export const redeem = mutation({
  args: { code: v.string() }, returns: v.object({ id: v.id("coDubs") }),
  handler: async (ctx, { code }) => {
    const user = await requireUser(ctx);
    await person(ctx, user._id);
    const room = await ctx.db.query("coDubs").withIndex("by_code", (q) => q.eq("code", code.trim().toLowerCase())).unique();
    if (room === null || (room.recipientId !== undefined && room.recipientId !== user._id && room.ownerId !== user._id)) throw appError("NOT_FOUND", "This invitation isn't available to your account");
    if (room.status === "cancelled" || room.status === "declined") throw appError("INVALID_STATE", "This invitation is no longer open");
    if (room.ownerId === user._id) return { id: room._id };
    if (room.recipientId === undefined) await ctx.db.patch(room._id, { recipientId: user._id, updatedAt: Date.now() });
    return { id: room._id };
  },
});

export const room = query({
  args: { id: v.id("coDubs") }, returns: roomV,
  handler: async (ctx, { id }) => roomSummary(ctx, await memberRoom(ctx, id, (await requireUser(ctx))._id), (await requireUser(ctx))._id),
});

export const acceptInvite = mutation({
  args: { id: v.id("coDubs") }, returns: okV,
  handler: async (ctx, { id }) => {
    const user = await requireUser(ctx);
    const room = await memberRoom(ctx, id, user._id);
    if (room.recipientId !== user._id || (room.status !== "invited" && room.status !== "accepted")) throw appError("INVALID_STATE", "Only the invited performer can accept an open invitation");
    await ctx.db.patch(id, { status: "accepted", updatedAt: Date.now() });
    return { ok: true };
  },
});

export const closeInvite = mutation({
  args: { id: v.id("coDubs") }, returns: okV,
  handler: async (ctx, { id }) => {
    const user = await requireUser(ctx);
    const room = await memberRoom(ctx, id, user._id);
    if (room.status === "completed") throw appError("INVALID_STATE", "A completed co-dub can be unshared from its result instead");
    await ctx.db.patch(id, { status: room.ownerId === user._id ? "cancelled" : "declined", updatedAt: Date.now() });
    return { ok: true };
  },
});

export const complete = mutation({
  args: { id: v.id("coDubs"), assetId: v.id("socialAssets"), linesRecorded: v.number() }, returns: okV,
  handler: async (ctx, args) => {
    const user = await requireUser(ctx);
    const room = await memberRoom(ctx, args.id, user._id);
    if (room.recipientId !== user._id) throw appError("NOT_FOUND", "Only the invited performer can finish this co-dub");
    if (room.status === "completed" && room.resultAssetId === args.assetId) return { ok: true };
    if (room.status !== "accepted") throw appError("INVALID_STATE", "Accept the invitation before uploading your performance");
    await ownedAsset(ctx, args.assetId, user._id);
    const total = room.script.lines.filter((line) => line.speakerId === room.script.guestCharacterId).length;
    if (!Number.isSafeInteger(args.linesRecorded) || args.linesRecorded !== total) throw appError("INVALID_ARGUMENT", "Keep every line of your invited character before completing the co-dub");
    await ctx.db.patch(args.id, { resultAssetId: args.assetId, guestLinesRecorded: args.linesRecorded, status: "completed", updatedAt: Date.now() });
    return { ok: true };
  },
});

export const postSolo = mutation({
  args: { assetId: v.id("socialAssets"), title: v.string(), characterName: v.string(), linesRecorded: v.number() }, returns: okV,
  handler: async (ctx, args) => {
    const user = await requireUser(ctx);
    await ownedAsset(ctx, args.assetId, user._id);
    if (args.title.trim().length === 0 || args.title.length > 200 || args.characterName.length > 80 || !Number.isSafeInteger(args.linesRecorded) || args.linesRecorded < 1 || args.linesRecorded > 100) throw appError("INVALID_ARGUMENT", "The shared dub needs a title, character and recorded lines");
    const collaborations = await ctx.db.query("coDubs").withIndex("by_result", (q) => q.eq("resultAssetId", args.assetId)).take(1);
    if (collaborations.length > 0) throw appError("INVALID_STATE", "Post a combined co-dub through its result so both performers can approve it");
    const existing = await ctx.db.query("socialPosts").withIndex("by_asset", (q) => q.eq("assetId", args.assetId)).unique();
    if (existing === null) await ctx.db.insert("socialPosts", { ...args, ownerId: user._id, visible: true, createdAt: Date.now() });
    else if (!existing.visible) await ctx.db.patch(existing._id, { visible: true, createdAt: Date.now() });
    return { ok: true };
  },
});

export const approvePost = mutation({
  args: { id: v.id("coDubs") }, returns: okV,
  handler: async (ctx, { id }) => {
    const user = await requireUser(ctx);
    const room = await memberRoom(ctx, id, user._id);
    if (room.status !== "completed" || room.resultAssetId === undefined) throw appError("INVALID_STATE", "Finish the co-dub before posting it");
    const ownerApproved = room.ownerApproved || room.ownerId === user._id;
    const guestApproved = room.guestApproved || room.recipientId === user._id;
    await ctx.db.patch(id, { ownerApproved, guestApproved, updatedAt: Date.now() });
    if (ownerApproved && guestApproved) {
      const existing = await ctx.db.query("socialPosts").withIndex("by_co_dub", (q) => q.eq("coDubId", id)).unique();
      const character = room.script.speakers.find((speaker) => speaker.id === room.script.ownerCharacterId);
      if (character === undefined) throw appError("INVALID_STATE", "The co-dub's character is missing");
      if (existing === null) await ctx.db.insert("socialPosts", { ownerId: room.ownerId, guestId: room.recipientId, assetId: room.resultAssetId, title: room.script.title, characterName: character.name, linesRecorded: room.script.ownerLinesRecorded, coDubId: id, visible: true, createdAt: Date.now() });
      else await ctx.db.patch(existing._id, { visible: true, createdAt: Date.now() });
    }
    return { ok: true };
  },
});

export const unpublish = mutation({
  args: { id: v.id("socialPosts") }, returns: okV,
  handler: async (ctx, { id }) => {
    const user = await requireUser(ctx);
    const post = await ctx.db.get(id);
    if (post === null) throw appError("NOT_FOUND", "This post isn't available");
    const room = post.coDubId === undefined ? null : await memberRoom(ctx, post.coDubId, user._id);
    if (post.ownerId !== user._id && room === null) throw appError("NOT_FOUND", "Only a performer can stop sharing this dub");
    await ctx.db.patch(id, { visible: false });
    if (room !== null) await ctx.db.patch(room._id, { ownerApproved: false, guestApproved: false });
    return { ok: true };
  },
});

export const withdrawApproval = mutation({
  args: { id: v.id("coDubs") }, returns: okV,
  handler: async (ctx, { id }) => {
    const user = await requireUser(ctx);
    const room = await memberRoom(ctx, id, user._id);
    if (room.ownerId === user._id) await ctx.db.patch(id, { ownerApproved: false, updatedAt: Date.now() });
    else await ctx.db.patch(id, { guestApproved: false, updatedAt: Date.now() });
    const post = await ctx.db.query("socialPosts").withIndex("by_co_dub", (q) => q.eq("coDubId", id)).unique();
    if (post !== null) await ctx.db.patch(post._id, { visible: false });
    return { ok: true };
  },
});

export const media = internalQuery({
  args: { rawId: v.string() }, returns: v.union(v.object({ storageId: v.id("_storage") }), v.null()),
  handler: async (ctx, { rawId }) => {
    const user = await requireUser(ctx);
    const id = ctx.db.normalizeId("socialAssets", rawId);
    if (id === null) return null;
    const asset = await ctx.db.get(id);
    if (asset?.storageId === undefined) return null;
    if (asset.ownerId === user._id) return { storageId: asset.storageId };
    const [sources, results, posts] = await Promise.all([
      ctx.db.query("coDubs").withIndex("by_source", (q) => q.eq("sourceAssetId", id)).collect(),
      ctx.db.query("coDubs").withIndex("by_result", (q) => q.eq("resultAssetId", id)).collect(),
      ctx.db.query("socialPosts").withIndex("by_asset", (q) => q.eq("assetId", id)).collect(),
    ]);
    if ([...sources, ...results].some((room) => room.status !== "cancelled" && room.status !== "declined" && (room.ownerId === user._id || room.recipientId === user._id))) return { storageId: asset.storageId };
    for (const post of posts) if (await canReadPost(ctx, post, user._id)) return { storageId: asset.storageId };
    return null;
  },
});
