import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { api } from "./_generated/api";
import { type DubScoreSheet, practicePlan } from "./liveTutor";
import { alice, bob, newBackend, upload } from "./test.helpers";

// Everything here is a synthetic fixture: invented lines and transcripts, and uploads that are never graded.

type SheetLine = DubScoreSheet["lines"][number];
type Word = SheetLine["words"][number];

const matched = (text: string): Word => ({ expected: text, recognized: text, textStatus: "matched" });

function line(lineIndex: number, referenceText: string, status: SheetLine["status"], words: Word[], reason: string | null): SheetLine {
  return { lineIndex, referenceText, status, recognizedText: null, lineScore: null, wordAccuracy: null, timingFit: null, reason, coachingSummary: null, words };
}

const post = (body: object): RequestInit => ({ method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
const clientDubId = "6f1c1e0e-0000-4000-8000-0000000000aa";

describe("live tutor practice plan", () => {
  it("picks lines with word differences or no speech, in scene order, and keeps word-perfect lines for polishing", () => {
    const plan = practicePlan([
      line(3, "Fixture line three.", "unscorable", [], "no_speech"),
      line(0, "Fixture line one.", "scored", [matched("Fixture"), matched("line"), matched("one")], null),
      line(1, "Fixture line two.", "scored", [matched("Fixture"), { expected: "line", recognized: "lime", textStatus: "substituted" }, { expected: "two", recognized: null, textStatus: "omitted" }], null),
      line(2, "Fixture line four.", "failed", [], "provider_unavailable"),
      line(4, "Fixture line five.", "unscorable", [], "unsupported_locale"),
    ]);
    expect(plan.toFix.map((target) => target.lineIndex)).toEqual([1, 3]);
    expect(plan.toFix[0]?.findings).toEqual([`said "lime" instead of "line"`, `left out "two"`]);
    expect(plan.wordPerfect).toEqual(["Fixture line one."]);
  });
});

describe("POST /tutor/live-session", () => {
  let fetchSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    // Keeps the submitted dub's grading jobs from running, so it stays mid-scoring.
    vi.useFakeTimers();
    vi.stubEnv("OPENAI_API_KEY", "fixture-openai-key-do-not-use");
    fetchSpy = vi.spyOn(globalThis, "fetch");
  });
  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllEnvs();
    fetchSpy.mockRestore();
  });

  it("answers 401 without an identity, before reading the body or calling OpenAI", async () => {
    const response = await newBackend().fetch("/tutor/live-session", post({ clientDubId }));
    expect(response.status).toBe(401);
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it("only opens a session for the caller's own dub once it has finished scoring", async () => {
    const t = newBackend();
    const a = t.withIdentity(alice);
    const b = t.withIdentity(bob);
    await a.mutation(api.users.ensure, {});
    await b.mutation(api.users.ensure, {});
    await a.mutation(api.dubs.submit, {
      clientDubId,
      sceneTitle: "SYNTHETIC fixture scene",
      characterName: "Fixture hero",
      locale: "en-US",
      timeZone: "America/Los_Angeles",
      capturedAt: Date.now(),
      takes: [{ lineIndex: 0, referenceText: "Fixture line one.", startMs: 1000, endMs: 3000, storageId: await upload(t) }],
    });

    const scoring = await a.fetch("/tutor/live-session", post({ clientDubId }));
    expect(scoring.status).toBe(409);
    expect(await scoring.json()).toEqual({ error: expect.any(String), code: "still_scoring" });

    const someoneElse = await b.fetch("/tutor/live-session", post({ clientDubId }));
    expect(someoneElse.status).toBe(404);
    expect(await someoneElse.json()).toEqual({ error: expect.any(String), code: "not_found" });

    expect((await a.fetch("/tutor/live-session", post({ clientDubId: "not-a-uuid" }))).status).toBe(400);
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it.each([
    { characterName: "Anakin Skywalker", voice: "ash" },
    { characterName: "Obi-Wan Kenobi", voice: "cedar" },
    { characterName: "Fixture hero", voice: "marin" },
  ])("opens the completed dub's practice session with $voice for $characterName", async ({ characterName, voice }) => {
    const voices: string[] = [];
    fetchSpy.mockImplementation(async (_input: string | URL | Request, init?: RequestInit) => {
      const body: { session: { audio: { output: { voice: string } } } } = JSON.parse(String(init?.body));
      voices.push(body.session.audio.output.voice);
      return Response.json({ value: "ek_fixture", expires_at: 1_800_000_000, session: {} });
    });
    const t = newBackend();
    const a = t.withIdentity(alice);
    await a.mutation(api.users.ensure, {});
    const { dubId } = await a.mutation(api.dubs.submit, {
      clientDubId,
      sceneTitle: "SYNTHETIC fixture scene",
      characterName,
      locale: "en-US",
      timeZone: "America/Los_Angeles",
      capturedAt: Date.now(),
      takes: [{ lineIndex: 0, referenceText: "Fixture line one.", startMs: 1000, endMs: 3000, storageId: await upload(t) }],
    });
    await t.run(async (ctx) => {
      const takes = await ctx.db.query("dubTakes").withIndex("by_dub", (q) => q.eq("dubId", dubId)).collect();
      for (const take of takes) {
        await ctx.db.patch(take._id, { status: "failed", failure: { code: "provider_unavailable", message: "Synthetic grading failure" } });
      }
      await ctx.db.patch(dubId, { status: "complete", completedAt: Date.now() });
    });

    const response = await a.fetch("/tutor/live-session", post({ clientDubId }));
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ clientSecret: "ek_fixture" });
    expect(voices).toEqual([voice]);
  });
});

describe("POST /tutor/take-coach", () => {
  let fetchSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    vi.stubEnv("OPENAI_API_KEY", "fixture-openai-key-do-not-use");
    fetchSpy = vi.spyOn(globalThis, "fetch");
  });
  afterEach(() => {
    vi.unstubAllEnvs();
    fetchSpy.mockRestore();
  });

  const scene = { sceneTitle: "SYNTHETIC fixture scene", characterName: "Fixture hero", locale: "en-US" };

  it("answers 401 without an identity and 400 for a bad scene, before calling OpenAI", async () => {
    const t = newBackend();
    expect((await t.fetch("/tutor/take-coach", post(scene))).status).toBe(401);
    const a = t.withIdentity(alice);
    expect((await a.fetch("/tutor/take-coach", post({ ...scene, locale: "English" }))).status).toBe(400);
    expect((await a.fetch("/tutor/take-coach", post({ ...scene, characterName: "  " }))).status).toBe(400);
    expect((await a.fetch("/tutor/take-coach", post({ ...scene, referencePitchHz: -1 }))).status).toBe(400);
    expect((await a.fetch("/tutor/take-coach", post({ ...scene, characterLines: [" "] }))).status).toBe(400);
    expect((await a.fetch("/tutor/take-coach", post({ ...scene, characterLines: Array(13).fill("Fixture line.") }))).status).toBe(400);
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it("gives a speaker who is a coach that coach's voice and avatar, and anyone else the tutor's voice and no avatar", async () => {
    const voices: string[] = [];
    fetchSpy.mockImplementation(async (_input: string | URL | Request, init?: RequestInit) => {
      voices.push((JSON.parse(String(init?.body)) as { session: { audio: { output: { voice: string } } } }).session.audio.output.voice);
      return Response.json({ value: "ek_fixture", expires_at: 1_800_000_000, session: {} });
    });
    const a = newBackend().withIdentity(alice);

    const anakin = await a.fetch("/tutor/take-coach", post({ ...scene, characterName: "Anakin Skywalker" }));
    expect(await anakin.json()).toMatchObject({ clientSecret: "ek_fixture", avatarCharacterId: "anakin" });
    const obiWan = await a.fetch("/tutor/take-coach", post({ ...scene, characterName: "Obi-Wan Kenobi" }));
    expect(await obiWan.json()).toMatchObject({ clientSecret: "ek_fixture", avatarCharacterId: "obi-wan" });
    const someoneElse = await a.fetch("/tutor/take-coach", post(scene));
    expect(await someoneElse.json()).not.toHaveProperty("avatarCharacterId");
    expect(voices).toEqual(["ash", "cedar", "marin"]);
  });
});
