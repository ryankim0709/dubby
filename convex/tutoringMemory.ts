import { Supermemory, SupermemoryError } from "supermemory";
import { roundHalfUp } from "./assessment/assess";
import type { ScoreMetric } from "./gradingContract";
import { requiredEnv } from "./lib/env";
import type { LearnerPreferences } from "./tutoringPreferences";
import { applicableRecords, isWordDifficulty, normalizeWord, type SeriesProgress, type TutoringReport } from "./tutoringProgress";
import type { DubContext, TutoringRecord } from "./tutoringRecords";

// API shapes follow the installed supermemory 5.1.2 SDK and the v5 reference at
// https://api.supermemory.ai/v5/openapi, checked 2026-11-15. v3 and v4 shut down on 2026-12-31.
// Convex holds the practice history; these documents are derived text, so they can be rebuilt or deleted.

/** Guides Supermemory's memory extraction; the API caps it at 1500 characters. */
const supportingContext =
  "Notes about one Dubby learner, who practises a language by dubbing short movie lines. Each dub has a score " +
  "card that Dubby measured, with scores out of 100. Remember every dub, its scores and the words that differed, how " +
  "scores and skills change over time, recurring word difficulties, and the learner's stated goals and preferences. " +
  "The scores measure these dubs only; " +
  "do not infer proficiency levels or general grammar ability from repeated movie dialogue.";

/** A word needs this many distinct attempts with an issue before it is written as a recurring difficulty. */
const recurringDifficultyAttempts = 2;

export class TutoringMemoryError extends Error {
  constructor(
    message: string,
    /** Whether trying the same operation again later could succeed. */
    readonly retryable: boolean,
    options?: ErrorOptions,
  ) {
    super(message, options);
  }
}

const hex = (bytes: ArrayBuffer) => [...new Uint8Array(bytes)].map((byte) => byte.toString(16).padStart(2, "0")).join("");

export async function sha256Hex(text: string): Promise<string> {
  return hex(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)));
}

/**
 * One Supermemory namespace per learner isolates their memories. It comes only from the authenticated
 * subject, keyed by a server secret so the provider never sees the raw identity and can't reverse it.
 * Namespaces allow letters, digits, "_", ":" and "-", up to 100 characters. The "dubit" prefix is from the
 * app's former name; changing it would orphan every learner's stored memories.
 */
export async function learnerNamespace(subject: string, secret: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const digest = hex(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(subject)));
  return `dubit-u-${digest.slice(0, 32)}`;
}

export type MemoryMetadata = Record<string, string | string[]>;

export type MemoryDocument = {
  /** Deterministic from the source, so a retry or a re-derivation addresses the same document. */
  id: string;
  kind: "attempt" | "dub" | "trend" | "difficulty" | "preferences";
  content: string;
  /** When the source happened, for attempt notes. */
  date?: string;
  metadata: MemoryMetadata;
};

const quote = (words: readonly string[]) => words.map((word) => `"${word}"`).join(", ");
/** Scores are written as whole numbers on the contract's 0 to 100 scale. */
const whole = (value: number) => String(roundHalfUp(value));
const count = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`;

const scoreNames: Record<ScoreMetric, string> = {
  languageOverall: "overall language score",
  pronunciation: "pronunciation",
  wordAccuracy: "words said",
  fluency: "fluency",
  timingFit: "timing",
};
const metricOrder: readonly ScoreMetric[] = ["languageOverall", "pronunciation", "wordAccuracy", "fluency", "timingFit"];

/** Words of a scored attempt with an issue: script words that were swapped or missed, or acoustic flags. */
function flaggedWords(record: TutoringRecord, wantScript: boolean): string[] {
  const { assessment } = record;
  if (assessment.status === "unscorable") return [];
  const acoustic = record.evaluator.measurement === "acoustic";
  return [
    ...new Set(
      assessment.wordResults.flatMap((word) => {
        const isScript = word.textStatus === "substituted" || word.textStatus === "omitted";
        if (word.expected === null || !isWordDifficulty(word, acoustic) || isScript !== wantScript) return [];
        return [normalizeWord(word.expected, assessment.locale)];
      }),
    ),
  ];
}

/** What differed from the script, word by word: what was said instead, what was missed, what was added. */
function scriptDifferences(record: TutoringRecord): string[] {
  if (record.assessment.status === "unscorable") return [];
  return record.assessment.wordResults.flatMap((word) => {
    switch (word.textStatus) {
      case "substituted":
        return [`said "${word.recognized}" for "${word.expected}"`];
      case "omitted":
        return [`missed "${word.expected}"`];
      case "inserted":
        return [`added "${word.recognized}"`];
      case "matched":
        return [];
    }
  });
}

/** A line's measured scores, led by the dub score sheet's line score when the attempt has one. */
function scoreSummary(record: TutoringRecord): string | null {
  const { assessment, sheet } = record;
  if (assessment.status === "unscorable") return null;
  const parts = [
    ...(sheet === undefined || sheet.lineScore === null ? [] : [`line score ${whole(sheet.lineScore)}`]),
    ...metricOrder.flatMap((metric) => {
      const value = assessment.scores[metric];
      return value === null ? [] : [`${scoreNames[metric]} ${whole(value)}`];
    }),
  ];
  return parts.length === 0 ? null : parts.join(", ");
}

function attemptDocument(record: TutoringRecord, id: string): MemoryDocument {
  const { assessment, dub } = record;
  const where = dub === undefined ? "" : ` as ${dub.characterName} in "${dub.sceneTitle}"`;
  const practised = `Practice note: on ${assessment.recordedAt.slice(0, 10)} the learner dubbed the ${assessment.locale} line "${assessment.referenceText}"${where}.`;
  let outcome: string;
  if (assessment.status === "unscorable") {
    outcome = `The recording could not be assessed (${assessment.reason.replaceAll("_", " ")}).`;
  } else {
    const acoustic = record.evaluator.measurement === "acoustic";
    const scores = scoreSummary(record);
    const differences = scriptDifferences(record);
    const pronunciation = flaggedWords(record, false);
    const parts = [
      ...(assessment.recognizedText === null ? [] : [`Heard: "${assessment.recognizedText}".`]),
      ...(scores === null ? [] : [`Scores out of 100: ${scores}.`]),
      ...(differences.length > 0 ? [`Differences from the script: ${differences.join("; ")}.`] : []),
      ...(pronunciation.length === 0 ? [] : [`Words flagged by an acoustic pronunciation check: ${quote(pronunciation)}.`]),
      ...(differences.length + pronunciation.length === 0 && assessment.wordResults.length > 0 ? ["Every word matched the script."] : []),
      ...(acoustic ? [] : ["Judged by script agreement only; pronunciation wasn't measured."]),
    ];
    outcome = parts.join(" ");
  }
  return {
    id,
    kind: "attempt",
    content: `${practised} ${outcome}`.trim(),
    date: assessment.recordedAt,
    metadata: {
      kind: "attempt",
      locale: assessment.locale,
      lineId: assessment.lineId,
      attemptId: assessment.attemptId,
      assessmentId: assessment.assessmentId,
    },
  };
}

/** The dub score sheet's score card, as the learner saw it on the result screen. */
function scoreCardText(card: DubContext["scoreCard"]): string {
  const totals = [
    card.dubScore === null ? "no dub score, since no line could be scored" : `dub score ${whole(card.dubScore)}`,
    ...(card.wordAccuracy === null ? [] : [`words said ${whole(card.wordAccuracy)}`]),
    ...(card.timingFit === null ? [] : [`timing ${whole(card.timingFit)}`]),
  ];
  const counts = [
    `${card.linesScored} of ${count(card.linesDubbed, "line", "lines")} scored`,
    ...(card.linesUnscorable === 0 ? [] : [`${card.linesUnscorable} could not be assessed`]),
    ...(card.linesFailed === 0 ? [] : [`${card.linesFailed} failed to score`]),
  ];
  return `Score card (dub-v1, out of 100): ${totals.join(", ")}; ${counts.join(", ")}.`;
}

/** For sessions without a score card: each measured metric averaged over the scored lines. */
function measuredAverages(records: readonly TutoringRecord[]): string {
  const scored = records.flatMap((record) => (record.assessment.status === "scored" ? [record.assessment.scores] : []));
  const averages = metricOrder.flatMap((metric) => {
    const values = scored.flatMap((scores) => (scores[metric] === null ? [] : [scores[metric]]));
    return values.length === 0 ? [] : [`${scoreNames[metric]} ${whole(values.reduce((sum, value) => sum + value, 0) / values.length)}`];
  });
  return averages.length === 0 ? "None of its takes could be assessed." : `Measured averages out of 100: ${averages.join(", ")}.`;
}

function lineSummary(record: TutoringRecord): string {
  const { assessment } = record;
  const line = `"${assessment.referenceText}"`;
  if (assessment.status === "unscorable") return `${line} could not be assessed (${assessment.reason.replaceAll("_", " ")}).`;
  const differences = scriptDifferences(record);
  return `${line}: ${scoreSummary(record) ?? "no scores"}; ${differences.length === 0 ? "every word right" : differences.join(", ")}.`;
}

/** One dubbing session as a whole: what was dubbed, its score card, and every line's result. */
function dubDocument(id: string, records: readonly TutoringRecord[]): MemoryDocument {
  const ordered = [...records].sort(
    (a, b) => a.assessment.recordedAt.localeCompare(b.assessment.recordedAt) || a.assessment.attemptId.localeCompare(b.assessment.attemptId),
  );
  const first = ordered[0]!;
  const { locale } = first.assessment;
  const date = first.assessment.recordedAt.slice(0, 10);
  const { dub } = first;
  const header =
    dub === undefined ? `Dub session on ${date} in ${locale}.` : `Dub session on ${date} in ${locale}: scene "${dub.sceneTitle}", dubbing as ${dub.characterName}.`;
  const card = dub === undefined ? measuredAverages(ordered) : scoreCardText(dub.scoreCard);
  return {
    id,
    kind: "dub",
    content: `${header} ${card} Lines: ${ordered.map(lineSummary).join(" ")}`,
    date: first.assessment.recordedAt,
    metadata: { kind: "dub", locale, sessionId: first.sessionId, attemptIds: ordered.map((record) => record.assessment.attemptId) },
  };
}

type DubScorePoint = { date: string; dubScore: number };

/** The dub scores of one series, oldest first, one per dub. */
function dubHistory(records: readonly TutoringRecord[], series: SeriesProgress): DubScorePoint[] {
  const bySession = new Map<string, DubScorePoint>();
  for (const record of records) {
    const dubScore = record.dub?.scoreCard.dubScore ?? null;
    const inSeries =
      record.assessment.locale === series.locale &&
      record.assessment.rubricVersion === series.rubricVersion &&
      record.evaluator.provider === series.evaluator.provider &&
      record.evaluator.configVersion === series.evaluator.configVersion;
    if (dubScore === null || !inSeries) continue;
    const date = record.assessment.recordedAt.slice(0, 10);
    const known = bySession.get(record.sessionId);
    if (known === undefined || date < known.date) bySession.set(record.sessionId, { date, dubScore });
  }
  return [...bySession.entries()]
    .sort(([aId, a], [bId, b]) => a.date.localeCompare(b.date) || aId.localeCompare(bId))
    .map(([, point]) => point);
}

/** How one series' scores, skills, and words have moved over time. */
function trendDocument(id: string, series: SeriesProgress, dubs: readonly DubScorePoint[]): MemoryDocument {
  const basis = series.pronunciationBasis === "acoustic" ? "an acoustic pronunciation check" : "script agreement";
  const span = series.daily.length === 0 ? "" : ` from ${series.daily[0]!.date} to ${series.daily[series.daily.length - 1]!.date}`;
  const skills = series.skills.flatMap((skill) => {
    if (skill.latest === null) return [];
    const name = scoreNames[skill.metric];
    if (skill.first === null || skill.direction === "insufficient_history") return [`${name} ${whole(skill.latest.value)} so far`];
    return [`${name} from ${whole(skill.first.value)} on ${skill.first.date} to ${whole(skill.latest.value)} on ${skill.latest.date} (${skill.direction})`];
  });
  const improved = series.words.filter((word) => word.status === "improved").map((word) => word.word);
  const persistent = series.words.filter((word) => word.status === "persistent_weakness").map((word) => word.word);
  const parts = [
    `Practice so far: ${count(series.volume.sessions, "dub", "dubs")} on ${count(series.volume.practiceDays, "practice day", "practice days")}.`,
    ...(dubs.length === 0 ? [] : [`Dub scores out of 100, oldest first: ${dubs.slice(-10).map((point) => `${whole(point.dubScore)} on ${point.date}`).join(", ")}.`]),
    skills.length === 0 ? "No skill has been measured yet." : `Skills out of 100: ${skills.join("; ")}.`,
    ...(series.skills.some((skill) => skill.direction !== "insufficient_history") ? [] : ["There isn't practice on enough different days to call a trend yet."]),
    ...(improved.length === 0 ? [] : [`Words the learner now gets right: ${quote(improved.slice(0, 5))}.`]),
    ...(persistent.length === 0 ? [] : [`Words still giving trouble: ${quote(persistent.slice(0, 5))}.`]),
  ];
  return {
    id,
    kind: "trend",
    content: `Progress trend in ${series.locale}, judged by ${basis}${span}: ${parts.join(" ")}`,
    metadata: { kind: "trend", locale: series.locale, evaluator: series.evaluator.provider },
  };
}

/**
 * The memory documents that should exist for a learner right now, one per source: each attempt, each dub
 * with its score card, one trend per progress series, recurring difficulties, and preferences. Content is
 * plain text carrying the scores Convex measured, and metadata names the Convex records that back it.
 */
export async function deriveMemoryDocuments(
  records: readonly TutoringRecord[],
  report: TutoringReport,
  preferences: LearnerPreferences | null,
): Promise<MemoryDocument[]> {
  const documents: MemoryDocument[] = [];
  const applicable = applicableRecords(records);
  for (const record of applicable) {
    const id = `attempt-${(await sha256Hex(record.assessment.attemptId)).slice(0, 40)}`;
    documents.push(attemptDocument(record, id));
  }
  const sessions = new Map<string, TutoringRecord[]>();
  for (const record of applicable) sessions.set(record.sessionId, [...(sessions.get(record.sessionId) ?? []), record]);
  for (const sessionId of [...sessions.keys()].sort()) {
    documents.push(dubDocument(`dub-${(await sha256Hex(sessionId)).slice(0, 40)}`, sessions.get(sessionId)!));
  }
  for (const series of report.series) {
    const key = [series.locale, series.rubricVersion, series.evaluator.provider, series.evaluator.configVersion].join("|");
    documents.push(trendDocument(`trend-${(await sha256Hex(key)).slice(0, 40)}`, series, dubHistory(applicable, series)));
  }
  for (const series of report.series) {
    for (const word of series.words) {
      if (word.status === "improved" || word.issueAttemptIds.length < recurringDifficultyAttempts) continue;
      const basis = word.pronunciationIssueCount > 0 ? "an acoustic pronunciation check and the script" : "script agreement";
      documents.push({
        id: `difficulty-${(await sha256Hex(`${series.locale}|${word.word}`)).slice(0, 40)}`,
        kind: "difficulty",
        content:
          `Recurring difficulty in ${series.locale}: the learner keeps struggling with "${word.word}" ` +
          `(seen on ${word.issueAttemptIds.length} attempts, judged by ${basis}).`,
        metadata: { kind: "difficulty", locale: series.locale, word: word.word, attemptIds: [...word.issueAttemptIds] },
      });
    }
  }
  if (preferences !== null) {
    const parts = [
      ...(preferences.targetLocale === undefined ? [] : [`practising ${preferences.targetLocale}`]),
      `focus: ${preferences.focus.replaceAll("_", " ")}`,
      `challenge: ${preferences.challenge}`,
      ...(preferences.avoidLineIds.length === 0 ? [] : [`avoids lines ${quote(preferences.avoidLineIds)}`]),
      ...(preferences.goalNote === undefined ? [] : [`goal, in the learner's words: "${preferences.goalNote}"`]),
    ];
    documents.push({
      id: "preferences",
      kind: "preferences",
      content: `Learner preferences, stated by the learner: ${parts.join("; ")}.`,
      metadata: { kind: "preferences" },
    });
  }
  return documents;
}

/** Detects a change in a document's content or backing records, so unchanged documents aren't resent. */
export async function documentHash(document: MemoryDocument): Promise<string> {
  return sha256Hex(JSON.stringify([document.content, document.date ?? null, document.metadata]));
}

/** Everything tutoring needs from long-term memory. Tests supply a fake; production uses Supermemory. */
export interface TutoringMemoryStore {
  upsert(namespace: string, document: MemoryDocument): Promise<void>;
  /** Deletes by document ID; a document that is already gone counts as deleted. */
  remove(namespace: string, ids: readonly string[]): Promise<void>;
  /** Retrieved snippets, best first. They are context only and never a measurement. */
  search(namespace: string, query: string, limit: number): Promise<string[]>;
}

function wrap(operation: string, error: unknown): never {
  if (error instanceof TutoringMemoryError) throw error;
  if (error instanceof SupermemoryError) {
    const status = error.statusCode;
    // 409: a document that is still processing can refuse a change until processing finishes.
    const retryable = status === undefined || status === 408 || status === 409 || status === 429 || status >= 500;
    throw new TutoringMemoryError(`Supermemory ${operation} failed with status ${status ?? "none"}: ${error.message}`, retryable, { cause: error });
  }
  throw new TutoringMemoryError(`Supermemory ${operation} failed: ${String(error)}`, true, { cause: error });
}

export class SupermemoryStore implements TutoringMemoryStore {
  constructor(private readonly client: Supermemory) {}

  /**
   * Replaces the document's content. Supermemory's add appends to a document that already has the ID rather
   * than replacing it, so an existing document is updated in place and only a missing one is added.
   */
  async upsert(namespace: string, document: MemoryDocument): Promise<void> {
    const fields = {
      content: document.content,
      metadata: document.metadata,
      ...(document.date === undefined ? {} : { date: document.date }),
      supportingContext,
      taskType: "memory" as const,
    };
    let response: { status: string };
    try {
      response = await this.client.documents.update(namespace, document.id, fields);
    } catch (error) {
      if (!(error instanceof SupermemoryError && error.statusCode === 404)) wrap("update", error);
      try {
        response = await this.client.add(namespace, { id: document.id, ...fields });
      } catch (addError) {
        wrap("add", addError);
      }
    }
    if (response.status === "failed") {
      throw new TutoringMemoryError(`Supermemory processing failed for document ${document.id}`, true);
    }
  }

  async remove(namespace: string, ids: readonly string[]): Promise<void> {
    try {
      const response = await this.client.documents.delete(namespace, { ids: [...ids] });
      const failures = response.errors.filter((failure) => !/not found/i.test(failure.error));
      if (failures.length === 0) return;
      const details = failures.map((failure) => `${failure.id}: ${failure.error}`).join("; ");
      // A document that is still being processed can't be deleted yet, so the delete has to wait.
      throw new TutoringMemoryError(`Supermemory delete failed: ${details}`, failures.every((failure) => /still processing/i.test(failure.error)));
    } catch (error) {
      wrap("delete", error);
    }
  }

  async search(namespace: string, query: string, limit: number): Promise<string[]> {
    try {
      // Hybrid also returns the notes as written: memories extracted from them can lag behind, and live
      // searches in "memories" mode found nothing for notes that were stored and matched as chunks.
      const response = await this.client.search(namespace, { query, searchMode: "hybrid", limit, threshold: 0.4 });
      return [...new Set(response.results.flatMap((result) => {
        const text = result.memory ?? result.chunk;
        return text === undefined ? [] : [text];
      }))];
    } catch (error) {
      return wrap("search", error);
    }
  }
}

export function createMemoryStore(): SupermemoryStore {
  return new SupermemoryStore(new Supermemory({ apiKey: requiredEnv("SUPERMEMORY_API_KEY"), maxRetries: 2, timeoutInSeconds: 20 }));
}

/** Outbox policy: bounded exponential backoff, then an explicit failed state. */
export const maxOutboxAttempts = 6;
const firstBackoffMs = 30_000;
const maxBackoffMs = 3_600_000;

export type OutboxOutcome =
  | { state: "done" }
  | { state: "pending"; attempts: number; nextAttemptAt: number }
  | { state: "failed"; attempts: number };

export function outboxOutcomeAfterFailure(previousAttempts: number, error: unknown, now: number): OutboxOutcome {
  const attempts = previousAttempts + 1;
  const retryable = error instanceof TutoringMemoryError && error.retryable;
  if (!retryable || attempts >= maxOutboxAttempts) return { state: "failed", attempts };
  return { state: "pending", attempts, nextAttemptAt: now + Math.min(firstBackoffMs * 2 ** (attempts - 1), maxBackoffMs) };
}
