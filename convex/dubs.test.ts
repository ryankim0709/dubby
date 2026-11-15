import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { api } from "./_generated/api";
import type { Id } from "./_generated/dataModel";
import { alice, drain, newBackend } from "./test.helpers";

// Everything here is a synthetic fixture: silent WAVs and invented transcription results.

type WhisperWord = { word: string; start: number; end: number };

/** SYNTHETIC silence as a 16 kHz mono 16-bit WAV. */
function wav(seconds: number): Uint8Array<ArrayBuffer> {
  const dataBytes = Math.round(seconds * 16_000) * 2;
  const bytes = new Uint8Array(44 + dataBytes);
  const view = new DataView(bytes.buffer);
  const text = (offset: number, value: string) => [...value].forEach((char, index) => (bytes[offset + index] = char.charCodeAt(0)));
  text(0, "RIFF");
  view.setUint32(4, 36 + dataBytes, true);
  text(8, "WAVE");
  text(12, "fmt ");
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);
  view.setUint16(22, 1, true);
  view.setUint32(24, 16_000, true);
  view.setUint32(28, 32_000, true);
  view.setUint16(32, 2, true);
  view.setUint16(34, 16, true);
  text(36, "data");
  view.setUint32(40, dataBytes, true);
  return bytes;
}

/** Stands in for OpenAI's transcription endpoint, answering by the uploaded file's size. */
function fakeWhisper(bySize: Map<number, WhisperWord[]>, failure?: { status: number }) {
  const requests: FormData[] = [];
  vi.stubGlobal("fetch", async (input: string | URL | Request, init?: RequestInit) => {
    const request = new Request(input, init);
    const url = new URL(request.url);
    if (url.hostname !== "api.openai.com" || !url.pathname.endsWith("/audio/transcriptions")) return new Response("not faked", { status: 500 });
    const form = await request.formData();
    requests.push(form);
    if (failure !== undefined) return Response.json({ error: { message: "provider detail" } }, { status: failure.status });
    const file = form.get("file");
    const words = file instanceof Blob ? bySize.get(file.size) : undefined;
    if (words === undefined) return new Response("unknown fixture", { status: 500 });
    return Response.json({ task: "transcribe", language: "english", duration: 3, text: words.map((word) => word.word).join(" "), words });
  });
  return requests;
}

async function learner() {
  const t = newBackend();
  const a = t.withIdentity(alice);
  await a.mutation(api.users.ensure, {});
  const upload = async (seconds: number): Promise<Id<"_storage">> =>
    await t.run(async (ctx) => await ctx.storage.store(new Blob([wav(seconds)], { type: "audio/wav" })));
  return { t, a, upload };
}

const dub = (clientDubId: string, locale: string, takes: { lineIndex: number; referenceText: string; startMs: number; endMs: number; storageId: Id<"_storage"> }[]) => ({
  clientDubId,
  sceneTitle: "SYNTHETIC fixture scene",
  characterName: "Fixture hero",
  locale,
  timeZone: "America/Los_Angeles",
  capturedAt: Date.now(),
  takes,
});

beforeEach(() => {
  vi.useFakeTimers();
  vi.stubEnv("OPENAI_API_KEY", "fixture-openai-key-do-not-use");
});
afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllEnvs();
  vi.unstubAllGlobals();
});

describe("dub score sheet", () => {
  it("grades every take against its line, completes the sheet, and hands it to tutoring", async () => {
    const { t, a, upload } = await learner();
    const first = await upload(3);
    const second = await upload(1);
    const requests = fakeWhisper(
      new Map([
        [wav(3).byteLength, [{ word: "You", start: 0.2, end: 0.4 }, { word: "underestimate", start: 0.4, end: 1.2 }, { word: "my", start: 1.2, end: 1.4 }, { word: "power", start: 1.4, end: 2.0 }]],
        [wav(1).byteLength, [{ word: "Don't", start: 0.1, end: 0.4 }, { word: "do", start: 0.4, end: 0.6 }, { word: "it", start: 0.6, end: 0.9 }]],
      ]),
    );
    const args = dub("6f1c1e0e-0000-4000-8000-000000000001", "en-US", [
      { lineIndex: 0, referenceText: "You underestimate my power.", startMs: 1000, endMs: 4000, storageId: first },
      { lineIndex: 1, referenceText: "Don't try it.", startMs: 5000, endMs: 6000, storageId: second },
    ]);
    const { dubId, created } = await a.mutation(api.dubs.submit, args);
    expect(created).toBe(true);
    expect(await a.mutation(api.dubs.submit, args)).toEqual({ dubId, created: false });
    await drain(t);

    const sheet = await a.query(api.dubs.scoreSheet, { clientDubId: args.clientDubId });
    // Line 0: every word, 1800 ms spoken for a 3000 ms window. Line 1: "try" heard as "do", 800 ms for 1000 ms.
    expect(sheet).toMatchObject({
      sheetVersion: "dub-v1",
      status: "complete",
      dubScore: 79,
      wordAccuracy: 83,
      timingFit: 70,
      linesDubbed: 2,
      linesScored: 2,
      linesUnscorable: 0,
      linesFailed: 0,
      lines: [
        { lineIndex: 0, status: "scored", lineScore: 88, wordAccuracy: 100, timingFit: 60 },
        { lineIndex: 1, status: "scored", lineScore: 71, wordAccuracy: 67, timingFit: 80, recognizedText: "Don't do it" },
      ],
    });
    expect(sheet?.lines[1]?.words).toContainEqual({ expected: "try", recognized: "do", textStatus: "substituted" });
    // The script is never sent as a hint, so the provider can't fill in the intended words.
    expect(requests.map((form) => form.get("prompt"))).toEqual([null, null]);

    const tutoring = await t.run(async (ctx) => ({
      assessments: await ctx.db.query("tutoringAssessments").collect(),
      memory: await ctx.db.query("tutoringMemoryOutbox").collect(),
    }));
    expect(tutoring.assessments).toHaveLength(2);
    expect(tutoring.memory.length).toBeGreaterThan(0);
  });

  it("never sends an unsupported language to the provider or counts an unscorable line as zero", async () => {
    const { t, a, upload } = await learner();
    const requests = fakeWhisper(new Map());
    const args = dub("6f1c1e0e-0000-4000-8000-000000000002", "ja-JP", [
      { lineIndex: 0, referenceText: "Synthetic line.", startMs: 0, endMs: 2000, storageId: await upload(2) },
    ]);
    await a.mutation(api.dubs.submit, args);
    await drain(t);

    expect(await a.query(api.dubs.scoreSheet, { clientDubId: args.clientDubId })).toMatchObject({
      status: "complete",
      dubScore: null,
      linesUnscorable: 1,
      lines: [{ status: "unscorable", reason: "unsupported_locale", lineScore: null }],
    });
    expect(requests).toHaveLength(0);
  });

  it("records a provider failure on its take and still completes the sheet", async () => {
    const { t, a, upload } = await learner();
    fakeWhisper(new Map(), { status: 400 });
    const args = dub("6f1c1e0e-0000-4000-8000-000000000003", "en-US", [
      { lineIndex: 0, referenceText: "Synthetic line.", startMs: 0, endMs: 2000, storageId: await upload(2) },
    ]);
    await a.mutation(api.dubs.submit, args);
    await drain(t);

    expect(await a.query(api.dubs.scoreSheet, { clientDubId: args.clientDubId })).toMatchObject({
      status: "complete",
      dubScore: null,
      linesFailed: 1,
      lines: [{ status: "failed", reason: "provider_rejected" }],
    });
    expect(await t.run(async (ctx) => await ctx.db.query("tutoringAssessments").collect())).toEqual([]);
  });
});
