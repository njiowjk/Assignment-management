import { Temporal } from "@js-temporal/polyfill";
import { BackendError } from "../errors.js";
import type { RemoteTask } from "../models.js";

export const WEBCLASS_BASE = "https://lms2025.hosei.ac.jp/webclass/";
export const WEBCLASS_API = WEBCLASS_BASE + "ip_mods.php/plugin/score_summary_table";
const fail = (): never => { throw new BackendError("invalidWebClassData"); };
export function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) return fail();
  return value as Record<string, unknown>;
}
function name(value: unknown): string {
  if (typeof value !== "string" || !value.trim() || value.length > 20_000) return fail();
  return value;
}
export function identifier(value: unknown): string {
  if (typeof value !== "string" || !/^[A-Za-z0-9_-]{1,200}$/.test(value)) return fail();
  return value;
}
function numeric(value: unknown): number | null {
  if (value === null) return null;
  if ((typeof value !== "number" && typeof value !== "string") || value === "" || !Number.isFinite(Number(value))) return fail();
  return Number(value);
}
function flag(value: unknown): boolean {
  if (typeof value !== "boolean") return fail();
  return value;
}
function date(value: unknown): number | null {
  if (value === null || value === "") return null;
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/.test(value)) return fail();
  try {
    // The university API returns local Japanese wall-clock times, not the Mac's timezone.
    return Temporal.PlainDateTime.from(value.replace(" ", "T"), { overflow: "reject" })
      .toZonedDateTime("Asia/Tokyo", { disambiguation: "reject" }).epochMilliseconds;
  } catch { return fail(); }
}

export interface WebClassCourse { id: string; name: string }
export function parseCourses(value: unknown): WebClassCourse[] {
  if (!Array.isArray(value) || value.length > 1000) return fail();
  const seen = new Set<string>(), courses: WebClassCourse[] = [];
  for (const raw of value) {
    const row = object(raw), id = identifier(row.group_id), title = name(row.group_name);
    if (seen.has(id)) return fail();
    seen.add(id);
    // Never request teacher/other-student score endpoints, even with a teaching-role account.
    if (flag(object(row.perms).PERM_COURSE_RESULT)) continue;
    courses.push({ id, name: title });
  }
  return courses;
}

/** Mirror the deployed student dashboard's completed/uncompleted filters.
 * A date alone is evidence only when no visible pass threshold applies.
 * Anonymous questionnaires intentionally have no per-user completion information.
 */
export function completion(content: Record<string, unknown>, score: Record<string, unknown> | undefined): boolean | null {
  const enquete = content.enquete === false ? null : object(content.enquete);
  const anonymous = enquete ? flag(enquete.anonymous) : false;
  const hiddenScore = flag(content.hidden_score), border = numeric(content.border);
  if (anonymous || !score) return null;
  const answered = date(score.answer_datetime) !== null, max = numeric(score.max_score);
  const passed = (max !== null && border !== null && !hiddenScore && max >= border) ||
    (border === null && answered) || (hiddenScore && border !== null && answered) || (!!enquete && answered);
  const pending = (max !== null && border !== null && !hiddenScore && max < border) || !answered;
  if (passed && pending) return null;
  if (passed) return true;
  if (pending) return false;
  return null;
}

export function parseContents(value: unknown, course: WebClassCourse, userID: string): RemoteTask[] {
  if (!Array.isArray(value) || value.length > 50_000) return fail();
  const seen = new Set<string>(), tasks: RemoteTask[] = [];
  for (const raw of value) {
    const row = object(raw), id = identifier(row.contents_id);
    if (identifier(row.group_id) !== course.id || seen.has(id)) return fail();
    seen.add(id);
    if (flag(row.hidden_content)) continue;
    const title = name(row.contents_name), deadline = date(row.end_date);
    if (deadline === null) continue;
    if (!Array.isArray(row.scores)) return fail();
    const scores = row.scores.map(object).filter(s => identifier(s.user_id) === userID);
    if (scores.length > 1) return fail();
    tasks.push({ externalID: `${course.id}:${id}`, source: "WebClass", courseName: course.name,
      title, deadline, isCompleted: completion(row, scores[0]),
      // A course link cannot inadvertently start an activity attempt.
      sourceURL: WEBCLASS_BASE + `course.php/${encodeURIComponent(course.id)}/login` });
  }
  return tasks;
}
