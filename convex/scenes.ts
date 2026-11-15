import { v } from "convex/values";
import type { Doc } from "./_generated/dataModel";
import { internalMutation, internalQuery, query } from "./_generated/server";
import { requireLearner } from "./lib/auth";
import { lineView } from "./lib/catalog";
import { appError } from "./lib/errors";
import { logEvent } from "./lib/log";
import { nullable } from "./lib/validators";

const lineViewV = v.object({
  lineId: v.id("referenceLines"),
  lineKey: v.string(),
  characterId: v.id("characters"),
  order: v.number(),
  text: v.string(),
  startSeconds: v.number(),
  endSeconds: v.number(),
  locale: v.string(),
  referenceVersion: v.number(),
});

const characterViewV = v.object({ characterId: v.id("characters"), slug: v.string(), name: v.string() });

const sceneSummaryV = v.object({
  sceneId: v.id("scenes"),
  slug: v.string(),
  title: v.string(),
  synopsis: nullable(v.string()),
  locale: v.string(),
  durationSeconds: v.number(),
  characters: v.array(characterViewV),
});

function summary(scene: Doc<"scenes">, characters: Doc<"characters">[]) {
  return {
    sceneId: scene._id,
    slug: scene.slug,
    title: scene.title,
    synopsis: scene.synopsis ?? null,
    locale: scene.locale,
    durationSeconds: scene.durationSeconds,
    characters: characters.map((c) => ({ characterId: c._id, slug: c.slug, name: c.name })),
  };
}

export const list = query({
  args: {},
  returns: v.array(sceneSummaryV),
  handler: async (ctx) => {
    await requireLearner(ctx);
    const scenes = await ctx.db
      .query("scenes")
      .withIndex("by_published", (q) => q.eq("published", true))
      .collect();
    return await Promise.all(
      scenes.map(async (scene) => {
        const characters = await ctx.db
          .query("characters")
          .withIndex("by_scene", (q) => q.eq("sceneId", scene._id))
          .collect();
        return summary(scene, characters);
      }),
    );
  },
});

/** A published scene with its characters, the newest revision of each line, and a URL for its stored video. */
export const get = query({
  args: { sceneId: v.id("scenes") },
  returns: nullable(
    v.object({ ...sceneSummaryV.fields, provenance: v.any(), videoUrl: nullable(v.string()), lines: v.array(lineViewV) }),
  ),
  handler: async (ctx, { sceneId }) => {
    await requireLearner(ctx);
    const scene = await ctx.db.get("scenes", sceneId);
    if (scene === null || !scene.published) return null;
    const characters = await ctx.db
      .query("characters")
      .withIndex("by_scene", (q) => q.eq("sceneId", scene._id))
      .collect();
    const newest = new Map<string, Doc<"referenceLines">>();
    for (const character of characters) {
      const rows = await ctx.db.query("referenceLines").withIndex("by_character", (q) => q.eq("characterId", character._id)).collect();
      for (const row of rows) {
        const current = newest.get(row.lineKey);
        if (current === undefined || row.referenceVersion > current.referenceVersion) newest.set(row.lineKey, row);
      }
    }
    return {
      ...summary(scene, characters),
      provenance: scene.provenance,
      videoUrl: scene.videoId === undefined ? null : await ctx.storage.getUrl(scene.videoId),
      lines: [...newest.values()].sort((a, b) => a.startSeconds - b.startSeconds || a.order - b.order).map(lineView),
    };
  },
});

const manifestProvenanceV = v.object({
  work: v.string(),
  creator: v.string(),
  sourceURL: v.optional(v.string()),
  sourceSHA256: v.optional(v.string()),
  license: v.string(),
  licenseURL: v.optional(v.string()),
  attribution: v.string(),
  excerpt: v.optional(v.object({ start: v.number(), end: v.number() })),
  modifications: v.optional(v.array(v.string())),
  dialogueSeparation: v.optional(v.object({ method: v.string(), tool: v.string(), notes: v.optional(v.string()) })),
  transcriptSource: v.optional(v.string()),
  wordTimingSource: v.optional(v.string()),
});

/**
 * Loads or updates one catalog scene from a Scene Manifest v1 (the manifest fields the backend
 * needs, plus `published`). Media file entries and word timings are ignored: the files ship inside
 * the app. Running it again with the same manifest changes nothing; a line whose text or timing
 * changed must carry a higher referenceVersion, which inserts a new row so recorded attempts keep
 * their exact reference.
 */
export const seed = internalMutation({
  args: {
    schemaVersion: v.literal(1),
    sceneId: v.string(),
    title: v.string(),
    synopsis: v.optional(v.string()),
    locale: v.string(),
    durationSeconds: v.number(),
    published: v.boolean(),
    provenance: manifestProvenanceV,
    characters: v.array(v.object({ id: v.string(), displayName: v.string(), description: v.optional(v.string()) })),
    lines: v.array(
      v.object({
        id: v.string(),
        characterId: v.string(),
        start: v.number(),
        end: v.number(),
        text: v.string(),
        referenceVersion: v.number(),
      }),
    ),
  },
  returns: v.object({ sceneId: v.id("scenes"), linesInserted: v.number(), linesUnchanged: v.number() }),
  handler: async (ctx, manifest) => {
    const invalid = (message: string) => appError("INVALID_ARGUMENT", message);
    if (manifest.sceneId.trim() === "" || manifest.title.trim() === "") throw invalid("sceneId and title are required");
    if (!Number.isFinite(manifest.durationSeconds) || manifest.durationSeconds <= 0) throw invalid("durationSeconds must be positive");
    const characterIds = new Set(manifest.characters.map((c) => c.id));
    if (characterIds.size !== manifest.characters.length) throw invalid("character ids must be unique");

    const lineIds = new Set<string>();
    let previousStart = -Infinity;
    for (const line of manifest.lines) {
      if (!characterIds.has(line.characterId)) throw invalid(`line ${line.id} references an unknown character`);
      if (lineIds.has(line.id)) throw invalid(`duplicate line id ${line.id}`);
      lineIds.add(line.id);
      if (line.text.trim() === "") throw invalid(`line ${line.id} has no text`);
      if (!Number.isInteger(line.referenceVersion) || line.referenceVersion < 1) throw invalid(`line ${line.id} needs a positive integer referenceVersion`);
      if (!Number.isFinite(line.start) || !Number.isFinite(line.end) || !(line.start >= 0 && line.start < line.end && line.end <= manifest.durationSeconds)) {
        throw invalid(`line ${line.id} must satisfy 0 <= start < end <= durationSeconds`);
      }
      if (line.start < previousStart) throw invalid("lines must be sorted by start");
      previousStart = line.start;
    }
    for (const character of manifest.characters) {
      const own = manifest.lines.filter((line) => line.characterId === character.id);
      for (let i = 1; i < own.length; i += 1) {
        if (own[i]!.start < own[i - 1]!.end) throw invalid(`lines of ${character.id} overlap`);
      }
    }

    const sceneFields = {
      title: manifest.title,
      ...(manifest.synopsis === undefined ? {} : { synopsis: manifest.synopsis }),
      locale: manifest.locale,
      durationSeconds: manifest.durationSeconds,
      published: manifest.published,
      provenance: manifest.provenance,
    };
    const existingScene = await ctx.db.query("scenes").withIndex("by_slug", (q) => q.eq("slug", manifest.sceneId)).unique();
    let sceneId;
    if (existingScene === null) {
      sceneId = await ctx.db.insert("scenes", { slug: manifest.sceneId, ...sceneFields });
    } else {
      sceneId = existingScene._id;
      // The manifest doesn't carry the uploaded video, so re-seeding must keep it.
      const video = existingScene.videoId === undefined ? {} : { videoId: existingScene.videoId };
      await ctx.db.replace(sceneId, { slug: manifest.sceneId, ...sceneFields, ...video });
    }

    const characterDocIds = new Map<string, Doc<"characters">["_id"]>();
    for (const character of manifest.characters) {
      const existing = await ctx.db
        .query("characters")
        .withIndex("by_scene_slug", (q) => q.eq("sceneId", sceneId).eq("slug", character.id))
        .unique();
      if (existing === null) {
        characterDocIds.set(character.id, await ctx.db.insert("characters", { sceneId, slug: character.id, name: character.displayName }));
        continue;
      }
      if (existing.name !== character.displayName) await ctx.db.patch(existing._id, { name: character.displayName });
      characterDocIds.set(character.id, existing._id);
    }

    let linesInserted = 0;
    let linesUnchanged = 0;
    for (const [index, line] of manifest.lines.entries()) {
      const characterId = characterDocIds.get(line.characterId)!;
      const newest = await ctx.db
        .query("referenceLines")
        .withIndex("by_scene_line_key", (q) => q.eq("sceneId", sceneId).eq("lineKey", line.id))
        .order("desc")
        .first();
      if (newest !== null && newest.characterId !== characterId) throw invalid(`line ${line.id} cannot move to another character`);
      if (newest !== null && line.referenceVersion < newest.referenceVersion) throw invalid(`line ${line.id} has an older referenceVersion than the stored one`);
      const sameContent =
        newest !== null &&
        newest.text === line.text &&
        newest.startSeconds === line.start &&
        newest.endSeconds === line.end &&
        newest.order === index &&
        newest.locale === manifest.locale;
      if (newest !== null && line.referenceVersion === newest.referenceVersion) {
        if (!sameContent) throw invalid(`line ${line.id} changed without a higher referenceVersion`);
        linesUnchanged += 1;
        continue;
      }
      await ctx.db.insert("referenceLines", {
        sceneId,
        characterId,
        lineKey: line.id,
        order: index,
        text: line.text,
        startSeconds: line.start,
        endSeconds: line.end,
        locale: manifest.locale,
        referenceVersion: line.referenceVersion,
      });
      linesInserted += 1;
    }
    logEvent({ operation: "scenes.seed", status: "ok", count: linesInserted });
    return { sceneId, linesInserted, linesUnchanged };
  },
});

/** A short-lived URL to POST a scene video to; the response body is `{ "storageId": ... }`. Internal, like `seed`. */
export const generateVideoUploadUrl = internalMutation({
  args: {},
  returns: v.string(),
  handler: async (ctx) => await ctx.storage.generateUploadUrl(),
});

/** Points a seeded scene at an uploaded video and deletes the video it replaces, so storage holds no orphans. */
export const attachVideo = internalMutation({
  args: { slug: v.string(), videoId: v.id("_storage") },
  returns: v.id("scenes"),
  handler: async (ctx, { slug, videoId }) => {
    const scene = await ctx.db.query("scenes").withIndex("by_slug", (q) => q.eq("slug", slug)).unique();
    if (scene === null) throw appError("NOT_FOUND", `no scene has slug ${slug}; seed it first`);
    const file = await ctx.db.system.get("_storage", videoId);
    if (file === null) throw appError("INVALID_UPLOAD", `no stored file has id ${videoId}`);
    if (!file.contentType?.startsWith("video/")) {
      throw appError("INVALID_UPLOAD", `stored file ${videoId} has content type ${file.contentType ?? "none"}, not video/*`);
    }
    if (scene.videoId !== undefined && scene.videoId !== videoId) await ctx.storage.delete(scene.videoId);
    await ctx.db.patch("scenes", scene._id, { videoId });
    logEvent({ operation: "scenes.attachVideo", status: "ok" });
    return scene._id;
  },
});

const catalogEntryV = v.object({
  slug: v.string(),
  title: v.string(),
  durationSeconds: v.number(),
  video: v.object({ url: v.string(), sha256: v.string(), byteSize: v.number(), contentType: v.string() }),
});

/**
 * Published scenes that have a stored video, for the public `GET /scenes` route. The app downloads each
 * video once and checks it against `sha256` (base64, as `_storage` records it).
 */
export const catalog = internalQuery({
  args: {},
  returns: v.array(catalogEntryV),
  handler: async (ctx) => {
    const scenes = await ctx.db
      .query("scenes")
      .withIndex("by_published", (q) => q.eq("published", true))
      .collect();
    const entries = await Promise.all(
      scenes.map(async (scene) => {
        if (scene.videoId === undefined) return null;
        const file = await ctx.db.system.get("_storage", scene.videoId);
        const url = await ctx.storage.getUrl(scene.videoId);
        if (file === null || url === null) throw new Error(`scene ${scene.slug} points at missing file ${scene.videoId}`);
        if (file.contentType === undefined) throw new Error(`scene ${scene.slug} video ${scene.videoId} has no content type`);
        return {
          slug: scene.slug,
          title: scene.title,
          durationSeconds: scene.durationSeconds,
          video: { url, sha256: file.sha256, byteSize: file.size, contentType: file.contentType },
        };
      }),
    );
    return entries.filter((entry) => entry !== null);
  },
});
