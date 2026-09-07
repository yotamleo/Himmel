#!/usr/bin/env node
// Hook-integrity verification for run-hook-with-bash.js (HIMMEL-1666,
// HIMMEL-2528). Required by BOTH launcher copies — scripts/hooks/ and
// marketplace/plugins/himmel-ops/hooks/ — via a directory-relative
// `require('./hook-integrity.js')`, so each launcher gets the copy that ships
// beside it. The two copies of THIS file are byte-identical and
// test-plugin-hook-bash-wiring.sh proves it.
'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');

// Local copy of the launcher's path normaliser (one line, and importing it back
// from the launcher would make the two modules mutually recursive).
function normalize(candidate) {
  return String(candidate || '').replace(/\\/g, '/').replace(/\/+$/, '');
}

// ------------------------------------------------------------ hook integrity
//
// HIMMEL-1666. HIMMEL-1649 closed the DELETE vector for a $CLAUDE_PROJECT_DIR-
// relative guard (--fail-closed-when): a MISSING script now fails closed on the
// GLM lane. The REWRITE vector stayed open — a dispatched worker's envelope
// grants Edit(<worktree>) and Bash(node *)/Bash(bash *), both of which reach
// every project-local hook script this launcher runs, so a worker could
// overwrite a guard's CONTENT (e.g. to `exit 0`) and every later invocation of
// this launcher would run the tampered file and trust its verdict.
//
// Chosen direction: content-hash verification, not a dispatcher-owned execution
// path (the other option HIMMEL-1666 weighed). Project-local hooks stay
// project-local and versionable; the cost is a pin file per session instead of
// moving the scripts out of the worktree entirely.
//
// record-hook-integrity.sh (a SessionStart hook, so it runs before ANY tool
// call — benign or malicious — can execute in the session) pins every
// scripts/hooks/*.sh and scripts/guardrails/*.sh file to its git-committed blob
// hash at HEAD, keyed by session_id, in $HIMMEL_HOOK_INTEGRITY_DIR (default
// ~/.claude/himmel/hook-integrity — outside every worktree, so outside every
// worker's Edit(<worktree>) grant). This launcher recomputes the ON-DISK blob
// hash of a project-local script before running it and compares it to that
// pin. A worker that rewrites the guard's on-disk content changes its blob
// hash; the NEXT invocation of that guard (which routes through here first)
// then mismatches and is denied — before the tampered content ever runs. The
// worker never gets to use whatever the rewritten guard would have allowed,
// because the launcher never reaches the point of running it.
//
// Scope: EVERY $CLAUDE_PROJECT_DIR-relative hook this launcher resolves (single
// or chained), not just the GLM lane — the exposure was never GLM-specific
// (see HIMMEL-1666). Safe to roll out broadly because it fails OPEN whenever it
// cannot form an opinion: no session id on the payload, no pin file for this
// session (record-hook-integrity.sh never ran, or predates this checkout), or
// no pin entry for this particular script. It fails CLOSED only on an actual
// pinned mismatch — the one signal that is unambiguous. That also means the fix
// only takes effect from the NEXT session start onward (the operator ruling
// this ticket shipped under): an already-running session has no pin file yet,
// so every check in it fails open exactly as before.
//
// HIMMEL_HOOK_INTEGRITY_BYPASS_OK=1, set in the LAUNCHING shell (this repo's
// standard bypass model — see scripts/hooks/CLAUDE.md), is the documented
// escape hatch for a legitimate mid-session hook edit (an operator actively
// developing a hook).
//
// HONEST RESIDUALS:
// (a) the pin file itself lives in an ordinary user-writable directory; a
// worker with unrestricted Bash runs as the SAME OS user record-hook-
// integrity.sh does. HIMMEL-2085 closed the class of attack this used to warn
// was fully open: block-glm-external-writes.sh's pin-dir write-fence now
// denies a Bash/PowerShell command that references this directory for EVERY
// dispatched worker lane (keyed on the general HIMMEL_WORKER marker, not just
// GLM) — see that hook's header for the mechanism and its own residual (a
// command-TEXT fence, not a filesystem permission boundary; an OS-user-level
// attacker with chmod is still out of scope). (b) verify-then-spawn below is a
// classic TOCTOU: this reads and hashes the script, then a SEPARATE spawnSync
// re-opens the same path to execute it, with a window between the two where
// a concurrently racing process could swap the file. Same adjudication shape
// as this repo's other deferred TOCTOU residuals (HIMMEL-1663, HIMMEL-1704) —
// real, narrow, defense-in-depth, not a same-night fix.
//
// ------------------------------------------------------------- HIMMEL-2528
//
// The pin above is a SNAPSHOT of the session's checkout, and that snapshot goes
// stale for an entirely legitimate reason: a worktree cut before a hook change
// landed on the main line, then brought up to date (a pull, a rebase onto a
// merged main, a `git checkout` of a sibling branch) now holds hook bytes the
// session-start pin never saw. Before this ticket that was indistinguishable
// from tampering, so it denied — every hook call, for the rest of the session,
// on a checkout that is MORE current than the pin. HIMMEL-2528 teaches the
// mismatch path to tell the two populations apart and to ADVANCE the pin when
// (and only when) the new bytes are provably the project's own history.
//
// The record grew three fields for it (schema v2 — record-hook-integrity.sh
// writes them):
//   anchor_ref  the origin-tracking default-branch ref the session was pinned
//               against, e.g. "refs/remotes/origin/main"
//   anchor      the commit that ref pointed at when the record was written
//   git_dir     the ABSOLUTE git dir of the pinned checkout
// A record missing any of the three is LEGACY (every record written before this
// ticket) and keeps the old behaviour: a mismatch denies.
//
// On a mismatch against a v2 record, under the record lock, with EVERY git call
// pinned to `--git-dir=<record.git_dir>` and GIT_NO_REPLACE_OBJECTS=1:
//   (a) the on-disk blob must BE the blob at the anchor ref's current tip T for
//       this path — the new bytes are not "plausible", they are the project's
//       published bytes;
//   (b) the recorded anchor must be an ancestor of T — the anchor line only
//       ever moves forward, so a rewound or replaced origin ref denies;
//   (c) the PINNED blob must appear somewhere in T's history for this path.
// (c) is what separates the two pin populations with no stored flag, and it is
// the load-bearing one. A pin that is BEHIND (a worktree cut before the hook
// change merged) holds an older main-line blob for that path, so it is found in
// T's history → allow, and re-pin. A pin that is AHEAD (an unmerged hook change
// on this branch, or a tampered blob that was never committed anywhere) is not
// in T's history → deny, with no re-pin: today's behaviour, kept, as the
// intended degrade, until the change actually lands on the main line, after
// which the next mismatch finds it and heals. Two near-miss attacks fall out of
// the same three checks: restoring an OLDER blob over an ahead pin fails (c)
// (the ahead pin is not in history), and a descendant commit that changes other
// files while keeping the old blob fails (a) (the tip's blob for this path is
// not what is on disk).
//
// The re-pin is written SYNCHRONOUSLY before this returns ok, under an
// mkdir-based lock on the record path, and is re-read back before the allow is
// granted — a launcher that says "ok, advanced" while the advancement is still
// only in memory would re-do the whole verification (and re-pay its git cost)
// on every subsequent hook call in the session, and would silently allow on a
// pin directory that has become unwritable.
//
// The FAST PATH — everything up to and including `blob(disk) === pin` — is
// unchanged and strictly git-free: not one child process is spawned on it. That
// matters because this code runs on every hook call in every session.

function gitBlobSha1(buffer) {
  const header = Buffer.from(`blob ${buffer.length}\0`, 'utf8');
  return crypto.createHash('sha1').update(Buffer.concat([header, buffer])).digest('hex');
}

function hookIntegrityDir() {
  return process.env.HIMMEL_HOOK_INTEGRITY_DIR
    || path.join(os.homedir(), '.claude', 'himmel', 'hook-integrity');
}

// session_id comes off the hook payload's JSON with no shape guarantee and is
// used to build a filesystem path below. record-hook-integrity.sh enforces the
// same restriction on the write side (its own header comment carries the
// reasoning) — a `/`, `..`, or a leading `-` in an otherwise-untrusted string
// must never reach path.join unfiltered, defense-in-depth even though a real
// Claude Code session_id is not agent-controlled input.
const SAFE_SESSION_ID = /^[A-Za-z0-9_-]+$/;

function integrityRecordPath(sessionId) {
  if (!sessionId || !SAFE_SESSION_ID.test(sessionId)) return null;
  return path.join(hookIntegrityDir(), `${sessionId}.json`);
}

function loadIntegrityRecord(sessionId) {
  const file = integrityRecordPath(sessionId);
  if (!file) return null;
  try {
    const parsed = JSON.parse(fs.readFileSync(file, 'utf8'));
    return parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : null;
  } catch (_e) {
    return null; // no pin file, unreadable, or malformed — all fail OPEN
  }
}

function recordPins(record) {
  return record && typeof record.pins === 'object' && record.pins && !Array.isArray(record.pins)
    ? record.pins
    : null;
}

function nonEmptyString(value) {
  return typeof value === 'string' && value.length > 0;
}

// Schema v2 = all three HIMMEL-2528 fields present. Anything else is LEGACY and
// keeps the pre-2528 deny-on-mismatch behaviour.
function isV2Record(record) {
  return Boolean(record)
    && nonEmptyString(record.anchor_ref)
    && nonEmptyString(record.anchor)
    && nonEmptyString(record.git_dir);
}

// ------------------------------------------------------------------ git calls
//
// GIT_NO_REPLACE_OBJECTS=1 on every call, at zero cost: refs/replace and
// info/grafts are history-rewriting mechanisms that live INSIDE the repository
// a tampering worker can already write to, so without it a `git replace <tip>
// <forged>` would make checks (a)/(c) below read a history the project never
// published.
//
// Every call is also TIME-BOUNDED, because the mismatch path runs git while
// HOLDING the record lock: a git that never returns (a `.git` on a dead NFS
// mount, a stalled network filesystem, a repository another process has wedged)
// would pin the lock open for every other launcher in the session — the very
// failure the lock's own 200 ms bounded wait exists to prevent. 5 s is roughly
// 300x the measured worst case: three of the four calls are single object reads
// (O(ms)), and the only history walk — `log --find-object`, which scans the
// whole path-limited history when the blob is NOT there — takes 17 ms over
// himmel's ~1950 commits. Four calls therefore bound a wedged lock at ~20 s
// instead of forever. A timeout is a VERIFICATION FAILURE, never a pass.
const GIT_TIMEOUT_DEFAULT_MS = 5000;
const GIT_TIMEOUT_CODE = 'HIMMEL_HOOK_INTEGRITY_GIT_TIMEOUT';

// The override exists so the suite can drive the timeout in milliseconds rather
// than seconds. It is not an attack surface worth fencing: shrinking the budget
// only makes verification DENY sooner (fail-closed), and enlarging it cannot
// turn a deny into an allow — it can only make this launcher wait longer.
function gitTimeoutMs() {
  const raw = Number(process.env.HIMMEL_HOOK_INTEGRITY_GIT_TIMEOUT_MS);
  return Number.isInteger(raw) && raw > 0 ? raw : GIT_TIMEOUT_DEFAULT_MS;
}

function runGit(args, cwd) {
  const budget = gitTimeoutMs();
  const result = spawnSync('git', args, {
    cwd: cwd || undefined,
    encoding: 'utf8',
    env: { ...process.env, GIT_NO_REPLACE_OBJECTS: '1' },
    timeout: budget,
    windowsHide: true,
  });
  // A timed-out git is SIGTERM'd and would otherwise land in the same branch as
  // "git is absent" below, where an empty result reads as "the ref does not
  // exist" — a wrong, and quietly misleading, deny reason. Throw a tagged error
  // instead so the one caller that can name it does, and so no check can ever
  // interpret a hung git as a satisfied condition.
  if (result.error && result.error.code === 'ETIMEDOUT') {
    const err = new Error(`git exceeded the ${budget} ms verification budget`);
    err.himmelCode = GIT_TIMEOUT_CODE;
    throw err;
  }
  // spawn failure (git absent) and a signal-killed git both land here.
  if (result.error || typeof result.status !== 'number') return null;
  return { status: result.status, stdout: String(result.stdout || '') };
}

// Every verification call goes through the git dir the RECORD names — never
// `-C <projectDir>` and never a bare `git` in the project. A worktree's `.git`
// is a one-line pointer FILE that the same Edit grant which motivates this
// whole check can rewrite; `-C <projectDir>` would then follow it into a decoy
// repository that happily contains the tampered blob on its "origin" tip.
// cwd is deliberately os.tmpdir() and the pathspec below carries `:(top)`, so
// neither the caller's cwd nor a work tree inferred from it can shift how the
// pathspec resolves.
function gitInRecordedRepo(gitDir, args) {
  return runGit([`--git-dir=${gitDir}`, ...args], os.tmpdir());
}

function gitStdout(result) {
  return result && result.status === 0 ? result.stdout.trim() : '';
}

// ------------------------------------------------------------- record locking
//
// Two launchers can hit the same mismatch on the same tool call (a --chain
// entry and a sibling entry, or two chains), and both would advance the same
// record. The lock is an atomic mkdir of "<recordPath>.lock" holding an `owner`
// file; scripts/hooks/hook-integrity-lock.sh implements the identical protocol
// for the bash side, and the two must stay in step.
const LOCK_MAX_WAIT_MS = 200;
const LOCK_POLL_MS = 10;

// A pid is only meaningful inside the namespace that minted it. Under Git-Bash
// on Windows, bash's $$ is an MSYS pid ("msys") — a DIFFERENT numbering from
// the win32 pids node sees — so neither side may interpret the other's pid.
// A foreign namespace is therefore never reclaimed, only waited out.
function lockNamespace() {
  return process.platform === 'win32' ? 'win32' : 'posix';
}

// Field 22 of /proc/<pid>/stat (starttime). Everything up to and including the
// last ") " is skipped because comm can itself contain spaces and parens, after
// which field 3 is at index 0 — so field 22 is index 19. Empty string wherever
// this is unavailable (non-Linux, hidepid, a vanished pid); an empty token
// simply removes the pid-reuse discrimination below, it never widens reclaim.
function processStartToken(pid) {
  try {
    return fs.readFileSync(`/proc/${pid}/stat`, 'utf8').replace(/^.*\) /, '').split(/\s+/)[19] || '';
  } catch (_e) {
    return '';
  }
}

function sleepMs(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

function parseLockOwner(lockDir) {
  let raw;
  try {
    raw = fs.readFileSync(path.join(lockDir, 'owner'), 'utf8');
  } catch (_e) {
    return null; // unreadable owner — refuse to reclaim
  }
  const fields = {};
  for (const line of raw.split('\n')) {
    const match = line.match(/^([a-z_]+)=(.*)$/);
    if (match) fields[match[1]] = match[2];
  }
  const pid = Number(fields.pid);
  if (!Number.isInteger(pid) || pid <= 0) return null;
  if (typeof fields.pid_namespace !== 'string' || !fields.pid_namespace) return null;
  if (typeof fields.start_time !== 'string') return null;
  return { pid, namespace: fields.pid_namespace, startTime: fields.start_time };
}

// Reclaim ONLY when the owner is provably dead. Never by age: an over-age lock
// whose owner is merely paused (a stopped process, a swapped-out box, a
// debugger) would resume inside its critical section and publish a record built
// from the state it read BEFORE we stole the lock — silently overwriting a
// newer publication. "Old" is not "dead"; only the pid says that.
function reclaimIfDead(lockDir) {
  const owner = parseLockOwner(lockDir);
  if (!owner) return false;                                // malformed → refuse
  if (owner.namespace !== lockNamespace()) return false;    // foreign pids are not ours to read
  let alive = true;
  try {
    process.kill(owner.pid, 0);
  } catch (e) {
    // ESRCH: no such process. EPERM: the process EXISTS under another user —
    // that is a live owner, not a dead one.
    if (e && e.code === 'ESRCH') alive = false;
  }
  // pid reuse: the pid resolves, but to a process that started at a different
  // time than the one that took the lock, so the original owner is gone.
  if (alive && owner.startTime) {
    const live = processStartToken(owner.pid);
    if (live && live !== owner.startTime) alive = false;
  }
  if (alive) return false;
  // The owner is provably dead — but "provably dead" is a conclusion TWO
  // contenders can reach from the same owner file at the same time, so the
  // steal itself has to pick a winner. Removing the directory in place does
  // not: both would remove it, and the loser's removal would land AFTER the
  // winner had re-created the lock and started its critical section, deleting a
  // live lock and leaving two launchers publishing from stale reads.
  //
  // Renaming is at least atomic — but a rename cannot be CONDITIONED on which
  // directory is at the path, and that is the hole this used to paper over. It
  // is only true that "the loser's rename fails ENOENT" while the winner has
  // not yet recreated the path. Once the winner has stolen the dead lock AND
  // re-taken it under its own live pid, the loser's rename SUCCEEDS — against
  // the winner's LIVE lock, which it then carts off and deletes.
  //
  // So the identity check happens after the move and is undone when it was the
  // wrong one: the directory we just renamed aside must still carry the owner
  // we inspected. A recreated lock cannot, by construction — a holder only ever
  // writes its OWN pid into the owner file, and we only got here by proving the
  // recorded pid is dead, so a recreated lock always names a different, live
  // pid. An owner file that is not there at all (mkdir done, stamp not yet
  // written) is the same verdict: not the incarnation we judged. Put it back
  // and refuse.
  //
  // RESIDUAL, small but real: the restore is itself two syscalls, so a third
  // party can occupy the freed path in between. The rename back then fails and
  // we leave the graveyard where it is rather than delete a lock we could not
  // return — inert litter beats an unjustified deletion.
  //
  // That failed restore leaves the ONE state this protocol cannot resolve, and
  // it is worth naming exactly rather than glossing: the holder whose live lock
  // we carted off still believes it holds the path, while the third party
  // genuinely does — two writers, both inside their critical section.
  // releaseRecordLock's ownership check below stops the first from deleting the
  // second's lock on the way out, which bounds the damage to that overlap
  // instead of letting the protocol collapse into unlocked publishing for
  // everyone afterwards. It does not close the overlap, and nothing built from
  // mkdir + rename can: the identity of a lock directory can only be SAMPLED
  // after the fact, never made a precondition of the operation (there is no
  // conditional rmdir, and rename cannot be predicated on what sits at the
  // source). Closing it needs a primitive the kernel keeps valid for the whole
  // critical section — an fcntl/flock on a held fd, which would also dissolve
  // the liveness probing and the graveyard entirely — i.e. a different lock,
  // not one more check on this one. Reaching the state at all needs all three
  // of: a provably dead owner, a contender that wins the steal and re-takes the
  // path, and a third occupant arriving inside that two-syscall restore.
  //
  // The graveyard name carries our pid and a random suffix so two reclaimers
  // can never collide on the destination either. hil_lock_reclaim in
  // scripts/hooks/hook-integrity-lock.sh implements this same protocol for
  // bash and the two must not diverge; the post-rename identity check is the
  // one part not mirrored there yet.
  const graveyard = `${lockDir}.dead.${process.pid}.${crypto.randomBytes(4).toString('hex')}`;
  try {
    fs.renameSync(lockDir, graveyard);
  } catch (_e) {
    return false; // someone else won the steal; nothing of ours to clean up
  }
  const moved = parseLockOwner(graveyard);
  if (!moved || moved.pid !== owner.pid || moved.namespace !== owner.namespace
      || moved.startTime !== owner.startTime) {
    try {
      fs.renameSync(graveyard, lockDir);
    } catch (_e) { /* the path is occupied again — leave the graveyard inert */ }
    return false;
  }
  try {
    fs.rmSync(graveyard, { recursive: true, force: true });
  } catch (_e) {
    // The lock path is already free, which is all the caller needs; a graveyard
    // we could not remove is inert (nothing ever looks at it again).
  }
  return true;
}

// Returns the lock dir on success, null when the bounded wait expired or the
// lock could not be created at all (an unwritable pin directory lands here).
function acquireRecordLock(recordPath) {
  const lockDir = `${recordPath}.lock`;
  const deadline = Date.now() + LOCK_MAX_WAIT_MS;
  for (;;) {
    let created = false;
    try {
      fs.mkdirSync(lockDir);
      created = true;
    } catch (e) {
      if (!e || e.code !== 'EEXIST') return null;
    }
    if (created) {
      // The mkdir and the owner file are two operations, and the second can
      // fail on its own (a full disk, a directory that turned unwritable
      // between them). An owner-less lock directory is the worst possible
      // residue: reclaimIfDead refuses it FOREVER (parseLockOwner returns null
      // for a missing owner file, and "refuse" is the deliberate answer to an
      // owner we cannot read), so it would wedge the re-pin path for every
      // future session on this record — a permanent deny, from a transient
      // error. Take the directory back down and report failure instead; this
      // call then simply denies, and the next launcher starts clean.
      try {
        fs.writeFileSync(
          path.join(lockDir, 'owner'),
          `pid=${process.pid}\npid_namespace=${lockNamespace()}\nstart_time=${processStartToken(process.pid)}\n`,
        );
        return lockDir;
      } catch (_e) {
        try {
          fs.rmSync(lockDir, { recursive: true, force: true });
        } catch (_e2) { /* best effort — nothing better is available here */ }
        return null;
      }
    }
    if (Date.now() >= deadline) return null;
    if (!reclaimIfDead(lockDir)) sleepMs(LOCK_POLL_MS);
  }
}

// Remove the lock ONLY when its owner file still names THIS process — the
// semantics hil_lock_release has carried all along in
// scripts/hooks/hook-integrity-lock.sh, and the divergence that turned
// reclaimIfDead's steal window into a deleted successor. A former holder whose
// lock was carted off there keeps a path STRING that a successor now owns, and
// an unconditional rmSync on the way out deletes that successor's live lock,
// leaving two publishers running with no lock between them.
//
// pid + namespace, exactly like the bash twin — deliberately NOT start_time.
// The comparison is against our OWN live pid, which cannot be a reused number
// while we are the process holding it, so start_time has nothing to
// discriminate here; all it could do is refuse a legitimate release when /proc
// was unreadable at acquire time and readable now, leaking the lock until the
// next reclaim. Matching the twin beats a check with no discriminating power.
//
// Necessary, not sufficient: see reclaimIfDead's RESIDUAL for what this bounds
// and what it cannot close.
function releaseRecordLock(lockDir) {
  try {
    const owner = parseLockOwner(lockDir);
    if (!owner || owner.pid !== process.pid || owner.namespace !== lockNamespace()) return;
    fs.rmSync(lockDir, { recursive: true, force: true });
  } catch (_e) {
    // A lock we cannot remove is waited out (and then reclaimed) by the next
    // launcher; never let cleanup change a decision that is already made.
  }
}

// Atomic-as-we-can publish: temp file BESIDE the destination (a mkdtemp temp
// dir can land on another filesystem, where rename() is EXDEV), rename over it,
// restore 0400. The destination is 0400 by design, and Windows refuses to
// rename over a read-only file — chmod 0600 first, and on win32 fall back to
// unlink+rename (record-hook-integrity.sh's `attrib -R` is a bash-only path).
function persistIntegrityRecord(recordPath, record) {
  const tmp = `${recordPath}.tmp-${process.pid}-${crypto.randomBytes(6).toString('hex')}`;
  fs.writeFileSync(tmp, `${JSON.stringify(record)}\n`, { mode: 0o600 });
  try {
    try {
      fs.chmodSync(recordPath, 0o600);
    } catch (_e) {
      // Destination may not exist yet, or chmod may be a no-op on this host.
    }
    try {
      fs.renameSync(tmp, recordPath);
    } catch (e) {
      if (process.platform !== 'win32') throw e;
      // win32 fallback. It used to unlink the incumbent record and then rename
      // the replacement in, which is fail-OPEN twice over: readers take the
      // fast path WITHOUT the lock, and loadIntegrityRecord treats an absent
      // record as "no opinion" (allow), so any reader landing between the two
      // calls skips verification entirely — and if the second rename also
      // failed, the record was gone for good and verification stayed disabled
      // for the rest of the session. Move the incumbent ASIDE instead: the
      // window shrinks to one rename, and a failed publish can put the old
      // record back rather than leaving nothing.
      const aside = `${recordPath}.old-${process.pid}-${crypto.randomBytes(6).toString('hex')}`;
      fs.renameSync(recordPath, aside);
      try {
        fs.renameSync(tmp, recordPath);
      } catch (e2) {
        try {
          fs.renameSync(aside, recordPath); // restore: never publish an absence
        } catch (_e) { /* best effort — the aside copy is still on disk to recover by hand */ }
        throw e2;
      }
      try {
        fs.unlinkSync(aside);
      } catch (_e) { /* best effort — a stale aside copy is inert */ }
      // Between those two renames the record still does not exist, and rename
      // semantics on win32 cannot close that — there is no atomic replace here,
      // which is why this fallback exists at all. What used to make it a hole
      // was the READER side: a lock-free fast-path reader in that window read
      // an absent record as "no opinion" and allowed. loadRecordAcrossPublish
      // below closes that, using the lock plus the `aside` file this line
      // creates as the two markers of a publication in flight — so the aside is
      // load-bearing beyond its own restore, and this name must keep matching
      // PUBLISH_ASIDE_SUFFIX. Concurrent WRITERS were never at risk:
      // persistIntegrityRecord only ever runs under the record lock.
    }
  } catch (e) {
    try {
      fs.unlinkSync(tmp);
    } catch (_e) { /* best effort */ }
    throw e;
  }
  try {
    fs.chmodSync(recordPath, 0o400);
  } catch (_e) { /* best effort — the pin still exists and still verifies */ }
}

// ------------------------------------------- reading across a publish window
//
// The win32 fallback above has no atomic replace, so between its two renames
// there is NO record on disk. Readers take the fast path without the lock and
// treat an absent record as "no opinion" → allow, so a reader landing in that
// window skips verification altogether; and a publisher killed inside the
// window leaves that state on disk permanently, silently disabling
// verification for the rest of the session.
//
// TWO markers together say "a publication is in flight", and neither alone
// does:
//   * the record LOCK — persistIntegrityRecord only ever runs while holding it;
//   * an `<record>.old-…` ASIDE — nothing but that fallback ever creates one.
// The lock alone would be wrong: record-hook-integrity.sh holds this same lock
// while it builds the session's FIRST record, and there is legitimately no
// record on disk then. Requiring the aside too leaves that ordinary
// session-start case on the fail-open path it has always been on.
//
// Cost where it matters: a session WITH a record returns on the first line and
// pays nothing. A session with no record at all pays one existsSync plus one
// re-read that misses — an open() returning ENOENT, and the price of not
// mistaking a publisher who finished mid-inspection for one who was never
// there (see the fail-open exits below). No git, no spawn, and no lock is taken
// unless both markers are present — the zero-spawn fast path is untouched.
const PUBLISH_ASIDE_SUFFIX = '.old-';

// A publish-window denial is NOT a content mismatch, and denyIntegrityMismatch's
// ordinary copy would send an operator hunting for a tampered file that is not
// there. It gets its own body, told apart by this sentinel prefix on `reason`
// rather than by a new parameter: run-hook-with-bash.js calls that function as
// (scriptPath, relPath, reason) from three places, and that signature is not
// this module's to change.
const PUBLISH_WINDOW_DENY = 'publish-window: ';

// "Several asides" and "no aside" used to be the same answer — null — and the
// caller reads null as "no evidence of a publication, fail open". So a single
// leftover aside from an EARLIER failed cleanup put every later publication
// window of that session back on the fail-open path this whole section exists
// to close, by being AMBIGUOUS rather than absent. They are opposite evidence:
// none says nothing was ever in flight, several says a window was entered and
// at least one was never resolved. Absent keeps failing open; ambiguous denies.
const AMBIGUOUS_ASIDE = Symbol('ambiguous publish aside');

// Returns the single aside's path, null when there is none (and when the pin
// directory cannot be listed at all — no evidence either way, and a directory
// we cannot read is the same directory the record read already failed on), or
// AMBIGUOUS_ASIDE when more than one is present.
function publishAsidePath(recordPath) {
  const dir = path.dirname(recordPath);
  const prefix = `${path.basename(recordPath)}${PUBLISH_ASIDE_SUFFIX}`;
  let names;
  try {
    names = fs.readdirSync(dir);
  } catch (_e) {
    return null;
  }
  const asides = names.filter((name) => name.indexOf(prefix) === 0);
  if (asides.length === 1) return path.join(dir, asides[0]);
  // More than one and there is no telling which incumbent this window belongs
  // to — which is a reason to refuse, never a reason to stop looking.
  return asides.length === 0 ? null : AMBIGUOUS_ASIDE;
}

// Returns { record } — the record to verify against, null meaning "no opinion,
// fail open" exactly as before — or { record: null, denyReason } when a
// publication is in flight and could not be resolved.
function loadRecordAcrossPublish(sessionId) {
  const record = loadIntegrityRecord(sessionId);
  if (record) return { record };
  const recordPath = integrityRecordPath(sessionId);
  // Nothing to re-read for a rejected session id: integrityRecordPath and
  // loadIntegrityRecord refuse it by the same test, so a second read is
  // guaranteed to return the same null.
  if (!recordPath) return { record: null };
  // Every fail-open exit below re-reads the record first, and that is the whole
  // point of them. The two markers this function consults are the DEBRIS of a
  // publication in flight, and a publisher that finishes while we are looking
  // at them TAKES THEM AWAY — so "no lock" and "no aside" are also exactly what
  // a publication that completed one instant ago looks like. Returning fail-open
  // from either without looking again gave up precisely in the window this
  // function exists to close: the record is on disk, readable, and we would have
  // ignored it.
  const reread = () => ({ record: loadIntegrityRecord(sessionId) });
  if (!fs.existsSync(`${recordPath}.lock`)) return reread();
  const aside = publishAsidePath(recordPath);
  if (aside === AMBIGUOUS_ASIDE) {
    const settled = loadIntegrityRecord(sessionId);
    if (settled) return { record: settled };
    return {
      record: null,
      denyReason: `${PUBLISH_WINDOW_DENY}more than one unresolved publication aside beside ${recordPath}`,
    };
  }
  if (!aside) return reread();
  // Retry first: a live publisher closes this window in one rename, so the
  // overwhelmingly likely outcome is that the record simply appears.
  const deadline = Date.now() + LOCK_MAX_WAIT_MS;
  while (Date.now() < deadline) {
    sleepMs(LOCK_POLL_MS);
    const fresh = loadIntegrityRecord(sessionId);
    if (fresh) return { record: fresh };
  }
  // It never landed. Failing open here IS the persistent hole, and denying for
  // the rest of the session bricks it for a state no future actor resolves — so
  // do what the publisher's own error path would have done and put the
  // incumbent back. Under the record lock, so a merely SLOW live publisher
  // cannot have its window stolen: acquireRecordLock reclaims only a provably
  // dead owner, which is exactly the crashed-publisher case, and returns null
  // for a live one — which denies below, transiently and correctly.
  const lockDir = acquireRecordLock(recordPath);
  if (!lockDir) {
    // No re-read here, unlike the exits above, and the difference is the
    // direction of the mistake: those failed OPEN on a publisher that had
    // finished, this one denies. A publish that lands after this point simply
    // gets verified on the next hook call — a transient deny costs one retry,
    // where a transient allow is the hole.
    return {
      record: null,
      denyReason: `${PUBLISH_WINDOW_DENY}a record publication is still in flight at ${recordPath}`,
    };
  }
  try {
    if (!fs.existsSync(recordPath)) {
      fs.renameSync(aside, recordPath);
      try {
        fs.chmodSync(recordPath, 0o400);
      } catch (_e) { /* best effort — the record is what matters, not its mode */ }
    }
  } catch (_e) {
    // A restore we could not perform denies on the re-read below.
  } finally {
    releaseRecordLock(lockDir);
  }
  const restored = loadIntegrityRecord(sessionId);
  if (restored) return { record: restored };
  return {
    record: null,
    denyReason: `${PUBLISH_WINDOW_DENY}a record publication left no record at ${recordPath}`,
  };
}

// ------------------------------------------------------------ bootstrap (§4)
//
// Reduced form of scripts/guardrails/lib.sh:103-125 default_branch — DELIBERATELY
// not a reimplementation of it (no local-branch probes, no init.defaultBranch
// fallback, no ambiguity note): this is reachable ONLY on the one-time bootstrap
// below, where the record is legacy and therefore carries no anchor_ref to read.
// Every v2 path uses the recorded ref and never comes here.
function bootstrapDefaultRef(projectDir) {
  const head = runGit(['-C', projectDir, 'symbolic-ref', '--quiet', '--short', 'refs/remotes/origin/HEAD']);
  const short = gitStdout(head);
  if (short) return short.startsWith('refs/') ? short : `refs/remotes/${short}`;
  for (const ref of ['refs/remotes/origin/main', 'refs/remotes/origin/master']) {
    if (gitStdout(runGit(['-C', projectDir, 'rev-parse', '--verify', '--quiet', ref]))) return ref;
  }
  return null;
}

// OPEN RESIDUAL (HIMMEL-2528, reviewed and left open deliberately): the two
// bootstrap probes run `-C projectDir`. Every v2 path instead runs
// `--git-dir=<record.git_dir>` precisely so a rewritten worktree `.git` — a
// one-line pointer FILE, writable by the same Edit(<worktree>) grant this whole
// check exists to survive — cannot redirect git at a repository the attacker
// chose (row 11 of test-hook-rewrite-integrity.sh proves that for the v2 path).
// Here there is nothing to pin to: the record is LEGACY, which is the entire
// entry condition, and a legacy record carries no git_dir. So a worker that
// rewrites `<projectDir>/.git` to point at a decoy repo whose default branch
// carries a tampered recorder gets that recorder accepted by this bootstrap.
//
// Neither obvious closure works. Refusing a gitfile pointer (accept only a real
// `.git` DIRECTORY) would refuse the exception in every session running from a
// git worktree — which is how himmel does all feature work, and exactly the
// deploy-time population this exception exists to unbrick, so it reintroduces
// the ordering problem wholesale. Constraining the resolved git dir by LOCATION
// (require it outside projectDir) stops only the decoy staged INSIDE the
// worktree, not one staged anywhere else with the Bash grant the same worker
// holds — a fence in appearance only.
//
// What bounds it is REACHABILITY, and reachability only. It does not bound the
// CONSEQUENCE, and an earlier draft of this comment implied that it did by
// calling the exception narrow and stopping there. The single path this
// exception admits is record-hook-integrity.sh — the script that writes every
// pin in the record. A tampered recorder accepted here can therefore pin
// whatever bytes it likes for every hook in the chain, or keep publishing
// legacy records so this branch never becomes unreachable at all. "Only the
// recorder" is the LARGEST blast radius in this file, not a small one: inside
// the window the bypass is total.
//
// So the honest statement is the entry condition, not a containment claim: a
// LEGACY record only, the recorder's own path only, no re-pin written here, and
// the on-disk bytes must equal the origin-tracking default branch's tip for
// that path. Sessions started after this ticket never hold a legacy record at
// all, and the recorder replaces the legacy record with a v2 one moments later,
// after which this branch is unreachable for the life of the session — one
// path, in one session, at one deploy, with everything at stake inside it.
//
// It exists because the recorder pins ITSELF and the plugin's SessionStart
// chain runs it THROUGH this launcher: a live session holding a legacy record
// would deny the changed recorder before it could ever write the v2 record that
// makes the mismatch path work, so deploying HIMMEL-2528 would brick every
// session already running. That is a deploy-ordering argument and buys exactly
// one deploy past the ordering problem. It is not a security argument.
//
// Closure is the signed hook-generation manifest tracked as HIMMEL-2572 — hook
// content trusted by a signature over the committed tree rather than by
// whatever origin/<default> resolves to at the moment this runs. Deliberately
// NOT fixed here.
const RECORDER_REL_PATH = 'scripts/hooks/record-hook-integrity.sh';

function bootstrapAcceptsRecorder(projectDir, relPath, actual) {
  if (relPath !== RECORDER_REL_PATH) return false;
  const ref = bootstrapDefaultRef(projectDir);
  if (!ref) return false;
  return gitStdout(runGit(['-C', projectDir, 'rev-parse', '--verify', '--quiet', `${ref}:${relPath}`])) === actual;
}

// ------------------------------------------------------- the mismatch path
//
// Reached ONLY when blob(disk) !== the pinned blob. Returns {ok:true} after a
// persisted re-pin, or {ok:false, relPath, reason}. Never throws.
//
// The wrapper exists for ONE case: runGit throws on a timeout (see its header),
// and a hung git has to become a deny that says so. It is a wrapper rather than
// a catch inside the body because every throw site is already inside the body's
// try/finally, so the lock is released before this ever sees the error, and the
// bootstrap probes — which run BEFORE the lock is taken — are covered too.
function resolveMismatch(context) {
  try {
    return resolveMismatchInner(context);
  } catch (e) {
    if (e && e.himmelCode === GIT_TIMEOUT_CODE) {
      return { ok: false, relPath: context.relPath, reason: e.message };
    }
    throw e; // anything else keeps the caller's fail-closed catch-all
  }
}

function resolveMismatchInner(context) {
  const { projectDir, relPath, actual, record, sessionId } = context;
  const deny = (reason) => ({ ok: false, relPath, reason: reason || null });

  if (!isV2Record(record)) {
    return bootstrapAcceptsRecorder(projectDir, relPath, actual) ? { ok: true } : deny(null);
  }

  const recordPath = integrityRecordPath(sessionId);
  if (!recordPath) return deny(null);

  const lockDir = acquireRecordLock(recordPath);
  if (!lockDir) {
    // A sibling launcher on the same tool call has usually just advanced this
    // exact pin — re-read from disk and re-run the fast path once before
    // denying, so two hooks racing the same legitimate update do not deny.
    const fresh = loadIntegrityRecord(sessionId);
    const freshPins = recordPins(fresh);
    if (freshPins && freshPins[relPath] === actual) return { ok: true };
    return deny(`could not take the record lock at ${recordPath}.lock`);
  }

  try {
    // Re-read inside the lock: a sibling may have published while we waited.
    const fresh = loadIntegrityRecord(sessionId);
    const freshPins = recordPins(fresh);
    if (freshPins && freshPins[relPath] === actual) return { ok: true };
    const current = isV2Record(fresh) && freshPins ? fresh : record;
    const pins = recordPins(current);
    if (!pins) return deny(null);
    const pinned = pins[relPath];
    if (!nonEmptyString(pinned)) return deny(null);

    const gitDir = current.git_dir;
    // Resolved ONCE, and only now that the lock is held — a sibling may have
    // advanced the ref itself while we waited.
    const tip = gitStdout(gitInRecordedRepo(gitDir, ['rev-parse', '--verify', '--quiet', current.anchor_ref]));
    if (!tip) {
      const probe = gitInRecordedRepo(gitDir, ['rev-parse', '--git-dir']);
      if (probe === null) return deny('git is unavailable');
      return deny(`the anchor ref ${current.anchor_ref} could not be resolved`);
    }

    // (a) the on-disk bytes must BE the anchor tip's bytes for this path.
    const atTip = gitStdout(gitInRecordedRepo(gitDir, ['rev-parse', '--verify', '--quiet', `${tip}:${relPath}`]));
    if (atTip !== actual) return deny('not the anchor tip');

    // (b) monotonic: the recorded anchor must still be an ancestor of the tip.
    const ancestor = gitInRecordedRepo(gitDir, ['merge-base', '--is-ancestor', current.anchor, tip]);
    if (!ancestor || ancestor.status !== 0) return deny('anchor rewind');

    // (c) the PINNED blob must appear in the anchor line's history for this
    // path. `--full-history` is stated explicitly: default history
    // simplification prunes TREESAME parents, which is exactly where a
    // legitimately-behind pin's blob lives under a --no-ff main merge. (git's
    // pickaxe/--find-object machinery happens to disable simplification on its
    // own today — verified on git 2.55 — but that is an implementation detail
    // to rely on, not a contract.) The `:(top)` pathspec magic keeps the path
    // repo-root-relative regardless of the cwd git infers a work tree from.
    const history = gitStdout(gitInRecordedRepo(gitDir, [
      'log', '--full-history', `--find-object=${pinned}`, '--format=%H', '-n', '1', tip, '--', `:(top)${relPath}`,
    ]));
    if (!history) return deny('pinned blob is not on the anchor line');

    // Accept: advance the pin and the anchor in ONE transaction, preserving
    // every sibling pin a concurrent advancement may have published.
    const next = { ...current, pins: { ...pins, [relPath]: actual }, anchor: tip };
    try {
      persistIntegrityRecord(recordPath, next);
      const verified = loadIntegrityRecord(sessionId);
      const verifiedPins = recordPins(verified);
      if (!verifiedPins || verifiedPins[relPath] !== actual || verified.anchor !== tip) {
        return deny(`could not persist the re-pin under ${hookIntegrityDir()}`);
      }
    } catch (_e) {
      // Never return ok on an unpersisted advancement: the next hook call would
      // re-do this whole verification, and an unwritable pin directory would go
      // unnoticed until it mattered.
      return deny(`could not persist the re-pin under ${hookIntegrityDir()}`);
    }
    return { ok: true };
  } finally {
    releaseRecordLock(lockDir);
  }
}

function verifyProjectHookIntegrity(scriptPath, sessionId) {
  // ---- FAST PATH: strictly git-free, no child process, on every hook call ----
  if (process.env.HIMMEL_HOOK_INTEGRITY_BYPASS_OK === '1') return { ok: true };
  const projectDir = process.env.CLAUDE_PROJECT_DIR;
  if (!projectDir) return { ok: true };
  const normScript = normalize(scriptPath).toLowerCase();
  const normProject = normalize(projectDir).toLowerCase();
  if (!normScript.startsWith(`${normProject}/`)) return { ok: true }; // not project-local
  const relPath = normalize(scriptPath).slice(normalize(projectDir).length + 1);
  const { record, denyReason } = loadRecordAcrossPublish(sessionId);
  if (denyReason) return { ok: false, relPath, reason: denyReason };
  const pins = recordPins(record);
  if (!pins) return { ok: true };
  const expected = pins[relPath];
  if (typeof expected !== 'string' || !expected) return { ok: true }; // unpinned script
  let actual;
  try {
    actual = gitBlobSha1(fs.readFileSync(scriptPath));
  } catch (_e) {
    return { ok: true }; // unreadable/missing — the DELETE vector, already covered by --fail-closed-when
  }
  if (actual === expected) return { ok: true };
  // ---------------------------------- MISMATCH: HIMMEL-2528 re-pin or deny ---
  try {
    return resolveMismatch({ projectDir, relPath, actual, record, sessionId });
  } catch (_e) {
    // Any unforeseen failure on the mismatch path denies, exactly as before
    // this ticket — a crash here must never become an allow, and must never
    // spill a stack trace into the session transcript.
    return { ok: false, relPath, reason: null };
  }
}

function denyIntegrityMismatch(scriptPath, relPath, reason) {
  if (typeof reason === 'string' && reason.indexOf(PUBLISH_WINDOW_DENY) === 0) {
    process.stderr.write(
      `run-hook-with-bash: DENY ${path.basename(scriptPath)} — the session's hook-integrity record is `
      + `mid-publication and could not be read, so nothing vouches for ${relPath} `
      + `(${reason.slice(PUBLISH_WINDOW_DENY.length)}). An absent record used to read as "no opinion" `
      + 'and allow, which is how a reader in this window skipped verification entirely. Retry once the '
      + 'publishing process has finished; if it died, the incumbent record is beside the missing one as '
      + 'a .old-* file. Legitimate mid-session hook edit: rerun with HIMMEL_HOOK_INTEGRITY_BYPASS_OK=1 '
      + 'set in the LAUNCHING shell.\n',
    );
    return;
  }
  process.stderr.write(
    `run-hook-with-bash: DENY ${path.basename(scriptPath)} — on-disk content no longer matches the `
    + `git-committed version pinned at session start (${relPath}). A guard that fails this check cannot `
    + 'be trusted to run tampered, so the tool call it would have evaluated is refused instead. '
    + (reason ? `Re-pin refused: ${reason}. ` : '')
    + 'Legitimate mid-session hook edit: rerun with HIMMEL_HOOK_INTEGRITY_BYPASS_OK=1 set in the LAUNCHING shell.\n',
  );
}

// acquireRecordLock / reclaimIfDead / releaseRecordLock / persistIntegrityRecord
// are exported for the suite only — the launcher uses none of them. They are the
// three failure modes that cannot be provoked through verifyProjectHookIntegrity
// from the outside (a lost reclaim race, an owner file that will not write, and
// the win32 publish fallback), and a race whose fix is not tested is a fix that
// silently regresses.
module.exports = {
  LOCK_MAX_WAIT_MS,
  LOCK_POLL_MS,
  SAFE_SESSION_ID,
  acquireRecordLock,
  denyIntegrityMismatch,
  gitBlobSha1,
  hookIntegrityDir,
  integrityRecordPath,
  isV2Record,
  loadIntegrityRecord,
  persistIntegrityRecord,
  reclaimIfDead,
  releaseRecordLock,
  verifyProjectHookIntegrity,
};
