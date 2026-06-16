import { expect, test } from "bun:test";
import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { breakerTrips, nextBackoff, formatPidfile, parsePidfile, killBridge } from "./supervisor";
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
