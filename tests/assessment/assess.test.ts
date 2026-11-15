import assert from "node:assert/strict";
import test from "node:test";
import {
  assessAttempt,
  AssessmentError,
  computeLanguageOverall,
  computeTimingFit,
  validateAssessmentResponse,
} from "../../convex/assessment/index";
import type { AssessAttemptInput, AssessmentErrorKind } from "../../convex/assessment/index";
import { baseInput, exampleWords, ok, status, syntheticSuccess } from "./fixtures";
import type { SyntheticWord } from "./fixtures";

const assess = (words: SyntheticWord[], overrides: Partial<AssessAttemptInput> = {}, scores: { accuracy?: number; fluency?: number } = {}) =>
  assessAttempt(
    baseInput(ok(syntheticSuccess({ display: "synthetic", words, ...scores })), overrides),
  );

function errorKind(run: () => unknown): AssessmentErrorKind {
  try {
    run();
  } catch (error) {
    assert.ok(error instanceof AssessmentError, "expected an AssessmentError");
    return error.kind;
  }
  assert.fail("expected an AssessmentError");
}

test("the contract example scores 88 overall with a 90 timing fit and passes the full validator", () => {
  const outcome = assess(exampleWords, {}, { accuracy: 82, fluency: 80 });
  const { response, evidence } = outcome;
  assert.equal(response.status, "scored");
  assert.equal(response.measurement, "acoustic");
  assert.equal(evidence.measurement, "acoustic");
  assert.deepEqual(outcome.provenance, {
    evaluator: "azure-speech-pronunciation-assessment",
    measurement: "acoustic",
    modelVersion: null,
    evaluatorConfigVersion: "azure-rest-short-audio-v1",
  });
  assert.deepEqual(response.status === "scored" && response.scores, {
    languageOverall: 88,
    pronunciation: 82,
    wordAccuracy: 100,
    fluency: 80,
    timingFit: 90,
  });
  assert.equal(evidence.timing?.spokenDurationMs, 2700);
  assert.equal(evidence.timing?.deltaMs, -300);
  const withCoaching = {
    ...response,
    coaching: { summary: "You included every word.", strengths: ["Complete script."], focus: [] },
  };
  validateAssessmentResponse(withCoaching, { recordingDurationMs: 3200 });
});

test("languageOverall and timingFit round halves up", () => {
  assert.equal(computeLanguageOverall(10, 0, 0), 5);
  assert.equal(computeLanguageOverall(82, 100, 80), 88);
  assert.equal(computeLanguageOverall(0, 100, 0), 35);
  assert.equal(computeTimingFit(1990, 2000), 100);
  assert.equal(computeTimingFit(1000, 2000), 50);
  assert.equal(computeTimingFit(2000, 2000), 100);
  assert.equal(computeTimingFit(5000, 2000), 0);
});

test("wordAccuracy is rounded for display but languageOverall uses the unrounded value", () => {
  const { response, evidence } = assess(
    [
      { word: "the", startMs: 100, durationMs: 200, accuracy: 90 },
      { word: "blue", startMs: 400, durationMs: 300, accuracy: 90 },
      { word: "car", startMs: 800, durationMs: 300, accuracy: 90 },
    ],
    { referenceText: "The red car." },
    { accuracy: 90, fluency: 90 },
  );
  assert.equal(response.status === "scored" && response.scores.wordAccuracy, 67);
  assert.ok(Math.abs((evidence.rawScores.wordAccuracy ?? 0) - 66.6667) < 0.001);
  assert.ok(Math.abs((evidence.rawScores.languageOverall ?? 0) - (0.45 * 90 + 0.35 * (200 / 3) + 0.2 * 90)) < 1e-9);
});

test("matched, substituted, omitted and inserted words are aligned and counted", () => {
  const { response, evidence } = assess(
    [
      { word: "i", startMs: 100, durationMs: 100, accuracy: 95 },
      { word: "will", startMs: 250, durationMs: 200, accuracy: 85, errorType: "Mispronunciation" },
      { word: "not", errorType: "Omission" },
      { word: "go", startMs: 500, durationMs: 200, accuracy: 90 },
      { word: "to", startMs: 750, durationMs: 100, accuracy: 70, errorType: "Insertion" },
      { word: "town", startMs: 900, durationMs: 300, accuracy: 80 },
    ],
    { referenceText: "I will not go home" },
  );
  assert.equal(response.status, "scored");
  if (response.status !== "scored") return;
  assert.deepEqual(
    response.wordResults.map((word) => [word.referenceWordIndex, word.expected, word.recognized, word.textStatus]),
    [
      [0, "I", "i", "matched"],
      [1, "will", "will", "matched"],
      [2, "not", null, "omitted"],
      [3, "go", "go", "matched"],
      [null, null, "to", "inserted"],
      [4, "home", "town", "substituted"],
    ],
  );
  assert.deepEqual(evidence.counts, { matched: 3, substituted: 1, omitted: 1, inserted: 1 });
  assert.equal(response.scores.wordAccuracy, 40);
  const omitted = response.wordResults[2]!;
  assert.deepEqual([omitted.pronunciationScore, omitted.pronunciationUnavailableReason, omitted.startMs, omitted.endMs], [null, "omitted_word", null, null]);
  const substituted = response.wordResults[5]!;
  assert.deepEqual([substituted.pronunciationScore, substituted.pronunciationUnavailableReason, substituted.startMs, substituted.endMs], [null, "unaligned_word", 900, 1200]);
  assert.equal(response.wordResults[1]!.pronunciationScore, 85);
  assert.deepEqual(evidence.words, { mispronounced: [1], substituted: [4], omitted: [2], inserted: 1 });
  validateAssessmentResponse({ ...response, coaching: { summary: "Try again.", strengths: [], focus: [] } }, { recordingDurationMs: 3200 });
});

test("scores nested under PronunciationAssessment are read like the flat REST layout", () => {
  const nested = syntheticSuccess({ display: "You underestimate my power.", words: exampleWords, nested: true });
  const { response } = assessAttempt(baseInput(ok(nested)));
  assert.equal(response.status === "scored" && response.scores.pronunciation, 90);
});

test("digits in the reference match spelled-out recognized words", () => {
  const { response } = assess(
    [
      { word: "i", startMs: 100, durationMs: 100, accuracy: 90 },
      { word: "have", startMs: 250, durationMs: 200, accuracy: 90 },
      { word: "twenty", startMs: 500, durationMs: 300, accuracy: 90 },
      { word: "five", startMs: 850, durationMs: 300, accuracy: 90 },
      { word: "pencils", startMs: 1200, durationMs: 400, accuracy: 90 },
    ],
    { referenceText: "I have 25 pencils." },
  );
  assert.equal(response.status === "scored" && response.scores.wordAccuracy, 100);
});

test("boundaries slightly past the recording are clipped and larger overshoots are rejected", () => {
  const clipped = assess([{ word: "power", startMs: 3000, durationMs: 220, accuracy: 90 }], { referenceText: "power", recordingDurationMs: 3200 });
  assert.equal(clipped.response.status === "scored" && clipped.response.wordResults[0]!.endMs, 3200);
  assert.equal(
    errorKind(() => assess([{ word: "power", startMs: 3000, durationMs: 400, accuracy: 90 }], { referenceText: "power", recordingDurationMs: 3200 })),
    "invalid_provider_response",
  );
  assert.equal(
    errorKind(() => assess([{ word: "power", startMs: 3300, durationMs: 100, accuracy: 90 }], { referenceText: "power", recordingDurationMs: 3200 })),
    "invalid_provider_response",
  );
});

test("an unsupported locale is unscorable without calling the provider", () => {
  const { response, evidence } = assessAttempt(baseInput(undefined, { locale: "es-ES" }));
  assert.equal(response.status, "unscorable");
  assert.equal(response.status === "unscorable" && response.reason, "unsupported_locale");
  assert.equal(response.scores, null);
  assert.equal(evidence.unscorableReason, "unsupported_locale");
});

test("silence, noise, no match and empty recognition are unscorable from observed status only", () => {
  const reasonFor = (body: unknown) => {
    const { response } = assessAttempt(baseInput(ok(body)));
    assert.equal(response.status, "unscorable");
    assert.deepEqual([response.scores, response.wordResults, response.unavailableMetrics], [null, [], []]);
    return response.status === "unscorable" ? response.reason : undefined;
  };
  assert.equal(reasonFor(status("InitialSilenceTimeout")), "no_speech");
  assert.equal(reasonFor(status("BabbleTimeout")), "excessive_noise");
  assert.equal(reasonFor(status("NoMatch")), "insufficient_speech");
  assert.equal(reasonFor(syntheticSuccess({ display: "", words: [{ word: "power", errorType: "Omission" }] })), "insufficient_speech");
});

test("provider failures stay distinct from unscorable results", () => {
  const withStatus = (httpStatus: number) => () => assessAttempt(baseInput({ httpStatus, body: undefined }));
  assert.equal(errorKind(withStatus(401)), "provider_auth");
  assert.equal(errorKind(withStatus(403)), "provider_auth");
  assert.equal(errorKind(withStatus(400)), "provider_rejected");
  assert.equal(errorKind(withStatus(429)), "provider_unavailable");
  assert.equal(errorKind(withStatus(503)), "provider_unavailable");
  assert.equal(errorKind(() => assessAttempt(baseInput(ok(status("Error"))))), "provider_unavailable");
});

test("malformed provider payloads become errors, never partial success", () => {
  const valid = () => syntheticSuccess({ display: "You underestimate my power.", words: exampleWords }) as { NBest: Array<Record<string, unknown>> } & Record<string, unknown>;
  const mutations: Array<[string, (body: ReturnType<typeof valid>) => unknown]> = [
    ["not an object", () => "oops"],
    ["no RecognitionStatus", (body) => ({ ...body, RecognitionStatus: undefined })],
    ["undocumented status", (body) => ({ ...body, RecognitionStatus: "Mystery" })],
    ["missing NBest", (body) => ({ ...body, NBest: undefined })],
    ["empty NBest", (body) => ({ ...body, NBest: [] })],
    ["missing fluency", (body) => (delete body.NBest[0]!.FluencyScore, body)],
    ["missing accuracy", (body) => (delete body.NBest[0]!.AccuracyScore, body)],
    ["score above 100", (body) => ((body.NBest[0]!.AccuracyScore = 101), body)],
    ["score as string", (body) => ((body.NBest[0]!.FluencyScore = "90"), body)],
    ["missing Words", (body) => (delete body.NBest[0]!.Words, body)],
    ["missing display", (body) => (delete body.NBest[0]!.Display, delete body.DisplayText, body)],
    ["word without Duration", (body) => (delete (body.NBest[0]!.Words as Array<Record<string, unknown>>)[0]!.Duration, body)],
    ["word without ErrorType", (body) => (delete (body.NBest[0]!.Words as Array<Record<string, unknown>>)[0]!.ErrorType, body)],
    ["word without accuracy", (body) => (delete (body.NBest[0]!.Words as Array<Record<string, unknown>>)[0]!.AccuracyScore, body)],
    ["negative Offset", (body) => (((body.NBest[0]!.Words as Array<Record<string, unknown>>)[0]!.Offset = -5), body)],
  ];
  for (const [label, mutate] of mutations) {
    assert.equal(errorKind(() => assessAttempt(baseInput(ok(mutate(valid()))))), "invalid_provider_response", label);
  }
});

test("invalid references and invalid backend input are explicit errors", () => {
  assert.equal(errorKind(() => assessAttempt(baseInput(ok(status("NoMatch")), { referenceText: "...!?" }))), "invalid_reference");
  assert.equal(errorKind(() => assessAttempt(baseInput(ok(status("NoMatch")), { recordedAt: "yesterday" }))), "invalid_input");
  assert.equal(errorKind(() => assessAttempt(baseInput(ok(status("NoMatch")), { recordingDurationMs: 31_000 }))), "invalid_input");
  assert.equal(errorKind(() => assessAttempt(baseInput(ok(status("NoMatch")), { targetWindowMs: { startMs: 5, endMs: 5 } }))), "invalid_input");
  assert.equal(errorKind(() => assessAttempt(baseInput(ok(status("NoMatch")), { referenceVersion: 0 }))), "invalid_input");
  assert.equal(errorKind(() => assessAttempt(baseInput(undefined))), "invalid_input");
});
