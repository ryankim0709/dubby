import { createAzureEngine } from "./azureEngine";
import { tutoringCoachingProvider } from "../tutoringCoaching";
import type { AssessmentEngine, CoachingProvider } from "./contracts";

// The engine and coaching implementations register here. With none registered, jobs end in the
// explicit retryable failures engine_not_configured and coach_not_configured; nothing is faked.

function setEnv(name: string): string | undefined {
  const value = process.env[name];
  return value === undefined || value.length === 0 ? undefined : value;
}

/** Azure pronunciation assessment, when AZURE_SPEECH_KEY and a region or endpoint are set. */
export function getAssessmentEngine(): AssessmentEngine | null {
  const key = setEnv("AZURE_SPEECH_KEY");
  const region = setEnv("AZURE_SPEECH_REGION");
  const baseUrl = setEnv("AZURE_SPEECH_ENDPOINT");
  if (key === undefined || (region === undefined && baseUrl === undefined)) return null;
  return createAzureEngine({ key, region, baseUrl });
}

export function getCoachingProvider(): CoachingProvider | null {
  return tutoringCoachingProvider;
}
