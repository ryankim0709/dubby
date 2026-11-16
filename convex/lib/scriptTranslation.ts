import type OpenAI from "openai";
import { z } from "zod";
import { withProviderRetries } from "./transcription";

export class TranslationResponseError extends Error {}

/** One line of a scene section in spoken order. The speaker is absent when the app grouped voices on the device. */
export type SourceLine = { speaker?: string; seconds: number; text: string };
export type ScriptTranslationRequest = { sourceLocale: string; targetLocale: string; sceneTitle: string; lines: SourceLine[] };

// Checked against developers.openai.com on 2026-11-15: gpt-6-luna takes structured outputs and already powers the scene cast.
const translationModel = "gpt-6-luna";

// Translating the section in one request lets the model keep register and forms of address consistent between the
// characters, which line-by-line translation into Korean or Japanese gets wrong.
const translationInstructions = [
  "You translate the dialogue of a short film scene for a dubbing app. A language learner re-voices one character in the target language over the original video.",
  "You get the source and target languages as BCP-47 tags, the scene title, and the scene's lines in spoken order, each with how many seconds the actor takes to say it and, when known, who says it.",
  "Translate the lines as one conversation: keep the tone, the relationship between the characters, and the register and forms of address a native speaker would use between them consistent across every line.",
  "Write natural, idiomatic spoken dialogue, as a professional dub would, not a word-for-word translation.",
  "Each line must be sayable in about the same number of seconds as the original, so the learner can speak it over the actor's mouth movements. Prefer a shorter natural phrasing to a complete literal one.",
  "Return exactly one translation per input line, in the same order, never merging, splitting, skipping or adding lines. When a sentence runs across two lines, split its translation across the same two lines.",
  "Keep names of people and places as the dialogue uses them, written the way the target language normally writes them.",
  "Write only the spoken words in the target language's standard script: no romanization, notes, quotation marks, speaker labels or stage directions.",
].join("\n");

const translationSchema = {
  type: "object",
  properties: { lines: { type: "array", items: { type: "string" } } },
  required: ["lines"],
  additionalProperties: false,
} as const;

/** Numbered lines with their speaker and length, so the model can keep one translation per line. */
export function translationInput(request: ScriptTranslationRequest): string {
  const lines = request.lines
    .map((line, index) => `${index + 1}. [${line.speaker ?? "speaker unknown"}, ${line.seconds.toFixed(1)} s] ${line.text}`)
    .join("\n");
  return `Source language: ${request.sourceLocale}\nTarget language: ${request.targetLocale}\nScene title: ${request.sceneTitle}\n\nLines:\n${lines}`;
}

const modelTranslation = z.object({ lines: z.array(z.string().trim().min(1).max(1_000)) });

/** The studio pairs translations with line timings by position, so a missing or extra line is an error, not a shift. */
export function parseTranslation(outputText: string, lineCount: number): string[] {
  let json: unknown;
  try {
    json = JSON.parse(outputText);
  } catch {
    throw new TranslationResponseError("The translation model returned text that isn't JSON");
  }
  const parsed = modelTranslation.safeParse(json);
  if (!parsed.success) throw new TranslationResponseError("The translation model returned an empty line or JSON in the wrong shape");
  if (parsed.data.lines.length !== lineCount) {
    throw new TranslationResponseError(`The translation model returned ${parsed.data.lines.length} lines for ${lineCount}`);
  }
  return parsed.data.lines;
}

/** Translates a section's lines into the language the learner dubs in, keeping one translation per line. */
export async function translateScript(client: OpenAI, request: ScriptTranslationRequest): Promise<string[]> {
  return await withProviderRetries("scripts.translate", async () => {
    const response = await client.responses.create({
      model: translationModel,
      instructions: translationInstructions,
      input: translationInput(request),
      // Reasoning and the answer share this budget; a 30-second section's translation is a few hundred tokens.
      max_output_tokens: 8_000,
      store: false,
      reasoning: { effort: "low" },
      text: { format: { type: "json_schema", name: "script_translation", strict: true, schema: translationSchema } },
    }, { maxRetries: 0, timeout: 30_000 });
    return parseTranslation(response.output_text, request.lines.length);
  });
}
