// HIMMEL-4254 P4 (spec A13): one write at a time, machine-wide for UI servers.
// A lock file holding the owner pid (Bun has no flock, macOS no flock(1)),
// created by link(2) from a temp file that already holds the pid, so it is
// never visible empty. A lock whose pid is dead is stale: it is renamed aside
// before judging, so two racing takers cannot both remove a fresh lock. Each
// child runs as its own process-group leader and the whole group is killed on
// timeout.
import { spawn, spawnSync } from "node:child_process";
import { linkSync, mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";

const alive = (pid: number) => {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try { process.kill(pid, 0); return true; } catch (e) { return (e as NodeJS.ErrnoException).code === "EPERM"; }
};
const readPid = (p: string) => Number(readFileSync(p, "utf8").trim());
const uniq = () => `${process.pid}.${Buffer.from(crypto.getRandomValues(new Uint8Array(6))).toString("hex")}`;

// Returns a release function, or null when another live owner holds the lock.
export function acquireLock(path: string): (() => void) | null {
  mkdirSync(dirname(path), { recursive: true });
  const me = String(process.pid);
  const tmp = `${path}.${uniq()}.tmp`;
  writeFileSync(tmp, me, { mode: 0o600 });
  try {
    for (let attempt = 0; attempt < 3; attempt++) {
      try {
        linkSync(tmp, path);
        let held = true;
        // Remove only a lock that is still ours.
        return () => { if (held) { held = false; try { if (readFileSync(path, "utf8") === me) unlinkSync(path); } catch { /* already gone */ } } };
      } catch (e) {
        if ((e as NodeJS.ErrnoException).code !== "EEXIST") throw e;
      }
      let pid = NaN;
      try { pid = readPid(path); } catch { continue; } // vanished: retry
      if (alive(pid)) return null;
      // Stale. Move it aside and judge what was actually moved: a racer may
      // have replaced it with a live lock in between, and that goes back.
      // ponytail: a third taker landing inside the move-aside window can still win alongside the restored owner, upgrade path is flock via a native addon if more than two UI servers ever contend
      const aside = `${path}.${uniq()}.stale`;
      try { renameSync(path, aside); } catch { continue; } // vanished: retry
      try {
        let moved = NaN;
        try { moved = readPid(aside); } catch { /* unreadable: stale */ }
        if (alive(moved)) { try { linkSync(aside, path); } catch { /* a third taker won */ } return null; }
      } finally { try { unlinkSync(aside); } catch { /* gone */ } }
    }
    return null;
  } finally { try { unlinkSync(tmp); } catch { /* gone */ } }
}

export type ChildResult = { rc: number | null; stdout: string; stderr: string; timedOut: boolean };
const MAX_OUT = 256 * 1024;
const CLOSE_GRACE_MS = 2000;

// execFile semantics (argv array, no shell) plus detached: the child leads its
// own process group, so a timeout kills every descendant with kill(-pgid)
// (taskkill /T on Windows, which has no process groups).
export function runChild(argv: string[], o: { cwd: string; env: Record<string, string | undefined>; timeoutMs: number }): Promise<ChildResult> {
  return new Promise((done) => {
    const c = spawn(argv[0], argv.slice(1), { cwd: o.cwd, env: o.env as NodeJS.ProcessEnv, detached: true, shell: false, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "", stderr = "", timedOut = false, finished = false;
    c.stdout!.on("data", (d) => { if (stdout.length < MAX_OUT) stdout += d; });
    c.stderr!.on("data", (d) => { if (stderr.length < MAX_OUT) stderr += d; });
    const killGroup = () => {
      if (c.pid === undefined) return;
      if (process.platform === "win32") {
        // Only while the leader lives: an exited pid can be reused on Windows.
        // ponytail: Windows cannot reap a descendant that outlives the leader, upgrade path is a Job Object if Windows actions leave orphans (Windows parked, epic HIMMEL-4102)
        if (c.exitCode === null && c.signalCode === null) spawnSync("taskkill", ["/pid", String(c.pid), "/T", "/F"], { stdio: "ignore" });
        return;
      }
      try { process.kill(-c.pid, "SIGKILL"); } catch { try { c.kill("SIGKILL"); } catch { /* already gone */ } }
    };
    let grace: ReturnType<typeof setTimeout> | undefined;
    const timer = setTimeout(() => { timedOut = true; killGroup(); }, o.timeoutMs);
    const finish = (rc: number | null) => {
      if (finished) return;
      finished = true;
      clearTimeout(timer); clearTimeout(grace);
      // Always reap the group: a descendant may outlive the leader (timed out,
      // holding the pipe, or with its stdio redirected away from it), and the
      // write lock must not be released while it still runs.
      killGroup();
      c.stdout!.destroy(); c.stderr!.destroy();
      done({ rc, stdout, stderr, timedOut });
    };
    c.on("error", (e) => { stderr += String(e.message); finish(null); });
    // "close" fires once stdout/stderr are drained. A descendant that keeps a
    // pipe open would delay it forever, so after the leader exits wait at most
    // CLOSE_GRACE_MS (none after a timeout kill) before finishing anyway.
    c.on("close", (code) => finish(timedOut ? null : code));
    c.on("exit", (code) => { grace = setTimeout(() => finish(timedOut ? null : code), timedOut ? 0 : CLOSE_GRACE_MS); });
  });
}
