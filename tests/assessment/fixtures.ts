// SYNTHETIC fixtures. The payloads follow the field names and units in Microsoft's REST short-audio and
// pronunciation-assessment documentation; no Azure service produced them, and none are real recordings.
import type { AssessAttemptInput } from "../../convex/assessment/index";

export interface SyntheticWord {
  word: string;
  startMs?: number;
  durationMs?: number;
  accuracy?: number;
  errorType?: string;
}

const TICKS_PER_MS = 10_000;

/** Builds a synthetic Success body in the REST sample's flat shape. */
export function syntheticSuccess(options: {
  display: string;
  words: SyntheticWord[];
  accuracy?: number;
  fluency?: number;
  completeness?: number;
  nested?: boolean;
}): Record<string, unknown> {
  const scoresOf = (scores: Record<string, unknown>) => (options.nested ? { PronunciationAssessment: scores } : scores);
  return {
    RecognitionStatus: "Success",
    Offset: 700_000,
    Duration: 8_400_000,
    DisplayText: options.display,
    SNR: 38.5,
    NBest: [
      {
        Confidence: 0.98,
        Lexical: options.display.toLowerCase(),
        Display: options.display,
        ...scoresOf({
          AccuracyScore: options.accuracy ?? 90,
          FluencyScore: options.fluency ?? 90,
          CompletenessScore: options.completeness ?? 100,
          PronScore: 90,
        }),
        Words: options.words.map((entry) => {
          const errorType = entry.errorType ?? "None";
          const omitted = errorType === "Omission";
          return {
            Word: entry.word,
            ...(omitted ? {} : { Offset: (entry.startMs ?? 0) * TICKS_PER_MS, Duration: (entry.durationMs ?? 200) * TICKS_PER_MS }),
            ...scoresOf({ ...(entry.accuracy === undefined ? {} : { AccuracyScore: entry.accuracy }), ErrorType: errorType }),
          };
        }),
      },
    ],
  };
}

export const status = (RecognitionStatus: string) => ({ RecognitionStatus });

/** The contract's own illustrative example: four matched words, spoken span 2,700 ms of a 3,000 ms window. */
export const exampleWords: SyntheticWord[] = [
  { word: "you", startMs: 200, durationMs: 220, accuracy: 96 },
  { word: "underestimate", startMs: 430, durationMs: 1120, accuracy: 64 },
  { word: "my", startMs: 1650, durationMs: 230, accuracy: 93 },
  { word: "power", startMs: 2000, durationMs: 900, accuracy: 91 },
];

export function baseInput(provider: AssessAttemptInput["provider"], overrides: Partial<AssessAttemptInput> = {}): AssessAttemptInput {
  return {
    assessmentId: "assessment_001",
    attemptId: "take_003",
    lineId: "scene_001_line_02",
    referenceVersion: 1,
    locale: "en-US",
    recordedAt: "2026-11-14T18:00:00-08:00",
    referenceText: "You underestimate my power.",
    targetWindowMs: { startMs: 10_000, endMs: 13_000 },
    recordingDurationMs: 3_200,
    provider,
    ...overrides,
  };
}

export const ok = (body: unknown) => ({ httpStatus: 200, body });
