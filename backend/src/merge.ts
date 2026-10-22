import { randomUUID } from "node:crypto";
import { BackendError } from "./errors.js";
import type { MergeResult, RemoteTask, TaskItem, TaskSource, SyncSummary } from "./models.js";

/** Pure domain operation. Only the requested source is returned; persistence stays in the native adapter. */
export function mergeTasks(existing: readonly TaskItem[], incoming: readonly RemoteTask[],
                           source: TaskSource, now: number): MergeResult {
  const seen = new Set<string>();
  for (const task of incoming) {
    if (task.source !== source || !task.externalID || seen.has(task.externalID)) {
      throw new BackendError("invalidCalendar");
    }
    seen.add(task.externalID);
  }
  const previous = new Map<string, TaskItem>();
  for (const task of existing.filter(task => task.source === source)) {
    if (previous.has(task.externalID)) throw new BackendError("backend");
    previous.set(task.externalID, task);
  }
  const summary: SyncSummary = { inserted: 0, updated: 0, deadlineChanges: 0, missing: 0 };
  const tasks: TaskItem[] = [];
  for (const remote of incoming) {
    const before = previous.get(remote.externalID);
    if (before) {
      if (before.deadline !== remote.deadline) summary.deadlineChanges++;
      if (before.title !== remote.title || before.courseName !== remote.courseName ||
          (before.detail ?? null) !== (remote.detail ?? null) || before.deadline !== remote.deadline ||
          (before.sourceURL ?? null) !== (remote.sourceURL ?? null) || before.isRemovedFromSource ||
          (remote.isCompleted != null && remote.isCompleted !== (before.status === "completed"))) summary.updated++;
    } else { summary.inserted++; }

    const completed = remote.isCompleted ?? (before?.status === "completed");
    tasks.push({
      id: before?.id ?? randomUUID(),
      externalID: remote.externalID, source, title: remote.title, courseName: remote.courseName,
      detail: remote.detail ?? null, deadline: remote.deadline, sourceURL: remote.sourceURL ?? null,
      status: completed ? "completed" : remote.deadline < now ? "overdue" : "active",
      firstDetectedAt: before?.firstDetectedAt ?? now,
      lastSyncedAt: now,
      completedAt: completed ? before?.completedAt ?? now : null,
      completionIsKnown: remote.isCompleted != null || (before?.status === "completed" && before.completionIsKnown),
      isRemovedFromSource: remote.isRemovedFromSource ?? false,
    });
    if (remote.isRemovedFromSource) summary.missing++;
  }
  for (const before of previous.values()) {
    if (!seen.has(before.externalID)) {
      tasks.push({ ...before, isRemovedFromSource: true });
      summary.missing++;
    }
  }
  return { tasks, summary };
}
