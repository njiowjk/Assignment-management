import { load } from "cheerio/slim";
import { BackendError } from "../errors.js";
import type { MoodleSession, RemoteTask, TaskItem } from "../models.js";
import { safePageURL, record } from "../validation.js";
import { configurationFromHTML, MoodleSessionClient } from "./moodle-session.js";
import type { Fetch } from "./moodle.js";

export type Labels = Map<string, string>;
const normalize = (text: string): string => text.replace(/\s+/g, " ").trim();

/** Uses status fields in Moodle's own renderer, never deadline, grade, or absence of a calendar action. */
export function completionFromHTML(html: string, module: string, labels: Labels): boolean | null {
  const $ = load(html);
  if ($("body").attr("id") !== `page-mod-${module}-view`) return null;
  if (module === "assign") {
    const table = $(".submissionstatustable");
    if (table.find(".submissionstatusdraft, .submissionstatusreopened").length) return false;
    if (table.find(".submissionstatussubmitted").length) return true;
    const statusLabel = labels.get("assign:submissionstatus");
    if (statusLabel) {
      for (const row of table.find("tr").toArray()) {
        const cells = $(row).children("th,td");
        if (normalize(cells.first().text()) !== statusLabel) continue;
        const status = normalize(cells.last().text());
        if (["nosubmissionyet", "noattempt", "nosubmission"].some(key => labels.get("assign:" + key) === status)) return false;
      }
    }
    return null;
  }
  if (module === "quiz") {
    const states = $("table.quizattemptsummary tbody td").toArray().map(cell => {
      const copy = $(cell).clone(); copy.find(".statedetails").remove(); return normalize(copy.text());
    });
    if (["stateinprogress", "stateoverdue"].some(key => {
      const label = labels.get("quiz:" + key); return label != null && states.includes(label);
    })) return false;
    const finished = labels.get("quiz:statefinished");
    if (finished && states.includes(finished)) return true;
    if (!$("table.quizattemptsummary tbody tr").length && $("form[action$='/mod/quiz/startattempt.php']").length) return false;
    return null;
  }
  return automaticCompletionFromHTML(html);
}

export function automaticCompletionFromHTML(html: string): boolean | null {
  const $ = load(html);
  const requirements = $("[data-region='completionrequirements'] [role='listitem']");
  if (requirements.length && requirements.toArray().every(item => $(item).hasClass("alert-success"))) return true;
  if (requirements.toArray().some(item => $(item).hasClass("bg-light"))) return false;
  return null;
}

const labelKeys = [
  ...["submissionstatus", "nosubmissionyet", "noattempt", "nosubmission"].map(stringid => ({ stringid, component: "assign" })),
  ...["statefinished", "stateinprogress", "stateoverdue"].map(stringid => ({ stringid, component: "quiz" })),
];

export async function checkCompletions(current: RemoteTask[], existing: TaskItem[], session: MoodleSession,
                                        fetcher?: Fetch): Promise<RemoteTask[]> {
  const client = new MoodleSessionClient(session, fetcher);
  await client.authenticate();
  const tasks = new Map(current.map(task => [task.externalID, { ...task }]));
  // Recheck cached deadlines even when the rolling ICS feed no longer includes them.
  for (const cached of existing.filter(item => item.source === "Moodle")) {
    if (!tasks.has(cached.externalID)) tasks.set(cached.externalID, {
      externalID: cached.externalID, source: "Moodle", title: cached.title, courseName: cached.courseName,
      deadline: cached.deadline, detail: cached.detail ?? null, sourceURL: cached.sourceURL ?? null,
      isCompleted: null, isRemovedFromSource: true,
    });
  }
  const labels: Labels = new Map();
  const [strings] = await client.ajax([{ methodname: "core_get_strings", args: {
    strings: labelKeys.map(item => ({ ...item, stringparams: [] })),
  } }]);
  if (Array.isArray(strings)) for (const value of strings) {
    const row = record(value);
    if (typeof row.component === "string" && typeof row.stringid === "string" && typeof row.string === "string") {
      labels.set(row.component + ":" + row.stringid, normalize(load(row.string).text()));
    }
  }
  const all = [...tasks.values()];
  // Calendar AJAX is read-only. UID's host must match the authenticated Moodle site.
  const events = new Map<string, Record<string, unknown>>();
  for (let offset = 0; offset < all.length; offset += 20) {
    const batch = all.slice(offset, offset + 20).flatMap(task => {
      const uid = /^(\d+)@([^@]+)$/.exec(task.externalID);
      return uid && uid[2]?.toLowerCase() === client.base.hostname && Number.isSafeInteger(Number(uid[1]))
        ? [{ task, eventid: Number(uid[1]) }] : [];
    });
    if (!batch.length) continue;
    const results = await client.ajax(batch.map(item => ({ methodname: "core_calendar_get_calendar_event_by_id", args: { eventid: item.eventid } })));
    results.forEach((value, index) => {
      if (!value) return;
      const response = record(value), event = response.event;
      if (event && typeof event === "object") events.set(batch[index]!.task.externalID, record(event));
    });
  }
  const pages = new Map<string, Promise<boolean | null>>();
  let next = 0;
  async function work(): Promise<void> {
    while (next < all.length) {
      const task = all[next++]!;
      let module: string | undefined, cmid: number | undefined;
      const event = events.get(task.externalID);
      if (typeof event?.modulename === "string" && /^[a-z][a-z0-9_]*$/.test(event.modulename) &&
          typeof event.instance === "number" && Number.isSafeInteger(event.instance) && event.instance > 0) {
        module = event.modulename; cmid = event.instance;
      } else if (task.sourceURL) {
        const url = new URL(task.sourceURL, client.base);
        const match = /\/mod\/([a-z][a-z0-9_]*)\/view\.php$/.exec(url.pathname);
        const id = Number(url.searchParams.get("id"));
        if (url.origin === client.base.origin && match && Number.isSafeInteger(id) && id > 0) { module = match[1]; cmid = id; }
      }
      if (!module || cmid == null) continue;
      const page = new URL(`mod/${module}/view.php?id=${cmid}`, client.base);
      task.sourceURL = safePageURL(page.href);
      const key = `${module}:${cmid}`;
      if (!pages.has(key)) pages.set(key, (async () => {
        try {
          if (module !== "assign" && module !== "quiz") {
            // Read the course-list fragment. Visiting the activity itself could mark it viewed.
            const [fragment] = await client.ajax([{ methodname: "core_course_get_module", args: { id: cmid } }]);
            return typeof fragment === "string" ? automaticCompletionFromHTML(fragment) : null;
          }
          const html = await client.text(page.href);
          configurationFromHTML(html, client.base);
          return completionFromHTML(html, module!, labels);
        } catch (error) {
          if (error instanceof BackendError && error.code === "moodleLoginRequired") throw error;
          return null;
        }
      })());
      task.isCompleted = await pages.get(key)!;
    }
  }
  await Promise.all(Array.from({ length: Math.min(3, all.length) }, () => work()));
  return all;
}
