import { describe, expect, it } from "vitest";
import { internal } from "./_generated/api";
import { CastResponseError, type DiarizedSegment, diarizedSegments, parseCast } from "./lib/sceneCast";
import { expectAppError, fixtureManifest, newBackend } from "./test.helpers";

async function publishedVideo() {
  const t = newBackend();
  await t.mutation(internal.scenes.seed, fixtureManifest({}));
  const videoId = await t.run(async (ctx) => await ctx.storage.store(new Blob([new Uint8Array(16)], { type: "video/mp4" })));
  await t.mutation(internal.scenes.attachVideo, { slug: "synthetic-fixture-scene", videoId });
  const file = await t.run(async (ctx) => await ctx.db.system.get("_storage", videoId));
  if (file === null) throw new Error("The fixture video wasn't stored");
  return { t, key: { slug: "synthetic-fixture-scene", sha256: file.sha256, locale: "en-US" } };
}

const segments: DiarizedSegment[] = [
  { speaker: "A", start: 0.5, end: 2, text: "Synthetic line one." },
  { speaker: "B", start: 2.4, end: 4, text: "Synthetic line two." },
  { speaker: "A", start: 5, end: 6, text: "Synthetic line three." },
];
const frames = [{ seconds: 1.5, jpegBase64: "AA==" }, { seconds: 3, jpegBase64: "AA==" }];

describe("published scene cast", () => {
  it("asks for frames only when nothing is stored, shares one lease, and serves the stored cast without a provider call", async () => {
    const { t, key } = await publishedVideo();
    expect(await t.mutation(internal.sceneCasts.claim, { ...key, frameSeconds: [] })).toEqual({ status: "framesNeeded" });
    expect(await t.run(async (ctx) => await ctx.db.query("sceneCasts").collect())).toEqual([]);

    const claimed = await t.mutation(internal.sceneCasts.claim, { ...key, frameSeconds: [1.5, 3] });
    if (claimed.status !== "claimed") throw new Error("A request with frames must acquire the cast lease");
    expect(await t.mutation(internal.sceneCasts.claim, { ...key, frameSeconds: [] })).toEqual({ status: "processing" });

    const characters = [{ name: "Synthetic Hero", portraitSeconds: 1.5, faceCenterX: 0.3 }, { name: null, portraitSeconds: null, faceCenterX: null }];
    const castSegments = [{ start: 0.5, end: 2, character: 0 }, { start: 2.4, end: 4, character: 1 }];
    await t.mutation(internal.sceneCasts.complete, { castId: claimed.castId, leaseId: claimed.leaseId, characters, segments: castSegments });
    const response = await t.fetch("/scenes/speakers", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ ...key, frames: [] }) });
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ status: "ready", characters, segments: castSegments });
  });

  it("rejects unknown scenes, changed files, other languages and frames from outside the scene before reserving work", async () => {
    const { t, key } = await publishedVideo();
    await expectAppError(t.mutation(internal.sceneCasts.claim, { ...key, slug: "missing-scene", frameSeconds: [1] }), "NOT_FOUND");
    await expectAppError(t.mutation(internal.sceneCasts.claim, { ...key, sha256: "different-file", frameSeconds: [1] }), "CONFLICT");
    await expectAppError(t.mutation(internal.sceneCasts.claim, { ...key, locale: "fr-FR", frameSeconds: [1] }), "INVALID_ARGUMENT");
    await expectAppError(t.mutation(internal.sceneCasts.claim, { ...key, frameSeconds: [1, 42] }), "INVALID_ARGUMENT");
    expect(await t.run(async (ctx) => await ctx.db.query("sceneCasts").collect())).toEqual([]);
    const response = await t.fetch("/scenes/speakers", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ ...key, frames: [{ seconds: 1, jpegBase64: "not base64!" }] }) });
    expect(response.status).toBe(400);
  });

  it("holds a failed cast for the lease without re-spending and refuses a stale completion", async () => {
    const { t, key } = await publishedVideo();
    const first = await t.mutation(internal.sceneCasts.claim, { ...key, frameSeconds: [1] });
    if (first.status !== "claimed") throw new Error("The first request must acquire the lease");
    await t.mutation(internal.sceneCasts.fail, { castId: first.castId, leaseId: first.leaseId });
    await expectAppError(t.mutation(internal.sceneCasts.claim, { ...key, frameSeconds: [1] }), "INVALID_STATE");
    await t.run(async (ctx) => await ctx.db.patch("sceneCasts", first.castId, { leaseExpiresAt: 0 }));
    expect((await t.mutation(internal.sceneCasts.claim, { ...key, frameSeconds: [1] })).status).toBe("claimed");
    await expectAppError(t.mutation(internal.sceneCasts.complete, { castId: first.castId, leaseId: first.leaseId, characters: [], segments: [] }), "CONFLICT");
  });
});

describe("cast parsing", () => {
  it("keeps spoken diarized segments in time order and rejects timings outside the audio", () => {
    const response = { duration: 10, segments: [
      { speaker: "B", start: 4, end: 5, text: " Later. " },
      { speaker: "A", start: 1, end: 2, text: "Earlier." },
      { speaker: "A", start: 6, end: 7, text: " " },
    ] };
    expect(diarizedSegments(response)).toEqual([
      { speaker: "A", start: 1, end: 2, text: "Earlier." },
      { speaker: "B", start: 4, end: 5, text: "Later." },
    ]);
    expect(() => diarizedSegments({ duration: 3, segments: [{ speaker: "A", start: 1, end: 9, text: "Too long." }] })).toThrow(CastResponseError);
    expect(() => diarizedSegments({ duration: 3, text: "No segments." })).toThrow(CastResponseError);
  });

  it("gives each voice's segments to its character, numbers characters by first line, drops silent ones, and keeps a face position only with its frame", () => {
    const output = JSON.stringify({
      characters: [
        { name: "  ", portraitSeconds: 3, faceCenterX: 0.7 },
        { name: "Silent", portraitSeconds: 1.5, faceCenterX: 0.5 },
        { name: "Hero", portraitSeconds: null, faceCenterX: 0.2 },
      ],
      voices: [{ voice: "B", character: 0 }, { voice: "A", character: 2 }],
    });
    expect(parseCast(output, segments, frames)).toEqual({
      status: "ready",
      characters: [{ name: "Hero", portraitSeconds: null, faceCenterX: null }, { name: null, portraitSeconds: 3, faceCenterX: 0.7 }],
      segments: [{ start: 0.5, end: 2, character: 0 }, { start: 2.4, end: 4, character: 1 }, { start: 5, end: 6, character: 0 }],
    });
  });

  it("lets two voices share a character when diarization split one person", () => {
    const output = JSON.stringify({ characters: [{ name: "Hero", portraitSeconds: 1.5, faceCenterX: 0.4 }], voices: [{ voice: "A", character: 0 }, { voice: "B", character: 0 }] });
    expect(parseCast(output, segments, frames).segments.map((segment) => segment.character)).toEqual([0, 0, 0]);
  });

  it("rejects casts that skip or repeat a voice, invent characters, pick unseen frames, or aren't JSON", () => {
    const character = { name: null, portraitSeconds: null, faceCenterX: null };
    const both = [{ voice: "A", character: 0 }, { voice: "B", character: 0 }];
    expect(() => parseCast(JSON.stringify({ characters: [character], voices: [{ voice: "A", character: 0 }] }), segments, frames)).toThrow(CastResponseError);
    expect(() => parseCast(JSON.stringify({ characters: [character], voices: [...both, { voice: "A", character: 0 }] }), segments, frames)).toThrow(CastResponseError);
    expect(() => parseCast(JSON.stringify({ characters: [character], voices: [{ voice: "A", character: 0 }, { voice: "B", character: 1 }] }), segments, frames)).toThrow(CastResponseError);
    expect(() => parseCast(JSON.stringify({ characters: [{ ...character, portraitSeconds: 2.2 }], voices: both }), segments, frames)).toThrow(CastResponseError);
    expect(() => parseCast("Not JSON", segments, frames)).toThrow(CastResponseError);
  });
});
