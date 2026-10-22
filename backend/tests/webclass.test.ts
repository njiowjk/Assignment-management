import test from "node:test";
import assert from "node:assert/strict";
import { BackendError } from "../src/errors.js";
import { completion, parseContents, parseCourses, WEBCLASS_API, WEBCLASS_BASE } from "../src/connectors/webclass-data.js";
import { decodeWebClassSession, webClassUser, WebClassConnector } from "../src/connectors/webclass.js";
import type { MoodleSession } from "../src/models.js";
import type { Fetch } from "../src/connectors/moodle.js";
import { mergeTasks } from "../src/merge.js";

// Entirely synthetic fixtures with the shape observed in the university's real API.
const course = { id: "synthetic-course", name: "授業" };
const session: MoodleSession = { baseURL: WEBCLASS_BASE, cookies: [
  { name: "WCSynthetic", value: "synthetic", domain: "lms2025.hosei.ac.jp", path: "/webclass/", secure: true }
] };
const content = (extra: Record<string, unknown> = {}) => ({ group_id: course.id, contents_id: "synthetic-content",
  contents_name: "課題", end_date: "2026-10-27 09:00:59", hidden_content: false, hidden_score: false,
  border: null, enquete: false, scores: [score()], ...extra });
const score = (extra: Record<string, unknown> = {}) => ({ user_id: "self", max_score: null, answer_datetime: null, ...extra });
const cfg = '<script type="application/json" class="js-config">' + JSON.stringify({
  API_URL: "/webclass/ip_mods.php/plugin/score_summary_table", TOP_URL: "/webclass/", userWebClassId: "self"
}) + '</script>';
const apiCourse = (id = course.id, teacher = false) => ({ group_id: id, group_name: "授業", perms: { PERM_COURSE_RESULT: teacher } });
const code = (expected: string) => (error: unknown) => error instanceof BackendError && error.code === expected;

test("WebClass stable IDs use course and content IDs, independent of title and deadline", () => {
  const first = parseContents([content()], course, "self")[0]!;
  const changed = parseContents([content({ contents_name: "変更", end_date: "2026-11-01 23:59:59" })], course, "self")[0]!;
  assert.equal(first.externalID, changed.externalID);
  const previous = mergeTasks([], [first], "WebClass", Date.now()).tasks;
  const merged = mergeTasks(previous, [changed], "WebClass", Date.now());
  assert.equal(merged.tasks[0]?.id, previous[0]?.id);
  assert.equal(merged.summary.deadlineChanges, 1);
});
test("WebClass parses JST including seconds without depending on host timezone", () => {
  assert.equal(parseContents([content()], course, "self")[0]?.deadline, Date.parse("2026-10-27T00:00:59Z"));
});
test("WebClass ignores hidden content and items without deadlines, regardless of kind", () => {
  assert.equal(parseContents([content({ hidden_content: true })], course, "self").length, 0);
  assert.equal(parseContents([content({ end_date: null })], course, "self").length, 0);
  assert.equal(parseContents([content({ end_date: "", contents_kind: "Material" })], course, "self").length, 0);
  for (const kind of ["Question", "Report", "Material", "Unit"]) {
    assert.equal(parseContents([content({ contents_kind: kind })], course, "self").length, 1);
  }
});
for (const bad of ["2026-02-30 09:00:00", "2026-10-21T09:00:00", "unknown", "2026-10-21 24:00:00"]) {
  test(`WebClass rejects invalid date ${bad}`, () => assert.throws(() => parseContents([content({ end_date: bad })], course, "self"), code("invalidWebClassData")));
}
test("WebClass refuses changed schema, mixed courses, duplicate identities and duplicate self scores", () => {
  for (const value of [null, {}, [content(), content()], [content({ group_id: "different" })],
    [content({ scores: [score(), score()] })], [content({ hidden_content: "false" })],
    [content({ scores: null })], [content({ border: "bad" })], [content({ enquete: null })]]) {
    assert.throws(() => parseContents(value, course, "self"), code("invalidWebClassData"));
  }
});
test("WebClass uses only the authenticated student's score; missing self is unknown", () => {
  const other = score({ user_id: "other", answer_datetime: "2026-10-20 09:00:00", max_score: 100 });
  assert.equal(parseContents([content({ scores: [other, score()] })], course, "self")[0]?.isCompleted, false);
  assert.equal(parseContents([content({ scores: [other] })], course, "self")[0]?.isCompleted, null);
});
test("WebClass absence of a pass threshold: date confirms submission, zero points is valid", () => {
  assert.equal(completion(content(), score({ answer_datetime: "2026-10-20 09:00:00", max_score: 0 })), true);
  assert.equal(completion(content(), score()), false);
});
test("WebClass visible pass threshold: failing attempts stay unfinished", () => {
  assert.equal(completion(content({ border: 10 }), score({ answer_datetime: "2026-10-20 09:00:00", max_score: 9 })), false);
  assert.equal(completion(content({ border: "10" }), score({ answer_datetime: "2026-10-20 09:00:00", max_score: 10 })), true);
  assert.equal(completion(content({ border: 10 }), score({ answer_datetime: "2026-10-20 09:00:00" })), null);
});
test("WebClass zero threshold is not treated as missing", () => {
  assert.equal(completion(content({ border: 0 }), score({ max_score: 0, answer_datetime: "2026-10-20 09:00:00" })), true);
});
test("WebClass hidden scores follow official student filter rather than infer failure", () => {
  assert.equal(completion(content({ border: 10, hidden_score: true }), score({ answer_datetime: "2026-10-20 09:00:00", max_score: 0 })), true);
  assert.equal(completion(content({ border: 10, hidden_score: true }), score()), false);
});
test("WebClass nonanonymous answered questionnaire completes; anonymous stays unknown", () => {
  assert.equal(completion(content({ enquete: { anonymous: false } }), score()), false);
  assert.equal(completion(content({ enquete: { anonymous: false } }), score({ answer_datetime: "2026-10-20 09:00:00" })), true);
  assert.equal(completion(content({ enquete: { anonymous: true } }), score({ answer_datetime: "2026-10-20 09:00:00" })), null);
});
test("WebClass stores neither scores nor student identity in task payload; links cannot start attempts", () => {
  const task = parseContents([content()], course, "self")[0]!;
  assert.equal(task.sourceURL, WEBCLASS_BASE + "course.php/synthetic-course/login");
  for (const field of ["max_score", "answer_datetime", "user_id", "username", "realname"]) assert.ok(!JSON.stringify(task).includes(field));
});
test("WebClass courses exclude teaching roles and reject ambiguous or hostile IDs", () => {
  assert.deepEqual(parseCourses([apiCourse(), apiCourse("teacher", true)]), [course]);
  for (const rows of [[apiCourse(), apiCourse()], [apiCourse("../escape")], [{}], null]) {
    assert.throws(() => parseCourses(rows), code("invalidWebClassData"));
  }
});
test("WebClass dashboard metadata must match exact observed API and site paths", () => {
  assert.equal(webClassUser(cfg), "self");
  for (const html of ["<form>login</form>", cfg.replace("/webclass/", "https://evil.test/"), cfg.replace("self", "../escape")]) {
    assert.throws(() => webClassUser(html), code("webClassLoginRequired"));
  }
});
test("WebClass accepts only LMS cookies, not portal, IdP, broad SSO, or injected headers", () => {
  assert.equal(decodeWebClassSession(session), session);
  for (const change of [{ domain: "hosei.ac.jp" }, { domain: "idp.hosei.ac.jp" }, { domain: "hoppii2025.hosei.ac.jp" },
    { value: "a\r\nInjected: true" }, { name: "bad name" }, { path: "no-slash" }, { expiresAt: "tomorrow" }]) {
    assert.throws(() => decodeWebClassSession({ ...session, cookies: [{ ...session.cookies[0], ...change }] }), code("webClassLoginRequired"));
  }
  assert.throws(() => decodeWebClassSession({ ...session, baseURL: "https://other.test/" }), code("webClassLoginRequired"));
});

function fetcher(overrides: { courses?: unknown; contents?: unknown; failCourse?: string } = {}): Fetch {
  return async (input, options) => {
    const url = new URL(input);
    assert.equal(options.method, "GET"); assert.equal(options.redirect, "manual");
    assert.equal(options.credentials, "omit"); assert.equal(options.cache, "no-store");
    assert.equal((options.headers as Record<string, string>).Cookie, "WCSynthetic=synthetic");
    assert.equal(url.origin, new URL(WEBCLASS_BASE).origin);
    if (url.pathname.endsWith("/dashboard")) return new Response(cfg);
    if (url.pathname.endsWith("/courses")) return Response.json(overrides.courses ?? [apiCourse()]);
    assert.equal(url.pathname, new URL(WEBCLASS_API).pathname + "/contents");
    if (url.searchParams.get("group_id") === overrides.failCourse) return new Response("unavailable", { status: 503 });
    return Response.json(overrides.contents ?? [content()]);
  };
}
test("WebClass fetch uses only dashboard/courses/contents GETs and returns normalized tasks", async () => {
  const result = await new WebClassConnector(session, fetcher()).fetchTasks();
  assert.equal(result.length, 1); assert.equal(result[0]?.source, "WebClass"); assert.equal(result[0]?.isCompleted, false);
});
test("WebClass server failure in one course rejects the entire fetch", async () => {
  await assert.rejects(new WebClassConnector(session, fetcher({ courses: [apiCourse(), apiCourse("failed")], failCourse: "failed" })).fetchTasks(), code("server"));
});
test("WebClass empty enrollment is a valid empty snapshot", async () => {
  assert.deepEqual(await new WebClassConnector(session, fetcher({ courses: [] })).fetchTasks(), []);
});
for (const status of [302, 401, 403]) {
  test(`WebClass expired session HTTP ${status} never follows login redirects`, async () => {
    let calls = 0;
    await assert.rejects(new WebClassConnector(session, async () => {
      calls++; return new Response(null, { status, headers: { location: "https://idp.hosei.ac.jp/openam/" } });
    }).fetchTasks(), code("webClassLoginRequired"));
    assert.equal(calls, 1);
  });
}
test("WebClass expired or mismatched cookie paths fail before network access", async () => {
  for (const changed of [{ expiresAt: 0 }, { path: "/webclassx/" }]) {
    await assert.rejects(new WebClassConnector({ ...session, cookies: [{ ...session.cookies[0]!, ...changed }] }, async () => {
      assert.fail("must not access network");
    }).fetchTasks(), code("webClassLoginRequired"));
  }
});
test("WebClass HTML login response and malformed JSON never return an empty successful snapshot", async () => {
  for (const text of ["<html>login</html>", "{broken"]) {
    await assert.rejects(new WebClassConnector(session, async input => new Response(new URL(input).pathname.endsWith("/dashboard") ? cfg : text)).fetchTasks(),
      code(text.startsWith("<") ? "webClassLoginRequired" : "invalidWebClassData"));
  }
});
test("WebClass oversized responses are bounded and offline exceptions are redacted", async () => {
  await assert.rejects(new WebClassConnector(session, async () => new Response("x", { headers: { "content-length": "9000000" } })).fetchTasks(), code("tooLarge"));
  await assert.rejects(new WebClassConnector(session, async () => { throw new Error("private synthetic cookie"); }).fetchTasks(), code("network"));
});

test("WebClass bounds the streamed response even without Content-Length", async () => {
  let cancelled = false;
  await assert.rejects(new WebClassConnector(session, async () => new Response(new ReadableStream<Uint8Array>({
    pull(controller) { controller.enqueue(new Uint8Array(1024 * 1024)); },
    cancel() { cancelled = true; }
  }))).fetchTasks(), code("tooLarge"));
  assert.equal(cancelled, true);
});
test("WebClass keeps concurrency at three and scans all enrolled years", async () => {
  let active = 0, max = 0, fetched = 0;
  const courses = Array.from({ length: 7 }, (_, i) => ({ ...apiCourse(`course-${i}`), year: 2025 + i % 2 }));
  const mock: Fetch = async (input, options) => {
    const url = new URL(input);
    if (url.pathname.endsWith("/contents")) {
      active++; max = Math.max(max, active);
      await new Promise(resolve => setTimeout(resolve, 2));
      active--; fetched++;
      return Response.json([content({ group_id: url.searchParams.get("group_id") })]);
    }
    return fetcher({ courses })(input, options);
  };
  assert.equal((await new WebClassConnector(session, mock).fetchTasks()).length, 7);
  assert.equal(max, 3); assert.equal(fetched, 7);
});
