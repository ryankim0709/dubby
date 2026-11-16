import { afterEach, expect, test, vi } from "vitest";
import { api } from "./_generated/api";
import type { Id } from "./_generated/dataModel";
import { alice, bob, newBackend, type Backend } from "./test.helpers";

const carol = { issuer: alice.issuer, subject: "carol", tokenIdentifier: alice.issuer + "|carol" };
const dave = { issuer: alice.issuer, subject: "dave", tokenIdentifier: alice.issuer + "|dave" };
const script = {
  title: "SYNTHETIC two-person test scene", duration: 10, locale: "es-ES",
  speakers: [{ id: 0, name: "Fixture A" }, { id: 1, name: "Fixture B" }],
  lines: [{ id: 0, speakerId: 0, text: "Hola", start: 1, end: 3 }, { id: 1, speakerId: 1, text: "Buenos días", start: 4, end: 7 }],
  protectedSpans: [{ start: 1, end: 3.5 }], ownerCharacterId: 0, guestCharacterId: 1, ownerLinesRecorded: 1,
};

async function world() {
  const t = newBackend();
  const a = t.withIdentity(alice), b = t.withIdentity(bob), c = t.withIdentity(carol), d = t.withIdentity(dave);
  for (const [caller, username] of [[a, "alice"], [b, "bob"], [c, "carol"], [d, "dave"]] as const) {
    const { userId } = await caller.mutation(api.users.ensure, {});
    await t.run(async (ctx) => { await ctx.db.patch(userId, { username }); });
  }
  return { t, a, b, c, d };
}

async function asset(t: Backend, caller: ReturnType<Backend["withIdentity"]>): Promise<Id<"socialAssets">> {
  const ticket = await caller.mutation(api.social.prepareUpload, {});
  const storageId = await t.run(async (ctx) => ctx.storage.store(new Blob(["SYNTHETIC video bytes, not a playable recording"], { type: "video/mp4" })));
  await caller.mutation(api.social.finishUpload, { ticketId: ticket.ticketId, storageId });
  return ticket.ticketId;
}

async function connect(sender: ReturnType<Backend["withIdentity"]>, recipient: ReturnType<Backend["withIdentity"]>, username: string): Promise<void> {
  await sender.mutation(api.social.requestFriend, { username });
  const request = (await recipient.query(api.social.snapshot, {})).requests.find((request) => request.incoming);
  if (request === undefined) throw new Error("The synthetic friend request wasn't stored");
  await recipient.mutation(api.social.acceptFriend, { id: request.id });
}

afterEach(() => { vi.unstubAllEnvs(); });

test("social reads and uploads require authentication; friendships require the recipient's acceptance", async () => {
  const { t, a, b } = await world();
  await expect(t.query(api.social.snapshot, {})).rejects.toThrow("Sign in");
  await expect(t.mutation(api.social.prepareUpload, {})).rejects.toThrow("Sign in");
  await a.mutation(api.social.requestFriend, { username: " BOB " });
  const request = (await a.query(api.social.snapshot, {})).requests[0];
  expect(request.incoming).toBe(false);
  await expect(a.mutation(api.social.acceptFriend, { id: request.id })).rejects.toThrow("addressed to you");
  expect((await a.query(api.social.snapshot, {})).friends).toEqual([]);
  await b.mutation(api.social.acceptFriend, { id: request.id });
  expect((await a.query(api.social.snapshot, {})).friends[0].username).toBe("bob");
  await expect(a.mutation(api.social.requestFriend, { username: "alice" })).rejects.toThrow("someone else");
});

test("a shared link can be claimed once, private room reads and source media are limited to its performers", async () => {
  const { t, a, b, c } = await world();
  const assetId = await asset(t, a);
  const invite = await a.mutation(api.social.invite, { assetId, script, clientId: "fixture-invite-1" });
  const repeated = await a.mutation(api.social.invite, { assetId, script, clientId: "fixture-invite-1" });
  expect(repeated).toEqual(invite);
  expect((await a.query(api.social.snapshot, {})).rooms).toHaveLength(1);
  expect((await c.fetch("/social/media/" + assetId)).status).toBe(404);
  await b.mutation(api.social.redeem, { code: invite.code });
  await expect(c.mutation(api.social.redeem, { code: invite.code })).rejects.toThrow("isn't available");
  await expect(c.query(api.social.room, { id: invite.id })).rejects.toThrow("isn't available");
  expect((await b.fetch("/social/media/" + assetId)).status).toBe(200);
  expect((await t.fetch("/social/media/" + assetId)).status).toBe(401);
});

test("combined dubs need every invited line, both posting approvals, and a current friendship to watch from the feed", async () => {
  const { t, a, b, c, d } = await world();
  await connect(a, b, "bob");
  await connect(b, c, "carol");
  const source = await asset(t, a);
  const guestId = (await b.query(api.social.snapshot, {})).me.id;
  const invite = await a.mutation(api.social.invite, { assetId: source, script, recipientId: guestId, clientId: "fixture-complete" });
  await expect(c.mutation(api.social.redeem, { code: invite.code })).rejects.toThrow("isn't available");
  const result = await asset(t, b);
  await expect(b.mutation(api.social.complete, { id: invite.id, assetId: result, linesRecorded: 1 })).rejects.toThrow("Accept");
  await b.mutation(api.social.acceptInvite, { id: invite.id });
  await expect(b.mutation(api.social.complete, { id: invite.id, assetId: result, linesRecorded: 0 })).rejects.toThrow("every line");
  await b.mutation(api.social.complete, { id: invite.id, assetId: result, linesRecorded: 1 });
  await expect(b.mutation(api.social.postSolo, { assetId: result, title: "Not a solo dub", characterName: "Fixture B", linesRecorded: 1 })).rejects.toThrow("both performers");
  await a.mutation(api.social.approvePost, { id: invite.id });
  expect((await c.query(api.social.snapshot, {})).posts).toEqual([]);
  expect((await c.fetch("/social/media/" + result)).status).toBe(404);
  await a.mutation(api.social.withdrawApproval, { id: invite.id });
  await b.mutation(api.social.approvePost, { id: invite.id });
  expect((await c.query(api.social.snapshot, {})).posts).toEqual([]);
  await a.mutation(api.social.approvePost, { id: invite.id });
  const shared = (await c.query(api.social.snapshot, {})).posts;
  expect(shared).toHaveLength(1);
  expect(shared[0]).toMatchObject({ title: script.title, guest: { username: "bob" }, linesRecorded: 1, guestLinesRecorded: 1 });
  expect((await c.fetch("/social/media/" + result)).status).toBe(200);
  expect((await d.fetch("/social/media/" + result)).status).toBe(404);
  await expect(c.mutation(api.social.unpublish, { id: shared[0].id })).rejects.toThrow("isn't available");
  await b.mutation(api.social.removeFriend, { personId: (await c.query(api.social.snapshot, {})).me.id });
  expect((await c.query(api.social.snapshot, {})).posts).toEqual([]);
  expect((await c.fetch("/social/media/" + result)).status).toBe(404);
  await b.mutation(api.social.unpublish, { id: shared[0].id });
  expect((await a.query(api.social.snapshot, {})).posts).toEqual([]);
  expect((await a.query(api.social.room, { id: invite.id })).published).toBe(false);
});

test("upload tickets cannot be finalized by another learner or claim an already-owned file", async () => {
  const { t, a, b } = await world();
  const ticket = await a.mutation(api.social.prepareUpload, {});
  const storageId = await t.run(async (ctx) => ctx.storage.store(new Blob(["synthetic"], { type: "video/mp4" })));
  await expect(b.mutation(api.social.finishUpload, { ticketId: ticket.ticketId, storageId })).rejects.toThrow("isn't yours");
  await a.mutation(api.social.finishUpload, { ticketId: ticket.ticketId, storageId });
  const another = await b.mutation(api.social.prepareUpload, {});
  await expect(b.mutation(api.social.finishUpload, { ticketId: another.ticketId, storageId })).rejects.toThrow("unclaimed");
  const wrongType = await t.run(async (ctx) => ctx.storage.store(new Blob(["not video"], { type: "text/html" })));
  await expect(b.mutation(api.social.finishUpload, { ticketId: another.ticketId, storageId: wrongType })).rejects.toThrow("MP4");
});

test("videos larger than 80 MB can be finalized and posted", async () => {
  const { t, a } = await world();
  const ticket = await a.mutation(api.social.prepareUpload, {});
  const storageId = await t.run(async (ctx) => ctx.storage.store(new Blob([new Uint8Array(80 * 1024 * 1024 + 1)], { type: "video/mp4" })));
  await a.mutation(api.social.finishUpload, { ticketId: ticket.ticketId, storageId });
  await a.mutation(api.social.postSolo, { assetId: ticket.ticketId, title: "Synthetic large video", characterName: "Fixture A", linesRecorded: 1 });
  expect((await a.query(api.social.snapshot, {})).posts[0].assetId).toBe(ticket.ticketId);
});

test.each([1, 31, 121])("co-dub invitations accept a %s-second scene", async (duration: number) => {
  const { t, a, b } = await world();
  const source = await asset(t, a);
  const scale = duration / script.duration;
  const timedScript = {
    ...script, duration,
    lines: script.lines.map((line) => ({ ...line, start: line.start * scale, end: line.end * scale })),
    protectedSpans: script.protectedSpans.map((span) => ({ start: span.start * scale, end: span.end * scale })),
  };
  const invite = await a.mutation(api.social.invite, { assetId: source, script: timedScript, clientId: "fixture-duration" });
  await b.mutation(api.social.redeem, { code: invite.code });
  await b.mutation(api.social.acceptInvite, { id: invite.id });
  expect((await b.query(api.social.room, { id: invite.id })).script).toEqual(timedScript);
});

test("canceling an invitation revokes its source video and prevents a late acceptance", async () => {
  const { t, a, b } = await world();
  const source = await asset(t, a);
  const invite = await a.mutation(api.social.invite, { assetId: source, script, clientId: "fixture-cancel" });
  await b.mutation(api.social.redeem, { code: invite.code });
  await a.mutation(api.social.closeInvite, { id: invite.id });
  await expect(b.mutation(api.social.acceptInvite, { id: invite.id })).rejects.toThrow("open invitation");
  expect((await b.fetch("/social/media/" + source)).status).toBe(404);
});

test("overlapping performances and unowned source videos cannot create invitations", async () => {
  const { t, a, b } = await world();
  const source = await asset(t, a);
  await expect(b.mutation(api.social.invite, { assetId: source, script, clientId: "fixture-stolen" })).rejects.toThrow("isn't available");
  await expect(a.mutation(api.social.invite, { assetId: source, script: { ...script, protectedSpans: [{ start: 1, end: 5 }] }, clientId: "fixture-overlap" })).rejects.toThrow("overlap");
  await expect(a.mutation(api.social.invite, { assetId: source, script: { ...script, ownerLinesRecorded: 0, protectedSpans: [] }, clientId: "fixture-no-takes" })).rejects.toThrow("kept performance");
});

test("solo posts stay friend-only and can be withdrawn by their author", async () => {
  const { t, a, b, c } = await world();
  await connect(a, b, "bob");
  const source = await asset(t, a);
  await a.mutation(api.social.postSolo, { assetId: source, title: "Synthetic solo scene", characterName: "Fixture A", linesRecorded: 1 });
  const post = (await b.query(api.social.snapshot, {})).posts[0];
  expect(post.title).toBe("Synthetic solo scene");
  expect((await c.query(api.social.snapshot, {})).posts).toEqual([]);
  await a.mutation(api.social.unpublish, { id: post.id });
  expect((await b.fetch("/social/media/" + source)).status).toBe(404);
});

test("users.ensure binds a social username only to its verified password-account issuer and subject", async () => {
  const t = newBackend();
  const issuer = "https://synthetic-dubby-issuer.test";
  vi.stubEnv("CONVEX_SITE_URL", issuer);
  const accountId = await t.run(async (ctx) => ctx.db.insert("passwordAccounts", { username: "synthetic-user", passwordHash: "SYNTHETIC_NOT_A_PASSWORD", createdAt: Date.now() }));
  const verified = t.withIdentity({ issuer, subject: accountId, tokenIdentifier: issuer + "|" + accountId });
  await verified.mutation(api.users.ensure, {});
  expect((await verified.query(api.social.snapshot, {})).me.username).toBe("synthetic-user");
  const otherIssuer = t.withIdentity({ issuer: "https://other.test", subject: accountId, tokenIdentifier: "https://other.test|" + accountId });
  await otherIssuer.mutation(api.users.ensure, {});
  await expect(otherIssuer.query(api.social.snapshot, {})).rejects.toThrow("Dubby username");
});
