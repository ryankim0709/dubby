import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout } from "node:timers/promises";
import { pathToFileURL } from "node:url";
import { promisify } from "node:util";
import { z } from "zod";

const catalogSchema = z.object({ scenes: z.array(z.object({
  slug: z.string().min(1),
  durationSeconds: z.number().positive().max(120),
  details: z.object({ locale: z.string().min(1) }),
  video: z.object({ url: z.url(), sha256: z.string().min(1), byteSize: z.number().int().positive().max(24_000_000) }),
})) });
const transcriptReply = z.discriminatedUnion("status", [
  z.object({ status: z.literal("processing") }),
  z.object({ status: z.literal("ready"), locale: z.string(), durationSeconds: z.number().positive(), words: z.array(z.object({ text: z.string(), start: z.number(), end: z.number() })) }),
]);
const castReply = z.discriminatedUnion("status", [
  z.object({ status: z.literal("processing") }),
  z.object({ status: z.literal("framesNeeded") }),
  z.object({ status: z.literal("ready"), characters: z.array(z.object({ name: z.string().nullable(), portraitSeconds: z.number().nullable(), faceCenterX: z.number().nullable() })), segments: z.array(z.object({ start: z.number(), end: z.number(), character: z.number().int().nonnegative() })) }),
]);
type Scene = z.infer<typeof catalogSchema>["scenes"][number];
type SceneKey = { slug: string; sha256: string; locale: string };
type Frame = { seconds: number; jpegBase64: string };
const runFile = promisify(execFile);

/** Public routes accept only an existing published video's checksum, and share the app's cache leases. */
async function request(url: URL, init: RequestInit, slug: string): Promise<Response> {
  for (let attempt = 1; attempt <= 3; attempt += 1) {
    let response: Response;
    try {
      response = await fetch(url, { ...init, signal: AbortSignal.timeout(330_000) });
    } catch (error) {
      if (!(error instanceof TypeError || error instanceof DOMException)) throw error;
      console.warn(JSON.stringify({ operation: "scenes.prepare", slug, endpoint: url.pathname, attempt, status: "network_failed", error: error.message }));
      if (attempt === 3) throw error;
      await setTimeout(500 * 2 ** (attempt - 1));
      continue;
    }
    if (response.ok) return response;
    const body = await response.text();
    const error = new Error(`Scene preparation failed: slug=${slug}, endpoint=${url.pathname}, status=${response.status}, body=${body}`);
    console.warn(JSON.stringify({ operation: "scenes.prepare", slug, endpoint: url.pathname, attempt, httpStatus: response.status, body }));
    if (attempt === 3 || (response.status !== 429 && response.status < 500)) throw error;
    await setTimeout(500 * 2 ** (attempt - 1));
  }
  throw new Error("Scene preparation retry loop ended without a result");
}

async function post(url: URL, body: SceneKey | (SceneKey & { frames: Frame[] })): Promise<Response> {
  return await request(url, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) }, body.slug);
}

async function prepareTranscript(siteURL: URL, key: SceneKey): Promise<void> {
  const deadline = Date.now() + 360_000;
  while (Date.now() < deadline) {
    const response = transcriptReply.parse(await (await post(new URL("/scenes/transcribe", siteURL), key)).json());
    if (response.status === "ready") return;
    await setTimeout(2_000);
  }
  throw new Error(`Scene transcription timed out: slug=${key.slug}, locale=${key.locale}`);
}

/** Download only on a cache miss, and verify the same file identity the backend uses before sampling. */
async function sampleFrames(scene: Scene): Promise<Frame[]> {
  const response = await request(new URL(scene.video.url), { method: "GET" }, scene.slug);
  const video = Buffer.from(await response.arrayBuffer());
  if (video.length !== scene.video.byteSize || createHash("sha256").update(video).digest("base64") !== scene.video.sha256) {
    throw new Error(`Scene download failed its size or checksum check: slug=${scene.slug}`);
  }
  const directory = await mkdtemp(join(tmpdir(), "dubby-prepare-"));
  try {
    const path = join(directory, "scene.mp4");
    await writeFile(path, video);
    const interval = Math.max(1.5, scene.durationSeconds / 80);
    const frames: Frame[] = [];
    for (let seconds = interval / 2; seconds < scene.durationSeconds; seconds += interval) {
      const { stdout } = await runFile("ffmpeg", [
        "-v", "error", "-ss", String(seconds), "-i", path, "-frames:v", "1",
        "-vf", "scale=512:512:force_original_aspect_ratio=decrease", "-q:v", "5", "-f", "image2pipe", "-vcodec", "mjpeg", "pipe:1",
      ], { encoding: "buffer", maxBuffer: 150_000, timeout: 30_000 });
      if (stdout.length === 0) throw new Error(`Scene frame is empty: slug=${scene.slug}, seconds=${seconds}`);
      frames.push({ seconds: Math.round(seconds * 100) / 100, jpegBase64: stdout.toString("base64") });
    }
    return frames;
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}

async function prepareCast(siteURL: URL, scene: Scene, key: SceneKey): Promise<void> {
  const deadline = Date.now() + 360_000;
  let sampled: Frame[] | null = null;
  let frames: Frame[] = [];
  while (Date.now() < deadline) {
    const response = castReply.parse(await (await post(new URL("/scenes/speakers", siteURL), { ...key, frames })).json());
    if (response.status === "ready") return;
    if (response.status === "framesNeeded") {
      sampled ??= await sampleFrames(scene);
      frames = sampled;
    } else {
      frames = [];
      await setTimeout(2_000);
    }
  }
  throw new Error(`Scene cast preparation timed out: slug=${key.slug}, locale=${key.locale}`);
}

export async function prepareScenes(siteURL: URL): Promise<number> {
  const { scenes } = catalogSchema.parse(await (await request(new URL("/scenes", siteURL), { method: "GET" }, "catalog")).json());
  for (const scene of scenes) {
    const key: SceneKey = { slug: scene.slug, sha256: scene.video.sha256, locale: scene.details.locale };
    await Promise.all([prepareTranscript(siteURL, key), prepareCast(siteURL, scene, key)]);
    console.log(JSON.stringify({ operation: "scenes.prepare", slug: scene.slug, status: "ready" }));
  }
  return scenes.length;
}

if (process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const siteURL = new URL(z.url().parse(process.argv[2] ?? process.env.CONVEX_SITE_URL));
  const count = await prepareScenes(siteURL);
  console.log(JSON.stringify({ operation: "scenes.prepare", status: "complete", count }));
}
