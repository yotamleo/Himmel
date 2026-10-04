import { test, expect, beforeEach, afterEach } from "bun:test";
import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { acquireLock, runChild, type Lock } from "../lock";

// Scratch dir only: no real ~/.himmel lock is touched.
let dir = "";
beforeEach(() => { dir = mkdtempSync(join(tmpdir(), "cfgui-lock-")); });
afterEach(() => rmSync(dir, { recursive: true, force: true }));
const take = (p: string) => { const l = acquireLock(p); if ("busy" in l) throw new Error(l.busy); return l as Lock; };
const deadPid = () => spawnSync("true").pid!;

test("an acquired lock holds this pid and leaves no temp files behind", () => {
  const p = join(dir, "write.lock");
  const l = take(p);
  expect(readFileSync(p, "utf8").split(" ")[0]).toBe(String(process.pid));
  expect(readdirSync(dir)).toEqual(["write.lock"]);
  l.release();
  expect(existsSync(p)).toBe(false);
});

test("release does not remove a lock another owner has taken since", () => {
  const p = join(dir, "write.lock");
  const l = take(p);
  rmSync(p);
  writeFileSync(p, "1"); // pid 1 is always alive
  l.release();
  expect(readFileSync(p, "utf8")).toBe("1");
});

test("a stale lock is taken over; a live one is left in place", () => {
  const p = join(dir, "write.lock");
  writeFileSync(p, "");  // empty: a crash before the pid landed
  take(p).release();
  writeFileSync(p, "1");
  expect("busy" in acquireLock(p)).toBe(true);
  expect(readFileSync(p, "utf8")).toBe("1");
});

test("a dead owner whose action group still runs keeps the lock live", async () => {
  const p = join(dir, "write.lock");
  const orphan = spawn("sleep", ["30"], { detached: true, stdio: "ignore" });
  try {
    writeFileSync(p, `${deadPid()} tok ${orphan.pid}`);
    expect("busy" in acquireLock(p)).toBe(true);
    process.kill(-orphan.pid!, "SIGKILL");
    await new Promise((r) => orphan.once("exit", r));
    take(p).release();
  } finally { try { process.kill(-orphan.pid!, "SIGKILL"); } catch { /* gone */ } }
});

test("three concurrent takers on a stale lock: exactly one wins, every round", async () => {
  const p = join(dir, "write.lock");
  const taker = join(import.meta.dir, "lock-taker.ts");
  for (let round = 0; round < 20; round++) {
    writeFileSync(p, String(deadPid()));
    const startAt = Date.now() + 500;
    const runs = await Promise.all([0, 1, 2].map(() => new Promise<{ out: string; code: number | null }>((res) => {
      const c = spawn(process.execPath, [taker, p, String(startAt)], { stdio: ["ignore", "pipe", "inherit"] });
      let o = ""; c.stdout!.on("data", (d) => (o += d)); c.on("close", (code) => res({ out: o.trim(), code }));
    })));
    const outs = runs.map((r) => r.out);
    expect(outs.filter((o) => o === "won").length).toBe(1);
    expect(outs.filter((o) => o === "lost").length).toBe(2);
    expect(runs.map((r) => r.code)).toEqual([0, 0, 0]);
    rmSync(p, { force: true });
  }
}, 120_000);

test("a stale breaker left by a dead taker fails closed with a remedy, never a takeover", () => {
  const p = join(dir, "write.lock");
  writeFileSync(p, String(deadPid()));
  writeFileSync(`${p}.break`, String(deadPid()));
  const l = acquireLock(p);
  expect("busy" in l && l.busy).toContain(`remove ${p}.break`);
});

test("a busy answer on a live lock names the lock path and the remedy for a reused pid", () => {
  const p = join(dir, "write.lock");
  writeFileSync(p, "1"); // pid 1 is always alive, as a reused pid would be
  const l = acquireLock(p);
  expect("busy" in l && l.busy).toContain(p);
  expect("busy" in l && l.busy).toContain("if no config-ui server is running");
});

test("release keeps the lock while the action's group still runs (a group that outlives the reap wait)", () => {
  const p = join(dir, "write.lock");
  const orphan = spawn("sleep", ["30"], { detached: true, stdio: "ignore" });
  try {
    const l = take(p);
    l.setGroup(orphan.pid!);
    l.release();
    expect(existsSync(p)).toBe(true);
    expect("busy" in acquireLock(p)).toBe(true);
  } finally { try { process.kill(-orphan.pid!, "SIGKILL"); } catch { /* gone */ } }
});

test("an onSpawn that throws kills and reaps the group, then rejects: the child never runs unsupervised", async () => {
  let pgid = 0;
  const err = await runChild(["sh", "-c", "sleep 30"], { cwd: dir, env: process.env, timeoutMs: 60_000, onSpawn: (pg) => { pgid = pg; throw new Error("lock write failed"); } }).then(() => null, (e) => e);
  expect(String(err)).toContain("lock write failed");
  expect(pgid).toBeGreaterThan(0);
  let code = "";
  try { process.kill(-pgid, 0); } catch (e) { code = String((e as NodeJS.ErrnoException).code); }
  expect(code).toBe("ESRCH");
});

test("a UTF-8 character split across two output chunks is decoded whole", async () => {
  const r = await runChild(["sh", "-c", "printf '\\303'; sleep 0.3; printf '\\251'; printf '\\303' >&2; sleep 0.3; printf '\\251' >&2"], { cwd: dir, env: process.env, timeoutMs: 5000 });
  expect(r.stdout).toBe("é");
  expect(r.stderr).toBe("é");
});

test("runChild resolves only once the whole process group is gone", async () => {
  const r = await runChild(["sh", "-c", "echo $$; sleep 30 0</dev/null 1>/dev/null 2>&1 &"], { cwd: dir, env: process.env, timeoutMs: 60_000 });
  const pgid = Number(r.stdout.trim());
  expect(pgid).toBeGreaterThan(0);
  let code = "";
  try { process.kill(-pgid, 0); } catch (e) { code = String((e as NodeJS.ErrnoException).code); }
  expect(code).toBe("ESRCH");
});

test("onSpawn reports the child's pgid so the lock can record it", async () => {
  let seen = 0;
  const r = await runChild(["sh", "-c", "echo $$"], { cwd: dir, env: process.env, timeoutMs: 5000, onSpawn: (pg) => { seen = pg; } });
  expect(seen).toBe(Number(r.stdout.trim()));
});

test("output written after the leader exits is kept (finish on close, not exit)", async () => {
  const r = await runChild(["sh", "-c", "(sleep 0.3; echo late) & echo early"], { cwd: dir, env: process.env, timeoutMs: 5000 });
  expect(r.rc).toBe(0);
  expect(r.stdout).toBe("early\nlate\n");
});

// Alive unless kill(0) fails or Linux /proc shows a zombie; with no /proc the
// kill(0) answer stands, so the check is not vacuous off Linux.
const alive = (pid: number) => {
  try { process.kill(pid, 0); } catch { return false; }
  try { return !readFileSync(`/proc/${pid}/stat`, "utf8").includes(") Z "); } catch { return true; }
};

// The lock must never be released while a descendant of the action still runs.
for (const [name, script] of [
  ["holding the pipe open past the grace period", "sleep 30 & echo $!"],
  ["with its stdio redirected away from the pipe", "sleep 30 0</dev/null 1>/dev/null 2>&1 & echo $!"],
] as const) {
  test(`a descendant ${name} does not hang the result, and is killed`, async () => {
    const t0 = Date.now();
    const r = await runChild(["sh", "-c", script], { cwd: dir, env: process.env, timeoutMs: 60_000 });
    expect(r.rc).toBe(0);
    expect(Date.now() - t0).toBeLessThan(10_000);
    const gc = Number(r.stdout.trim());
    expect(gc).toBeGreaterThan(0);
    for (let i = 0; i < 20 && alive(gc); i++) await Bun.sleep(50);
    expect(alive(gc)).toBe(false);
  });
}
