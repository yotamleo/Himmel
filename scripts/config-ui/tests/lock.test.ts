import { test, expect, beforeEach, afterEach } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { acquireLock, runChild } from "../lock";

// Scratch dir only: no real ~/.himmel lock is touched.
let dir = "";
beforeEach(() => { dir = mkdtempSync(join(tmpdir(), "cfgui-lock-")); });
afterEach(() => rmSync(dir, { recursive: true, force: true }));

test("an acquired lock holds this pid and leaves no temp files behind", () => {
  const p = join(dir, "write.lock");
  const release = acquireLock(p)!;
  expect(readFileSync(p, "utf8")).toBe(String(process.pid));
  expect(readdirSync(dir)).toEqual(["write.lock"]);
  release();
  expect(existsSync(p)).toBe(false);
});

test("release does not remove a lock another owner has taken since", () => {
  const p = join(dir, "write.lock");
  const release = acquireLock(p)!;
  rmSync(p);
  writeFileSync(p, "1"); // pid 1 is always alive
  release();
  expect(readFileSync(p, "utf8")).toBe("1");
});

test("a stale lock is taken over; a live one is left in place", () => {
  const p = join(dir, "write.lock");
  writeFileSync(p, "");  // empty: a crash before the pid landed
  const release = acquireLock(p)!;
  expect(release).not.toBeNull();
  release();
  writeFileSync(p, "1");
  expect(acquireLock(p)).toBeNull();
  expect(readFileSync(p, "utf8")).toBe("1");
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
