// Text normalization and tokenization for rubric language-v1. Changing any rule here is a rubric revision.
// Only en-US is implemented; every other locale is reported as unsupported_locale by the caller.

export const NORMALIZATION_VERSION = "language-v1";
export const SUPPORTED_LOCALES: readonly string[] = ["en-US"];

export interface Token {
  /** Case-folded form used for alignment. */
  norm: string;
  /** Form shown to the learner: the original casing without surrounding punctuation. */
  display: string;
}

const ones = [
  "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven",
  "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
];
const tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"];
const scales: Array<[number, string]> = [
  [1_000_000_000, "billion"],
  [1_000_000, "million"],
  [1_000, "thousand"],
];

function below1000(n: number): string[] {
  const words: string[] = [];
  if (n >= 100) {
    words.push(ones[Math.floor(n / 100)]!, "hundred");
    n %= 100;
  }
  if (n >= 20) {
    words.push(tens[Math.floor(n / 10)]!);
    n %= 10;
    if (n > 0) words.push(ones[n]!);
    return words;
  }
  if (n > 0) words.push(ones[n]!);
  return words;
}

/** Spoken cardinal for a non-negative integer below 10^12, so a digit reference matches the engine's spelled-out words. */
function cardinalWords(n: number): string[] {
  if (n === 0) return ["zero"];
  const words: string[] = [];
  for (const [size, name] of scales) {
    if (n >= size) {
      words.push(...below1000(Math.floor(n / size)), name);
      n %= size;
    }
  }
  words.push(...below1000(n));
  return words;
}

/**
 * Splits text into alignment tokens: NFKC, curly apostrophes folded to ', dashes treated as separators,
 * punctuation dropped, apostrophes and hyphens kept inside a word, lowercase compare form, digit runs
 * spelled out as cardinals. Years, decimals and ordinals are not expanded and compare literally.
 */
export function tokenize(text: string): Token[] {
  const cleaned = text
    .normalize("NFKC")
    .replace(/[\u2018\u2019\u02BC]/g, "'")
    .replace(/[\u2014\u2013\u2015]/g, " ")
    .replace(/(?<=\d),(?=\d{3}(?!\d))/g, "");
  const tokens: Token[] = [];
  for (const piece of cleaned.split(/[^\p{L}\p{N}'-]+/u)) {
    const word = piece.replace(/^['-]+|['-]+$/g, "");
    if (word === "") continue;
    if (/^\d{1,12}$/.test(word)) {
      for (const spoken of cardinalWords(Number(word))) tokens.push({ norm: spoken, display: spoken });
      continue;
    }
    tokens.push({ norm: word.toLocaleLowerCase("en-US"), display: word });
  }
  return tokens;
}
