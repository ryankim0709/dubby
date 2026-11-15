import { WhopError } from "@whop/sdk";
import type { HttpRouter } from "convex/server";
import { ConvexError } from "convex/values";
import { z } from "zod";
import { api } from "./_generated/api";
import { httpAction } from "./_generated/server";
import { publishRequest, uploadRequest } from "./lib/clubs";
import { ConfigurationError } from "./lib/env";

async function clubResponse<T>(operation: () => Promise<T>): Promise<Response> {
  try { return Response.json(await operation()); }
  catch (error) {
    if (error instanceof z.ZodError || error instanceof SyntaxError) return Response.json({ error: "The club request or Whop response was invalid" }, { status: 400 });
    if (error instanceof ConfigurationError) return Response.json({ error: error.message }, { status: 503 });
    if (error instanceof WhopError) return Response.json({ error: `Whop chat failed (HTTP ${error.statusCode ?? 0}). Try again shortly.` }, { status: 502 });
    if (error instanceof ConvexError) {
      const data = z.object({ code: z.string(), message: z.string() }).parse(error.data);
      const status = data.code === "UNAUTHENTICATED" ? 401 : data.code === "NOT_FOUND" ? 404 : data.code === "CONFLICT" || data.code === "INVALID_STATE" ? 409 : 400;
      return Response.json({ error: data.message, code: data.code }, { status });
    }
    throw error;
  }
}

export function registerClubRoutes(http: HttpRouter): void {
  http.route({ path: "/clubs/feed", method: "GET", handler: httpAction(ctx => clubResponse(() => ctx.runAction(api.clubs.feed, {}))) });
  http.route({ path: "/clubs/uploads", method: "POST", handler: httpAction((ctx, request) => clubResponse(async () => ctx.runAction(api.clubs.prepareUpload, uploadRequest.parse(await request.json())))) });
  http.route({ path: "/clubs/posts", method: "POST", handler: httpAction((ctx, request) => clubResponse(async () => {
    const args = publishRequest.parse(await request.json());
    return await ctx.runAction(api.clubs.publish, args);
  })) });
}
