/// <reference types="vite/client" />
import { convexTest } from "convex-test";
import { expect, vi } from "vitest";
import { api, internal } from "./_generated/api";
import type { Id } from "./_generated/dataModel";
import type {
  AssessAttemptInput,
  AssessmentEngine,
  AssessmentOutcome,
  Coaching,
  CoachingProvider,
  EngineProvenance,
} from "./integrations/contracts";
import schema from "./schema";

// Everything here is a synthetic test fixture. Nothing models a real scene, recording, provider
// response, or score.

export const modules = import.meta.glob(["./**/*.ts", "./_generated/*.js", "!./**/*.test.ts", "!./test.helpers.ts", "!./**/*.d.ts"]);

export const alice = { issuer: "https://issuer.fixture.test", subject: "alice", tokenIdentifier: "https://issuer.fixture.test|alice" };
export const bob = { issuer: "https://issuer.fixture.test", subject: "bob", tokenIdentifier: "https://issuer.fixture.test|bob" };

/** The engine and coaching implementations the mocked providers module hands to the job runner. */
export const doubles: { engine: AssessmentEngine | null; coach: CoachingProvider | null } = { engine: null, coach: null };

export const fixtureText = "You underestimate my power.";

export const acousticProvenance: EngineProvenance = {
  provider: "test-double",
  providerModelVersion: null,
  configVersion: "test-1",
  measurement: "acoustic",
};

type ScoredOutcome = { response: Extract<AssessmentOutcome["response"], { status: "scored" }>; evidence: AssessmentOutcome["evidence"] };

const evidenceBase: AssessmentOutcome["evidence"] = {
  provider: { name: "test-double", locale: "en-US", recognitionStatus: "Success", snr: null, completenessScore: null },
  normalizationVersion: "test-1",
  rawScores: { pronunciation: 82, wordAccuracy: 100, fluency: 80, languageOverall: 87.9, timingFit: 90 },
  referenceTokenCount: 4,
  counts: { matched: 4, substituted: 0, omitted: 0, inserted: 0 },
  words: { mispronounced: [1], substituted: [], omitted: [], inserted: 0 },
  timing: { spokenStartMs: 200, spokenEndMs: 2900, spokenDurationMs: 2700, targetDurationMs: 3000, deltaMs: -300 },
  unscorableReason: null,
};

/** An engine result for the line in `input`, matching the worked example in the grading contract. */
export function scoredOutcome(input: AssessAttemptInput): ScoredOutcome {
  const word = (index: number, text: string, score: number, startMs: number, endMs: number) => ({
    referenceWordIndex: index,
    expected: text,
    recognized: text,
    textStatus: "matched" as const,
    pronunciationScore: score,
    startMs,
    endMs,
  });
  return {
    response: {
      schemaVersion: 1,
      rubricVersion: "language-v1",
      assessmentId: input.assessmentId,
      attemptId: input.attemptId,
      lineId: input.lineId,
      referenceVersion: input.referenceVersion,
      locale: input.locale,
      recordedAt: input.recordedAt,
      referenceText: input.referenceText,
      recognizedText: input.referenceText,
      status: "scored",
      scores: { languageOverall: 88, pronunciation: 82, wordAccuracy: 100, fluency: 80, timingFit: 90 },
      unavailableMetrics: [],
      wordResults: [word(0, "You", 96, 200, 420), word(1, "underestimate", 64, 430, 1550), word(2, "my", 93, 1650, 1880), word(3, "power", 91, 2000, 2900)],
    },
    evidence: structuredClone(evidenceBase),
  };
}

export function unscorableOutcome(input: AssessAttemptInput): AssessmentOutcome {
  const { response } = scoredOutcome(input);
  return {
    response: {
      schemaVersion: 1,
      rubricVersion: "language-v1",
      assessmentId: response.assessmentId,
      attemptId: response.attemptId,
      lineId: response.lineId,
      referenceVersion: response.referenceVersion,
      locale: response.locale,
      recordedAt: response.recordedAt,
      referenceText: response.referenceText,
      recognizedText: null,
      status: "unscorable",
      reason: "no_speech",
      scores: null,
      unavailableMetrics: [],
      wordResults: [],
    },
    evidence: {
      ...structuredClone(evidenceBase),
      rawScores: { pronunciation: null, wordAccuracy: null, fluency: null, languageOverall: null, timingFit: null },
      referenceTokenCount: 0,
      counts: { matched: 0, substituted: 0, omitted: 0, inserted: 0 },
      words: { mispronounced: [], substituted: [], omitted: [], inserted: 0 },
      timing: null,
      unscorableReason: "no_speech",
    },
  };
}

export function engineDouble(
  assess: (input: AssessAttemptInput) => AssessmentOutcome | Promise<AssessmentOutcome> = scoredOutcome,
  provenance: EngineProvenance = acousticProvenance,
): AssessmentEngine {
  return { provenance, assess: async (input) => await assess(input) };
}

export function coachingFixture(overrides: Partial<Coaching> = {}): Coaching {
  return {
    summary: "Fixture coaching summary.",
    strengths: ["Fixture strength."],
    focus: [{ kind: "pronunciation", referenceWordIndex: 1, instruction: "Fixture instruction.", practiceText: "underestimate" }],
    provider: "test-double",
    configVersion: "test-1",
    ...overrides,
  };
}

export function newBackend() {
  return convexTest(schema, modules);
}
export type Backend = ReturnType<typeof newBackend>;

export const fixtureLineIds = ["fixture-line-01", "fixture-line-02", "fixture-line-03"] as const;

const manifestBase = () => ({
  schemaVersion: 1 as const,
  sceneId: "synthetic-fixture-scene",
  title: "SYNTHETIC TEST FIXTURE scene",
  synopsis: "A synthetic scene used only by tests.",
  locale: "en-US",
  durationSeconds: 10,
  published: true,
  provenance: { work: "synthetic test fixture", creator: "tests", license: "none; never shipped", attribution: "none" },
  characters: [
    { id: "fixture-a", displayName: "Fixture Character A" },
    { id: "fixture-b", displayName: "Fixture Character B" },
  ],
  lines: [
    { id: fixtureLineIds[0] as string, characterId: "fixture-a", start: 1, end: 4, text: fixtureText, referenceVersion: 1 },
    { id: fixtureLineIds[1] as string, characterId: "fixture-a", start: 4.5, end: 6, text: "Fixture line two.", referenceVersion: 1 },
    { id: fixtureLineIds[2] as string, characterId: "fixture-b", start: 6.5, end: 8, text: "Fixture line three.", referenceVersion: 1 },
  ],
});

/** A clearly labeled synthetic manifest: two characters, three lines. */
export function fixtureManifest(overrides: Partial<ReturnType<typeof manifestBase>> = {}) {
  return { ...manifestBase(), ...overrides };
}

export async function seedFixture(t: Backend) {
  const { sceneId } = await t.mutation(internal.scenes.seed, fixtureManifest());
  return await t.run(async (ctx) => {
    const characters = await ctx.db.query("characters").collect();
    const lines = await ctx.db.query("referenceLines").collect();
    const character = (slug: string) => characters.find((c) => c.slug === slug)!._id;
    const line = (key: string) => lines.find((l) => l.lineKey === key)!._id;
    return {
      sceneId,
      characterA: character("fixture-a"),
      characterB: character("fixture-b"),
      line1: line(fixtureLineIds[0]),
      line2: line(fixtureLineIds[1]),
      line3: line(fixtureLineIds[2]),
    };
  });
}

export async function startWorld() {
  const t = newBackend();
  const fixture = await seedFixture(t);
  const a = t.withIdentity(alice);
  const b = t.withIdentity(bob);
  await a.mutation(api.users.ensure, {});
  await b.mutation(api.users.ensure, {});
  await a.mutation(api.users.setTimeZone, { timeZone: "America/Los_Angeles" });
  await b.mutation(api.users.setTimeZone, { timeZone: "Europe/Paris" });
  return { t, a, b, ...fixture };
}
export type World = Awaited<ReturnType<typeof startWorld>>;

export async function upload(t: Backend, type = "audio/wav", size = 2048): Promise<Id<"_storage">> {
  return await t.run(async (ctx) => await ctx.storage.store(new Blob([new Uint8Array(size).fill(7)], { type })));
}

type Caller = ReturnType<Backend["withIdentity"]>;

export async function record(
  t: Backend,
  user: Caller,
  input: { projectId: Id<"projects">; lineId: Id<"referenceLines">; clientAttemptId?: string; storageId?: Id<"_storage">; durationMs?: number },
) {
  const storageId = input.storageId ?? (await upload(t));
  return await user.mutation(api.attempts.create, {
    projectId: input.projectId,
    lineId: input.lineId,
    clientAttemptId: input.clientAttemptId ?? crypto.randomUUID(),
    storageId,
    durationMs: input.durationMs ?? 3500,
    capturedAt: Date.now() - 1000,
  });
}

export async function expectAppError(promise: Promise<unknown>, code: string) {
  const error = await promise.then(
    () => null,
    (caught: unknown) => caught,
  );
  expect(error, `expected a ${code} error`).not.toBeNull();
  expect((error as { data?: { code?: string } }).data?.code).toBe(code);
}

export async function drain(t: Backend) {
  await t.finishAllScheduledFunctions(vi.runAllTimers);
}
