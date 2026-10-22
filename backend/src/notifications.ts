import { BackendError } from "./errors.js";
import type { TaskSource } from "./models.js";
import { localTasks, record, source, text, timestamp } from "./validation.js";

export type NotificationKind = "newTask" | "dayBefore" | "hoursBefore" | "deadlineChanged" | "overdue";
export interface NotificationPreferences {
  enabled: boolean; newTask: boolean; dayBefore: boolean; hoursBefore: boolean;
  deadlineChanged: boolean; overdue: boolean; sound: boolean;
}
interface Observation { taskID: string; deadline: number; revision: number }
export interface NotificationReceipt { id: string; fireAt: number }
export interface TaskNotification {
  id: string; taskID: string; kind: NotificationKind; fireAt: number;
  deadline: number; title: string; courseName: string; source: TaskSource;
}
type ImmediateEvent = Pick<TaskNotification, "id" | "taskID" | "kind" | "fireAt">;
export interface NotificationState {
  observations: Observation[]; sources: TaskSource[]; receipts: NotificationReceipt[];
  events: ImmediateEvent[];
}
const kinds: NotificationKind[] = ["newTask", "dayBefore", "hoursBefore", "deadlineChanged", "overdue"];
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const identifier = /^assignment\.v1\.[0-9a-f-]{36}\.-?\d+\.\d+\.(newTask|dayBefore|hoursBefore|deadlineChanged|overdue)$/;
function taskID(value: unknown): string {
  const result = text(value).toLowerCase();
  if (!uuid.test(result)) throw new BackendError("backend");
  return result;
}
function array(value: unknown, limit: number): unknown[] {
  if (!Array.isArray(value) || value.length > limit) throw new BackendError("backend");
  return value;
}
function revision(value: unknown): number {
  if (!Number.isSafeInteger(value) || (value as number) < 0 || (value as number) > 1_000_000) throw new BackendError("backend");
  return value as number;
}
function stateFrom(value: unknown): NotificationState {
  const s = record(value);
  const observations = array(s.observations, 50_000).map(value => {
    const row = record(value);
    return { taskID: taskID(row.taskID), deadline: timestamp(row.deadline), revision: revision(row.revision) };
  });
  const sources = array(s.sources, 2).map(source);
  const receipts = array(s.receipts, 20_000).map(value => {
    const row = record(value), id = text(row.id);
    if (!identifier.test(id)) throw new BackendError("backend");
    return { id, fireAt: timestamp(row.fireAt) };
  });
  const events = array(s.events, 100).map(value => {
    const row = record(value), id = text(row.id), kind = text(row.kind) as NotificationKind;
    const key = taskID(row.taskID);
    if (!identifier.test(id) || !["newTask", "deadlineChanged"].includes(kind) ||
        !id.startsWith(`assignment.v1.${key}.`) || !id.endsWith(`.${kind}`)) throw new BackendError("backend");
    return { id, kind, taskID: key, fireAt: timestamp(row.fireAt) };
  });
  for (const ids of [observations.map(x => x.taskID), sources, receipts.map(x => x.id), events.map(x => x.id)]) {
    if (new Set(ids).size !== ids.length) throw new BackendError("backend");
  }
  return { observations, sources, receipts, events };
}

/** Pure notification policy. No OS calls, network, credentials, or database writes. */
export function notificationPlan(value: unknown): { state: NotificationState; requests: TaskNotification[]; validIDs: string[] } {
  const input = record(value), now = timestamp(input.now), tasks = localTasks(input.tasks);
  const raw = record(input.preferences);
  for (const key of ["enabled", ...kinds, "sound"]) if (typeof raw[key] !== "boolean") throw new BackendError("backend");
  const preferences = raw as unknown as NotificationPreferences;
  const syncedSources = array(input.syncedSources, 2).map(source);
  if (new Set(syncedSources).size !== syncedSources.length || new Set(tasks.map(x => x.id.toLowerCase())).size !== tasks.length) {
    throw new BackendError("backend");
  }
  const previous = stateFrom(input.state);
  const observations = new Map(previous.observations.map(x => [x.taskID, x]));
  const receipts = new Map(previous.receipts.map(x => [x.id, x]));
  const valid = new Set<string>(), candidates: TaskNotification[] = [];
  let events = [...previous.events];
  const current: Observation[] = [];
  for (const task of tasks) {
    const id = task.id.toLowerCase(), old = observations.get(id), deadline = Math.trunc(task.deadline);
    const changed = old != null && old.deadline !== deadline;
    const rev = Math.min(1_000_000, (old?.revision ?? 0) + (changed ? 1 : 0));
    current.push({ taskID: id, deadline, revision: rev });
    const eligible = task.completionIsKnown && ["active", "overdue"].includes(task.status) && !task.isRemovedFromSource;
    if (!preferences.enabled || !eligible) continue;
    const make = (kind: NotificationKind, fireAt: number): TaskNotification => ({
      id: `assignment.v1.${id}.${deadline}.${rev}.${kind}`, taskID: id, kind, fireAt, deadline,
      title: task.title, courseName: task.courseName, source: task.source,
    });
    // First enable / first import of each LMS establishes a silent baseline.
    const baselined = previous.sources.includes(task.source);
    for (const kind of kinds) if (preferences[kind]) valid.add(make(kind, now).id);
    if (baselined && ((!old && deadline > now && preferences.newTask) || (changed && preferences.deadlineChanged))) {
      const event = make(changed ? "deadlineChanged" : "newTask", now);
      if (!events.some(x => x.id === event.id)) events.push({ id: event.id, taskID: id, kind: event.kind, fireAt: now });
    }
    for (const [kind, offset] of [["dayBefore", 86_400_000], ["hoursBefore", 10_800_000], ["overdue", 0]] as const) {
      if (!preferences[kind]) continue;
      const notification = make(kind, deadline - offset);
      // Never backfill historical reminders. A short grace covers a running app's timer drift.
      if (notification.fireAt > now || (baselined && old?.deadline === deadline && now - notification.fireAt <= 300_000)) {
        if (!receipts.has(notification.id) || notification.fireAt > now) candidates.push(notification);
      }
    }
  }
  // Preserve unsent immediate events for retry; do not regenerate them after a successful add.
  events = events.filter(x => valid.has(x.id) && !receipts.has(x.id) && x.fireAt <= now && now - x.fireAt <= 3_600_000)
    .slice(-100);
  const byID = new Map(tasks.map(x => [x.id.toLowerCase(), x]));
  candidates.push(...events.slice(0, 5).map(event => {
    const task = byID.get(event.taskID)!;
    return { ...event, deadline: Math.trunc(task.deadline), title: task.title, courseName: task.courseName, source: task.source };
  }));
  candidates.sort((a, b) => a.fireAt - b.fireAt || a.id.localeCompare(b.id));
  // Conservative bounded queue; a running app refills it each minute and after sync.
  const requests = candidates.slice(0, 48);
  return {
    state: { observations: current, sources: [...new Set([...previous.sources, ...syncedSources])], events,
      receipts: [...receipts.values()].filter(x => valid.has(x.id)).sort((a, b) => a.fireAt - b.fireAt).slice(-20_000) },
    requests, validIDs: [...valid],
  };
}
