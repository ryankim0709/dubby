import { z } from "zod";

// Shapes follow https://docs.liveavatar.com/openapi.json and the official web SDK
// (github.com/heygen-com/liveavatar-web-sdk), checked 2026-11-15.
const apiBase = "https://api.liveavatar.com";
// Every LiveAvatar response wraps its payload as {code, data, message}; the web SDK treats 1000 as success.
const successCode = 1000;
// Sandbox sessions cost no credits but only run with this stock avatar and end after about a minute.
export const sandboxAvatarId = "dd73ea75-1218-4ef3-92ce-606d5f7fbc0a";

const maxAttempts = 3;

export class LiveAvatarError extends Error {}

const sessionTokenEnvelope = z.object({
  code: z.number(),
  message: z.string().optional(),
  data: z.object({ session_id: z.string().min(1), session_token: z.string().min(1) }),
});

export type SessionTokenRequest = {
  apiKey: string;
  avatarId: string;
  voiceId: string | undefined;
  /** Two-letter language code for the avatar's speech, such as "es". */
  language: string;
  isSandbox: boolean;
};

export type SessionToken = { sessionId: string; sessionToken: string };

/**
 * Mints a FULL-mode session token. The app then starts, keeps alive, and stops the session with that
 * short-lived token, as the official web SDK does, so the account API key never leaves the backend.
 * No context is attached: without one the avatar's built-in LLM doesn't answer, and it only speaks
 * the text the app sends it.
 */
export async function createSessionToken(request: SessionTokenRequest): Promise<SessionToken> {
  const body = {
    mode: "FULL",
    avatar_id: request.avatarId,
    is_sandbox: request.isSandbox,
    avatar_persona: {
      ...(request.voiceId === undefined ? {} : { voice_id: request.voiceId }),
      language: request.language,
    },
  };
  const json = await postWithRetry("create session token", `${apiBase}/v1/sessions/token`, {
    "X-API-KEY": request.apiKey,
  }, body);
  const envelope = sessionTokenEnvelope.safeParse(json);
  if (!envelope.success) {
    throw new LiveAvatarError(
      `create session token returned an unexpected body: ${envelope.error.message}`,
    );
  }
  if (envelope.data.code !== successCode) {
    throw new LiveAvatarError(
      `create session token failed with code ${envelope.data.code}: ${envelope.data.message ?? ""}`,
    );
  }
  return {
    sessionId: envelope.data.data.session_id,
    sessionToken: envelope.data.data.session_token,
  };
}

type Attempt =
  | { kind: "succeeded"; json: unknown }
  | { kind: "failed"; error: LiveAvatarError; retryable: boolean };

async function attemptPost(
  operation: string,
  url: string,
  headers: Record<string, string>,
  body: object,
): Promise<Attempt> {
  let response: Response;
  try {
    response = await fetch(url, {
      method: "POST",
      headers: { ...headers, "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
  } catch (error) {
    return { kind: "failed", error: new LiveAvatarError(`${operation} request failed: ${String(error)}`), retryable: true };
  }
  if (response.ok) {
    return { kind: "succeeded", json: await response.json() };
  }
  // Error bodies carry validation messages, not credentials, so they're safe to surface.
  const error = new LiveAvatarError(`${operation} failed with status ${response.status}: ${await response.text()}`);
  return { kind: "failed", error, retryable: response.status === 429 || response.status >= 500 };
}

/** Retries network failures, 429, and 5xx with exponential backoff, warning on each failed attempt. */
async function postWithRetry(
  operation: string,
  url: string,
  headers: Record<string, string>,
  body: object,
): Promise<unknown> {
  for (let attempt = 1; ; attempt += 1) {
    const result = await attemptPost(operation, url, headers, body);
    if (result.kind === "succeeded") {
      return result.json;
    }
    if (!result.retryable || attempt === maxAttempts) {
      throw result.error;
    }
    console.warn("liveavatar request failed, retrying", { operation, attempt, error: result.error.message });
    await new Promise((resolve) => setTimeout(resolve, 250 * 2 ** (attempt - 1)));
  }
}
