// Pure entry point: turns one Azure pronunciation-assessment HTTP result into the grading-contract response.
// The backend action calls this with identifiers and metadata it resolved itself; nothing here reads the
// network, the clock or secrets.

import { align } from "./align";
import { AZURE_PROVIDER_NAME, MAX_ASSESSED_AUDIO_MS, parseAzureResponse, ticksToEndMs, ticksToStartMs } from "./azure";
import type { AzureRecognition } from "./azure";
import { NORMALIZATION_VERSION, SUPPORTED_LOCALES, tokenize } from "./normalize";
import { AssessmentError, RUBRIC_VERSION, SCHEMA_VERSION } from "./types";
import type {
  AssessmentResponseWithoutCoaching,
  Measurement,
  ResponseEnvelope,
  Scores,
  UnscorableReason,
  WordResult,
} from "./types";

/** Boundaries may overshoot the recording by this much (tick rounding, encoder padding) and are clipped; larger deviations are invalid. */
export const BOUNDARY_TOLERANCE_MS = 50;

export const RFC3339 = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$/;

export interface AssessAttemptInput {
  assessmentId: string;
  attemptId: string;
  lineId: string;
  /** Positive integer revision of the immutable reference transcript. */
  referenceVersion: number;
  locale: string;
  /** RFC 3339 capture time from validated attempt metadata. */
  recordedAt: string;
  /** Reference text resolved from stored project data, never from the client. */
  referenceText: string;
  /** The source line's dialogue window in integer milliseconds. The window is only used for timingFit. */
  targetWindowMs: { startMs: number; endMs: number };
  /** Duration of the uploaded WAV in integer milliseconds (inspectWav derives it). */
  recordingDurationMs: number;
  /** The HTTP result of the Azure call: status code and parsed JSON body. Not inspected for unsupported locales. */
  provider?: { httpStatus: number; body: unknown };
}

export interface AssessmentEvidence {
  provider: { name: string; locale: string; recognitionStatus: string; snr: number | null; completenessScore: number | null };
  normalizationVersion: string;
  /** Unrounded engine and computed values, for coaching that must not contradict the displayed rounding. */
  rawScores: { pronunciation: number | null; wordAccuracy: number | null; fluency: number | null; languageOverall: number | null; timingFit: number | null };
  referenceTokenCount: number;
  counts: { matched: number; substituted: number; omitted: number; inserted: number };
  /** Reference indices grouped by the alignment outcome. mispronounced lists matched words the engine flagged ErrorType=Mispronunciation (accuracy below 60). */
  words: { mispronounced: number[]; substituted: number[]; omitted: number[]; inserted: number };
  /** Always "acoustic" on the Azure path. */
  measurement: Measurement;
  timing: { spokenStartMs: number; spokenEndMs: number; spokenDurationMs: number; targetDurationMs: number; deltaMs: number } | null;
  unscorableReason: UnscorableReason | null;
}

/** Evaluator provenance for storage next to the assessment (grading contract, "Persistence, versions, and progress"). */
export interface AssessmentProvenance {
  evaluator: string;
  measurement: Measurement;
  /** Azure does not disclose a model version in the REST response, so none is invented. */
  modelVersion: null;
  evaluatorConfigVersion: string;
}

export const EVALUATOR_CONFIG_VERSION = "azure-rest-short-audio-v1";

export interface AssessmentOutcome {
  response: AssessmentResponseWithoutCoaching;
  evidence: AssessmentEvidence;
  provenance: AssessmentProvenance;
}

const roundHalfUp = (value: number): number => Math.floor(value + 0.5 + 1e-9);

/** 0.45 pronunciation + 0.35 word accuracy + 0.20 fluency, rounded half up, from unrounded components. */
export function computeLanguageOverall(pronunciation: number, wordAccuracy: number, fluency: number): number {
  return roundHalfUp(0.45 * pronunciation + 0.35 * wordAccuracy + 0.2 * fluency);
}

/** 100 x max(0, 1 - |d - t| / t), rounded half up, using integer arithmetic so halves are exact. */
export function computeTimingFit(spokenMs: number, targetMs: number): number {
  const numerator = 100 * Math.max(0, targetMs - Math.abs(spokenMs - targetMs));
  return Math.floor((2 * numerator + targetMs) / (2 * targetMs));
}

function checkInput(input: AssessAttemptInput): void {
  const bad = (problem: string) => new AssessmentError("invalid_input", `Assessment input ${problem}`);
  for (const key of ["assessmentId", "attemptId", "lineId", "locale", "referenceText"] as const) {
    if (typeof input[key] !== "string" || input[key].trim() === "") throw bad(`${key} must be a non-empty string`);
  }
  if (!Number.isInteger(input.referenceVersion) || input.referenceVersion < 1) throw bad("referenceVersion must be a positive integer");
  if (!RFC3339.test(input.recordedAt) || Number.isNaN(Date.parse(input.recordedAt))) throw bad("recordedAt must be an RFC 3339 timestamp");
  if (!Number.isInteger(input.recordingDurationMs) || input.recordingDurationMs <= 0) throw bad("recordingDurationMs must be a positive integer");
  if (input.recordingDurationMs > MAX_ASSESSED_AUDIO_MS) throw bad(`recordingDurationMs exceeds the ${MAX_ASSESSED_AUDIO_MS} ms assessment limit`);
  const window = input.targetWindowMs;
  if (!Number.isInteger(window?.startMs) || !Number.isInteger(window?.endMs) || window.startMs < 0 || window.endMs <= window.startMs) {
    throw bad("targetWindowMs must be integer milliseconds with 0 <= startMs < endMs");
  }
}

function checkProviderStatus(httpStatus: number): void {
  if (httpStatus === 200) return;
  const context = { httpStatus };
  if (httpStatus === 401 || httpStatus === 403) throw new AssessmentError("provider_auth", "Azure rejected the credentials or endpoint", context);
  if (httpStatus === 408 || httpStatus === 429 || httpStatus >= 500) throw new AssessmentError("provider_unavailable", "Azure is temporarily unavailable", context);
  throw new AssessmentError("provider_rejected", "Azure rejected the request (unsupported language or unreadable audio)", context);
}

interface SpokenToken {
  norm: string;
  display: string;
  startMs: number;
  endMs: number;
  accuracy: number | null;
  mispronounced: boolean;
}

/** Clips a measured span to the recording within BOUNDARY_TOLERANCE_MS and rejects anything the recording cannot contain. */
function boundaries(word: string, startTicks: number, durationTicks: number, recordingMs: number): { startMs: number; endMs: number } {
  const startMs = Math.max(0, ticksToStartMs(startTicks));
  const rawEnd = ticksToEndMs(startTicks + durationTicks);
  const endMs = Math.min(rawEnd, recordingMs);
  if (rawEnd - recordingMs > BOUNDARY_TOLERANCE_MS || startMs >= endMs) {
    throw new AssessmentError("invalid_provider_response", "Azure word boundaries fall outside the recording", { word: word.length, startMs, endMs: rawEnd, recordingMs });
  }
  return { startMs, endMs };
}

function spokenTokens(recognition: AzureRecognition, recordingMs: number): SpokenToken[] {
  const tokens: SpokenToken[] = [];
  for (const entry of recognition.words) {
    if (entry.errorType === "Omission") continue;
    const span = boundaries(entry.word, entry.startTicks!, entry.durationTicks!, recordingMs);
    // One engine word can normalize to several tokens (a spelled-out number); they share the word's span and score.
    for (const token of tokenize(entry.word)) {
      tokens.push({ ...token, ...span, accuracy: entry.accuracyScore, mispronounced: entry.errorType === "Mispronunciation" });
    }
  }
  return tokens;
}

export function assessAttempt(input: AssessAttemptInput): AssessmentOutcome {
  checkInput(input);

  const envelope = (recognizedText: string | null): ResponseEnvelope => ({
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
    measurement: "acoustic",
  });
  const provenance: AssessmentProvenance = {
    evaluator: AZURE_PROVIDER_NAME,
    measurement: "acoustic",
    modelVersion: null,
    evaluatorConfigVersion: EVALUATOR_CONFIG_VERSION,
  };
  const unscorable = (reason: UnscorableReason, recognizedText: string | null, recognitionStatus: string, partial?: Partial<AssessmentEvidence>): AssessmentOutcome => ({
    response: { ...envelope(recognizedText), status: "unscorable", reason, scores: null, unavailableMetrics: [], wordResults: [] },
    evidence: {
      provider: { name: AZURE_PROVIDER_NAME, locale: input.locale, recognitionStatus, snr: null, completenessScore: null },
      normalizationVersion: NORMALIZATION_VERSION,
      rawScores: { pronunciation: null, wordAccuracy: null, fluency: null, languageOverall: null, timingFit: null },
      referenceTokenCount: 0,
      counts: { matched: 0, substituted: 0, omitted: 0, inserted: 0 },
      words: { mispronounced: [], substituted: [], omitted: [], inserted: 0 },
      timing: null,
      measurement: "acoustic",
      unscorableReason: reason,
      ...partial,
    },
    provenance,
  });

  if (!SUPPORTED_LOCALES.includes(input.locale)) return unscorable("unsupported_locale", null, "not_requested");

  const reference = tokenize(input.referenceText);
  if (reference.length === 0) throw new AssessmentError("invalid_reference", "The reference text has no tokens to assess");
  if (!input.provider) throw new AssessmentError("invalid_input", "Assessment input provider result is required for a supported locale");
  checkProviderStatus(input.provider.httpStatus);

  const parsed = parseAzureResponse(input.provider.body);
  if (parsed.kind === "unscorable") {
    const outcome = unscorable(parsed.reason, parsed.recognizedText, parsed.recognitionStatus, { referenceTokenCount: reference.length });
    return outcome;
  }

  const { recognition } = parsed;
  const spoken = spokenTokens(recognition, input.recordingDurationMs);
  if (spoken.length === 0) {
    return unscorable("insufficient_speech", recognition.displayText.trim() === "" ? null : recognition.displayText, recognition.recognitionStatus, {
      referenceTokenCount: reference.length,
    });
  }

  const alignment = align(
    reference.map((token) => token.norm),
    spoken.map((token) => token.norm),
  );
  const wordResults: WordResult[] = [];
  const mispronounced: number[] = [];
  const substituted: number[] = [];
  const omitted: number[] = [];
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
    if (step.op === "insert") {
      const heard = spoken[step.recognizedIndex]!;
      wordResults.push({
        referenceWordIndex: null,
        expected: null,
        recognized: heard.display,
        textStatus: "inserted",
        pronunciationScore: null,
        pronunciationUnavailableReason: "unaligned_word",
        startMs: heard.startMs,
        endMs: heard.endMs,
      });
      continue;
    }
    const heard = spoken[step.recognizedIndex]!;
    const base = {
      referenceWordIndex: step.referenceIndex,
      expected: reference[step.referenceIndex]!.display,
      recognized: heard.display,
      startMs: heard.startMs,
      endMs: heard.endMs,
    };
    if (step.op === "substitute") {
      substituted.push(step.referenceIndex);
      wordResults.push({ ...base, textStatus: "substituted", pronunciationScore: null, pronunciationUnavailableReason: "unaligned_word" });
      continue;
    }
    if (heard.mispronounced) mispronounced.push(step.referenceIndex);
    wordResults.push(
      heard.accuracy === null
        ? { ...base, textStatus: "matched", pronunciationScore: null, pronunciationUnavailableReason: "insufficient_evidence" }
        : { ...base, textStatus: "matched", pronunciationScore: roundHalfUp(heard.accuracy) },
    );
  }

  const errors = alignment.substituted + alignment.omitted + alignment.inserted;
  const wordAccuracy = 100 * Math.max(0, 1 - errors / reference.length);
  const spokenStartMs = Math.min(...spoken.map((token) => token.startMs));
  const spokenEndMs = Math.max(...spoken.map((token) => token.endMs));
  const spokenDurationMs = spokenEndMs - spokenStartMs;
  const targetDurationMs = input.targetWindowMs.endMs - input.targetWindowMs.startMs;
  const timingFit = computeTimingFit(spokenDurationMs, targetDurationMs);
  const languageOverall = 0.45 * recognition.accuracyScore + 0.35 * wordAccuracy + 0.2 * recognition.fluencyScore;

  const scores: Scores = {
    languageOverall: computeLanguageOverall(recognition.accuracyScore, wordAccuracy, recognition.fluencyScore),
    pronunciation: roundHalfUp(recognition.accuracyScore),
    wordAccuracy: roundHalfUp(wordAccuracy),
    fluency: roundHalfUp(recognition.fluencyScore),
    timingFit,
  };

  return {
    response: {
      ...envelope(recognition.displayText),
      status: "scored",
      scores,
      unavailableMetrics: [],
      wordResults,
    },
    evidence: {
      provider: {
        name: AZURE_PROVIDER_NAME,
        locale: input.locale,
        recognitionStatus: recognition.recognitionStatus,
        snr: recognition.snr,
        completenessScore: recognition.completenessScore,
      },
      normalizationVersion: NORMALIZATION_VERSION,
      rawScores: {
        pronunciation: recognition.accuracyScore,
        wordAccuracy,
        fluency: recognition.fluencyScore,
        languageOverall,
        timingFit,
      },
      referenceTokenCount: reference.length,
      counts: { matched: alignment.matched, substituted: alignment.substituted, omitted: alignment.omitted, inserted: alignment.inserted },
      words: { mispronounced, substituted, omitted, inserted: alignment.inserted },
      timing: { spokenStartMs, spokenEndMs, spokenDurationMs, targetDurationMs, deltaMs: spokenDurationMs - targetDurationMs },
      measurement: "acoustic",
      unscorableReason: null,
    },
    provenance,
  };
}
