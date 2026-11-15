import { httpActionGeneric, type GenericActionCtx, type GenericDataModel, type HttpRouter } from "convex/server";
import { ConvexError } from "convex/values";
import OpenAI from "openai";
import { z } from "zod";
import { coachCharacters, findCharacter, publicCharacter, type CoachCharacter } from "./coachCharacters";
import { coachModelId, coachReply, CoachReplyError, CoachTimeoutError, createCoachClient, pcmSampleRateHz, speakReply, speechModelId } from "./coachReply";
import { ConfigurationError, requiredEnv } from "./lib/env";
import { logEvent } from "./lib/log";
import { createOpenAIClient } from "./lib/openai";
import { createSessionToken, LiveAvatarError, sandboxAvatarId } from "./liveAvatar";
import { createTakeCoachSecret, createTutorSecret, LiveTutorError, practicePlan, realtimeModelId, scoreSheetRef, takeCoachInstructions, tutorInstructions } from "./liveTutor";
import { tutoringRefs } from "./tutoringRefs";
import { composeReply } from "./tutoringReply";
import { api } from "./_generated/api";

/** Development-only failures a QA run can ask for with the X-QA-Fault header; ignored unless QA_FAULTS_ENABLED is "true". */
const qaFaults = ["provider_error", "provider_timeout", "missing_key"] as const;
type QaFault = (typeof qaFaults)[number];

function requestedFault(request: Request): QaFault | undefined {
  if (process.env.QA_FAULTS_ENABLED !== "true") return undefined;
  const value = request.headers.get("X-QA-Fault");
  return qaFaults.find((fault) => fault === value);
}

// Provider keys live only in the Convex deployment's environment variables, never in the app. Every route
// except the public coach catalog needs a signed-in learner, whose identity comes from the verified auth
// token and never from the request.

const locale = z.string().min(2).max(35);

const sessionRequest = z.object({
  characterId: z.string().min(1),
  /** Two-letter code the app already sends. LITE mode needs no language, since the avatar only renders audio we send. */
  language: z.string().regex(/^[a-z]{2}$/).optional(),
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

const liveSessionRequest = z.object({ clientDubId: z.uuid() });

const takeCoachRequest = z.object({
  sceneTitle: z.string().trim().min(1).max(200),
  characterName: z.string().trim().min(1).max(200),
  locale: z.string().regex(/^[a-z]{2,3}-[A-Z]{2}$/),
});

type ActionCtx = GenericActionCtx<GenericDataModel>;

function json(status: number, body: object): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

/** One content-free line per reply, for QA and monitoring. */
function logReply(model: string, status: "ok" | "error", code: string, startedAt: number): void {
  console.log(`coach.reply provider=openai api=responses model=${model} status=${status} code=${code} latencyMs=${Date.now() - startedAt}`);
}

const errorBody = (code: string, error: string) => ({ error, code });

async function hasPremium(ctx: ActionCtx): Promise<boolean> {
  const premium = await ctx.runQuery(api.billing.status, {});
  // Convex queries are cached; expiry must also be checked at request time before spending credit.
  return premium.isPremium && (premium.expiresAt === null || premium.expiresAt > Date.now());
}

/**
 * Voices the checked reply for the avatar. The text is already valid and grounded, so a speech failure doesn't
 * discard it: the response carries `audio: null` and the failure code, and the app shows the text without a voice.
 */
async function voiceReply(client: OpenAI, character: CoachCharacter, text: string): Promise<{ audio: object; audioError?: undefined } | { audio: null; audioError: { code: string } }> {
  const started = Date.now();
  const model = speechModelId();
  const log = (status: "ok" | "error", code: string) =>
    console.log(`coach.speech provider=openai api=audio.speech model=${model} status=${status} code=${code} latencyMs=${Date.now() - started}`);
  try {
    const spoken = await speakReply(client, character, text, model);
    log("ok", "none");
    return {
      audio: { format: "pcm_s16le", sampleRateHz: pcmSampleRateHz, channels: 1, chunks: spoken.chunks, durationMs: spoken.durationMs, aiGenerated: true },
    };
  } catch (error) {
    const code = error instanceof CoachTimeoutError || error instanceof OpenAI.APIConnectionTimeoutError ? "provider_timeout" : error instanceof CoachReplyError || error instanceof OpenAI.APIError ? "provider_failed" : undefined;
    if (code === undefined) throw error;
    console.error("coach speech failed", { code });
    log("error", code);
    return { audio: null, audioError: { code } };
  }
}

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
  if (error instanceof CoachTimeoutError || error instanceof OpenAI.APIConnectionTimeoutError) {
    console.error("coach provider timed out", { operation });
    return json(504, errorBody("provider_timeout", "The coach model didn't answer in time"));
  }
  if (error instanceof LiveAvatarError || error instanceof CoachReplyError || error instanceof LiveTutorError) {
    console.error("coach provider call failed", { operation, error: error.message });
    return json(502, errorBody("provider_failed", error.message));
  }
  if (error instanceof OpenAI.APIError) {
    console.error("coach provider call failed", { operation, status: error.status, error: error.message });
    return json(502, errorBody("provider_failed", "The coach model request failed"));
  }
  throw error;
}

/** A token no configured provider accepts makes getUserIdentity throw; to a caller that is the same as no sign-in. */
async function isSignedIn(ctx: ActionCtx): Promise<boolean> {
  try {
    return (await ctx.auth.getUserIdentity()) !== null;
  } catch {
    return false;
  }
}

/** Runs the handler only for a signed-in learner; the handler never receives an identity from the client. */
function authenticated(handler: (ctx: ActionCtx, request: Request) => Promise<Response>) {
  return httpActionGeneric(async (ctx, request) => {
    if (!(await isSignedIn(ctx))) return json(401, errorBody("unauthenticated", "Sign in to use the coach"));
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
    handler: authenticated(async (ctx, request) => {
      const body = await parseBody(request, sessionRequest);
      if (body instanceof Response) return body;
      const character = findCharacter(body.characterId);
      if (character === undefined) return json(404, errorBody("not_found", `No coach named ${body.characterId}`));
      if (!(await hasPremium(ctx))) return json(403, errorBody("premium_required", "Upgrade to Dubby Premium to talk to a coach"));
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
      if (!(await hasPremium(ctx))) return json(403, errorBody("premium_required", "Upgrade to Dubby Premium to talk to a coach"));
      const started = Date.now();
      const fault = requestedFault(request);
      let model = coachModelId();
      try {
        if (fault === "missing_key") throw new ConfigurationError("The deployment env var OPENAI_API_KEY isn't set");
        if (fault === "provider_error") throw new CoachReplyError("Simulated provider error");
        if (fault === "provider_timeout") throw new CoachTimeoutError("Simulated provider timeout");
        const client = createCoachClient();
        const context = await ctx.runQuery(tutoringRefs.replyContext, body.locale === undefined ? {} : { locale: body.locale });
        const lastLearnerTurn = body.turns.findLast((turn) => turn.role === "learner")?.text ?? "";
        const memoryNotes = context.memory === "on" ? await ctx.runAction(tutoringRefs.searchMemory, { query: lastLearnerTurn }) : [];
        const pack = { ...context.pack, memoryNotes: memoryNotes.slice(0, 3) };
        const composed = await composeReply(pack, (evidence) => coachReply(client, character, body.languageName, body.turns, evidence, model));
        model = composed.model;
        logReply(model, "ok", "none", started);
        const speech = body.audio ? await voiceReply(client, character, composed.text) : undefined;
        return json(200, {
          text: composed.text,
          source: composed.source,
          ...(composed.provenance === undefined ? {} : { provenance: composed.provenance }),
          feedbackBasis: pack.basis,
          citedEvidenceIds: composed.cites,
          exercise: pack.exercise,
          ...(speech === undefined ? {} : speech),
        });
      } catch (error) {
        const failed = failure("POST /coach/reply", error);
        logReply(model, "error", (JSON.parse(await failed.clone().text()) as { code: string }).code, started);
        return failed;
      }
    }),
  });

  // The tutor works from the stored sheet of the caller's own dub; the app sends only which dub.
  http.route({
    path: "/tutor/live-session",
    method: "POST",
    handler: authenticated(async (ctx, request) => {
      const operation = "tutor.liveSession";
      const body = await parseBody(request, liveSessionRequest);
      if (body instanceof Response) return body;
      const sheet = await ctx.runQuery(scoreSheetRef, { clientDubId: body.clientDubId });
      if (sheet === null) {
        logEvent({ operation, status: "rejected", errorCode: "not_found", httpStatus: 404 });
        return json(404, errorBody("not_found", "No dub of yours has that id"));
      }
      if (sheet.status !== "complete") {
        logEvent({ operation, status: "rejected", errorCode: "still_scoring", httpStatus: 409 });
        return json(409, errorBody("still_scoring", "The dub is still being scored"));
      }
      const secret = await createTutorSecret(createOpenAIClient(), realtimeModelId(), tutorInstructions(sheet, practicePlan(sheet.lines)));
      logEvent({ operation, status: "ok", httpStatus: 200 });
      return json(200, secret);
    }),
  });

  // The studio's take coach. Scene and character names only set the persona; nothing here is graded.
  http.route({
    path: "/tutor/take-coach",
    method: "POST",
    handler: authenticated(async (_ctx, request) => {
      const body = await parseBody(request, takeCoachRequest);
      if (body instanceof Response) return body;
      const secret = await createTakeCoachSecret(createOpenAIClient(), realtimeModelId(), takeCoachInstructions(body));
      logEvent({ operation: "tutor.takeCoach", status: "ok", httpStatus: 200 });
      return json(200, secret);
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
    method: "GET",
    handler: authenticated(async (ctx) => json(200, { items: await ctx.runQuery(tutoringRefs.memoryItems, {}) })),
  });

  http.route({
    path: "/tutor/memory",
    method: "DELETE",
    handler: authenticated(async (ctx) => json(200, await ctx.runMutation(tutoringRefs.forgetMemory, {}))),
  });
}
