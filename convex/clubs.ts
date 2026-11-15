import { ConvexError, v } from "convex/values";
import { z } from "zod";
import { api, internal } from "./_generated/api";
import type { Id } from "./_generated/dataModel";
import { action, internalMutation, query } from "./_generated/server";
import { requireUser } from "./lib/auth";
import { clubChallenge, clubFile, clubMessage, clubUserClient, uploadFile, uploadRequest, validClubMedia } from "./lib/clubs";
import type { ClubFeed } from "./lib/clubs";
import { requiredEnv } from "./lib/env";
import { appError } from "./lib/errors";
import { whopRequest } from "./lib/whop";

const kindV = v.union(v.literal("video"), v.literal("voice"));

export const membership = query({
  args: {},
  returns: v.object({ whopUserId: v.string(), displayName: v.string(), members: v.array(v.object({ whopUserId: v.string(), displayName: v.string() })) }),
  handler: async (ctx) => {
    const user = await requireUser(ctx);
    const member = await ctx.db.query("clubMembers").withIndex("by_owner", q => q.eq("ownerId", user._id)).unique();
    if (member === null) throw appError("NOT_FOUND", "This sandbox club is available to demo and demo1. Sign in with either demo account.");
    const members = await ctx.db.query("clubMembers").collect();
    return { whopUserId: member.whopUserId, displayName: member.displayName, members: members.map(m => ({ whopUserId: m.whopUserId, displayName: m.displayName })) };
  },
});

export const seedDemoMembers = internalMutation({
  args: { members: v.array(v.object({ username: v.string(), whopUserId: v.string(), displayName: v.string() })) },
  returns: v.null(),
  handler: async (ctx, { members }) => {
    if (process.env.WHOP_SANDBOX !== "true") throw appError("INVALID_STATE", "Demo club members require the Whop sandbox");
    if (members.length !== 2 || new Set(members.map(m => m.username)).size !== 2 || new Set(members.map(m => m.whopUserId)).size !== 2) throw appError("INVALID_ARGUMENT", "Two distinct demo members are required");
    for (const member of members) {
      if (!["demo", "demo1"].includes(member.username) || !member.whopUserId.startsWith("user_")) throw appError("INVALID_ARGUMENT", "Only the two sandbox demo identities may be enrolled");
      const account = await ctx.db.query("passwordAccounts").withIndex("by_username", q => q.eq("username", member.username)).unique();
      if (account === null) throw appError("NOT_FOUND", "Seed the demo password accounts first");
      const tokenIdentifier = `${requiredEnv("CONVEX_SITE_URL")}|${account._id}`;
      let user = await ctx.db.query("users").withIndex("by_token_identifier", q => q.eq("tokenIdentifier", tokenIdentifier)).unique();
      if (user === null) {
        const id = await ctx.db.insert("users", { tokenIdentifier, createdAt: Date.now() });
        user = await ctx.db.get("users", id);
      }
      if (user === null) throw appError("USER_NOT_FOUND", "The demo learner could not be registered");
      const existing = await ctx.db.query("clubMembers").withIndex("by_owner", q => q.eq("ownerId", user._id)).unique();
      if (existing !== null) {
        if (existing.whopUserId !== member.whopUserId) throw appError("CONFLICT", "The demo learner already has a different Whop identity");
      } else await ctx.db.insert("clubMembers", { ownerId: user._id, whopUserId: member.whopUserId, displayName: member.displayName });
    }
    return null;
  },
});

export const rememberUpload = internalMutation({
  args: { subject: v.string(), requestId: v.string(), fileId: v.string(), kind: kindV, byteSize: v.number() },
  returns: v.id("clubUploads"),
  handler: async (ctx, args) => {
    const user = await ctx.db.query("users").withIndex("by_token_identifier", q => q.eq("tokenIdentifier", args.subject)).unique();
    if (user === null) throw appError("USER_NOT_FOUND", "Sign in before sharing");
    const existing = await ctx.db.query("clubUploads").withIndex("by_owner_request", q => q.eq("ownerId", user._id).eq("requestId", args.requestId)).unique();
    if (existing !== null) {
      if (existing.kind !== args.kind || existing.byteSize !== args.byteSize || existing.fileId !== args.fileId) throw appError("CONFLICT", "That upload request already belongs to a different file");
      return existing._id;
    }
    return await ctx.db.insert("clubUploads", { ownerId: user._id, requestId: args.requestId, fileId: args.fileId, kind: args.kind, byteSize: args.byteSize, createdAt: Date.now() });
  },
});

export const claimPost = internalMutation({
  args: { subject: v.string(), uploadId: v.string(), caption: v.string(), replyToMessageId: v.union(v.string(), v.null()) },
  returns: v.object({ uploadId: v.id("clubUploads"), fileId: v.string(), kind: kindV, byteSize: v.number(), messageId: v.union(v.string(), v.null()) }),
  handler: async (ctx, args) => {
    const user = await ctx.db.query("users").withIndex("by_token_identifier", q => q.eq("tokenIdentifier", args.subject)).unique();
    const uploadId = ctx.db.normalizeId("clubUploads", args.uploadId);
    const upload = uploadId === null ? null : await ctx.db.get("clubUploads", uploadId);
    if (user === null || upload === null || upload.ownerId !== user._id) throw appError("NOT_FOUND", "That club upload wasn't found");
    if ((upload.kind === "voice") !== (args.replyToMessageId !== null)) throw appError("INVALID_ARGUMENT", "Voice feedback must reply to a video; video submissions start a new post");
    if (upload.caption !== undefined && (upload.caption !== args.caption || upload.replyToMessageId !== args.replyToMessageId)) throw appError("CONFLICT", "This upload is already being shared with different details");
    await ctx.db.patch("clubUploads", upload._id, { caption: args.caption, replyToMessageId: args.replyToMessageId });
    return { uploadId: upload._id, fileId: upload.fileId, kind: upload.kind, byteSize: upload.byteSize, messageId: upload.messageId ?? null };
  },
});

export const completePost = internalMutation({
  args: { uploadId: v.id("clubUploads"), messageId: v.string() }, returns: v.null(),
  handler: async (ctx, args) => {
    const upload = await ctx.db.get("clubUploads", args.uploadId);
    if (upload === null) throw appError("NOT_FOUND", "The club upload wasn't found");
    if (upload.messageId !== undefined && upload.messageId !== args.messageId) throw appError("CONFLICT", "The upload was already posted as a different message");
    await ctx.db.patch("clubUploads", args.uploadId, { messageId: args.messageId });
    return null;
  },
});

export const prepareUpload = action({
  args: { requestId: v.string(), kind: kindV, byteSize: v.number() },
  returns: v.object({ uploadId: v.id("clubUploads"), url: v.string(), headers: v.record(v.string(), v.string()) }),
  handler: async (ctx, args): Promise<{ uploadId: Id<"clubUploads">; url: string; headers: Record<string, string> }> => {
    const request = uploadRequest.parse(args);
    if (request.kind === "voice" && request.byteSize > 5_000_000) throw appError("INVALID_ARGUMENT", "Voice feedback must be under 5 MB");
    const member = await ctx.runQuery(api.clubs.membership, {});
    const identity = await ctx.auth.getUserIdentity();
    if (identity === null) throw appError("UNAUTHENTICATED", "Sign in before sharing");
    const client = await clubUserClient(member.whopUserId);
    const file = uploadFile.parse(await whopRequest("clubs.upload", () => client.files.create({
      filename: `${request.requestId}.${request.kind === "video" ? "mp4" : "m4a"}`, byte_size: request.byteSize, visibility: "private",
    }, { idempotencyKey: `club-upload-${member.whopUserId}-${request.requestId}` })));
    const uploadId = await ctx.runMutation(internal.clubs.rememberUpload, { ...request, fileId: file.id, subject: identity.tokenIdentifier });
    return { uploadId, url: file.upload_url, headers: file.upload_headers };
  },
});

export const publish = action({
  args: { uploadId: v.string(), caption: v.string(), replyToMessageId: v.union(v.string(), v.null()) },
  returns: v.object({ messageId: v.string() }),
  handler: async (ctx, args): Promise<{ messageId: string }> => {
    const member = await ctx.runQuery(api.clubs.membership, {});
    const identity = await ctx.auth.getUserIdentity();
    if (identity === null) throw appError("UNAUTHENTICATED", "Sign in before sharing");
    if (args.caption.length > 300) throw appError("INVALID_ARGUMENT", "Captions can contain up to 300 characters");
    const upload = await ctx.runMutation(internal.clubs.claimPost, { ...args, subject: identity.tokenIdentifier });
    if (upload.messageId !== null) return { messageId: upload.messageId };
    const client = await clubUserClient(member.whopUserId);
    const channelId = requiredEnv("WHOP_CLUB_CHANNEL_ID");
    let file = clubFile.parse(await whopRequest("clubs.file", () => client.files.retrieve({ id: upload.fileId })));
    for (let attempt = 0; (file.upload_status === "pending" || file.upload_status === "processing") && attempt < 10; attempt += 1) {
      await new Promise<void>(resolve => setTimeout(resolve, 500));
      file = clubFile.parse(await whopRequest("clubs.file", () => client.files.retrieve({ id: upload.fileId })));
    }
    if (file.upload_status === "failed") throw appError("INVALID_UPLOAD", "Whop couldn't process this recording. Try exporting or recording it again.");
    if (file.upload_status !== "ready") throw appError("INVALID_STATE", "Whop is still processing this upload. Try sharing again in a moment.");
    if (file.removed_by_moderation || file.size !== upload.byteSize || !validClubMedia(upload.kind, file.content_type)) throw appError("INVALID_UPLOAD", "Whop rejected the upload's media type or size");
    if (file.duration_seconds !== null && (file.duration_seconds <= 0 || file.duration_seconds > 31)) throw appError("INVALID_UPLOAD", "Club videos and voice feedback must be 30 seconds or shorter");
    const replyToMessageId = args.replyToMessageId;
    if (replyToMessageId !== null) {
      const parent = clubMessage.parse(await whopRequest("clubs.replyTarget", () => client.messages.retrieve({ id: replyToMessageId })));
      if (parent.channel_id !== channelId || !parent.attachments.some(a => a.content_type === "video/mp4" && !a.removed_by_moderation)) throw appError("INVALID_ARGUMENT", "Choose a video in this club to give voice feedback");
    }
    const message = clubMessage.parse(await whopRequest("clubs.publish", () => client.messages.create({
      channel_id: channelId, content: args.caption, attachments: [{ id: file.id }],
      ...(args.replyToMessageId === null ? {} : { replying_to_message_id: args.replyToMessageId }),
    }, { idempotencyKey: `club-post-${args.uploadId}` })));
    if (message.author_user_id !== member.whopUserId || message.channel_id !== channelId) throw new ConvexError({ code: "INVALID_STATE", message: "Whop returned a message for a different author or club" });
    await ctx.runMutation(internal.clubs.completePost, { uploadId: upload.uploadId, messageId: message.id });
    return { messageId: message.id };
  },
});

export const feed = action({
  args: {},
  handler: async (ctx): Promise<ClubFeed> => {
    const member = await ctx.runQuery(api.clubs.membership, {});
    const client = await clubUserClient(member.whopUserId);
    const channelId = requiredEnv("WHOP_CLUB_CHANNEL_ID");
    const page = await whopRequest("clubs.feed", () => client.messages.list({ channel_id: channelId, first: 50 }));
    const messages = z.array(clubMessage).parse(page.data);
    const posts = messages.flatMap(message => {
      const author = member.members.find(m => m.whopUserId === message.author_user_id);
      const media = message.attachments.find(file => file.upload_status === "ready" && !file.removed_by_moderation && file.url !== null && (validClubMedia("video", file.content_type) || validClubMedia("voice", file.content_type)));
      if (author === undefined || media === undefined || media.url === null) return [];
      return [{ id: message.id, authorId: author.whopUserId, authorName: author.displayName, caption: message.content ?? "", createdAt: message.created_at, replyToMessageId: message.replying_to_message_id, kind: media.content_type === "video/mp4" ? "video" as const : "voice" as const, mediaURL: media.url, durationSeconds: media.duration_seconds }];
    }).reverse();
    return { name: "Dub Clubs", challenge: clubChallenge, viewerId: member.whopUserId, members: member.members.map(m => ({ id: m.whopUserId, displayName: m.displayName })), posts };
  },
});
