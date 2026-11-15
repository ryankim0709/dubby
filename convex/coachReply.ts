import Anthropic from "@anthropic-ai/sdk";
import type { CoachCharacter } from "./coachCharacters";

export type CoachTurn = { role: "learner" | "coach"; text: string };

export class CoachReplyError extends Error {}

// Every character shares these rules; only the persona changes, so one coaching system powers them all.
const coachingRules = (languageName: string) =>
  [
    `You are a language coach inside DubIt, an app where learners practise ${languageName} by dubbing short movie scenes.`,
    "Everything you write is spoken aloud by a talking avatar, so write plain speech: no markdown, lists, emoji, or stage directions.",
    "Keep each reply to one to three short sentences.",
    `Speak mostly in ${languageName} at the learner's level, and switch to English only for a brief explanation when they are stuck.`,
    "You only receive a speech-to-text transcript of the learner, not their audio, so never claim to have heard their pronunciation or accent.",
    "Comment on wording, grammar, and natural phrasing, give one concrete thing to try next, and ask them to say it.",
    "Stay in character, but never claim to be a real actor or quote copyrighted film dialogue at length.",
  ].join("\n");

/** Turns the app's transcript into Messages API turns; the API requires the first turn to be the user's. */
export function messagesFor(turns: readonly CoachTurn[]): Anthropic.MessageParam[] {
  return turns.map((turn) => ({
    role: turn.role === "learner" ? "user" : "assistant",
    content: turn.text,
  }));
}

/** Asks Claude what the coach says next. The SDK retries 429, 5xx, and connection failures with backoff. */
export async function coachReply(
  client: Anthropic,
  character: CoachCharacter,
  languageName: string,
  turns: readonly CoachTurn[],
): Promise<string> {
  const response = await client.beta.messages.create({
    model: "claude-opus-5-5",
    max_tokens: 16000,
    // Spoken chat needs a fast first reply more than deep reasoning.
    output_config: { effort: "low" },
    betas: ["server-side-fallback-2026-07-01"],
    fallbacks: "default",
    system: `${coachingRules(languageName)}\n\n${character.persona}`,
    messages: messagesFor(turns),
  });
  if (response.stop_reason === "refusal") {
    throw new CoachReplyError(
      `Claude declined the coach reply (category: ${response.stop_details?.category ?? "none"})`,
    );
  }
  const text = response.content
    .flatMap((block) => (block.type === "text" ? [block.text] : []))
    .join(" ")
    .trim();
  if (text.length === 0) {
    throw new CoachReplyError(`Claude returned no text (stop_reason: ${response.stop_reason})`);
  }
  return text;
}
