import assert from "node:assert/strict";
import test from "node:test";
import { AssessmentError, buildAzureRequest, inspectWav, requestAzureAssessment } from "../../convex/assessment/index";
import type { RetryWarning } from "../../convex/assessment/index";

/** SYNTHETIC silence encoded as 16 kHz mono 16-bit PCM WAV. */
function wav(options: { seconds?: number; sampleRate?: number; channels?: number } = {}): Uint8Array {
  const sampleRate = options.sampleRate ?? 16_000;
  const channels = options.channels ?? 1;
  const dataBytes = Math.round((options.seconds ?? 1) * sampleRate) * channels * 2;
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

test("the request carries the documented assessment parameters and content type", () => {
  const spec = buildAzureRequest({ region: "eastus", locale: "en-US", referenceText: "Good morning." });
  assert.equal(spec.url, "https://eastus.stt.speech.microsoft.com/speech/recognition/conversation/cognitiveservices/v1?language=en-US&format=detailed");
  assert.equal(spec.headers["Content-Type"], "audio/wav; codecs=audio/pcm; samplerate=16000");
  assert.deepEqual(JSON.parse(atob(spec.headers["Pronunciation-Assessment"]!)), {
    ReferenceText: "Good morning.",
    GradingSystem: "HundredMark",
    Granularity: "Word",
    Dimension: "Comprehensive",
    EnableMiscue: "True",
  });
  assert.ok(!("Ocp-Apim-Subscription-Key" in spec.headers));
});

test("reference text with non-ASCII characters survives header encoding", () => {
  const spec = buildAzureRequest({ baseUrl: "https://example.invalid/stt", locale: "en-US", referenceText: "Café — don’t go" });
  const decoded = new TextDecoder().decode(Uint8Array.from(atob(spec.headers["Pronunciation-Assessment"]!), (char) => char.charCodeAt(0)));
  assert.equal(JSON.parse(decoded).ReferenceText, "Café — don’t go");
});

test("inspectWav accepts 16 kHz mono PCM and reports its duration", () => {
  assert.equal(inspectWav(wav({ seconds: 2.5 })).durationMs, 2500);
});

test("inspectWav rejects other formats and over-long audio", () => {
  const kind = (bytes: Uint8Array) => {
    try {
      inspectWav(bytes);
    } catch (error) {
      assert.ok(error instanceof AssessmentError);
      return error.kind;
    }
    return "accepted";
  };
  assert.equal(kind(wav({ sampleRate: 44_100 })), "invalid_input");
  assert.equal(kind(wav({ channels: 2 })), "invalid_input");
  assert.equal(kind(wav({ seconds: 31 })), "invalid_input");
  assert.equal(kind(new Uint8Array([1, 2, 3])), "invalid_input");
  assert.equal(kind(wav({ seconds: 30 })), "accepted");
});

const response = (status: number, body: unknown = {}) => new Response(JSON.stringify(body), { status });

function client(responses: Array<Response | Error>) {
  const requests: Array<{ url: string; key: string | null }> = [];
  const warnings: RetryWarning[] = [];
  const sleeps: number[] = [];
  const fetchStub = (async (url: string | URL | Request, init?: RequestInit) => {
    requests.push({ url: String(url), key: new Headers(init?.headers).get("Ocp-Apim-Subscription-Key") });
    const next = responses.shift()!;
    if (next instanceof Error) throw next;
    return next;
  }) as typeof fetch;
  const options = { key: "synthetic-key-123", region: "eastus", fetch: fetchStub, sleep: async (ms: number) => void sleeps.push(ms), warn: (warning: RetryWarning) => warnings.push(warning) };
  return { options, requests, warnings, sleeps };
}

const call = { locale: "en-US", referenceText: "Good morning.", wav: wav() };

test("transient failures are retried with backoff and each attempt is warned", async () => {
  const { options, requests, warnings, sleeps } = client([response(503), response(429), response(200, { RecognitionStatus: "NoMatch" })]);
  const result = await requestAzureAssessment(options, call);
  assert.equal(result.httpStatus, 200);
  assert.deepEqual(result.body, { RecognitionStatus: "NoMatch" });
  assert.equal(requests.length, 3);
  assert.equal(requests[0]!.key, "synthetic-key-123");
  assert.deepEqual(sleeps, [500, 1000]);
  assert.deepEqual(warnings.map((warning) => [warning.attempt, warning.httpStatus]), [[1, 503], [2, 429]]);
  assert.ok(!JSON.stringify(warnings).includes("synthetic-key-123"));
});

test("retries are bounded and the last transient status is returned for classification", async () => {
  const { options, requests } = client([response(500), response(500), response(500), response(200)]);
  const result = await requestAzureAssessment(options, call);
  assert.equal(result.httpStatus, 500);
  assert.equal(requests.length, 3);
});

test("authorization and validation failures are not retried", async () => {
  const { options, requests } = client([response(401), response(200)]);
  assert.equal((await requestAzureAssessment(options, call)).httpStatus, 401);
  assert.equal(requests.length, 1);
});

test("repeated network failures end as provider_unavailable", async () => {
  const { options, warnings } = client([new Error("down"), new Error("down"), new Error("down")]);
  await assert.rejects(requestAzureAssessment(options, call), (error: unknown) => error instanceof AssessmentError && error.kind === "provider_unavailable" && error.retryable);
  assert.equal(warnings.length, 2);
});

test("a body that is not JSON surfaces as an undefined body for the parser to reject", async () => {
  const { options } = client([new Response("<html>", { status: 200 })]);
  assert.equal((await requestAzureAssessment(options, call)).body, undefined);
});
