import { load } from "cheerio/slim";
import { BackendError } from "../errors.js";
import type { MoodleSession } from "../models.js";
import { calendarURL, record } from "../validation.js";
import type { Fetch } from "./moodle.js";

export function moodleRoot(calendar: URL): URL {
  const root = new URL(calendar.origin);
  const index = calendar.pathname.indexOf("/calendar/");
  root.pathname = index >= 0 ? calendar.pathname.slice(0, index + 1) : "/";
  return root;
}

export function decodeSession(value: unknown, calendar: URL): MoodleSession {
  const raw = record(value), base = calendarURL(raw.baseURL), expected = moodleRoot(calendar);
  if (base.href.replace(/\/$/, "") !== expected.href.replace(/\/$/, "") || !Array.isArray(raw.cookies) || raw.cookies.length > 100) {
    throw new BackendError("moodleLoginRequired");
  }
  for (const value of raw.cookies) {
    const cookie = record(value);
    if (typeof cookie.name !== "string" || !/^[A-Za-z0-9_!#$%&'*+.^`|~-]+$/.test(cookie.name) ||
        typeof cookie.value !== "string" || /[\x00-\x20;\x7f]/.test(cookie.value) ||
        typeof cookie.domain !== "string" || typeof cookie.path !== "string" || !cookie.path.startsWith("/") ||
        typeof cookie.secure !== "boolean" || (cookie.expiresAt != null &&
        (typeof cookie.expiresAt !== "number" || !Number.isFinite(cookie.expiresAt)))) throw new BackendError("moodleLoginRequired");
    const domain = cookie.domain.replace(/^\./, "").toLowerCase();
    if (base.hostname !== domain && !base.hostname.endsWith("." + domain)) throw new BackendError("moodleLoginRequired");
  }
  return raw as unknown as MoodleSession;
}

export function cookieHeader(session: MoodleSession, url: URL, now = Date.now()): string {
  const base = new URL(session.baseURL);
  if (base.origin !== url.origin || url.protocol !== "https:") throw new BackendError("moodleLoginRequired");
  return session.cookies.filter(cookie => (cookie.expiresAt == null || cookie.expiresAt > now) &&
    (url.pathname === cookie.path || (url.pathname.startsWith(cookie.path) &&
      (cookie.path.endsWith("/") || url.pathname[cookie.path.length] === "/"))))
    .map(cookie => `${cookie.name}=${cookie.value}`).join("; ");
}

export interface MoodleConfiguration { wwwroot: string; sesskey: string; userId: number }

/** Parse the official M.cfg JSON without executing page JavaScript or reading login inputs. */
export function configurationFromHTML(html: string, base: URL): MoodleConfiguration {
  const $ = load(html);
  if ($("body.notloggedin, body#page-login-index, form#login").length) throw new BackendError("moodleLoginRequired");
  for (const script of $("script").toArray()) {
    const text = $(script).html() ?? "";
    const start = /\bM\.cfg\s*=\s*\{/.exec(text);
    if (!start) continue;
    const begin = start.index + start[0].length - 1;
    let quoted = false, escaped = false, depth = 0;
    for (let index = begin; index < text.length; index++) {
      const character = text[index];
      if (!quoted && character === "{") depth++;
      if (!quoted && character === "}" && --depth === 0) {
        try {
          const cfg = record(JSON.parse(text.slice(begin, index + 1)) as unknown);
          if (typeof cfg.wwwroot === "string" && cfg.wwwroot.replace(/\/$/, "") === base.href.replace(/\/$/, "") &&
              typeof cfg.sesskey === "string" && /^[A-Za-z0-9]{5,128}$/.test(cfg.sesskey) &&
              typeof cfg.userId === "number" && Number.isSafeInteger(cfg.userId) && cfg.userId > 0) {
            return cfg as unknown as MoodleConfiguration;
          }
        } catch { /* Never expose source HTML or tokens. */ }
        break;
      }
      if (character === '"' && !escaped) quoted = !quoted;
      escaped = character === "\\" && !escaped;
    }
  }
  throw new BackendError("moodleLoginRequired");
}

export class MoodleSessionClient {
  readonly base: URL;
  private cfg?: MoodleConfiguration;
  constructor(private readonly session: MoodleSession, private readonly fetcher: Fetch = globalThis.fetch) {
    this.base = new URL(session.baseURL.replace(/\/?$/, "/"));
  }

  async text(path: string, init: RequestInit = {}): Promise<string> {
    let url = new URL(path, this.base);
    const controller = new AbortController(), timer = setTimeout(() => controller.abort(), 15_000);
    try {
      for (let redirects = 0; redirects <= 3; redirects++) {
        if (url.origin !== this.base.origin || !url.pathname.startsWith(this.base.pathname)) throw new BackendError("moodleLoginRequired");
        const cookie = cookieHeader(this.session, url);
        if (!cookie) throw new BackendError("moodleLoginRequired");
        const response = await this.fetcher(url, { ...init, redirect: "manual", credentials: "omit", cache: "no-store",
          signal: controller.signal, headers: { ...init.headers, Cookie: cookie } });
        try {
          if (response.status >= 300 && response.status < 400) {
            const location = response.headers.get("location");
            if (!location || redirects === 3 || init.method === "POST") throw new BackendError("moodleLoginRequired");
            url = new URL(location, url); continue;
          }
          if (response.status === 401 || response.status === 403) throw new BackendError("moodleLoginRequired");
          if (!response.ok) throw new BackendError("server");
          if (Number(response.headers.get("content-length")) > 8 * 1024 * 1024) throw new BackendError("tooLarge");
          const reader = response.body?.getReader();
          if (!reader) throw new BackendError("server");
          const chunks: Uint8Array[] = []; let size = 0;
          try {
            for (;;) { const { value, done } = await reader.read(); if (done) break;
              size += value.length; if (size > 8 * 1024 * 1024) throw new BackendError("tooLarge"); chunks.push(value); }
          } finally { await reader.cancel().catch(() => {}); reader.releaseLock(); }
          return new TextDecoder("utf-8", { fatal: true }).decode(Buffer.concat(chunks));
        } finally { if (!response.body?.locked) await response.body?.cancel().catch(() => {}); }
      }
      throw new BackendError("moodleLoginRequired");
    } catch (error) {
      if (error instanceof BackendError) throw error;
      throw new BackendError("network");
    } finally { clearTimeout(timer); }
  }

  async authenticate(): Promise<void> {
    this.cfg = configurationFromHTML(await this.text("my/"), this.base);
  }

  async ajax(calls: { methodname: string; args: Record<string, unknown> }[]): Promise<(unknown | null)[]> {
    if (!this.cfg) await this.authenticate();
    // Only explicitly listed read operations may be issued by this connector.
    if (calls.some(call => !["core_calendar_get_calendar_event_by_id", "core_get_strings", "core_course_get_module"].includes(call.methodname))) {
      throw new BackendError("backend");
    }
    const path = `lib/ajax/service.php?sesskey=${encodeURIComponent(this.cfg!.sesskey)}`;
    let results: unknown;
    const body = await this.text(path, { method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify(calls.map((call, index) => ({ index, ...call }))) });
    try { results = JSON.parse(body) as unknown; } catch { throw new BackendError("moodleLoginRequired"); }
    if (!Array.isArray(results) || results.length !== calls.length) throw new BackendError("server");
    return results.map(value => {
      const result = record(value);
      if (result.error) {
        const code = record(result.exception ?? {}).errorcode;
        if (["invalidsesskey", "requireloginerror", "notloggedin", "servicerequireslogin"].includes(String(code))) {
          throw new BackendError("moodleLoginRequired");
        }
        return null;
      }
      return result.data ?? null;
    });
  }
}
