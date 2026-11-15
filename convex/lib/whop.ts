import { WhopClient, WhopEnvironment, WhopError, WhopTimeoutError } from "@whop/sdk";
import { requiredEnv } from "./env";
import { logEvent } from "./log";

export function createWhopClient(): WhopClient {
  return new WhopClient({
    token: requiredEnv("WHOP_API_KEY"),
    environment: process.env.WHOP_SANDBOX === "true" ? WhopEnvironment.Sandbox : WhopEnvironment.Production,
    apiVersionDate: "2026-11-13-1",
    maxRetries: 0,
    timeoutInSeconds: 10,
  });
}

export async function whopRequest<T>(operation: string, request: () => Promise<T>): Promise<T> {
  for (let attempt = 1; ; attempt += 1) {
    try {
      return await request();
    } catch (error) {
      if (!(error instanceof WhopError)) throw error;
      const retryable = error instanceof WhopTimeoutError || error.statusCode === undefined || error.statusCode === 408 || error.statusCode === 429 || error.statusCode >= 500;
      logEvent({ operation, status: retryable && attempt < 3 ? "retrying" : "failed", tries: attempt, httpStatus: error.statusCode, retryable });
      if (!retryable || attempt === 3) throw error;
      await new Promise<void>((resolve) => setTimeout(resolve, 250 * 2 ** (attempt - 1)));
    }
  }
}
