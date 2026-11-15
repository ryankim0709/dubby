import { WORD_BOUNDARY_TOLERANCE_MS } from "./config";
import type { AssessmentOutcome, Coaching } from "../integrations/contracts";

/** The engine or coaching output broke the contract; retrying the same call cannot fix it. */
export class InvalidOutputError extends Error {
  constructor(
    readonly code: "invalid_engine_output" | "invalid_coaching_output",
    message: string,
  ) {
    super(message);
    this.name = "InvalidOutputError";
  }
}

export type ExpectedEcho = {
  attemptId: string;
  lineId: string;
  referenceVersion: number;
  locale: string;
  recordedAt: string;
  referenceText: string;
  recordingDurationMs: number;
};

function invalid(message: string): never {
  throw new InvalidOutputError("invalid_engine_output", message);
}

/**
 * Checks an engine outcome for contract consistency before it is stored: the ids it echoes, null
 * scores matched one-to-one by unavailable metrics, a total that never hides a missing component, a
 * full ordered alignment, word boundaries inside the recording, and no pronunciation value from a
 * transcript-only measurement. It does not recompute totals; the engine owns them.
 * Returns the number of reference words the alignment covers.
 */
export function validateOutcome(outcome: AssessmentOutcome, expected: ExpectedEcho): number {
  const { response } = outcome;
  const measurement = outcome.provenance.measurement;
  if (response.measurement !== measurement || outcome.evidence.measurement !== measurement) {
    invalid("the outcome reports inconsistent measurement kinds");
  }
  if (
    response.attemptId !== expected.attemptId ||
    response.lineId !== expected.lineId ||
    response.referenceVersion !== expected.referenceVersion ||
    response.locale !== expected.locale ||
    response.recordedAt !== expected.recordedAt ||
    response.referenceText !== expected.referenceText
  ) {
    invalid("the outcome doesn't describe the requested attempt");
  }
  if (response.status === "unscorable") return 0;

  const { scores, unavailableMetrics, wordResults } = response;
  const nullMetrics = (Object.keys(scores) as (keyof typeof scores)[]).filter((metric) => scores[metric] === null);
  const listed = unavailableMetrics.map((entry) => entry.metric);
  if (listed.length !== nullMetrics.length || nullMetrics.some((metric) => listed.filter((m) => m === metric).length !== 1)) {
    invalid("each null score needs exactly one unavailable-metric entry, and nothing else may be listed");
  }
  if (unavailableMetrics.some((entry) => entry.reason === "missing_components" && entry.metric !== "languageOverall")) {
    invalid("missing_components applies only to languageOverall");
  }
  const components = [scores.pronunciation, scores.wordAccuracy, scores.fluency];
  if (components.every((value) => value === null)) invalid("a scored result needs at least one language measurement");
  if (scores.languageOverall !== null && components.some((value) => value === null)) {
    invalid("languageOverall can't be reported while a component is unavailable");
  }
  if (measurement === "transcript_only" && (scores.pronunciation !== null || wordResults.some((word) => word.pronunciationScore !== null))) {
    invalid("a transcript-only measurement can't carry pronunciation values");
  }
  if (wordResults.length === 0 && scores.wordAccuracy !== null) invalid("word accuracy needs a word alignment");

  let nextIndex = 0;
  for (const word of wordResults) {
    const isInsertion = word.textStatus === "inserted";
    if (isInsertion !== (word.referenceWordIndex === null) || isInsertion !== (word.expected === null)) {
      invalid("only insertions lack a reference index and expected token");
    }
    if ((word.textStatus === "omitted") !== (word.recognized === null)) invalid("only omissions lack a recognized token");
    if ((word.pronunciationScore === null) !== (word.pronunciationUnavailableReason !== undefined)) {
      invalid("a null word pronunciation needs exactly one unavailable reason");
    }
    if (word.referenceWordIndex !== null) {
      if (word.referenceWordIndex !== nextIndex) invalid("reference words must appear once each, in order");
      nextIndex += 1;
    }
    if ((word.startMs === null) !== (word.endMs === null)) invalid("word boundaries come in pairs");
    if (word.startMs !== null && word.endMs !== null) {
      if (word.startMs >= word.endMs) invalid("startMs must be before endMs");
      if (word.endMs > expected.recordingDurationMs + WORD_BOUNDARY_TOLERANCE_MS) invalid("a word ends after the recording");
    }
  }
  if (wordResults.length > 0 && nextIndex === 0) invalid("the alignment has no reference words");
  return nextIndex;
}

/** Rejects coaching that cites reference words the line doesn't have or invents content for an unscorable take. */
export function validateCoaching(coaching: Coaching, status: "scored" | "unscorable", referenceWordCount: number): void {
  const bad = (message: string): never => {
    throw new InvalidOutputError("invalid_coaching_output", message);
  };
  if (status === "unscorable" && (coaching.strengths.length > 0 || coaching.focus.length > 0)) {
    bad("coaching for an unscorable take has no strengths or focus items");
  }
  for (const item of coaching.focus) {
    if (item.referenceWordIndex !== null && item.referenceWordIndex >= referenceWordCount) {
      bad("coaching cites a reference word outside the line");
    }
  }
}
