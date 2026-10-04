// HIMMEL-4254 P4 (spec A13): one write at a time, machine-wide for UI servers.
// O_EXCL lock file holding the owner pid (Bun has no flock, macOS no flock(1));
// a lock whose pid is dead is stale and replaced. Each child runs as its own
// process-group leader and the whole group is killed on timeout.
import { spawn } from "node:child_process";
import { closeSync, mkdirSync, openSync, readFileSync, unlinkSync, writeSync } from "node:fs";
import { dirname } from "node:path";

const alive = (pid: number) => {
  try { process.kill(pid, 0); return true; } catch (e) { return (e as NodeJS.ErrnoException).code === "EPERM"; }
};

// Returns a release function, or null when another live owner holds the lock.
export function acquireLock(path: string): (() => void) | null {
  mkdirSync(dirname(path), { recursive: true });
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const fd = openSync(path, "wx", 0o600);
      writeSync(fd, String(process.pid));
      closeSync(fd);
      let held = true;
      return () => { if (held) { held = false; try { unlinkSync(path); } catch { /* already gone */ } } };
    } catch (e) {
      if ((e as NodeJS.ErrnoException).code !== "EEXIST") throw e;
      let pid = NaN;
      try { pid = Number(readFileSync(path, "utf8").trim()); } catch { continue; } // vanished: retry
      if (Number.isInteger(pid) && pid > 0 && alive(pid)) return null;
      try { unlinkSync(path); } catch { /* raced: retry */ }
    }
  }
  return null;
}

export type ChildResult = { rc: number | null; stdout: string; stderr: string; timedOut: boolean };
const MAX_OUT = 256 * 1024;

// execFile semantics (argv array, no shell) plus detached: the child leads its
// own process group, so a timeout kills every descendant with kill(-pgid).
export function runChild(argv: string[], o: { cwd: string; env: Record<string, string | undefined>; timeoutMs: number }): Promise<ChildResult> {
  return new Promise((done) => {
    const c = spawn(argv[0], argv.slice(1), { cwd: o.cwd, env: o.env as NodeJS.ProcessEnv, detached: true, shell: false, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "", stderr = "", timedOut = false, finished = false;
    c.stdout!.on("data", (d) => { if (stdout.length < MAX_OUT) stdout += d; });
    c.stderr!.on("data", (d) => { if (stderr.length < MAX_OUT) stderr += d; });
    const killGroup = () => { try { process.kill(-c.pid!, "SIGKILL"); } catch { /* group already gone */ } };
    const timer = setTimeout(() => { timedOut = true; killGroup(); }, o.timeoutMs);
    const finish = (rc: number | null) => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      if (timedOut) killGroup(); // a grandchild may have outlived the leader's kill
      c.stdout!.destroy(); c.stderr!.destroy();
      done({ rc, stdout, stderr, timedOut });
    };
    c.on("error", (e) => { stderr += String(e.message); finish(null); });
    c.on("exit", (code) => finish(timedOut ? null : code));
  });
}
