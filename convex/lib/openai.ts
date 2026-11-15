import OpenAI from "openai";
import { requiredEnv } from "./env";

/** Bounded so a stalled provider can't hold a Convex action open: two SDK retries, 30 s per request. */
const MAX_RETRIES = 2;
const REQUEST_TIMEOUT_MS = 30_000;

/**
 * The one place an OpenAI client is built. It makes no model choice; each workload's owner picks
 * models for the Responses API. Throws ConfigurationError (a 503 in the router) when the key is unset.
 */
export function createOpenAIClient(): OpenAI {
  return new OpenAI({ apiKey: requiredEnv("OPENAI_API_KEY"), maxRetries: MAX_RETRIES, timeout: REQUEST_TIMEOUT_MS });
}

/**
 * Describes a failed OpenAI call for a 502 response and its log line: the status only. A provider
 * error body can echo request content or credentials, so it is never surfaced.
 */
export function describeOpenAIFailure(error: unknown): { status: number | null; message: string } | null {
  if (!(error instanceof OpenAI.APIError)) return null;
  const status = error.status ?? null;
  return { status, message: status === null ? "OpenAI request failed: no response from the provider" : `OpenAI request failed with status ${status}` };
}
