import { type Auth, httpActionGeneric, httpRouter } from "convex/server";
import { ConvexError } from "convex/values";
import OpenAI from "openai";
import { z } from "zod";
import { internal } from "./_generated/api";
import { httpAction } from "./_generated/server";
import { SCHEMA_VERSION } from "./lib/config";
import { ConfigurationError, requiredEnv } from "./lib/env";
import { PASSWORD_JWKS_PATH, publicJwks } from "./lib/passwordAuth";
import { logEvent } from "./lib/log";
import { TranscriptionResponseError } from "./lib/transcription";
import { registerTutoringRoutes } from "./tutoringHttp";
import { transcribePublishedScene } from "./sceneTranscription";
import { parseWaitlistSignup } from "./waitlist";
import { paidSignupFromEvent, verifyWhopSignature } from "./whop";

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
  handler: httpActionGeneric(async () => json(200, { ok: true, service: "dubby-backend", schemaVersion: SCHEMA_VERSION })),
});

registerTutoringRoutes(http);

/** Convex fetches this to validate password session tokens (auth.config.ts). */
http.route({
  path: PASSWORD_JWKS_PATH,
  method: "GET",
  handler: httpActionGeneric(async () => {
    let privateKey: string;
    try {
      privateKey = requiredEnv("PASSWORD_AUTH_PRIVATE_KEY");
    } catch (error) {
      if (!(error instanceof ConfigurationError)) throw error;
      logEvent({ operation: "passwordAuth.jwks", status: "failed", errorCode: "not_configured", httpStatus: 503 });
      return json(503, { error: "Password sign-in isn't configured on this deployment" });
    }
    return json(200, await publicJwks(privateKey));
  }),
});

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

// The landing page is served from Vercel, a different origin, so the signup route answers CORS preflights.
// It's public on purpose: anyone may join the waitlist, and it stores only what the form sends.
const waitlistCors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
  "Access-Control-Max-Age": "86400",
};

function waitlistJson(status: number, body: object): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...waitlistCors },
  });
}

http.route({
  path: "/waitlist",
  method: "OPTIONS",
  handler: httpActionGeneric(async () => new Response(null, { status: 204, headers: waitlistCors })),
});

http.route({
  path: "/waitlist",
  method: "POST",
  handler: httpAction(async (ctx, request) => {
    const operation = "waitlist.join";
    let body: unknown;
    try {
      body = await request.json();
    } catch {
      logEvent({ operation, status: "rejected", errorCode: "invalid_json", httpStatus: 400 });
      return waitlistJson(400, { error: "Send a JSON object" });
    }
    const parsed = parseWaitlistSignup(body);
    if (parsed.kind === "invalid") {
      logEvent({ operation, status: "rejected", errorCode: "invalid_argument", httpStatus: 400 });
      return waitlistJson(400, { error: parsed.error });
    }
    if (parsed.kind === "bot") {
      logEvent({ operation, status: "skipped", errorCode: "honeypot", httpStatus: 200 });
      return waitlistJson(200, { ok: true, created: true });
    }
    const { created } = await ctx.runMutation(internal.waitlist.join, parsed.signup);
    logEvent({ operation, status: "ok", httpStatus: 200 });
    return waitlistJson(200, { ok: true, created });
  }),
});

// Whop calls this when a founding member pays on the landing page. The signature is checked before anything is read.
http.route({
  path: "/whop/webhook",
  method: "POST",
  handler: httpAction(async (ctx, request) => {
    const operation = "whop.webhook";
    const secret = process.env.WHOP_WEBHOOK_SECRET;
    if (secret === undefined || secret === "") {
      logEvent({ operation, status: "failed", errorCode: "not_configured", httpStatus: 503 });
      return json(503, { error: "Whop webhook isn't configured" });
    }
    const body = await request.text();
    const verified = await verifyWhopSignature({
      secret,
      id: request.headers.get("webhook-id"),
      timestamp: request.headers.get("webhook-timestamp"),
      signatureHeader: request.headers.get("webhook-signature"),
      body,
      nowSeconds: Math.floor(Date.now() / 1000),
    });
    if (!verified) {
      logEvent({ operation, status: "rejected", errorCode: "bad_signature", httpStatus: 401 });
      return json(401, { error: "Invalid signature" });
    }
    let event: unknown;
    try {
      event = JSON.parse(body);
    } catch {
      logEvent({ operation, status: "rejected", errorCode: "invalid_json", httpStatus: 400 });
      return json(400, { error: "Invalid JSON" });
    }
    const paid = paidSignupFromEvent(event);
    if (paid === null) {
      // Other event types, or a payment without a usable email: acknowledge so Whop doesn't retry.
      logEvent({ operation, status: "skipped", httpStatus: 200 });
      return json(200, { ok: true });
    }
    await ctx.runMutation(internal.whop.markPaid, paid);
    logEvent({ operation, status: "ok", httpStatus: 200 });
    return json(200, { ok: true });
  }),
});

const audioPath = /^\/media\/attempts\/([^/]+)\/audio$/;
http.route({
  pathPrefix: "/social/media/",
  method: "GET",
  handler: httpAction(async (ctx, request) => {
    if (!(await isSignedIn(ctx))) return unauthenticated("social.media");
    const rawId = new URL(request.url).pathname.slice("/social/media/".length);
    const asset = await ctx.runQuery(internal.social.media, { rawId });
    if (asset === null) return json(404, { error: "This video isn't shared with your account" });
    const blob = await ctx.storage.get(asset.storageId);
    if (blob === null) return json(404, { error: "The shared video is missing" });
    return new Response(blob, { headers: { "Content-Type": "video/mp4", "Cache-Control": "private, no-store" } });
  }),
});
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
