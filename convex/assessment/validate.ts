// Runtime validator for the complete grading-contract response, coaching included.
// Mirrored by the Swift validator in Dubbing/Assessment/. It checks structure, enums, score bounds, null reasons,
// reference indices, alignment coverage, timestamps and recording bounds, and recomputes wordAccuracy from the
// alignment so a response whose score disagrees with its own word results is rejected.

import { RFC3339 } from "./assess";
import { SUPPORTED_LOCALES, tokenize } from "./normalize";
import {
  AssessmentValidationError,
  FOCUS_KINDS,
  MEASUREMENTS,
  METRICS,
  PRONUNCIATION_UNAVAILABLE_REASONS,
  RUBRIC_VERSION,
  SCHEMA_VERSION,
  TEXT_STATUSES,
  UNAVAILABLE_REASONS,
  UNSCORABLE_REASONS,
} from "./types";
import type { AssessmentResponse, Metric } from "./types";

export interface ValidationOptions {
  /** When given, every word boundary must end within the recording. */
  recordingDurationMs?: number;
}

type Json = Record<string, unknown>;
const isRecord = (value: unknown): value is Json => typeof value === "object" && value !== null && !Array.isArray(value);
const isScore = (value: unknown): value is number => typeof value === "number" && Number.isFinite(value) && value >= 0 && value <= 100;
const isNonEmptyString = (value: unknown): value is string => typeof value === "string" && value.trim() !== "";
const oneOf = <T extends string>(allowed: readonly T[], value: unknown): value is T => typeof value === "string" && (allowed as readonly string[]).includes(value);

export function validateAssessmentResponse(value: unknown, options: ValidationOptions = {}): AssessmentResponse {
  const issues: string[] = [];
  const bad = (path: string, problem: string) => issues.push(`${path} ${problem}`);

  if (!isRecord(value)) throw new AssessmentValidationError(["response must be an object"]);
  const r = value;

  if (r.schemaVersion !== SCHEMA_VERSION) bad("schemaVersion", `must be ${SCHEMA_VERSION}`);
  if (r.rubricVersion !== RUBRIC_VERSION) bad("rubricVersion", `must be ${RUBRIC_VERSION}`);
  for (const key of ["assessmentId", "attemptId", "lineId", "locale", "referenceText"]) {
    if (!isNonEmptyString(r[key])) bad(key, "must be a non-empty string");
  }
  if (!Number.isInteger(r.referenceVersion) || (r.referenceVersion as number) < 1) bad("referenceVersion", "must be a positive integer");
  if (typeof r.recordedAt !== "string" || !RFC3339.test(r.recordedAt) || Number.isNaN(Date.parse(r.recordedAt))) bad("recordedAt", "must be an RFC 3339 timestamp");
  if (r.recognizedText !== null && typeof r.recognizedText !== "string") bad("recognizedText", "must be a string or null");
  if (!oneOf(MEASUREMENTS, r.measurement)) bad("measurement", "must be acoustic or transcript_only");
  // A missing or unknown value is read as transcript_only, so it gets no acoustic scores.
  const transcriptOnly = r.measurement !== "acoustic";

  const coaching = r.coaching;
  let focusLimit = Number.POSITIVE_INFINITY;
  const checkCoaching = (referenceCount: number | null) => {
    if (!isRecord(coaching)) return bad("coaching", "must be an object");
    if (!isNonEmptyString(coaching.summary)) bad("coaching.summary", "must be a non-empty string");
    if (!Array.isArray(coaching.strengths) || !coaching.strengths.every((item) => isNonEmptyString(item))) bad("coaching.strengths", "must be an array of non-empty strings");
    if (!Array.isArray(coaching.focus)) return bad("coaching.focus", "must be an array");
    if (coaching.focus.length > 3) bad("coaching.focus", "may hold at most three suggestions");
    focusLimit = coaching.focus.length;
    coaching.focus.forEach((item: unknown, index: number) => {
      const path = `coaching.focus[${index}]`;
      if (!isRecord(item)) return bad(path, "must be an object");
      if (!oneOf(FOCUS_KINDS, item.kind)) bad(`${path}.kind`, "is not a known focus kind");
      const wordIndex = item.referenceWordIndex;
      if (wordIndex !== null && (!Number.isInteger(wordIndex) || (wordIndex as number) < 0 || (referenceCount !== null && (wordIndex as number) >= referenceCount))) {
        bad(`${path}.referenceWordIndex`, "must be null or a valid reference index");
      }
      if (!isNonEmptyString(item.instruction)) bad(`${path}.instruction`, "must be a non-empty string");
      if (!isNonEmptyString(item.practiceText)) bad(`${path}.practiceText`, "must be a non-empty string");
    });
  };

  if (r.status === "unscorable") {
    if (!oneOf(UNSCORABLE_REASONS, r.reason)) bad("reason", "is not a known unscorable reason");
    if (r.scores !== null) bad("scores", "must be null when unscorable");
    if (!Array.isArray(r.wordResults) || r.wordResults.length !== 0) bad("wordResults", "must be empty when unscorable");
    if (!Array.isArray(r.unavailableMetrics) || r.unavailableMetrics.length !== 0) bad("unavailableMetrics", "must be empty when unscorable");
    checkCoaching(null);
    if (isRecord(coaching) && ((Array.isArray(coaching.strengths) && coaching.strengths.length > 0) || focusLimit > 0)) {
      bad("coaching", "must have empty strengths and focus when unscorable");
    }
  } else if (r.status === "scored") {
    checkScored(r, options, bad, checkCoaching, transcriptOnly);
  } else {
    bad("status", "must be scored or unscorable");
  }

  if (issues.length > 0) throw new AssessmentValidationError(issues);
  return r as unknown as AssessmentResponse;
}

function checkScored(
  r: Json,
  options: ValidationOptions,
  bad: (path: string, problem: string) => void,
  checkCoaching: (referenceCount: number | null) => void,
  transcriptOnly: boolean,
): void {
  const scores = r.scores;
  const measured = new Set<Metric>();
  if (!isRecord(scores)) {
    bad("scores", "must be an object when scored");
  } else {
    for (const metric of METRICS) {
      const entry = scores[metric];
      if (entry === null) continue;
      if (!isScore(entry)) bad(`scores.${metric}`, "must be null or a finite number from 0 through 100");
      else measured.add(metric);
    }
    const components = ["pronunciation", "wordAccuracy", "fluency"] as const;
    const allComponents = components.every((metric) => measured.has(metric));
    if (!allComponents && measured.has("languageOverall")) bad("scores.languageOverall", "must be null when a component is missing");
    if (allComponents && !measured.has("languageOverall")) bad("scores.languageOverall", "must be present when every component is measured");
    if (!components.some((metric) => measured.has(metric))) bad("scores", "scored responses need at least one language measurement");
  }

  if (transcriptOnly && isRecord(scores)) {
    for (const metric of ["pronunciation", "fluency"] as const) {
      if (scores[metric] !== null) bad(`scores.${metric}`, "must be null unless measurement is acoustic");
    }
  }

  const nullMetrics = new Map<string, string>();
  if (!Array.isArray(r.unavailableMetrics)) {
    bad("unavailableMetrics", "must be an array");
  } else {
    r.unavailableMetrics.forEach((item: unknown, index: number) => {
      const path = `unavailableMetrics[${index}]`;
      if (!isRecord(item) || !oneOf(METRICS, item.metric) || !oneOf(UNAVAILABLE_REASONS, item.reason)) return bad(path, "must hold a known metric and reason");
      if (nullMetrics.has(item.metric)) bad(path, `duplicates ${item.metric}`);
      nullMetrics.set(item.metric, item.reason);
      if (item.reason === "missing_components" && item.metric !== "languageOverall") bad(path, "may use missing_components only for languageOverall");
      if (item.metric === "languageOverall" && item.reason !== "missing_components") bad(path, "must use missing_components for languageOverall");
    });
    if (isRecord(scores)) {
      for (const metric of METRICS) {
        const unavailable = nullMetrics.has(metric);
        if (measured.has(metric) && unavailable) bad("unavailableMetrics", `must not list measured metric ${metric}`);
        if (!measured.has(metric) && !unavailable) bad("unavailableMetrics", `must explain null metric ${metric}`);
      }
    }
  }

  const referenceCount = checkWords(r, options, bad, nullMetrics.has("wordAccuracy"), isRecord(scores) ? scores.wordAccuracy : null, transcriptOnly);
  checkCoaching(referenceCount);
}

/** Validates wordResults and returns the reference token count they cover, or null when there is no alignment. */
function checkWords(
  r: Json,
  options: ValidationOptions,
  bad: (path: string, problem: string) => void,
  wordAccuracyUnavailable: boolean,
  wordAccuracy: unknown,
  transcriptOnly: boolean,
): number | null {
  if (!Array.isArray(r.wordResults)) {
    bad("wordResults", "must be an array");
    return null;
  }
  const words: unknown[] = r.wordResults;
  if (words.length === 0) {
    if (!wordAccuracyUnavailable) bad("wordResults", "may be empty only when wordAccuracy is unavailable");
    return null;
  }
  if (wordAccuracyUnavailable) bad("wordAccuracy", "must be measured when an alignment is present");

  let nextReference = 0;
  let errors = 0;
  words.forEach((word, index) => {
    const path = `wordResults[${index}]`;
    if (!isRecord(word)) return bad(path, "must be an object");
    if (!oneOf(TEXT_STATUSES, word.textStatus)) return bad(`${path}.textStatus`, "is not a known status");
    const status = word.textStatus;
    if (status !== "matched") errors++;

    const referenceIndex = word.referenceWordIndex;
    if (status === "inserted") {
      if (referenceIndex !== null || word.expected !== null || !isNonEmptyString(word.recognized)) bad(path, "an insertion needs a recognized token and no reference index or expected token");
    } else {
      if (referenceIndex !== nextReference) bad(`${path}.referenceWordIndex`, `must be ${nextReference}: each reference token appears once, in order`);
      nextReference++;
      if (!isNonEmptyString(word.expected)) bad(`${path}.expected`, "must be a non-empty string");
      if (status === "omitted" && word.recognized !== null) bad(`${path}.recognized`, "must be null for an omission");
      if (status !== "omitted" && !isNonEmptyString(word.recognized)) bad(`${path}.recognized`, "must be a non-empty string");
    }

    const reason = word.pronunciationUnavailableReason;
    if (word.pronunciationScore === null) {
      if (!oneOf(PRONUNCIATION_UNAVAILABLE_REASONS, reason)) bad(`${path}.pronunciationUnavailableReason`, "is required when pronunciationScore is null");
    } else {
      if (!isScore(word.pronunciationScore)) bad(`${path}.pronunciationScore`, "must be null or a number from 0 through 100");
      if (transcriptOnly) bad(`${path}.pronunciationScore`, "must be null unless measurement is acoustic");
      if (reason !== undefined) bad(`${path}.pronunciationUnavailableReason`, "must be absent when pronunciationScore is present");
      if (status === "omitted") bad(`${path}.pronunciationScore`, "must be null for an omission");
    }
    if (status === "omitted" && reason !== "omitted_word") bad(`${path}.pronunciationUnavailableReason`, "must be omitted_word for an omission");

    const { startMs, endMs } = word;
    if (startMs === null || endMs === null) {
      if (startMs !== endMs) bad(path, "startMs and endMs must both be null or both be integers");
      if (status !== "omitted" && startMs !== null) bad(path, "boundary mismatch");
      return;
    }
    if (status === "omitted") return bad(path, "an omission has null boundaries");
    if (!Number.isInteger(startMs) || !Number.isInteger(endMs) || (startMs as number) < 0 || (startMs as number) >= (endMs as number)) {
      bad(path, "boundaries must be integers with 0 <= startMs < endMs");
    } else if (options.recordingDurationMs !== undefined && (endMs as number) > options.recordingDurationMs) {
      bad(path, "endMs exceeds the recording duration");
    }
  });

  if (typeof r.locale === "string" && SUPPORTED_LOCALES.includes(r.locale) && typeof r.referenceText === "string") {
    const expected = tokenize(r.referenceText).length;
    if (nextReference !== expected) bad("wordResults", `must cover ${expected} reference tokens, found ${nextReference}`);
  }
  if (nextReference > 0 && typeof wordAccuracy === "number") {
    const exact = 100 * Math.max(0, 1 - errors / nextReference);
    if (wordAccuracy !== Math.floor(exact + 0.5 + 1e-9)) bad("scores.wordAccuracy", "does not match the substitutions, omissions and insertions in wordResults");
  }
  return nextReference;
}
