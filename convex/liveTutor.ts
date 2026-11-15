import { makeFunctionReference } from "convex/server";
import type { Infer } from "convex/values";
import type OpenAI from "openai";
import type { dubScoreSheetV } from "./lib/validators";

// The live tutor: after a dub is scored, the learner talks with an OpenAI Realtime voice tutor that works through
// the lines they got wrong. The backend writes the tutor's instructions from the stored score sheet and mints a
// short-lived client secret with them; the app then streams audio to OpenAI directly, so no audio passes through
// Convex and the long-lived key never leaves the deployment.

export type DubScoreSheet = Infer<typeof dubScoreSheetV>;
type SheetLine = DubScoreSheet["lines"][number];

/** The caller's own score sheet; the query resolves ownership from the auth token, never from the request. */
export const scoreSheetRef = makeFunctionReference<"query", { clientDubId: string }, DubScoreSheet | null>("dubs:scoreSheet");

// Checked against developers.openai.com on 2026-11-15. gpt-realtime-2.1 replaces gpt-realtime, which shuts down
// on 2027-01-20; gpt-realtime-2.1-mini is the cheaper, faster option. gpt-transcribe transcribes each turn that VAD
// commits; gpt-live-transcribe doesn't support VAD, and gpt-4o-mini-transcribe shuts down on 2027-02-26.
const defaultRealtimeModel = "gpt-realtime-2.1";
const transcriptionModel = "gpt-transcribe";
const tutorVoice = "marin";
/** Only long enough for the app to open its socket; the session itself outlives the secret. */
const clientSecretTtlSeconds = 120;
/** A focused session: a handful of lines, not the whole scene. */
const maxLinesToFix = 6;
const maxWordPerfectLines = 3;
/** The Realtime API takes PCM only at 24 kHz. */
const pcmRateHz = 24_000;

export function realtimeModelId(): string {
  return process.env.OPENAI_REALTIME_MODEL || defaultRealtimeModel;
}

export class LiveTutorError extends Error {}

export type PracticeLine = {
  lineIndex: number;
  referenceText: string;
  recognizedText: string | null;
  /** What the script check found, in plain words. */
  findings: string[];
};

export type PracticePlan = {
  /** Lines whose take missed, swapped or added words, or had no speech, in scene order. */
  toFix: PracticeLine[];
  /** Lines said word for word, for polishing once the fixes are done. */
  wordPerfect: string[];
};

/** Failed takes and takes that couldn't be scored for other reasons say nothing about the learner, so they find nothing. */
function findingsFor(line: SheetLine): string[] {
  if (line.status === "unscorable" && line.reason === "no_speech") return ["said nothing that was heard in the take"];
  if (line.status !== "scored") return [];
  return line.words.flatMap((word) => {
    switch (word.textStatus) {
      case "matched":
        return [];
      case "substituted":
        return [`said "${word.recognized ?? ""}" instead of "${word.expected ?? ""}"`];
      case "omitted":
        return [`left out "${word.expected ?? ""}"`];
      case "inserted":
        return [`added "${word.recognized ?? ""}"`];
    }
  });
}

export function practicePlan(lines: readonly SheetLine[]): PracticePlan {
  const ordered = [...lines].sort((a, b) => a.lineIndex - b.lineIndex);
  const toFix = ordered.flatMap((line) => {
    const findings = findingsFor(line);
    return findings.length === 0 ? [] : [{ lineIndex: line.lineIndex, referenceText: line.referenceText, recognizedText: line.recognizedText, findings }];
  });
  const wordPerfect = ordered.filter((line) => line.status === "scored" && findingsFor(line).length === 0).map((line) => line.referenceText);
  return { toFix: toFix.slice(0, maxLinesToFix), wordPerfect: wordPerfect.slice(0, maxWordPerfectLines) };
}

export function tutorInstructions(sheet: Pick<DubScoreSheet, "sceneTitle" | "characterName" | "locale">, plan: PracticePlan): string {
  const fixes = plan.toFix.map((line, index) => {
    const heard = line.recognizedText === null ? "" : ` The transcript of their take was "${line.recognizedText}".`;
    return `${index + 1}. "${line.referenceText}": they ${line.findings.join("; ")}.${heard}`;
  });
  return [
    `You are Dubby's live pronunciation tutor. The learner just dubbed ${sheet.characterName} in the scene "${sheet.sceneTitle}", speaking ${sheet.locale}. Coach them out loud through the lines they had trouble with.`,
    "",
    "How to run the session:",
    "- Open with one short, warm sentence, then start on the first line below.",
    "- Work on one line at a time: say it slowly and clearly, ask the learner to repeat it, then listen.",
    "- After each try, give one specific correction about what you just heard, such as a sound, a stressed syllable, or a dropped or swapped word. Demonstrate it and ask them to try again. If it was right, say so briefly and move on.",
    "- Move to the next line after a good repetition or after three tries, so the learner never gets stuck.",
    "- When the list is done, polish a line they said word for word, or ask what they would like to practise.",
    "- Keep every turn to one or two short sentences. This is a spoken conversation: no lists, markdown, or emoji.",
    `- Practise in ${sheet.locale}. Switch to English only for a brief explanation when the learner is stuck or asks.`,
    "",
    "What you know and what you don't:",
    "- The findings below come from a speech-to-text check of their recorded takes. They show which words were missed, swapped or added, not how sounds were pronounced.",
    "- Pronunciation feedback must come from what you hear in this conversation. If you aren't sure what you heard, ask them to repeat instead of guessing.",
    "- Never state scores, percentages or progress numbers, and never claim to have heard their original recordings.",
    "",
    "Lines to fix, in scene order:",
    ...(fixes.length === 0 ? ["None: every scored line matched the script word for word."] : fixes),
    "",
    "Lines said word for word:",
    ...(plan.wordPerfect.length === 0 ? ["None."] : plan.wordPerfect.map((text) => `- "${text}"`)),
  ].join("\n");
}

export type LiveTutorSecret = {
  /** An ephemeral `ek_` key that can only open Realtime sessions with this configuration. */
  clientSecret: string;
  /** Seconds since the epoch. */
  expiresAt: number;
  model: string;
};

/** Mints a client secret whose session carries the tutor's instructions, voice, audio formats and turn detection. */
export async function createTutorSecret(client: OpenAI, model: string, instructions: string): Promise<LiveTutorSecret> {
  const created = await client.realtime.clientSecrets.create({
    expires_after: { anchor: "created_at", seconds: clientSecretTtlSeconds },
    session: {
      type: "realtime",
      model,
      instructions,
      output_modalities: ["audio"],
      audio: {
        input: {
          format: { type: "audio/pcm", rate: pcmRateHz },
          transcription: { model: transcriptionModel },
          // Learners pause mid-line while they work out a sound; semantic VAD waits for them to finish.
          turn_detection: { type: "semantic_vad" },
        },
        output: { format: { type: "audio/pcm", rate: pcmRateHz }, voice: tutorVoice },
      },
    },
  });
  if (created.value.length === 0) throw new LiveTutorError("OpenAI returned an empty Realtime client secret");
  return { clientSecret: created.value, expiresAt: created.expires_at, model };
}
