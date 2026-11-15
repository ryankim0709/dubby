import type { AssessmentOutcome, WordResult } from "../integrations/contracts";
import { align } from "./align";
import { computeTimingFit, RFC3339, roundHalfUp } from "./assess";
import { NORMALIZATION_VERSION, tokenize } from "./normalize";
import { AssessmentError, type ResponseEnvelope, RUBRIC_VERSION, SCHEMA_VERSION, type UnscorableReason } from "./types";

// The transcript evaluator of the dub score sheet (docs/grading-contract.md, "Dub score sheet"). It reads
// which words were said and when; it never reports pronunciation or fluency, which a transcript can't show.

export const TRANSCRIPT_EVALUATOR = "openai-whisper";
export const TRANSCRIPT_MODEL = "whisper-1";
export const TRANSCRIPT_CONFIG_VERSION = "whisper-transcript-v1";
/** Locales whose words are separated by spaces, which word alignment needs. */
export const TRANSCRIPT_LOCALES: readonly string[] = ["en-US", "es-ES", "fr-FR", "de-DE", "ko-KR"];

export interface TranscriptAssessInput {
  assessmentId: string;
  attemptId: string;
  lineId: string;
  referenceVersion: number;
  locale: string;
  /** RFC 3339 capture time. */
  recordedAt: string;
  referenceText: string;
  /** The line's window in milliseconds; only its length is used, for timingFit. */
  targetWindowMs: { startMs: number; endMs: number };
  /** Length of the uploaded WAV, measured from its header. */
  recordingDurationMs: number;
}

/** One transcribed word, with times in seconds from the start of the recording. */
export interface TranscribedWord {
  text: string;
  start: number;
  end: number;
}

interface SpokenToken {
  norm: string;
  display: string;
  span: { startMs: number; endMs: number } | null;
}

function checkInput(input: TranscriptAssessInput): void {
  const bad = (problem: string) => new AssessmentError("invalid_input", `Transcript assessment input ${problem}`);
  for (const key of ["assessmentId", "attemptId", "lineId", "locale", "referenceText"] as const) {
    if (input[key].trim() === "") throw bad(`${key} must be a non-empty string`);
  }
  if (!Number.isInteger(input.referenceVersion) || input.referenceVersion < 1) throw bad("referenceVersion must be a positive integer");
  if (!RFC3339.test(input.recordedAt) || Number.isNaN(Date.parse(input.recordedAt))) throw bad("recordedAt must be an RFC 3339 timestamp");
  if (!Number.isInteger(input.recordingDurationMs) || input.recordingDurationMs <= 0) throw bad("recordingDurationMs must be a positive integer");
  const { startMs, endMs } = input.targetWindowMs;
  if (!Number.isInteger(startMs) || !Number.isInteger(endMs) || startMs < 0 || endMs <= startMs) {
    throw bad("targetWindowMs must be integer milliseconds with 0 <= startMs < endMs");
  }
}

/** Clips a word to the recording; a span that is empty after clipping has no measured timing. */
function spanOf(word: TranscribedWord, recordingMs: number): { startMs: number; endMs: number } | null {
  const startMs = Math.max(0, Math.round(word.start * 1000));
  const endMs = Math.min(recordingMs, Math.round(word.end * 1000));
  return startMs < endMs ? { startMs, endMs } : null;
}

function envelope(input: TranscriptAssessInput, recognizedText: string | null): ResponseEnvelope {
  return {
    schemaVersion: SCHEMA_VERSION,
    rubricVersion: RUBRIC_VERSION,
    assessmentId: input.assessmentId,
    attemptId: input.attemptId,
    lineId: input.lineId,
    referenceVersion: input.referenceVersion,
    locale: input.locale,
    recordedAt: input.recordedAt,
    referenceText: input.referenceText,
    recognizedText,
    measurement: "transcript_only",
  };
}

const provenance = {
  evaluator: TRANSCRIPT_EVALUATOR,
  measurement: "transcript_only" as const,
  modelVersion: TRANSCRIPT_MODEL,
  evaluatorConfigVersion: TRANSCRIPT_CONFIG_VERSION,
};

function unscorable(input: TranscriptAssessInput, reason: UnscorableReason, recognizedText: string | null, referenceTokenCount: number): AssessmentOutcome {
  return {
    response: { ...envelope(input, recognizedText), status: "unscorable", reason, scores: null, unavailableMetrics: [], wordResults: [] },
    evidence: {
      provider: { name: TRANSCRIPT_EVALUATOR, locale: input.locale, recognitionStatus: reason, snr: null, completenessScore: null },
      normalizationVersion: NORMALIZATION_VERSION,
      rawScores: { pronunciation: null, wordAccuracy: null, fluency: null, languageOverall: null, timingFit: null },
      referenceTokenCount,
      counts: { matched: 0, substituted: 0, omitted: 0, inserted: 0 },
      words: { mispronounced: [], substituted: [], omitted: [], inserted: 0 },
      measurement: "transcript_only",
      timing: null,
      unscorableReason: reason,
    },
    provenance,
  };
}

/** The spoken span from the first to the last timed word, against the line's window. */
function measureTiming(spans: readonly { startMs: number; endMs: number }[], targetDurationMs: number) {
  if (spans.length === 0) return null;
  const spokenStartMs = Math.min(...spans.map((span) => span.startMs));
  const spokenEndMs = Math.max(...spans.map((span) => span.endMs));
  const spokenDurationMs = spokenEndMs - spokenStartMs;
  return { spokenStartMs, spokenEndMs, spokenDurationMs, targetDurationMs, deltaMs: spokenDurationMs - targetDurationMs };
}

/** The outcome for a locale the transcript evaluator can't align, decided before any provider call. */
export function unsupportedLocaleOutcome(input: TranscriptAssessInput): AssessmentOutcome {
  checkInput(input);
  return unscorable(input, "unsupported_locale", null, 0);
}

/** Grades one take from its transcribed words against the line's reference text. */
export function assessTranscript(input: TranscriptAssessInput, words: readonly TranscribedWord[]): AssessmentOutcome {
  checkInput(input);
  const reference = tokenize(input.referenceText);
  if (reference.length === 0) throw new AssessmentError("invalid_reference", "The reference text has no tokens to assess");

  const spoken: SpokenToken[] = words.flatMap((word) => {
    const span = spanOf(word, input.recordingDurationMs);
    return tokenize(word.text).map((token) => ({ ...token, span }));
  });
  const recognizedText = words.map((word) => word.text.trim()).join(" ").trim();
  if (spoken.length === 0) return unscorable(input, "no_speech", recognizedText === "" ? null : recognizedText, reference.length);

  const alignment = align(
    reference.map((token) => token.norm),
    spoken.map((token) => token.norm),
  );
  const wordResults: WordResult[] = [];
  const substituted: number[] = [];
  const omitted: number[] = [];
  const timing = (token: SpokenToken) => ({ startMs: token.span?.startMs ?? null, endMs: token.span?.endMs ?? null });
  for (const step of alignment.ops) {
    if (step.op === "omit") {
      omitted.push(step.referenceIndex);
      wordResults.push({
        referenceWordIndex: step.referenceIndex,
        expected: reference[step.referenceIndex]!.display,
        recognized: null,
        textStatus: "omitted",
        pronunciationScore: null,
        pronunciationUnavailableReason: "omitted_word",
        startMs: null,
        endMs: null,
      });
      continue;
    }
    const heard = spoken[step.recognizedIndex]!;
    if (step.op === "insert") {
      wordResults.push({
        referenceWordIndex: null,
        expected: null,
        recognized: heard.display,
        textStatus: "inserted",
        pronunciationScore: null,
        pronunciationUnavailableReason: "unaligned_word",
        ...timing(heard),
      });
      continue;
    }
    const base = { referenceWordIndex: step.referenceIndex, expected: reference[step.referenceIndex]!.display, recognized: heard.display, ...timing(heard) };
    if (step.op === "substitute") {
      substituted.push(step.referenceIndex);
      wordResults.push({ ...base, textStatus: "substituted", pronunciationScore: null, pronunciationUnavailableReason: "unaligned_word" });
      continue;
    }
    wordResults.push({ ...base, textStatus: "matched", pronunciationScore: null, pronunciationUnavailableReason: "insufficient_evidence" });
  }

  const errors = alignment.substituted + alignment.omitted + alignment.inserted;
  const wordAccuracy = 100 * Math.max(0, 1 - errors / reference.length);
  const spans = spoken.flatMap((token) => (token.span === null ? [] : [token.span]));
  const measuredTiming = measureTiming(spans, input.targetWindowMs.endMs - input.targetWindowMs.startMs);
  const timingFit = measuredTiming === null ? null : computeTimingFit(measuredTiming.spokenDurationMs, measuredTiming.targetDurationMs);

  return {
    response: {
      ...envelope(input, recognizedText),
      status: "scored",
      scores: { languageOverall: null, pronunciation: null, wordAccuracy: roundHalfUp(wordAccuracy), fluency: null, timingFit },
      unavailableMetrics: [
        { metric: "languageOverall", reason: "missing_components" },
        { metric: "pronunciation", reason: "insufficient_evidence" },
        { metric: "fluency", reason: "insufficient_evidence" },
        ...(timingFit === null ? [{ metric: "timingFit" as const, reason: "insufficient_evidence" as const }] : []),
      ],
      wordResults,
    },
    evidence: {
      provider: { name: TRANSCRIPT_EVALUATOR, locale: input.locale, recognitionStatus: "Success", snr: null, completenessScore: null },
      normalizationVersion: NORMALIZATION_VERSION,
      rawScores: { pronunciation: null, wordAccuracy, fluency: null, languageOverall: null, timingFit },
      referenceTokenCount: reference.length,
      counts: { matched: alignment.matched, substituted: alignment.substituted, omitted: alignment.omitted, inserted: alignment.inserted },
      words: { mispronounced: [], substituted, omitted, inserted: alignment.inserted },
      measurement: "transcript_only",
      timing: measuredTiming,
      unscorableReason: null,
    },
    provenance,
  };
}
