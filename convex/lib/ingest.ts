import type { Doc } from "../_generated/dataModel";

/**
 * The payload the tutoring module ingests after an assessment is stored (section 1 of the tutoring
 * interface). Every value comes from backend-owned rows, never from the client.
 */
export type IngestAssessmentArgs = {
  assessment: {
    schemaVersion: 1;
    rubricVersion: "language-v1";
    assessmentId: string;
    attemptId: string;
    lineId: string;
    referenceVersion: number;
    locale: string;
    recordedAt: string;
    status: "scored" | "unscorable";
    reason?: string;
    referenceText: string;
    recognizedText: string | null;
    scores: Doc<"assessments">["scores"];
    unavailableMetrics: Doc<"assessments">["unavailableMetrics"];
    wordResults: Doc<"assessments">["wordResults"];
    coaching: Doc<"assessments">["coaching"];
  };
  attempt: {
    attemptId: string;
    ownerSubject: string;
    projectId: string;
    sceneId: string;
    characterId: string;
    capturedAt: string;
    receivedAt: string;
    timeZone: string;
    speakingDurationMs: number;
    recordingDurationMs: number;
  };
  provenance: {
    provider: string;
    modelVersion: string | null;
    configVersion: string;
    completedAt: string;
    measurement: "acoustic" | "transcript_only";
  };
};

export function buildIngestAssessmentArgs(input: {
  assessment: Doc<"assessments">;
  attempt: Doc<"attempts">;
  project: Doc<"projects">;
  ownerSubject: string;
}): IngestAssessmentArgs {
  const { assessment, attempt, project, ownerSubject } = input;
  return {
    assessment: {
      schemaVersion: assessment.schemaVersion,
      rubricVersion: assessment.rubricVersion,
      assessmentId: assessment._id,
      attemptId: assessment.attemptId,
      lineId: assessment.lineId,
      referenceVersion: assessment.referenceVersion,
      locale: assessment.locale,
      recordedAt: assessment.recordedAt,
      status: assessment.status,
      ...(assessment.reason === undefined ? {} : { reason: assessment.reason }),
      referenceText: assessment.referenceText,
      recognizedText: assessment.recognizedText,
      scores: assessment.scores,
      unavailableMetrics: assessment.unavailableMetrics,
      wordResults: assessment.wordResults,
      coaching: assessment.coaching,
    },
    attempt: {
      attemptId: attempt._id,
      ownerSubject,
      projectId: attempt.projectId,
      sceneId: project.sceneId,
      characterId: project.characterId,
      capturedAt: new Date(attempt.capturedAt).toISOString(),
      receivedAt: new Date(attempt.receivedAt).toISOString(),
      timeZone: attempt.timeZone,
      speakingDurationMs: Math.round(assessment.speakingDurationMs ?? 0),
      recordingDurationMs: attempt.durationMs,
    },
    provenance: {
      provider: assessment.provenance.engine.provider,
      modelVersion: assessment.provenance.engine.providerModelVersion,
      configVersion: assessment.provenance.engine.configVersion,
      completedAt: new Date(assessment.completedAt).toISOString(),
      measurement: assessment.provenance.engine.measurement,
    },
  };
}
