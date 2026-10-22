import assert from "node:assert/strict";
import { test } from "node:test";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { parseICS, MAX_CALENDAR_BYTES } from "../src/connectors/ics-parser.js";
import { allowsRedirect, MoodleConnector } from "../src/connectors/moodle.js";
import { BackendError } from "../src/errors.js";
import { WebClassConnector } from "../src/connectors/webclass.js";
import { mergeTasks } from "../src/merge.js";
import type { RemoteTask, TaskItem } from "../src/models.js";
import { calendarURL, localTasks } from "../src/validation.js";

const now = Date.parse("2026-10-21T12:00:00Z");
const zone = "Asia/Tokyo";
const event = "UID:one\r\nSUMMARY:課題\r\nDTSTART:20261022T170000Z";
function calendar(value = event, prefix = ""): Buffer {
  return Buffer.from(`BEGIN:VCALENDAR\r\nVERSION:2.0\r\n${prefix}BEGIN:VEVENT\r\n${value}\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n`);
}
function remote(overrides: Partial<RemoteTask> = {}): RemoteTask {
  return { externalID: "one", source: "Moodle", title: "課題", courseName: "授業", deadline: now, ...overrides };
}
function initial(overrides: Partial<RemoteTask> = {}): TaskItem[] {
  return mergeTasks([], [remote(overrides)], "Moodle", now).tasks;
}
function throwsCode(code: string, action: () => unknown): void {
  assert.throws(action, error => error instanceof BackendError && error.code === code);
}

test("ICS: UID, UTF8, escaped text, categories and page URL", () => {
  const [task] = parseICS(calendar("UID:one\r\nSUMMARY:SQL\\, 演習\r\nCATEGORIES:授業\\,基礎,大学\r\nDTSTART:20261021T140000Z\r\nDESCRIPTION:行1\\n行2\r\nURL:https://example.test/mod/assign/view.php?id=10"), zone);
  assert.equal(task?.externalID, "one"); assert.equal(task?.title, "SQL, 演習");
  assert.equal(task?.courseName, "授業,基礎"); assert.equal(task?.detail, "行1\n行2");
  assert.equal(task?.deadline, Date.parse("2026-10-21T14:00:00Z"));
  assert.equal(task?.sourceURL, "https://example.test/mod/assign/view.php?id=10");
  assert.equal(task?.isCompleted, null);
});
test("ICS: TZID and DTEND take precedence", () => {
  const [task] = parseICS(calendar("UID:two\r\nSUMMARY:時刻\r\nDTSTART;TZID=\"Asia/Tokyo\":20261022T100000\r\nDTEND;TZID=Asia/Tokyo:20261022T170000"), zone);
  assert.equal(task?.deadline, Date.parse("2026-10-22T08:00:00Z"));
});
test("ICS: calendar timezone for floating dates", () => {
  const [task] = parseICS(calendar("UID:f\r\nSUMMARY:時刻\r\nDTSTART:20261022T170000", "X-WR-TIMEZONE:Europe/London\r\n"), zone);
  assert.equal(task?.deadline, Date.parse("2026-10-22T16:00:00Z"));
});
test("ICS: exclusive all-day end and single all-day date", () => {
  const first = parseICS(calendar("UID:d\r\nSUMMARY:終日\r\nDTSTART;VALUE=DATE:20261022\r\nDTEND;VALUE=DATE:20261023"), zone);
  const second = parseICS(calendar("UID:d\r\nSUMMARY:終日\r\nDTSTART;VALUE=DATE:20261022"), zone);
  assert.equal(first[0]?.deadline, Date.parse("2026-10-22T14:59:59Z"));
  assert.equal(second[0]?.deadline, first[0]?.deadline);
});
test("ICS: all-day DST transition uses calendar day, not 24 hours", () => {
  const [task] = parseICS(calendar("UID:d\r\nSUMMARY:DST\r\nDTSTART;VALUE=DATE:20260308"), "America/New_York");
  assert.equal(task?.deadline, Date.parse("2026-03-09T03:59:59Z"));
});
test("ICS: unfolds lines before decoding a split multibyte character", () => {
  const input = calendar(); const position = input.indexOf(Buffer.from("課")) + 1;
  const folded = Buffer.concat([input.subarray(0, position), Buffer.from("\r\n "), input.subarray(position)]);
  assert.equal(parseICS(folded, zone)[0]?.title, "課題");
});
test("ICS: ignores nested alarm summary", () => {
  const data = calendar(`${event}\r\nBEGIN:VALARM\r\nSUMMARY:alarm\r\nEND:VALARM`);
  assert.equal(parseICS(data, zone)[0]?.title, "課題");
});
for (const [label, body, code] of [
  ["invalid date", "UID:x\r\nSUMMARY:x\r\nDTSTART:20260230T120000Z", "invalidCalendar"],
  ["missing deadline", "UID:x\r\nSUMMARY:x", "invalidCalendar"],
  ["duplicate UID property", `UID:duplicate\r\n${event}`, "invalidCalendar"],
  ["recurrence", `${event}\r\nRRULE:FREQ=WEEKLY`, "unsupportedCalendar"],
  ["unknown zone", "UID:x\r\nSUMMARY:x\r\nDTSTART;TZID=Unknown/Zone:20261022T170000", "unsupportedCalendar"],
  ["inverted range", "UID:x\r\nSUMMARY:x\r\nDTSTART:20261022T170000Z\r\nDTEND:20261021T170000Z", "invalidCalendar"],
] as const) test(`ICS rejects ${label}`, () => throwsCode(code, () => parseICS(calendar(body), zone)));
test("ICS rejects HTML, truncated input and invalid UTF8", () => {
  for (const data of [Buffer.from("<html>login</html>"), calendar().subarray(0, -20), Buffer.from([255])]) {
    throwsCode("invalidCalendar", () => parseICS(data, zone));
  }
});
test("ICS: cancelled events skipped and token URLs omitted", () => {
  assert.deepEqual(parseICS(calendar("UID:cancelled\r\nSTATUS:CANCELLED"), zone), []);
  const [task] = parseICS(calendar(`${event}\r\nURL:https://example.test/?authtoken=synthetic`), zone);
  assert.equal(task?.sourceURL, null);
});
test("ICS: rejects duplicate event identities", () => {
  const data = calendar().toString().replace("END:VCALENDAR", `BEGIN:VEVENT\r\n${event}\r\nEND:VEVENT\r\nEND:VCALENDAR`);
  throwsCode("invalidCalendar", () => parseICS(Buffer.from(data), zone));
});
test("ICS rejects oversized feeds", () => throwsCode("tooLarge", () => parseICS(new Uint8Array(MAX_CALENDAR_BYTES + 1), zone)));

test("merge inserts and repeated sync is idempotent", () => {
  const original = initial();
  const result = mergeTasks(original, [remote()], "Moodle", now + 1000);
  assert.equal(result.tasks.length, 1); assert.equal(result.tasks[0]?.id, original[0]?.id);
  assert.equal(result.summary.inserted, 0); assert.equal(result.summary.updated, 0);
  assert.equal(original[0]?.completionIsKnown, false);
});
test("merge updates deadline/title while preserving UUID and firstDetectedAt", () => {
  const original = initial(); const result = mergeTasks(original, [remote({ title: "変更", deadline: now + 1000 })], "Moodle", now);
  assert.equal(result.tasks[0]?.id, original[0]?.id); assert.equal(result.tasks[0]?.firstDetectedAt, original[0]?.firstDetectedAt);
  assert.equal(result.summary.updated, 1); assert.equal(result.summary.deadlineChanges, 1);
  assert.equal(result.tasks[0]?.title, "変更");
});
test("merge preserves missing/overdue tasks and never mutates input", () => {
  const original = initial({ deadline: now - 1000 }); const saved = structuredClone(original);
  const result = mergeTasks(original, [], "Moodle", now + 1000);
  assert.deepEqual(original, saved); assert.equal(result.tasks[0]?.isRemovedFromSource, true);
  assert.equal(result.tasks[0]?.status, "overdue"); assert.equal(result.summary.missing, 1);
});
test("merge isolates sources and reappearance clears missing flag", () => {
  const moodle = initial(), webclass = mergeTasks([], [remote({ source: "WebClass" })], "WebClass", now).tasks;
  const result = mergeTasks([...moodle, ...webclass], [], "Moodle", now);
  assert.equal(result.tasks.length, 1); assert.equal(result.tasks[0]?.source, "Moodle");
  const restored = mergeTasks(result.tasks, [remote()], "Moodle", now);
  assert.equal(restored.tasks[0]?.isRemovedFromSource, false);
});
test("merge unknown submission never reopens confirmed completion", () => {
  const original = initial({ isCompleted: true });
  const result = mergeTasks(original, [remote()], "Moodle", now + 1000);
  assert.equal(result.tasks[0]?.status, "completed"); assert.equal(result.tasks[0]?.completedAt, now);
  assert.equal(result.tasks[0]?.completionIsKnown, true);
});
test("merge confirmed unsubmitted state can reopen completion", () => {
  const result = mergeTasks(initial({ isCompleted: true }), [remote({ isCompleted: false })], "Moodle", now + 1000);
  assert.equal(result.tasks[0]?.status, "overdue"); assert.equal(result.tasks[0]?.completedAt, null);
});
test("merge rejects mixed sources/duplicate IDs", () => {
  throwsCode("invalidCalendar", () => mergeTasks([], [remote(), remote()], "Moodle", now));
  throwsCode("invalidCalendar", () => mergeTasks([], [remote({ source: "WebClass" })], "Moodle", now));
});
test("wire validation rejects malformed dates/UUIDs and nonfinite numbers", () => {
  throwsCode("backend", () => localTasks([{ ...initial()[0], id: "invalid" }]));
  throwsCode("backend", () => localTasks([{ ...initial()[0], deadline: NaN }]));
});
for (const url of ["http://example.test/", "https://user:secret@example.test/", "invalid", "https://example.test/a b", "file:///tmp/feed"]) {
  test(`URL rejects ${url.split(":")[0]} input`, () => throwsCode("invalidURL", () => calendarURL(url)));
}
test("redirect policy accepts only same HTTPS origin", () => {
  const original = new URL("https://example.test/calendar");
  assert.ok(allowsRedirect(original, new URL("https://example.test/next")));
  for (const next of ["https://other.test/", "http://example.test/", "https://example.test:8443/"]) {
    assert.equal(allowsRedirect(original, new URL(next)), false);
  }
});
test("WebClass requires a session and does not fetch anonymously", async () => {
  await assert.rejects(new WebClassConnector().fetchTasks(), error => error instanceof BackendError && error.code === "webClassLoginRequired");
});
test("Moodle fetch returns parsed feed without cookies or disk cache", async () => {
  const result = await new MoodleConnector("https://example.test/", zone, async (_url, options) => {
    assert.equal(options.credentials, "omit"); assert.equal(options.cache, "no-store"); assert.equal(options.redirect, "manual");
    return new Response(calendar().toString(), { headers: { "Content-Type": "text/calendar" } });
  }).fetchTasks();
  assert.equal(result[0]?.externalID, "one");
});
for (const [status, type, expected] of [[403, "text/plain", "authentication"], [503, "text/plain", "server"], [200, "text/html", "authentication"]] as const) {
  test(`Moodle maps status ${status}/${type}`, async () => {
    const connector = new MoodleConnector("https://example.test/", zone, async () => new Response("data", { status, headers: { "Content-Type": type } }));
    await assert.rejects(connector.fetchTasks(), error => error instanceof BackendError && error.code === expected);
  });
}
test("Moodle rejects cross-origin redirect before sending another request", async () => {
  let calls = 0;
  const connector = new MoodleConnector("https://example.test/", zone, async () => {
    calls++; return new Response(null, { status: 302, headers: { location: "https://other.test/" } });
  });
  await assert.rejects(connector.fetchTasks(), error => error instanceof BackendError && error.code === "authentication");
  assert.equal(calls, 1);
});
test("Moodle follows same-origin redirects with a bounded count", async () => {
  let calls = 0;
  const connector = new MoodleConnector("https://example.test/", zone, async () => {
    calls++; return calls === 1 ? new Response(null, { status: 302, headers: { location: "/feed" } }) : new Response(calendar().toString());
  });
  assert.equal((await connector.fetchTasks()).length, 1); assert.equal(calls, 2);
  const loop = new MoodleConnector("https://example.test/", zone, async () => new Response(null, { status: 302, headers: { location: "/loop" } }));
  await assert.rejects(loop.fetchTasks(), error => error instanceof BackendError && error.code === "authentication");
});
test("Moodle maps offline errors without exposing the raw URL", async () => {
  const connector = new MoodleConnector("https://example.test/?token=synthetic", zone, async () => { throw new Error("token=synthetic"); });
  await assert.rejects(connector.fetchTasks(), error => error instanceof BackendError && error.message === "network");
});
test("Moodle rejects advertised and streaming oversized responses", async () => {
  for (const response of [new Response("", { headers: { "Content-Length": "9000000" } }),
                          new Response(new Uint8Array(MAX_CALENDAR_BYTES + 1))]) {
    const connector = new MoodleConnector("https://example.test/", zone, async () => response);
    await assert.rejects(connector.fetchTasks(), error => error instanceof BackendError && error.code === "tooLarge");
  }
});

async function invoke(input: string): Promise<{ output: string; errors: string; code: number | null }> {
  const worker = fileURLToPath(new URL("../../dist/worker.mjs", import.meta.url));
  // Compiled tests live at .test-build/tests; worker lives at backend/dist.
  const child = spawn(process.execPath, [worker], { stdio: ["pipe", "pipe", "pipe"] });
  const out: Buffer[] = [], err: Buffer[] = [];
  child.stdout.on("data", chunk => out.push(chunk)); child.stderr.on("data", chunk => err.push(chunk));
  const exit = new Promise<number | null>((resolve, reject) => { child.on("close", resolve); child.on("error", reject); });
  child.stdin.end(input);
  const code = await exit;
  return { output: Buffer.concat(out).toString(), errors: Buffer.concat(err).toString(), code };
}
test("worker protocol is versioned and stdout contains JSON only", async () => {
  const response = await invoke(JSON.stringify({ version: 1, command: "health" }));
  assert.equal(response.code, 0); assert.equal(response.errors, "");
  assert.deepEqual(JSON.parse(response.output), { version: 1, ok: true, result: { protocolVersion: 1 } });
});
test("worker protocol rejects malformed/unknown requests without logging input", async () => {
  for (const request of ["broken token=synthetic", JSON.stringify({ version: 99, command: "health", token: "synthetic" }),
                         JSON.stringify({ version: 1, command: "merge", existing: [], tasks: [{ deadline: "NaN" }] })]) {
    const response = await invoke(request);
    assert.equal(response.errors, ""); assert.equal(response.output.includes("synthetic"), false);
    assert.equal(JSON.parse(response.output).ok, false);
  }
});
