// scripts/telegram/console-heartbeat-watch.ts
// HIMMEL-3510. Bridge-side alert for a console's console-wait.sh heartbeat
// (scripts/handover/console-kit/console-wait.sh, HIMMEL-3509 — not edited
// here, its file is owned by that ticket's leg) going stale while the
// console session is still running. N383 measured that an external SIGKILL
// of the waiter re-invokes the console (a task notification fires) — not
// silent. The harness's own "low memory" kill of a background task
// (HIMMEL-3097; legs N129/N132 never woke) is unreproduced and may NOT
// re-invoke: the waiter dies, the session sits idle, and nothing tells the
// operator. This module is pure code — no model turn, no new always-on
// process — driven by a periodic timer already living in poller.ts's main().
//
// Heartbeat contract (owned by console-wait.sh):
//   hb=<epoch> pid=<pid> key=<sha16> tick=<ok|fail|-> state=<waiting|exited> [exit=<reason>]
// rewritten on every poll (CONSOLE_WAIT_POLL_SEC, default 1s), atomically
// (write-then-rename). A line that doesn't match the contract is read
// defensively and is NEVER an alert — the contract can change out from under
// this file (send a FINDING to the console per the brief, don't guess).
import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import { BASH_BIN, REPO_ROOT } from "./run";

export type Heartbeat = {
  hb: number;
  pid: number;
  key: string;
  tick: "ok" | "fail" | "-";
  state: "waiting" | "exited";
  reason?: string;
};

const HEARTBEAT_RE = /^hb=(\d+) pid=(\d+) key=(\S+) tick=(ok|fail|-) state=(waiting|exited)(?: exit=(\S+))?$/;

export function parseHeartbeat(raw: string): Heartbeat | null {
  const m = HEARTBEAT_RE.exec(raw.trim());
  if (!m) return null;
  return { hb: Number(m[1]), pid: Number(m[2]), key: m[3], tick: m[4] as Heartbeat["tick"], state: m[5] as Heartbeat["state"], reason: m[6] };
}

// Default staleness threshold. The heartbeat is rewritten on every poll
// (CONSOLE_WAIT_POLL_SEC, default 1s) in the common case, but console-wait.sh
// only reaches that write AFTER a due tick's sample() call returns — and a
// single tick call may legitimately block the waiter for up to
// CONSOLE_WAIT_TICK_TIMEOUT (default 120s: a slow `gh`/jira/bank-preflight
// call, not a dead waiter) before the next heartbeat write. 3x that ceiling
// clears the worst legitimate gap with margin, so a slow-but-alive tick never
// reads as a silent kill. Configurable by the caller (poller.ts wires
// TELEGRAM_HEARTBEAT_STALE_MS through its own intervalEnvMs, matching every
// other bridge interval).
export const DEFAULT_STALE_MS = 3 * 120_000; // 360s

export type SessionAliveFn = (consoleName: string) => Promise<boolean>;
export type AlertFn = (consoleName: string, ageSec: number) => Promise<void>;
// consoleName -> already alerted for the CURRENT stale episode. Cleared the
// moment the heartbeat is fresh again or the console exits cleanly, so the
// next stale episode alerts once more (re-armed, not one-shot forever).
export type AlertedState = Map<string, boolean>;

const WAIT_SUFFIX = ".md.wait";

// Scans <root>/consoles/*.md.wait — the heartbeat files console-wait.sh
// writes next to each console's own file inbox (consoleInboxPath in
// console-route.ts). Never touches the inbox .md files themselves.
export async function checkStaleHeartbeats(
  root: string,
  nowMs: number,
  staleMs: number,
  alerted: AlertedState,
  sessionAlive: SessionAliveFn,
  alert: AlertFn,
): Promise<void> {
  const dir = join(root, "consoles");
  let entries: string[] = [];
  try { entries = await readdir(dir); } catch { return; }
  for (const f of entries) {
    if (!f.endsWith(WAIT_SUFFIX)) continue;
    const name = f.slice(0, -WAIT_SUFFIX.length);
    let raw: string;
    try { raw = await readFile(join(dir, f), "utf8"); } catch { continue; }
    const hb = parseHeartbeat(raw);
    if (!hb) continue; // malformed — never an alert
    if (hb.state === "exited") { alerted.set(name, false); continue; } // not stale by definition — re-arms
    const ageMs = nowMs - hb.hb * 1000;
    if (ageMs <= staleMs) { alerted.set(name, false); continue; } // fresh — re-arms
    if (alerted.get(name)) continue; // already alerted this stale episode
    if (!(await sessionAlive(name))) continue; // the console process itself is gone — nothing to alert
    await alert(name, Math.round(ageMs / 1000));
    alerted.set(name, true);
  }
}

// censusSessionAlive: is a live claude session named `consoleName` running,
// per the same claude_sessions() census tick.sh/ceiling-conformance.sh use
// (scripts/lanes/lib/claude-sessions.sh, real /proc/<pid>/cmdline argv — no
// re-derivation of that parsing here). Shells out to the thin
// console-census.sh wrapper rather than reimplementing the scan.
//
// ponytail: a degraded or failed census (script rc>0) and a genuinely absent
// console both read as "not found" here — the caller only asks "should I
// alert," and a census too broken to trust must not manufacture a false
// "alive" that would then page the operator over nothing.
export async function censusSessionAlive(
  consoleName: string,
  opts: { env?: Record<string, string | undefined> } = {},
): Promise<boolean> {
  const script = join(REPO_ROOT, "scripts", "telegram", "console-census.sh");
  const p = Bun.spawn([BASH_BIN, script], { env: opts.env ?? (process.env as Record<string, string>), stdout: "pipe", stderr: "pipe" });
  // Drain stdout AND stderr concurrently with p.exited — an unread stderr
  // pipe fills its OS buffer and blocks the child from exiting, hanging this
  // await forever once its diagnostics grow past that buffer.
  const [stdout, , exitCode] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text(), p.exited]);
  if (exitCode !== 0) return false; // degraded/failed scan — never trust a match from it
  return stdout.split("\n").some((line) => line.split("\t")[1] === consoleName);
}
