import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, writeFileSync, existsSync, openSync, writeSync, closeSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';

import { acquireLock, withSettingsLock, lockPathFor } from './settings-lock.mjs';

function tmpSettings(initial) {
  const dir = mkdtempSync(join(tmpdir(), 'settings-lock-'));
  const settings = join(dir, 'settings.json');
  writeFileSync(settings, JSON.stringify(initial));
  return { dir, settings };
}

// A genuinely dead pid: spawn a child, wait for it to exit, return its pid.
// Reuse is possible in principle but not on the test's timescale, and the
// liveness probe runs immediately at acquire time.
async function deadPid() {
  const child = spawn(process.execPath, ['-e', 'process.exit(0)']);
  const pid = child.pid;
  await new Promise((res) => child.on('exit', res));
  return pid;
}

test('runs the section and releases the lock', async () => {
  const { dir, settings } = tmpSettings({ value: 0 });
  try {
    const lockPath = lockPathFor(settings);
    const result = await withSettingsLock(settings, () => {
      const cur = JSON.parse(readFileSync(settings, 'utf8'));
      writeFileSync(settings, JSON.stringify({ value: cur.value + 1 }));
      return 'done';
    });
    assert.equal(result, 'done');
    assert.equal(JSON.parse(readFileSync(settings, 'utf8')).value, 1);
    assert.ok(!existsSync(lockPath), 'lockfile removed after the section');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// HIMMEL-1552: the reason the lock exists. Writer A is blocked mid-transform
// (holds the lock, has read, not yet written); writer B starts and commits.
// Without coordination B reads A's PRE-commit state and one write is lost. With
// the lock, B blocks until A commits, then reads A's result — both applied.
// Deterministic via an injected barrier (acquireLock/release handles), NOT a
// timed race.
test('two writers serialise: the second reads the first commit, no lost update', async () => {
  const { dir, settings } = tmpSettings({ value: 0 });
  try {
    // Writer A: mid-transform — holds the lock and has read, but not written.
    const releaseA = await acquireLock(settings);
    const aRead = JSON.parse(readFileSync(settings, 'utf8')); // A read value:0

    // Writer B: starts while A holds. Under the lock it must BLOCK; without a
    // lock it would run now, read the same stale value:0, and lose a write.
    const writerB = withSettingsLock(settings, () => {
      const bRead = JSON.parse(readFileSync(settings, 'utf8'));
      writeFileSync(settings, JSON.stringify({ value: bRead.value + 1 }));
    });
    // Drain pending microtasks so B has ATTEMPTED. Under the lock it is blocked
    // in acquire (A still holds); this is a deterministic drain, not a sleep —
    // the assertion does not depend on how long setTimeout takes.
    await new Promise((r) => setTimeout(r, 0));

    // Writer A commits its transform and releases.
    writeFileSync(settings, JSON.stringify({ value: aRead.value + 100 }));
    releaseA();

    await writerB;
    const final = JSON.parse(readFileSync(settings, 'utf8'));
    assert.equal(final.value, 101, 'A=100 and B=+1 both applied; B read A commit');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('sweeps a stale lock left by a dead holder', async () => {
  const { dir, settings } = tmpSettings({ value: 0 });
  try {
    const lockPath = lockPathFor(settings);
    const pid = await deadPid();
    // Plant a stale lockfile whose holder is dead.
    const fd = openSync(lockPath, 'w');
    writeSync(fd, `${pid}\n`);
    closeSync(fd);
    assert.ok(existsSync(lockPath));

    // Acquisition must sweep it and succeed (promptly, not after the timeout).
    const release = await acquireLock(settings, { timeoutMs: 1000 });
    assert.ok(existsSync(lockPath), 'a fresh lockfile now exists (ours)');
    release();
    assert.ok(!existsSync(lockPath), 'released');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('times out with a clear message when the lock is held by a live process', async () => {
  const { dir, settings } = tmpSettings({ value: 0 });
  try {
    const releaseA = await acquireLock(settings); // we hold it (live)
    let caught;
    try {
      await acquireLock(settings, { timeoutMs: 200 });
    } catch (err) {
      caught = err;
    }
    releaseA();
    assert.ok(caught, 'a held lock times out and throws');
    assert.match(caught.message, /could not acquire settings lock .* within 200ms/);
    assert.match(caught.message, /held by pid/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// HIMMEL-1552 (glm-1, CR round 1). tryCreate() creates the lockfile and writes
// the holder pid as two steps. If the write fails after the create succeeds
// (ENOSPC/EIO), an EMPTY lockfile is orphaned — and parseInt('') is NaN, which
// used to skip the stale-holder check entirely, so nothing could ever reclaim
// it. That wedges every future acquisition permanently, defeating the whole
// point of having a stale-lock policy. It must be swept once it persists past
// the grace period.
test('sweeps an orphaned lockfile that carries no usable pid', async () => {
  const { dir, settings } = tmpSettings({ value: 0 });
  try {
    const lockPath = lockPathFor(settings);
    writeFileSync(lockPath, ''); // the crashed-mid-create artifact
    const release = await acquireLock(settings, { timeoutMs: 4000 });
    release();
    assert.ok(!existsSync(lockPath), 'orphaned lockfile swept and the lock reclaimed');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('a throwing section still releases the lock', async () => {
  const { dir, settings } = tmpSettings({ value: 0 });
  try {
    const lockPath = lockPathFor(settings);
    await assert.rejects(
      withSettingsLock(settings, () => { throw new Error('boom'); }),
      /boom/,
    );
    assert.ok(!existsSync(lockPath), 'lock released in finally despite the throw');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// HIMMEL-1552 REGRESSION GUARD. A lock that only ONE of the two sanctioned
// writers takes provides no mutual exclusion at all, and that is not a
// hypothetical: the first cut of this module was imported into
// wire-trust-hooks.mjs and never called, so the writer carrying the actual
// lost-update window (writeAtomic's compare-then-rename) ran unprotected while
// every unit test above still passed. The module being correct says nothing
// about the writers being wired to it — so assert the wiring itself.
//
// Deterministic: this process holds the lock for the whole child run, so the
// child MUST hit its acquire timeout. A writer that skips the lock instead
// completes its --check and exits 0, failing this test. --check is used because
// it mutates nothing; the lock is acquired before the check branch is reached.
const REPO_ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');

function runCli(relPath, settingsPath) {
  return new Promise((res) => {
    const child = spawn(process.execPath, [join(REPO_ROOT, relPath), '--check', settingsPath]);
    let stderr = '';
    child.stderr.on('data', (d) => { stderr += d; });
    child.on('close', (code) => res({ code, stderr }));
  });
}

for (const cli of ['scripts/hooks/wire-hook-bash.mjs', 'scripts/trust/wire-trust-hooks.mjs']) {
  test(`${cli} acquires the shared settings lock before touching the file`, async () => {
    const { dir, settings } = tmpSettings({ hooks: {} });
    try {
      const release = await acquireLock(settings); // held for the child's lifetime
      const { code, stderr } = await runCli(cli, settings);
      release();
      assert.equal(code, 1, `${cli} must refuse while another writer holds the lock`);
      assert.match(stderr, /could not acquire settings lock/);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
}
