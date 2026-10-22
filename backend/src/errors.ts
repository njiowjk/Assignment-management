export type ErrorCode = "invalidURL" | "invalidCalendar" | "unsupportedCalendar" |
  "network" | "authentication" | "server" | "tooLarge" | "backend" | "notConfigured" | "moodleLoginRequired";

export class BackendError extends Error {
  constructor(readonly code: ErrorCode) { super(code); }
}

export function safeError(error: unknown): ErrorCode {
  return error instanceof BackendError ? error.code : "backend";
}
