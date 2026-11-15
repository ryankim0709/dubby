import assert from "node:assert/strict";
import test from "node:test";
import { AssessmentValidationError, validateAssessmentResponse } from "../../convex/assessment/index";

// SYNTHETIC contract responses used only to exercise the validator.
const word = (index: number | null, expected: string | null, recognized: string | null, textStatus: string, score: number | null, start: number | null, end: number | null, reason?: string) => ({
  referenceWordIndex: index,
  expected,
  recognized,
  textStatus,
  pronunciationScore: score,
  ...(reason ? { pronunciationUnavailableReason: reason } : {}),
  startMs: start,
  endMs: end,
});

const scored = () => ({
  schemaVersion: 1,
  rubricVersion: "language-v1",
  assessmentId: "assessment_001",
  attemptId: "take_003",
  lineId: "scene_001_line_02",
  referenceVersion: 1,
  locale: "en-US",
  recordedAt: "2026-11-14T18:00:00-08:00",
  status: "scored",
  referenceText: "You underestimate my power.",
  recognizedText: "You underestimate power.",
  scores: { languageOverall: 80, pronunciation: 82, wordAccuracy: 75, fluency: 80, timingFit: 90 } as Record<string, number | null>,
  unavailableMetrics: [] as Array<Record<string, unknown>>,
  wordResults: [
    word(0, "You", "You", "matched", 96, 200, 420),
    word(1, "underestimate", "underestimate", "matched", 64, 430, 1550),
    word(2, "my", null, "omitted", null, null, null, "omitted_word"),
    word(3, "power", "power", "matched", 91, 2000, 2900),
  ],
  coaching: {
    summary: "You skipped 'my'.",
    strengths: [],
    focus: [{ kind: "word_accuracy", referenceWordIndex: 2, instruction: "Say 'my' before 'power'.", practiceText: "my power" }] as Array<Record<string, unknown>>,
  },
});

const unscorable = () => ({
  schemaVersion: 1,
  rubricVersion: "language-v1",
  assessmentId: "assessment_002",
  attemptId: "take_004",
  lineId: "scene_001_line_02",
  referenceVersion: 1,
  locale: "en-US",
  recordedAt: "2026-11-14T18:00:00Z",
  status: "unscorable",
  reason: "no_speech",
  referenceText: "You underestimate my power.",
  recognizedText: null,
  scores: null,
  unavailableMetrics: [],
  wordResults: [],
  coaching: { summary: "We could not hear speech. Move closer and try again.", strengths: [], focus: [] },
});

function issuesOf(value: unknown, options = {}): string[] {
  try {
    validateAssessmentResponse(value, options);
  } catch (error) {
    assert.ok(error instanceof AssessmentValidationError);
    return error.issues;
  }
  return [];
}

test("valid scored and unscorable responses pass", () => {
  assert.deepEqual(issuesOf(scored(), { recordingDurationMs: 3200 }), []);
  assert.deepEqual(issuesOf(unscorable()), []);
});

test("null scores need exactly one unavailableMetrics entry with the right reason", () => {
  const response = scored();
  response.scores = { languageOverall: null, pronunciation: 82, wordAccuracy: 75, fluency: null, timingFit: null };
  assert.ok(issuesOf(response).some((issue) => issue.includes("must explain null metric fluency")));

  response.unavailableMetrics = [
    { metric: "fluency", reason: "unsupported_locale" },
    { metric: "timingFit", reason: "insufficient_evidence" },
    { metric: "languageOverall", reason: "missing_components" },
  ];
  assert.deepEqual(issuesOf(response), []);

  response.unavailableMetrics = [...response.unavailableMetrics, { metric: "fluency", reason: "insufficient_evidence" }];
  assert.ok(issuesOf(response).some((issue) => issue.includes("duplicates fluency")));

  response.unavailableMetrics = [{ metric: "fluency", reason: "missing_components" }];
  assert.ok(issuesOf(response).some((issue) => issue.includes("missing_components only for languageOverall")));

  const measured = scored();
  measured.unavailableMetrics = [{ metric: "pronunciation", reason: "insufficient_evidence" }];
  assert.ok(issuesOf(measured).some((issue) => issue.includes("must not list measured metric pronunciation")));
});

test("languageOverall must be null exactly when a component is missing", () => {
  const response = scored();
  response.scores.fluency = null;
  response.unavailableMetrics = [{ metric: "fluency", reason: "insufficient_evidence" }];
  assert.ok(issuesOf(response).some((issue) => issue.includes("languageOverall must be null")));
});

test("an empty alignment requires wordAccuracy to be unavailable", () => {
  const response = scored();
  response.wordResults = [];
  assert.ok(issuesOf(response).some((issue) => issue.includes("wordResults may be empty only")));
  response.scores.wordAccuracy = null;
  response.scores.languageOverall = null;
  response.unavailableMetrics = [
    { metric: "wordAccuracy", reason: "insufficient_evidence" },
    { metric: "languageOverall", reason: "missing_components" },
  ];
  assert.deepEqual(issuesOf(response), []);
});

test("alignment coverage, ordering and wordAccuracy consistency are enforced", () => {
  const skipped = scored();
  skipped.wordResults = [skipped.wordResults[0]!, skipped.wordResults[2]!, skipped.wordResults[3]!];
  assert.ok(issuesOf(skipped).some((issue) => issue.includes("each reference token appears once, in order")));

  const wrongScore = scored();
  wrongScore.scores.wordAccuracy = 100;
  assert.ok(issuesOf(wrongScore).some((issue) => issue.includes("does not match the substitutions")));

  const insertion = scored();
  insertion.wordResults.push(word(null, null, "uh", "inserted", null, 3000, 3100, "unaligned_word"));
  insertion.scores.wordAccuracy = 50;
  assert.deepEqual(issuesOf(insertion), []);
});

test("word timestamps and pronunciation reasons are checked", () => {
  const outOfBounds = scored();
  outOfBounds.wordResults[3] = word(3, "power", "power", "matched", 91, 2000, 3300);
  assert.ok(issuesOf(outOfBounds, { recordingDurationMs: 3200 }).some((issue) => issue.includes("exceeds the recording duration")));

  const reversed = scored();
  reversed.wordResults[0] = word(0, "You", "You", "matched", 96, 500, 400);
  assert.ok(issuesOf(reversed).some((issue) => issue.includes("0 <= startMs < endMs")));

  const noReason = scored();
  noReason.wordResults[1] = word(1, "underestimate", "underestimate", "matched", null, 430, 1550);
  assert.ok(issuesOf(noReason).some((issue) => issue.includes("pronunciationUnavailableReason is required")));

  const extraReason = scored();
  extraReason.wordResults[0] = word(0, "You", "You", "matched", 96, 200, 420, "insufficient_evidence");
  assert.ok(issuesOf(extraReason).some((issue) => issue.includes("must be absent")));

  const scoredOmission = scored();
  scoredOmission.wordResults[2] = word(2, "my", null, "omitted", 50, null, null);
  assert.ok(issuesOf(scoredOmission).some((issue) => issue.includes("must be null for an omission")));
});

test("coaching and unscorable shape rules are enforced", () => {
  const tooMany = scored();
  tooMany.coaching.focus = Array.from({ length: 4 }, () => ({ kind: "fluency", referenceWordIndex: null, instruction: "Slow down.", practiceText: "my power" }));
  assert.ok(issuesOf(tooMany).some((issue) => issue.includes("at most three")));

  const badIndex = scored();
  badIndex.coaching.focus = [{ kind: "pronunciation", referenceWordIndex: 9, instruction: "Repeat it.", practiceText: "power" }];
  assert.ok(issuesOf(badIndex).some((issue) => issue.includes("valid reference index")));

  const emptySummary = scored();
  emptySummary.coaching.summary = " ";
  assert.ok(issuesOf(emptySummary).some((issue) => issue.includes("coaching.summary")));

  const withScores = unscorable() as Record<string, unknown>;
  withScores.scores = { languageOverall: 0 };
  assert.ok(issuesOf(withScores).some((issue) => issue.includes("scores must be null")));

  const withFocus = unscorable();
  withFocus.coaching.strengths = ["Nice try."] as never[];
  assert.ok(issuesOf(withFocus).some((issue) => issue.includes("empty strengths and focus")));

  const missing = unscorable() as Record<string, unknown>;
  delete missing.recordedAt;
  missing.reason = "silence";
  assert.deepEqual(issuesOf(missing).sort(), ["reason is not a known unscorable reason", "recordedAt must be an RFC 3339 timestamp"]);

  assert.deepEqual(issuesOf(null), ["response must be an object"]);
});
