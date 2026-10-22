import { BackendError } from "./errors.js";
import type { RemoteTask, TaskItem, TaskSource } from "./models.js";

export function record(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new BackendError("backend");
  return value as Record<string, unknown>;
}

export function text(value: unknown): string {
  if (typeof value !== "string" || value.length === 0) throw new BackendError("backend");
  return value;
}

export function timestamp(value: unknown): number {
  if (typeof value !== "number" || !Number.isFinite(value) || Math.abs(value) > 8.64e15) {
    throw new BackendError("backend");
  }
  return value;
}

export function source(value: unknown): TaskSource {
  if (value !== "Moodle" && value !== "WebClass") throw new BackendError("backend");
  return value;
}

function optionalString(value: unknown): void {
  if (value != null && typeof value !== "string") throw new BackendError("backend");
}

export function remoteTasks(value: unknown): RemoteTask[] {
  if (!Array.isArray(value) || value.length > 50_000) throw new BackendError("backend");
  for (const item of value) {
    const row = record(item);
    text(row.externalID); source(row.source); text(row.courseName); text(row.title); timestamp(row.deadline);
    optionalString(row.detail); optionalString(row.sourceURL);
    if (row.isCompleted != null && typeof row.isCompleted !== "boolean") throw new BackendError("backend");
    if (row.isRemovedFromSource != null && typeof row.isRemovedFromSource !== "boolean") throw new BackendError("backend");
  }
  return value as RemoteTask[];
}

export function localTasks(value: unknown): TaskItem[] {
  remoteTasks(value);
  for (const item of value as unknown[]) {
    const row = record(item);
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(text(row.id))) {
      throw new BackendError("backend");
    }
    timestamp(row.firstDetectedAt); timestamp(row.lastSyncedAt);
    if (row.completedAt != null) timestamp(row.completedAt);
    if (!["active", "overdue", "completed", "unavailable"].includes(text(row.status)) ||
        typeof row.completionIsKnown !== "boolean" || typeof row.isRemovedFromSource !== "boolean") {
      throw new BackendError("backend");
    }
  }
  return value as TaskItem[];
}

export function calendarURL(value: unknown): URL {
  if (typeof value !== "string") throw new BackendError("invalidURL");
  const trimmed = value.trim();
  try {
    const url = new URL(trimmed);
    if (!/^https:\/\/[^/\\]/i.test(trimmed) || url.protocol !== "https:" || !url.hostname ||
        url.username || url.password || trimmed.includes("#") || /[\s\\]/.test(trimmed)) throw new Error();
    return url;
  } catch { throw new BackendError("invalidURL"); }
}

export function safePageURL(value: string): string | null {
  try {
    const url = calendarURL(value);
    const secrets = /^(authtoken|token|password|session|sesskey|key)$/i;
    if ([...url.searchParams.keys()].some(key => secrets.test(key))) return null;
    return url.href;
  } catch { return null; }
}
