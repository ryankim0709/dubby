import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { api, internal } from "./_generated/api";
import { AssessmentError, CoachingError } from "./integrations/contracts";
import type { AssessAttemptInput, AssessmentOutcome, Coaching, EngineProvenance } from "./integrations/contracts";
import { buildIngestAssessmentArgs } from "./lib/ingest";
import {
  type World,
  acousticProvenance,
  alice,
  coachingFixture,
  doubles,
  drain,
  engineDouble,
  expectAppError,
  record,
  scoredOutcome,
  startWorld,
  unscorableOutcome,
} from "./test.helpers";

vi.mock("./integrations/providers", async () => {
  const { doubles: current } = await import("./test.helpers");
  return { getAssessmentEngine: () => current.engine, getCoachingProvider: () => current.coach };
});

let engineCalls = 0;
let coachCalls = 0;

function plugInDoubles(
  overrides: {
    assess?: (input: AssessAttemptInput) => AssessmentOutcome | Promise<AssessmentOutcome>;
    coach?: () => Promise<Coaching>;
    provenance?: EngineProvenance;
  } = {},
) {
  const assess = overrides.assess ?? scoredOutcome;
  doubles.engine = engineDouble(async (input) => {
    engineCalls += 1;
    return await assess(input);
  }, overrides.provenance);
  doubles.coach = {
    coach: async () => {
      coachCalls += 1;
      return await (overrides.coach ?? (async () => coachingFixture()))();
    },
  };
}

async function startAttempt(world: World) {
  const { projectId } = await world.a.mutation(api.projects.start, { sceneId: world.sceneId, characterId: world.characterA });
  const created = await record(world.t, world.a, { projectId, lineId: world.line1 });
  return { projectId, ...created };
}

async function jobOf(world: World, jobId: Awaited<ReturnType<typeof startAttempt>>["jobId"]) {
  return await world.t.run(async (ctx) => await ctx.db.get("assessmentJobs", jobId));
}

beforeEach(() => {
  vi.useFakeTimers();
  engineCalls = 0;
  coachCalls = 0;
  doubles.engine = null;
  doubles.coach = null;
});
afterEach(() => {
  vi.useRealTimers();
});

describe("assessment jobs", () => {
  it("stores one scored assessment with the engine's totals and full provenance", async () => {
    const world = await startWorld();
    plugInDoubles();
    const { attemptId, jobId } = await startAttempt(world);
    await drain(world.t);

    const result = await world.a.query(api.assessments.forAttempt, { attemptId });
    expect(result?.job).toMatchObject({ jobId, status: "succeeded", tries: 1, error: null });
    expect(result?.assessment).toMatchObject({
      status: "scored",
      scores: { languageOverall: 88, pronunciation: 82, wordAccuracy: 100, fluency: 80, timingFit: 90 },
      recognizedText: "You underestimate my power.",
      referenceVersion: 1,
      locale: "en-US",
      speakingDurationMs: 2700,
      provenance: { engine: { provider: "test-double", providerModelVersion: null, measurement: "acoustic" }, coaching: { provider: "test-double" } },
    });
    expect(result?.assessment?.assessmentId).toBe((await jobOf(world, jobId))?.assessmentId);
  });

  it("hands the engine only backend-resolved facts", async () => {
    const world = await startWorld();
    let seen: AssessAttemptInput | undefined;
    plugInDoubles({
      assess: (input) => {
        seen = input;
        return scoredOutcome(input);
      },
    });
    const { attemptId, jobId } = await startAttempt(world);
    await drain(world.t);
    expect(seen).toMatchObject({
      assessmentId: jobId,
      attemptId,
      lineId: world.line1,
      referenceVersion: 1,
      locale: "en-US",
      referenceText: "You underestimate my power.",
      targetWindowMs: { startMs: 1000, endMs: 4000 },
      recordingDurationMs: 3500,
    });
    expect(seen?.provider).toBeUndefined();
  });

  it("builds the tutoring ingestion payload from stored rows only", async () => {
    const world = await startWorld();
    plugInDoubles();
    const { attemptId, projectId } = await startAttempt(world);
    await drain(world.t);
    const args = await world.t.run(async (ctx) => {
      const assessment = (await ctx.db.query("assessments").first())!;
      const attempt = (await ctx.db.get("attempts", attemptId))!;
      const project = (await ctx.db.get("projects", projectId))!;
      return buildIngestAssessmentArgs({ assessment, attempt, project, ownerSubject: alice.tokenIdentifier });
    });
    expect(args.assessment).toMatchObject({
      schemaVersion: 1,
      rubricVersion: "language-v1",
      attemptId,
      lineId: world.line1,
      status: "scored",
      scores: { languageOverall: 88 },
      coaching: { focus: [{ kind: "pronunciation", practiceText: "underestimate" }] },
    });
    expect(args.assessment.assessmentId).toEqual(expect.any(String));
    expect(args.attempt).toMatchObject({
      attemptId,
      ownerSubject: alice.tokenIdentifier,
      projectId,
      sceneId: world.sceneId,
      characterId: world.characterA,
      timeZone: "America/Los_Angeles",
      speakingDurationMs: 2700,
      recordingDurationMs: 3500,
    });
    expect(args.assessment.recordedAt).toBe(args.attempt.capturedAt);
    expect(args.provenance).toMatchObject({ provider: "test-double", modelVersion: null, configVersion: "test-1", measurement: "acoustic" });
    expect(Number.isNaN(Date.parse(args.provenance.completedAt))).toBe(false);
  });

  it("fails explicitly and retryably when no engine is configured, then succeeds on retry without a new attempt", async () => {
    const world = await startWorld();
    const { attemptId, jobId } = await startAttempt(world);
    await drain(world.t);

    const failed = await jobOf(world, jobId);
    expect(failed).toMatchObject({ status: "failed", tries: 1, error: { code: "engine_not_configured", retryable: true } });
    expect(await world.a.query(api.assessments.forAttempt, { attemptId })).toMatchObject({ assessment: null });

    plugInDoubles();
    await world.a.mutation(api.assessments.retry, { jobId });
    await drain(world.t);

    expect(await jobOf(world, jobId)).toMatchObject({ status: "succeeded" });
    const counts = await world.t.run(async (ctx) => ({
      attempts: (await ctx.db.query("attempts").collect()).length,
      jobs: (await ctx.db.query("assessmentJobs").collect()).length,
      assessments: (await ctx.db.query("assessments").collect()).length,
    }));
    expect(counts).toEqual({ attempts: 1, jobs: 1, assessments: 1 });
  });

  it("retries provider_unavailable with backoff, then lands in a retryable failed state", async () => {
    const world = await startWorld();
    plugInDoubles({ assess: () => { throw new AssessmentError("provider_unavailable", "fixture outage"); } });
    const { jobId } = await startAttempt(world);
    await drain(world.t);

    expect(engineCalls).toBe(3);
    expect(await jobOf(world, jobId)).toMatchObject({ status: "failed", tries: 3, error: { code: "provider_unavailable", retryable: true } });

    plugInDoubles();
    await world.a.mutation(api.assessments.retry, { jobId });
    await drain(world.t);
    expect(await jobOf(world, jobId)).toMatchObject({ status: "succeeded", tries: 1 });
    expect(await world.t.run(async (ctx) => (await ctx.db.query("attempts").collect()).length)).toBe(1);
  });

  it("recovers when a transient failure clears within the retry budget", async () => {
    const world = await startWorld();
    let calls = 0;
    plugInDoubles({
      assess: (input) => {
        calls += 1;
        if (calls === 1) throw new AssessmentError("provider_unavailable", "fixture");
        return scoredOutcome(input);
      },
    });
    const { jobId } = await startAttempt(world);
    await drain(world.t);
    expect(await jobOf(world, jobId)).toMatchObject({ status: "succeeded", tries: 2 });
  });

  it.each(["invalid_input", "invalid_reference", "provider_auth", "provider_rejected", "invalid_provider_response"] as const)(
    "does not retry %s and refuses an owner retry",
    async (kind) => {
      const world = await startWorld();
      plugInDoubles({ assess: () => { throw new AssessmentError(kind, "fixture"); } });
      const { jobId } = await startAttempt(world);
      await drain(world.t);
      expect(engineCalls).toBe(1);
      expect(await jobOf(world, jobId)).toMatchObject({ status: "failed", error: { code: kind, retryable: false } });
      await expectAppError(world.a.mutation(api.assessments.retry, { jobId }), "INVALID_STATE");
    },
  );

  it("fails permanently when the engine breaks the output contract", async () => {
    const world = await startWorld();
    plugInDoubles({ assess: () => ({ response: {} }) as never });
    const { jobId } = await startAttempt(world);
    await drain(world.t);
    expect(await jobOf(world, jobId)).toMatchObject({ status: "failed", error: { code: "invalid_engine_output", retryable: false } });
  });

  it("fails permanently when the engine describes a different attempt", async () => {
    const world = await startWorld();
    plugInDoubles({ assess: (input) => scoredOutcome({ ...input, attemptId: "someone-elses-attempt" }) });
    const { jobId } = await startAttempt(world);
    await drain(world.t);
    expect(await jobOf(world, jobId)).toMatchObject({ status: "failed", error: { code: "invalid_engine_output", retryable: false } });
  });

  it("never stores a pronunciation value from a transcript-only measurement", async () => {
    const world = await startWorld();
    plugInDoubles({ provenance: { ...acousticProvenance, measurement: "transcript_only" } });
    const { jobId } = await startAttempt(world);
    await drain(world.t);
    expect(await jobOf(world, jobId)).toMatchObject({ status: "failed", error: { code: "invalid_engine_output", retryable: false } });
    expect(await world.t.run(async (ctx) => (await ctx.db.query("assessments").collect()).length)).toBe(0);
  });

  it("stores a transcript-only result whose pronunciation values are all null", async () => {
    const world = await startWorld();
    plugInDoubles({
      provenance: { ...acousticProvenance, measurement: "transcript_only" },
      assess: (input) => {
        const outcome = scoredOutcome(input);
        outcome.response.scores = { languageOverall: null, pronunciation: null, wordAccuracy: 100, fluency: null, timingFit: 90 };
        outcome.response.unavailableMetrics = [
          { metric: "languageOverall", reason: "missing_components" },
          { metric: "pronunciation", reason: "insufficient_evidence" },
          { metric: "fluency", reason: "insufficient_evidence" },
        ];
        for (const word of outcome.response.wordResults) {
          word.pronunciationScore = null;
          word.pronunciationUnavailableReason = "insufficient_evidence";
        }
        return outcome;
      },
    });
    const { attemptId } = await startAttempt(world);
    await drain(world.t);
    const result = await world.a.query(api.assessments.forAttempt, { attemptId });
    expect(result?.assessment).toMatchObject({
      scores: { pronunciation: null, languageOverall: null, wordAccuracy: 100 },
      provenance: { engine: { measurement: "transcript_only" } },
    });
  });

  it("retrying a coaching-stage failure reuses the stored outcome and never calls the engine again", async () => {
    const world = await startWorld();
    plugInDoubles();
    doubles.coach = null;
    const { jobId } = await startAttempt(world);
    await drain(world.t);

    expect(engineCalls).toBe(1);
    expect(await jobOf(world, jobId)).toMatchObject({ status: "failed", stage: "coach", error: { code: "coach_not_configured", retryable: true } });

    plugInDoubles();
    await world.a.mutation(api.assessments.retry, { jobId });
    await drain(world.t);
    expect(engineCalls).toBe(1);
    expect(coachCalls).toBe(1);
    expect(await jobOf(world, jobId)).toMatchObject({ status: "succeeded" });
  });

  it("rejects coaching that cites a word outside the reference", async () => {
    const world = await startWorld();
    plugInDoubles({
      coach: async () => coachingFixture({ focus: [{ kind: "word_accuracy", referenceWordIndex: 9, instruction: "x", practiceText: "y" }] }),
    });
    const { jobId } = await startAttempt(world);
    await drain(world.t);
    expect(await jobOf(world, jobId)).toMatchObject({ status: "failed", error: { code: "invalid_coaching_output", retryable: false } });
  });

  it("surfaces a coaching provider failure as retryable without calling the engine again", async () => {
    const world = await startWorld();
    plugInDoubles({ coach: async () => { throw new CoachingError("coach_down", "fixture", true); } });
    const { jobId } = await startAttempt(world);
    await drain(world.t);
    expect(coachCalls).toBe(3);
    expect(engineCalls).toBe(1);
    expect(await jobOf(world, jobId)).toMatchObject({ status: "failed", error: { code: "coach_down", retryable: true } });
  });

  it("stores an unscorable result as a successful assessment, not a failure", async () => {
    const world = await startWorld();
    plugInDoubles({
      assess: unscorableOutcome,
      coach: async () => coachingFixture({ strengths: [], focus: [], summary: "We couldn't hear speech. Try again closer to the microphone." }),
    });
    const { attemptId } = await startAttempt(world);
    await drain(world.t);
    const result = await world.a.query(api.assessments.forAttempt, { attemptId });
    expect(result?.job?.status).toBe("succeeded");
    expect(result?.assessment).toMatchObject({
      status: "unscorable",
      reason: "no_speech",
      scores: null,
      wordResults: [],
      unavailableMetrics: [],
      recognizedText: null,
      speakingDurationMs: null,
    });
  });

  it("a regrade creates a new job and a new assessment id for the same attempt", async () => {
    const world = await startWorld();
    plugInDoubles();
    const { attemptId, jobId } = await startAttempt(world);
    await drain(world.t);
    const first = await world.a.query(api.assessments.forAttempt, { attemptId });

    const regrade = await world.t.mutation(internal.assessments.reassess, { attemptId });
    await drain(world.t);
    const second = await world.a.query(api.assessments.forAttempt, { attemptId });

    expect(regrade.jobId).not.toBe(jobId);
    expect(second?.job).toMatchObject({ jobId: regrade.jobId, kind: "reassessment", status: "succeeded" });
    expect(second?.assessment?.assessmentId).not.toBe(first?.assessment?.assessmentId);
    expect(engineCalls).toBe(2);
    expect(
      await world.t.run(async (ctx) => ({
        attempts: (await ctx.db.query("attempts").collect()).length,
        assessments: (await ctx.db.query("assessments").collect()).length,
      })),
    ).toEqual({ attempts: 1, assessments: 2 });
  });

  it("refuses a regrade while a job is still in progress", async () => {
    const world = await startWorld();
    const { attemptId } = await startAttempt(world);
    await expectAppError(world.t.mutation(internal.assessments.reassess, { attemptId }), "INVALID_STATE");
  });

  it("returns a job whose lease expired to the queue, and fails it visibly once tries are spent", async () => {
    const world = await startWorld();
    plugInDoubles();
    const { jobId } = await startAttempt(world);
    await world.t.run(async (ctx) => {
      await ctx.db.patch(jobId, { status: "processing", tries: 1, leaseExpiresAt: Date.now() - 1 });
    });
    expect(await world.t.mutation(internal.assessments.reclaimStale, {})).toBe(1);
    await drain(world.t);
    expect(await jobOf(world, jobId)).toMatchObject({ status: "succeeded" });

    const second = await world.t.mutation(internal.assessments.reassess, { attemptId: (await jobOf(world, jobId))!.attemptId });
    await world.t.run(async (ctx) => {
      await ctx.db.patch(second.jobId, { status: "processing", tries: 3, leaseExpiresAt: Date.now() - 1 });
    });
    await world.t.mutation(internal.assessments.reclaimStale, {});
    expect(await jobOf(world, second.jobId)).toMatchObject({ status: "failed", error: { code: "lease_expired", retryable: true } });
  });

  it("ignores writes from an action whose lease was lost", async () => {
    const world = await startWorld();
    const { jobId } = await startAttempt(world);
    const claim = await world.t.mutation(internal.assessments.claim, { jobId });
    expect(claim).not.toBeNull();
    const stale = await world.t.mutation(internal.assessments.recordFailure, {
      jobId,
      lease: claim!.lease + 1,
      failure: { code: "x", message: "x", retryable: false, autoRetry: false },
    });
    expect(stale).toBe("stale");
    expect(await jobOf(world, jobId)).toMatchObject({ status: "processing" });
  });
});
