import { z } from "zod";

export class SimliError extends Error {}

const tokenSchema = z.object({ session_token: z.string().min(1), warnings: z.array(z.string()).optional() });

export type SimliSession = { sessionToken: string };

/** Only the short-lived session token reaches the iPhone; the face and API key stay on the server. */
export async function createSimliSession(apiKey: string, faceId: string): Promise<SimliSession> {
  for (let attempt = 1; ; attempt += 1) {
    let response: Response;
    try {
      response = await fetch("https://api.simli.ai/compose/token", {
        method: "POST",
        headers: { "Content-Type": "application/json", "x-simli-api-key": apiKey },
        body: JSON.stringify({ faceId, handleSilence: true, maxSessionLength: 600, maxIdleTime: 180 }),
        signal: AbortSignal.timeout(10_000),
      });
    } catch (error) {
      if (!(error instanceof TypeError) && !(error instanceof DOMException && (error.name === "TimeoutError" || error.name === "AbortError"))) throw error;
      const failure = new SimliError(`Creating Simli session for face ${faceId} failed: ${error.message.replaceAll(apiKey, "[redacted]")}`);
      console.warn("Simli session request failed", { faceId, attempt, error: failure.message });
      if (attempt === 3) throw failure;
      await new Promise<void>((resolve) => setTimeout(resolve, 250 * 2 ** (attempt - 1)));
      continue;
    }
    if (!response.ok) {
      const body = (await response.text())
        .replaceAll(apiKey, "[redacted]")
        .replace(/("session_token"\s*:\s*")[^"]*"/g, '$1[redacted]"');
      const failure = new SimliError(`Creating Simli session for face ${faceId} failed with status ${response.status}: ${body}`);
      console.warn("Simli session request failed", { faceId, attempt, status: response.status });
      if (attempt === 3 || (response.status !== 429 && response.status < 500)) throw failure;
      await new Promise<void>((resolve) => setTimeout(resolve, 250 * 2 ** (attempt - 1)));
      continue;
    }
    let body: z.infer<typeof tokenSchema>;
    try {
      body = tokenSchema.parse(await response.json());
    } catch (error) {
      if (!(error instanceof z.ZodError) && !(error instanceof SyntaxError)) throw error;
      throw new SimliError(`Creating Simli session for face ${faceId} returned invalid session data (status ${response.status})`);
    }
    for (const warning of body.warnings ?? []) {
      console.warn("Simli session configuration warning", { faceId, warning: warning.replaceAll(apiKey, "[redacted]") });
    }
    return { sessionToken: body.session_token };
  }
}
