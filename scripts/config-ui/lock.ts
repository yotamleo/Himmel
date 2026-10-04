// HIMMEL-4254 P4 (spec A13): one write at a time, machine-wide for UI servers.
// A lock file holding "<owner pid> <token> [<child pgid>]" (Bun has no flock,
// macOS no flock(1)), created by link(2) from a temp file that already holds
// it, so it is never visible empty. The lock is live while the owner pid OR
// the action's process group exists: a crashed server's orphaned child keeps
// it. A stale lock is replaced only by whoever holds the breaker file
// (`<lock>.break`, also created by link(2)), so exactly one taker wins; a
// breaker left by a dead taker fails closed with a remedy. Each child runs as
// its own process-group leader, the whole group is killed on every finish, and
// the result waits until the group is gone.
import { spawn, spawnSync } from "node:child_process";
import { linkSync, mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { StringDecoder } from "node:string_decoder";

const alive = (pid: number) => {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try { process.kill(pid, 0); return true; } catch (e) { return (e as NodeJS.ErrnoException).code === "EPERM"; }
};
// ponytail: Windows has no process groups, so a crashed server's orphan does not keep the lock there, upgrade path is a Job Object (Windows parked, epic HIMMEL-4102)
const groupAlive = (pgid: number) => {
  if (process.platform === "win32" || !Number.isInteger(pgid) || pgid <= 1) return false;
  try { process.kill(-pgid, 0); return true; } catch (e) { return (e as NodeJS.ErrnoException).code === "EPERM"; }
};
const parse = (s: string) => { const [pid, token = "", pgid] = s.trim().split(/\s+/); return { pid: Number(pid), token, pgid: Number(pgid) }; };
const live = (s: string) => { const o = parse(s); return alive(o.pid) || groupAlive(o.pgid); };
const read = (p: string): string | null => {
  try { return readFileSync(p, "utf8"); } catch (e) { if ((e as NodeJS.ErrnoException).code === "ENOENT") return null; throw e; }
};
const link = (from: string, to: string) => {
  try { linkSync(from, to); return true; } catch (e) { if ((e as NodeJS.ErrnoException).code === "EEXIST") return false; throw e; }
};
const uniq = () => `${process.pid}.${Buffer.from(crypto.getRandomValues(new Uint8Array(6))).toString("hex")}`;

export type Lock = { setGroup(pgid: number): void; release(): void };
export type Busy = { busy: string };
const BUSY: Busy = { busy: "another action is running" };

// Returns the held lock, or why it could not be taken.
export function acquireLock(path: string): Lock | Busy {
  mkdirSync(dirname(path), { recursive: true });
  const token = uniq();
  const mine = `${process.pid} ${token}`;
  const tmp = `${path}.${token}.tmp`;
  writeFileSync(tmp, mine, { mode: 0o600 });
  try {
    for (let attempt = 0; attempt < 3; attempt++) {
      if (link(tmp, path)) return held(path, mine);
      const seen = read(path);
      if (seen === null) continue; // released in between: retry
      // A reused owner pid reads as live, so the remedy is in the answer.
      if (live(seen)) return { busy: `another action is running: if no config-ui server is running, remove ${path}` };
      // Stale. Only the breaker holder may replace it: no other taker can,
      // and its dead owner cannot release it, so the re-read below is final.
      const breaker = `${path}.break`;
      if (!link(tmp, breaker)) {
        const b = read(breaker);
        if (b === null) continue; // a racer just finished: retry
        if (alive(parse(b).pid)) return BUSY;
        return { busy: `a stale-lock takeover was interrupted: remove ${breaker} if no config-ui server is running` };
      }
      try {
        const now = read(path);
        if (now !== null && (now !== seen || live(now))) return BUSY;
        if (now !== null) unlinkSync(path);
        return link(tmp, path) ? held(path, mine) : BUSY;
      } finally { if (read(breaker) === mine) unlinkSync(breaker); }
    }
    return BUSY;
  } finally { try { unlinkSync(tmp); } catch { /* gone */ } }
}

// A live owner's lock cannot be replaced by anyone else, so read-then-write
// on our own lock is not a race.
function held(path: string, mine: string): Lock {
  const token = parse(mine).token;
  const ours = () => { const s = read(path); return s !== null && parse(s).token === token; };
  let pgid = 0, done = false;
  return {
    setGroup(g: number) {
      if (done || !ours()) return;
      pgid = g;
      const t = `${path}.${uniq()}.tmp`;
      writeFileSync(t, `${mine} ${g}`, { mode: 0o600 });
      try { renameSync(t, path); } catch (e) { try { unlinkSync(t); } catch { /* gone */ } throw e; }
    },
    // Left in place while the action's group still exists: it stays live
    // through that group, and goes stale once the group is gone.
    // ponytail: a group that survives runChild's bounded wait (a D-state process) keeps the lock until this server exits, upgrade path is a deferred re-release, HIMMEL-4354
    release() {
      if (done) return;
      done = true;
      if (groupAlive(pgid)) return;
      if (ours()) try { unlinkSync(path); } catch { /* gone */ }
    },
  };
}

export type ChildResult = { rc: number | null; stdout: string; stderr: string; timedOut: boolean };
const MAX_OUT = 256 * 1024;
const CLOSE_GRACE_MS = 2000;
const REAP_WAIT_MS = 5000;

// execFile semantics (argv array, no shell) plus detached: the child leads its
// own process group, so a timeout kills every descendant with kill(-pgid)
// (taskkill /T on Windows, which has no process groups). onSpawn gets the
// pgid (= the leader's pid) so the caller can record it in the lock. If onSpawn
// throws, the group is killed and reaped and the promise rejects: the child
// never runs unsupervised.
// ponytail: a server crash between spawn and onSpawn leaves that one orphan unrecorded (the window is spawn-to-onSpawn only), upgrade path is spawning through a wrapper that writes its own pgid first, HIMMEL-4354
export function runChild(argv: string[], o: { cwd: string; env: Record<string, string | undefined>; timeoutMs: number; onSpawn?: (pgid: number) => void }): Promise<ChildResult> {
  return new Promise((done, fail) => {
    const c = spawn(argv[0], argv.slice(1), { cwd: o.cwd, env: o.env as NodeJS.ProcessEnv, detached: true, shell: false, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "", stderr = "", timedOut = false, finished = false;
    // Streaming decoders: a character split across two chunks stays whole.
    const outDec = new StringDecoder("utf8"), errDec = new StringDecoder("utf8");
    c.stdout!.on("data", (d) => { if (stdout.length < MAX_OUT) stdout += outDec.write(d); });
    c.stderr!.on("data", (d) => { if (stderr.length < MAX_OUT) stderr += errDec.write(d); });
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
    // SIGKILL is delivered at once but reaped later: wait (bounded) until
    // kill(-pgid, 0) says ESRCH, so the lock is never released early.
    const reaped = async () => {
      if (c.pid === undefined) return;
      for (const end = Date.now() + REAP_WAIT_MS; groupAlive(c.pid) && Date.now() < end;) await Bun.sleep(20);
    };
    if (c.pid !== undefined) {
      try { o.onSpawn?.(c.pid); } catch (e) {
        c.on("error", () => { /* spawn already failed the caller */ });
        c.stdout!.destroy(); c.stderr!.destroy();
        killGroup();
        void reaped().then(() => fail(e));
        return;
      }
    }
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
      void reaped().then(() => done({ rc, stdout: stdout + outDec.end(), stderr: stderr + errDec.end(), timedOut }));
    };
    c.on("error", (e) => { stderr += String(e.message); finish(null); });
    // "close" fires once stdout/stderr are drained. A descendant that keeps a
    // pipe open would delay it forever, so after the leader exits wait at most
    // CLOSE_GRACE_MS (none after a timeout kill) before finishing anyway.
    c.on("close", (code) => finish(timedOut ? null : code));
    c.on("exit", (code) => { grace = setTimeout(() => finish(timedOut ? null : code), timedOut ? 0 : CLOSE_GRACE_MS); });
  });
}
