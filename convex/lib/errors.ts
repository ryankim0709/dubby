import { ConvexError } from "convex/values";

export type AppErrorCode =
  | "UNAUTHENTICATED"
  | "USER_NOT_FOUND"
  | "NOT_FOUND"
  | "INVALID_ARGUMENT"
  | "INVALID_UPLOAD"
  | "CONFLICT"
  | "INVALID_STATE"
  | "INCOMPLETE_TAKES";

export type AppErrorData = { code: AppErrorCode; message: string; missingLineKeys?: string[] };

/** Clients branch on `data.code`; the message is for humans and never carries private content. */
export function appError(code: AppErrorCode, message: string, extra: { missingLineKeys?: string[] } = {}) {
  const data: AppErrorData = { code, message, ...extra };
  return new ConvexError(data);
}
