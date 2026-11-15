import { Supermemory, SupermemoryError } from "supermemory";
import { requiredEnv } from "./lib/env";
import type { LearnerPreferences } from "./tutoringPreferences";
import { applicableRecords, isWordDifficulty, normalizeWord, type TutoringReport } from "./tutoringProgress";
import type { TutoringRecord } from "./tutoringRecords";

// API shapes follow the installed supermemory 5.1.2 SDK and the v5 reference at
// https://api.supermemory.ai/v5/openapi, checked 2026-11-15. v3 and v4 shut down on 2026-12-31.
// Convex holds the practice history; these documents are derived text, so they can be rebuilt or deleted.

/** Guides Supermemory's memory extraction; the API caps it at 1500 characters. */
const supportingContext =
  "Notes about one DubIt learner, who practises a language by dubbing short movie lines. Remember recurring " +
  "word difficulties, practised lines, and the learner's stated goals and preferences. The notes carry no scores; " +
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
 * Namespaces allow letters, digits, "_", ":" and "-", up to 100 characters.
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
  kind: "attempt" | "difficulty" | "preferences";
  content: string;
  /** When the source happened, for attempt notes. */
  date?: string;
  metadata: MemoryMetadata;
};

const quote = (words: readonly string[]) => words.map((word) => `"${word}"`).join(", ");

function attemptDocument(record: TutoringRecord, id: string): MemoryDocument {
  const { assessment } = record;
  const practised = `Practice note: on ${assessment.recordedAt.slice(0, 10)} the learner dubbed the ${assessment.locale} line "${assessment.referenceText}".`;
  let outcome: string;
  if (assessment.status === "unscorable") {
    outcome = `The recording could not be assessed (${assessment.reason.replaceAll("_", " ")}).`;
  } else {
    const acoustic = record.evaluator.measurement === "acoustic";
    const flagged = (wantScript: boolean) => [
      ...new Set(
        assessment.wordResults.flatMap((word) => {
          const isScript = word.textStatus === "substituted" || word.textStatus === "omitted";
          if (word.expected === null || !isWordDifficulty(word, acoustic) || isScript !== wantScript) return [];
          return [normalizeWord(word.expected, assessment.locale)];
        }),
      ),
    ];
    const script = flagged(true);
    const pronunciation = flagged(false);
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

/**
 * The memory documents that should exist for a learner right now, one per source. Content is plain
 * qualitative text with no scores, and metadata names the Convex records that back it.
 */
export async function deriveMemoryDocuments(
  records: readonly TutoringRecord[],
  report: TutoringReport,
  preferences: LearnerPreferences | null,
): Promise<MemoryDocument[]> {
  const documents: MemoryDocument[] = [];
  for (const record of applicableRecords(records)) {
    const id = `attempt-${(await sha256Hex(record.assessment.attemptId)).slice(0, 40)}`;
    documents.push(attemptDocument(record, id));
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
      const response = await this.client.search(namespace, { query, searchMode: "memories", limit, threshold: 0.4 });
      return response.results.flatMap((result) => (result.memory === undefined ? [] : [result.memory]));
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
