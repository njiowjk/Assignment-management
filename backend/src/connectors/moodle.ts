import { BackendError } from "../errors.js";
import type { RemoteTask, TaskSourceConnector } from "../models.js";
import { calendarURL } from "../validation.js";
import { MAX_CALENDAR_BYTES, parseICS } from "./ics-parser.js";

export type Fetch = (input: URL, init: RequestInit) => Promise<Response>;

export function allowsRedirect(original: URL, target: URL): boolean {
  return target.protocol === "https:" && original.origin === target.origin && !target.username && !target.password;
}

/** No cookie jar or disk cache; credentials are supplied only for this invocation. */
export class MoodleConnector implements TaskSourceConnector {
  readonly source = "Moodle" as const;
  constructor(private readonly url: string, private readonly timeZone: string,
              private readonly fetcher: Fetch = globalThis.fetch) {}

  async fetchTasks(): Promise<RemoteTask[]> {
    const original = calendarURL(this.url);
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 60_000);
    let target = original;
    try {
      for (let redirects = 0; redirects <= 3; redirects++) {
        const response = await this.fetcher(target, { method: "GET", redirect: "manual", cache: "no-store",
          credentials: "omit", headers: { Accept: "text/calendar" }, signal: controller.signal });
        try {
          if (response.status >= 300 && response.status < 400) {
            const location = response.headers.get("location");
            if (!location || redirects === 3) throw new BackendError("authentication");
            const next = new URL(location, target);
            if (!allowsRedirect(original, next)) throw new BackendError("authentication");
            target = next;
            continue;
          }
          if (response.status === 401 || response.status === 403) throw new BackendError("authentication");
          if (!response.ok) throw new BackendError("server");
          if (response.headers.get("content-type")?.toLowerCase().startsWith("text/html")) throw new BackendError("authentication");
          if (Number(response.headers.get("content-length") ?? 0) > MAX_CALENDAR_BYTES) throw new BackendError("tooLarge");
          if (!response.body) throw new BackendError("invalidCalendar");
          const reader = response.body.getReader();
          const chunks: Uint8Array[] = [];
          let size = 0;
          try {
            for (;;) {
              const { value, done } = await reader.read();
              if (done) break;
              size += value.length;
              if (size > MAX_CALENDAR_BYTES) throw new BackendError("tooLarge");
              chunks.push(value);
            }
          } finally { await reader.cancel().catch(() => {}); reader.releaseLock(); }
          return parseICS(Buffer.concat(chunks), this.timeZone);
        } finally {
          if (!response.body?.locked) await response.body?.cancel().catch(() => {});
        }
      }
      throw new BackendError("authentication");
    } catch (error) {
      if (error instanceof BackendError) throw error;
      throw new BackendError("network");
    } finally { clearTimeout(timeout); }
  }
}
