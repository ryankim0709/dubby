import { Supermemory, SupermemoryError } from "supermemory";
import type { ScoreMetric } from "./gradingContract";
import { requiredEnv } from "./lib/env";
import type { LearnerPreferences } from "./tutoringPreferences";
import { applicableRecords, isWordDifficulty, normalizeWord, type SeriesProgress, type TutoringReport } from "./tutoringProgress";
import type { TutoringRecord } from "./tutoringRecords";

// API shapes follow the installed supermemory 5.1.2 SDK and the v5 reference at
// https://api.supermemory.ai/v5/openapi, checked 2026-11-15. v3 and v4 shut down on 2026-12-31.
// Convex holds the practice history; these documents are derived text, so they can be rebuilt or deleted.

/** Guides Supermemory's memory extraction; the API caps it at 1500 characters. */
const supportingContext =
  "Notes about one Dubby learner, who practises a language by dubbing short movie lines. Remember each dub they " +
  "record, how their skills trend over time, recurring word difficulties, practised lines, and the learner's stated " +
  "goals and preferences. The notes carry no scores; " +
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

function attemptDocument(record: TutoringRecord, id: string): MemoryDocument {
  const { assessment } = record;
  const practised = `Practice note: on ${assessment.recordedAt.slice(0, 10)} the learner dubbed the ${assessment.locale} line "${assessment.referenceText}".`;
  let outcome: string;
  if (assessment.status === "unscorable") {
    outcome = `The recording could not be assessed (${assessment.reason.replaceAll("_", " ")}).`;
  } else {
    const acoustic = record.evaluator.measurement === "acoustic";
    const script = flaggedWords(record, true);
    const pronunciation = flaggedWords(record, false);
    const parts = [
      ...(script.length === 0 ? [] : [`Words that differed from the script: ${quote(script)}.`]),
      ...(pronunciation.length === 0 ? [] : [`Words flagged by an acoustic pronunciation check: ${quote(pronunciation)}.`]),
      ...(script.length + pronunciation.length === 0 && assessment.wordResults.length > 0 ? ["Every word matched the script."] : []),
      ...(acoustic ? [] : ["Feedback was based on script agreement only."]),
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

/** One dubbing session as a whole: which lines it covered and which script words went wrong across it. */
function dubDocument(id: string, records: readonly TutoringRecord[]): MemoryDocument {
  const ordered = [...records].sort(
    (a, b) => a.assessment.recordedAt.localeCompare(b.assessment.recordedAt) || a.assessment.attemptId.localeCompare(b.assessment.attemptId),
  );
  const first = ordered[0]!;
  const { locale } = first.assessment;
  const lines = [...new Set(ordered.map((record) => record.assessment.referenceText))];
  const scored = ordered.filter((record) => record.assessment.status === "scored");
  const differed = [...new Set(scored.flatMap((record) => flaggedWords(record, true)))];
  const outcome =
    scored.length === 0
      ? "None of its takes could be assessed."
      : [
          differed.length === 0 ? "Every assessed line matched the script." : `Words that differed from the script across the dub: ${quote(differed)}.`,
          ...(scored.length < ordered.length ? ["Some takes could not be assessed."] : []),
        ].join(" ");
  return {
    id,
    kind: "dub",
    content: `Dub session: on ${first.assessment.recordedAt.slice(0, 10)} the learner dubbed a scene in ${locale}, recording the lines ${quote(lines)}. ${outcome}`,
    date: first.assessment.recordedAt,
    metadata: { kind: "dub", locale, sessionId: first.sessionId, attemptIds: ordered.map((record) => record.assessment.attemptId) },
  };
}

const skillNames: Record<ScoreMetric, string> = {
  languageOverall: "the overall language score",
  pronunciation: "pronunciation",
  wordAccuracy: "saying the script's words",
  fluency: "fluency",
  timingFit: "fitting each line's timing",
};

/** How one series' skills and words have moved from the first practice day to the latest, in words. */
function trendDocument(id: string, series: SeriesProgress): MemoryDocument {
  const basis = series.pronunciationBasis === "acoustic" ? "an acoustic pronunciation check" : "script agreement";
  const span = series.daily.length === 0 ? "" : ` from ${series.daily[0]!.date} to ${series.daily[series.daily.length - 1]!.date}`;
  const directions = series.skills.flatMap((skill) =>
    skill.direction === "improving" || skill.direction === "declining" || skill.direction === "steady" ? [`${skillNames[skill.metric]} is ${skill.direction}`] : [],
  );
  const improved = series.words.filter((word) => word.status === "improved").map((word) => word.word);
  const persistent = series.words.filter((word) => word.status === "persistent_weakness").map((word) => word.word);
  const parts = [
    directions.length === 0 ? "There isn't practice on enough different days to see a trend yet." : `Since the first practice day, ${directions.join("; ")}.`,
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
 * The memory documents that should exist for a learner right now, one per source: each attempt, each dub,
 * one trend per progress series, recurring difficulties, and preferences. Content is plain qualitative
 * text with no scores, and metadata names the Convex records that back it.
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
    documents.push(trendDocument(`trend-${(await sha256Hex(key)).slice(0, 40)}`, series));
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
    const retryable = status === undefined || status === 408 || status === 429 || status >= 500;
    throw new TutoringMemoryError(`Supermemory ${operation} failed with status ${status ?? "none"}: ${error.message}`, retryable, { cause: error });
  }
  throw new TutoringMemoryError(`Supermemory ${operation} failed: ${String(error)}`, true, { cause: error });
}

export class SupermemoryStore implements TutoringMemoryStore {
  constructor(private readonly client: Supermemory) {}

  async upsert(namespace: string, document: MemoryDocument): Promise<void> {
    try {
      const response = await this.client.add(namespace, {
        id: document.id,
        content: document.content,
        metadata: document.metadata,
        ...(document.date === undefined ? {} : { date: document.date }),
        supportingContext,
        taskType: "memory",
      });
      if (response.status === "failed") {
        throw new TutoringMemoryError(`Supermemory processing failed for document ${document.id}`, true);
      }
    } catch (error) {
      wrap("add", error);
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
