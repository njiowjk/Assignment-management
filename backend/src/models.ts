export type TaskSource = "Moodle" | "WebClass";
export type TaskStatus = "active" | "overdue" | "completed" | "unavailable";

/** Wire dates are milliseconds since Unix epoch. null means unavailable, never inferred completion. */
export interface RemoteTask {
  externalID: string;
  source: TaskSource;
  courseName: string;
  title: string;
  detail?: string | null;
  deadline: number;
  sourceURL?: string | null;
  isCompleted?: boolean | null;
  isRemovedFromSource?: boolean;
}

export interface MoodleSession {
  baseURL: string;
  cookies: { name: string; value: string; domain: string; path: string; secure: boolean; expiresAt?: number | null }[];
}

export interface TaskItem {
  id: string;
  externalID: string;
  source: TaskSource;
  courseName: string;
  title: string;
  detail?: string | null;
  deadline: number;
  status: TaskStatus;
  sourceURL?: string | null;
  firstDetectedAt: number;
  lastSyncedAt: number;
  completedAt?: number | null;
  isRemovedFromSource: boolean;
  completionIsKnown: boolean;
}

export interface SyncSummary {
  inserted: number;
  updated: number;
  deadlineChanges: number;
  missing: number;
}

export interface MergeResult { tasks: TaskItem[]; summary: SyncSummary }

export interface TaskSourceConnector {
  readonly source: TaskSource;
  fetchTasks(): Promise<RemoteTask[]>;
}
