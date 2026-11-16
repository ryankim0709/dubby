// @vitest-environment node
import { createServer, type IncomingMessage } from "node:http";
import { describe, expect, it } from "vitest";
import { prepareScenes } from "../scripts/prepare-scenes";
import { internal } from "./_generated/api";
import { fixtureManifest, newBackend } from "./test.helpers";

async function requestBody(request: IncomingMessage): Promise<Buffer> {
  const chunks: Buffer[] = [];
  for await (const chunk of request) chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
  return Buffer.concat(chunks);
}

describe("library preparation", () => {
  it("prepares every catalog entry over HTTP and reruns entirely from the Convex cache", async () => {
    const backend = newBackend();
    for (const slug of ["synthetic-fixture-scene", "second-synthetic-scene"]) {
      await backend.mutation(internal.scenes.seed, { ...fixtureManifest({}), sceneId: slug });
      const videoId = await backend.run(async (ctx) => await ctx.storage.store(new Blob([new Uint8Array(16)], { type: "video/mp4" })));
      await backend.mutation(internal.scenes.attachVideo, { slug, videoId });
      const file = await backend.run(async (ctx) => await ctx.db.system.get("_storage", videoId));
      if (file === null) throw new Error("The synthetic video must exist");
      const key = { slug, sha256: file.sha256, locale: "en-US" };
      const transcript = await backend.mutation(internal.sceneTranscription.claim, key);
      const cast = await backend.mutation(internal.sceneCasts.claim, { ...key, frameSeconds: [1] });
      if (transcript.status !== "claimed" || cast.status !== "claimed") throw new Error("New videos need fresh preparation leases");
      await backend.mutation(internal.sceneTranscription.complete, { transcriptId: transcript.transcriptId, leaseId: transcript.leaseId, durationSeconds: 10, words: [{ text: "Synthetic.", start: 1, end: 2 }] });
      await backend.mutation(internal.sceneCasts.complete, { castId: cast.castId, leaseId: cast.leaseId, characters: [{ name: "Voice", portraitSeconds: 1, faceCenterX: null }], segments: [{ start: 1, end: 2, character: 0 }] });
    }
    const paths: string[] = [];
    const server = createServer((request, response) => {
      void (async (): Promise<void> => {
        const path = request.url ?? "/";
        paths.push(path);
        const body = await requestBody(request);
        const result = await backend.fetch(path, {
          method: request.method,
          headers: { "Content-Type": "application/json" },
          ...(body.length === 0 ? {} : { body: body.toString("utf8") }),
        });
        response.writeHead(result.status, { "Content-Type": "application/json" });
        response.end(Buffer.from(await result.arrayBuffer()));
      })().catch((error: Error) => {
        response.writeHead(500);
        response.end(error.message);
      });
    });
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    try {
      const address = server.address();
      if (address === null || typeof address === "string") throw new Error("The fixture server must listen on a TCP port");
      const siteURL = new URL(`http://127.0.0.1:${address.port}`);
      expect(await prepareScenes(siteURL)).toBe(2);
      expect(await prepareScenes(siteURL)).toBe(2);
      expect(paths.filter((path) => path === "/scenes/transcribe")).toHaveLength(4);
      expect(paths.filter((path) => path === "/scenes/speakers")).toHaveLength(4);
      expect(paths.every((path) => ["/scenes", "/scenes/transcribe", "/scenes/speakers"].includes(path))).toBe(true);
      expect(await backend.run(async (ctx) => (await ctx.db.query("sceneTranscripts").collect()).length)).toBe(2);
      expect(await backend.run(async (ctx) => (await ctx.db.query("sceneCasts").collect()).length)).toBe(2);
    } finally {
      await new Promise<void>((resolve, reject) => server.close((error) => error === undefined ? resolve() : reject(error)));
    }
  });
});
