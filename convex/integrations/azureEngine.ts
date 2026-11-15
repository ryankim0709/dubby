import { assessAttempt, requestAzureAssessment } from "../assessment";
import { logEvent } from "../lib/log";
import type { AssessmentEngine } from "./contracts";

export type AzureEngineConfig = {
  key: string;
  /** Speech resource region such as "eastus". Ignored when baseUrl is set. */
  region?: string;
  /** Full recognition endpoint without a query string, for resources with a custom domain. */
  baseUrl?: string;
  fetch?: typeof fetch;
  sleep?: (ms: number) => Promise<void>;
};

/**
 * Scores a recording with Azure pronunciation assessment. The adapter inspects the WAV (16 kHz mono
 * PCM, at most 30 s), calls the service with bounded retries, and turns the response into the
 * contract outcome; this only connects it to the job runner. Retry warnings carry the job id and
 * status code, never the key, the audio, or the transcript.
 */
export function createAzureEngine(config: AzureEngineConfig): AssessmentEngine {
  return {
    assess: async (input, audio) => {
      const call = await requestAzureAssessment(
        {
          key: config.key,
          region: config.region,
          baseUrl: config.baseUrl,
          fetch: config.fetch,
          sleep: config.sleep,
          warn: (warning) =>
            logEvent({
              operation: warning.operation,
              status: "retrying",
              errorCode: warning.outcome,
              httpStatus: warning.httpStatus,
              jobId: input.assessmentId,
              attemptId: input.attemptId,
              tries: warning.attempt,
            }),
        },
        { locale: input.locale, referenceText: input.referenceText, wav: new Uint8Array(await audio.arrayBuffer()) },
      );
      return assessAttempt({ ...input, recordingDurationMs: call.durationMs, provider: { httpStatus: call.httpStatus, body: call.body } });
    },
  };
}
