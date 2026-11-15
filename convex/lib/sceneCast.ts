import { type Infer, v } from "convex/values";
import type OpenAI from "openai";
import { z } from "zod";
import { withProviderRetries } from "./transcription";
import { nullable } from "./validators";

export const castCharacterV = v.object({ name: nullable(v.string()), portraitSeconds: nullable(v.number()), faceCenterX: nullable(v.number()) });
export const castSegmentV = v.object({ start: v.number(), end: v.number(), character: v.number() });
export const sceneCastV = v.object({
  status: v.literal("ready"),
  characters: v.array(castCharacterV),
  segments: v.array(castSegmentV),
});
export type SceneCast = Infer<typeof sceneCastV>;

/** A still the app sampled from the published video, at `seconds` from its start. */
export type CastFrame = { seconds: number; jpegBase64: string };
export type DiarizedSegment = { speaker: string; start: number; end: number; text: string };

export class CastResponseError extends Error {}

// Checked against developers.openai.com on 2026-11-15. gpt-4o-transcribe-diarize is the only OpenAI model that labels
// speakers, and it shuts down on 2027-02-26 with no named successor. gpt-6-luna takes image input and structured outputs.
const diarizeModel = "gpt-4o-transcribe-diarize";
const castModel = "gpt-6-luna";

const providerDiarization = z.object({
  duration: z.number().finite().positive(),
  segments: z.array(z.object({
    speaker: z.string().min(1),
    start: z.number().finite().nonnegative(),
    end: z.number().finite().nonnegative(),
    text: z.string(),
  })),
});

/** The segments that hold words, in time order. Without them there is nobody to cast. */
export function diarizedSegments(response: unknown): DiarizedSegment[] {
  const parsed = providerDiarization.safeParse(response);
  if (!parsed.success) throw new CastResponseError("OpenAI returned a diarized transcript without speaker segments");
  const { duration, segments } = parsed.data;
  if (segments.some((segment) => segment.end < segment.start || segment.end > duration + 0.1)) {
    throw new CastResponseError("OpenAI returned speaker segments outside the audio");
  }
  const spoken = segments.filter((segment) => segment.text.trim().length > 0).sort((a, b) => a.start - b.start);
  if (spoken.length === 0) throw new CastResponseError("OpenAI found no speech in the scene");
  return spoken.map(({ speaker, start, end, text }) => ({ speaker, start, end, text: text.trim() }));
}

/** Who speaks when, judged by voice alone. Diarization labels speakers A, B, … and knows no names. */
export async function diarizeScene(client: OpenAI, file: File, locale: string): Promise<DiarizedSegment[]> {
  return await withProviderRetries("scenes.diarize", async () => {
    const response = await client.audio.transcriptions.create({
      model: diarizeModel,
      file,
      language: locale.split("-")[0]!,
      response_format: "diarized_json",
      // Required for audio longer than 30 seconds.
      chunking_strategy: "auto",
    }, { maxRetries: 0, timeout: 90_000 });
    return diarizedSegments(response);
  });
}

// The model maps whole voices, not single segments: on a live scene, diarization labelled every segment
// correctly, and letting the model reassign segments one by one only introduced mistakes.
const castInstructions = [
  "You identify the characters in a short film scene for a dubbing app, where a learner picks a character to dub.",
  "You get the scene title, its transcript as segments with times and a voice label from automatic speaker diarization, and frames sampled across the scene with their times.",
  "Each voice label is one person's voice. Map every voice label to the character it belongs to. Map two labels to the same character only when diarization clearly split one person's voice in two.",
  "List each character in the order they first speak.",
  "Name a character only when the scene title or the dialogue makes it clear, and only as they write or say it, adding nothing from outside the scene; otherwise use null. A line that addresses someone by name is spoken by someone else, and people rarely say their own name. Never identify real people or actors from their faces.",
  "For each character, pick the frame that shows their face most clearly and largest, preferably while they speak: the speaker is usually on screen, facing the camera, mouth open. Give its time exactly as labelled, and the horizontal centre of their face as a fraction of the frame width, from 0 at the left edge to 1 at the right. Use null for both when no frame clearly shows them.",
].join("\n");

const castSchema = {
  type: "object",
  properties: {
    characters: {
      type: "array",
      items: {
        type: "object",
        properties: {
          name: { type: ["string", "null"] },
          portraitSeconds: { type: ["number", "null"] },
          faceCenterX: { type: ["number", "null"] },
        },
        required: ["name", "portraitSeconds", "faceCenterX"],
        additionalProperties: false,
      },
    },
    voices: {
      type: "array",
      items: {
        type: "object",
        properties: { voice: { type: "string" }, character: { type: "integer" } },
        required: ["voice", "character"],
        additionalProperties: false,
      },
    },
  },
  required: ["characters", "voices"],
  additionalProperties: false,
} as const;

/** The transcript as text, then each frame after a label with its time, so the model can line them up. */
export function castInput(title: string, segments: readonly DiarizedSegment[], frames: readonly CastFrame[]): OpenAI.Responses.ResponseInput {
  const transcript = segments
    .map((segment) => `${segment.start.toFixed(1)}–${segment.end.toFixed(1)} s [voice ${segment.speaker}] ${segment.text}`)
    .join("\n");
  const voices = [...new Set(segments.map((segment) => segment.speaker))].join(", ");
  const content: OpenAI.Responses.ResponseInputMessageContentList = [
    { type: "input_text", text: `Scene title: ${title}\n\nVoice labels: ${voices}\n\nTranscript segments:\n${transcript}\n\nFrames:` },
    ...frames.flatMap((frame): OpenAI.Responses.ResponseInputMessageContentList => [
      { type: "input_text", text: `Frame at ${frame.seconds.toFixed(2)} s` },
      { type: "input_image", detail: "low", image_url: `data:image/jpeg;base64,${frame.jpegBase64}` },
    ]),
  ];
  return [{ role: "user", content }];
}

const modelCast = z.object({
  characters: z.array(z.object({
    name: z.string().trim().max(60).nullable(),
    portraitSeconds: z.number().finite().nullable(),
    faceCenterX: z.number().min(0).max(1).nullable(),
  })).min(1).max(8),
  voices: z.array(z.object({ voice: z.string(), character: z.number().int().nonnegative() })),
});

/**
 * Checks the model's cast against the segments and frames it was given. Characters are renumbered by
 * when they first speak, and any it listed without a voice are dropped: the app casts only speakers.
 */
export function parseCast(outputText: string, segments: readonly DiarizedSegment[], frames: readonly CastFrame[]): SceneCast {
  let json: unknown;
  try {
    json = JSON.parse(outputText);
  } catch {
    throw new CastResponseError("The cast model returned text that isn't JSON");
  }
  const parsed = modelCast.safeParse(json);
  if (!parsed.success) throw new CastResponseError("The cast model returned JSON in the wrong shape");
  const { characters, voices } = parsed.data;
  const labels = new Set(segments.map((segment) => segment.speaker));
  const voiceCharacters = new Map(voices.map(({ voice, character }) => [voice, character]));
  if (voices.length !== labels.size || voiceCharacters.size !== labels.size || [...labels].some((label) => !voiceCharacters.has(label))) {
    throw new CastResponseError("The cast model didn't map every voice exactly once");
  }
  if (voices.some(({ character }) => character >= characters.length)) throw new CastResponseError("The cast model mapped a voice to a character it didn't list");
  const segmentCharacters = segments.map((segment) => voiceCharacters.get(segment.speaker)!);
  const order = [...new Set(segmentCharacters)];
  return {
    status: "ready",
    characters: order.map((index) => {
      const { name, portraitSeconds, faceCenterX } = characters[index]!;
      if (portraitSeconds !== null && !frames.some((frame) => Math.abs(frame.seconds - portraitSeconds) < 0.06)) {
        throw new CastResponseError("The cast model picked a frame time it wasn't shown");
      }
      return {
        name: name === null || name.length === 0 ? null : name,
        portraitSeconds,
        faceCenterX: portraitSeconds === null ? null : faceCenterX,
      };
    }),
    segments: segments.map((segment, index) => ({ start: segment.start, end: segment.end, character: order.indexOf(segmentCharacters[index]!) })),
  };
}

/** Maps diarized voices to characters, names them, and picks a frame of each from what the frames and dialogue show. */
export async function castScene(client: OpenAI, title: string, segments: readonly DiarizedSegment[], frames: readonly CastFrame[]): Promise<SceneCast> {
  return await withProviderRetries("scenes.cast", async () => {
    const response = await client.responses.create({
      model: castModel,
      instructions: castInstructions,
      input: castInput(title, segments, frames),
      // Reasoning and the answer share this budget; the answer itself is a few hundred tokens.
      max_output_tokens: 8_000,
      store: false,
      reasoning: { effort: "low" },
      text: { format: { type: "json_schema", name: "scene_cast", strict: true, schema: castSchema } },
    }, { maxRetries: 0, timeout: 90_000 });
    return parseCast(response.output_text, segments, frames);
  });
}
