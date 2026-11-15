import Anthropic from "@anthropic-ai/sdk";
import { httpActionGeneric, httpRouter } from "convex/server";
import { z } from "zod";
import { coachCharacters, findCharacter, publicCharacter } from "./coachCharacters";
import { coachReply, CoachReplyError } from "./coachReply";
import { createSessionToken, LiveAvatarError, sandboxAvatarId } from "./liveAvatar";

// Provider keys live only in the Convex deployment's environment variables, never in the app.
// The routes have no user auth yet, so anyone with the deployment URL can spend credits; add
// Convex auth before sharing a build outside the team.

const sessionRequest = z.object({
  characterId: z.string().min(1),
  /** Two-letter code, such as "es". */
  language: z.string().regex(/^[a-z]{2}$/),
});

const replyRequest = z.object({
  characterId: z.string().min(1),
  languageName: z.string().min(1).max(40),
  turns: z
    .array(z.object({ role: z.enum(["learner", "coach"]), text: z.string().min(1).max(2000) }))
    .min(1)
    .max(60)
    .refine((turns) => turns[0]?.role === "learner", "the first turn must be the learner's"),
});

class ConfigurationError extends Error {}

function requiredEnv(name: string): string {
  const value = process.env[name];
  if (value === undefined || value.length === 0) {
    throw new ConfigurationError(`The deployment env var ${name} isn't set`);
  }
  return value;
}

function json(status: number, body: object): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

async function parseBody<T>(request: Request, schema: z.ZodType<T>): Promise<T | Response> {
  let body: unknown;
  try {
    body = await request.json();
  } catch (error) {
    return json(400, { error: `The request body isn't JSON: ${String(error)}` });
  }
  const parsed = schema.safeParse(body);
  return parsed.success ? parsed.data : json(400, { error: parsed.error.message });
}

/** Maps the failures these routes expect to HTTP responses; anything else propagates as a 500. */
function failure(operation: string, error: unknown): Response {
  if (error instanceof ConfigurationError) {
    console.error("coach backend misconfigured", { operation, error: error.message });
    return json(503, { error: error.message });
  }
  if (error instanceof LiveAvatarError || error instanceof CoachReplyError) {
    console.error("coach provider call failed", { operation, error: error.message });
    return json(502, { error: error.message });
  }
  if (error instanceof Anthropic.APIError) {
    console.error("coach provider call failed", { operation, status: error.status, error: error.message });
    return json(502, { error: `Claude request failed with status ${error.status}: ${error.message}` });
  }
  throw error;
}

const http = httpRouter();

http.route({
  path: "/coach/characters",
  method: "GET",
  handler: httpActionGeneric(async () => json(200, { characters: coachCharacters.map(publicCharacter) })),
});

http.route({
  path: "/coach/session-token",
  method: "POST",
  handler: httpActionGeneric(async (_ctx, request) => {
    const body = await parseBody(request, sessionRequest);
    if (body instanceof Response) return body;
    const character = findCharacter(body.characterId);
    if (character === undefined) return json(404, { error: `No coach named ${body.characterId}` });
    try {
      const isSandbox = process.env.LIVEAVATAR_SANDBOX === "true";
      const token = await createSessionToken({
        apiKey: requiredEnv("LIVEAVATAR_API_KEY"),
        avatarId: isSandbox ? sandboxAvatarId : requiredEnv(character.avatarIdEnv),
        voiceId: isSandbox ? process.env[character.voiceIdEnv] : requiredEnv(character.voiceIdEnv),
        language: body.language,
        isSandbox,
      });
      return json(200, token);
    } catch (error) {
      return failure("session-token", error);
    }
  }),
});

http.route({
  path: "/coach/reply",
  method: "POST",
  handler: httpActionGeneric(async (_ctx, request) => {
    const body = await parseBody(request, replyRequest);
    if (body instanceof Response) return body;
    const character = findCharacter(body.characterId);
    if (character === undefined) return json(404, { error: `No coach named ${body.characterId}` });
    try {
      const client = new Anthropic({ apiKey: requiredEnv("ANTHROPIC_API_KEY") });
      const text = await coachReply(client, character, body.languageName, body.turns);
      return json(200, { text });
    } catch (error) {
      return failure("reply", error);
    }
  }),
});

export default http;
