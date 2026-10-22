import { Temporal } from "@js-temporal/polyfill";
import { BackendError } from "../errors.js";
import type { RemoteTask } from "../models.js";
import { safePageURL } from "../validation.js";

export const MAX_CALENDAR_BYTES = 8 * 1024 * 1024;
interface Property { name: string; value: string; parameters: Map<string, string> }
type Fields = Map<string, Property[]>;

function split(value: string, separator: string): string[] {
  const pieces = [""];
  let quoted = false, escaped = false;
  for (const character of value) {
    if (character === separator && !quoted && !escaped) pieces.push("");
    else pieces[pieces.length - 1] += character;
    if (character === '"' && !escaped) quoted = !quoted;
    escaped = character === "\\" && !escaped;
  }
  return pieces;
}

function unescape(value: string): string {
  return value.replace(/\\([nN,;\\])/g, (_, character: string) => /[nN]/.test(character) ? "\n" : character);
}

function property(line: string): Property {
  const parts = split(line, ":");
  if (parts.length < 2) throw new BackendError("invalidCalendar");
  const header = split(parts[0]!, ";");
  const parameters = new Map<string, string>();
  for (const parameter of header.slice(1)) {
    const equals = parameter.indexOf("=");
    if (equals < 1) throw new BackendError("invalidCalendar");
    parameters.set(parameter.slice(0, equals).toUpperCase(), parameter.slice(equals + 1).replace(/^"|"$/g, ""));
  }
  return { name: header[0]!.toUpperCase(), value: parts.slice(1).join(":"), parameters };
}

function single(fields: Fields, key: string): Property | undefined {
  const values = fields.get(key) ?? [];
  if (values.length > 1) throw new BackendError("invalidCalendar");
  return values[0];
}

function dateOnly(field: Property): boolean {
  return field.parameters.get("VALUE") === "DATE" || field.value.length === 8;
}

function validateZone(zone: string): void {
  try { new Temporal.ZonedDateTime(0n, zone); }
  catch { throw new BackendError("unsupportedCalendar"); }
}

function date(field: Property, fallbackZone: string): Temporal.ZonedDateTime {
  const utc = field.value.endsWith("Z");
  const match = dateOnly(field) ? /^(\d{4})(\d{2})(\d{2})$/.exec(field.value) :
    /^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z?$/.exec(field.value);
  if (!match) throw new BackendError("unsupportedCalendar");
  const specifiedZone = field.parameters.get("TZID");
  if (specifiedZone && utc) throw new BackendError("unsupportedCalendar");
  const zone = utc ? "UTC" : specifiedZone ?? fallbackZone;
  validateZone(zone);
  try {
    const value = Temporal.PlainDateTime.from({
      year: Number(match[1]), month: Number(match[2]), day: Number(match[3]),
      hour: Number(match[4] ?? 0), minute: Number(match[5] ?? 0), second: Number(match[6] ?? 0),
    }, { overflow: "reject" });
    return value.toZonedDateTime(zone, { disambiguation: "reject" });
  } catch { throw new BackendError("invalidCalendar"); }
}

export function parseICS(data: Uint8Array, defaultTimeZone: string): RemoteTask[] {
  if (data.length > MAX_CALENDAR_BYTES) throw new BackendError("tooLarge");
  // Unfold bytes first: a folded line may split a UTF-8 character.
  const bytes: number[] = [];
  for (let i = 0; i < data.length;) {
    if (data[i] === 13 && data[i + 1] === 10 && (data[i + 2] === 32 || data[i + 2] === 9)) i += 3;
    else if (data[i] === 10 && (data[i + 1] === 32 || data[i + 1] === 9)) i += 2;
    else { bytes.push(data[i]!); i++; }
  }
  let lines: string[];
  try {
    lines = new TextDecoder("utf-8", { fatal: true }).decode(Uint8Array.from(bytes))
      .replace(/^\uFEFF/, "").replace(/\r\n/g, "\n").split("\n").filter(line => line.length > 0);
  } catch { throw new BackendError("invalidCalendar"); }
  if (lines[0] !== "BEGIN:VCALENDAR" || lines.at(-1) !== "END:VCALENDAR") throw new BackendError("invalidCalendar");
  const stack: string[] = [], events: Fields[] = [];
  let fields: Fields = new Map(), zone = defaultTimeZone;
  validateZone(zone);
  for (const line of lines) {
    const field = property(line);
    if (field.name === "BEGIN") {
      if (!stack.length && field.value !== "VCALENDAR") throw new BackendError("invalidCalendar");
      if (field.value === "VEVENT") {
        if (stack.join("/") !== "VCALENDAR") throw new BackendError("invalidCalendar");
        fields = new Map();
      }
      stack.push(field.value);
    } else if (field.name === "END") {
      if (stack.pop() !== field.value) throw new BackendError("invalidCalendar");
      if (field.value === "VEVENT") events.push(fields);
    } else if (stack.join("/") === "VCALENDAR/VEVENT") {
      fields.set(field.name, [...(fields.get(field.name) ?? []), field]);
    } else if (stack.join("/") === "VCALENDAR" && field.name === "X-WR-TIMEZONE") {
      zone = field.value; validateZone(zone);
    }
  }
  if (stack.length) throw new BackendError("invalidCalendar");
  const tasks: RemoteTask[] = [], seen = new Set<string>();
  for (const event of events) {
    if (single(event, "STATUS")?.value.toUpperCase() === "CANCELLED") continue;
    if (["RRULE", "RDATE", "EXDATE", "RECURRENCE-ID"].some(key => event.has(key))) {
      throw new BackendError("unsupportedCalendar");
    }
    const uid = single(event, "UID")?.value, title = single(event, "SUMMARY")?.value;
    if (!uid || !title || seen.has(uid)) throw new BackendError("invalidCalendar");
    seen.add(uid);
    const start = single(event, "DTSTART"), end = single(event, "DTEND"), deadlineField = end ?? start;
    if (!deadlineField) throw new BackendError("invalidCalendar");
    if (!end && event.has("DURATION")) throw new BackendError("unsupportedCalendar");
    const deadlineDate = date(deadlineField, zone);
    let deadline = deadlineDate.epochMilliseconds;
    if (dateOnly(deadlineField)) deadline = (end ? deadline : deadlineDate.add({ days: 1 }).epochMilliseconds) - 1000;
    if (start && end && date(end, zone).epochMilliseconds < date(start, zone).epochMilliseconds) {
      throw new BackendError("invalidCalendar");
    }
    const courseField = single(event, "X-MOODLE-COURSE")?.value ?? event.get("CATEGORIES")?.[0]?.value;
    const courseName = courseField ? unescape(split(courseField, ",")[0]!) : "授業名未取得";
    const pageURL = single(event, "URL")?.value;
    const detail = single(event, "DESCRIPTION")?.value;
    tasks.push({ externalID: uid, source: "Moodle", courseName: courseName || "授業名未取得",
      title: unescape(title), detail: detail == null ? null : unescape(detail), deadline,
      sourceURL: pageURL ? safePageURL(pageURL) : null, isCompleted: null });
  }
  return tasks;
}
