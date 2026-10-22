import { BackendError } from "../errors.js";
import type { RemoteTask, TaskSourceConnector } from "../models.js";

/** Implement only after observing the real HOPPII/WebClass authentication and data flow. */
export class WebClassConnector implements TaskSourceConnector {
  readonly source = "WebClass" as const;
  async fetchTasks(): Promise<RemoteTask[]> { throw new BackendError("notConfigured"); }
}
