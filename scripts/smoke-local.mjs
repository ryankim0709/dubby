// End-to-end smoke run against a LOCAL Convex deployment (anonymous agent mode) over real HTTP.
// Prerequisites: `npx convex dev` is running with the DEV_ONLY_TEST_JWT_* variables configured
// (see docs/convex-backend.md). It spends nothing and calls no provider. The scene is a labeled
// synthetic fixture seeded through the internal seed mutation.
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { ConvexHttpClient } from "convex/browser";
import { mintToken } from "./dev-auth.mjs";

const root = join(import.meta.dirname, "..");
const env = Object.fromEntries(
  readFileSync(join(root, ".env.local"), "utf8")
    .split("\n")
    .filter((line) => /^[A-Z_]+=/.test(line))
    .map((line) => line.split("=", 2)),
);
const cloudUrl = env.CONVEX_URL;
const siteUrl = env.CONVEX_SITE_URL;

let failures = 0;
function check(name, ok, detail = "") {
  console.log((ok ? "PASS " : "FAIL ") + name + (ok ? "" : " " + detail));
  if (!ok) failures += 1;
}

const wav = Buffer.alloc(1024, 7);
const manifest = {
  schemaVersion: 1,
  sceneId: "synthetic-smoke-scene",
  title: "SYNTHETIC TEST FIXTURE smoke scene",
  locale: "en-US",
  durationSeconds: 10,
  published: true,
  provenance: { work: "synthetic test fixture", creator: "smoke script", license: "none; never shipped", attribution: "none" },
  characters: [{ id: "smoke-a", displayName: "Smoke A" }, { id: "smoke-b", displayName: "Smoke B" }],
  lines: [{ id: "smoke-line-01", characterId: "smoke-a", start: 1, end: 3, text: "Synthetic smoke line.", referenceVersion: 1 }],
};
execFileSync("npx", ["convex", "run", "scenes:seed", JSON.stringify(manifest)], { cwd: root, stdio: ["ignore", "ignore", "inherit"], env: { ...process.env, CONVEX_AGENT_MODE: "anonymous" } });

const client = (subject) => {
  const c = new ConvexHttpClient(cloudUrl);
  c.setAuth(mintToken(subject));
  return c;
};
const alice = client("smoke-alice");
const bob = client("smoke-bob");
const bearer = (subject) => ({ Authorization: "Bearer " + mintToken(subject) });

const health = await fetch(siteUrl + "/health");
check("GET /health is public", health.status === 200 && (await health.json()).service === "dubit-backend");
const characters = await fetch(siteUrl + "/coach/characters");
check("GET /coach/characters is public", characters.status === 200);

const body = JSON.stringify({ characterId: "anakin", language: "es" });
const headers = { "Content-Type": "application/json" };
check("POST /coach/session-token without a token is 401", (await fetch(siteUrl + "/coach/session-token", { method: "POST", headers, body })).status === 401);
check("POST /coach/reply with a garbage token is 401", (await fetch(siteUrl + "/coach/reply", { method: "POST", headers: { ...headers, Authorization: "Bearer not-a-jwt" }, body: "{}" })).status === 401);
const signedIn = await fetch(siteUrl + "/coach/session-token", { method: "POST", headers: { ...headers, ...bearer("smoke-alice") }, body });
check("POST /coach/session-token with a valid token passes auth (503: no provider key set)", signedIn.status === 503, "status " + signedIn.status);

await alice.mutation("users:ensure", {});
await bob.mutation("users:ensure", {});
await alice.mutation("users:setTimeZone", { timeZone: "America/Los_Angeles" });
const scenes = await alice.query("scenes:list", {});
const scene = scenes.find((s) => s.slug === "synthetic-smoke-scene");
check("scenes.list shows the seeded fixture", scene !== undefined);
const detail = await alice.query("scenes:get", { sceneId: scene.sceneId });
const { projectId } = await alice.mutation("projects:start", { sceneId: scene.sceneId, characterId: scene.characters[0].characterId });

async function upload(c) {
  const url = await c.mutation("attempts:generateUploadUrl", {});
  const response = await fetch(url, { method: "POST", headers: { "Content-Type": "audio/wav" }, body: wav });
  return (await response.json()).storageId;
}
const storageId = await upload(alice);
const clientAttemptId = crypto.randomUUID();
const create = (c, extra = {}) =>
  c.mutation("attempts:create", { projectId, lineId: detail.lines[0].lineId, clientAttemptId, storageId, durationMs: 2000, capturedAt: Date.now() - 1000, ...extra });
const first = await create(alice);
const again = await create(alice);
check("attempts.create is idempotent over HTTP", first.attemptId === again.attemptId && first.jobId === again.jobId);

const bobProject = (await bob.mutation("projects:start", { sceneId: scene.sceneId, characterId: scene.characters[0].characterId })).projectId;
const stolen = await bob
  .mutation("attempts:create", { projectId: bobProject, lineId: detail.lines[0].lineId, clientAttemptId: crypto.randomUUID(), storageId, durationMs: 2000, capturedAt: Date.now(), timeZone: "UTC" })
  .then(() => null, (error) => error);
check("another user can't claim the first user's upload", stolen !== null);

const audioUrl = siteUrl + "/media/attempts/" + first.attemptId + "/audio";
const own = await fetch(audioUrl, { headers: bearer("smoke-alice") });
check("owner streams the recording", own.status === 200 && Buffer.from(await own.arrayBuffer()).equals(wav) && own.headers.get("content-type") === "audio/wav");
const ranged = await fetch(audioUrl, { headers: { ...bearer("smoke-alice"), Range: "bytes=0-9" } });
check("owner can request a byte range", ranged.status === 206);
check("another user gets 404", (await fetch(audioUrl, { headers: bearer("smoke-bob") })).status === 404);
check("no token gets 401", (await fetch(audioUrl)).status === 401);

let job = null;
for (let i = 0; i < 20; i += 1) {
  job = (await alice.query("assessments:forAttempt", { attemptId: first.attemptId }))?.job;
  if (job?.status === "failed" || job?.status === "succeeded") break;
  await new Promise((resolve) => setTimeout(resolve, 500));
}
check("with no engine plugged in the job fails explicitly and retryably", job?.status === "failed" && job.error.code === "engine_not_configured" && job.error.retryable === true, JSON.stringify(job));
check("another user sees no job state", (await bob.query("assessments:forAttempt", { attemptId: first.attemptId })) === null);

console.log(failures === 0 ? "SMOKE OK" : "SMOKE FAILED: " + failures);
process.exit(failures === 0 ? 0 : 1);
