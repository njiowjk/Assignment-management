import { load } from "cheerio/slim";
import { BackendError } from "../errors.js";
import type { MoodleSession, RemoteTask, TaskSourceConnector } from "../models.js";
import type { Fetch } from "./moodle.js";
import { cookieHeader } from "./moodle-session.js";
import { identifier, object, parseContents, parseCourses, WEBCLASS_API, WEBCLASS_BASE } from "./webclass-data.js";

export function decodeWebClassSession(value: unknown): MoodleSession {
  if (value == null) throw new BackendError("webClassLoginRequired");
  const row = object(value);
  if (row.baseURL !== WEBCLASS_BASE || !Array.isArray(row.cookies) || !row.cookies.length || row.cookies.length > 100) {
    throw new BackendError("webClassLoginRequired");
  }
  for (const raw of row.cookies) {
    const c = object(raw);
    if (typeof c.name !== "string" || !/^[A-Za-z0-9_!#$%&'*+.^`|~-]+$/.test(c.name) ||
        typeof c.value !== "string" || /[\x00-\x20;\x7f]/.test(c.value) ||
        typeof c.domain !== "string" || c.domain.replace(/^\./, "").toLowerCase() !== "lms2025.hosei.ac.jp" ||
        typeof c.path !== "string" || !c.path.startsWith("/") || typeof c.secure !== "boolean" ||
        (c.expiresAt != null && (typeof c.expiresAt !== "number" || !Number.isFinite(c.expiresAt)))) {
      throw new BackendError("webClassLoginRequired");
    }
  }
  return row as unknown as MoodleSession;
}

export function webClassUser(html: string): string {
  const $ = load(html);
  for (const script of $('script.js-config[type="application/json"]').toArray()) {
    try {
      const cfg = object(JSON.parse($(script).text()) as unknown);
      if (cfg.API_URL === "/webclass/ip_mods.php/plugin/score_summary_table" && cfg.TOP_URL === "/webclass/") {
        return identifier(cfg.userWebClassId);
      }
    } catch { /* Never log HTML, names, or session data. */ }
  }
  throw new BackendError("webClassLoginRequired");
}

/** Only the three observed, read-only dashboard routes are permitted. */
export class WebClassConnector implements TaskSourceConnector {
  readonly source = "WebClass" as const;
  constructor(private readonly session?: MoodleSession, private readonly fetcher: Fetch = globalThis.fetch) {}

  private async read(url: URL, signal: AbortSignal): Promise<string> {
    if (![WEBCLASS_API + "/dashboard", WEBCLASS_API + "/courses", WEBCLASS_API + "/contents"].includes(url.origin + url.pathname) ||
        url.username || url.password || url.hash) throw new BackendError("invalidWebClassData");
    if (!this.session) throw new BackendError("webClassLoginRequired");
    const cookie = cookieHeader(this.session, url);
    if (!cookie) throw new BackendError("webClassLoginRequired");
    const response = await this.fetcher(url, { method: "GET", redirect: "manual", credentials: "omit", cache: "no-store",
      headers: { Cookie: cookie, Accept: url.pathname.endsWith("/dashboard") ? "text/html" : "application/json" }, signal });
    try {
      // Do not follow SSO/login redirects and never send LMS cookies to the identity provider.
      if ((response.status >= 300 && response.status < 400) || response.status === 401 || response.status === 403) {
        throw new BackendError("webClassLoginRequired");
      }
      if (!response.ok) throw new BackendError("server");
      if (Number(response.headers.get("content-length")) > 8 * 1024 * 1024) throw new BackendError("tooLarge");
      const reader = response.body?.getReader();
      if (!reader) throw new BackendError("invalidWebClassData");
      const chunks: Uint8Array[] = []; let size = 0;
      try {
        for (;;) {
          const { done, value } = await reader.read(); if (done) break;
          size += value.length; if (size > 8 * 1024 * 1024) throw new BackendError("tooLarge");
          chunks.push(value);
        }
      } finally { await reader.cancel().catch(() => {}); reader.releaseLock(); }
      return new TextDecoder("utf-8", { fatal: true }).decode(Buffer.concat(chunks));
    } finally { if (!response.body?.locked) await response.body?.cancel().catch(() => {}); }
  }

  async fetchTasks(): Promise<RemoteTask[]> {
    decodeWebClassSession(this.session);
    const controller = new AbortController(), timer = setTimeout(() => controller.abort(), 60_000);
    try {
      const userID = webClassUser(await this.read(new URL(WEBCLASS_API + "/dashboard"), controller.signal));
      const json = async (url: URL): Promise<unknown> => {
        const body = await this.read(url, controller.signal);
        try { return JSON.parse(body) as unknown; }
        catch { throw new BackendError(/^\s*</.test(body) ? "webClassLoginRequired" : "invalidWebClassData"); }
      };
      const courses = parseCourses(await json(new URL(WEBCLASS_API + "/courses")));
      const results: RemoteTask[][] = new Array(courses.length);
      let cursor = 0;
      // All enrolled years, including old overdue tasks; at most three concurrent requests.
      await Promise.all(Array.from({ length: Math.min(3, courses.length) }, async () => {
        while (cursor < courses.length) {
          if (controller.signal.aborted) throw new BackendError("network");
          const index = cursor++, course = courses[index]!;
          const url = new URL(WEBCLASS_API + "/contents"); url.searchParams.set("group_id", course.id);
          results[index] = parseContents(await json(url), course, userID);
        }
      }));
      // No partial success: a failed course cannot make cached tasks disappear.
      return results.flat();
    } catch (error) {
      if (error instanceof BackendError) throw error;
      throw new BackendError("network");
    } finally { controller.abort(); clearTimeout(timer); }
  }
}
