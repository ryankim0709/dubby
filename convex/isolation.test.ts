import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { api } from "./_generated/api";
import { type World, bob, expectAppError, record, startWorld, upload } from "./test.helpers";

let world: World;

async function aliceProject() {
  const { projectId } = await world.a.mutation(api.projects.start, { sceneId: world.sceneId, characterId: world.characterA });
  return projectId;
}

beforeEach(async () => {
  vi.useFakeTimers();
  world = await startWorld();
});
afterEach(() => {
  vi.useRealTimers();
});

describe("two identities", () => {
  it("hides another user's project, attempts, assessments, and history as if they did not exist", async () => {
    const projectId = await aliceProject();
    const { attemptId, jobId } = await record(world.t, world.a, { projectId, lineId: world.line1 });
    await world.a.mutation(api.takes.accept, { attemptId });

    expect(await world.b.query(api.projects.get, { projectId })).toBeNull();
    expect(await world.b.query(api.attempts.listForLine, { projectId, lineId: world.line1 })).toBeNull();
    expect(await world.b.query(api.assessments.forAttempt, { attemptId })).toBeNull();
    expect(await world.b.query(api.history.list, {})).toEqual([]);
    expect(await world.a.query(api.history.list, {})).toHaveLength(1);

    await expectAppError(world.b.mutation(api.takes.accept, { attemptId }), "NOT_FOUND");
    await expectAppError(world.b.mutation(api.projects.complete, { projectId }), "NOT_FOUND");
    await expectAppError(world.b.mutation(api.assessments.retry, { jobId }), "NOT_FOUND");
    await expectAppError(record(world.t, world.b, { projectId, lineId: world.line1 }), "NOT_FOUND");
  });

  it("does not let a user claim another user's uploaded recording", async () => {
    const projectId = await aliceProject();
    const storageId = await upload(world.t);
    await record(world.t, world.a, { projectId, lineId: world.line1, storageId });

    const { projectId: bobProject } = await world.b.mutation(api.projects.start, { sceneId: world.sceneId, characterId: world.characterA });
    await expectAppError(record(world.t, world.b, { projectId: bobProject, lineId: world.line1, storageId }), "INVALID_UPLOAD");
    await expectAppError(record(world.t, world.a, { projectId, lineId: world.line2, storageId }), "INVALID_UPLOAD");
  });

  it("rejects every call without an identity", async () => {
    const projectId = await aliceProject();
    const { attemptId, jobId } = await record(world.t, world.a, { projectId, lineId: world.line1 });
    const t = world.t;
    await expectAppError(t.mutation(api.users.ensure, {}), "UNAUTHENTICATED");
    await expectAppError(t.mutation(api.users.setTimeZone, { timeZone: "UTC" }), "UNAUTHENTICATED");
    await expectAppError(t.query(api.scenes.list, {}), "UNAUTHENTICATED");
    await expectAppError(t.mutation(api.projects.start, { sceneId: world.sceneId, characterId: world.characterA }), "UNAUTHENTICATED");
    await expectAppError(t.query(api.projects.get, { projectId }), "UNAUTHENTICATED");
    await expectAppError(t.mutation(api.attempts.generateUploadUrl, {}), "UNAUTHENTICATED");
    await expectAppError(record(t, t, { projectId, lineId: world.line1 }), "UNAUTHENTICATED");
    await expectAppError(t.query(api.assessments.forAttempt, { attemptId }), "UNAUTHENTICATED");
    await expectAppError(t.mutation(api.assessments.retry, { jobId }), "UNAUTHENTICATED");
    await expectAppError(t.mutation(api.takes.accept, { attemptId }), "UNAUTHENTICATED");
    await expectAppError(t.mutation(api.projects.complete, { projectId }), "UNAUTHENTICATED");
    await expectAppError(t.query(api.history.list, {}), "UNAUTHENTICATED");
  });

  it("asks a signed-in user who never called users.ensure to register first", async () => {
    const stranger = world.t.withIdentity({ ...bob, subject: "carol", tokenIdentifier: "https://issuer.fixture.test|carol" });
    await expectAppError(stranger.query(api.history.list, {}), "USER_NOT_FOUND");
    const { userId, created } = await stranger.mutation(api.users.ensure, {});
    expect(created).toBe(true);
    expect(await stranger.mutation(api.users.ensure, {})).toEqual({ userId, created: false });
  });
});

describe("recording uploads", () => {
  it("returns the existing attempt and job when the app repeats a create", async () => {
    const projectId = await aliceProject();
    const clientAttemptId = crypto.randomUUID();
    const storageId = await upload(world.t);
    const first = await record(world.t, world.a, { projectId, lineId: world.line1, clientAttemptId, storageId });
    const second = await record(world.t, world.a, { projectId, lineId: world.line1, clientAttemptId, storageId });
    expect(second).toEqual(first);
    expect(await world.t.run(async (ctx) => (await ctx.db.query("attempts").collect()).length)).toBe(1);
    expect(await world.t.run(async (ctx) => (await ctx.db.query("assessmentJobs").collect()).length)).toBe(1);
    await expectAppError(record(world.t, world.a, { projectId, lineId: world.line2, clientAttemptId, storageId }), "CONFLICT");
  });

  it("treats the same client attempt id from two users as two attempts", async () => {
    const projectId = await aliceProject();
    const { projectId: bobProject } = await world.b.mutation(api.projects.start, { sceneId: world.sceneId, characterId: world.characterA });
    const clientAttemptId = crypto.randomUUID();
    const first = await record(world.t, world.a, { projectId, lineId: world.line1, clientAttemptId });
    const second = await record(world.t, world.b, { projectId: bobProject, lineId: world.line1, clientAttemptId });
    expect(second.attemptId).not.toBe(first.attemptId);
  });

  it("validates the upload, the line, the capture time, and the time zone", async () => {
    const projectId = await aliceProject();
    await expectAppError(record(world.t, world.a, { projectId, lineId: world.line1, storageId: await upload(world.t, "audio/mp4") }), "INVALID_UPLOAD");
    await expectAppError(record(world.t, world.a, { projectId, lineId: world.line1, storageId: await upload(world.t, "audio/wav", 10 * 1024 * 1024 + 1) }), "INVALID_UPLOAD");
    await expectAppError(record(world.t, world.a, { projectId, lineId: world.line3 }), "INVALID_ARGUMENT");
    await expectAppError(record(world.t, world.a, { projectId, lineId: world.line1, durationMs: 30_001 }), "INVALID_ARGUMENT");
    await expectAppError(record(world.t, world.a, { projectId, lineId: world.line1, clientAttemptId: "not-a-uuid" }), "INVALID_ARGUMENT");

    const base = { projectId, lineId: world.line1, durationMs: 2000 };
    const mint = async () => ({ ...base, clientAttemptId: crypto.randomUUID(), storageId: await upload(world.t, "audio/wav") });
    await expectAppError(world.a.mutation(api.attempts.create, { ...(await mint()), capturedAt: Date.now() + 3_600_000 }), "INVALID_ARGUMENT");
    await expectAppError(world.a.mutation(api.attempts.create, { ...(await mint()), capturedAt: Date.now() - 90 * 86_400_000 }), "INVALID_ARGUMENT");
    await expectAppError(world.a.mutation(api.attempts.create, { ...(await mint()), capturedAt: Date.now(), timeZone: "Mars/Olympus" }), "INVALID_ARGUMENT");
    const ok = await world.a.mutation(api.attempts.create, { ...(await mint()), capturedAt: Date.now(), timeZone: "Asia/Tokyo" });
    expect((await world.t.run(async (ctx) => await ctx.db.get("attempts", ok.attemptId)))?.timeZone).toBe("Asia/Tokyo");
  });

  it("falls back to the profile time zone and asks for one when neither exists", async () => {
    const projectId = await aliceProject();
    const { attemptId } = await record(world.t, world.a, { projectId, lineId: world.line1 });
    expect((await world.t.run(async (ctx) => await ctx.db.get("attempts", attemptId)))?.timeZone).toBe("America/Los_Angeles");

    const drifter = world.t.withIdentity({ ...bob, subject: "dana", tokenIdentifier: "https://issuer.fixture.test|dana" });
    await drifter.mutation(api.users.ensure, {});
    const { projectId: p } = await drifter.mutation(api.projects.start, { sceneId: world.sceneId, characterId: world.characterA });
    await expectAppError(record(world.t, drifter, { projectId: p, lineId: world.line1 }), "INVALID_ARGUMENT");
  });
});

describe("accepted takes and completion", () => {
  it("moves only the pointer when a newer take is accepted", async () => {
    const projectId = await aliceProject();
    const first = await record(world.t, world.a, { projectId, lineId: world.line1 });
    const second = await record(world.t, world.a, { projectId, lineId: world.line1 });
    await world.a.mutation(api.takes.accept, { attemptId: first.attemptId });
    const moved = await world.a.mutation(api.takes.accept, { attemptId: second.attemptId });
    expect(moved.replacedAttemptId).toBe(first.attemptId);

    const project = await world.a.query(api.projects.get, { projectId });
    expect(project?.acceptedTakes).toMatchObject([{ lineId: world.line1, attemptId: second.attemptId }]);
    const attempts = await world.a.query(api.attempts.listForLine, { projectId, lineId: world.line1 });
    expect(attempts?.map((a) => [a.attemptId, a.accepted])).toEqual([
      [second.attemptId, true],
      [first.attemptId, false],
    ]);
    expect(await world.t.run(async (ctx) => (await ctx.db.query("assessmentJobs").collect()).length)).toBe(2);
  });

  it("completes only when every line of the character has an accepted take", async () => {
    const projectId = await aliceProject();
    const one = await record(world.t, world.a, { projectId, lineId: world.line1 });
    await world.a.mutation(api.takes.accept, { attemptId: one.attemptId });
    await expect(world.a.mutation(api.projects.complete, { projectId })).rejects.toMatchObject({
      data: { code: "INCOMPLETE_TAKES", missingLineKeys: ["fixture-line-02"] },
    });

    const two = await record(world.t, world.a, { projectId, lineId: world.line2 });
    await world.a.mutation(api.takes.accept, { attemptId: two.attemptId });
    const done = await world.a.mutation(api.projects.complete, { projectId });
    expect(await world.a.mutation(api.projects.complete, { projectId })).toEqual(done);

    const history = await world.a.query(api.history.list, { status: "completed" });
    expect(history).toMatchObject([{ projectId, status: "completed", acceptedLineCount: 2, lineCount: 2, sceneTitle: "SYNTHETIC TEST FIXTURE scene" }]);
    await expectAppError(world.a.mutation(api.takes.accept, { attemptId: one.attemptId }), "INVALID_STATE");
    await expectAppError(record(world.t, world.a, { projectId, lineId: world.line1 }), "INVALID_STATE");
    const restarted = await world.a.mutation(api.projects.start, { sceneId: world.sceneId, characterId: world.characterA });
    expect(restarted.created).toBe(true);
  });

  it("returns the same project when a start is repeated while active", async () => {
    const first = await world.a.mutation(api.projects.start, { sceneId: world.sceneId, characterId: world.characterA });
    const second = await world.a.mutation(api.projects.start, { sceneId: world.sceneId, characterId: world.characterA });
    expect(second).toEqual({ projectId: first.projectId, created: false });
  });
});
