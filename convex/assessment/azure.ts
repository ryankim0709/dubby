// Azure AI Speech adapter: request construction, WAV inspection and response parsing.
//
// Sources, checked 2026-11-15:
//  - Speech to text REST API for short audio (endpoint, audio format, headers, Pronunciation-Assessment
//    parameters, status codes, RecognitionStatus values, response properties, sample responses):
//    https://learn.microsoft.com/en-us/azure/ai-services/speech-service/rest-speech-to-text-short
//  - Pronunciation assessment (parameter meanings, scripted result fields, Mispronunciation = word
//    AccuracyScore below 60, Offset/Duration in 100-nanosecond units, 30-second limit for miscue):
//    https://learn.microsoft.com/en-us/azure/ai-services/speech-service/how-to-pronunciation-assessment
//
// The REST sample nests nothing under PronunciationAssessment while the SDK JSON sample does; both
// shapes are documented, so scores are read from either location.

import { AssessmentError } from "./types";

export const AZURE_PROVIDER_NAME = "azure-speech-pronunciation-assessment";

/** The REST API for short audio documents a 60 s audio limit and 30 s for pronunciation assessment. */
export const MAX_ASSESSED_AUDIO_MS = 30_000;

const WAV_CONTENT_TYPE = "audio/wav; codecs=audio/pcm; samplerate=16000";
const TICKS_PER_MS = 10_000;

export interface AzureRequestOptions {
  /** Speech resource region such as "eastus". Used to build the regional host when baseUrl is absent. */
  region?: string;
  /** Full endpoint without query, e.g. https://<resource>.cognitiveservices.azure.com/stt/speech/recognition/conversation/cognitiveservices/v1. */
  baseUrl?: string;
  locale: string;
  referenceText: string;
}

export interface AzureRequestSpec {
  method: "POST";
  url: string;
  /** Excludes the subscription key: the caller adds Ocp-Apim-Subscription-Key from its secret store. */
  headers: Record<string, string>;
  /** The audio is sent as the request body; it must pass inspectWav first. */
}

function base64Utf8(text: string): string {
  let binary = "";
  for (const byte of new TextEncoder().encode(text)) binary += String.fromCharCode(byte);
  return btoa(binary);
}

/** Scripted, word-granularity, comprehensive (accuracy + fluency + completeness), miscue-enabled assessment on a 0-100 scale. */
export function buildAzureRequest(options: AzureRequestOptions): AzureRequestSpec {
  const host =
    options.baseUrl ??
    (options.region
      ? `https://${options.region}.stt.speech.microsoft.com/speech/recognition/conversation/cognitiveservices/v1`
      : undefined);
  if (!host) throw new AssessmentError("invalid_input", "Either baseUrl or region is required to build the Azure request");
  const parameters = {
    ReferenceText: options.referenceText,
    GradingSystem: "HundredMark",
    Granularity: "Word",
    Dimension: "Comprehensive",
    EnableMiscue: "True",
  };
  return {
    method: "POST",
    url: `${host}?language=${encodeURIComponent(options.locale)}&format=detailed`,
    headers: {
      Accept: "application/json",
      "Content-Type": WAV_CONTENT_TYPE,
      "Pronunciation-Assessment": base64Utf8(JSON.stringify(parameters)),
    },
  };
}

export interface WavInfo {
  durationMs: number;
}

/** Verifies the upload is 16 kHz mono 16-bit PCM WAV within the assessed limit and returns its duration. */
export function inspectWav(bytes: Uint8Array): WavInfo {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const tag = (offset: number) => String.fromCharCode(...bytes.subarray(offset, offset + 4));
  const fail = (message: string) => new AssessmentError("invalid_input", `Audio is not usable for assessment: ${message}`);
  if (bytes.byteLength < 12 || tag(0) !== "RIFF" || tag(8) !== "WAVE") throw fail("not a RIFF/WAVE file");

  let format: { channels: number; sampleRate: number; bits: number; code: number } | undefined;
  let offset = 12;
  while (offset + 8 <= bytes.byteLength) {
    const id = tag(offset);
    const size = view.getUint32(offset + 4, true);
    const body = offset + 8;
    if (id === "fmt ") {
      if (size < 16 || body + 16 > bytes.byteLength) throw fail("truncated fmt chunk");
      format = {
        code: view.getUint16(body, true),
        channels: view.getUint16(body + 2, true),
        sampleRate: view.getUint32(body + 4, true),
        bits: view.getUint16(body + 14, true),
      };
    } else if (id === "data") {
      if (!format) throw fail("data chunk precedes fmt chunk");
      if (format.code !== 1 || format.channels !== 1 || format.sampleRate !== 16_000 || format.bits !== 16) {
        throw fail(`expected 16 kHz mono 16-bit PCM, got code ${format.code}, ${format.channels} ch, ${format.sampleRate} Hz, ${format.bits}-bit`);
      }
      const available = bytes.byteLength - body;
      const dataBytes = size > available ? available : size;
      const durationMs = Math.round(dataBytes / 32);
      if (durationMs <= 0) throw fail("no audio samples");
      if (durationMs > MAX_ASSESSED_AUDIO_MS) throw fail(`${durationMs} ms exceeds the ${MAX_ASSESSED_AUDIO_MS} ms pronunciation-assessment limit`);
      return { durationMs };
    }
    offset = body + size + (size % 2);
  }
  throw fail("no data chunk");
}

// ---------------------------------------------------------------------------------------------------------
// Response parsing

export type RecognitionOutcome =
  | { kind: "unscorable"; reason: "no_speech" | "excessive_noise" | "insufficient_speech"; recognizedText: string | null; recognitionStatus: string }
  | { kind: "recognized"; recognition: AzureRecognition };

export interface AzureWord {
  word: string;
  errorType: string;
  /** Absent for omissions, which carry no audio. */
  startTicks: number | null;
  durationTicks: number | null;
  accuracyScore: number | null;
}

export interface AzureRecognition {
  recognitionStatus: "Success";
  displayText: string;
  accuracyScore: number;
  fluencyScore: number;
  completenessScore: number | null;
  snr: number | null;
  words: AzureWord[];
}

const invalid = (path: string, problem: string) =>
  new AssessmentError("invalid_provider_response", `Azure response field ${path} ${problem}`, { path });

type Json = Record<string, unknown>;

const isRecord = (value: unknown): value is Json => typeof value === "object" && value !== null && !Array.isArray(value);

function score(value: unknown, path: string): number {
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0 || value > 100) throw invalid(path, "must be a finite number from 0 through 100");
  return value;
}

/** Offset and Duration are documented as 100-nanosecond counts; the simple-format sample shows them as numeric strings. */
function ticks(value: unknown, path: string): number {
  const parsed = typeof value === "string" && /^\d+$/.test(value) ? Number(value) : value;
  if (typeof parsed !== "number" || !Number.isSafeInteger(parsed) || parsed < 0) throw invalid(path, "must be a non-negative integer tick count");
  return parsed;
}

/** Reads a score from the SDK-style nested PronunciationAssessment object or the REST sample's flat position. */
function field(node: Json, key: string): unknown {
  const nested = node.PronunciationAssessment;
  if (isRecord(nested) && key in nested) return nested[key];
  return node[key];
}

function parseWord(raw: unknown, index: number): AzureWord {
  const path = `NBest[0].Words[${index}]`;
  if (!isRecord(raw)) throw invalid(path, "must be an object");
  if (typeof raw.Word !== "string" || raw.Word === "") throw invalid(`${path}.Word`, "must be a non-empty string");
  const errorType = field(raw, "ErrorType");
  if (typeof errorType !== "string") throw invalid(`${path}.ErrorType`, "must be a string");
  if (errorType === "Omission") {
    return { word: raw.Word, errorType, startTicks: null, durationTicks: null, accuracyScore: null };
  }
  const durationTicks = ticks(raw.Duration, `${path}.Duration`);
  if (durationTicks === 0) throw invalid(`${path}.Duration`, "must be positive for a spoken word");
  const accuracy = field(raw, "AccuracyScore");
  return {
    word: raw.Word,
    errorType,
    startTicks: ticks(raw.Offset, `${path}.Offset`),
    durationTicks,
    // An inserted word has no reference phonemes to be scored against, so the service may omit its accuracy.
    accuracyScore: errorType === "Insertion" && accuracy === undefined ? null : score(accuracy, `${path}.AccuracyScore`),
  };
}

/** Parses a 200 response body. Missing required fields throw invalid_provider_response; they never become partial success. */
export function parseAzureResponse(body: unknown): RecognitionOutcome {
  if (!isRecord(body)) throw invalid("<body>", "must be a JSON object");
  const status = body.RecognitionStatus;
  if (typeof status !== "string") throw invalid("RecognitionStatus", "must be a string");

  switch (status) {
    case "InitialSilenceTimeout":
      return { kind: "unscorable", reason: "no_speech", recognizedText: null, recognitionStatus: status };
    case "BabbleTimeout":
      return { kind: "unscorable", reason: "excessive_noise", recognizedText: null, recognitionStatus: status };
    case "NoMatch":
      return { kind: "unscorable", reason: "insufficient_speech", recognizedText: null, recognitionStatus: status };
    case "Error":
      throw new AssessmentError("provider_unavailable", "Azure reported an internal recognition error", { recognitionStatus: status });
    case "Success":
      break;
    default:
      throw invalid("RecognitionStatus", "has an undocumented value");
  }

  if (!Array.isArray(body.NBest) || body.NBest.length === 0 || !isRecord(body.NBest[0])) throw invalid("NBest", "must be a non-empty array of objects");
  const best: Json = body.NBest[0];
  const display = typeof best.Display === "string" ? best.Display : body.DisplayText;
  if (typeof display !== "string") throw invalid("NBest[0].Display", "or DisplayText must be a string");
  if (!Array.isArray(best.Words)) throw invalid("NBest[0].Words", "must be an array");
  const completeness = field(best, "CompletenessScore");

  return {
    kind: "recognized",
    recognition: {
      recognitionStatus: "Success",
      displayText: display,
      accuracyScore: score(field(best, "AccuracyScore"), "NBest[0].AccuracyScore"),
      fluencyScore: score(field(best, "FluencyScore"), "NBest[0].FluencyScore"),
      completenessScore: completeness === undefined ? null : score(completeness, "NBest[0].CompletenessScore"),
      snr: typeof body.SNR === "number" && Number.isFinite(body.SNR) ? body.SNR : null,
      words: best.Words.map(parseWord),
    },
  };
}

/** Converts a documented 100-ns tick count to whole milliseconds; the end rounds up so a measured span never shrinks to zero. */
export const ticksToStartMs = (value: number): number => Math.floor(value / TICKS_PER_MS);
export const ticksToEndMs = (value: number): number => Math.ceil(value / TICKS_PER_MS);
