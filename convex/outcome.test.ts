import { describe, expect, it } from "vitest";
import { assessmentOutcomeSchema } from "./integrations/contracts";
import { InvalidOutputError, validateCoaching, validateOutcome } from "./lib/outcome";
import { acousticProvenance, coachingFixture, scoredOutcome, unscorableOutcome } from "./test.helpers";

const input = {
  assessmentId: "job",
  attemptId: "attempt",
  lineId: "line",
  referenceVersion: 1,
  locale: "en-US",
  recordedAt: "2026-11-15T10:00:00.000Z",
  referenceText: "You underestimate my power.",
  targetWindowMs: { startMs: 1000, endMs: 4000 },
  recordingDurationMs: 3500,
};
const expected = { ...input };

function check(edit: (outcome: ReturnType<typeof scoredOutcome>) => void = () => {}, provenance = acousticProvenance) {
  const outcome = scoredOutcome(input);
  edit(outcome);
  return validateOutcome(outcome, expected, provenance);
}

describe("validateOutcome", () => {
  it("accepts the worked example and counts the reference words", () => {
    expect(check()).toBe(4);
    expect(validateOutcome(unscorableOutcome(input), expected, acousticProvenance)).toBe(0);
  });

  it("rejects an outcome for a different attempt or reference", () => {
    expect(() => check((o) => { o.response.attemptId = "someone-else"; })).toThrow(InvalidOutputError);
    expect(() => check((o) => { o.response.referenceText = "Other text."; })).toThrow(InvalidOutputError);
    expect(() => check((o) => { o.response.referenceVersion = 2; })).toThrow(InvalidOutputError);
  });

  it("requires exactly one unavailable-metric entry per null score", () => {
    expect(() => check((o) => { o.response.scores.timingFit = null; })).toThrow(InvalidOutputError);
    expect(() => check((o) => { o.response.unavailableMetrics = [{ metric: "fluency", reason: "insufficient_evidence" }]; })).toThrow(InvalidOutputError);
    expect(() =>
      check((o) => {
        o.response.scores.timingFit = null;
        o.response.unavailableMetrics = [{ metric: "timingFit", reason: "missing_components" }];
      }),
    ).toThrow(InvalidOutputError);
    expect(() =>
      check((o) => {
        o.response.scores.timingFit = null;
        o.response.unavailableMetrics = [{ metric: "timingFit", reason: "insufficient_evidence" }];
      }),
    ).not.toThrow();
  });

  it("never lets the total hide a missing component", () => {
    expect(() =>
      check((o) => {
        o.response.scores.fluency = null;
        o.response.unavailableMetrics = [{ metric: "fluency", reason: "insufficient_evidence" }];
      }),
    ).toThrow(InvalidOutputError);
    expect(() =>
      check((o) => {
        o.response.scores.fluency = null;
        o.response.scores.languageOverall = null;
        o.response.unavailableMetrics = [
          { metric: "languageOverall", reason: "missing_components" },
          { metric: "fluency", reason: "insufficient_evidence" },
        ];
      }),
    ).not.toThrow();
  });

  it("rejects alignments that skip, repeat, or reorder reference words, or leave the recording", () => {
    expect(() => check((o) => { o.response.wordResults.splice(1, 1); })).toThrow(InvalidOutputError);
    expect(() => check((o) => { o.response.wordResults[1] = o.response.wordResults[0]!; })).toThrow(InvalidOutputError);
    expect(() => check((o) => { o.response.wordResults[0]!.endMs = 9000; })).toThrow(InvalidOutputError);
    expect(() => check((o) => { o.response.wordResults[0]!.startMs = 420; })).toThrow(InvalidOutputError);
  });

  it("requires a reason whenever a word pronunciation is null", () => {
    expect(() => check((o) => { o.response.wordResults[0]!.pronunciationScore = null; })).toThrow(InvalidOutputError);
    expect(() =>
      check((o) => {
        const word = o.response.wordResults[0]!;
        word.pronunciationScore = null;
        word.pronunciationUnavailableReason = "insufficient_evidence";
      }),
    ).not.toThrow();
  });

  it("forces every pronunciation value to null for a transcript-only measurement", () => {
    const transcriptOnly = { ...acousticProvenance, measurement: "transcript_only" as const };
    expect(() => check(() => {}, transcriptOnly)).toThrow(InvalidOutputError);
    expect(() =>
      check((o) => {
        o.response.scores = { languageOverall: null, pronunciation: null, wordAccuracy: 100, fluency: null, timingFit: 90 };
        o.response.unavailableMetrics = [
          { metric: "languageOverall", reason: "missing_components" },
          { metric: "pronunciation", reason: "insufficient_evidence" },
          { metric: "fluency", reason: "insufficient_evidence" },
        ];
        for (const word of o.response.wordResults) {
          word.pronunciationScore = null;
          word.pronunciationUnavailableReason = "insufficient_evidence";
        }
      }, transcriptOnly),
    ).not.toThrow();
    expect(() =>
      check((o) => {
        o.response.scores = { languageOverall: null, pronunciation: null, wordAccuracy: 100, fluency: null, timingFit: 90 };
        o.response.unavailableMetrics = [
          { metric: "languageOverall", reason: "missing_components" },
          { metric: "pronunciation", reason: "insufficient_evidence" },
          { metric: "fluency", reason: "insufficient_evidence" },
        ];
      }, transcriptOnly),
    ).toThrow(InvalidOutputError);
  });
});

describe("outcome schema", () => {
  it("drops unrelated provider fields and rejects scores outside 0 to 100", () => {
    const parsed = assessmentOutcomeSchema.safeParse({ ...scoredOutcome(input), debug: true });
    expect(parsed.success && "debug" in parsed.data).toBe(false);
    const bad = scoredOutcome(input);
    bad.response.scores.fluency = 101;
    expect(assessmentOutcomeSchema.safeParse(bad).success).toBe(false);
  });

  it("rejects an unscorable outcome that carries scores or words", () => {
    const outcome = unscorableOutcome(input);
    expect(assessmentOutcomeSchema.safeParse({ ...outcome, response: { ...outcome.response, scores: { languageOverall: 1 } } }).success).toBe(false);
  });
});

describe("validateCoaching", () => {
  it("rejects word indices outside the reference", () => {
    const coaching = coachingFixture({ focus: [{ kind: "word_accuracy", referenceWordIndex: 4, instruction: "x", practiceText: "y" }] });
    expect(() => validateCoaching(coaching, "scored", 4)).toThrow(InvalidOutputError);
    expect(() => validateCoaching(coaching, "scored", 5)).not.toThrow();
  });

  it("allows only an explanation for an unscorable take", () => {
    expect(() => validateCoaching(coachingFixture(), "unscorable", 0)).toThrow(InvalidOutputError);
    expect(() => validateCoaching(coachingFixture({ strengths: [], focus: [] }), "unscorable", 0)).not.toThrow();
  });
});
