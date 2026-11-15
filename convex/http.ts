import Anthropic from "@anthropic-ai/sdk";
import { type Auth, httpActionGeneric, httpRouter } from "convex/server";
import { ConvexError } from "convex/values";
import { z } from "zod";
import { internal } from "./_generated/api";
import { httpAction } from "./_generated/server";
import { SCHEMA_VERSION } from "./lib/config";
import { ConfigurationError, requiredEnv } from "./lib/env";
import { logEvent } from "./lib/log";
import { describeOpenAIFailure } from "./lib/openai";
import { coachCharacters, findCharacter, publicCharacter } from "./coachCharacters";
import { coachReply, CoachReplyError } from "./coachReply";
import { createSessionToken, LiveAvatarError, sandboxAvatarId } from "./liveAvatar";

// Provider keys live only in the Convex deployment's environment variables, never in the app.
// The two routes that spend provider credit require a signed-in caller and answer 401 before any
// provider call; /coach/characters and /health are public and spend nothing.

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

/** A token no configured provider accepts makes getUserIdentity throw; to a caller that is the same as no sign-in. */
async function isSignedIn(ctx: { auth: Auth }): Promise<boolean> {
  try {
    return (await ctx.auth.getUserIdentity()) !== null;
  } catch {
    return false;
  }
}

function unauthenticated(operation: string): Response {
  logEvent({ operation, status: "rejected", errorCode: "unauthenticated", httpStatus: 401 });
  return json(401, { error: "Sign in to continue" });
}

/** Maps the failures these routes expect to HTTP responses; anything else propagates as a 500. */
function failure(operation: string, error: unknown): Response {
  if (error instanceof ConfigurationError) {
    logEvent({ operation, status: "failed", errorCode: "not_configured", httpStatus: 503 });
    return json(503, { error: error.message });
  }
  if (error instanceof LiveAvatarError || error instanceof CoachReplyError) {
    logEvent({ operation, status: "failed", errorCode: "provider_failed", httpStatus: 502 });
    return json(502, { error: error.message });
  }
  const openAIFailure = describeOpenAIFailure(error);
  if (openAIFailure !== null) {
    logEvent({ operation, status: "failed", errorCode: "provider_failed", httpStatus: 502 });
    return json(502, { error: openAIFailure.message });
  }
  if (error instanceof Anthropic.APIError) {
    logEvent({ operation, status: "failed", errorCode: "provider_failed", httpStatus: 502 });
    return json(502, { error: `Claude request failed with status ${error.status}: ${error.message}` });
  }
  throw error;
}

const http = httpRouter();

http.route({
  path: "/health",
  method: "GET",
  handler: httpActionGeneric(async () => json(200, { ok: true, service: "dubit-backend", schemaVersion: SCHEMA_VERSION })),
});

http.route({
  path: "/coach/characters",
  method: "GET",
  handler: httpActionGeneric(async () => json(200, { characters: coachCharacters.map(publicCharacter) })),
});

http.route({
  path: "/coach/session-token",
  method: "POST",
  handler: httpActionGeneric(async (ctx, request) => {
    if (!(await isSignedIn(ctx))) return unauthenticated("coach.session-token");
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
      return failure("coach.session-token", error);
    }
  }),
});

http.route({
  path: "/coach/reply",
  method: "POST",
  handler: httpActionGeneric(async (ctx, request) => {
    if (!(await isSignedIn(ctx))) return unauthenticated("coach.reply");
    const body = await parseBody(request, replyRequest);
    if (body instanceof Response) return body;
    const character = findCharacter(body.characterId);
    if (character === undefined) return json(404, { error: `No coach named ${body.characterId}` });
    try {
      const client = new Anthropic({ apiKey: requiredEnv("ANTHROPIC_API_KEY") });
      const text = await coachReply(client, character, body.languageName, body.turns);
      return json(200, { text });
    } catch (error) {
      return failure("coach.reply", error);
    }
  }),
});

const audioPath = /^\/media\/attempts\/([^/]+)\/audio$/;
const rangeHeader = /^bytes=(\d*)-(\d*)$/;

/** Streams a recording to its owner. Range requests are supported so AVPlayer can seek. */
http.route({
  pathPrefix: "/media/attempts/",
  method: "GET",
  handler: httpAction(async (ctx, request) => {
    const operation = "media.attempt-audio";
    const match = audioPath.exec(new URL(request.url).pathname);
    if (match === null) return json(404, { error: "Not found" });
    if (!(await isSignedIn(ctx))) return unauthenticated(operation);

    let file;
    try {
      file = await ctx.runQuery(internal.media.attemptAudio, { rawAttemptId: match[1] });
    } catch (error) {
      if (error instanceof ConvexError && (error.data as { code?: string }).code === "USER_NOT_FOUND") file = null;
      else throw error;
    }
    const blob = file === null ? null : await ctx.storage.get(file.storageId);
    if (file === null || blob === null) {
      logEvent({ operation, status: "rejected", errorCode: "not_found", httpStatus: 404 });
      return json(404, { error: "Not found" });
    }

    const headers: Record<string, string> = {
      "Content-Type": file.contentType,
      "Accept-Ranges": "bytes",
      "Cache-Control": "private, no-store",
    };
    const requested = rangeHeader.exec(request.headers.get("Range") ?? "");
    if (requested === null) {
      logEvent({ operation, status: "ok", httpStatus: 200 });
      return new Response(blob, { status: 200, headers });
    }
    const size = blob.size;
    const [, first, last] = requested;
    const start = first === "" ? Math.max(size - Number(last), 0) : Number(first);
    const end = first === "" || last === "" ? size - 1 : Math.min(Number(last), size - 1);
    if ((first === "" && last === "") || start >= size || start > end) {
      logEvent({ operation, status: "rejected", errorCode: "range_not_satisfiable", httpStatus: 416 });
      return new Response(null, { status: 416, headers: { ...headers, "Content-Range": `bytes */${size}` } });
    }
    logEvent({ operation, status: "ok", httpStatus: 206 });
    return new Response(blob.slice(start, end + 1), {
      status: 206,
      headers: { ...headers, "Content-Range": `bytes ${start}-${end}/${size}` },
    });
  }),
});

export default http;
