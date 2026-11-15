// Types for the grading contract v1 (docs/grading-contract.md, rubric language-v1).
// This module is pure TypeScript: it exports no Convex functions and imports nothing from Convex,
// so the backend action can call it and it can move without changes.

export const SCHEMA_VERSION = 1;
export const RUBRIC_VERSION = "language-v1";

export type Metric = "languageOverall" | "pronunciation" | "wordAccuracy" | "fluency" | "timingFit";
export const METRICS: readonly Metric[] = ["languageOverall", "pronunciation", "wordAccuracy", "fluency", "timingFit"];

export type Scores = Record<Metric, number | null>;

export type UnavailableReason = "unsupported_locale" | "insufficient_evidence" | "missing_components";
export const UNAVAILABLE_REASONS: readonly UnavailableReason[] = ["unsupported_locale", "insufficient_evidence", "missing_components"];

export interface UnavailableMetric {
  metric: Metric;
  reason: UnavailableReason;
}

export type TextStatus = "matched" | "substituted" | "omitted" | "inserted";
export const TEXT_STATUSES: readonly TextStatus[] = ["matched", "substituted", "omitted", "inserted"];

export type PronunciationUnavailableReason = "omitted_word" | "unaligned_word" | "unsupported_locale" | "insufficient_evidence";
export const PRONUNCIATION_UNAVAILABLE_REASONS: readonly PronunciationUnavailableReason[] = [
  "omitted_word",
  "unaligned_word",
  "unsupported_locale",
  "insufficient_evidence",
];

export interface WordResult {
  referenceWordIndex: number | null;
  expected: string | null;
  recognized: string | null;
  textStatus: TextStatus;
  pronunciationScore: number | null;
  /** Present exactly when pronunciationScore is null. */
  pronunciationUnavailableReason?: PronunciationUnavailableReason;
  startMs: number | null;
  endMs: number | null;
}

export type FocusKind = "pronunciation" | "word_accuracy" | "fluency" | "timing";
export const FOCUS_KINDS: readonly FocusKind[] = ["pronunciation", "word_accuracy", "fluency", "timing"];

export interface CoachingFocus {
  kind: FocusKind;
  referenceWordIndex: number | null;
  instruction: string;
  practiceText: string;
}

export interface Coaching {
  summary: string;
  strengths: string[];
  focus: CoachingFocus[];
}

export type UnscorableReason = "no_speech" | "excessive_noise" | "insufficient_speech" | "unsupported_locale";
export const UNSCORABLE_REASONS: readonly UnscorableReason[] = ["no_speech", "excessive_noise", "insufficient_speech", "unsupported_locale"];

/**
 * How pronunciation and fluency were obtained. "acoustic" means a speech-assessment service measured the audio.
 * "transcript_only" means only recognized text was available (including any LLM or transcription output), so
 * pronunciation, fluency and every word pronunciationScore must be null. A missing or unknown value is read as
 * "transcript_only" by consumers.
 */
export type Measurement = "acoustic" | "transcript_only";
export const MEASUREMENTS: readonly Measurement[] = ["acoustic", "transcript_only"];

export interface ResponseEnvelope {
  schemaVersion: 1;
  rubricVersion: "language-v1";
  assessmentId: string;
  attemptId: string;
  lineId: string;
  referenceVersion: number;
  locale: string;
  /** RFC 3339 recording timestamp copied from validated attempt metadata. */
  recordedAt: string;
  referenceText: string;
  recognizedText: string | null;
  measurement: Measurement;
}

export interface ScoredResponse extends ResponseEnvelope {
  status: "scored";
  scores: Scores;
  unavailableMetrics: UnavailableMetric[];
  wordResults: WordResult[];
  coaching: Coaching;
}

export interface UnscorableResponse extends ResponseEnvelope {
  status: "unscorable";
  reason: UnscorableReason;
  scores: null;
  unavailableMetrics: [];
  wordResults: [];
  coaching: Coaching;
}

export type AssessmentResponse = ScoredResponse | UnscorableResponse;

/** What the assessment adapter returns: the contract response minus the coaching the tutoring service writes. */
export type ScoredResponseWithoutCoaching = Omit<ScoredResponse, "coaching">;
export type UnscorableResponseWithoutCoaching = Omit<UnscorableResponse, "coaching">;
export type AssessmentResponseWithoutCoaching = ScoredResponseWithoutCoaching | UnscorableResponseWithoutCoaching;

/**
 * Explicit failure kinds. Every one of these makes the assessment job fail; none may be turned into an
 * `unscorable` result or a fabricated score (grading contract, "Unscorable audio and processing failures").
 */
export type AssessmentErrorKind =
  /** The backend supplied a malformed identifier, timestamp, duration, window or audio file. */
  | "invalid_input"
  /** The reference text has no usable tokens for the locale. */
  | "invalid_reference"
  /** Network failure, 408, 429, 5xx, or a provider-reported internal error. Retryable. */
  | "provider_unavailable"
  /** 401 or 403: the key, region or endpoint is wrong. Not retryable. */
  | "provider_auth"
  /** Another 4xx, such as an unsupported language or unreadable audio. Not retryable. */
  | "provider_rejected"
  /** A 200 whose body lacks a field the adapter depends on, or carries out-of-range values. */
  | "invalid_provider_response";

export class AssessmentError extends Error {
  readonly kind: AssessmentErrorKind;
  /** Redacted, safe-to-log context: operation parameters and status codes, never keys, audio or transcripts. */
  readonly details: Record<string, unknown>;

  constructor(kind: AssessmentErrorKind, message: string, details: Record<string, unknown> = {}) {
    super(message);
    this.name = "AssessmentError";
    this.kind = kind;
    this.details = details;
  }

  get retryable(): boolean {
    return this.kind === "provider_unavailable";
  }
}

export class AssessmentValidationError extends Error {
  readonly issues: string[];

  constructor(issues: string[]) {
    super(`Assessment response failed validation: ${issues.join("; ")}`);
    this.name = "AssessmentValidationError";
    this.issues = issues;
  }
}
