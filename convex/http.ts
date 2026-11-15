import { type Auth, httpActionGeneric, httpRouter } from "convex/server";
import { ConvexError } from "convex/values";
import { internal } from "./_generated/api";
import { httpAction } from "./_generated/server";
import { SCHEMA_VERSION } from "./lib/config";
import { logEvent } from "./lib/log";
import { registerTutoringRoutes } from "./tutoringHttp";

// The coach and tutoring routes (tutoringHttp.ts) require a signed-in caller where they spend provider credit and
// answer 401 before any provider call; /coach/characters and /health are public and spend nothing.

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
