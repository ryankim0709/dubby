// Seeds a Convex deployment with demo learners and weeks of scored dubs, so the Progress tab and the coach's
// memory have history to show.
//
// Every take goes through the real pipeline: macOS `say` speaks the line with the learner's scripted mistakes
// and pacing, the app's own upload and submit functions store it, and Whisper scores it. The learners and their
// voices are synthetic; the scores are the pipeline's real measurements of those recordings.
//
// Usage, on macOS from the repository root, with CONVEX_DEPLOY_KEY, CONVEX_URL and CONVEX_SITE_URL in .env.local:
//   node scripts/seed-demo-progress.mjs
// It acts as each learner with the deploy key, so no password is used. Re-running skips dubs that already exist.
// Dubs are dated over the last four weeks; the backend accepts capture times up to 30 days old.
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ConvexHttpClient } from "convex/browser";
import { makeFunctionReference } from "convex/server";

const root = join(import.meta.dirname, "..");
const envFile = join(root, ".env.local");
const fileEnv = Object.fromEntries(
  (existsSync(envFile) ? readFileSync(envFile, "utf8") : "")
    .split("\n")
    .filter((line) => /^[A-Z_]+=/.test(line))
    .map((line) => {
      const split = line.indexOf("=");
      return [line.slice(0, split), line.slice(split + 1).trim().replace(/^['"]|['"]$/g, "")];
    }),
);
const env = { ...fileEnv, ...process.env };
for (const name of ["CONVEX_DEPLOY_KEY", "CONVEX_URL", "CONVEX_SITE_URL"]) {
  if (!env[name]) throw new Error(`${name} must be set in .env.local or the environment`);
}

const fn = (name) => makeFunctionReference(name);
const DAY_MS = 24 * 60 * 60 * 1000;
/** The pace every line's window is measured at, in words per minute. */
const NATURAL_RATE = 180;
const SPAN_DAYS = 27;

const tearsOfSteel = JSON.parse(readFileSync(join(root, "Dubbing/DemoScenes/tears-of-steel-bridge/tears-of-steel-bridge-manifest.json"), "utf8"));

/** Scenes per language. Tears of Steel is CC-BY 3.0 (Blender Foundation); the others are original dialogue. */
const scenes = {
  "en-US": [
    // Celia's line only: Thom's are fragments ("by— it's...") that a synthetic voice doesn't read as dialogue.
    { title: tearsOfSteel.title, character: "Celia", lines: tearsOfSteel.lines.filter((line) => line.characterId === "celia").map((line) => line.text) },
    { title: "Late Night Diner", character: "Rosa", lines: ["Can I get a coffee to go?", "We close in ten minutes, honey.", "Then make it a large one.", "You look like you haven't slept in days."] },
    { title: "The Last Train Home", character: "Eli", lines: ["Is this the last train to the city?", "I left my ticket on the platform.", "Hold the doors, please!", "We made it, just barely."] },
  ],
  "es-ES": [
    { title: "Café en Madrid", character: "Lucía", lines: ["¿Me pone un café con leche, por favor?", "Claro, ¿algo más?", "Sí, una tostada con tomate.", "Hoy hace mucho calor en la calle."] },
    { title: "El tren de la noche", character: "Diego", lines: ["Perdone, ¿este asiento está libre?", "Sí, siéntese, por favor.", "¿A qué hora llegamos a Sevilla?", "Creo que llegamos al amanecer."] },
  ],
  "fr-FR": [
    { title: "Le Petit Café", character: "Camille", lines: ["Bonjour, un croissant et un café, s'il vous plaît.", "Vous voulez autre chose ?", "Non merci, c'est tout.", "Bonne journée, à demain !"] },
    { title: "Le Train de nuit", character: "Hugo", lines: ["Excusez-moi, cette place est libre ?", "Oui, asseyez-vous.", "Le train part à quelle heure ?", "Dans dix minutes, je crois."] },
  ],
};

/** Words a learner tends to say instead of the script's word. Words not listed are dropped when they go wrong. */
const confusables = {
  "en-US": { coffee: "copy", large: "big", train: "plane", ticket: "jacket", doors: "door", city: "center", freaked: "freaking", minutes: "minute", slept: "sleep", last: "next", made: "make", platform: "station", honey: "money", robot: "rabbit", admit: "omit" },
  "es-ES": { leche: "lecho", tostada: "tostado", tomate: "tomates", calor: "color", asiento: "asunto", libre: "listo", amanecer: "anochecer", llegamos: "llegaremos", algo: "nada", calle: "casa" },
  "fr-FR": { journée: "soirée", demain: "bientôt", place: "plage", libre: "livre", minutes: "secondes", heure: "heures", croissant: "croissants", café: "thé", merci: "mercredi", tout: "tous" },
};

/**
 * Who to seed. `from` and `to` are the learner's habits on their first and last dub: the chance of getting a word
 * wrong, and how far their pace strays from the line's natural pace.
 */
const learners = [
  { username: "demo", locale: "en-US", timeZone: "America/Los_Angeles", voice: "Samantha", dubs: 12, from: { mistakes: 0.3, pace: 0.45 }, to: { mistakes: 0, pace: 0.04 } },
  { username: "demo1", locale: "en-US", timeZone: "America/New_York", voice: "Daniel", dubs: 8, from: { mistakes: 0.15, pace: 0.25 }, to: { mistakes: 0.1, pace: 0.18 } },
  { username: "maya", locale: "es-ES", timeZone: "Europe/Madrid", voice: "Flo (Spanish (Spain))", dubs: 10, from: { mistakes: 0.35, pace: 0.5 }, to: { mistakes: 0.04, pace: 0.08 } },
  { username: "theo", locale: "fr-FR", timeZone: "Europe/Paris", voice: "Thomas", dubs: 8, from: { mistakes: 0.3, pace: 0.4 }, to: { mistakes: 0.08, pace: 0.12 } },
  { username: "jordan", locale: "en-US", timeZone: "America/Chicago", voice: "Fred", dubs: 6, from: { mistakes: 0.45, pace: 0.6 }, to: { mistakes: 0.25, pace: 0.3 } },
];

/** A small seeded generator, so every run makes the same dubs. */
function random(seedText) {
  let state = createHash("sha256").update(seedText).digest().readUInt32LE(0);
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** A stable UUID for a learner's nth seeded dub, so a re-run finds the dub it already made. */
function dubId(username, index) {
  const hex = createHash("sha256").update(`seed-demo-progress-v2|${username}|${index}`).digest("hex");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-5${hex.slice(13, 16)}-8${hex.slice(17, 20)}-${hex.slice(20, 32)}`;
}

/** The line as this learner says it: each word goes wrong with the given chance, swapped when a confusable exists, else dropped. */
function spoken(text, locale, mistakeChance, next) {
  const words = text.split(/\s+/);
  const said = words.flatMap((word) => {
    if (next() >= mistakeChance) return [word];
    const bare = word.toLocaleLowerCase(locale).replace(/[^\p{L}'-]/gu, "");
    const swap = confusables[locale][bare];
    if (swap !== undefined) return [word.replace(new RegExp(bare, "iu"), swap)];
    return words.length > 2 ? [] : [word];
  });
  return said.length === 0 ? text : said.join(" ");
}

function speak(folder, name, voice, rate, text) {
  const aiff = join(folder, `${name}.aiff`);
  const wav = join(folder, `${name}.wav`);
  execFileSync("say", ["-v", voice, "-r", String(Math.round(rate)), "-o", aiff, text]);
  execFileSync("afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff, wav]);
  const info = execFileSync("afinfo", [wav], { encoding: "utf8" });
  const seconds = Number(/estimated duration: ([\d.]+)/.exec(info)?.[1]);
  if (!Number.isFinite(seconds)) throw new Error(`afinfo didn't report a duration for ${wav}`);
  return { wav, durationMs: Math.round(seconds * 1000) };
}

const lerp = (from, to, progress) => from + (to - from) * progress;

async function seedLearner(admin, learner, folder) {
  const account = await admin.query(fn("passwordAuth:accountByUsername"), { username: learner.username });
  if (account === null) throw new Error(`The ${learner.username} account doesn't exist after seeding accounts`);
  const site = env.CONVEX_SITE_URL;
  const client = new ConvexHttpClient(env.CONVEX_URL);
  client.setAdminAuth(env.CONVEX_DEPLOY_KEY, { subject: account._id, issuer: site, tokenIdentifier: `${site}|${account._id}` });
  await client.mutation(fn("users:ensure"), {});

  const next = random(learner.username);
  const sceneList = scenes[learner.locale];
  const submitted = [];
  for (let index = 0; index < learner.dubs; index += 1) {
    const clientDubId = dubId(learner.username, index);
    if ((await client.query(fn("dubs:scoreSheet"), { clientDubId })) !== null) {
      submitted.push(clientDubId);
      continue;
    }
    const progress = learner.dubs === 1 ? 1 : index / (learner.dubs - 1);
    const mistakes = lerp(learner.from.mistakes, learner.to.mistakes, progress);
    const pace = lerp(learner.from.pace, learner.to.pace, progress);
    const daysAgo = SPAN_DAYS - Math.round(progress * (SPAN_DAYS - 1));
    const capturedAt = Date.now() - daysAgo * DAY_MS - Math.round(next() * 3 * 60 * 60 * 1000);
    const scene = sceneList[index % sceneList.length];
    const count = Math.min(scene.lines.length, 2 + Math.floor(next() * 2));
    const first = Math.floor(next() * (scene.lines.length - count + 1));

    const takes = [];
    for (let offset = 0; offset < count; offset += 1) {
      const lineIndex = first + offset;
      const text = scene.lines[lineIndex];
      const natural = speak(folder, `natural-${learner.username}-${index}-${offset}`, learner.voice, NATURAL_RATE, text);
      // Too slow or too fast by about `pace`, so timing fit tracks how far the pace strays.
      const stray = 1 + pace * (0.6 + 0.4 * next());
      const rate = next() < 0.5 ? NATURAL_RATE / stray : NATURAL_RATE * stray;
      const take = speak(folder, `take-${learner.username}-${index}-${offset}`, learner.voice, rate, spoken(text, learner.locale, mistakes, next));
      const uploadUrl = await client.mutation(fn("dubs:generateUploadUrl"), {});
      const upload = await fetch(uploadUrl, { method: "POST", headers: { "Content-Type": "audio/wav" }, body: readFileSync(take.wav) });
      if (!upload.ok) throw new Error(`Uploading a take failed with status ${upload.status}: ${await upload.text()}`);
      const { storageId } = await upload.json();
      const startMs = lineIndex * 6000;
      takes.push({ lineIndex, referenceText: text, startMs, endMs: startMs + Math.max(400, natural.durationMs - 150), storageId });
    }
    await client.mutation(fn("dubs:submit"), {
      clientDubId,
      sceneTitle: scene.title,
      characterName: scene.character,
      locale: learner.locale,
      timeZone: learner.timeZone,
      capturedAt,
      takes,
    });
    submitted.push(clientDubId);
    console.log(`${learner.username}: submitted dub ${index + 1} of ${learner.dubs} (${scene.title}, ${daysAgo} days ago)`);
  }
  return { client, submitted };
}

async function waitForSheets(learner, client, clientDubIds) {
  const deadline = Date.now() + 10 * 60 * 1000;
  const scores = [];
  for (const clientDubId of clientDubIds) {
    let sheet = await client.query(fn("dubs:scoreSheet"), { clientDubId });
    while (sheet?.status !== "complete") {
      if (Date.now() > deadline) throw new Error(`${learner.username}'s dub ${clientDubId} didn't finish scoring within 10 minutes`);
      await new Promise((resolve) => setTimeout(resolve, 2000));
      sheet = await client.query(fn("dubs:scoreSheet"), { clientDubId });
    }
    scores.push(sheet.dubScore ?? "–");
  }
  console.log(`${learner.username} (${learner.locale}) dub scores, oldest first: ${scores.join(", ")}`);
}

const admin = new ConvexHttpClient(env.CONVEX_URL);
admin.setAdminAuth(env.CONVEX_DEPLOY_KEY);
const created = await admin.action(fn("passwordAuth:seedDemoAccounts"), {});
console.log(`Accounts created: ${created.created.length === 0 ? "none (all existed)" : created.created.join(", ")}`);

const folder = mkdtempSync(join(tmpdir(), "dubby-seed-"));
try {
  const runs = [];
  for (const learner of learners) runs.push({ learner, ...(await seedLearner(admin, learner, folder)) });
  for (const { learner, client, submitted } of runs) await waitForSheets(learner, client, submitted);
} finally {
  rmSync(folder, { recursive: true, force: true });
}
