/// <reference types="vite/client" />
import { convexTest } from "convex-test";
import { defineSchema } from "convex/server";
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { gradingResult, type GradingResult } from "./gradingContract";
import { createSessionToken } from "./liveAvatar";
import { selectNextExercise } from "./tutoringExercise";
import { defaultPreferences, learnerPreferences } from "./tutoringPreferences";
import { deriveMemoryDocuments, learnerNamespace, outboxOutcomeAfterFailure, TutoringMemoryError } from "./tutoringMemory";
import { buildTutoringReport } from "./tutoringProgress";
import { dubbingSessionResults, recordsForSession, type TutoringRecord } from "./tutoringRecords";
import { tutoringRefs } from "./tutoringRefs";
import { buildEvidencePack, composeReply, replyProblems, templateReply, type EvidencePack } from "./tutoringReply";
import { tutoringTables } from "./tutoringTables";

// Synthetic, contract-shaped grading results. Every fixture passes the contract schema before use.

const lineA = { lineId: "scene_001_line_02", referenceText: "You underestimate my power." };
const lineB = { lineId: "scene_001_line_05", referenceText: "Hello there." };
type Line = typeof lineA;
type Ids = { assessmentId: string; attemptId: string; recordedAt: string };
type Evaluator = { provider: string; modelVersion: string | null; configVersion: string; completedAt: string; measurement: "acoustic" | "transcript_only" };
type WordSpec = { status?: "matched" | "substituted" | "omitted"; pron?: number | null };

const mean = (values: readonly number[]) => values.reduce((sum, value) => sum + value, 0) / values.length;

function scored(ids: Ids, line: Line, words: readonly WordSpec[], fluency: number | null, locale = "en-US"): GradingResult {
  const tokens = line.referenceText.split(" ");
  const faults = words.filter((word) => (word.status ?? "matched") !== "matched").length;
  const wordAccuracy = Math.round(100 * Math.max(0, 1 - faults / tokens.length));
  const pronScores = words.flatMap((word) => (word.pron == null ? [] : [word.pron]));
  const pronunciation = pronScores.length === 0 ? null : Math.round(mean(pronScores));
  const languageOverall =
    pronunciation !== null && fluency !== null ? Math.round(0.45 * pronunciation + 0.35 * wordAccuracy + 0.2 * fluency) : null;
  const unavailable = [
    ...(pronunciation === null ? [{ metric: "pronunciation", reason: "insufficient_evidence" }] : []),
    ...(fluency === null ? [{ metric: "fluency", reason: "insufficient_evidence" }] : []),
    ...(languageOverall === null ? [{ metric: "languageOverall", reason: "missing_components" }] : []),
  ];
  return gradingResult.parse({
    schemaVersion: 1,
    rubricVersion: "language-v1",
    ...ids,
    lineId: line.lineId,
    referenceVersion: 1,
    locale,
    status: "scored",
    referenceText: line.referenceText,
    recognizedText: line.referenceText,
    scores: { languageOverall, pronunciation, wordAccuracy, fluency, timingFit: 90 },
    unavailableMetrics: unavailable,
    wordResults: tokens.map((token, index) => {
      const spec = words[index] ?? {};
      const status = spec.status ?? "matched";
      const pron = status === "omitted" ? null : (spec.pron ?? null);
      return {
        referenceWordIndex: index,
        expected: token,
        recognized: status === "omitted" ? null : status === "substituted" ? "other" : token,
        textStatus: status,
        pronunciationScore: pron,
        ...(pron === null ? { pronunciationUnavailableReason: status === "omitted" ? "omitted_word" : "insufficient_evidence" } : {}),
        startMs: status === "omitted" ? null : index * 500,
        endMs: status === "omitted" ? null : index * 500 + 400,
      };
    }),
    coaching: { summary: "Synthetic coaching.", strengths: [], focus: [] },
  });
}

function unscorable(ids: Ids, line: Line): GradingResult {
  return gradingResult.parse({
    schemaVersion: 1,
    rubricVersion: "language-v1",
    ...ids,
    lineId: line.lineId,
    referenceVersion: 1,
    locale: "en-US",
    status: "unscorable",
    reason: "no_speech",
    referenceText: line.referenceText,
    recognizedText: null,
    scores: null,
    unavailableMetrics: [],
    wordResults: [],
    coaching: { summary: "We couldn't hear speech. Hold the phone closer and try again.", strengths: [], focus: [] },
  });
}

const acousticEvaluator = { provider: "synthetic", modelVersion: null, configVersion: "synthetic-v1", completedAt: "2026-11-10T18:00:00Z", measurement: "acoustic" } as const;
const scriptEvaluator = { ...acousticEvaluator, configVersion: "script-v1", measurement: "transcript_only" } as const;

function session(
  sessionId: string,
  evaluator: Evaluator,
  assessments: GradingResult[],
  completedAt = evaluator.completedAt,
  timeZone = "America/Los_Angeles",
) {
  return dubbingSessionResults.parse({
    sessionId,
    sceneId: "scene_001",
    characterId: "anakin",
    timeZone,
    evaluator: { ...evaluator, completedAt },
    assessments: assessments.map((assessment) => ({ assessment, speakingDurationMs: 2000, recordingDurationMs: 6000 })),
  });
}

function recordsOf(...sessions: ReturnType<typeof session>[]): TutoringRecord[] {
  return sessions.flatMap((item) => {
    const built = recordsForSession(item, "2026-11-15T00:00:00Z");
    if (!built.ok) throw new Error(JSON.stringify(built.issues));
    return built.records;
  });
}

const good = (n: number): WordSpec[] => Array.from({ length: n }, () => ({ pron: 92 }));
const withWeak = (weak: number, score: number, n = 4): WordSpec[] => good(n).map((word, index) => (index === weak ? { pron: score } : word));

// Nov 10 (Pacific): a1 weak on "underestimate"; a2 same day retry better; a3 unscorable.
// Nov 12: a4 regraded (as4 then as4b); a5 at 23:30 Pacific, which is already Nov 13 in UTC.
const history = recordsOf(
  session("s1", acousticEvaluator, [
    scored({ assessmentId: "as1", attemptId: "a1", recordedAt: "2026-11-10T10:00:00-08:00" }, lineA, withWeak(1, 64), 70),
    scored({ assessmentId: "as2", attemptId: "a2", recordedAt: "2026-11-10T10:05:00-08:00" }, lineA, withWeak(1, 66), 80),
    unscorable({ assessmentId: "as3", attemptId: "a3", recordedAt: "2026-11-10T10:10:00-08:00" }, lineB),
  ]),
  session("s2", acousticEvaluator, [
    scored({ assessmentId: "as4", attemptId: "a4", recordedAt: "2026-11-12T09:00:00-08:00" }, lineA, withWeak(1, 62), 82),
  ]),
  session("s2", acousticEvaluator, [
    scored({ assessmentId: "as4b", attemptId: "a4", recordedAt: "2026-11-12T09:00:00-08:00" }, lineA, withWeak(1, 61), 82),
  ], "2026-11-12T20:00:00Z"),
  session("s2", acousticEvaluator, [
    scored({ assessmentId: "as5", attemptId: "a5", recordedAt: "2026-11-12T23:30:00-08:00" }, lineB, good(2), 90),
  ]),
);

describe("grading contract boundary", () => {
  const valid = scored({ assessmentId: "as9", attemptId: "a9", recordedAt: "2026-11-10T10:00:00-08:00" }, lineA, good(4), 80);

  test("rejects a null score without an unavailable-metric reason", () => {
    if (valid.status !== "scored") throw new Error("fixture");
    expect(gradingResult.safeParse({ ...valid, scores: { ...valid.scores, fluency: null } }).success).toBe(false);
  });

  test("rejects a combined score that exists without all its components", () => {
    if (valid.status !== "scored") throw new Error("fixture");
    const broken = { ...valid, scores: { ...valid.scores, fluency: null }, unavailableMetrics: [{ metric: "fluency", reason: "insufficient_evidence" }] };
    expect(gradingResult.safeParse(broken).success).toBe(false);
  });

  test("rejects duplicate reference indices and word spans past the recording", () => {
    if (valid.status !== "scored") throw new Error("fixture");
    const duplicated = { ...valid, wordResults: valid.wordResults.map((word) => ({ ...word, referenceWordIndex: 0 })) };
    expect(gradingResult.safeParse(duplicated).success).toBe(false);
    const late = session("s9", acousticEvaluator, [valid]);
    const tooShort = { ...late, assessments: late.assessments.map((item) => ({ ...item, recordingDurationMs: 1500 })) };
    expect(recordsForSession(tooShort, "2026-11-15T00:00:00Z").ok).toBe(false);
  });

  test("a transcript-only evaluator can't carry a pronunciation score", () => {
    const sneaky = session("s9", scriptEvaluator, [valid]);
    const built = recordsForSession(sneaky, "2026-11-15T00:00:00Z");
    expect(built).toMatchObject({ ok: false });
  });

  test("a transcript-only evaluator can't carry a fluency score either", () => {
    const withFluency = scored({ assessmentId: "as8", attemptId: "a8", recordedAt: "2026-11-10T10:00:00-08:00" }, lineA, [{}, {}, {}, {}], 80);
    expect(recordsForSession(session("s9", scriptEvaluator, [withFluency]), "2026-11-15T00:00:00Z")).toMatchObject({ ok: false });
  });

  test("an unknown measurement kind is treated as transcript-only", () => {
    const parsed = dubbingSessionResults.parse({ ...session("s9", scriptEvaluator, [valid]), evaluator: { ...scriptEvaluator, measurement: "magic" } });
    expect(parsed.evaluator.measurement).toBe("transcript_only");
  });
});

describe("progress", () => {
  const report = buildTutoringReport(history, [], "2026-11-15T00:00:00Z");
  const series = report.series[0]!;

  test("counts each attempt once and groups days in the learner's time zone", () => {
    expect(report.series).toHaveLength(1);
    expect(series.volume).toEqual({ sessions: 2, attempts: 5, scorableAttempts: 4, lines: 2, practiceDays: 2, speakingMs: 10000 });
    expect(series.daily.map((day) => day.date)).toEqual(["2026-11-10", "2026-11-12"]);
  });

  test("first-scorable uses the earliest take per line and day; best-attempt keeps one take's components together", () => {
    const [nov10, nov12] = series.daily;
    // Nov 10, line A: first take pronunciation round(mean(92,64,92,92)) = 85; the retry (79) has the higher languageOverall? check.
    expect(nov10!.firstScorable.pronunciation).toEqual({ value: 85, samples: 1 });
    const firstOverall = nov10!.firstScorable.languageOverall!.value;
    const bestOverall = nov10!.bestAttempt.languageOverall!.value;
    expect(bestOverall).toBeGreaterThan(firstOverall);
    expect(nov10!.bestAttempt.fluency).toEqual({ value: 80, samples: 1 });
    // Nov 12 averages the regraded line A take and line B, one sample each.
    expect(nov12!.firstScorable.pronunciation!.samples).toBe(2);
  });

  test("a regrade replaces its attempt instead of adding one, and adds no speaking time", () => {
    const attempts = series.lines.find((line) => line.lineId === lineA.lineId)!.attempts;
    expect(attempts).toBe(3);
    expect(series.lines.find((line) => line.lineId === lineA.lineId)!.latestAssessmentId).toBe("as4b");
    const withoutRegrade = buildTutoringReport(history.filter((record) => record.assessment.assessmentId !== "as4b"), [], "x");
    expect(withoutRegrade.series[0]!.volume.speakingMs).toBe(series.volume.speakingMs);
  });

  test("repeated-line improvement compares days with a consistent selection rule and keeps its sources", () => {
    expect(series.repeatedLines).toHaveLength(1);
    expect(series.repeatedLines[0]).toMatchObject({ lineId: lineA.lineId, first: { date: "2026-11-10", attemptId: "a1" }, latest: { date: "2026-11-12", attemptId: "a4", assessmentId: "as4b" } });
  });

  test("unscorable attempts add volume but no scores, and unavailable metrics are never zero", () => {
    expect(series.daily.every((day) => Object.values(day.firstScorable).every((sample) => sample === null || sample.value > 0))).toBe(true);
    expect(series.lines.find((line) => line.lineId === lineB.lineId)).toMatchObject({ latestStatus: "scored" });
  });

  test("finds persistent weaknesses from word evidence with their attempts", () => {
    expect(series.words[0]).toMatchObject({ word: "underestimate", status: "persistent_weakness", issueSessions: 2, issueAttemptIds: ["a1", "a2", "a4"], pronunciationIssueCount: 3 });
  });

  test("different locales, rubrics and evaluators form separate series", () => {
    const other = recordsOf(
      session("s3", scriptEvaluator, [scored({ assessmentId: "as20", attemptId: "a20", recordedAt: "2026-11-13T10:00:00-08:00" }, lineA, [{}, {}, {}, {}], null)]),
      session("s4", acousticEvaluator, [scored({ assessmentId: "as21", attemptId: "a21", recordedAt: "2026-11-14T10:00:00-08:00" }, { lineId: "es_1", referenceText: "Hola amigo" }, good(2), 80, "es-ES")]),
    );
    const mixed = buildTutoringReport([...history, ...other], [], "x");
    expect(mixed.series.map((item) => [item.locale, item.pronunciationBasis])).toEqual([["es-ES", "acoustic"], ["en-US", "script_agreement"], ["en-US", "acoustic"]]);
  });

  test("a transcript-only series reports script agreement and never a pronunciation difficulty", () => {
    const scriptOnly = recordsOf(
      session("s3", scriptEvaluator, [
        scored({ assessmentId: "b1", attemptId: "b1", recordedAt: "2026-11-13T10:00:00-08:00" }, lineA, [{}, { status: "substituted" }, {}, {}], null),
      ]),
    );
    const built = buildTutoringReport(scriptOnly, [], "x").series[0]!;
    expect(built.pronunciationBasis).toBe("script_agreement");
    expect(built.words[0]).toMatchObject({ word: "underestimate", scriptIssueCount: 1, pronunciationIssueCount: 0 });
    expect(built.daily[0]!.firstScorable.pronunciation).toBeNull();
    expect(built.daily[0]!.firstScorable.fluency).toBeNull();
    expect(built.unavailableMetrics.map((entry) => entry.metric)).toEqual(["pronunciation", "fluency"]);
    expect(JSON.stringify(built)).not.toMatch(/"pronunciation":\s*[0-9]/);
  });

  test("is deterministic for any input order", () => {
    const shuffled = [...history].reverse();
    expect(buildTutoringReport(shuffled, [], "x")).toEqual(buildTutoringReport(history, [], "x"));
  });
});

describe("next exercise", () => {
  const report = buildTutoringReport(history, [], "x");

  test("drills the persistent weak word, naming the line and the attempts that justify it", () => {
    const exercise = selectNextExercise(report, defaultPreferences);
    expect(exercise).toMatchObject({ kind: "drill_word", practiceText: "underestimate", lineId: lineA.lineId, focus: "pronunciation", basis: "acoustic" });
    expect(exercise.evidence.attemptIds).toEqual(["a1", "a2", "a4"]);
    expect(exercise.evidence.assessmentIds).toContain("as4b");
  });

  test("returns a first-attempt exercise with no history", () => {
    expect(selectNextExercise(buildTutoringReport([], [], "x"), defaultPreferences)).toMatchObject({ kind: "first_attempt", basis: "none", reasonCode: "no_scorable_history" });
  });

  test("avoided lines are never suggested", () => {
    const exercise = selectNextExercise(report, learnerPreferences.parse({ avoidLineIds: [lineA.lineId] }));
    expect(exercise.lineId).not.toBe(lineA.lineId);
  });

  test("a pronunciation preference falls back to script accuracy without an acoustic measurement", () => {
    const scriptOnly = buildTutoringReport(
      recordsOf(session("s3", scriptEvaluator, [scored({ assessmentId: "b1", attemptId: "b1", recordedAt: "2026-11-13T10:00:00-08:00" }, lineA, [{}, { status: "substituted" }, {}, {}], null)])),
      [],
      "x",
    );
    const exercise = selectNextExercise(scriptOnly, learnerPreferences.parse({ focus: "pronunciation" }));
    expect(exercise.focus).toBe("word_accuracy");
    expect(exercise.basis).toBe("script_agreement");
    expect(exercise.reasonCode).toMatch(/script_fallback$/);
    expect(exercise.instruction.toLowerCase()).not.toContain("pronunc");
  });

  test("a fluency preference falls back the same way without an acoustic measurement", () => {
    const scriptOnly = buildTutoringReport(
      recordsOf(session("s3", scriptEvaluator, [scored({ assessmentId: "b1", attemptId: "b1", recordedAt: "2026-11-13T10:00:00-08:00" }, lineA, [{}, { status: "substituted" }, {}, {}], null)])),
      [],
      "x",
    );
    const exercise = selectNextExercise(scriptOnly, learnerPreferences.parse({ focus: "fluency" }));
    expect(exercise.focus).toBe("word_accuracy");
    expect(exercise.reasonCode).toMatch(/script_fallback$/);
    expect(exercise.instruction.toLowerCase()).not.toMatch(/fluen|smooth/);
  });

  test("is stable across repeated calls", () => {
    expect(selectNextExercise(report, defaultPreferences)).toEqual(selectNextExercise(report, defaultPreferences));
  });
});

describe("coach reply evidence and post-check", () => {
  const acoustic = buildEvidencePack(buildTutoringReport(history, [], "x"), selectNextExercise(buildTutoringReport(history, [], "x"), defaultPreferences));
  const scriptRecords = recordsOf(
    session("s3", scriptEvaluator, [scored({ assessmentId: "b1", attemptId: "b1", recordedAt: "2026-11-13T10:00:00-08:00" }, lineA, [{}, { status: "substituted" }, {}, {}], null)]),
  );
  const scriptReport = buildTutoringReport(scriptRecords, [], "x");
  const script = buildEvidencePack(scriptReport, selectNextExercise(scriptReport, defaultPreferences));
  const empty = buildEvidencePack(buildTutoringReport([], [], "x"), selectNextExercise(buildTutoringReport([], [], "x"), defaultPreferences));

  test("the pack carries no numbers and ties every item to a stored assessment", () => {
    expect(acoustic.items.map((item) => item.id)).toContain("as4b");
    const spoken = JSON.stringify([acoustic.items.map((item) => item.headline), acoustic.exercise.instruction]);
    expect(spoken).not.toMatch(/\d/);
  });

  test("rejects uncited, unknown-id, long, numeric and markdown replies", () => {
    const id = acoustic.items[0]!.id;
    expect(replyProblems({ text: "Nice work today.", cites: [] }, acoustic)).toContain("uncited");
    expect(replyProblems({ text: "Nice work.", cites: ["invented"] }, acoustic)).toContain("cites_unknown_evidence");
    expect(replyProblems({ text: Array.from({ length: 60 }, () => "word").join(" "), cites: [id] }, acoustic)).toContain("too_many_words");
    expect(replyProblems({ text: "One. Two. Three. Four.", cites: [id] }, acoustic)).toContain("too_many_sentences");
    expect(replyProblems({ text: "You scored 88 on that.", cites: [id] }, acoustic)).toContain("unsupported_number");
    expect(replyProblems({ text: "**Great** job", cites: [id] }, acoustic)).toContain("not_plain_speech");
    expect(replyProblems({ text: "Say it again.", cites: [id] }, acoustic)).toEqual([]);
  });

  test("without an acoustic measurement it rejects pronunciation claims and requires the script disclosure", () => {
    const id = script.items[0]!.id;
    expect(script.basis).toBe("script_agreement");
    expect(replyProblems({ text: "Your pronunciation of power is off.", cites: [id] }, script)).toContain("acoustic_claim_without_acoustic_measurement");
    expect(replyProblems({ text: "Say it again.", cites: [id] }, script)).toContain("missing_script_disclosure");
    expect(replyProblems({ text: "Going by how closely your words match the script, say it again.", cites: [id] }, script)).toEqual([]);
  });

  test("with no practice, a reply must cite nothing", () => {
    expect(empty.basis).toBe("none");
    expect(replyProblems({ text: "Record a line and we start.", cites: [] }, empty)).toEqual([]);
    expect(replyProblems({ text: "Record a line.", cites: ["x"] }, empty)).toContain("cites_unknown_evidence");
  });

  test("the template passes its own post-check for every basis and stays short", () => {
    for (const pack of [acoustic, script, empty]) {
      const reply = templateReply(pack);
      expect(replyProblems(reply, pack)).toEqual([]);
      expect(reply.text.split(/\s+/).length).toBeLessThanOrEqual(45);
    }
    expect(templateReply(script).text).toContain("match the script");
  });

  const generated = (text: string): { text: string; model: string; responseId: string | null } => ({ text, model: "gpt-test", responseId: "resp_1" });

  test("uses a valid model reply and records its provenance", async () => {
    const id = acoustic.items[0]!.id;
    const ok = await composeReply(acoustic, async () => generated(JSON.stringify({ text: "Say underestimate slowly.", cites: [id] })));
    expect(ok).toMatchObject({ source: "model", cites: [id], provenance: { provider: "openai", api: "responses", model: "gpt-test", responseId: "resp_1" } });
  });

  test("falls back to the template only when the model answered but the reply failed the post-check", async () => {
    const id = acoustic.items[0]!.id;
    for (const text of [JSON.stringify({ text: "You got 88.", cites: [id] }), "not json", JSON.stringify({ text: "Fine.", cites: [] })]) {
      const result = await composeReply(acoustic, async () => generated(text));
      expect(result.source).toBe("template");
      expect(result.provenance).toBeUndefined();
      expect(result.problems.length).toBeGreaterThan(0);
      expect(replyProblems(result, acoustic)).toEqual([]);
    }
  });

  test("a provider failure is never turned into a canned reply", async () => {
    await expect(
      composeReply(acoustic, async () => {
        throw new Error("provider down");
      }),
    ).rejects.toThrow("provider down");
  });

  test("without an acoustic measurement a reply can't state a fluency finding either", () => {
    const id = script.items[0]!.id;
    expect(replyProblems({ text: "Going by how closely your words match the script, your fluency is great.", cites: [id] }, script)).toContain("acoustic_claim_without_acoustic_measurement");
    expect(replyProblems({ text: "Going by how closely your words match the script, say it smoothly.", cites: [id] }, script)).toContain("acoustic_claim_without_acoustic_measurement");
  });
});

describe("memory derivation", () => {
  const report = buildTutoringReport(history, [], "x");

  test("documents are deterministic, one per source, and carry no scores", async () => {
    const first = await deriveMemoryDocuments(history, report, learnerPreferences.parse({ goalNote: "Order food in Madrid" }));
    const second = await deriveMemoryDocuments([...history].reverse(), report, learnerPreferences.parse({ goalNote: "Order food in Madrid" }));
    expect(first).toEqual(second);
    expect(new Set(first.map((doc) => doc.id)).size).toBe(first.length);
    expect(first.filter((doc) => doc.kind === "attempt")).toHaveLength(5);
    expect(first.some((doc) => doc.kind === "difficulty" && doc.content.includes("underestimate"))).toBe(true);
    for (const doc of first) expect(doc.content.replace(/\d{4}-\d{2}-\d{2}/g, "").replace(/seen on \d+ attempts/, "")).not.toMatch(/\d/);
    expect(first.find((doc) => doc.kind === "preferences")!.content).toContain("Order food in Madrid");
  });

  test("the namespace is derived from the subject with a secret and is stable and provider-safe", async () => {
    const a = await learnerNamespace("https://issuer|alice", "secret-1");
    expect(a).toMatch(/^dubit-u-[0-9a-f]{32}$/);
    expect(a).toBe(await learnerNamespace("https://issuer|alice", "secret-1"));
    expect(a).not.toBe(await learnerNamespace("https://issuer|bob", "secret-1"));
    expect(a).not.toBe(await learnerNamespace("https://issuer|alice", "secret-2"));
    expect(a).not.toContain("alice");
  });

  test("outbox backoff doubles, stays bounded, and ends in an explicit failed state", () => {
    const now = 1_000;
    const transient = new TutoringMemoryError("503", true);
    expect(outboxOutcomeAfterFailure(0, transient, now)).toEqual({ state: "pending", attempts: 1, nextAttemptAt: now + 30_000 });
    expect(outboxOutcomeAfterFailure(1, transient, now)).toMatchObject({ nextAttemptAt: now + 60_000 });
    expect(outboxOutcomeAfterFailure(5, transient, now)).toEqual({ state: "failed", attempts: 6 });
    expect(outboxOutcomeAfterFailure(0, new TutoringMemoryError("400", false), now)).toEqual({ state: "failed", attempts: 1 });
    expect(outboxOutcomeAfterFailure(0, new Error("bug"), now)).toMatchObject({ state: "failed" });
  });
});

describe("avatar session token", () => {
  afterEach(() => vi.unstubAllGlobals());

  test("mints a LITE-mode token, so LiveAvatar runs no conversational model", async () => {
    const requests: unknown[] = [];
    vi.stubGlobal("fetch", async (_url: string, init: RequestInit) => {
      requests.push(JSON.parse(String(init.body)));
      return Response.json({ code: 1000, data: { session_id: "sess", session_token: "tok" } });
    });
    const token = await createSessionToken({ apiKey: "k", avatarId: "av", isSandbox: true });
    expect(token).toEqual({ sessionId: "sess", sessionToken: "tok" });
    expect(requests[0]).toMatchObject({ mode: "LITE", avatar_id: "av", is_sandbox: true });
    expect(JSON.stringify(requests[0])).not.toContain("avatar_persona");
  });
});

// ---- Convex functions, identities, outbox and routes ---------------------------------------------------------

// convex-test finds the functions root through a _generated entry; this deployment has no codegen output yet.
const modules = { ...import.meta.glob(["./*.ts", "!./*.test.ts"]), "./_generated/api.js": async () => ({}) };
const schema = defineSchema(tutoringTables);

const alice = { tokenIdentifier: "https://issuer.test|alice", subject: "alice", issuer: "https://issuer.test" };
const bob = { tokenIdentifier: "https://issuer.test|bob", subject: "bob", issuer: "https://issuer.test" };

type FakeMemory = {
  documents: Map<string, Map<string, { content: string; metadata: unknown }>>;
  calls: string[];
  failures: { status: number; remaining: number } | null;
};

function fakeSupermemory(): FakeMemory {
  const state: FakeMemory = { documents: new Map(), calls: [], failures: null };
  vi.stubGlobal("fetch", async (input: string | URL | Request, init?: RequestInit) => {
    const url = new URL(input instanceof Request ? input.url : String(input));
    const method = init?.method ?? "GET";
    const namespace = decodeURIComponent(url.pathname.split("/")[2] ?? "");
    state.calls.push(method + " " + url.pathname);
    if (state.failures !== null && state.failures.remaining > 0) {
      state.failures.remaining -= 1;
      return new Response(JSON.stringify({ error: "failure" }), { status: state.failures.status, headers: { "Content-Type": "application/json" } });
    }
    const body = init?.body === undefined ? {} : JSON.parse(String(init.body));
    const docs = state.documents.get(namespace) ?? new Map();
    state.documents.set(namespace, docs);
    if (method === "POST" && url.pathname.endsWith("/document")) {
      docs.set(body.id, { content: body.content, metadata: body.metadata });
      return Response.json({ id: body.id, status: "queued" });
    }
    if (method === "DELETE" && url.pathname.endsWith("/document")) {
      for (const id of body.ids) docs.delete(id);
      return Response.json({ count: body.ids.length, errors: [] });
    }
    if (method === "POST" && url.pathname.endsWith("/search")) {
      return Response.json({ results: [...docs.values()].slice(0, 3).map((doc, index) => ({ id: "m" + index, memory: doc.content, metadata: {}, similarity: 0.9, isLatest: true, isInference: false, system: {} })), searchTime: 1 });
    }
    return new Response("unexpected", { status: 500 });
  });
  return state;
}

// convex-test's clock stands still under fake timers, so move it forward the way real time would before a drain.
// Moving the system time doesn't fire scheduled timers, which keeps each drain explicit.
function drain(t: ReturnType<typeof convexTest>) {
  vi.setSystemTime(Date.now() + 1000);
  return t.action(tutoringRefs.drainMemoryOutbox, {});
}

const ingestArgs = (subject: string, item: ReturnType<typeof session>) => ({ subject, session: item });

describe("convex tutoring functions", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-11-15T12:00:00Z"));
    process.env.SUPERMEMORY_API_KEY = "test-key";
    process.env.TUTOR_MEMORY_NAMESPACE_SECRET = "test-secret";
  });
  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
    delete process.env.SUPERMEMORY_API_KEY;
    delete process.env.TUTOR_MEMORY_NAMESPACE_SECRET;
  });

  const first = session("s1", acousticEvaluator, [
    scored({ assessmentId: "as1", attemptId: "a1", recordedAt: "2026-11-10T10:00:00-08:00" }, lineA, withWeak(1, 64), 70),
  ]);

  test("repeated ingestion of the same assessment doesn't double count, and a changed payload conflicts", async () => {
    const t = convexTest(schema, modules);
    expect(await t.mutation(tutoringRefs.ingestDubbingSession, ingestArgs(alice.tokenIdentifier, first))).toEqual({ outcome: "ok", results: [{ assessmentId: "as1", outcome: "inserted" }] });
    expect(await t.mutation(tutoringRefs.ingestDubbingSession, ingestArgs(alice.tokenIdentifier, first))).toEqual({ outcome: "ok", results: [{ assessmentId: "as1", outcome: "duplicate" }] });
    const changed = session("s1", acousticEvaluator, [scored({ assessmentId: "as1", attemptId: "a1", recordedAt: "2026-11-10T10:00:00-08:00" }, lineA, withWeak(1, 10), 70)]);
    expect(await t.mutation(tutoringRefs.ingestDubbingSession, ingestArgs(alice.tokenIdentifier, changed))).toMatchObject({ results: [{ outcome: "conflict" }] });
    const progress = await t.withIdentity(alice).query(tutoringRefs.progress, {});
    expect(progress.series[0]!.volume.attempts).toBe(1);
  });

  test("the single-assessment entry point validates and rejects bad payloads without storing them", async () => {
    const t = convexTest(schema, modules);
    const item = first.assessments[0]!;
    const result = await t.mutation(tutoringRefs.ingestAssessment, {
      subject: alice.tokenIdentifier,
      assessment: item.assessment,
      attempt: { sessionId: "s1", sceneId: "scene_001", characterId: "anakin", timeZone: "America/Los_Angeles", speakingDurationMs: 2000, recordingDurationMs: 6000 },
      evaluator: first.evaluator,
    });
    expect(result).toMatchObject({ outcome: "ok", results: [{ outcome: "inserted" }] });
    const bad = await t.mutation(tutoringRefs.ingestAssessment, {
      subject: alice.tokenIdentifier,
      assessment: { ...item.assessment, scores: "nope" },
      attempt: {},
      evaluator: first.evaluator,
    });
    expect(bad.outcome).toBe("rejected");
  });

  test("a regrade adds neither an attempt nor speaking time", async () => {
    const t = convexTest(schema, modules);
    await t.mutation(tutoringRefs.ingestDubbingSession, ingestArgs(alice.tokenIdentifier, first));
    const regrade = session("s1", acousticEvaluator, [scored({ assessmentId: "as1b", attemptId: "a1", recordedAt: "2026-11-10T10:00:00-08:00" }, lineA, withWeak(1, 72), 70)], "2026-11-12T00:00:00Z");
    await t.mutation(tutoringRefs.ingestDubbingSession, ingestArgs(alice.tokenIdentifier, regrade));
    const volume = (await t.withIdentity(alice).query(tutoringRefs.progress, {})).series[0]!.volume;
    expect(volume).toMatchObject({ attempts: 1, speakingMs: 2000 });
  });

  test("two identities can't see each other's progress, preferences, exercise or memory status", async () => {
    const t = convexTest(schema, modules);
    await t.mutation(tutoringRefs.ingestDubbingSession, ingestArgs(alice.tokenIdentifier, first));
    await t.withIdentity(alice).mutation(tutoringRefs.setPreferences, { preferences: { goalNote: "alice goal" }, expectedVersion: 0 });
    const asBob = t.withIdentity(bob);
    expect((await asBob.query(tutoringRefs.progress, {})).series).toEqual([]);
    expect(await asBob.query(tutoringRefs.getPreferences, {})).toMatchObject({ version: 0 });
    expect((await asBob.query(tutoringRefs.getPreferences, {})).preferences.goalNote).toBeUndefined();
    expect(await asBob.query(tutoringRefs.nextExercise, {})).toMatchObject({ kind: "first_attempt" });
    expect(await asBob.query(tutoringRefs.memoryStatus, {})).toEqual({ pending: 0, failed: 0, done: 0 });
    expect((await t.withIdentity(alice).query(tutoringRefs.progress, {})).series).toHaveLength(1);
    await expect(t.query(tutoringRefs.progress, {})).rejects.toThrow(/no authenticated learner/);
  });

  test("preferences are validated and a stale version is a conflict", async () => {
    const t = convexTest(schema, modules).withIdentity(alice);
    const saved = await t.mutation(tutoringRefs.setPreferences, { preferences: { focus: "fluency", challenge: "gentle" }, expectedVersion: 0 });
    expect(saved).toMatchObject({ version: 1, preferences: { focus: "fluency", challenge: "gentle", memory: "on" } });
    await expect(t.mutation(tutoringRefs.setPreferences, { preferences: {}, expectedVersion: 0 })).rejects.toThrow(/version_conflict/);
    await expect(t.mutation(tutoringRefs.setPreferences, { preferences: { focus: "telepathy" }, expectedVersion: 1 })).rejects.toThrow(/invalid_request/);
    await expect(t.mutation(tutoringRefs.setPreferences, { preferences: { userId: "bob" }, expectedVersion: 1 })).rejects.toThrow(/invalid_request/);
  });

  test("memory is written once per document, into a namespace derived from the identity, and retries don't duplicate", async () => {
    const memory = fakeSupermemory();
    const t = convexTest(schema, modules);
    await t.mutation(tutoringRefs.ingestDubbingSession, ingestArgs(alice.tokenIdentifier, first));
    await t.mutation(tutoringRefs.ingestDubbingSession, ingestArgs(bob.tokenIdentifier, first));
    const drained = await drain(t);
    expect(drained).toEqual({ sent: 2, failed: 0 });
    const namespaces = [...memory.documents.keys()];
    expect(namespaces).toHaveLength(2);
    expect(namespaces.every((namespace) => /^dubit-u-[0-9a-f]{32}$/.test(namespace))).toBe(true);
    expect(namespaces).toContain(await learnerNamespace(alice.tokenIdentifier, "test-secret"));
    // Nothing is left to send, and a duplicate ingestion queues nothing new.
    await t.mutation(tutoringRefs.ingestDubbingSession, ingestArgs(alice.tokenIdentifier, first));
    expect(await drain(t)).toEqual({ sent: 0, failed: 0 });
    expect(await t.withIdentity(alice).query(tutoringRefs.memoryStatus, {})).toEqual({ pending: 0, failed: 0, done: 1 });
  });

  test("a transient memory failure retries with backoff, then succeeds, and a permanent one fails explicitly", async () => {
    const memory = fakeSupermemory();
    memory.failures = { status: 400, remaining: 1 };
    const t = convexTest(schema, modules);
    await t.mutation(tutoringRefs.ingestDubbingSession, ingestArgs(alice.tokenIdentifier, first));
    expect(await drain(t)).toEqual({ sent: 0, failed: 1 });
    expect(await t.withIdentity(alice).query(tutoringRefs.memoryStatus, {})).toEqual({ pending: 0, failed: 1, done: 0 });
    // The tutor still answers from Convex evidence while memory is failed.
    expect(await t.withIdentity(alice).query(tutoringRefs.nextExercise, {})).toMatchObject({ kind: expect.any(String) });
    expect(await t.mutation(tutoringRefs.retryFailedMemory, {})).toEqual({ retried: 1 });
    expect(await drain(t)).toEqual({ sent: 1, failed: 0 });
    expect(await t.withIdentity(alice).query(tutoringRefs.memoryStatus, {})).toEqual({ pending: 0, failed: 0, done: 1 });
  });

  test("a retryable outage keeps the row pending with a later attempt time", async () => {
    const memory = fakeSupermemory();
    memory.failures = { status: 503, remaining: 99 };
    const t = convexTest(schema, modules);
    await t.mutation(tutoringRefs.ingestDubbingSession, ingestArgs(alice.tokenIdentifier, first));
    const pending = drain(t);
    await vi.advanceTimersByTimeAsync(60_000);
    expect(await pending).toEqual({ sent: 0, failed: 1 });
    const rows = await t.run(async (ctx) => ctx.db.query("tutoringMemoryOutbox").collect());
    expect(rows[0]).toMatchObject({ state: "pending", attempts: 1 });
    expect(rows[0]!.nextAttemptAt).toBeGreaterThan(new Date("2026-11-15T12:00:00Z").getTime());
  });

  test("deleting source records deletes or re-derives their memory documents", async () => {
    const memory = fakeSupermemory();
    const t = convexTest(schema, modules);
    const second = session("s2", acousticEvaluator, [scored({ assessmentId: "as2", attemptId: "a2", recordedAt: "2026-11-11T10:00:00-08:00" }, lineB, good(2), 90)]);
    await t.mutation(tutoringRefs.ingestDubbingSession, ingestArgs(alice.tokenIdentifier, first));
    await t.mutation(tutoringRefs.ingestDubbingSession, ingestArgs(alice.tokenIdentifier, second));
    await drain(t);
    const namespace = await learnerNamespace(alice.tokenIdentifier, "test-secret");
    expect(memory.documents.get(namespace)!.size).toBe(2);
    await t.mutation(tutoringRefs.removeAttempt, { subject: alice.tokenIdentifier, attemptId: "a1" });
    await drain(t);
    expect(memory.documents.get(namespace)!.size).toBe(1);
    await t.withIdentity(alice).mutation(tutoringRefs.forgetMemory, {});
    await drain(t);
    expect(memory.documents.get(namespace)!.size).toBe(0);
    expect((await t.withIdentity(alice).query(tutoringRefs.progress, {})).series[0]!.volume.attempts).toBe(1);
    await t.mutation(tutoringRefs.removeLearner, { subject: alice.tokenIdentifier });
    expect((await t.withIdentity(alice).query(tutoringRefs.progress, {})).series).toEqual([]);
  });

  test("memory search works for the caller only and is silent when memory is unavailable", async () => {
    fakeSupermemory();
    const t = convexTest(schema, modules);
    await t.mutation(tutoringRefs.ingestDubbingSession, ingestArgs(alice.tokenIdentifier, first));
    await drain(t);
    expect((await t.withIdentity(alice).action(tutoringRefs.searchMemory, { query: "line" })).length).toBeGreaterThan(0);
    expect(await t.withIdentity(bob).action(tutoringRefs.searchMemory, { query: "line" })).toEqual([]);
    vi.stubGlobal("fetch", async () => new Response("down", { status: 400 }));
    expect(await t.withIdentity(alice).action(tutoringRefs.searchMemory, { query: "line" })).toEqual([]);
  });

  test("the reply context gives a pack that only cites this learner's assessments", async () => {
    const t = convexTest(schema, modules);
    await t.mutation(tutoringRefs.ingestDubbingSession, ingestArgs(alice.tokenIdentifier, first));
    const asAlice = await t.withIdentity(alice).query(tutoringRefs.replyContext, {});
    expect(asAlice.pack.items.map((item) => item.id)).toEqual(["as1"]);
    const asBob = await t.withIdentity(bob).query(tutoringRefs.replyContext, {});
    expect(asBob.pack.items).toEqual([]);
  });
});

type OpenAiCall = { path: string; body: Record<string, unknown> };

/** Stands in for api.openai.com: answers /v1/responses with the given text and /v1/audio/speech with a few PCM bytes. */
function fakeOpenAI(replyText: () => string, failure?: { status: number }) {
  const calls: OpenAiCall[] = [];
  vi.stubGlobal("fetch", async (input: string | URL | Request, init?: RequestInit) => {
    const url = new URL(input instanceof Request ? input.url : String(input));
    if (url.hostname !== "api.openai.com") return new Response("not faked", { status: 500 });
    calls.push({ path: url.pathname, body: JSON.parse(String(init?.body ?? "{}")) });
    if (failure !== undefined) return Response.json({ error: { message: "secret provider detail" } }, { status: failure.status });
    if (url.pathname.endsWith("/audio/speech")) return new Response(new Uint8Array([1, 2, 3, 4]), { headers: { "Content-Type": "audio/pcm" } });
    return Response.json({
      id: "resp_test",
      object: "response",
      created_at: 0,
      model: "gpt-6-luna-test",
      status: "completed",
      output: [{ type: "message", id: "msg_1", status: "completed", role: "assistant", content: [{ type: "output_text", text: replyText(), annotations: [] }] }],
    });
  });
  return calls;
}

describe("coach and tutor HTTP routes", () => {
  const seeded = session("s1", acousticEvaluator, [
    scored({ assessmentId: "as1", attemptId: "a1", recordedAt: "2026-11-10T10:00:00-08:00" }, lineA, withWeak(1, 64), 70),
  ]);
  const replyBody = JSON.stringify({ characterId: "anakin", languageName: "English", locale: "en-US", turns: [{ role: "learner", text: "Hi coach" }] });
  const post = (t: ReturnType<typeof convexTest>, headers: Record<string, string> = {}, body = replyBody) =>
    t.withIdentity(alice).fetch("/coach/reply", { method: "POST", headers: { "Content-Type": "application/json", ...headers }, body });

  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-11-15T12:00:00Z"));
    process.env.OPENAI_API_KEY = "test-openai-key";
  });
  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
    for (const name of ["OPENAI_API_KEY", "QA_FAULTS_ENABLED", "SUPERMEMORY_API_KEY"]) delete process.env[name];
  });

  async function seededTutor() {
    const t = convexTest(schema, modules);
    await t.mutation(tutoringRefs.ingestDubbingSession, ingestArgs(alice.tokenIdentifier, seeded));
    return t;
  }

  test("every coach and tutor route except the coach list needs a signed-in learner", async () => {
    const t = convexTest(schema, modules);
    expect((await t.fetch("/coach/characters")).status).toBe(200);
    for (const [path, method] of [["/coach/reply", "POST"], ["/coach/session-token", "POST"], ["/tutor/progress", "GET"], ["/tutor/next-exercise", "GET"], ["/tutor/preferences", "GET"], ["/tutor/memory", "GET"], ["/tutor/memory", "DELETE"]] as const) {
      const response = await t.fetch(path, { method, headers: { "Content-Type": "application/json" }, ...(method === "POST" ? { body: "{}" } : {}) });
      expect([path, response.status, ((await response.json()) as { code: string }).code]).toEqual([path, 401, "unauthenticated"]);
    }
  });

  test("a valid model reply is returned with its provenance, evidence and a content-free log line", async () => {
    const log = vi.spyOn(console, "log").mockImplementation(() => {});
    const calls = fakeOpenAI(() => JSON.stringify({ text: "Say underestimate slowly.", cites: ["as1"] }));
    const t = await seededTutor();
    const response = await post(t);
    expect(response.status).toBe(200);
    const body = (await response.json()) as Record<string, unknown>;
    expect(body).toMatchObject({
      text: "Say underestimate slowly.",
      source: "model",
      feedbackBasis: "acoustic",
      citedEvidenceIds: ["as1"],
      provenance: { provider: "openai", api: "responses", model: "gpt-6-luna-test", responseId: "resp_test" },
      exercise: { kind: "drill_word" },
    });
    expect(JSON.stringify(body)).not.toContain("test-openai-key");
    expect(calls[0]!.body).toMatchObject({ model: "gpt-6-luna", store: false, text: { format: { type: "json_schema", strict: true } } });
    const line = log.mock.calls.map((call) => String(call[0])).find((entry) => entry.startsWith("coach.reply"));
    expect(line).toMatch(/^coach\.reply provider=openai api=responses model=gpt-6-luna-test status=ok code=none latencyMs=\d+$/);
    expect(line).not.toContain("Hi coach");
  });

  test("a reply that fails the post-check becomes the template, with no provenance", async () => {
    fakeOpenAI(() => JSON.stringify({ text: "You scored 88 points.", cites: ["as1"] }));
    const body = (await (await post(await seededTutor())).json()) as Record<string, unknown>;
    expect(body).toMatchObject({ source: "template", citedEvidenceIds: ["as1"] });
    expect(body).not.toHaveProperty("provenance");
    expect(String(body.text)).not.toMatch(/\d/);
  });

  test("can return the reply as PCM audio for the avatar", async () => {
    const calls = fakeOpenAI(() => JSON.stringify({ text: "Say it again.", cites: ["as1"] }));
    const response = await post(await seededTutor(), {}, JSON.stringify({ ...JSON.parse(replyBody), audio: true }));
    expect(((await response.json()) as { audio: unknown }).audio).toEqual({ format: "pcm_s16le_24khz_mono", base64: "AQIDBA==", aiGenerated: true });
    expect(calls.map((call) => call.path)).toContain("/v1/audio/speech");
    expect(calls.find((call) => call.path.endsWith("/speech"))!.body).toMatchObject({ response_format: "pcm", voice: "ash" });
  });

  test("a provider failure returns an error with no text and doesn't echo the provider's body", async () => {
    fakeOpenAI(() => "", { status: 400 });
    const response = await post(await seededTutor());
    const body = (await response.json()) as Record<string, unknown>;
    expect(response.status).toBe(502);
    expect(body).toMatchObject({ code: "provider_failed" });
    expect(body).not.toHaveProperty("text");
    expect(JSON.stringify(body)).not.toContain("secret provider detail");
  });

  test("a missing OpenAI key is a 503 and calls nothing", async () => {
    delete process.env.OPENAI_API_KEY;
    const calls = fakeOpenAI(() => "");
    const response = await post(await seededTutor());
    expect([response.status, ((await response.json()) as { code: string }).code]).toEqual([503, "not_configured"]);
    expect(calls).toHaveLength(0);
  });

  test("QA fault headers are honored only when QA_FAULTS_ENABLED is true", async () => {
    const calls = fakeOpenAI(() => JSON.stringify({ text: "Say it again.", cites: ["as1"] }));
    const t = await seededTutor();
    expect((await post(t, { "X-QA-Fault": "provider_error" })).status).toBe(200);
    expect(calls.length).toBeGreaterThan(0);
    calls.length = 0;
    process.env.QA_FAULTS_ENABLED = "true";
    for (const [fault, status, code] of [["provider_error", 502, "provider_failed"], ["provider_timeout", 504, "provider_timeout"], ["missing_key", 503, "not_configured"]] as const) {
      const response = await post(t, { "X-QA-Fault": fault });
      const body = (await response.json()) as Record<string, unknown>;
      expect([response.status, body.code]).toEqual([status, code]);
      expect(body).not.toHaveProperty("text");
    }
    expect(calls).toHaveLength(0);
    expect((await post(t, { "X-QA-Fault": "unknown_fault" })).status).toBe(200);
  });

  test("the progress, exercise, preference and memory routes serve only the signed-in learner", async () => {
    const t = await seededTutor();
    const get = async (identity: typeof alice, path: string) => (await t.withIdentity(identity).fetch(path)).json() as Promise<any>;
    expect((await get(alice, "/tutor/progress")).series).toHaveLength(1);
    expect((await get(bob, "/tutor/progress")).series).toEqual([]);
    expect((await get(alice, "/tutor/next-exercise")).exercise.kind).toBe("drill_word");
    expect((await get(bob, "/tutor/next-exercise")).exercise.kind).toBe("first_attempt");
    const memory = (await get(alice, "/tutor/memory")).items as { kind: string; sourceIds: string[]; state: string }[];
    expect(memory).toEqual([expect.objectContaining({ kind: "attempt_note", sourceIds: ["a1", "as1"], state: "pending" })]);
    expect((await get(bob, "/tutor/memory")).items).toEqual([]);
    const put = (preferences: unknown, expectedVersion: number) =>
      t.withIdentity(alice).fetch("/tutor/preferences", { method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ preferences, expectedVersion }) });
    expect((await put({ focus: "timing" }, 0)).status).toBe(200);
    const stale = await put({}, 0);
    expect([stale.status, ((await stale.json()) as { code: string }).code]).toEqual([409, "version_conflict"]);
    expect((await put({ userId: "bob" }, 1)).status).toBe(400);
    expect((await t.withIdentity(alice).fetch("/tutor/memory", { method: "DELETE" })).status).toBe(200);
  });
});

describe("pack helper", () => {
  test("a pack from an empty report is empty and basis none", () => {
    const pack: EvidencePack = buildEvidencePack(buildTutoringReport([], [], "x"), selectNextExercise(buildTutoringReport([], [], "x"), defaultPreferences));
    expect(pack).toMatchObject({ basis: "none", items: [] });
  });
});
