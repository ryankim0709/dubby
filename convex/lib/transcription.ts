import { type Infer, v } from "convex/values";
import OpenAI from "openai";
import { z } from "zod";
import { logEvent } from "./log";

export const timedWordV = v.object({ text: v.string(), start: v.number(), end: v.number() });
export type TimedWord = Infer<typeof timedWordV>;

export const sceneTranscriptV = v.object({
  status: v.literal("ready"),
  locale: v.string(),
  durationSeconds: v.number(),
  words: v.array(timedWordV),
});
export type SceneTranscript = Infer<typeof sceneTranscriptV>;

export class TranscriptionResponseError extends Error {}

const providerTranscript = z.object({
  duration: z.number().finite().positive(),
  words: z.array(z.object({ word: z.string().trim().min(1), start: z.number().finite().nonnegative(), end: z.number().finite().nonnegative() })),
});

/** Only measured word timings can drive recording windows; plain transcript text isn't enough. */
export function timedTranscript(response: OpenAI.Audio.TranscriptionVerbose, locale: string): SceneTranscript {
  const parsed = providerTranscript.safeParse(response);
  if (!parsed.success) throw new TranscriptionResponseError("OpenAI returned a transcript without valid word timings");
  const { duration, words } = parsed.data;
  let previousStart = 0;
  for (const word of words) {
    if (word.end < word.start || word.start < previousStart || word.end > duration + 0.1) {
      throw new TranscriptionResponseError("OpenAI returned word timings outside the audio or out of order");
    }
    previousStart = word.start;
  }
  return { status: "ready", locale, durationSeconds: duration, words: words.map(({ word, start, end }) => ({ text: word, start, end })) };
}

/** Whisper is the file-transcription model that supplies the word timestamps the studio needs. */
export async function transcribeScene(client: OpenAI, file: File, locale: string): Promise<SceneTranscript> {
  return await withProviderRetries("scenes.transcribe", async () => {
    const response = await client.audio.transcriptions.create({
      model: "whisper-1",
      file,
      language: locale.split("-")[0]!,
      response_format: "verbose_json",
      timestamp_granularities: ["word"],
    }, { maxRetries: 0, timeout: 30_000 });
    return timedTranscript(response, locale);
  });
}

/** Runs one OpenAI request up to three times, retrying lost connections, 429 and 5xx with backoff. */
export async function withProviderRetries<T>(operation: string, request: () => Promise<T>): Promise<T> {
  for (let attempt = 1; attempt <= 3; attempt += 1) {
    try {
      return await request();
    } catch (error) {
      if (!(error instanceof OpenAI.APIError)) throw error;
      const retryable = error instanceof OpenAI.APIConnectionError || error.status === 429 || (error.status !== undefined && error.status >= 500);
      logEvent({ operation, status: retryable && attempt < 3 ? "retrying" : "failed", tries: attempt, httpStatus: error.status, retryable });
      if (!retryable || attempt === 3) throw error;
      await new Promise<void>((resolve) => setTimeout(resolve, 250 * 2 ** (attempt - 1)));
    }
  }
  throw new Error(`${operation} retry loop ended without a result`);
}
