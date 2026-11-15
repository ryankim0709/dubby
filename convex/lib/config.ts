/** Limits and timings shared by the backend. Recording limits follow contract v1 section 5. */

/** Assessment audio is 16 kHz mono 16-bit PCM WAV; the engine rejects other encodings as invalid_input. */
export const ACCEPTED_AUDIO_TYPES = ["audio/wav"] as const;
export const MAX_UPLOAD_BYTES = 10 * 1024 * 1024;
export const MAX_RECORDING_MS = 30_000;

/** A capture time may lead the server clock by this much (client clock skew). */
export const CAPTURED_AT_FUTURE_SKEW_MS = 5 * 60_000;
/** A capture time may trail the server clock by this much (recordings queued while offline). */
export const CAPTURED_AT_MAX_AGE_MS = 30 * 24 * 60 * 60_000;

export const MAX_JOB_TRIES = 3;
export const BACKOFF_BASE_MS = 2_000;
export const LEASE_MS = 5 * 60_000;

/** Slack between the client-reported recording length and engine word boundaries (rounding in the client's reported length). */
export const WORD_BOUNDARY_TOLERANCE_MS = 250;

export const RUBRIC_VERSION = "language-v1";
export const SCHEMA_VERSION = 1;
