export type LogEvent = {
  operation: string;
  status: "ok" | "rejected" | "retrying" | "failed" | "skipped";
  errorCode?: string;
  httpStatus?: number;
  userId?: string;
  projectId?: string;
  attemptId?: string;
  jobId?: string;
  assessmentId?: string;
  stage?: string;
  tries?: number;
  retryable?: boolean;
  count?: number;
};

/**
 * One JSON line per operation outcome or failed try. The type is a closed allow-list of ids and
 * codes so a tokens, keys, audio, or transcript text can't be logged by accident.
 */
export function logEvent(event: LogEvent): void {
  const line = JSON.stringify({ app: "dubit-backend", ...event });
  if (event.status === "failed" || event.status === "retrying") console.warn(line);
  else console.log(line);
}
