import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { api } from "./_generated/api";
import { coachAssessment } from "./tutoringCoaching";
import { coachingSchema } from "./integrations/contracts";
import { tutoringRefs } from "./tutoringRefs";
import { acousticProvenance, alice, bob, doubles, drain, engineDouble, record, scoredOutcome, startWorld } from "./test.helpers";

// The assessment engine is a test double; coaching is the real tutoring implementation.
vi.mock("./integrations/providers", async () => {
  const { doubles: current } = await import("./test.helpers");
  const { tutoringCoachingProvider } = await import("./tutoringCoaching");
  return { getAssessmentEngine: () => current.engine, getCoachingProvider: () => tutoringCoachingProvider };
});

beforeEach(() => {
  vi.useFakeTimers();
  doubles.engine = engineDouble(async (input) => scoredOutcome(input), acousticProvenance);
});
afterEach(() => {
  vi.useRealTimers();
});

describe("tutoring wired into the assessment pipeline", () => {
  it("ingests a finished assessment for its owner only, and the tutor reads it back", async () => {
    const world = await startWorld();
    const { projectId } = await world.a.mutation(api.projects.start, { sceneId: world.sceneId, characterId: world.characterA });
    const { attemptId } = await record(world.t, world.a, { projectId, lineId: world.line1 });
    await drain(world.t);

    const stored = await world.a.query(api.assessments.forAttempt, { attemptId });
    expect(stored?.job?.status).toBe("succeeded");
    expect(stored?.assessment?.coaching.focus.length).toBeGreaterThan(0);

    const mine = await world.t.withIdentity(alice).query(tutoringRefs.progress, {});
    expect(mine.series).toHaveLength(1);
    expect(mine.series[0]!.volume).toMatchObject({ attempts: 1, scorableAttempts: 1 });
    expect(mine.series[0]!.evaluator).toMatchObject({ provider: "test-double", measurement: "acoustic" });
    expect((await world.t.withIdentity(bob).query(tutoringRefs.progress, {})).series).toEqual([]);
  });
});

describe("coaching from stored measurements", () => {
  const input = (overrides: object = {}) => {
    const outcome = scoredOutcome({ assessmentId: "x", attemptId: "a", lineId: "l", referenceVersion: 1, locale: "en-US", recordedAt: "2026-11-10T10:00:00-08:00", referenceText: "You underestimate my power.", targetWindowMs: { startMs: 0, endMs: 3000 }, recordingDurationMs: 3500 });
    return {
      locale: "en-US",
      referenceText: "You underestimate my power.",
      recognizedText: outcome.response.recognizedText,
      status: "scored" as const,
      reason: null,
      scores: outcome.response.scores,
      wordResults: outcome.response.wordResults,
      evidence: outcome.evidence,
      learner: { userId: "u" },
      ...overrides,
    };
  };

  it("coaches an acoustically weak word and always satisfies the coaching contract", () => {
    const coaching = coachAssessment(input());
    expect(coachingSchema.safeParse(coaching).success).toBe(true);
    expect(coaching.focus.map((item) => item.kind)).toContain("pronunciation");
  });

  it("never gives pronunciation or fluency coaching without those measurements", () => {
    const base = input();
    const scores = { ...base.scores!, pronunciation: null, fluency: null, languageOverall: null };
    const words = base.wordResults.map((word, index) => ({ ...word, pronunciationScore: null, textStatus: index === 1 ? ("substituted" as const) : word.textStatus, recognized: index === 1 ? "estimate" : word.recognized }));
    const coaching = coachAssessment(input({ scores, wordResults: words }));
    expect(coaching.focus.map((item) => item.kind)).toEqual(["word_accuracy"]);
    expect(coaching.strengths.join(" ")).not.toMatch(/pronunciation|smoothly/);
  });

  it("gives an unscorable take no strengths or focus", () => {
    const coaching = coachAssessment(input({ status: "unscorable", reason: "no_speech", scores: null, wordResults: [] }));
    expect(coaching).toMatchObject({ strengths: [], focus: [] });
  });
});
