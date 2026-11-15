// Word alignment for the wordAccuracy metric. The alignment minimizes substitutions + omissions + insertions
// (Levenshtein with unit costs, as the contract counts S, D and I) and, among equally cheap alignments, keeps
// the most exact matches, so an omitted word is not hidden behind a chain of substitutions.

export type AlignOp =
  | { op: "match" | "substitute"; referenceIndex: number; recognizedIndex: number }
  | { op: "omit"; referenceIndex: number }
  | { op: "insert"; recognizedIndex: number };

export interface Alignment {
  ops: AlignOp[];
  matched: number;
  substituted: number;
  omitted: number;
  inserted: number;
}

/** Ties on both criteria prefer a diagonal move, then an omission, then an insertion, so the result is deterministic. */
export function align(reference: readonly string[], recognized: readonly string[]): Alignment {
  const n = reference.length;
  const m = recognized.length;
  // One number encodes (errors, matches): each error costs `error`, each match refunds 1, and matches never exceed min(n, m) < error.
  const error = n + m + 1;
  const cost: number[][] = Array.from({ length: n + 1 }, () => new Array<number>(m + 1).fill(0));
  for (let i = 1; i <= n; i++) cost[i]![0] = i * error;
  for (let j = 1; j <= m; j++) cost[0]![j] = j * error;
  const diagonalCost = (i: number, j: number) => cost[i - 1]![j - 1]! + (reference[i - 1] === recognized[j - 1] ? -1 : error);
  for (let i = 1; i <= n; i++) {
    for (let j = 1; j <= m; j++) {
      cost[i]![j] = Math.min(diagonalCost(i, j), cost[i - 1]![j]! + error, cost[i]![j - 1]! + error);
    }
  }

  const ops: AlignOp[] = [];
  let i = n;
  let j = m;
  while (i > 0 || j > 0) {
    const here = cost[i]![j]!;
    if (i > 0 && j > 0 && here === diagonalCost(i, j)) {
      ops.push({ op: reference[i - 1] === recognized[j - 1] ? "match" : "substitute", referenceIndex: i - 1, recognizedIndex: j - 1 });
      i--;
      j--;
    } else if (i > 0 && here === cost[i - 1]![j]! + error) {
      ops.push({ op: "omit", referenceIndex: i - 1 });
      i--;
    } else {
      ops.push({ op: "insert", recognizedIndex: j - 1 });
      j--;
    }
  }
  ops.reverse();

  const count = (kind: AlignOp["op"]) => ops.filter((entry) => entry.op === kind).length;
  return {
    ops,
    matched: count("match"),
    substituted: count("substitute"),
    omitted: count("omit"),
    inserted: count("insert"),
  };
}
