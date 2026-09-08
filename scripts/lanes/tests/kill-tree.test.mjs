// Coverage for scripts/lib/kill-tree.mjs (HIMMEL-1956, consolidating
// HIMMEL-1835): the shared process-TREE stop for the JS/TS side.
//
// THE POINT OF THIS SUITE: the defect it pins shipped because the only test
// that existed asserted the DIRECT child died. It did, on every platform --
// while its descendants kept running and holding the output pipes. So the
// cases below spawn a real grandchild that outlives its parent and assert the
// GRANDCHILD is gone.
//
// PLATFORM: the defect is POSIX-only (Windows taskkill /T already walks the
// tree), so the grandchild cases are POSIX-only too and SKIP on win32 -- the
// operator's primary station. They are exercised on Linux: verified in WSL2
// during development, and CI on the public mirror runs on ubuntu. The last
// case runs everywhere.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { setTimeout as sleep } from "node:timers/promises";
import { killTree, SPAWN_OWN_GROUP } from "../../lib/kill-tree.mjs";

const POSIX = process.platform !== "win32";

// alive(pid) -- signal 0 probes existence without delivering anything. A
// not-yet-reaped zombie would answer 0 here, which is why the fixtures below
// let the grandchild be reparented to init (its parent shell is gone, so
// nothing of ours holds a zombie entry for it).
function alive(pid) {
  try { process.kill(pid, 0); return true; } catch (e) { return e?.code === "EPERM"; }
}

// spawnFixture -- a child shell that prints the pid of a background grandchild.
// The grandchild outlives its parent, which is the shape every caller of this
// helper is trying to clean up: a worker that spawned something of its own
// before it overran its deadline. `parentTail` decides whether the parent
// shell then hangs around (the timeout case) or exits immediately (the
// already-exited case).
//
// A fixture that fails AFTER spawning must not leak what it spawned (panel
// round 2, codex-1): the caller's cleanup only ever sees a fixture that was
// returned, so the throw path cleans up here before it rethrows.
async function spawnFixture({ ownGroup = true, parentTail = "sleep 300" } = {}) {
  const child = spawn("sh", ["-c", `sleep 300 & echo $!; ${parentTail}`], {
    ...(ownGroup ? SPAWN_OWN_GROUP : {}),
    stdio: ["ignore", "pipe", "ignore"],
  });
  try {
    const grandchild = await new Promise((resolve, reject) => {
      let buf = "";
      const t = setTimeout(() => reject(new Error("fixture never printed its grandchild pid")), 10_000);
      child.stdout.on("data", (d) => {
        buf += String(d);
        const m = buf.match(/(\d+)/);
        if (m) { clearTimeout(t); resolve(Number(m[1])); }
      });
      child.on("error", (e) => { clearTimeout(t); reject(e); });
    });
    return { child, grandchild };
  } catch (e) {
    hardCleanup({ child });
    throw e;
  }
}

// Nothing may leak out of this suite even when an assertion fails -- or when
// the fixture itself does, before it ever learned the grandchild's pid.
function hardCleanup({ child, grandchild }) {
  for (const pid of [grandchild, child?.pid]) {
    if (!pid) continue;
    try { process.kill(pid, "SIGKILL"); } catch { /* gone */ }
  }
  // Covers the grandchild even when its pid was never captured.
  if (child?.pid) { try { process.kill(-child.pid, "SIGKILL"); } catch { /* no group */ } }
}

test("POSIX: the whole group dies, grandchild included (the defect this ticket exists for)", { skip: !POSIX }, async () => {
  const fx = await spawnFixture();
  try {
    assert.equal(alive(fx.grandchild), true, "fixture grandchild should be alive before the stop");
    const r = killTree(fx.child.pid, (s) => fx.child.kill(s));
    assert.equal(r.ok, true, `expected a clean stop, got ${r.detail}`);
    await sleep(1500);
    assert.equal(alive(fx.grandchild), false, "the GRANDCHILD survived -- signalling the direct pid only is the bug");
    assert.equal(alive(fx.child.pid), false, "the direct child survived");
  } finally {
    hardCleanup(fx);
  }
});

test("POSIX: a child spawned WITHOUT its own group still gets the direct signal (legacy callers keep working)", { skip: !POSIX }, async () => {
  const fx = await spawnFixture({ ownGroup: false });
  try {
    // No group to signal -> the kernel answers ESRCH, which the helper treats
    // as "nothing to do" rather than an error. The direct child must still die
    // (this is the pre-1956 behaviour, deliberately preserved).
    const r = killTree(fx.child.pid, (s) => fx.child.kill(s));
    assert.equal(r.ok, true, `ESRCH on a groupless child must not be reported as a failure: ${r.detail}`);
    await sleep(1000);
    assert.equal(alive(fx.child.pid), false, "the direct child must die even with no group");
  } finally {
    hardCleanup(fx);
  }
});

test("POSIX: descendants are reaped even after the direct child has already exited (HIMMEL-1835 hole 2)", { skip: !POSIX }, async () => {
  // The child exits immediately; its background grandchild does not. The old
  // shape returned early on `exitCode !== null` and cleaned up nothing --
  // exactly the case where the MCP fleet is left running. A pgid stays
  // reserved while the group has members, so the group signal is still
  // precisely aimed here, never at a recycled pid.
  const fx = await spawnFixture({ parentTail: "exit 0" });
  try {
    await new Promise((r) => fx.child.on("exit", r));
    assert.notEqual(fx.child.exitCode, null, "fixture child should have exited on its own");
    assert.equal(alive(fx.grandchild), true, "the grandchild should outlive its parent shell");
    const r = killTree(fx.child.pid, (s) => fx.child.kill(s), { exited: true });
    assert.equal(r.ok, true, `expected a clean stop, got ${r.detail}`);
    await sleep(1500);
    assert.equal(alive(fx.grandchild), false, "an already-exited child must not skip reaping its descendants");
  } finally {
    hardCleanup(fx);
  }
});

test("a pid that does not exist is a no-op, not a thrown error", () => {
  // 2^31-ish: never a live pid on either platform. Windows takes the taskkill
  // branch (rc 128, "not found", accepted); POSIX takes the group branch
  // (ESRCH, accepted). Neither may throw or report failure.
  const r = killTree(2147483646, () => { throw new Error("no such handle"); });
  assert.equal(r.ok, true, `a missing target must not be reported as a failure: ${r.detail}`);
});

test("win32: declining to tree-stop an already-exited child is reported as a SKIP, not a failure", { skip: POSIX }, () => {
  // Aiming taskkill at a pid that is no longer ours is the one thing this
  // branch must not do, so the skip is correct behaviour. Reporting it as
  // ok:false made every clean codex-bank-probe run log a WARNING about a
  // failure that had not happened (PR #1751).
  const r = killTree(4242, () => {}, { exited: true });
  assert.equal(r.ok, true, "a deliberate skip must not be reported as a failed stop");
  assert.match(r.detail ?? "", /skipped taskkill/, "the skip should still be stated, just not as a failure");
});

test("win32: a taskkill that cannot be STARTED is reported with its cause", { skip: POSIX }, () => {
  // spawnSync does not throw on ENOENT -- it returns { error, status: null }.
  // Reading only the status reported a bare `rc=null`, naming neither the
  // cause nor the fix (PR #1751). Emptying PATH is what makes the lookup fail.
  const savedPath = process.env.PATH;
  const savedWinPath = process.env.Path;
  try {
    process.env.PATH = "";
    delete process.env.Path;
    const r = killTree(4242, () => {});
    assert.equal(r.ok, false, "an unstartable taskkill is a real failure");
    assert.doesNotMatch(r.detail, /rc=null/, "a spawn failure must not be reported as a null return code");
    assert.match(r.detail, /could not be spawned/);
  } finally {
    if (savedPath === undefined) delete process.env.PATH; else process.env.PATH = savedPath;
    if (savedWinPath !== undefined) process.env.Path = savedWinPath;
  }
});

test("SPAWN_OWN_GROUP asks for a dedicated group on POSIX and stays out of the way on Windows", () => {
  // The two halves of the fix live on opposite sides of the spawn, so the
  // spawn-side half is worth pinning: an empty object here on POSIX would make
  // every group signal above a silent ESRCH no-op.
  if (POSIX) assert.deepEqual(SPAWN_OWN_GROUP, { detached: true });
  else assert.deepEqual(SPAWN_OWN_GROUP, {}, "detached on Windows means a new console and an outliving child, for no gain");
});
