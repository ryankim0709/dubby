import { z } from "zod";
import { gradingResult, wordSpanIssues } from "./gradingContract";

function isTimeZone(value: string): boolean {
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: value });
    return true;
  } catch (error) {
    if (error instanceof RangeError) return false;
    throw error;
  }
}

const identifier = z.string().min(1).max(200);
const ianaTimeZone = z.string().refine(isTimeZone, "must be an IANA time zone, such as America/Los_Angeles");

/**
 * How the evaluator produced its numbers. Anything that isn't explicitly "acoustic" is treated as
 * transcript-only, so a missing or unknown value can never unlock a pronunciation finding.
 */
export const measurementKinds = ["acoustic", "transcript_only"] as const;
const measurement = z.enum(measurementKinds).catch("transcript_only");

/** Assessment provenance from the grading contract. Results from different evaluators are never compared. */
export const evaluatorProvenance = z.object({
  provider: identifier,
  /** Null when the provider doesn't disclose a model version; one is never invented. */
  modelVersion: identifier.nullable(),
  configVersion: identifier,
  completedAt: z.iso.datetime({ offset: true }),
  measurement,
});
export type EvaluatorProvenance = z.infer<typeof evaluatorProvenance>;

const sheetScore = z.number().min(0).max(100).nullable();

/** One line's exact values on the dub score sheet (docs/grading-contract.md, "Dub score sheet"), unrounded. */
export const sheetLine = z.object({
  version: z.literal("dub-v1"),
  lineScore: sheetScore,
  wordAccuracy: sheetScore,
  timingFit: sheetScore,
});

/** The dub a session came from: what the learner dubbed and its completed score card. */
export const dubContext = z.object({
  sheetVersion: z.literal("dub-v1"),
  sceneTitle: z.string().min(1).max(200),
  characterName: z.string().min(1).max(200),
  scoreCard: z.object({
    dubScore: sheetScore,
    wordAccuracy: sheetScore,
    timingFit: sheetScore,
    linesDubbed: z.number().int().min(0),
    linesScored: z.number().int().min(0),
    linesUnscorable: z.number().int().min(0),
    linesFailed: z.number().int().min(0),
  }),
});
export type DubContext = z.infer<typeof dubContext>;

/** One graded attempt plus the backend-validated recording facts the contract's progress rules need. */
export const sessionAssessment = z.object({
  assessment: gradingResult,
  /** Measured speech in the original recording, silence excluded. */
  speakingDurationMs: z.number().int().min(0),
  recordingDurationMs: z.number().int().positive(),
  /** Present when the session came from the dub score sheet. */
  sheet: sheetLine.optional(),
});
export type SessionAssessment = z.infer<typeof sessionAssessment>;

/**
 * One dubbing session's graded line attempts, as the backend assembles them after grading. The learner's
 * identity is not part of it: the caller supplies it from the authenticated user.
 */
export const dubbingSessionResults = z.object({
  sessionId: identifier,
  sceneId: identifier,
  characterId: identifier,
  /** The learner's IANA time zone when they practised; local practice days are grouped in it. */
  timeZone: ianaTimeZone,
  evaluator: evaluatorProvenance,
  assessments: z.array(sessionAssessment).min(1),
  /** Present when the session came from the dub score sheet. */
  dub: dubContext.optional(),
});
export type DubbingSessionResults = z.infer<typeof dubbingSessionResults>;

/** What tutoring keeps about one assessment: the contract result plus its session and provenance context. */
export const tutoringRecord = z
  .object({
    recordVersion: z.literal(1),
    sessionId: identifier,
    sceneId: identifier,
    characterId: identifier,
    timeZone: ianaTimeZone,
    evaluator: evaluatorProvenance,
    speakingDurationMs: z.number().int().min(0),
    recordingDurationMs: z.number().int().positive(),
    /** Server time when tutoring stored the assessment. */
    ingestedAt: z.iso.datetime({ offset: true }),
    assessment: gradingResult,
    /** The dub and score card the attempt belongs to, when it came from the dub score sheet. */
    dub: dubContext.optional(),
    sheet: sheetLine.optional(),
  })
  .superRefine((record, ctx) => {
    for (const message of wordSpanIssues(record.assessment, record.recordingDurationMs)) {
      ctx.addIssue({ code: "custom", message });
    }
    if (record.speakingDurationMs > record.recordingDurationMs) {
      ctx.addIssue({ code: "custom", message: "speakingDurationMs can't exceed the recording's duration" });
    }
    if (record.evaluator.measurement === "acoustic" || record.assessment.status !== "scored") return;
    const hasPronunciation =
      record.assessment.scores.pronunciation !== null ||
      record.assessment.wordResults.some((word) => word.pronunciationScore !== null);
    if (hasPronunciation) {
      ctx.addIssue({ code: "custom", message: "a transcript-only evaluator can't supply pronunciation scores" });
    }
    // Fluency is an acoustic measurement in the grading contract, so a transcript-only evaluator can't supply it either.
    if (record.assessment.scores.fluency !== null) {
      ctx.addIssue({ code: "custom", message: "a transcript-only evaluator can't supply a fluency score" });
    }
  });
export type TutoringRecord = z.infer<typeof tutoringRecord>;

export type IngestIssue = { path: string; message: string };

/** Builds one validated record per assessment; any invalid record rejects the whole session with its issues. */
export function recordsForSession(
  session: DubbingSessionResults,
  ingestedAt: string,
): { ok: true; records: TutoringRecord[] } | { ok: false; issues: IngestIssue[] } {
  const parsed = session.assessments.map((item) =>
    tutoringRecord.safeParse({
      recordVersion: 1,
      sessionId: session.sessionId,
      sceneId: session.sceneId,
      characterId: session.characterId,
      timeZone: session.timeZone,
      evaluator: session.evaluator,
      speakingDurationMs: item.speakingDurationMs,
      recordingDurationMs: item.recordingDurationMs,
      ingestedAt,
      assessment: item.assessment,
      ...(session.dub === undefined ? {} : { dub: session.dub }),
      ...(item.sheet === undefined ? {} : { sheet: item.sheet }),
    }),
  );
  const issues = parsed.flatMap((result, index) =>
    result.success
      ? []
      : result.error.issues.map((issue) => ({
          path: ['assessments[' + index + ']', ...issue.path].join('.'),
          message: issue.message,
        })),
  );
  if (issues.length > 0) return { ok: false, issues };
  return { ok: true, records: parsed.flatMap((result) => (result.success ? [result.data] : [])) };
}

/** A line the learner could practise next, from the scene catalog the caller supplies. */
export type PracticeLine = {
  sceneId: string;
  lineId: string;
  referenceVersion: number;
  locale: string;
  referenceText: string;
};
