import { cronJobs } from "convex/server";
import { internal } from "./_generated/api";

const crons = cronJobs();

crons.interval("return stale assessment jobs to the queue", { minutes: 2 }, internal.assessments.reclaimStale, {});

export default crons;
