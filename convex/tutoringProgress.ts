import { scoreMetrics, type ScoreMetric, type ScoredResult, type Scores, type WordResult } from "./gradingContract";
import type { PracticeLine, TutoringRecord } from "./tutoringRecords";

// Initial product thresholds, to calibrate against real recordings like the contract's score weights.
/** A measured word pronunciation below this counts as a difficulty. */
const wordIssueThreshold = 70;
/** Smaller score changes between days are treated as noise. */
const meaningfulChange = 5;
/** A skill whose latest daily average is below this becomes a focus area. */
const skillFocusThreshold = 75;
/** A line whose latest take scores below this is worth retrying. */
export const lineMasteryThreshold = 80;
/** Consecutive clean occurrences after a difficulty before a word counts as improved. */
const recoveryRunLength = 2;
const maxFocusAreas = 3;
const maxSuggestedLines = 3;

type ScoredRecord = TutoringRecord & { assessment: ScoredResult };

const isAcoustic = (record: TutoringRecord) => record.evaluator.measurement === "acoustic";

/**
 * Evidence of a difficulty with a reference word: a script mismatch, or a low pronunciation score from an
 * acoustic evaluator. A transcript-only evaluator never yields a pronunciation difficulty.
 */
export function isWordDifficulty(word: WordResult, acoustic: boolean): boolean {
  if (word.textStatus === "substituted" || word.textStatus === "omitted") return true;
  return acoustic && word.pronunciationScore !== null && word.pronunciationScore < wordIssueThreshold;
}

export type MetricSample = { value: number; samples: number };
export type DatedValue = { date: string; value: number };
export type MetricSamples = Record<ScoreMetric, MetricSample | null>;

/**
 * One local day's performance. firstScorable gives each line equal weight through its earliest scorable
 * take. bestAttempt uses each line's highest-languageOverall take, with that take's components kept together.
 */
export type DailyPerformance = { date: string; firstScorable: MetricSamples; bestAttempt: MetricSamples };

export type SkillTrend = {
  metric: ScoreMetric;
  first: DatedValue | null;
  latest: DatedValue | null;
  change: number | null;
  direction: "improving" | "declining" | "steady" | "insufficient_history";
};

export type LinePoint = DatedValue & { attemptId: string; assessmentId: string };

/** The same line and reference revision, compared by its first scorable languageOverall on each day. */
export type LineProgress = {
  sceneId: string;
  lineId: string;
  referenceVersion: number;
  referenceText: string;
  first: LinePoint;
  latest: LinePoint;
  change: number;
};

/** A line the learner practised, with its latest applicable take. */
export type PracticedLine = {
  sceneId: string;
  lineId: string;
  referenceVersion: number;
  referenceText: string;
  attempts: number;
  latestAttemptId: string;
  latestAssessmentId: string;
  latestRecordedAt: string;
  latestStatus: "scored" | "unscorable";
  latestScores: Scores | null;
};

export type WordStatus = "persistent_weakness" | "recent_difficulty" | "recovering" | "improved";

/** A reference word with at least one evidence-backed difficulty, grouped by its normalized form. */
export type WordProgress = {
  word: string;
  status: WordStatus;
  /** Occurrences with evidence: a text mismatch or a measured pronunciation score. */
  occurrences: number;
  issueCount: number;
  issueSessions: number;
  scriptIssueCount: number;
  /** Issues from a measured pronunciation score; always 0 for a transcript-only evaluator. */
  pronunciationIssueCount: number;
  latestPronunciationScore: number | null;
  issueAttemptIds: string[];
  issueAssessmentIds: string[];
  /** The assessments whose issue was a script mismatch, and those whose issue was a measured pronunciation score. */
  scriptIssueAssessmentIds: string[];
  pronunciationIssueAssessmentIds: string[];
};

export type FocusArea =
  | {
      kind: "word";
      word: string;
      status: "persistent_weakness" | "recent_difficulty";
      issueCount: number;
      issueAttemptIds: string[];
    }
  | { kind: "skill"; metric: ScoreMetric; latest: DatedValue };

export type RetryLine = {
  sceneId: string;
  lineId: string;
  referenceVersion: number;
  referenceText: string;
  practiceWords: string[];
  latestLanguageOverall: number | null;
  latestAttemptId: string;
  latestAssessmentId: string;
};

export type NewLine = PracticeLine & { practiceWords: string[] };

export type TutoringGuidance = {
  summary: string;
  focusAreas: FocusArea[];
  retryLines: RetryLine[];
  newLines: NewLine[];
};

export type PracticeVolume = {
  sessions: number;
  /** Unique attempts, each counted once however often it was regraded. */
  attempts: number;
  scorableAttempts: number;
  lines: number;
  practiceDays: number;
  /** Measured speaking time of the unique attempts; silence and regrades add nothing. */
  speakingMs: number;
};

/** Progress within one comparable series: one locale, rubric, and evaluator. */
export type SeriesProgress = {
  locale: string;
  rubricVersion: string;
  evaluator: { provider: string; modelVersion: string | null; configVersion: string; measurement: "acoustic" | "transcript_only" };
  /** "script_agreement" means no acoustic measurement exists, so pronunciation findings are off limits. */
  pronunciationBasis: "acoustic" | "script_agreement";
  /** Metrics this series can never report, with why; a transcript-only evaluator measures no pronunciation or fluency. */
  unavailableMetrics: { metric: ScoreMetric; reason: "no_acoustic_measurement" }[];
  volume: PracticeVolume;
  daily: DailyPerformance[];
  skills: SkillTrend[];
  lines: PracticedLine[];
  repeatedLines: LineProgress[];
  words: WordProgress[];
  guidance: TutoringGuidance;
};

export type TutoringReport = {
  generatedAt: string;
  /** Daily groups use each attempt's own captured time zone, so a profile change never rewrites history. */
  timeZonePolicy: "attempt-time-zone";
  series: SeriesProgress[];
};

/** Groups preserve the input order within each group. */
function groupBy<T>(items: readonly T[], key: (item: T) => string): Map<string, T[]> {
  const groups = new Map<string, T[]>();
  for (const item of items) {
    const groupKey = key(item);
    const group = groups.get(groupKey);
    if (group === undefined) groups.set(groupKey, [item]);
    else group.push(item);
  }
  return groups;
}

function mapMetrics<T>(transform: (metric: ScoreMetric) => T): Record<ScoreMetric, T> {
  return {
    languageOverall: transform("languageOverall"),
    pronunciation: transform("pronunciation"),
    wordAccuracy: transform("wordAccuracy"),
    fluency: transform("fluency"),
    timingFit: transform("timingFit"),
  };
}

const roundTenth = (value: number) => Math.round(value * 10) / 10;
const mean = (values: readonly number[]) => values.reduce((sum, value) => sum + value, 0) / values.length;
const compareText = (a: string, b: string) => (a < b ? -1 : a > b ? 1 : 0);

/** The calendar day the attempt was recorded on, in the time zone the learner practised in. */
function localDate(record: TutoringRecord): string {
  // en-CA formats dates as YYYY-MM-DD.
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: record.timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(new Date(record.assessment.recordedAt));
}

const lineKey = (record: TutoringRecord) => `${record.assessment.lineId}#${record.assessment.referenceVersion}`;
const seriesKey = (record: TutoringRecord) =>
  [
    record.assessment.locale,
    record.assessment.rubricVersion,
    record.evaluator.provider,
    record.evaluator.modelVersion ?? "undisclosed",
    record.evaluator.configVersion,
    record.evaluator.measurement,
  ].join("|");
const recordedTime = (record: TutoringRecord) => Date.parse(record.assessment.recordedAt);
const isScored = (record: TutoringRecord): record is ScoredRecord => record.assessment.status === "scored";

/** Groups words case-insensitively without edge punctuation, keeping interior apostrophes and hyphens. */
export function normalizeWord(token: string, locale: string): string {
  return token.toLocaleLowerCase(locale).replace(/^[\p{P}\p{S}]+|[\p{P}\p{S}]+$/gu, "");
}

function referenceWords(text: string, locale: string): Set<string> {
  return new Set(
    text
      .split(/\s+/)
      .map((token) => normalizeWord(token, locale))
      .filter((word) => word.length > 0),
  );
}

/**
 * A regrade keeps its attemptId, so each attempt counts once, using the assessment completed last (ties
 * go to the greater assessmentId). Records come back oldest first, with attempt IDs breaking ties.
 */
export function applicableRecords(records: readonly TutoringRecord[]): TutoringRecord[] {
  const latestByAttempt = [...groupBy(records, (record) => record.assessment.attemptId).values()].map((versions) =>
    versions.reduce((latest, candidate) => {
      const delta = Date.parse(candidate.evaluator.completedAt) - Date.parse(latest.evaluator.completedAt);
      if (delta !== 0) return delta > 0 ? candidate : latest;
      return compareText(candidate.assessment.assessmentId, latest.assessment.assessmentId) > 0 ? candidate : latest;
    }),
  );
  return latestByAttempt.sort(
    (a, b) => recordedTime(a) - recordedTime(b) || compareText(a.assessment.attemptId, b.assessment.attemptId),
  );
}

/** Groups records by local day, oldest first. Records within a day keep their input order. */
function byLocalDay<T extends TutoringRecord>(records: readonly T[]): [string, T[]][] {
  return [...groupBy(records, localDate)].sort(([a], [b]) => compareText(a, b));
}

function averageSamples(takes: readonly ScoredRecord[]): MetricSamples {
  return mapMetrics((metric) => {
    const values = takes.flatMap((take) => {
      const value = take.assessment.scores[metric];
      return value === null ? [] : [value];
    });
    return values.length === 0 ? null : { value: roundTenth(mean(values)), samples: values.length };
  });
}

function dailyPerformance(scored: readonly ScoredRecord[]): DailyPerformance[] {
  return byLocalDay(scored).map(([date, dayRecords]) => {
    const lines = [...groupBy(dayRecords, lineKey).values()];
    // Per metric, the earliest scorable take that has that metric: first-scorable performance.
    const firstScorable = mapMetrics((metric) => {
      const values = lines.flatMap((attempts) => {
        const value = attempts.find((record) => record.assessment.scores[metric] !== null)?.assessment.scores[metric];
        return value === undefined || value === null ? [] : [value];
      });
      return values.length === 0 ? null : { value: roundTenth(mean(values)), samples: values.length };
    });
    // The highest languageOverall take per line; strict ">" keeps the earliest take on a tie.
    const bestTakes = lines.flatMap((attempts) => {
      const best = attempts.reduce<ScoredRecord | undefined>((current, candidate) => {
        const value = candidate.assessment.scores.languageOverall;
        if (value === null) return current;
        const currentValue = current?.assessment.scores.languageOverall ?? null;
        return currentValue === null || value > currentValue ? candidate : current;
      }, undefined);
      return best === undefined ? [] : [best];
    });
    return { date, firstScorable, bestAttempt: averageSamples(bestTakes) };
  });
}

function skillTrend(metric: ScoreMetric, daily: readonly DailyPerformance[]): SkillTrend {
  const points = daily.flatMap((day) => {
    const sample = day.firstScorable[metric];
    return sample === null ? [] : [{ date: day.date, value: sample.value }];
  });
  const first = points[0] ?? null;
  const latest = points.at(-1) ?? null;
  if (first === null || latest === null || points.length < 2) {
    return { metric, first, latest, change: null, direction: "insufficient_history" };
  }
  const change = roundTenth(latest.value - first.value);
  const direction = change >= meaningfulChange ? "improving" : change <= -meaningfulChange ? "declining" : "steady";
  return { metric, first, latest, change, direction };
}

function repeatedLines(scored: readonly ScoredRecord[]): LineProgress[] {
  return [...groupBy(scored, lineKey).values()].flatMap((attempts) => {
    const days = byLocalDay(attempts).flatMap(([date, dayAttempts]) => {
      const record = dayAttempts.find((candidate) => candidate.assessment.scores.languageOverall !== null);
      const value = record?.assessment.scores.languageOverall;
      return record === undefined || value === undefined || value === null
        ? []
        : [{ date, value, attemptId: record.assessment.attemptId, assessmentId: record.assessment.assessmentId }];
    });
    const first = days[0];
    const latest = days.at(-1);
    const reference = attempts[0];
    if (first === undefined || latest === undefined || reference === undefined || days.length < 2) return [];
    return [
      {
        sceneId: reference.sceneId,
        lineId: reference.assessment.lineId,
        referenceVersion: reference.assessment.referenceVersion,
        referenceText: reference.assessment.referenceText,
        first,
        latest,
        change: roundTenth(latest.value - first.value),
      },
    ];
  });
}

function practicedLines(records: readonly TutoringRecord[]): PracticedLine[] {
  return [...groupBy(records, lineKey).values()]
    .flatMap((attempts) => {
      const latest = attempts.at(-1);
      if (latest === undefined) return [];
      return [
        {
          sceneId: latest.sceneId,
          lineId: latest.assessment.lineId,
          referenceVersion: latest.assessment.referenceVersion,
          referenceText: latest.assessment.referenceText,
          attempts: attempts.length,
          latestAttemptId: latest.assessment.attemptId,
          latestAssessmentId: latest.assessment.assessmentId,
          latestRecordedAt: latest.assessment.recordedAt,
          latestStatus: latest.assessment.status,
          latestScores: latest.assessment.status === "scored" ? latest.assessment.scores : null,
        },
      ];
    })
    .sort((a, b) => compareText(a.lineId, b.lineId) || a.referenceVersion - b.referenceVersion);
}

type WordEvidence = {
  word: string;
  attemptId: string;
  assessmentId: string;
  sessionId: string;
  isIssue: boolean;
  isScriptIssue: boolean;
  isPronunciationIssue: boolean;
  pronunciationScore: number | null;
};

function wordEvidence(record: ScoredRecord): WordEvidence[] {
  const acoustic = isAcoustic(record);
  return record.assessment.wordResults.flatMap((result) => {
    if (result.expected === null) return [];
    const word = normalizeWord(result.expected, record.assessment.locale);
    const isScriptIssue = result.textStatus === "substituted" || result.textStatus === "omitted";
    const isPronunciationIssue = isWordDifficulty(result, acoustic) && !isScriptIssue;
    const isIssue = isScriptIssue || isPronunciationIssue;
    // Acoustically, a matched word without a pronunciation measurement is neither a difficulty nor a success.
    if (word.length === 0 || (!isIssue && acoustic && result.pronunciationScore === null)) return [];
    return [
      {
        word,
        attemptId: record.assessment.attemptId,
        assessmentId: record.assessment.assessmentId,
        sessionId: record.sessionId,
        isIssue,
        isScriptIssue,
        isPronunciationIssue,
        pronunciationScore: acoustic ? result.pronunciationScore : null,
      },
    ];
  });
}

const wordStatusOrder: readonly WordStatus[] = ["persistent_weakness", "recent_difficulty", "recovering", "improved"];

function wordProgress(scored: readonly ScoredRecord[]): WordProgress[] {
  const words = [...groupBy(scored.flatMap(wordEvidence), (evidence) => evidence.word)].flatMap(([word, evidence]) => {
    const issues = evidence.filter((item) => item.isIssue);
    if (issues.length === 0) return [];
    const lastIssueIndex = evidence.findLastIndex((item) => item.isIssue);
    const cleanRun = evidence.length - 1 - lastIssueIndex;
    const issueSessions = new Set(issues.map((item) => item.sessionId)).size;
    const status: WordStatus =
      cleanRun === 0
        ? issueSessions >= 2
          ? "persistent_weakness"
          : "recent_difficulty"
        : cleanRun >= recoveryRunLength
          ? "improved"
          : "recovering";
    return [
      {
        word,
        status,
        occurrences: evidence.length,
        issueCount: issues.length,
        issueSessions,
        scriptIssueCount: issues.filter((item) => item.isScriptIssue).length,
        pronunciationIssueCount: issues.filter((item) => item.isPronunciationIssue).length,
        latestPronunciationScore: evidence.findLast((item) => item.pronunciationScore !== null)?.pronunciationScore ?? null,
        issueAttemptIds: [...new Set(issues.map((item) => item.attemptId))],
        issueAssessmentIds: [...new Set(issues.map((item) => item.assessmentId))],
        scriptIssueAssessmentIds: [...new Set(issues.filter((item) => item.isScriptIssue).map((item) => item.assessmentId))],
        pronunciationIssueAssessmentIds: [
          ...new Set(issues.filter((item) => item.isPronunciationIssue).map((item) => item.assessmentId)),
        ],
      },
    ];
  });
  return words.sort(
    (a, b) =>
      wordStatusOrder.indexOf(a.status) - wordStatusOrder.indexOf(b.status) ||
      b.issueSessions - a.issueSessions ||
      b.issueCount - a.issueCount ||
      compareText(a.word, b.word),
  );
}

function focusAreas(words: readonly WordProgress[], daily: readonly DailyPerformance[], acoustic: boolean): FocusArea[] {
  const struggling = words.flatMap((word): FocusArea[] =>
    word.status === "persistent_weakness" || word.status === "recent_difficulty"
      ? [{ kind: "word", word: word.word, status: word.status, issueCount: word.issueCount, issueAttemptIds: word.issueAttemptIds }]
      : [],
  );
  const latestDay = daily.at(-1);
  // languageOverall is a composite of the others, so the weakest underlying skill is the useful focus.
  const skillMetrics = acoustic
    ? (["pronunciation", "wordAccuracy", "fluency", "timingFit"] as const)
    : (["wordAccuracy", "fluency", "timingFit"] as const);
  const weakSkills = skillMetrics
    .flatMap((metric) => {
      const sample = latestDay?.firstScorable[metric] ?? null;
      return latestDay === undefined || sample === null || sample.value >= skillFocusThreshold
        ? []
        : [{ kind: "skill" as const, metric, latest: { date: latestDay.date, value: sample.value } }];
    })
    .sort((a, b) => a.latest.value - b.latest.value);
  return [...struggling.slice(0, 2), ...weakSkills.slice(0, 1), ...struggling.slice(2)].slice(0, maxFocusAreas);
}

function retryLines(scored: readonly ScoredRecord[], focusWords: ReadonlySet<string>): RetryLine[] {
  return [...groupBy(scored, lineKey).values()]
    .flatMap((attempts) => {
      const latest = attempts.at(-1);
      if (latest === undefined) return [];
      const words = referenceWords(latest.assessment.referenceText, latest.assessment.locale);
      const practiceWords = [...focusWords].filter((word) => words.has(word)).sort(compareText);
      if (practiceWords.length === 0) return [];
      return [
        {
          sceneId: latest.sceneId,
          lineId: latest.assessment.lineId,
          referenceVersion: latest.assessment.referenceVersion,
          referenceText: latest.assessment.referenceText,
          practiceWords,
          latestLanguageOverall: latest.assessment.scores.languageOverall,
          latestAttemptId: latest.assessment.attemptId,
          latestAssessmentId: latest.assessment.assessmentId,
        },
      ];
    })
    .sort(
      (a, b) =>
        (a.latestLanguageOverall ?? 101) - (b.latestLanguageOverall ?? 101) ||
        compareText(a.lineId, b.lineId) ||
        a.referenceVersion - b.referenceVersion,
    )
    .slice(0, maxSuggestedLines);
}

function newLines(
  catalog: readonly PracticeLine[],
  locale: string,
  practisedLineKeys: ReadonlySet<string>,
  focusWords: ReadonlySet<string>,
): NewLine[] {
  return catalog
    .filter((line) => line.locale === locale && !practisedLineKeys.has(`${line.lineId}#${line.referenceVersion}`))
    .flatMap((line) => {
      const words = referenceWords(line.referenceText, line.locale);
      const practiceWords = [...focusWords].filter((word) => words.has(word)).sort(compareText);
      return practiceWords.length === 0 ? [] : [{ ...line, practiceWords }];
    })
    .sort((a, b) => b.practiceWords.length - a.practiceWords.length || compareText(a.lineId, b.lineId))
    .slice(0, maxSuggestedLines);
}

const metricNames: Record<ScoreMetric, string> = {
  languageOverall: "language score",
  pronunciation: "pronunciation",
  wordAccuracy: "word accuracy",
  fluency: "fluency",
  timingFit: "timing fit",
};

function listed(items: readonly string[]): string {
  return items.length <= 2 ? items.join(" and ") : `${items.slice(0, -1).join(", ")}, and ${items.at(-1)}`;
}

const quoted = (words: readonly string[]) => listed(words.map((word) => `"${word}"`));

function progressSummary(
  volume: PracticeVolume,
  skills: readonly SkillTrend[],
  lines: readonly LineProgress[],
  words: readonly WordProgress[],
): string {
  const improvedLines = lines.filter((line) => line.change >= meaningfulChange).length;
  const changes = skills.flatMap((trend) =>
    trend.first !== null && trend.latest !== null && (trend.direction === "improving" || trend.direction === "declining")
      ? [
          `${metricNames[trend.metric]} ${trend.direction === "improving" ? "rose" : "fell"} ` +
            `from ${trend.first.value} to ${trend.latest.value}`,
        ]
      : [],
  );
  // Daily averages mix different lines, so they're labelled apart from same-line improvement, as the contract asks.
  const sentences = [
    `You practised ${volume.lines} lines across ${volume.sessions} sessions on ${volume.practiceDays} days, ` +
      `and ${volume.scorableAttempts} of ${volume.attempts} attempts could be scored.`,
    ...(changes.length === 0 ? [] : [`Averaged over the lines you practised each day, ${listed(changes)}.`]),
    ...(lines.length === 0
      ? []
      : [`On lines you repeated on different days, your language score improved on ${improvedLines} of ${lines.length}.`]),
  ];
  const persistent = words.filter((word) => word.status === "persistent_weakness").slice(0, 2).map((word) => word.word);
  const improved = words.filter((word) => word.status === "improved").slice(0, 2).map((word) => word.word);
  if (persistent.length > 0) sentences.push(`Keep working on ${quoted(persistent)}.`);
  if (improved.length > 0) sentences.push(`${quoted(improved)} ${improved.length === 1 ? "has" : "have"} improved.`);
  return sentences.join(" ");
}

function seriesProgress(records: readonly TutoringRecord[], catalog: readonly PracticeLine[]): SeriesProgress {
  const reference = records[0];
  if (reference === undefined) throw new Error("A progress series needs at least one record");
  const acoustic = isAcoustic(reference);
  const scored = records.filter(isScored);
  const volume: PracticeVolume = {
    sessions: new Set(records.map((record) => record.sessionId)).size,
    attempts: records.length,
    scorableAttempts: scored.length,
    lines: new Set(records.map(lineKey)).size,
    practiceDays: new Set(records.map(localDate)).size,
    speakingMs: records.reduce((sum, record) => sum + record.speakingDurationMs, 0),
  };
  const daily = dailyPerformance(scored);
  const skills = scoreMetrics.map((metric) => skillTrend(metric, daily));
  const repeated = repeatedLines(scored);
  const words = wordProgress(scored);
  const focus = focusAreas(words, daily, acoustic);
  const focusWords = new Set(focus.flatMap((area) => (area.kind === "word" ? [area.word] : [])));
  return {
    locale: reference.assessment.locale,
    rubricVersion: reference.assessment.rubricVersion,
    evaluator: {
      provider: reference.evaluator.provider,
      modelVersion: reference.evaluator.modelVersion,
      configVersion: reference.evaluator.configVersion,
      measurement: reference.evaluator.measurement,
    },
    pronunciationBasis: acoustic ? "acoustic" : "script_agreement",
    unavailableMetrics: acoustic
      ? []
      : [
          { metric: "pronunciation", reason: "no_acoustic_measurement" },
          { metric: "fluency", reason: "no_acoustic_measurement" },
        ],
    volume,
    daily,
    skills,
    lines: practicedLines(records),
    repeatedLines: repeated,
    words,
    guidance: {
      summary: progressSummary(volume, skills, repeated, words),
      focusAreas: focus,
      retryLines: retryLines(scored, focusWords),
      newLines: newLines(catalog, reference.assessment.locale, new Set(records.map(lineKey)), focusWords),
    },
  };
}

/**
 * Computes progress and tutoring guidance from stored assessments, following the grading contract's
 * progress rules. Every score and improvement comes from the assessments; nothing is generated.
 * Series are ordered by most recent practice first, then by key, so the output is deterministic.
 */
export function buildTutoringReport(
  records: readonly TutoringRecord[],
  catalog: readonly PracticeLine[],
  generatedAt: string,
): TutoringReport {
  const latestPractice = (group: readonly TutoringRecord[]) => Math.max(...group.map(recordedTime));
  const series = [...groupBy(applicableRecords(records), seriesKey)]
    .sort(([keyA, a], [keyB, b]) => latestPractice(b) - latestPractice(a) || compareText(keyA, keyB))
    .map(([, seriesRecords]) => seriesProgress(seriesRecords, catalog));
  return { generatedAt, timeZonePolicy: "attempt-time-zone", series };
}
