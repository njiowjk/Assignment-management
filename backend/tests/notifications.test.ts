import test from "node:test";
import assert from "node:assert/strict";
import { notificationPlan, type NotificationState } from "../src/notifications.js";
import { BackendError } from "../src/errors.js";

const now = Date.parse("2026-10-22T03:00:00Z");
const id = "00000000-0000-0000-0000-000000000001";
const task = (extra: Record<string, unknown> = {}) => ({ id, externalID: "synthetic", source: "Moodle", courseName: "授業", title: "課題",
  deadline: now + 172_800_000, status: "active", firstDetectedAt: now, lastSyncedAt: now,
  completionIsKnown: true, isRemovedFromSource: false, ...extra });
const preferences = { enabled: true, newTask: true, dayBefore: true, hoursBefore: true, deadlineChanged: true, overdue: true, sound: true };
const empty = (): NotificationState => ({ observations: [], sources: [], receipts: [], events: [] });
const input = (extra: Record<string, unknown> = {}) => ({ now, tasks: [task()], syncedSources: ["Moodle"], preferences, state: empty(), ...extra });
const baseline = () => notificationPlan(input()).state;

test("notifications: first enable is silent except future deadline reservations", () => {
  const plan = notificationPlan(input());
  assert.deepEqual(plan.requests.map(x => x.kind), ["dayBefore", "hoursBefore", "overdue"]);
  assert.ok(plan.requests.every(x => x.fireAt > now));
  assert.equal(plan.state.observations.length, 1);
});
test("notifications: first historical import and old deadlines never produce a burst", () => {
  const plan = notificationPlan(input({ tasks: [task({ deadline: now - 1000 })] }));
  assert.equal(plan.requests.length, 0); assert.equal(plan.state.events.length, 0);
});
test("notifications: a new task in a baselined LMS generates one durable immediate event", () => {
  const added = task({ id: "00000000-0000-0000-0000-000000000002" });
  const plan = notificationPlan(input({ state: baseline(), tasks: [task(), added] }));
  assert.equal(plan.requests.filter(x => x.kind === "newTask").length, 1);
  assert.equal(plan.state.events.length, 1);
  assert.equal(notificationPlan(input({ state: plan.state, tasks: [task(), added] })).state.events.length, 1);
  const journal = JSON.stringify(plan.state);
  for (const privateField of ["課題", "授業", "synthetic", "https"]) assert.ok(!journal.includes(privateField));
});
test("notifications: first import of a second LMS is independently baselined", () => {
  const plan = notificationPlan(input({ state: baseline(), syncedSources: ["Moodle", "WebClass"], tasks: [task(), task({
    id: "00000000-0000-0000-0000-000000000002", source: "WebClass" })] }));
  assert.equal(plan.requests.filter(x => x.kind === "newTask").length, 0);
  assert.deepEqual(plan.state.sources, ["Moodle", "WebClass"]);
});
test("notifications: unconfirmed, completed, missing, and unavailable tasks have no valid notification", () => {
  for (const extra of [{ completionIsKnown: false }, { status: "completed" }, { isRemovedFromSource: true }, { status: "unavailable" }]) {
    const plan = notificationPlan(input({ state: baseline(), tasks: [task(extra)] }));
    assert.deepEqual(plan.requests, []); assert.deepEqual(plan.validIDs, []);
  }
});
test("notifications: disabling every type or the master toggle cancels its identifiers", () => {
  for (const settings of [{ ...preferences, enabled: false }, Object.fromEntries(Object.keys(preferences).map(k => [k, k === "enabled"]))]) {
    const plan = notificationPlan(input({ preferences: settings, state: baseline() }));
    assert.deepEqual(plan.requests, []); assert.deepEqual(plan.validIDs, []);
  }
});
test("notifications: deadline changes cancel old IDs and reserve new reminders with one immediate alert", () => {
  const before = notificationPlan(input());
  const plan = notificationPlan(input({ state: before.state, tasks: [task({ deadline: now + 259_200_000 })] }));
  assert.equal(plan.requests.filter(x => x.kind === "deadlineChanged").length, 1);
  assert.ok(before.validIDs.every(x => !plan.validIDs.includes(x)));
  assert.equal(plan.state.observations[0]?.revision, 1);
});
test("notifications: changing back to an earlier deadline uses a new revision", () => {
  const changed = notificationPlan(input({ state: baseline(), tasks: [task({ deadline: now + 259_200_000 })] }));
  const back = notificationPlan(input({ state: changed.state }));
  assert.equal(back.state.observations[0]?.revision, 2);
  assert.ok(back.requests.every(x => x.id.includes(".2.")));
});
test("notifications: durable receipts deduplicate due reminders across a restart / JSON roundtrip", () => {
  const before = notificationPlan(input()), due = before.requests[0]!;
  const state = JSON.parse(JSON.stringify({ ...before.state, receipts: [{ id: due.id, fireAt: due.fireAt }] }));
  const atDeadline = notificationPlan(input({ now: due.fireAt, state }));
  assert.ok(!atDeadline.requests.some(x => x.id === due.id));
  assert.ok(atDeadline.validIDs.includes(due.id)); // don't cancel an OS request at its delivery boundary
});
test("notifications: a missing OS reservation may be restored before its due date", () => {
  const before = notificationPlan(input()), due = before.requests[0]!;
  const state = { ...before.state, receipts: [{ id: due.id, fireAt: due.fireAt }] };
  assert.ok(notificationPlan(input({ state })).requests.some(x => x.id === due.id));
});
test("notifications: failed immediate add stays in outbox, success receipt prevents replay", () => {
  const tasks = [task(), task({ id: "00000000-0000-0000-0000-000000000002" })];
  const plan = notificationPlan(input({ state: baseline(), tasks }));
  const alert = plan.requests.find(x => x.kind === "newTask")!;
  assert.ok(notificationPlan(input({ state: plan.state, tasks })).requests.some(x => x.id === alert.id));
  const state = { ...plan.state, receipts: [{ id: alert.id, fireAt: alert.fireAt }] };
  assert.ok(!notificationPlan(input({ state, tasks })).requests.some(x => x.id === alert.id));
});
test("notifications: title updates do not produce a new-task event", () => {
  const plan = notificationPlan(input({ state: baseline(), tasks: [task({ title: "改題" })] }));
  assert.ok(plan.requests.every(x => x.title === "改題"));
  assert.equal(plan.state.events.length, 0);
});
test("notifications: a brief timer drift is allowed but waking a day later never backfills missed alerts", () => {
  const state = baseline();
  assert.ok(notificationPlan(input({ state, now: now + 86_400_001 })).requests.some(x => x.kind === "dayBefore"));
  assert.ok(!notificationPlan(input({ state, now: now + 87_000_000 })).requests.some(x => x.kind === "dayBefore"));
});
test("notifications: past-due task discovered later is not a new task notification", () => {
  const plan = notificationPlan(input({ state: baseline(), tasks: [task(), task({
    id: "00000000-0000-0000-0000-000000000002", deadline: now - 1 })] }));
  assert.equal(plan.state.events.length, 0);
});
test("notifications: completion prunes pending immediate events and receipts", () => {
  const changed = notificationPlan(input({ state: baseline(), tasks: [task({ deadline: now + 259_200_000 })] }));
  const result = notificationPlan(input({ state: changed.state, tasks: [task({ status: "completed", deadline: now + 259_200_000 })] }));
  assert.deepEqual(result.state.events, []); assert.deepEqual(result.requests, []);
});
test("notifications: reservations are bounded and nearest-first", () => {
  const tasks = Array.from({ length: 30 }, (_, i) => task({ id: `00000000-0000-0000-0000-${String(i).padStart(12, "0")}`, deadline: now + (i + 2) * 86_400_000 }));
  const plan = notificationPlan(input({ tasks }));
  assert.equal(plan.requests.length, 48);
  assert.ok(plan.requests.every((x, i) => i === 0 || x.fireAt >= plan.requests[i - 1]!.fireAt));
});
test("notifications: due immediate notifications are rate-limited and kept for later retry", () => {
  const tasks = Array.from({ length: 8 }, (_, i) => task({ id: `00000000-0000-0000-0000-${String(i).padStart(12, "0")}` }));
  const plan = notificationPlan(input({ tasks, state: baseline() }));
  assert.ok(plan.requests.filter(x => x.kind === "newTask").length <= 5);
  assert.equal(plan.state.events.length, 7);
});
test("notifications: input objects are not mutated", () => {
  const value = input({ state: baseline() }), copy = JSON.stringify(value);
  notificationPlan(value); assert.equal(JSON.stringify(value), copy);
});
for (const bad of [{ now: NaN }, { tasks: [task(), task()] }, { preferences: { ...preferences, enabled: "true" } },
  { syncedSources: ["unknown"] }, { state: { ...empty(), sources: ["Moodle", "Moodle"] } },
  { state: { ...empty(), receipts: [{ id: "arbitrary", fireAt: now }] } },
  { state: { ...empty(), observations: [{ taskID: id, deadline: now, revision: -1 }] } }]) {
  test(`notifications reject invalid input ${JSON.stringify(bad)}`, () => {
    assert.throws(() => notificationPlan(input(bad)), e => e instanceof BackendError && e.code === "backend");
  });
}
