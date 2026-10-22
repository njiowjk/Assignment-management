import assert from "node:assert/strict";
import { test } from "node:test";
import { BackendError } from "../src/errors.js";
import { automaticCompletionFromHTML, checkCompletions, completionFromHTML } from "../src/connectors/moodle-completion.js";
import { configurationFromHTML, cookieHeader, decodeSession, MoodleSessionClient } from "../src/connectors/moodle-session.js";
import type { Fetch } from "../src/connectors/moodle.js";
import { mergeTasks } from "../src/merge.js";
import type { MoodleSession, RemoteTask } from "../src/models.js";

const base = new URL("https://example.test/moodle/");
const feed = new URL("https://example.test/moodle/calendar/export_execute.php?authtoken=synthetic");
const session: MoodleSession = { baseURL: base.href, cookies: [
  { name: "MoodleSession", value: "synthetic", domain: "example.test", path: "/moodle/", secure: true },
] };
const labels = new Map([
  ["assign:submissionstatus", "提出ステータス"], ["assign:nosubmissionyet", "未提出"],
  ["quiz:statefinished", "終了"], ["quiz:stateinprogress", "進行中"], ["quiz:stateoverdue", "期限超過"],
]);
function html(module = "assign", content = "", authenticated = true): string {
  return `<html><body id="page-mod-${module}-view"><script>M.cfg = ${JSON.stringify({
    wwwroot: "https://example.test/moodle", sesskey: "syntheticSessionKey", userId: authenticated ? 42 : 0,
  })};</script><main>${content}</main></body></html>`;
}
function status(state: string): string {
  return `<table class="submissionstatustable"><tr><th>提出ステータス</th><td class="submissionstatus${state}">${state}</td></tr></table>`;
}
function task(id = "1"): RemoteTask {
  return { externalID: `${id}@example.test`, title: "課題", courseName: "授業", source: "Moodle", deadline: 1234 };
}
const failAuth = (error: unknown): boolean => error instanceof BackendError && error.code === "moodleLoginRequired";

test("assignment submitted is complete even if grading is pending", () => {
  assert.equal(completionFromHTML(html("assign", status("submitted") + '<div class="submissionnotgraded">未採点</div>'), "assign", labels), true);
});
for (const state of ["draft", "reopened"]) test(`assignment ${state} is incomplete`, () => {
  assert.equal(completionFromHTML(html("assign", status(state)), "assign", labels), false);
});
test("assignment no submission uses Moodle's own translated label", () => {
  const page = html("assign", '<table class="submissionstatustable"><tr><th>提出ステータス</th><td>未提出</td></tr></table>');
  assert.equal(completionFromHTML(page, "assign", labels), false);
  assert.equal(completionFromHTML(page, "assign", new Map()), null);
});
test("grade/deadline/general text do not imply submission", () => {
  assert.equal(completionFromHTML(html("assign", '<div class="submissiongraded">100</div><p>提出済み</p>'), "assign", labels), null);
});
test("HTML outside the submission table cannot hide an assignment", () => {
  assert.equal(completionFromHTML(html("assign", '<div class="submissionstatussubmitted">example</div>'), "assign", labels), null);
});
test("quiz finished attempt is complete; active attempt takes priority", () => {
  const table = (state: string) => `<table class="quizattemptsummary"><tbody><tr><td>1</td><td>${state}<span class="statedetails">details</span></td></tr></tbody></table>`;
  assert.equal(completionFromHTML(html("quiz", table("終了")), "quiz", labels), true);
  assert.equal(completionFromHTML(html("quiz", table("終了") + table("進行中")), "quiz", labels), false);
  assert.equal(completionFromHTML(html("quiz", table("期限超過")), "quiz", labels), false);
});
test("quiz without attempts is incomplete only with actual start form", () => {
  assert.equal(completionFromHTML(html("quiz", '<form action="https://example.test/moodle/mod/quiz/startattempt.php"></form>'), "quiz", labels), false);
  assert.equal(completionFromHTML(html("quiz"), "quiz", labels), null);
});
test("automatic completion requires all actual conditions complete; manual buttons ignored", () => {
  const fragment = (classes: string[]) => `<div data-region="completionrequirements">${classes.map(value => `<div role="listitem" class="${value}">rule</div>`).join("")}</div>`;
  assert.equal(automaticCompletionFromHTML(fragment(["alert-success", "alert-success"])), true);
  assert.equal(automaticCompletionFromHTML(fragment(["alert-success", "bg-light"])), false);
  assert.equal(automaticCompletionFromHTML('<button data-action="toggle-manual-completion">Done</button>'), null);
});
test("parse login metadata rejects anonymous or wrong-origin pages", () => {
  assert.equal(configurationFromHTML(html(), base).userId, 42);
  assert.throws(() => configurationFromHTML(html("assign", "", false), base), failAuth);
  assert.throws(() => configurationFromHTML('<body class="notloggedin"><form id="login"></form></body>', base), failAuth);
  assert.throws(() => configurationFromHTML(html(), new URL("https://different.test/")), failAuth);
});
test("session validation rejects other origins and header injection", () => {
  assert.deepEqual(decodeSession(session, feed), session);
  assert.throws(() => decodeSession({ ...session, baseURL: "https://different.test/" }, feed), failAuth);
  assert.throws(() => decodeSession({ ...session, cookies: [{ ...session.cookies[0], value: "x\r\nleak" }] }, feed), failAuth);
});
test("cookie header obeys origin, path boundary and expiry", () => {
  assert.equal(cookieHeader(session, new URL("my/", base)), "MoodleSession=synthetic");
  assert.equal(cookieHeader(session, new URL("https://example.test/moodlex/")), "");
  assert.equal(cookieHeader({ ...session, cookies: [{ ...session.cookies[0]!, expiresAt: 1 }] }, base), "");
  assert.throws(() => cookieHeader(session, new URL("https://different.test/")), failAuth);
});
test("authenticated redirects cannot send cookies to another origin", async () => {
  let count = 0;
  const client = new MoodleSessionClient(session, async () => { count++; return new Response(null, { status: 302, headers: { location: "https://different.test/" } }); });
  await assert.rejects(client.authenticate(), failAuth); assert.equal(count, 1);
});

function fetchFixture(options: { expire?: boolean; generic?: boolean } = {}): { fetch: Fetch; paths: string[] } {
  const paths: string[] = [];
  return { paths, fetch: async (url, init) => {
    paths.push(url.pathname);
    assert.equal((init.headers as Record<string, string>).Cookie, "MoodleSession=synthetic");
    assert.equal(url.origin, base.origin);
    if (url.pathname.endsWith("/my/")) return new Response(html());
    if (url.pathname.endsWith("/lib/ajax/service.php")) {
      const calls = JSON.parse(String(init.body)) as { methodname: string; args: { strings?: { stringid: string; component: string }[]; eventid?: number } }[];
      return new Response(JSON.stringify(calls.map(call => {
        if (options.expire) return { error: true, exception: { errorcode: "invalidsesskey" } };
        if (call.methodname === "core_get_strings") return { error: false, data: call.args.strings!.map(value => ({ ...value, string: labels.get(value.component + ":" + value.stringid) ?? value.stringid })) };
        if (call.methodname === "core_course_get_module") return { error: false, data: '<div data-region="completionrequirements"><div role="listitem" class="alert-success">Done</div></div>' };
        return { error: false, data: { event: { id: call.args.eventid, modulename: options.generic ? "feedback" : "assign", instance: call.args.eventid, action: null } } };
      })));
    }
    return new Response(html("assign", status(url.searchParams.get("id") === "1" ? "submitted" : "draft")));
  } };
}
test("full completion pipeline resolves missing page URL and rechecks old cached deadlines", async () => {
  const fixture = fetchFixture();
  const cached = mergeTasks([], [task("2")], "Moodle", 1).tasks;
  const result = await checkCompletions([task()], cached, session, fixture.fetch);
  assert.equal(result[0]?.isCompleted, true); assert.equal(result[0]?.sourceURL, "https://example.test/moodle/mod/assign/view.php?id=1");
  assert.equal(result[1]?.isCompleted, false); assert.equal(result[1]?.isRemovedFromSource, true);
  const saved = mergeTasks(cached, result, "Moodle", 2).tasks;
  assert.equal(saved.find(row => row.externalID.startsWith("1@"))?.status, "completed");
  assert.equal(saved.find(row => row.externalID.startsWith("2@"))?.isRemovedFromSource, true);
});
test("generic activity reads course fragment without visiting and marking it viewed", async () => {
  const fixture = fetchFixture({ generic: true });
  assert.equal((await checkCompletions([task()], [], session, fixture.fetch))[0]?.isCompleted, true);
  assert.equal(fixture.paths.some(path => path.includes("/mod/feedback/")), false);
});
test("expired authenticated session fails instead of marking all completed", async () => {
  const fixture = fetchFixture({ expire: true });
  await assert.rejects(checkCompletions([task()], [], session, fixture.fetch), failAuth);
});
test("null calendar action alone is not evidence of completion", async () => {
  const fixture = fetchFixture();
  const result = await checkCompletions([task("2")], [], session, fixture.fetch);
  assert.equal(result[0]?.isCompleted, false);
});
test("unrecognised activity markup stays unknown and never disappears", async () => {
  const fixture = fetchFixture();
  const fetcher: Fetch = (url, init) => url.pathname.includes("/mod/assign/") ? Promise.resolve(new Response(html("assign", "layout changed"))) : fixture.fetch(url, init);
  const checked = await checkCompletions([task()], [], session, fetcher);
  const saved = mergeTasks([], checked, "Moodle", 2).tasks;
  assert.equal(saved[0]?.completionIsKnown, false); assert.equal(saved[0]?.status, "active");
});
