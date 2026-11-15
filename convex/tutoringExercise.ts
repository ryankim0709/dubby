import type { Scores } from "./gradingContract";
import type { Focus, LearnerPreferences } from "./tutoringPreferences";
import {
  lineMasteryThreshold,
  type PracticedLine,
  type SeriesProgress,
  type TutoringReport,
  type WordProgress,
} from "./tutoringProgress";

export type ExerciseKind = "drill_word" | "retry_line" | "new_line" | "first_attempt";

/** The single next step the tutor suggests, with the attempts and assessments that justify it. */
export type NextExercise = {
  kind: ExerciseKind;
  locale: string | null;
  lineId: string | null;
  referenceVersion: number | null;
  practiceText: string | null;
  focus: Focus;
  instruction: string;
  reasonCode: string;
  /** What the evidence rests on. "script_agreement" means no acoustic pronunciation measurement exists. */
  basis: "acoustic" | "script_agreement" | "none";
  evidence: { attemptIds: string[]; assessmentIds: string[] };
};

type Candidate = NextExercise & { priority: number };

const kindRank: Record<ExerciseKind, number> = { drill_word: 0, retry_line: 1, new_line: 2, first_attempt: 3 };
const sortedUnique = (items: readonly string[]) => [...new Set(items)].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));

const focusMetric: Record<Exclude<Focus, "any">, keyof Scores> = {
  pronunciation: "pronunciation",
  word_accuracy: "wordAccuracy",
  fluency: "fluency",
  timing: "timingFit",
};
const metricFocus: Partial<Record<keyof Scores, Exclude<Focus, "any">>> = {
  pronunciation: "pronunciation",
  wordAccuracy: "word_accuracy",
  fluency: "fluency",
  timingFit: "timing",
};

const lineInstruction: Record<Focus, string> = {
  pronunciation: "Listen to the line once, then say it again, slowing down on the hardest word.",
  word_accuracy: "Read the script, then say the line again with every word in order.",
  fluency: "Say the line again in one smooth go, without stopping between words.",
  timing: "Say the line again, matching the pace of the original scene.",
  any: "Say the line again and aim for a cleaner take.",
};

function wordCandidate(series: SeriesProgress, word: WordProgress, line: PracticedLine | undefined): Candidate {
  const acoustic = series.pronunciationBasis === "acoustic" && word.pronunciationIssueCount > 0;
  return {
    kind: "drill_word",
    locale: series.locale,
    lineId: line?.lineId ?? null,
    referenceVersion: line?.referenceVersion ?? null,
    practiceText: word.word,
    focus: acoustic ? "pronunciation" : "word_accuracy",
    instruction: acoustic
      ? `Listen to "${word.word}", say it slowly three times, then say the whole line.`
      : `Check "${word.word}" in the script, say it slowly, then say the whole line.`,
    reasonCode: word.status === "persistent_weakness" ? "word_persistent_weakness" : "word_recent_difficulty",
    basis: series.pronunciationBasis,
    evidence: { attemptIds: sortedUnique(word.issueAttemptIds), assessmentIds: sortedUnique(word.issueAssessmentIds) },
    priority: word.status === "persistent_weakness" ? 80 : 65,
  };
}

function lineCandidate(series: SeriesProgress, line: PracticedLine): Candidate | undefined {
  const evidence = { attemptIds: [line.latestAttemptId], assessmentIds: [line.latestAssessmentId] };
  const base = {
    kind: "retry_line" as const,
    locale: series.locale,
    lineId: line.lineId,
    referenceVersion: line.referenceVersion,
    practiceText: line.referenceText,
    basis: series.pronunciationBasis,
    evidence,
  };
  if (line.latestScores === null) {
    return {
      ...base,
      focus: "any",
      instruction: "Record the line again somewhere quiet, holding the phone closer.",
      reasonCode: "line_unscorable",
      priority: 70,
    };
  }
  const overall = line.latestScores.languageOverall;
  // Without a combined score, fall back to the weakest measured component.
  const components = (Object.keys(metricFocus) as (keyof Scores)[]).flatMap((metric) => {
    const value = line.latestScores?.[metric] ?? null;
    return value === null ? [] : [{ metric, value }];
  });
  const weakest = components.sort((a, b) => a.value - b.value || (a.metric < b.metric ? -1 : 1))[0];
  const level = overall ?? weakest?.value;
  if (level === undefined || level >= lineMasteryThreshold) return undefined;
  const focus = (weakest === undefined ? undefined : metricFocus[weakest.metric]) ?? "any";
  return {
    ...base,
    focus,
    instruction: lineInstruction[focus],
    reasonCode: "line_below_target",
    priority: 40 + Math.round((100 - level) / 2),
  };
}

/**
 * Picks exactly one next exercise from measured evidence and the learner's explicit preferences.
 * Ordering is fully deterministic: priority, then kind, then line ID, then practice text.
 */
export function selectNextExercise(
  report: TutoringReport,
  preferences: LearnerPreferences,
  locale?: string,
): NextExercise {
  const wantedLocale = locale ?? preferences.targetLocale;
  const series = wantedLocale === undefined ? report.series[0] : report.series.find((item) => item.locale === wantedLocale);
  if (series === undefined) {
    return {
      kind: "first_attempt",
      locale: wantedLocale ?? null,
      lineId: null,
      referenceVersion: null,
      practiceText: null,
      focus: "any",
      instruction: "Pick a line from a scene you like and record your first take.",
      reasonCode: "no_scorable_history",
      basis: "none",
      evidence: { attemptIds: [], assessmentIds: [] },
    };
  }
  const avoided = new Set(preferences.avoidLineIds);
  const acoustic = series.pronunciationBasis === "acoustic";
  // Pronunciation and fluency are acoustic measurements, so without one those preferences fall back to script accuracy.
  const wantsFallback = (preferences.focus === "pronunciation" || preferences.focus === "fluency") && !acoustic;
  const wantedFocus: Focus = wantsFallback ? "word_accuracy" : preferences.focus;
  const lineStatus = new Map(series.lines.map((line) => [line.lineId + "#" + line.referenceVersion, line]));

  const candidates: Candidate[] = [];
  for (const word of series.words) {
    if (word.status !== "persistent_weakness" && word.status !== "recent_difficulty") continue;
    const lines = series.guidance.retryLines
      .filter((line) => line.practiceWords.includes(word.word))
      .map((line) => lineStatus.get(line.lineId + "#" + line.referenceVersion))
      .filter((line): line is PracticedLine => line !== undefined);
    const line = lines.find((item) => !avoided.has(item.lineId));
    if (lines.length > 0 && line === undefined) continue;
    candidates.push(wordCandidate(series, word, line));
  }
  for (const line of series.lines) {
    if (avoided.has(line.lineId)) continue;
    const candidate = lineCandidate(series, line);
    if (candidate !== undefined) candidates.push(candidate);
  }
  const unpractised = series.guidance.newLines.find((line) => !avoided.has(line.lineId));
  if (unpractised !== undefined) {
    candidates.push({
      kind: "new_line",
      locale: series.locale,
      lineId: unpractised.lineId,
      referenceVersion: unpractised.referenceVersion,
      practiceText: unpractised.referenceText,
      focus: "word_accuracy",
      instruction: `Try a new line that uses "${unpractised.practiceWords[0] ?? "your practice words"}".`,
      reasonCode: "new_line_with_focus_word",
      basis: series.pronunciationBasis,
      evidence: {
        attemptIds: sortedUnique(series.words.filter((w) => unpractised.practiceWords.includes(w.word)).flatMap((w) => w.issueAttemptIds)),
        assessmentIds: sortedUnique(series.words.filter((w) => unpractised.practiceWords.includes(w.word)).flatMap((w) => w.issueAssessmentIds)),
      },
      priority: 45,
    });
  }
  const latest = [...series.lines].sort((a, b) => (a.latestRecordedAt < b.latestRecordedAt ? 1 : a.latestRecordedAt > b.latestRecordedAt ? -1 : 0))[0];
  candidates.push({
    kind: "new_line",
    locale: series.locale,
    lineId: null,
    referenceVersion: null,
    practiceText: null,
    focus: "any",
    instruction: "Your recent takes look solid, so choose a new line to stretch yourself.",
    reasonCode: "no_open_weakness",
    basis: series.pronunciationBasis,
    evidence: {
      attemptIds: latest === undefined ? [] : [latest.latestAttemptId],
      assessmentIds: latest === undefined ? [] : [latest.latestAssessmentId],
    },
    priority: 30,
  });

  const scored = candidates.map((candidate) => {
    let priority = candidate.priority;
    let reasonCode = candidate.reasonCode;
    if (wantedFocus !== "any" && candidate.focus === wantedFocus) {
      priority += 15;
      if (wantsFallback) reasonCode += "_script_fallback";
    }
    if (preferences.challenge === "gentle" && candidate.kind !== "new_line") priority += 10;
    if (preferences.challenge === "stretch" && candidate.kind === "new_line") priority += 10;
    return { ...candidate, priority, reasonCode };
  });
  scored.sort(
    (a, b) =>
      b.priority - a.priority ||
      kindRank[a.kind] - kindRank[b.kind] ||
      (a.lineId === b.lineId ? 0 : a.lineId === null ? 1 : b.lineId === null ? -1 : a.lineId < b.lineId ? -1 : 1) ||
      ((a.practiceText ?? "") < (b.practiceText ?? "") ? -1 : (a.practiceText ?? "") > (b.practiceText ?? "") ? 1 : 0),
  );
  const { priority: _priority, ...exercise } = scored[0]!;
  return exercise;
}
