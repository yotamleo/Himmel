// scripts/lib/settings-lock.mjs — exclusive lock around .claude/settings.json
// writes, shared by the two sanctioned writers (wire-hook-bash, wire-trust-hooks).
// HIMMEL-1552.
//
// WHY. Each writer does read -> transform -> atomic-rename. Without coordination,
// a writer that replaces settings.json AFTER another's read and BEFORE its rename
// is silently overwritten — including a permissions change. The re-read inside
// writeAtomic narrows that window; it does not close it. This module holds ONE
// exclusive lock across the whole read -> transform -> write/rename sequence for
// BOTH writers, so they serialise rather than race.
//
// SCOPE. Local only — not a distributed lock. Atomic-create (openSync 'wx') is
// the exclusion primitive: O_CREAT|O_EXCL fails with EEXIST if the file exists,
// which is the test-and-set we need. A stale lock (holder crashed) is swept once
// the holder's pid is confirmed dead. Works on Windows (the repo's primary
// platform) and on POSIX: 'wx' and unlinkSync behave the same on both, and the
// fd is closed after writing the pid so the lockfile is never held open (Windows
// would otherwise refuse to unlink an open file).

import { closeSync, openSync, readFileSync, unlinkSync, writeFileSync } from 'node:fs';

const DEFAULT_TIMEOUT_MS = 5000;
const POLL_MS = 25;
// How long an UNPARSEABLE lockfile must persist before it is swept as stale.
// tryCreate() creates the file and writes the pid as two steps, so a healthy
// holder's lockfile is legitimately empty for a sub-millisecond window and must
// NOT be swept — but if writeFileSync throws after the create succeeds (ENOSPC,
// EIO), an empty file is left behind forever. Without a sweep that file wedges
// every future acquisition: parseInt('') is NaN, which used to skip the stale
// check entirely, so no holder was ever confirmed dead and the lock could never
// be reclaimed. A grace period distinguishes the two: orders of magnitude longer
// than the create/write window, still bounded.
const UNPARSEABLE_GRACE_MS = 1000;

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// process.kill(pid, 0) is a liveness probe. Only ESRCH ("no such process") is
// evidence the holder is GONE. EPERM means the opposite — the process exists but
// belongs to another user, which is reachable on a shared POSIX box where the
// two writers run under different accounts. Reporting that as dead would sweep a
// LIVE holder's lock and produce the lost update this module exists to prevent,
// so anything that is not a definite ESRCH is treated as ALIVE. The cost of
// guessing "alive" is a bounded timeout with a clear message; the cost of
// guessing "dead" is silent corruption of settings.json. Fail safe.
function pidAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return e.code !== 'ESRCH';
  }
}

// Atomic test-and-set: create the lockfile with O_CREAT|O_EXCL ('wx'). Returns
// true iff THIS caller created it; false (EEXIST) if it already existed.
function tryCreate(lockPath, pid) {
  let fd;
  try {
    fd = openSync(lockPath, 'wx');
  } catch (e) {
    if (e.code === 'EEXIST') return false;
    throw e;
  }
  try {
    writeFileSync(fd, `${pid}\n`, 'utf8');
  } finally {
    closeSync(fd);
  }
  return true;
}

// Release only a lockfile that carries OUR pid. Never unlink a live holder's
// lock; a stale one is swept in acquire() after the holder is confirmed dead.
function releaseLock(lockPath, pid) {
  let held;
  try {
    held = readFileSync(lockPath, 'utf8').trim();
  } catch (e) {
    if (e.code === 'ENOENT') return; // already released
    return; // best-effort: a stranded lockfile is recovered by the stale policy
  }
  if (held === String(pid)) {
    try { unlinkSync(lockPath); } catch { /* best-effort */ }
  }
}

export function lockPathFor(settingsPath) {
  return `${settingsPath}.lock`;
}

// Acquire the exclusive lock for settingsPath. Returns a release() handle that
// MUST be called (use withSettingsLock unless you need manual control). Bounded
// by timeoutMs; a stale lock (dead holder) is swept so a crash does not wedge
// the repo forever.
export async function acquireLock(settingsPath, opts = {}) {
  const timeoutMs = opts.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  const lockPath = lockPathFor(settingsPath);
  const pid = process.pid;
  const start = Date.now();
  let unparseableSince = 0;
  for (;;) {
    if (tryCreate(lockPath, pid)) break;
    // Lock exists — is the holder alive?
    let holderPid = Number.NaN;
    try {
      holderPid = Number.parseInt(readFileSync(lockPath, 'utf8').trim(), 10);
    } catch (e) {
      if (e.code !== 'ENOENT') throw e;
      // vanished between our EEXIST and the read — loop and retry
    }
    if (Number.isNaN(holderPid) || holderPid <= 0) {
      // No usable pid. Either a holder is mid-create (harmless, resolves in
      // microseconds) or a create succeeded and its pid write failed, orphaning
      // a file that can never be attributed to a process. Sweep only once the
      // condition has PERSISTED past the grace period, so the benign race is
      // never mistaken for the wedge.
      if (unparseableSince === 0) {
        unparseableSince = Date.now();
      } else if (Date.now() - unparseableSince >= UNPARSEABLE_GRACE_MS) {
        try { unlinkSync(lockPath); } catch (e) { if (e.code !== 'ENOENT') throw e; }
        unparseableSince = 0;
        continue;
      }
    } else {
      unparseableSince = 0;
    }
    if (!Number.isNaN(holderPid) && holderPid > 0 && !pidAlive(holderPid)) {
      // Stale: the holder died holding the lock. Sweep and retry; the atomic
      // tryCreate decides who wins if two waiters race to reclaim it.
      try { unlinkSync(lockPath); } catch (e) { if (e.code !== 'ENOENT') throw e; }
      continue;
    }
    if (Date.now() - start >= timeoutMs) {
      throw new Error(
        `could not acquire settings lock ${lockPath} within ${timeoutMs}ms`
        + (Number.isNaN(holderPid) ? '' : ` (held by pid ${holderPid})`)
        + '. Another sanctioned writer may be editing .claude/settings.json; if'
        + ' none is running the holder crashed and you can remove the stale lockfile.',
      );
    }
    await sleep(POLL_MS);
  }
  return () => releaseLock(lockPath, pid);
}

// Run fn while holding the exclusive lock for settingsPath. The lock is held
// across the WHOLE fn — callers do read, transform, and write/rename inside it,
// not just around the rename. Released in finally, so a throwing transform never
// leaks the lock.
export async function withSettingsLock(settingsPath, fn, opts = {}) {
  const release = await acquireLock(settingsPath, opts);
  try {
    return await fn();
  } finally {
    release();
  }
}
