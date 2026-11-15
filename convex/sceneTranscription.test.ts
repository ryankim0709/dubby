import { describe, expect, it } from "vitest";
import { internal } from "./_generated/api";
import { timedTranscript, TranscriptionResponseError } from "./lib/transcription";
import { expectAppError, fixtureManifest, newBackend } from "./test.helpers";

async function publishedVideo() {
  const t = newBackend();
  await t.mutation(internal.scenes.seed, fixtureManifest({}));
  const videoId = await t.run(async (ctx) => await ctx.storage.store(new Blob([new Uint8Array(16)], { type: "video/mp4" })));
  await t.mutation(internal.scenes.attachVideo, { slug: "synthetic-fixture-scene", videoId });
  const file = await t.run(async (ctx) => await ctx.db.system.get("_storage", videoId));
  if (file === null) throw new Error("The fixture video wasn't stored");
  return { t, args: { slug: "synthetic-fixture-scene", sha256: file.sha256, locale: "en-US" } };
}

describe("published scene transcription", () => {
  it("shares one lease and serves measured cached words through HTTP without a provider call", async () => {
    const { t, args } = await publishedVideo();
    const claimed = await t.mutation(internal.sceneTranscription.claim, args);
    if (claimed.status !== "claimed") throw new Error("The first request must acquire the transcription lease");
    expect(await t.mutation(internal.sceneTranscription.claim, args)).toEqual({ status: "processing" });
    const words = [{ text: "Synthetic", start: 1, end: 1.5 }, { text: "dialogue.", start: 1.5, end: 2 }];
    await t.mutation(internal.sceneTranscription.complete, { transcriptId: claimed.transcriptId, leaseId: claimed.leaseId, durationSeconds: 10, words });
    const response = await t.fetch("/scenes/transcribe", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(args) });
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ status: "ready", locale: "en-US", durationSeconds: 10, words });
    expect(await t.mutation(internal.sceneTranscription.claim, args)).toEqual({ status: "ready", locale: "en-US", durationSeconds: 10, words });
  });

  it("rejects unknown scenes, changed files and incorrect languages before reserving provider work", async () => {
    const { t, args } = await publishedVideo();
    await expectAppError(t.mutation(internal.sceneTranscription.claim, { ...args, slug: "missing-scene" }), "NOT_FOUND");
    await expectAppError(t.mutation(internal.sceneTranscription.claim, { ...args, sha256: "different-file" }), "CONFLICT");
    await expectAppError(t.mutation(internal.sceneTranscription.claim, { ...args, locale: "fr-FR" }), "INVALID_ARGUMENT");
    expect(await t.run(async (ctx) => await ctx.db.query("sceneTranscripts").collect())).toEqual([]);
  });

  it("retains failed state without re-spending and recovers expired work without accepting stale completions", async () => {
    const { t, args } = await publishedVideo();
    const first = await t.mutation(internal.sceneTranscription.claim, args);
    if (first.status !== "claimed") throw new Error("The first request must acquire the lease");
    await t.mutation(internal.sceneTranscription.fail, { transcriptId: first.transcriptId, leaseId: first.leaseId });
    await expectAppError(t.mutation(internal.sceneTranscription.claim, args), "INVALID_STATE");
    await t.run(async (ctx) => await ctx.db.patch("sceneTranscripts", first.transcriptId, { leaseExpiresAt: 0 }));
    const second = await t.mutation(internal.sceneTranscription.claim, args);
    expect(second.status).toBe("claimed");
    await expectAppError(t.mutation(internal.sceneTranscription.complete, { transcriptId: first.transcriptId, leaseId: first.leaseId, durationSeconds: 10, words: [] }), "CONFLICT");
  });

  it("requires usable measured provider timings rather than accepting transcript text alone", () => {
    const response = { duration: 3, language: "english", text: "Synthetic dialogue." };
    expect(() => timedTranscript(response, "en-US")).toThrow(TranscriptionResponseError);
    expect(() => timedTranscript({ ...response, words: [{ word: "Synthetic", start: 2, end: 1 }] }, "en-US")).toThrow(TranscriptionResponseError);
    expect(timedTranscript({ ...response, words: [{ word: "Synthetic", start: 1, end: 2 }] }, "en-US").words).toEqual([{ text: "Synthetic", start: 1, end: 2 }]);
  });
});
