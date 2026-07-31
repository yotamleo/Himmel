// Timestamp every console.log/console.error line (HIMMEL-1401). supervisor.log
// carries none today: restart-bridge.ps1 launches `bun supervisor.ts > log 2>&1`,
// and supervisor.ts spawns poller.ts with stdout/stderr "inherit" — both write
// raw console output straight into that redirected file. A Telegram-API-side
// outage (e.g. a Bad Gateway storm) then shows up as a bare run of identical
// lines with no way to tell when it started, how long it lasted, or when it
// ended short of correlating file mtimes with run logs (2026-07-30 incident).
//
// Wraps `target.log`/`target.error` in place, prefixing an ISO-8601 timestamp
// arg ahead of the caller's own args — so every existing call site (across this
// file and everything it imports, in-process) gets a timestamp with no change at
// the call site itself. `target` defaults to the real `console`; tests pass a
// fake object so this is verifiable without mutating global state.
export function installTimestampedLogging(target: Pick<Console, "log" | "error"> = console): void {
  const rawLog = target.log.bind(target);
  const rawError = target.error.bind(target);
  target.log = ((...args: unknown[]) => rawLog(`[${new Date().toISOString()}]`, ...args)) as Console["log"];
  target.error = ((...args: unknown[]) => rawError(`[${new Date().toISOString()}]`, ...args)) as Console["error"];
}
