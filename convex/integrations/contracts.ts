import { z } from "zod";

// Seams between the backend and the engine and coaching implementations. Implementations return
// plain data; the backend validates it (lib/outcome.ts, coachingSchema) before storing anything.
//
// The engine seam mirrors the assessment adapter's input and outcome shapes so wiring a provider is
// a one-file change. The adapter computes languageOverall, wordAccuracy, and timingFit itself; the
// backend checks them for consistency but never recomputes them.

export type AssessmentErrorKind =
  | "invalid_input"
  | "invalid_reference"
  | "provider_unavailable"
  | "provider_auth"
  | "provider_rejected"
  | "invalid_provider_response";

/** Only provider_unavailable is retryable; every other kind fails the job without an automatic retry. */
export class AssessmentError extends Error {
  constructor(
    readonly kind: AssessmentErrorKind,
    message: string,
    readonly details: Record<string, unknown> = {},
  ) {
    super(message);
    this.name = "AssessmentError";
  }

  get retryable(): boolean {
    return this.kind === "provider_unavailable";
  }
}

export class CoachingError extends Error {
  constructor(
    readonly code: string,
    message: string,
    readonly retryable: boolean,
  ) {
    super(message);
    this.name = "CoachingError";
  }
}

export interface AssessAttemptInput {
  /** Correlation id for the adapter; the stored assessment gets its own database id. */
  assessmentId: string;
  attemptId: string;
  lineId: string;
  referenceVersion: number;
  locale: string;
  /** RFC 3339 capture time from validated attempt metadata. */
  recordedAt: string;
  /** Reference text resolved from stored project data, never from the client. */
  referenceText: string;
  /** The source line's dialogue window in integer milliseconds; used only for timingFit. */
  targetWindowMs: { startMs: number; endMs: number };
  /** The backend passes the validated client-reported length; an implementation that inspects the WAV may override it. */
  recordingDurationMs: number;
  /** The HTTP result of the provider call, filled in by the implementation, never by the backend. */
  provider?: { httpStatus: number; body: unknown };
}

const score = z.number().finite().min(0).max(100).nullable();
const milliseconds = z.number().int().min(0).nullable();
const metric = z.enum(["languageOverall", "pronunciation", "wordAccuracy", "fluency", "timingFit"]);

const wordResultSchema = z.object({
  referenceWordIndex: z.number().int().min(0).nullable(),
  expected: z.string().min(1).nullable(),
  recognized: z.string().min(1).nullable(),
  textStatus: z.enum(["matched", "substituted", "omitted", "inserted"]),
  pronunciationScore: score,
  pronunciationUnavailableReason: z.enum(["omitted_word", "unaligned_word", "unsupported_locale", "insufficient_evidence"]).optional(),
  startMs: milliseconds,
  endMs: milliseconds,
});
export type WordResult = z.infer<typeof wordResultSchema>;

const envelope = {
  schemaVersion: z.literal(1),
  rubricVersion: z.literal("language-v1"),
  assessmentId: z.string().min(1),
  attemptId: z.string().min(1),
  lineId: z.string().min(1),
  referenceVersion: z.number().int().min(1),
  locale: z.string().min(1),
  recordedAt: z.string().min(1),
  referenceText: z.string().min(1),
  recognizedText: z.string().nullable(),
};

const scoredResponse = z.object({
  ...envelope,
  status: z.literal("scored"),
  scores: z.object({
    languageOverall: score,
    pronunciation: score,
    wordAccuracy: score,
    fluency: score,
    timingFit: score,
  }),
  unavailableMetrics: z.array(
    z.object({ metric, reason: z.enum(["unsupported_locale", "insufficient_evidence", "missing_components"]) }),
  ),
  wordResults: z.array(wordResultSchema),
});

const unscorableResponse = z.object({
  ...envelope,
  status: z.literal("unscorable"),
  reason: z.enum(["no_speech", "excessive_noise", "insufficient_speech", "unsupported_locale"]),
  scores: z.null(),
  unavailableMetrics: z.array(z.never()).length(0),
  wordResults: z.array(z.never()).length(0),
});

const evidenceSchema = z.object({
  provider: z.object({
    name: z.string().min(1),
    locale: z.string(),
    recognitionStatus: z.string(),
    snr: z.number().finite().nullable(),
    completenessScore: z.number().finite().nullable(),
  }),
  normalizationVersion: z.string().min(1),
  rawScores: z.object({
    pronunciation: z.number().finite().nullable(),
    wordAccuracy: z.number().finite().nullable(),
    fluency: z.number().finite().nullable(),
    languageOverall: z.number().finite().nullable(),
    timingFit: z.number().finite().nullable(),
  }),
  referenceTokenCount: z.number().int().min(0),
  counts: z.object({
    matched: z.number().int().min(0),
    substituted: z.number().int().min(0),
    omitted: z.number().int().min(0),
    inserted: z.number().int().min(0),
  }),
  words: z.object({
    mispronounced: z.array(z.number().int().min(0)),
    substituted: z.array(z.number().int().min(0)),
    omitted: z.array(z.number().int().min(0)),
    inserted: z.number().int().min(0),
  }),
  timing: z
    .object({
      spokenStartMs: z.number().finite(),
      spokenEndMs: z.number().finite(),
      spokenDurationMs: z.number().finite().min(0),
      targetDurationMs: z.number().finite(),
      deltaMs: z.number().finite(),
    })
    .nullable(),
  unscorableReason: z.enum(["no_speech", "excessive_noise", "insufficient_speech", "unsupported_locale"]).nullable(),
});
export type AssessmentEvidence = z.infer<typeof evidenceSchema>;

export const assessmentOutcomeSchema = z.object({
  response: z.union([scoredResponse, unscorableResponse]),
  evidence: evidenceSchema,
});
export type AssessmentOutcome = z.infer<typeof assessmentOutcomeSchema>;

export const engineProvenanceSchema = z.object({
  provider: z.string().min(1),
  providerModelVersion: z.string().nullable(),
  configVersion: z.string().min(1),
  /**
   * acoustic: an acoustic model scored the audio. transcript_only: a transcript was read without an
   * acoustic model, so every pronunciation value must be null. A model's opinion is never acoustic evidence.
   */
  measurement: z.enum(["acoustic", "transcript_only"]),
});
export type EngineProvenance = z.infer<typeof engineProvenanceSchema>;

export interface AssessmentEngine {
  readonly provenance: EngineProvenance;
  /** Throws AssessmentError for failures. The outcome is validated before anything is stored. */
  assess(input: AssessAttemptInput, audio: Blob): Promise<AssessmentOutcome>;
}

export type CoachingInput = {
  locale: string;
  referenceText: string;
  recognizedText: string | null;
  status: "scored" | "unscorable";
  reason: string | null;
  scores: {
    languageOverall: number | null;
    pronunciation: number | null;
    wordAccuracy: number | null;
    fluency: number | null;
    timingFit: number | null;
  } | null;
  wordResults: WordResult[];
  /** Measured facts for coaching that must not contradict the stored scores. */
  evidence: AssessmentEvidence;
  /** Convex users id, for memory lookups. */
  learner: { userId: string };
};

/** Coaching explains measurements; it never supplies scores. */
export const coachingSchema = z.object({
  summary: z.string().min(1),
  strengths: z.array(z.string().min(1)),
  focus: z
    .array(
      z.object({
        kind: z.enum(["pronunciation", "word_accuracy", "fluency", "timing"]),
        referenceWordIndex: z.number().int().min(0).nullable(),
        instruction: z.string().min(1),
        practiceText: z.string().min(1),
      }),
    )
    .max(3),
  provider: z.string().min(1),
  configVersion: z.string().min(1),
});
export type Coaching = z.infer<typeof coachingSchema>;

export interface CoachingProvider {
  /** Throws CoachingError for provider failures. The return value is validated with coachingSchema. */
  coach(input: CoachingInput): Promise<Coaching>;
}
