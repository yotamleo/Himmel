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

test("a descendant holding the pipe open past the grace period does not hang the result, and is killed", async () => {
  const t0 = Date.now();
  const r = await runChild(["sh", "-c", "sleep 30 & echo $!"], { cwd: dir, env: process.env, timeoutMs: 60_000 });
  expect(r.rc).toBe(0);
  expect(Date.now() - t0).toBeLessThan(10_000);
  const gc = Number(r.stdout.trim());
  const alive = () => { try { process.kill(gc, 0); return !readFileSync(`/proc/${gc}/stat`, "utf8").includes(") Z "); } catch { return false; } };
  for (let i = 0; i < 20 && alive(); i++) await Bun.sleep(50);
  expect(alive()).toBe(false); // the lock must not be released while it still runs
});
