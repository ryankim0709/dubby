import { roundHalfUp } from "../assessment/assess";

// The dub score sheet's arithmetic (docs/grading-contract.md, "Dub score sheet (dub-v1)"). Changing a
// weight or a rule here is a new sheet version.

export const DUB_SHEET_VERSION = "dub-v1" as const;

export type DubTakeStatus = "queued" | "scored" | "unscorable" | "failed";

/** 0.70 word accuracy + 0.30 timing fit from unrounded parts; null when either part is unavailable. */
export function computeLineScore(wordAccuracy: number | null, timingFit: number | null): number | null {
  if (wordAccuracy === null || timingFit === null) return null;
  return 0.7 * wordAccuracy + 0.3 * timingFit;
}

export interface SheetLineInput {
  status: DubTakeStatus;
  /** Unrounded values, as computed for the line. */
  lineScore: number | null;
  wordAccuracy: number | null;
  timingFit: number | null;
}

export interface SheetSummary {
  status: "scoring" | "complete";
  dubScore: number | null;
  wordAccuracy: number | null;
  timingFit: number | null;
  linesDubbed: number;
  linesScored: number;
  linesUnscorable: number;
  linesFailed: number;
}

/** Mean of the present values, rounded half up; unavailable values are left out, never counted as zero. */
function roundedMean(values: readonly (number | null)[]): number | null {
  const present = values.filter((value): value is number => value !== null);
  if (present.length === 0) return null;
  return roundHalfUp(present.reduce((sum, value) => sum + value, 0) / present.length);
}

export function summarizeSheet(lines: readonly SheetLineInput[]): SheetSummary {
  const count = (status: DubTakeStatus) => lines.filter((line) => line.status === status).length;
  return {
    status: count("queued") === 0 ? "complete" : "scoring",
    dubScore: roundedMean(lines.map((line) => line.lineScore)),
    wordAccuracy: roundedMean(lines.map((line) => line.wordAccuracy)),
    timingFit: roundedMean(lines.map((line) => line.timingFit)),
    linesDubbed: lines.length,
    linesScored: count("scored"),
    linesUnscorable: count("unscorable"),
    linesFailed: count("failed"),
  };
}
