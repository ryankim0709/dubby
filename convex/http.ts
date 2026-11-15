import { type Auth, httpActionGeneric, httpRouter } from "convex/server";
import { ConvexError } from "convex/values";
import OpenAI from "openai";
import { z } from "zod";
import { internal } from "./_generated/api";
import { httpAction } from "./_generated/server";
import { SCHEMA_VERSION } from "./lib/config";
import { logEvent } from "./lib/log";
import { ConfigurationError } from "./lib/env";
import { TranscriptionResponseError } from "./lib/transcription";
import { registerTutoringRoutes } from "./tutoringHttp";
import { transcribePublishedScene } from "./sceneTranscription";

// The coach and tutoring routes (tutoringHttp.ts) require a signed-in caller where they spend provider credit and
// answer 401 before any provider call; /coach/characters, /scenes, and /health are public and spend nothing.

function json(status: number, body: object): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
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

const http = httpRouter();

http.route({
  path: "/health",
  method: "GET",
  handler: httpActionGeneric(async () => json(200, { ok: true, service: "dubit-backend", schemaVersion: SCHEMA_VERSION })),
});

registerTutoringRoutes(http);

// Public because the app has no sign-in yet; it exposes only what a published scene already shows.
http.route({
  path: "/scenes",
  method: "GET",
  handler: httpAction(async (ctx) => {
    const scenes = await ctx.runQuery(internal.scenes.catalog, {});
    logEvent({ operation: "scenes.catalog", status: "ok", count: scenes.length, httpStatus: 200 });
    return json(200, { scenes });
  }),
});

const transcriptionRequest = z.object({ slug: z.string().min(1).max(200), sha256: z.string().min(1).max(100), locale: z.enum(["en-US", "ko-KR", "ja-JP", "es-ES", "fr-FR", "de-DE", "zh-CN"]) });

// No uploaded audio or arbitrary URLs: the action checks publication, checksum and locale before spending credit.
http.route({
  path: "/scenes/transcribe",
  method: "POST",
  handler: httpAction(async (ctx, request) => {
    let body: z.infer<typeof transcriptionRequest>;
    try {
      body = transcriptionRequest.parse(await request.json());
    } catch (error) {
      if (error instanceof SyntaxError || error instanceof z.ZodError) return json(400, { error: "A scene slug, checksum and supported locale are required." });
      throw error;
    }
    try {
      const result = await transcribePublishedScene(ctx, body);
      return json(result.status === "ready" ? 200 : 202, result);
    } catch (error) {
      if (error instanceof ConvexError) {
        const data = z.object({ code: z.string(), message: z.string() }).parse(error.data);
        const status = data.code === "NOT_FOUND" ? 404 : data.code === "CONFLICT" ? 409 : 400;
        return json(status, { error: data.message });
      }
      if (error instanceof ConfigurationError) return json(503, { error: error.message, code: "not_configured" });
      if (error instanceof OpenAI.APIError) return json(502, { error: "OpenAI couldn't transcribe the library scene. Try again shortly.", code: "provider_failed" });
      if (error instanceof TranscriptionResponseError) return json(502, { error: error.message, code: "provider_failed" });
      throw error;
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
