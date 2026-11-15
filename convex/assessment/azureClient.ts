// Thin Azure transport with bounded retries. It takes fetch and sleep as parameters so the backend action,
// tests and the live check share one code path. Keys and audio never reach the warning log.

import { buildAzureRequest, inspectWav } from "./azure";
import type { AzureRequestOptions } from "./azure";
import { AssessmentError } from "./types";

export interface RetryWarning {
  operation: "azure_pronunciation_assessment";
  attempt: number;
  maxAttempts: number;
  outcome: "http_status" | "network_error";
  httpStatus?: number;
  retryInMs: number;
}

export interface AzureClientOptions extends Omit<AzureRequestOptions, "referenceText" | "locale"> {
  /** Speech resource key from the deployment secrets. */
  key: string;
  fetch?: typeof fetch;
  sleep?: (ms: number) => Promise<void>;
  maxAttempts?: number;
  baseDelayMs?: number;
  warn?: (warning: RetryWarning) => void;
}

export interface AzureAssessmentCall {
  locale: string;
  referenceText: string;
  /** 16 kHz mono 16-bit PCM WAV, at most 30 seconds. */
  wav: Uint8Array;
}

/** Retries network failures, 408, 429 and 5xx with exponential backoff; every other status returns at once. */
export async function requestAzureAssessment(
  options: AzureClientOptions,
  call: AzureAssessmentCall,
): Promise<{ httpStatus: number; body: unknown; durationMs: number }> {
  const { durationMs } = inspectWav(call.wav);
  const spec = buildAzureRequest({ ...options, locale: call.locale, referenceText: call.referenceText });
  const doFetch = options.fetch ?? fetch;
  const sleep = options.sleep ?? ((ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms)));
  const maxAttempts = options.maxAttempts ?? 3;
  const baseDelayMs = options.baseDelayMs ?? 500;

  for (let attempt = 1; ; attempt++) {
    const retryInMs = baseDelayMs * 2 ** (attempt - 1);
    const last = attempt === maxAttempts;
    let status: number | undefined;
    let text = "";
    try {
      const response = await doFetch(spec.url, {
        method: spec.method,
        headers: { ...spec.headers, "Ocp-Apim-Subscription-Key": options.key },
        body: call.wav.slice(),
      });
      status = response.status;
      text = await response.text();
    } catch {
      if (last) throw new AssessmentError("provider_unavailable", "Azure could not be reached", { attempts: attempt });
      options.warn?.({ operation: "azure_pronunciation_assessment", attempt, maxAttempts, outcome: "network_error", retryInMs });
      await sleep(retryInMs);
      continue;
    }

    const transient = status === 408 || status === 429 || status >= 500;
    if (transient && !last) {
      options.warn?.({ operation: "azure_pronunciation_assessment", attempt, maxAttempts, outcome: "http_status", httpStatus: status, retryInMs });
      await sleep(retryInMs);
      continue;
    }
    let body: unknown;
    try {
      body = text === "" ? undefined : JSON.parse(text);
    } catch {
      body = undefined;
    }
    return { httpStatus: status, body, durationMs };
  }
}
