import test from "node:test";
import assert from "node:assert/strict";
import { syncPolicy } from "../src/sync-policy.js";
import { BackendError } from "../src/errors.js";

const now = Date.parse("2026-10-22T03:00:00Z");
const state = (extra: Record<string, unknown> = {}) => ({ source: "Moodle", lastAttemptAt: now, failureCount: 0, blocked: false, ...extra });
const request = (extra: Record<string, unknown> = {}) => ({ now, intervalSeconds: 1800, trigger: "timer", states: [state()], enabled: ["Moodle"], ...extra });

test("policy: first startup syncs each enabled source once", () => {
  const plan = syncPolicy(request({ trigger: "startup", states: [], enabled: ["Moodle", "WebClass"] }));
  assert.deepEqual(plan.due, ["Moodle", "WebClass"]);
  assert.equal(plan.states.length, 2);
});
test("policy: recent success is not due on a regular timer, wake, or restored network", () => {
  for (const trigger of ["timer", "wake", "network"]) {
    const plan = syncPolicy(request({ trigger }));
    assert.deepEqual(plan.due, []); assert.equal(plan.nextRunAt, now + 1800000);
  }
});
test("policy: exact interval is due; before it is not", () => {
  assert.deepEqual(syncPolicy(request({ now: now + 1800000 })).due, ["Moodle"]);
  assert.deepEqual(syncPolicy(request({ now: now + 1799999 })).due, []);
});
test("policy: a long sleep coalesces all missed intervals to one sync per source", () => {
  const plan = syncPolicy(request({ now: now + 86400000, trigger: "wake" }));
  assert.deepEqual(plan.due, ["Moodle"]);
});
test("policy: settings choose 15/30/60/120 minutes and recalculate from last attempt", () => {
  for (const intervalSeconds of [900, 1800, 3600, 7200]) {
    assert.equal(syncPolicy(request({ intervalSeconds })).nextRunAt, now + intervalSeconds * 1000);
  }
});
test("policy: transient errors back off exponentially, capped by selected interval", () => {
  let states: unknown[] = [state()];
  for (let i = 1; i <= 8; i++) {
    const result = syncPolicy(request({ states, event: { source: "Moodle", outcome: "transient" } }));
    assert.equal(result.nextRunAt, now + Math.min(1800, 60 * 2 ** (i - 1)) * 1000);
    assert.equal(result.states[0]?.failureCount, i); states = result.states;
  }
});
test("policy: a restart cannot bypass persisted network backoff", () => {
  assert.deepEqual(syncPolicy(request({ trigger: "startup", states: [state({ failureCount: 1 })] })).due, []);
});
test("policy: success resets retry failures and clears the attention block", () => {
  const plan = syncPolicy(request({ states: [state({ failureCount: 5, blocked: true })], event: { source: "Moodle", outcome: "success" } }));
  assert.equal(plan.states[0]?.failureCount, 0); assert.equal(plan.states[0]?.blocked, false);
  assert.equal(plan.nextRunAt, now + 1800000);
});
test("policy: authentication/configuration errors pause automatic sync across restarts", () => {
  const states = syncPolicy(request({ event: { source: "Moodle", outcome: "attention" } })).states;
  for (const trigger of ["startup", "timer", "wake", "network"]) {
    const plan = syncPolicy(request({ states, trigger, now: now + 86400000 }));
    assert.deepEqual(plan.due, []); assert.equal(plan.nextRunAt, null);
  }
  assert.deepEqual(syncPolicy(request({ states, trigger: "manual" })).due, ["Moodle"]);
});
test("policy: pausing Moodle does not block healthy WebClass", () => {
  const plan = syncPolicy(request({ trigger: "startup", enabled: ["Moodle", "WebClass"], states: [state({ blocked: true })] }));
  assert.deepEqual(plan.due, ["WebClass"]);
});
test("policy: unconfigured sources never run, including on manual trigger", () => {
  assert.deepEqual(syncPolicy(request({ enabled: [], trigger: "manual" })).due, []);
  assert.equal(syncPolicy(request({ enabled: [] })).nextRunAt, null);
});
test("policy: cancelled requests are not recorded as success and avoid retry storms", () => {
  const plan = syncPolicy(request({ states: [state({ failureCount: 2 })], event: { source: "Moodle", outcome: "cancelled" } }));
  assert.equal(plan.states[0]?.failureCount, 2); assert.equal(plan.nextRunAt, now + 120000);
});
test("policy: clock rollback is clamped once and does not defer forever", () => {
  const first = syncPolicy(request({ states: [state({ lastAttemptAt: now + 3600000 })] }));
  assert.equal(first.states[0]?.lastAttemptAt, now);
  assert.deepEqual(syncPolicy(request({ states: first.states, now: now + 1800000 })).due, ["Moodle"]);
});
test("policy: input is immutable and state survives JSON persistence", () => {
  const input = request(), before = JSON.stringify(input);
  const first = syncPolicy(input); assert.equal(JSON.stringify(input), before);
  assert.deepEqual(syncPolicy(request({ states: JSON.parse(JSON.stringify(first.states)) })).states, first.states);
});
for (const extra of [{ intervalSeconds: 1 }, { intervalSeconds: "1800" }, { trigger: "invalid" }, { now: NaN },
  { states: [state({ failureCount: -1 })] }, { states: [state({ failureCount: 21 })] }, { states: [state({ blocked: "false" })] },
  { states: [state(), state()] }, { enabled: ["Moodle", "Moodle"] }, { enabled: ["invalid"] },
  { event: { source: "Moodle", outcome: "invalid" } }]) {
  test(`policy rejects malformed state ${JSON.stringify(extra)}`, () => {
    assert.throws(() => syncPolicy(request(extra)), e => e instanceof BackendError && e.code === "backend");
  });
}
