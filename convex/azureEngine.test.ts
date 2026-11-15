import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { exampleWords, status, syntheticSuccess } from "../tests/assessment/fixtures";
import { api } from "./_generated/api";
import { AZURE_PROVIDER_NAME, EVALUATOR_CONFIG_VERSION } from "./assessment";
import { createAzureEngine } from "./integrations/azureEngine";
import { AssessmentError, assessmentOutcomeSchema } from "./integrations/contracts";
import { validateOutcome } from "./lib/outcome";
import { type World, doubles, drain, fixtureText, record, startWorld } from "./test.helpers";

// The Azure engine is the real one; the coaching side is whatever the test plugs in, so these tests
// hold whichever coaching provider the deployment registers.
vi.mock("./integrations/providers", async (importOriginal) => {
  const actual = await importOriginal<typeof import("./integrations/providers")>();
  const { doubles: current } = await import("./test.helpers");
  return { ...actual, getCoachingProvider: () => current.coach };
});

// Every Azure response here is a synthetic fixture served by a fake fetch; no request leaves the test.

const KEY = "fixture-speech-key-do-not-use";

/** SYNTHETIC silence as a WAV. */
function wav({ seconds = 3.5, sampleRate = 16_000, channels = 1 } = {}): Uint8Array {
  const dataBytes = Math.round(seconds * sampleRate) * channels * 2;
  const bytes = new Uint8Array(44 + dataBytes);
  const view = new DataView(bytes.buffer);
  const text = (offset: number, value: string) => [...value].forEach((char, index) => (bytes[offset + index] = char.charCodeAt(0)));
  text(0, "RIFF");
  view.setUint32(4, 36 + dataBytes, true);
  text(8, "WAVE");
  text(12, "fmt ");
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);
  view.setUint16(22, channels, true);
  view.setUint32(24, sampleRate, true);
  view.setUint32(28, sampleRate * channels * 2, true);
  view.setUint16(32, channels * 2, true);
  view.setUint16(34, 16, true);
  text(36, "data");
  view.setUint32(40, dataBytes, true);
  return bytes;
}

const success = () => syntheticSuccess({ display: fixtureText, words: exampleWords });
const reply = (httpStatus: number, body: unknown = {}) => new Response(JSON.stringify(body), { status: httpStatus });

const input = {
  assessmentId: "job-1",
  attemptId: "attempt-1",
  lineId: "line-1",
  referenceVersion: 1,
  locale: "en-US",
  recordedAt: "2026-11-15T10:00:00.000Z",
  referenceText: fixtureText,
  targetWindowMs: { startMs: 1000, endMs: 4000 },
  recordingDurationMs: 3500,
};

function engineWith(responses: Response[]) {
  const fetchMock = vi.fn(async (..._args: Parameters<typeof fetch>) => {
    const next = responses.shift();
    if (next === undefined) throw new Error("unexpected extra request");
    return next;
  });
  const engine = createAzureEngine({ key: KEY, region: "eastus", fetch: fetchMock as unknown as typeof fetch, sleep: async () => {} });
  return { engine, fetchMock };
}

const audio = (bytes: Uint8Array = wav()) => new Blob([bytes as BlobPart], { type: "audio/wav" });

describe("Azure assessment engine", () => {
  it("scores a recording, reports acoustic provenance, and passes the backend's checks", async () => {
    const { engine, fetchMock } = engineWith([reply(200, success())]);
    const outcome = assessmentOutcomeSchema.parse(await engine.assess(input, audio()));

    expect(outcome.response.status).toBe("scored");
    expect(outcome.provenance).toEqual({
      evaluator: AZURE_PROVIDER_NAME,
      measurement: "acoustic",
      modelVersion: null,
      evaluatorConfigVersion: EVALUATOR_CONFIG_VERSION,
    });
    expect(() => validateOutcome(outcome, input)).not.toThrow();

    const [url, init] = fetchMock.mock.calls[0]!;
    expect(String(url)).toContain("https://eastus.stt.speech.microsoft.com/");
    expect((init!.headers as Record<string, string>)["Ocp-Apim-Subscription-Key"]).toBe(KEY);
    expect((init!.body as Uint8Array).byteLength).toBe(wav().byteLength);
  });

  it("returns an unscorable outcome, not an error, when the service heard no speech", async () => {
    const { engine } = engineWith([reply(200, status("InitialSilenceTimeout"))]);
    const outcome = assessmentOutcomeSchema.parse(await engine.assess(input, audio()));
    expect(outcome.response).toMatchObject({ status: "unscorable", reason: "no_speech", scores: null });
    expect(() => validateOutcome(outcome, input)).not.toThrow();
  });

  it("retries a 429, then succeeds, and logs the retry without the key, audio, or transcript", async () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    const { engine, fetchMock } = engineWith([reply(429), reply(200, success())]);
    const outcome = await engine.assess(input, audio());

    expect(outcome.response.status).toBe("scored");
    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(warn).toHaveBeenCalledTimes(1);
    const line = String(warn.mock.calls[0]![0]);
    expect(JSON.parse(line)).toMatchObject({ operation: "azure_pronunciation_assessment", status: "retrying", httpStatus: 429, jobId: "job-1", tries: 1 });
    expect(line).not.toContain(KEY);
    expect(line).not.toContain(fixtureText);
    warn.mockRestore();
  });

  it("fails a 401 without retrying and marks it not retryable", async () => {
    const { engine, fetchMock } = engineWith([reply(401)]);
    const error = await engine.assess(input, audio()).catch((caught: unknown) => caught);
    expect(error).toBeInstanceOf(AssessmentError);
    expect(error).toMatchObject({ kind: "provider_auth", retryable: false });
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("keeps a retryable failure retryable once the attempts are spent", async () => {
    const { engine, fetchMock } = engineWith([reply(503), reply(503), reply(503)]);
    const error = await engine.assess(input, audio()).catch((caught: unknown) => caught);
    expect(error).toMatchObject({ kind: "provider_unavailable", retryable: true });
    expect(fetchMock).toHaveBeenCalledTimes(3);
  });

  it.each([
    ["not a WAV file", new Uint8Array(64).fill(7)],
    ["a different sample rate", wav({ sampleRate: 8_000 })],
    ["stereo audio", wav({ channels: 2 })],
    ["audio over 30 seconds", wav({ seconds: 31 })],
  ])("rejects %s before calling the service", async (_name, bytes) => {
    const { engine, fetchMock } = engineWith([]);
    const error = await engine.assess(input, audio(bytes)).catch((caught: unknown) => caught);
    expect(error).toMatchObject({ kind: "invalid_input", retryable: false });
    expect(fetchMock).not.toHaveBeenCalled();
  });
});

describe("assessment jobs with the Azure engine configured", () => {
  let fetchMock: ReturnType<typeof vi.fn>;
  let world: World;

  async function startAttempt(bytes: Uint8Array = wav()) {
    const { projectId } = await world.a.mutation(api.projects.start, { sceneId: world.sceneId, characterId: world.characterA });
    const storageId = await world.t.run(async (ctx) => await ctx.storage.store(audio(bytes)));
    return await record(world.t, world.a, { projectId, lineId: world.line1, storageId });
  }

  const jobOf = (jobId: Awaited<ReturnType<typeof startAttempt>>["jobId"]) => world.t.run(async (ctx) => await ctx.db.get("assessmentJobs", jobId));

  beforeEach(async () => {
    vi.useFakeTimers();
    doubles.coach = null;
    vi.stubEnv("AZURE_SPEECH_KEY", KEY);
    vi.stubEnv("AZURE_SPEECH_REGION", "eastus");
    fetchMock = vi.fn(async () => reply(200, success()));
    vi.stubGlobal("fetch", fetchMock);
    world = await startWorld();
  });
  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllEnvs();
    vi.unstubAllGlobals();
  });

  it("fails with engine_not_configured, and never calls Azure, while the key or region is unset", async () => {
    vi.stubEnv("AZURE_SPEECH_KEY", "");
    const { jobId } = await startAttempt();
    await drain(world.t);
    expect(await jobOf(jobId)).toMatchObject({ status: "failed", stage: "measure", error: { code: "engine_not_configured", retryable: true } });
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("stores the scored outcome, then fails as coach_not_configured and never rescores on retry", async () => {
    const { jobId } = await startAttempt();
    await drain(world.t);

    const failed = await jobOf(jobId);
    expect(failed).toMatchObject({ status: "failed", stage: "coach", error: { code: "coach_not_configured", retryable: true } });
    expect(failed?.outcome).toMatchObject({
      response: { status: "scored", measurement: "acoustic" },
      provenance: { provider: AZURE_PROVIDER_NAME, measurement: "acoustic", providerModelVersion: null, configVersion: EVALUATOR_CONFIG_VERSION },
    });
    expect(fetchMock).toHaveBeenCalledTimes(1);

    await world.a.mutation(api.assessments.retry, { jobId });
    await drain(world.t);
    expect(await jobOf(jobId)).toMatchObject({ status: "failed", stage: "coach", error: { code: "coach_not_configured" } });
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("fails a job permanently when Azure rejects the key", async () => {
    fetchMock.mockImplementation(async () => reply(401));
    const { jobId } = await startAttempt();
    await drain(world.t);
    expect(await jobOf(jobId)).toMatchObject({ status: "failed", stage: "measure", error: { code: "provider_auth", retryable: false } });
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("fails a job permanently, without calling Azure, when the recording is not 16 kHz mono PCM", async () => {
    const { jobId } = await startAttempt(wav({ sampleRate: 44_100 }));
    await drain(world.t);
    expect(await jobOf(jobId)).toMatchObject({ status: "failed", stage: "measure", error: { code: "invalid_input", retryable: false } });
    expect(fetchMock).not.toHaveBeenCalled();
  });
});
