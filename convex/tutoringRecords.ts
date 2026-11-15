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

/** One graded attempt plus the backend-validated recording facts the contract's progress rules need. */
export const sessionAssessment = z.object({
  assessment: gradingResult,
  /** Measured speech in the original recording, silence excluded. */
  speakingDurationMs: z.number().int().min(0),
  recordingDurationMs: z.number().int().positive(),
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
