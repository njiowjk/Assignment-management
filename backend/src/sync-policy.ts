import { BackendError } from "./errors.js";
import { record, source, timestamp } from "./validation.js";
import type { TaskSource } from "./models.js";

type Trigger = "startup" | "timer" | "wake" | "network" | "manual";
type Outcome = "success" | "transient" | "attention" | "cancelled";
interface State { source: TaskSource; lastAttemptAt: number | null; failureCount: number; blocked: boolean }

/** Pure scheduling policy. It never reads credentials or starts a network request. */
export function syncPolicy(input: unknown): { states: State[]; due: TaskSource[]; nextRunAt: number | null } {
  const r = record(input), now = timestamp(r.now), interval = r.intervalSeconds;
  if (typeof interval !== "number" || ![900, 1800, 3600, 7200].includes(interval) ||
      !["startup", "timer", "wake", "network", "manual"].includes(String(r.trigger)) ||
      !Array.isArray(r.states) || r.states.length > 2 || !Array.isArray(r.enabled) || r.enabled.length > 2) {
    throw new BackendError("backend");
  }
  const states: State[] = r.states.map(value => {
    const s = record(value);
    if (!Number.isInteger(s.failureCount) || Number(s.failureCount) < 0 || Number(s.failureCount) > 20 || typeof s.blocked !== "boolean") {
      throw new BackendError("backend");
    }
    return { source: source(s.source), lastAttemptAt: s.lastAttemptAt == null ? null : timestamp(s.lastAttemptAt),
      failureCount: Number(s.failureCount), blocked: s.blocked };
  });
  if (new Set(states.map(s => s.source)).size !== states.length) throw new BackendError("backend");
  const enabled = r.enabled.map(source);
  if (new Set(enabled).size !== enabled.length) throw new BackendError("backend");
  for (const s of enabled) if (!states.some(state => state.source === s)) states.push({ source: s, lastAttemptAt: null, failureCount: 0, blocked: false });
  // Persist the clamp once if the user moves the system clock backwards.
  for (const s of states) if (s.lastAttemptAt !== null && s.lastAttemptAt > now) s.lastAttemptAt = now;
  if (r.event != null) {
    const event = record(r.event), target = source(event.source), outcome = String(event.outcome) as Outcome;
    if (!["success", "transient", "attention", "cancelled"].includes(outcome)) throw new BackendError("backend");
    let s = states.find(s => s.source === target);
    if (!s) { s = { source: target, lastAttemptAt: null, failureCount: 0, blocked: false }; states.push(s); }
    s.lastAttemptAt = now;
    if (outcome === "success") { s.failureCount = 0; s.blocked = false; }
    if (outcome === "transient") { s.failureCount = Math.min(20, s.failureCount + 1); s.blocked = false; }
    if (outcome === "attention") s.blocked = true;
  }
  const due: TaskSource[] = [], times: number[] = [];
  for (const s of states) {
    if (!enabled.includes(s.source)) continue;
    if ((r.trigger as Trigger) === "manual") { due.push(s.source); continue; }
    if (s.blocked) continue;
    // Retry at 1, 2, 4, 8... minutes, capped at the configured interval.
    const delay = (s.failureCount ? Math.min(interval, 60 * 2 ** (s.failureCount - 1)) : interval) * 1000;
    const next = s.lastAttemptAt === null ? now : Math.min(s.lastAttemptAt, now) + delay;
    if (next <= now || (r.trigger === "startup" && s.failureCount === 0)) due.push(s.source);
    times.push(next);
  }
  return { states, due, nextRunAt: times.length ? Math.min(...times) : null };
}
