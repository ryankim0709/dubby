import { v } from "convex/values";

export const nullable = <T extends Parameters<typeof v.union>[0]>(validator: T) => v.union(validator, v.null());

export const textStatusV = v.union(
  v.literal("matched"),
  v.literal("substituted"),
  v.literal("omitted"),
  v.literal("inserted"),
);

export const measurementKindV = v.union(v.literal("acoustic"), v.literal("transcript_only"));

export const unscorableReasonV = v.union(
  v.literal("no_speech"),
  v.literal("excessive_noise"),
  v.literal("insufficient_speech"),
  v.literal("unsupported_locale"),
);

export const scoresV = v.object({
  languageOverall: nullable(v.number()),
  pronunciation: nullable(v.number()),
  wordAccuracy: nullable(v.number()),
  fluency: nullable(v.number()),
  timingFit: nullable(v.number()),
});

export const scoreMetricV = v.union(
  v.literal("languageOverall"),
  v.literal("pronunciation"),
  v.literal("wordAccuracy"),
  v.literal("fluency"),
  v.literal("timingFit"),
);

export const unavailableMetricV = v.object({
  metric: scoreMetricV,
  reason: v.union(
    v.literal("unsupported_locale"),
    v.literal("insufficient_evidence"),
    v.literal("missing_components"),
  ),
});

export const wordResultV = v.object({
  referenceWordIndex: nullable(v.number()),
  expected: nullable(v.string()),
  recognized: nullable(v.string()),
  textStatus: textStatusV,
  pronunciationScore: nullable(v.number()),
  pronunciationUnavailableReason: v.optional(
    v.union(
      v.literal("omitted_word"),
      v.literal("unaligned_word"),
      v.literal("unsupported_locale"),
      v.literal("insufficient_evidence"),
    ),
  ),
  startMs: nullable(v.number()),
  endMs: nullable(v.number()),
});

export const coachingV = v.object({
  summary: v.string(),
  strengths: v.array(v.string()),
  focus: v.array(
    v.object({
      kind: v.union(
        v.literal("pronunciation"),
        v.literal("word_accuracy"),
        v.literal("fluency"),
        v.literal("timing"),
      ),
      referenceWordIndex: nullable(v.number()),
      instruction: v.string(),
      practiceText: v.string(),
    }),
  ),
});

export const engineProvenanceV = v.object({
  provider: v.string(),
  providerModelVersion: nullable(v.string()),
  configVersion: v.string(),
  measurement: measurementKindV,
});

export const provenanceV = v.object({
  engine: engineProvenanceV,
  coaching: v.object({ provider: v.string(), configVersion: v.string() }),
});

const responseEnvelope = {
  schemaVersion: v.literal(1),
  rubricVersion: v.literal("language-v1"),
  assessmentId: v.string(),
  attemptId: v.string(),
  lineId: v.string(),
  referenceVersion: v.number(),
  locale: v.string(),
  recordedAt: v.string(),
  referenceText: v.string(),
  recognizedText: nullable(v.string()),
  measurement: measurementKindV,
};

export const evidenceV = v.object({
  provider: v.object({
    name: v.string(),
    locale: v.string(),
    recognitionStatus: v.string(),
    snr: nullable(v.number()),
    completenessScore: nullable(v.number()),
  }),
  normalizationVersion: v.string(),
  rawScores: v.object({
    pronunciation: nullable(v.number()),
    wordAccuracy: nullable(v.number()),
    fluency: nullable(v.number()),
    languageOverall: nullable(v.number()),
    timingFit: nullable(v.number()),
  }),
  referenceTokenCount: v.number(),
  counts: v.object({ matched: v.number(), substituted: v.number(), omitted: v.number(), inserted: v.number() }),
  words: v.object({
    mispronounced: v.array(v.number()),
    substituted: v.array(v.number()),
    omitted: v.array(v.number()),
    inserted: v.number(),
  }),
  timing: nullable(
    v.object({
      spokenStartMs: v.number(),
      spokenEndMs: v.number(),
      spokenDurationMs: v.number(),
      targetDurationMs: v.number(),
      deltaMs: v.number(),
    }),
  ),
  measurement: measurementKindV,
  unscorableReason: nullable(unscorableReasonV),
});

/** The validated engine result kept on the job so a coaching retry never re-spends the engine. */
export const outcomeV = v.object({
  response: v.union(
    v.object({
      ...responseEnvelope,
      status: v.literal("scored"),
      scores: scoresV,
      unavailableMetrics: v.array(unavailableMetricV),
      wordResults: v.array(wordResultV),
    }),
    v.object({
      ...responseEnvelope,
      status: v.literal("unscorable"),
      reason: unscorableReasonV,
      scores: v.null(),
      unavailableMetrics: v.array(unavailableMetricV),
      wordResults: v.array(wordResultV),
    }),
  ),
  evidence: evidenceV,
  provenance: engineProvenanceV,
});

export const jobErrorV = v.object({ code: v.string(), message: v.string(), retryable: v.boolean() });

export const jobStatusV = v.union(
  v.literal("queued"),
  v.literal("processing"),
  v.literal("succeeded"),
  v.literal("failed"),
);
export const jobStageV = v.union(v.literal("measure"), v.literal("coach"));

/** The grading-contract envelope the action assembles; the mutation adds the job id and completion time. */
export const assessmentBodyFields = {
  schemaVersion: v.literal(1),
  rubricVersion: v.literal("language-v1"),
  attemptId: v.id("attempts"),
  lineId: v.id("referenceLines"),
  referenceVersion: v.number(),
  locale: v.string(),
  recordedAt: v.string(),
  status: v.union(v.literal("scored"), v.literal("unscorable")),
  reason: v.optional(unscorableReasonV),
  referenceText: v.string(),
  recognizedText: nullable(v.string()),
  scores: nullable(scoresV),
  unavailableMetrics: v.array(unavailableMetricV),
  wordResults: v.array(wordResultV),
  coaching: coachingV,
  speakingDurationMs: nullable(v.number()),
  provenance: provenanceV,
};

/** The stored row and the client view add the owning job and completion time. */
export const assessmentContentFields = {
  ...assessmentBodyFields,
  jobId: v.id("assessmentJobs"),
  completedAt: v.number(),
};

export const assessmentViewV = v.object({
  assessmentId: v.id("assessments"),
  ...assessmentContentFields,
});

export const jobViewV = v.object({
  jobId: v.id("assessmentJobs"),
  kind: v.union(v.literal("initial"), v.literal("reassessment")),
  status: jobStatusV,
  stage: jobStageV,
  tries: v.number(),
  error: nullable(jobErrorV),
  assessmentId: nullable(v.id("assessments")),
  updatedAt: v.number(),
});
