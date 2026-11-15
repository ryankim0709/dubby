import { z } from "zod";
import type { NextExercise } from "./tutoringExercise";
import type { SeriesProgress, TutoringReport } from "./tutoringProgress";

// Hard limits for a reply that a talking avatar speaks aloud. About two sentences is the target; these
// are the ceilings the post-check enforces.
export const maxSpokenWords = 45;
export const maxSpokenSentences = 3;

/** The sentence a script-based reply has to carry, so the learner knows no audio was measured. */
export const scriptDisclosure = "how closely your words match the script";

export type EvidenceItem = {
  /** The assessment ID. A reply may cite only IDs that appear in the pack. */
  id: string;
  attemptId: string;
  lineId: string;
  referenceText: string;
  /** A short clause that completes "your last take": it states a finding the assessment supports. */
  headline: string;
};

export type EvidencePack = {
  basis: "acoustic" | "script_agreement" | "none";
  items: EvidenceItem[];
  exercise: NextExercise;
  /** Retrieved memory snippets: unverified context for tone, never a source of measurements. */
  memoryNotes: string[];
};

const maxEvidenceItems = 3;
const maxMemoryNotes = 3;
const maxMemoryNoteLength = 200;

const quotedList = (words: readonly string[]) =>
  words.length <= 2
    ? words.map((word) => `"${word}"`).join(" and ")
    : `${words.slice(0, -1).map((word) => `"${word}"`).join(", ")}, and "${words.at(-1)}"`;

function headline(series: SeriesProgress, line: SeriesProgress["lines"][number]): string {
  if (line.latestScores === null) return "your last recording of this line could not be scored";
  const id = line.latestAssessmentId;
  const scriptWords = series.words.filter((word) => word.scriptIssueAssessmentIds.includes(id)).map((word) => word.word);
  const pronunciationWords = series.words
    .filter((word) => word.pronunciationIssueAssessmentIds.includes(id))
    .map((word) => word.word);
  const parts = [
    ...(scriptWords.length === 0 ? [] : [`${quotedList(scriptWords)} differed from the script`]),
    ...(pronunciationWords.length === 0 ? [] : [`the pronunciation check flagged ${quotedList(pronunciationWords)}`]),
  ];
  if (parts.length > 0) return parts.join(" and ");
  if (line.latestScores.wordAccuracy === null) return "your last take could not be compared word by word";
  return series.pronunciationBasis === "acoustic" ? "nothing was flagged in your last take" : "every word matched in your last take";
}

/**
 * Turns the computed report into what a reply may talk about. Every item is backed by one stored
 * assessment, and the pack carries no numbers, so a reply can't state a score the tutor didn't compute.
 */
export function buildEvidencePack(
  report: TutoringReport,
  exercise: NextExercise,
  memoryNotes: readonly string[] = [],
): EvidencePack {
  const series = report.series.find((item) => item.locale === exercise.locale) ?? report.series[0];
  const notes = memoryNotes.map((note) => note.trim().slice(0, maxMemoryNoteLength)).filter((note) => note.length > 0).slice(0, maxMemoryNotes);
  if (series === undefined) return { basis: "none", items: [], exercise, memoryNotes: notes };
  const items = [...series.lines]
    .sort(
      (a, b) =>
        (a.latestRecordedAt < b.latestRecordedAt ? 1 : a.latestRecordedAt > b.latestRecordedAt ? -1 : 0) ||
        (a.lineId < b.lineId ? -1 : 1),
    )
    .slice(0, maxEvidenceItems)
    .map((line) => ({
      id: line.latestAssessmentId,
      attemptId: line.latestAttemptId,
      lineId: line.lineId,
      referenceText: line.referenceText,
      headline: headline(series, line),
    }));
  return { basis: series.pronunciationBasis, items, exercise, memoryNotes: notes };
}

/** The evidence as prompt text. Memory notes are labelled unverified so the model can't present them as measured. */
export function renderEvidence(pack: EvidencePack): string {
  const basis =
    pack.basis === "acoustic"
      ? "Some findings come from an acoustic pronunciation measurement."
      : pack.basis === "script_agreement"
        ? `Feedback is based only on script agreement (a transcript compared with the script). No audio was measured, so make no pronunciation claim, and say "${scriptDisclosure}" when you cite evidence.`
        : "The learner has no assessed practice yet. Cite nothing.";
  return [
    basis,
    ...pack.items.map((item) => `[${item.id}] Line "${item.referenceText}": ${item.headline}.`),
    `Suggested next step: ${pack.exercise.instruction}`,
    ...(pack.memoryNotes.length === 0
      ? []
      : ["Unverified notes from earlier sessions, for context only:", ...pack.memoryNotes.map((note) => `- ${note}`)]),
  ].join("\n");
}

const modelReply = z.object({ text: z.string(), cites: z.array(z.string()) });
export type ModelReply = z.infer<typeof modelReply>;

/** Reads the model's JSON reply, tolerating a Markdown code fence around it. */
export function parseModelReply(raw: string): ModelReply | undefined {
  const unfenced = raw.trim().replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "");
  try {
    const parsed = modelReply.safeParse(JSON.parse(unfenced));
    return parsed.success ? parsed.data : undefined;
  } catch {
    return undefined;
  }
}

const pronunciationVocabulary = /pronunc|pronounc|accent|phoneme|acento|prononc|aussprache|発音|발음|发音|произнош/iu;

/** Why a model reply can't be spoken. An empty list means it passed. */
export function replyProblems(reply: ModelReply, pack: EvidencePack): string[] {
  const text = reply.text.trim();
  const problems: string[] = [];
  if (text.length === 0) problems.push("empty");
  if (/[\n*#_`|]/.test(text) || /\p{Extended_Pictographic}/u.test(text)) problems.push("not_plain_speech");
  if (text.split(/\s+/).length > maxSpokenWords) problems.push("too_many_words");
  const sentences = text.split(/(?<=[.!?…])\s+|(?<=[。！？])/u).filter((sentence) => sentence.trim().length > 0);
  if (sentences.length > maxSpokenSentences) problems.push("too_many_sentences");
  const known = new Set(pack.items.map((item) => item.id));
  if (reply.cites.some((id) => !known.has(id))) problems.push("cites_unknown_evidence");
  if (pack.items.length > 0 && reply.cites.length === 0) problems.push("uncited");
  if (/\d/.test(text)) problems.push("unsupported_number");
  if (pack.basis !== "acoustic" && pronunciationVocabulary.test(text)) problems.push("pronunciation_claim_without_acoustic_measurement");
  if (pack.basis === "script_agreement" && reply.cites.length > 0 && !text.toLowerCase().includes(scriptDisclosure)) {
    problems.push("missing_script_disclosure");
  }
  return problems;
}

const capitalize = (text: string) => text.charAt(0).toUpperCase() + text.slice(1);

/** The deterministic fallback: one finding from the newest assessed line, then the next step. */
export function templateReply(pack: EvidencePack): ModelReply {
  const top = pack.items[0];
  if (top === undefined) {
    return { text: `I haven't seen any practice from you yet. ${pack.exercise.instruction}`, cites: [] };
  }
  const finding =
    pack.basis === "script_agreement" ? `Going by ${scriptDisclosure}, ${top.headline}.` : `${capitalize(top.headline)}.`;
  return { text: `${finding} ${pack.exercise.instruction}`, cites: [top.id] };
}

export type ComposedReply = { text: string; cites: string[]; source: "model" | "template"; problems: string[] };

/**
 * Asks the model for a reply and keeps it only if it passes the post-check; a model failure, an
 * unreadable answer or a failed check falls back to the template. The tutor always answers.
 */
export async function composeReply(pack: EvidencePack, generate: (pack: EvidencePack) => Promise<string>): Promise<ComposedReply> {
  const fallback = (problems: string[]): ComposedReply => ({ ...templateReply(pack), source: "template", problems });
  let raw: string;
  try {
    raw = await generate(pack);
  } catch (error) {
    console.warn("coach model reply failed, using the template", { error: String(error) });
    return fallback(["model_failed"]);
  }
  const parsed = parseModelReply(raw);
  if (parsed === undefined) return fallback(["unreadable"]);
  const problems = replyProblems(parsed, pack);
  if (problems.length > 0) return fallback(problems);
  return { text: parsed.text.trim(), cites: [...new Set(parsed.cites)], source: "model", problems: [] };
}
