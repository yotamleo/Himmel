import { spawn } from "bun";
import { mkdirSync, readFileSync, writeFileSync, unlinkSync } from "node:fs";
import { dirname, join } from "node:path";
import { bridgeRoot } from "./bus";
import { installTimestampedLogging } from "./log-timestamp";

export function breakerTrips(consecutiveImmediateFails: number, maxFails: number): boolean {
  return consecutiveImmediateFails >= maxFails;
}
// exponential backoff in ms, capped at 60s.
export function nextBackoff(consecutiveFails: number): number {
  return Math.min(60000, 1000 * Math.pow(2, Math.max(0, consecutiveFails)));
}

const DEFAULT_MAX_FAILS = 5;
// POLLER_MAX_FAILS validation (HIMMEL-1272 CR). A bare
// `Number(process.env.POLLER_MAX_FAILS ?? 5)` turns any garbage into NaN, and
// `fails >= NaN` is ALWAYS false — the breaker would never trip and a
// crash-looping poller would spin forever, which is the exact opposite of what
// the breaker is for. The other end is worse for /restart specifically: `=0`
// makes `fails >= 0` true on the FIRST exit, so a deliberate rung-1 bounce would
// halt the bridge and leave no channel to report it on. Both fall back to the
// documented default, loudly.
export function resolveMaxFails(raw: string | undefined = process.env.POLLER_MAX_FAILS): number {
  if (raw === undefined || raw.trim() === "") return DEFAULT_MAX_FAILS;
  const n = Number(raw);
  // isSafeInteger, not isInteger: "9007199254740993" parses to a valid integer
  // ABOVE Number.MAX_SAFE_INTEGER, and a threshold that large means `fails >= n`
  // is never true in practice — the same silently-disabled breaker as the NaN
  // case, reached by a different route.
  if (Number.isSafeInteger(n) && n > 0) return n;
  console.error(`[supervisor] POLLER_MAX_FAILS="${raw}" is not a positive integer — using the default ${DEFAULT_MAX_FAILS}`);
  return DEFAULT_MAX_FAILS;
}
export const MAX_FAILS = resolveMaxFails();
export const IMMEDIATE_MS = 5000;   // exiting within 5s counts as an immediate crash

// The breaker's accounting, extracted (HIMMEL-1272) so it is TESTED rather than
// re-implemented in the test. It used to be an inline expression in main(), which
// left a test no way to exercise it without restating the rule — a test that
// passes even after production drifts away from it.
// A run that lasted at least IMMEDIATE_MS resets the counter: that is what makes a
// deliberate `/restart` of a healthy poller free, while a poller that dies on boot
// still accumulates toward MAX_FAILS.
export function nextFailCount(prev: number, ranMs: number): number {
  return ranMs < IMMEDIATE_MS ? prev + 1 : 0;
}

// --- Pidfile (HIMMEL-221): make `--kill` a real lever, not a stub. ---
// The supervisor records its own pid + the current poller child pid so a
// separate `bun supervisor.ts --kill` invocation can stop the whole bridge.
export type PidRec = { supervisor: number; poller: number | null };
export const pidfilePath = (): string => join(bridgeRoot(), "supervisor.pid");
export function formatPidfile(rec: PidRec): string { return JSON.stringify(rec); }
// A pid must be a positive integer — reject negatives (process.kill(-N) signals
// a whole process GROUP on POSIX) and non-integers from a hand-edited file.
const validPid = (n: unknown): n is number => typeof n === "number" && Number.isInteger(n) && n > 0;
export function parsePidfile(s: string): PidRec | null {
  try {
    const o = JSON.parse(s);
    if (!validPid(o?.supervisor)) return null;
    return { supervisor: o.supervisor, poller: validPid(o.poller) ? o.poller : null };
  } catch { return null; }
}

function writePidfile(rec: PidRec): void {
  const p = pidfilePath();
  try { mkdirSync(dirname(p), { recursive: true }); writeFileSync(p, formatPidfile(rec), "utf8"); }
  catch (e) { console.error(`[supervisor] could not write pidfile ${p} (${(e as any)?.code ?? e}); a later --kill may not find the bridge.`); }
}
function clearPidfile(): void { try { unlinkSync(pidfilePath()); } catch {} }

// Stop the running bridge from a separate process: read the pidfile, kill the
// supervisor FIRST (so it can't respawn the poller in the gap), then the poller.
// Return codes: 0 = killed (or already gone), 1 = pidfile absent (not running),
// 2 = pidfile unreadable/corrupt OR a signal failed (e.g. EPERM) → bridge MAY
// be running (do NOT claim stopped; the pidfile is kept so a retry can find it).
// killFn is injectable so tests can pin the rc>=2 contract (the uninstall
// siblings gate state removal on it) without signalling real pids.
export function killBridge(killFn: (pid: number) => void = (pid) => process.kill(pid)): number {
  const p = pidfilePath();
  let raw: string;
  try { raw = readFileSync(p, "utf8"); }
  catch (e: any) {
    if (e?.code === "ENOENT") { console.error(`[supervisor] --kill: no pidfile at ${p}; bridge not running.`); return 1; }
    console.error(`[supervisor] --kill: cannot read pidfile ${p} (${e?.code ?? e}); bridge MAY be running — check the poller manually.`); return 2;
  }
  const rec = parsePidfile(raw);
  if (!rec) { console.error(`[supervisor] --kill: pidfile ${p} is corrupt; bridge MAY be running — check the poller pid manually.`); return 2; }
  let signalFailed = false;
  for (const [label, pid] of [["supervisor", rec.supervisor], ["poller", rec.poller]] as const) {
    if (pid == null) continue;
    try { killFn(pid); console.error(`[supervisor] --kill: signalled ${label} pid ${pid}`); }
    catch (e: any) {
      if (e?.code === "ESRCH") console.error(`[supervisor] --kill: ${label} pid ${pid} already gone`);
      else { signalFailed = true; console.error(`[supervisor] --kill: FAILED to signal ${label} pid ${pid} (${e?.code ?? e}) — may still be running`); }
    }
  }
  if (signalFailed) {
    // Do NOT clear the pidfile: the bridge may still be live, and clearing it
    // would make a retry report "not running" (rc=1) while it keeps polling.
    console.error(`[supervisor] --kill: keeping pidfile ${p} — bridge MAY still be running; check manually.`);
    return 2;
  }
  clearPidfile();
  return 0;
}

async function main(): Promise<void> {
  installTimestampedLogging();   // HIMMEL-1401: every supervisor.log line gets an ISO timestamp
  if (process.argv.includes("--kill")) { process.exit(killBridge()); }
  writePidfile({ supervisor: process.pid, poller: null });
  let fails = 0;
  for (;;) {
    const started = performance.now();
    const p = spawn(["bun", "poller.ts"], { cwd: import.meta.dir, stdout: "inherit", stderr: "inherit" });
    writePidfile({ supervisor: process.pid, poller: p.pid });
    const code = await p.exited;
    writePidfile({ supervisor: process.pid, poller: null });   // poller gone until respawn
    const ranMs = performance.now() - started;
    fails = nextFailCount(fails, ranMs);   // a long run resets the breaker
    console.error(`[supervisor] poller exited code=${code} ranMs=${Math.round(ranMs)} consecutiveImmediateFails=${fails}`);
    if (breakerTrips(fails, MAX_FAILS)) {
      console.error(`[supervisor] circuit breaker TRIPPED after ${fails} immediate crashes — halting. Investigate the poller (token/.env, network, bus perms).`);
      clearPidfile();
      process.exit(1);
    }
    await Bun.sleep(nextBackoff(fails));
  }
}
if (import.meta.main) await main();
