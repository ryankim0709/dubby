import { httpActionGeneric, type GenericActionCtx, type GenericDataModel, type HttpRouter } from "convex/server";
import { ConvexError } from "convex/values";
import OpenAI from "openai";
import { z } from "zod";
import { coachCharacters, findCharacter, publicCharacter } from "./coachCharacters";
import { coachReply, CoachReplyError, speakReply } from "./coachReply";
import { ConfigurationError, requiredEnv } from "./env";
import { createSessionToken, LiveAvatarError, sandboxAvatarId } from "./liveAvatar";
import { tutoringRefs } from "./tutoringRefs";
import { composeReply } from "./tutoringReply";

// Provider keys live only in the Convex deployment's environment variables, never in the app. Every route
// except the public coach catalog needs a signed-in learner, whose identity comes from the verified auth
// token and never from the request.

const locale = z.string().min(2).max(35);

const sessionRequest = z.object({
  characterId: z.string().min(1),
});

const replyRequest = z.object({
  characterId: z.string().min(1),
  languageName: z.string().min(1).max(40),
  /** The locale being practised, such as "es-ES"; selects which practice history the reply draws on. */
  locale: locale.optional(),
  /** Also return the reply as PCM audio for the avatar to speak. */
  audio: z.boolean().default(false),
  turns: z
    .array(z.object({ role: z.enum(["learner", "coach"]), text: z.string().min(1).max(2000) }))
    .min(1)
    .max(60)
    .refine((turns) => turns[0]?.role === "learner", "the first turn must be the learner's"),
});

const preferencesRequest = z.object({ preferences: z.unknown(), expectedVersion: z.number().int().min(0) });

type ActionCtx = GenericActionCtx<GenericDataModel>;

function json(status: number, body: object): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

const errorBody = (code: string, error: string) => ({ error, code });

async function parseBody<T>(request: Request, schema: z.ZodType<T>): Promise<T | Response> {
  let body: unknown;
  try {
    body = await request.json();
  } catch (error) {
    return json(400, errorBody("invalid_request", `The request body isn't JSON: ${String(error)}`));
  }
  const parsed = schema.safeParse(body);
  return parsed.success ? parsed.data : json(400, errorBody("invalid_request", parsed.error.message));
}

function parseLocale(request: Request): string | undefined | Response {
  const value = new URL(request.url).searchParams.get("locale");
  if (value === null) return undefined;
  const parsed = locale.safeParse(value);
  return parsed.success ? parsed.data : json(400, errorBody("invalid_request", "locale isn't a valid locale"));
}

/** Maps the failures these routes expect to HTTP responses; anything else propagates as a 500. */
function failure(operation: string, error: unknown): Response {
  if (error instanceof ConfigurationError) {
    console.error("coach backend misconfigured", { operation, error: error.message });
    return json(503, errorBody("not_configured", error.message));
  }
  if (error instanceof ConvexError) {
    const data = error.data as { code?: string; message?: string };
    if (data.code === "version_conflict") return json(409, errorBody("version_conflict", data.message ?? "stale version"));
    if (data.code === "invalid_request") return json(400, errorBody("invalid_request", data.message ?? "invalid request"));
  }
  if (error instanceof LiveAvatarError || error instanceof CoachReplyError) {
    console.error("coach provider call failed", { operation, error: error.message });
    return json(502, errorBody("provider_failed", error.message));
  }
  if (error instanceof OpenAI.APIError) {
    console.error("coach provider call failed", { operation, status: error.status, error: error.message });
    return json(502, errorBody("provider_failed", `OpenAI request failed with status ${error.status}`));
  }
  throw error;
}

/** Runs the handler only for a signed-in learner; the handler never receives an identity from the client. */
function authenticated(handler: (ctx: ActionCtx, request: Request) => Promise<Response>) {
  return httpActionGeneric(async (ctx, request) => {
    if ((await ctx.auth.getUserIdentity()) === null) return json(401, errorBody("unauthenticated", "Sign in to use the coach"));
    try {
      return await handler(ctx, request);
    } catch (error) {
      return failure(request.method + " " + new URL(request.url).pathname, error);
    }
  });
}

export function registerTutoringRoutes(http: HttpRouter): void {
  http.route({
    path: "/coach/characters",
    method: "GET",
    handler: httpActionGeneric(async () => json(200, { characters: coachCharacters.map(publicCharacter) })),
  });

  http.route({
    path: "/coach/session-token",
    method: "POST",
    handler: authenticated(async (_ctx, request) => {
      const body = await parseBody(request, sessionRequest);
      if (body instanceof Response) return body;
      const character = findCharacter(body.characterId);
      if (character === undefined) return json(404, errorBody("not_found", `No coach named ${body.characterId}`));
      const isSandbox = process.env.LIVEAVATAR_SANDBOX === "true";
      const token = await createSessionToken({
        apiKey: requiredEnv("LIVEAVATAR_API_KEY"),
        avatarId: isSandbox ? sandboxAvatarId : requiredEnv(character.avatarIdEnv),
        isSandbox,
      });
      return json(200, token);
    }),
  });

  http.route({
    path: "/coach/reply",
    method: "POST",
    handler: authenticated(async (ctx, request) => {
      const body = await parseBody(request, replyRequest);
      if (body instanceof Response) return body;
      const character = findCharacter(body.characterId);
      if (character === undefined) return json(404, errorBody("not_found", `No coach named ${body.characterId}`));
      const client = new OpenAI({ apiKey: requiredEnv("OPENAI_API_KEY") });
      const context = await ctx.runQuery(tutoringRefs.replyContext, body.locale === undefined ? {} : { locale: body.locale });
      const lastLearnerTurn = body.turns.findLast((turn) => turn.role === "learner")?.text ?? "";
      const memoryNotes = context.memory === "on" ? await ctx.runAction(tutoringRefs.searchMemory, { query: lastLearnerTurn }) : [];
      const pack = { ...context.pack, memoryNotes: memoryNotes.slice(0, 3) };
      const composed = await composeReply(pack, (evidence) => coachReply(client, character, body.languageName, body.turns, evidence));
      let audio: { format: string; base64: string; aiGenerated: true } | null = null;
      if (body.audio) {
        audio = { format: "pcm_s16le_24khz_mono", base64: await speakReply(client, character, composed.text), aiGenerated: true };
      }
      return json(200, {
        text: composed.text,
        source: composed.source,
        feedbackBasis: pack.basis === "none" ? "none" : pack.basis,
        citedEvidenceIds: composed.cites,
        exercise: pack.exercise,
        ...(audio === null ? {} : { audio }),
      });
    }),
  });

  http.route({
    path: "/tutor/progress",
    method: "GET",
    handler: authenticated(async (ctx, request) => {
      const wanted = parseLocale(request);
      if (wanted instanceof Response) return wanted;
      return json(200, await ctx.runQuery(tutoringRefs.progress, wanted === undefined ? {} : { locale: wanted }));
    }),
  });

  http.route({
    path: "/tutor/next-exercise",
    method: "GET",
    handler: authenticated(async (ctx, request) => {
      const wanted = parseLocale(request);
      if (wanted instanceof Response) return wanted;
      return json(200, { exercise: await ctx.runQuery(tutoringRefs.nextExercise, wanted === undefined ? {} : { locale: wanted }) });
    }),
  });

  http.route({
    path: "/tutor/preferences",
    method: "GET",
    handler: authenticated(async (ctx) => json(200, await ctx.runQuery(tutoringRefs.getPreferences, {}))),
  });

  http.route({
    path: "/tutor/preferences",
    method: "PUT",
    handler: authenticated(async (ctx, request) => {
      const body = await parseBody(request, preferencesRequest);
      if (body instanceof Response) return body;
      return json(200, await ctx.runMutation(tutoringRefs.setPreferences, { preferences: body.preferences, expectedVersion: body.expectedVersion }));
    }),
  });

  http.route({
    path: "/tutor/memory/status",
    method: "GET",
    handler: authenticated(async (ctx) => json(200, await ctx.runQuery(tutoringRefs.memoryStatus, {}))),
  });

  http.route({
    path: "/tutor/memory",
    method: "DELETE",
    handler: authenticated(async (ctx) => json(200, await ctx.runMutation(tutoringRefs.forgetMemory, {}))),
  });
}
