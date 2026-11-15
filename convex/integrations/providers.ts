import type { AssessmentEngine, CoachingProvider } from "./contracts";

// The engine and coaching implementations register here. With none registered, jobs end in the
// explicit retryable failures engine_not_configured and coach_not_configured; nothing is faked.

export function getAssessmentEngine(): AssessmentEngine | null {
  return null;
}

export function getCoachingProvider(): CoachingProvider | null {
  return null;
}
