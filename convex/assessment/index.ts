// Public surface of the pronunciation-assessment adapter. See docs/assessment.md.
export { assessAttempt, computeLanguageOverall, computeTimingFit, BOUNDARY_TOLERANCE_MS } from "./assess";
export type { AssessAttemptInput, AssessmentEvidence, AssessmentOutcome } from "./assess";
export { buildAzureRequest, inspectWav, MAX_ASSESSED_AUDIO_MS, AZURE_PROVIDER_NAME } from "./azure";
export type { AzureRequestOptions, AzureRequestSpec, WavInfo } from "./azure";
export { requestAzureAssessment } from "./azureClient";
export type { AzureAssessmentCall, AzureClientOptions, RetryWarning } from "./azureClient";
export { validateAssessmentResponse } from "./validate";
export type { ValidationOptions } from "./validate";
export { NORMALIZATION_VERSION, SUPPORTED_LOCALES, tokenize } from "./normalize";
export { AssessmentError, AssessmentValidationError, RUBRIC_VERSION, SCHEMA_VERSION } from "./types";
export type * from "./types";
