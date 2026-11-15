import { convexTest } from "convex-test";
import { expect, test } from "vitest";
import { api, internal } from "./_generated/api";
import schema from "./schema";
import { alice, bob, modules } from "./test.helpers";

test("club uploads remain owned and a retried publication keeps one identity", async () => {
  const t = convexTest(schema, modules);
  const owner = await t.withIdentity(alice).mutation(api.users.ensure, {});
  await t.withIdentity(bob).mutation(api.users.ensure, {});
  await t.run(async ctx => { await ctx.db.insert("clubMembers", { ownerId: owner.userId, whopUserId: "user_demo", displayName: "Demo" }); });
  const request = { subject: alice.tokenIdentifier, requestId: "synthetic-upload", fileId: "file_synthetic", kind: "video" as const, byteSize: 100 };
  const uploadId = await t.mutation(internal.clubs.rememberUpload, request);
  expect(await t.mutation(internal.clubs.rememberUpload, request)).toBe(uploadId);
  await expect(t.mutation(internal.clubs.rememberUpload, { ...request, byteSize: 200 })).rejects.toThrow("different file");
  const claim = { subject: alice.tokenIdentifier, uploadId, caption: "Synthetic performance", replyToMessageId: null };
  await expect(t.mutation(internal.clubs.claimPost, { ...claim, subject: bob.tokenIdentifier })).rejects.toThrow("wasn't found");
  await expect(t.mutation(internal.clubs.claimPost, { ...claim, replyToMessageId: "post_someone" })).rejects.toThrow("Voice feedback");
  expect((await t.mutation(internal.clubs.claimPost, claim)).messageId).toBeNull();
  await t.mutation(internal.clubs.completePost, { uploadId, messageId: "post_synthetic" });
  expect((await t.mutation(internal.clubs.claimPost, claim)).messageId).toBe("post_synthetic");
  await expect(t.mutation(internal.clubs.claimPost, { ...claim, caption: "Changed after sending" })).rejects.toThrow("different details");
  await expect(t.withIdentity(bob).query(api.clubs.membership, {})).rejects.toThrow("demo and demo1");
  await expect(t.query(api.clubs.membership, {})).rejects.toThrow("Sign in");
});

test("voice uploads require a reply target before becoming a club post", async () => {
  const t = convexTest(schema, modules);
  await t.withIdentity(alice).mutation(api.users.ensure, {});
  const uploadId = await t.mutation(internal.clubs.rememberUpload, { subject: alice.tokenIdentifier, requestId: "synthetic-voice", fileId: "file_voice", kind: "voice", byteSize: 100 });
  await expect(t.mutation(internal.clubs.claimPost, { subject: alice.tokenIdentifier, uploadId, caption: "", replyToMessageId: null })).rejects.toThrow("Voice feedback");
  expect((await t.mutation(internal.clubs.claimPost, { subject: alice.tokenIdentifier, uploadId, caption: "", replyToMessageId: "post_video" })).kind).toBe("voice");
  expect((await t.fetch("/clubs/feed")).status).toBe(401);
});
