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
