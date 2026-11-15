import { describe, expect, it } from "vitest";
import { api, internal } from "./_generated/api";
import { alice, expectAppError, fixtureManifest, newBackend, seedFixture } from "./test.helpers";

const line = { id: "fixture-line-01", characterId: "fixture-a", start: 1, end: 2, text: "Fixture one.", referenceVersion: 1 };
const manifest = (lines = [line], overrides: Partial<ReturnType<typeof fixtureManifest>> = {}) =>
  fixtureManifest({ lines, ...overrides });

describe("scenes.seed", () => {
  it("is idempotent and inserts the next revision when a line is re-versioned", async () => {
    const t = newBackend();
    expect(await t.mutation(internal.scenes.seed, manifest())).toMatchObject({ linesInserted: 1, linesUnchanged: 0 });
    expect(await t.mutation(internal.scenes.seed, manifest())).toMatchObject({ linesInserted: 0, linesUnchanged: 1 });
    expect(await t.mutation(internal.scenes.seed, manifest([{ ...line, end: 2.5, referenceVersion: 2 }]))).toMatchObject({ linesInserted: 1 });

    const rows = await t.run(async (ctx) => await ctx.db.query("referenceLines").collect());
    expect(rows.map((r) => [r.lineKey, r.referenceVersion, r.endSeconds])).toEqual([
      ["fixture-line-01", 1, 2],
      ["fixture-line-01", 2, 2.5],
    ]);
    const scenes = await t.withIdentity(alice).query(api.scenes.list, {});
    expect(scenes).toMatchObject([{ slug: "synthetic-fixture-scene", synopsis: expect.any(String), characters: [{ slug: "fixture-a" }, { slug: "fixture-b" }] }]);
    const detail = await t.withIdentity(alice).query(api.scenes.get, { sceneId: scenes[0]!.sceneId });
    expect(detail?.lines).toMatchObject([{ lineKey: "fixture-line-01", referenceVersion: 2, endSeconds: 2.5 }]);
    expect(detail?.provenance).toMatchObject({ work: "synthetic test fixture" });
  });

  it("rejects a changed line that keeps its referenceVersion, or lowers it", async () => {
    const t = newBackend();
    await t.mutation(internal.scenes.seed, manifest([{ ...line, referenceVersion: 2 }]));
    await expectAppError(t.mutation(internal.scenes.seed, manifest([{ ...line, text: "Changed.", referenceVersion: 2 }])), "INVALID_ARGUMENT");
    await expectAppError(t.mutation(internal.scenes.seed, manifest([{ ...line, referenceVersion: 1 }])), "INVALID_ARGUMENT");
  });

  it("rejects bad timestamps, unknown characters, overlaps, duplicates, and unsorted lines", async () => {
    const t = newBackend();
    const seed = (lines: (typeof line)[]) => t.mutation(internal.scenes.seed, manifest(lines));
    await expectAppError(seed([{ ...line, start: 2, end: 2 }]), "INVALID_ARGUMENT");
    await expectAppError(seed([{ ...line, start: -1 }]), "INVALID_ARGUMENT");
    await expectAppError(seed([{ ...line, end: 10.5 }]), "INVALID_ARGUMENT");
    await expectAppError(seed([{ ...line, end: Number.NaN }]), "INVALID_ARGUMENT");
    await expectAppError(seed([{ ...line, characterId: "ghost" }]), "INVALID_ARGUMENT");
    await expectAppError(seed([line, { ...line, id: "fixture-line-02", start: 1.5, end: 3 }]), "INVALID_ARGUMENT");
    await expectAppError(seed([line, { ...line, start: 3, end: 4 }]), "INVALID_ARGUMENT");
    await expectAppError(seed([{ ...line, id: "b", start: 5, end: 6 }, { ...line, id: "a", start: 1, end: 2 }]), "INVALID_ARGUMENT");
    await expectAppError(seed([{ ...line, text: "  " }]), "INVALID_ARGUMENT");
    await expectAppError(seed([{ ...line, referenceVersion: 0 }]), "INVALID_ARGUMENT");
    expect(await t.run(async (ctx) => (await ctx.db.query("scenes").collect()).length)).toBe(0);
  });

  it("allows lines of different characters to overlap", async () => {
    const t = newBackend();
    const other = { ...line, id: "fixture-line-02", characterId: "fixture-b", start: 1.5, end: 3 };
    expect(await t.mutation(internal.scenes.seed, manifest([line, other]))).toMatchObject({ linesInserted: 2 });
  });

  it("keeps unpublished scenes out of the catalog and needs a signed-in reader", async () => {
    const t = newBackend();
    const { sceneId } = await t.mutation(internal.scenes.seed, manifest([line], { published: false, sceneId: "synthetic-unpublished-scene" }));
    expect(await t.withIdentity(alice).query(api.scenes.list, {})).toEqual([]);
    expect(await t.withIdentity(alice).query(api.scenes.get, { sceneId })).toBeNull();
    await expectAppError(t.query(api.scenes.list, {}), "UNAUTHENTICATED");
    await seedFixture(t);
    expect(await t.withIdentity(alice).query(api.scenes.list, {})).toHaveLength(1);
  });
});

describe("scenes.attachVideo", () => {
  it("serves the attached video, keeps it across re-seeds, and deletes the one it replaces", async () => {
    const t = newBackend();
    const store = (type: string) => t.run(async (ctx) => await ctx.storage.store(new Blob([new Uint8Array(16)], { type })));
    const { sceneId } = await t.mutation(internal.scenes.seed, manifest());
    const first = await store("video/mp4");
    await t.mutation(internal.scenes.attachVideo, { slug: "synthetic-fixture-scene", videoId: first });
    await t.mutation(internal.scenes.seed, manifest());
    expect((await t.withIdentity(alice).query(api.scenes.get, { sceneId }))?.videoUrl).toEqual(expect.any(String));

    await expectAppError(t.mutation(internal.scenes.attachVideo, { slug: "synthetic-fixture-scene", videoId: await store("text/plain") }), "INVALID_UPLOAD");
    await expectAppError(t.mutation(internal.scenes.attachVideo, { slug: "missing-scene", videoId: first }), "NOT_FOUND");

    const second = await store("video/mp4");
    await t.mutation(internal.scenes.attachVideo, { slug: "synthetic-fixture-scene", videoId: second });
    expect(await t.run(async (ctx) => [await ctx.storage.getUrl(first), (await ctx.db.get("scenes", sceneId))?.videoId])).toEqual([null, second]);
  });
});

describe("GET /scenes", () => {
  it("lists only published scenes that have a video, without sign-in", async () => {
    const t = newBackend();
    const video = () => t.run(async (ctx) => await ctx.storage.store(new Blob([new Uint8Array(16)], { type: "video/mp4" })));
    await t.mutation(internal.scenes.seed, manifest());
    await t.mutation(internal.scenes.seed, manifest([line], { sceneId: "synthetic-hidden-scene", published: false }));
    await t.mutation(internal.scenes.seed, manifest([line], { sceneId: "synthetic-silent-scene" }));
    await t.mutation(internal.scenes.attachVideo, { slug: "synthetic-fixture-scene", videoId: await video() });
    await t.mutation(internal.scenes.attachVideo, { slug: "synthetic-hidden-scene", videoId: await video() });

    const response = await t.fetch("/scenes", { method: "GET" });
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      scenes: [
        {
          slug: "synthetic-fixture-scene",
          title: "SYNTHETIC TEST FIXTURE scene",
          durationSeconds: 10,
          details: {
            locale: "en-US",
            synopsis: "A synthetic scene used only by tests.",
            characters: [
              { id: "fixture-a", name: "Fixture Character A", lineCount: 1 },
              { id: "fixture-b", name: "Fixture Character B", lineCount: 0 },
            ],
          },
          video: { url: expect.any(String), sha256: expect.any(String), byteSize: 16, contentType: "video/mp4" },
        },
      ],
    });
  });
});
