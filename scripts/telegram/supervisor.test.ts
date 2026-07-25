import { expect, test } from "bun:test";
import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { breakerTrips, nextBackoff, nextFailCount, resolveMaxFails, formatPidfile, parsePidfile, killBridge, IMMEDIATE_MS, MAX_FAILS } from "./supervisor";
test("breaker trips after N immediate crashes; resets implied by caller", () => {
  expect(breakerTrips(3, 3)).toBe(true);
  expect(breakerTrips(2, 3)).toBe(false);
});
test("backoff grows with consecutive failures and is bounded", () => {
  expect(nextBackoff(0)).toBeLessThan(nextBackoff(3));
  expect(nextBackoff(100)).toBeLessThanOrEqual(60000);   // capped at 60s
});
test("pidfile round-trips supervisor + poller pids", () => {
  expect(parsePidfile(formatPidfile({ supervisor: 100, poller: 200 }))).toEqual({ supervisor: 100, poller: 200 });
  expect(parsePidfile(formatPidfile({ supervisor: 100, poller: null }))).toEqual({ supervisor: 100, poller: null });
});
test("parsePidfile rejects garbage / missing supervisor pid", () => {
  expect(parsePidfile("not json")).toBeNull();
  expect(parsePidfile(JSON.stringify({ poller: 5 }))).toBeNull();   // no supervisor
  expect(parsePidfile(JSON.stringify({ supervisor: "x" }))).toBeNull();
});
test("parsePidfile rejects non-positive / non-integer pids (no process-group kill)", () => {
  expect(parsePidfile(JSON.stringify({ supervisor: -1 }))).toBeNull();      // negative = process group on POSIX
  expect(parsePidfile(JSON.stringify({ supervisor: 0 }))).toBeNull();
  expect(parsePidfile(JSON.stringify({ supervisor: 3.5 }))).toBeNull();
  expect(parsePidfile(JSON.stringify({ supervisor: 100, poller: -2 }))).toEqual({ supervisor: 100, poller: null });   // bad poller → null
});

// killBridge resolves the pidfile via BRIDGE_ROOT at call time, so each test
// runs against a fresh temp root (restored after) and an injected killFn —
// the real bridge / real pids are never touched.
function withBridgeRoot(fn: (root: string) => void): void {
  const prev = process.env.BRIDGE_ROOT;
  const root = mkdtempSync(join(tmpdir(), "sup-kill-"));
  process.env.BRIDGE_ROOT = root;
  try { fn(root); }
  finally {
    if (prev === undefined) delete process.env.BRIDGE_ROOT; else process.env.BRIDGE_ROOT = prev;
    rmSync(root, { recursive: true, force: true });
  }
}
const errWithCode = (code: string) => Object.assign(new Error(code), { code });

test("killBridge: non-ESRCH signal failure → rc 2 + pidfile KEPT (retry can still find the bridge)", () => {
  withBridgeRoot((root) => {
    const pidfile = join(root, "supervisor.pid");
    writeFileSync(pidfile, formatPidfile({ supervisor: 100, poller: 200 }), "utf8");
    expect(killBridge(() => { throw errWithCode("EPERM"); })).toBe(2);
    expect(existsSync(pidfile)).toBe(true);   // clearing it would make a retry report "not running"
  });
});

test("killBridge: ESRCH (already gone) → rc 0 + pidfile cleared", () => {
  withBridgeRoot((root) => {
    const pidfile = join(root, "supervisor.pid");
    writeFileSync(pidfile, formatPidfile({ supervisor: 100, poller: 200 }), "utf8");
    expect(killBridge(() => { throw errWithCode("ESRCH"); })).toBe(0);
    expect(existsSync(pidfile)).toBe(false);
  });
});

test("killBridge: supervisor kill OK, poller kill EPERM → rc 2 + pidfile KEPT", () => {
  withBridgeRoot((root) => {
    const pidfile = join(root, "supervisor.pid");
    writeFileSync(pidfile, formatPidfile({ supervisor: 100, poller: 200 }), "utf8");
    let callCount = 0;
    // First call (supervisor pid 100) succeeds; second call (poller pid 200) throws EPERM.
    expect(killBridge((pid) => {
      callCount++;
      if (callCount === 2) throw errWithCode("EPERM");
    })).toBe(2);
    expect(callCount).toBe(2);   // both pids were attempted
    expect(existsSync(pidfile)).toBe(true);   // pidfile kept so retry can find bridge
  });
});

// --- /restart interaction with the circuit breaker (HIMMEL-1272) ---

test("an intentional /restart of a HEALTHY poller never walks toward the breaker", () => {
  // Exercises the PRODUCTION accounting (nextFailCount + breakerTrips + the real
  // IMMEDIATE_MS / MAX_FAILS), not a restatement of it — a test that re-implements
  // the rule keeps passing after main() drifts away from it.
  // A FIXED local threshold, not the env-derived MAX_FAILS: an operator with
  // POLLER_MAX_FAILS exported would otherwise silently change what this test
  // exercises (loop bounds and the trip point), which is not something a unit
  // test's meaning should depend on.
  const MAX = 5;
  let fails = 0;
  for (let i = 0; i < MAX * 4; i++) {
    fails = nextFailCount(fails, IMMEDIATE_MS * 12);   // healthy uptime, then /restart
    expect(fails).toBe(0);
    expect(breakerTrips(fails, MAX)).toBe(false);
  }
  // …whereas a poller that dies immediately on boot still trips at MAX.
  fails = 0;
  for (let i = 0; i < MAX; i++) fails = nextFailCount(fails, 10);
  expect(breakerTrips(fails, MAX)).toBe(true);
  // …and one healthy run in between clears the accumulated count.
  fails = nextFailCount(fails, IMMEDIATE_MS);          // the boundary IS a healthy run
  expect(fails).toBe(0);
  expect(breakerTrips(fails, MAX)).toBe(false);
});

test("resolveMaxFails rejects values that would DISABLE or hair-trigger the breaker (HIMMEL-1272 CR)", () => {
  // NaN is the dangerous one: `fails >= NaN` is always false, so a garbage value
  // would silently disable the breaker and let a crash-looping poller spin forever.
  // "9007199254740993" parses to a valid integer ABOVE MAX_SAFE_INTEGER — a
  // threshold that large is a disabled breaker by another route, so isSafeInteger
  // (not isInteger) is the right predicate.
  for (const bad of ["", "   ", "garbage", "NaN", "1.5", "-1", "0", "1e999", "9007199254740993", "1e300"]) {
    expect(resolveMaxFails(bad)).toBe(5);
    expect(Number.isInteger(resolveMaxFails(bad))).toBe(true);
  }
  // Explicit blank input ONLY — resolveMaxFails(undefined) defaults its parameter
  // to process.env.POLLER_MAX_FAILS, so asserting 5 there would fail on a machine
  // that legitimately sets it. That is the same env-dependence the last round
  // flagged, reintroduced by the fix for it.
  expect(resolveMaxFails("")).toBe(5);
  expect(Number.isSafeInteger(resolveMaxFails("9007199254740993"))).toBe(true);
  // …and a legitimate override still wins.
  expect(resolveMaxFails("1")).toBe(1);
  expect(resolveMaxFails("12")).toBe(12);
  // The hair-trigger end matters for /restart: with MAX_FAILS=0 the breaker would
  // trip on the FIRST exit, so a deliberate rung-1 bounce would halt the bridge.
  expect(breakerTrips(nextFailCount(0, IMMEDIATE_MS * 12), resolveMaxFails("0"))).toBe(false);
});
