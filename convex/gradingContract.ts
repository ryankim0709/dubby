import { z } from "zod";

// Runtime schema for the line-attempt grading response in docs/grading-contract.md (schemaVersion 1).
// Unknown extra fields are stripped, as the contract asks of the service boundary.

export const scoreMetrics = ["languageOverall", "pronunciation", "wordAccuracy", "fluency", "timingFit"] as const;
export type ScoreMetric = (typeof scoreMetrics)[number];

const score = z.number().min(0).max(100).nullable();

const scores = z.object({
  languageOverall: score,
  pronunciation: score,
  wordAccuracy: score,
  fluency: score,
  timingFit: score,
});
export type Scores = z.infer<typeof scores>;

const unavailableMetric = z.object({
  metric: z.enum(scoreMetrics),
  reason: z.enum(["unsupported_locale", "insufficient_evidence", "missing_components"]),
});

const wordResult = z
  .object({
    referenceWordIndex: z.number().int().min(0).nullable(),
    expected: z.string().min(1).nullable(),
    recognized: z.string().min(1).nullable(),
    textStatus: z.enum(["matched", "substituted", "omitted", "inserted"]),
    pronunciationScore: score,
    pronunciationUnavailableReason: z
      .enum(["omitted_word", "unaligned_word", "unsupported_locale", "insufficient_evidence"])
      .optional(),
    startMs: z.number().int().min(0).nullable(),
    endMs: z.number().int().min(1).nullable(),
  })
  .superRefine((word, ctx) => {
    const isInsertion = word.textStatus === "inserted";
    if (isInsertion !== (word.referenceWordIndex === null) || isInsertion !== (word.expected === null)) {
      ctx.addIssue({ code: "custom", message: "only insertions lack a reference index and expected token" });
    }
    if ((word.textStatus === "omitted") !== (word.recognized === null)) {
      ctx.addIssue({ code: "custom", message: "only omissions lack a recognized token" });
    }
    if ((word.pronunciationScore === null) !== (word.pronunciationUnavailableReason !== undefined)) {
      ctx.addIssue({ code: "custom", message: "a null pronunciationScore needs exactly one unavailable reason" });
    }
    if ((word.startMs === null) !== (word.endMs === null)) {
      ctx.addIssue({ code: "custom", message: "startMs and endMs are both measured or both null" });
    }
    if (word.startMs !== null && word.endMs !== null && word.startMs >= word.endMs) {
      ctx.addIssue({ code: "custom", message: "startMs must be before endMs" });
    }
  });
export type WordResult = z.infer<typeof wordResult>;

const coachingFocus = z.object({
  kind: z.enum(["pronunciation", "word_accuracy", "fluency", "timing"]),
  referenceWordIndex: z.number().int().min(0).nullable(),
  instruction: z.string().min(1),
  practiceText: z.string().min(1),
});

const coaching = z.object({
  summary: z.string().min(1),
  strengths: z.array(z.string().min(1)),
  focus: z.array(coachingFocus).max(3),
});

const envelope = {
  schemaVersion: z.literal(1),
  rubricVersion: z.string().min(1),
  assessmentId: z.string().min(1),
  attemptId: z.string().min(1),
  lineId: z.string().min(1),
  referenceVersion: z.number().int().positive(),
  locale: z.string().min(2),
  recordedAt: z.iso.datetime({ offset: true }),
  referenceText: z.string().min(1),
  recognizedText: z.string().nullable(),
  coaching,
};

const scoredResult = z
  .object({
    ...envelope,
    status: z.literal("scored"),
    scores,
    unavailableMetrics: z.array(unavailableMetric),
    wordResults: z.array(wordResult),
  })
  .superRefine((result, ctx) => {
    for (const metric of scoreMetrics) {
      const entries = result.unavailableMetrics.filter((entry) => entry.metric === metric);
      const isNull = result.scores[metric] === null;
      if (entries.length !== (isNull ? 1 : 0)) {
        ctx.addIssue({ code: "custom", message: `${metric} needs one unavailable entry exactly when it is null` });
      }
      if (entries.some((entry) => entry.reason === "missing_components") && metric !== "languageOverall") {
        ctx.addIssue({ code: "custom", message: `missing_components applies only to languageOverall, not ${metric}` });
      }
    }
    const { languageOverall, pronunciation, wordAccuracy, fluency } = result.scores;
    if (pronunciation === null && wordAccuracy === null && fluency === null) {
      ctx.addIssue({ code: "custom", message: "a scored result needs at least one language measurement" });
    }
    const hasAllComponents = pronunciation !== null && wordAccuracy !== null && fluency !== null;
    if (hasAllComponents !== (languageOverall !== null)) {
      ctx.addIssue({ code: "custom", message: "languageOverall is present exactly when pronunciation, wordAccuracy and fluency all are" });
    }
    if (wordAccuracy !== null && result.wordResults.length === 0) {
      ctx.addIssue({ code: "custom", message: "wordAccuracy needs a word alignment; without one it is null" });
    }
    const referenceIndices = result.wordResults.flatMap((word) => (word.referenceWordIndex === null ? [] : [word.referenceWordIndex]));
    const isCovered = new Set(referenceIndices).size === referenceIndices.length && referenceIndices.every((index) => index < referenceIndices.length);
    if (!isCovered) {
      ctx.addIssue({ code: "custom", message: "each reference token appears once, with indices 0 to N-1 and no gaps" });
    }
  });

/**
 * Checks that measured word spans fit inside the recording. The envelope doesn't carry the recording's
 * length, so the caller supplies the validated attempt's duration.
 */
export function wordSpanIssues(result: GradingResult, recordingDurationMs: number): string[] {
  if (result.status !== "scored") return [];
  return result.wordResults.flatMap((word) =>
    word.endMs !== null && word.endMs > recordingDurationMs
      ? [`word ${word.referenceWordIndex ?? "inserted"} ends at ${word.endMs} ms, past the ${recordingDurationMs} ms recording`]
      : [],
  );
}

const unscorableResult = z.object({
  ...envelope,
  status: z.literal("unscorable"),
  reason: z.enum(["no_speech", "excessive_noise", "insufficient_speech", "unsupported_locale"]),
  scores: z.null(),
  unavailableMetrics: z.array(unavailableMetric).length(0),
  wordResults: z.array(wordResult).length(0),
  coaching: coaching.extend({ strengths: z.array(z.string()).length(0), focus: z.array(coachingFocus).length(0) }),
});

export const gradingResult = z.discriminatedUnion("status", [scoredResult, unscorableResult]);
export type GradingResult = z.infer<typeof gradingResult>;
export type ScoredResult = Extract<GradingResult, { status: "scored" }>;
