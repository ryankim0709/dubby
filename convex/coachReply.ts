import OpenAI from "openai";
import type { CoachCharacter } from "./coachCharacters";
import { requiredEnv } from "./env";
import { maxSpokenWords, scriptDisclosure, renderEvidence, type EvidencePack, type GeneratedReply } from "./tutoringReply";

export type CoachTurn = { role: "learner" | "coach"; text: string };

export class CoachReplyError extends Error {}
/** The provider didn't answer within the bounded timeout. */
export class CoachTimeoutError extends Error {}

// Each OpenAI attempt gets 8 seconds and a failed one is retried once, so a spoken reply either arrives or fails
// within about 17 seconds. Callers get a provider_timeout instead of a canned reply.
const requestTimeoutMs = 8_000;
const requestRetries = 1;

/** The one place the OpenAI client is built; the key stays in the Convex environment. */
export function createCoachClient(): OpenAI {
  return new OpenAI({ apiKey: requiredEnv("OPENAI_API_KEY"), timeout: requestTimeoutMs, maxRetries: requestRetries });
}

// Model IDs are plain configuration, not secrets. Defaults were checked against developers.openai.com on 2026-11-15.
// gpt-6-luna is OpenAI's most efficient model for focused, high-volume tasks, which suits a two-sentence spoken reply.
// The speech model is deprecated on 2027-01-06 per OpenAI's deprecation notice; set OPENAI_TTS_MODEL when its replacement is chosen.
const defaultCoachModel = "gpt-6-luna";
const defaultSpeechModel = "gpt-4o-mini-tts";

export const coachModelId = (env: Record<string, string | undefined> = process.env) => env.OPENAI_COACH_MODEL || defaultCoachModel;
export const speechModelId = (env: Record<string, string | undefined> = process.env) => env.OPENAI_TTS_MODEL || defaultSpeechModel;

// Every character shares these rules; only the persona changes, so one coaching system powers them all.
const coachingRules = (languageName: string, pack: EvidencePack) =>
  [
    `You are a language coach inside DubIt, an app where learners practise ${languageName} by dubbing short movie scenes.`,
    "Everything you write is spoken aloud by a talking avatar, so write plain speech: no markdown, lists, emoji, digits, or stage directions.",
    `Reply with at most two short sentences and under ${maxSpokenWords - 5} words.`,
    `Speak mostly in ${languageName} at the learner's level, and switch to English only for a brief explanation when they are stuck.`,
    "You never hear the learner's audio. You only have a speech-to-text transcript and the evidence below, so never claim to have heard their pronunciation or accent.",
    "Only state findings the evidence supports, and list the IDs of the evidence you used in cites. Put no ID in the spoken text.",
    "If the evidence is empty, cite nothing and invite the learner to record a line.",
    ...(pack.basis === "script_agreement"
      ? [`The evidence rests on script agreement only. Whenever you cite evidence, say "${scriptDisclosure}" in your reply and make no pronunciation claim.`]
      : []),
    "Stay in character, but never claim to be a real actor or quote copyrighted film dialogue at length.",
    `Reply as JSON: {"text": the spoken reply, "cites": [evidence IDs]}.`,
    "",
    "Evidence:",
    renderEvidence(pack),
  ].join("\n");

const replySchema = {
  type: "object",
  properties: {
    text: { type: "string" },
    cites: { type: "array", items: { type: "string" } },
  },
  required: ["text", "cites"],
  additionalProperties: false,
} as const;

/** Turns the app's transcript into Responses API input items; the first turn is the learner's. */
export function inputFor(turns: readonly CoachTurn[]): OpenAI.Responses.EasyInputMessage[] {
  return turns.map((turn) => ({
    role: turn.role === "learner" ? "user" : "assistant",
    content: turn.text,
  }));
}

/**
 * Asks the coach model for the next spoken reply as JSON {text, cites}, grounded in the tutor's evidence
 * pack. The caller runs the post-check and falls back to the template. store:false keeps the learner's
 * words out of OpenAI's stored response history; nothing here needs a stored response later.
 */
export async function coachReply(
  client: OpenAI,
  character: CoachCharacter,
  languageName: string,
  turns: readonly CoachTurn[],
  pack: EvidencePack,
  model: string = coachModelId(),
): Promise<GeneratedReply> {
  const response = await client.responses.create({
    model,
    instructions: `${coachingRules(languageName, pack)}\n\n${character.persona}`,
    input: inputFor(turns),
    max_output_tokens: 400,
    store: false,
    // Spoken chat needs a fast first reply more than deep reasoning.
    reasoning: { effort: "none" },
    text: { format: { type: "json_schema", name: "coach_reply", strict: true, schema: replySchema } },
  });
  const text = response.output_text.trim();
  if (text.length === 0) {
    throw new CoachReplyError(`The coach model returned no text (status: ${response.status ?? "unknown"})`);
  }
  return { text, model: response.model || model, responseId: response.id || null };
}

function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  const chunk = 0x8000;
  for (let offset = 0; offset < bytes.length; offset += chunk) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + chunk));
  }
  return btoa(binary);
}

/**
 * Voices a reply as raw PCM, 16-bit signed little-endian, 24 kHz mono, base64-encoded: the exact format
 * LiveAvatar's LITE-mode agent.speak command takes, so the app forwards it without conversion.
 */
export async function speakReply(client: OpenAI, character: CoachCharacter, text: string, model: string = speechModelId()): Promise<string> {
  const response = await client.audio.speech.create({
    model,
    voice: character.openaiVoice,
    input: text,
    instructions: character.voiceStyle,
    response_format: "pcm",
  });
  return bytesToBase64(new Uint8Array(await response.arrayBuffer()));
}
