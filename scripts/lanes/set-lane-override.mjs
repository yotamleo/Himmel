#!/usr/bin/env node
// scripts/lanes/set-lane-override.mjs — idempotent machine-local overlay
// writer for scripts/lanes/lanes.local.json (HIMMEL-758 / HIMMEL-1428).
//
// Writes/merges ONE lane's `probe` override by id into the gitignored
// machine-local overlay file that resolve.mjs's loadRegistry() reads on top
// of the shared scripts/lanes/lanes.json registry (see resolve.mjs's
// mergeLocalOverlay()). NEVER touches lanes.json itself — this script only
// ever opens the file named by --file (default: lanes.local.json next to
// this script), so a hard-coded local-only path is the only thing it can
// write. Idempotent: re-running with the same (id, probeKind) reaches the
// same end-state; every OTHER lane's existing override in the file is left
// untouched (a shallow per-id upsert, not a wholesale rewrite).
//
// Usage:
//   node set-lane-override.mjs <lane-id> <always|never> [--file <path>]
//
// probeKind is deliberately restricted to `always`/`never` (force-on /
// force-off) — the two forced-override kinds `evalProbe` (probe.mjs)
// understands; a config toggle that needs a genuinely conditional probe
// (env/path/installed/crprofile) is hand-authored in lanes.local.json
// directly, same as lanes.json itself.
import { readFileSync, writeFileSync, existsSync, mkdirSync, rmSync, statSync, renameSync, accessSync, constants } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const DEFAULT_FILE = join(SCRIPT_DIR, 'lanes.local.json');
// The shared registry resolve.mjs's loadRegistry() reads as the base layer —
// --file must never resolve to this path (see the read-only check in main()).
const SHARED_REGISTRY = join(SCRIPT_DIR, 'lanes.json');

// applyLaneOverride(local, laneId, probeKind) -> new local registry object.
// Pure (no I/O): replaces the matching-id entry's `probe`, or appends a new
// { id, probe } entry when laneId isn't already present in `local.lanes`.
// Force-on also extends an active adopter profile when the lane is in its
// wizard-owned scope; every other lane entry remains unchanged.
export function applyLaneOverride(local, laneId, probeKind) {
  const lanes = (local && Array.isArray(local.lanes)) ? local.lanes : [];
  const idx = lanes.findIndex((l) => l && l.id === laneId);
  const probe = { kind: probeKind };
  const nextLanes = idx === -1
    ? [...lanes, { id: laneId, probe }]
    // Shallow-merge onto the existing entry so hand-authored fields other
    // than `probe` (e.g. a conditional-probe lane augmented with an override)
    // survive the upsert instead of being dropped.
    : lanes.map((l, i) => (i === idx ? { ...l, id: laneId, probe } : l));
  const next = { ...(local || {}), lanes: nextLanes };
  // An explicit force-on is also consent to route a lane that the adopter
  // profile previously excluded. Without this, the profile filter runs after
  // the probe override and turns a successful config set into a no-op. The
  // scope condition mirrors resolveLaneInventory's suppression rule exactly:
  // a LEGACY allowlist without profileAllowlistScope constrains EVERY lane
  // (global semantics), so the extension must fire there too — scoping the
  // consent to scope-carrying files only left the legacy shape with the same
  // false-success this fix removes (CR round 4 [codex-1]).
  if (probeKind === 'always'
      && Array.isArray(next.profileAllowlist)
      && (!Array.isArray(next.profileAllowlistScope)
        || next.profileAllowlistScope.includes(laneId))
      && !next.profileAllowlist.includes(laneId)) {
    next.profileAllowlist = [...next.profileAllowlist, laneId];
  }
  return next;
}

// The adopter profile allowlist is independent of per-lane probe overrides.
// It can only suppress an otherwise-resolving lane; it never replaces that
// lane's real probe. profileAllowlistScope limits that suppression to the
// wizard-owned subset, so lanes the wizard never offers stay on their base
// probes. A legacy scope-less allowlist is global, so preserve its non-wizard
// members instead of converting it to scoped semantics. Preserve every existing
// override and de-duplicate ids in first-seen order so repeated installs converge.
export function applyProfileAllowlist(local, laneIds, scopeLaneIds) {
  const lanes = (local && Array.isArray(local.lanes)) ? local.lanes : [];
  const dedupeIds = (ids) => {
    const out = [];
    for (const id of ids || []) {
      if (typeof id === 'string' && !out.includes(id)) out.push(id);
    }
    return out;
  };
  const selected = dedupeIds(laneIds);
  const legacyGlobal = Array.isArray(local?.profileAllowlist)
    && !Array.isArray(local?.profileAllowlistScope);
  if (legacyGlobal) {
    const wizardScope = new Set(dedupeIds(scopeLaneIds));
    const preserved = dedupeIds(local.profileAllowlist).filter((id) => !wizardScope.has(id));
    const next = { ...(local || {}), lanes, profileAllowlist: dedupeIds([...preserved, ...selected]) };
    delete next.profileAllowlistScope;
    return next;
  }
  const next = { ...(local || {}), lanes, profileAllowlist: selected };
  if (Array.isArray(scopeLaneIds)) next.profileAllowlistScope = dedupeIds(scopeLaneIds);
  return next;
}

function loadLocal(file) {
  if (!existsSync(file)) return { lanes: [] };
  let parsed;
  try {
    parsed = JSON.parse(readFileSync(file, 'utf8'));
  } catch (e) {
    throw new Error(`set-lane-override: ${file} is not valid JSON: ${e.message}`);
  }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    const shape = Array.isArray(parsed) ? 'top-level array' : String(parsed);
    throw new Error(`set-lane-override: ${file} must be a non-array object whose 'lanes' property is an array or absent (got ${shape})`);
  }
  if (parsed.lanes !== undefined && !Array.isArray(parsed.lanes)) {
    const shape = parsed.lanes === null ? 'null' : typeof parsed.lanes;
    throw new Error(`set-lane-override: ${file} must be a non-array object whose 'lanes' property is an array or absent (got 'lanes' ${shape})`);
  }
  return parsed;
}

// Advisory lock via mkdirSync (atomic create-exclusive), mirroring
// scripts/where-are-we/lib/append.mjs's acquireLock/releaseLock. Serializes
// the loadLocal -> applyLaneOverride -> write-tmp -> rename sequence across
// concurrent invocations so two writers can't interleave and clobber each
// other's update.
//
// Stale-lock recovery (CodeRabbit #470): a process that dies AFTER mkdirSync
// but before releaseLock would strand `${file}.lock` forever, wedging every
// later update at the 10s timeout until someone deletes it by hand. So the
// holder records its PID inside the lock, and a waiter reclaims the lock at
// most ONCE if its owner process is gone (ESRCH) or the lock is older than
// LOCK_STALE_MS — far above the sub-second hold, so a live holder is never
// reclaimed. Reclamation is race-safe: rmSync(force) then a fresh atomic
// mkdirSync, so if two waiters both reclaim, only one wins the mkdir and the
// other keeps contending normally.
const LOCK_STALE_MS = 30000;

function _lockIsStale(lockPath) {
  // Owner process gone -> definitely stale. Otherwise decide on age.
  try {
    const pid = Number(readFileSync(join(lockPath, 'owner'), 'utf8').trim());
    if (Number.isInteger(pid) && pid > 0) {
      try { process.kill(pid, 0); }                        // alive (or not ours)
      catch (e) { if (e.code === 'ESRCH') return true; }   // no such process
    }
  } catch { /* no/unreadable owner file — fall back to age alone */ }
  try { return Date.now() - statSync(lockPath).mtimeMs > LOCK_STALE_MS; }
  catch { return false; }
}

function acquireLock(file, opts = {}) {
  const { timeoutMs = 10000, backoffMs = 20 } = opts;
  const lockPath = `${file}.lock`;
  const deadline = Date.now() + timeoutMs;
  let reclaimed = false;
  while (true) {
    try {
      mkdirSync(lockPath);
      try { writeFileSync(join(lockPath, 'owner'), String(process.pid)); } catch { /* best effort */ }
      return;
    } catch (e) {
      if (e.code !== 'EEXIST') throw e; // non-lock error — surface immediately
      // Reclaim an abandoned lock at most ONCE per acquire, so a lock a live
      // holder keeps legitimately recreating is never repeatedly nuked.
      if (!reclaimed && _lockIsStale(lockPath)) {
        reclaimed = true;
        // Reclaim via an atomic rename, not a bare rmSync: renameSync of the
        // observed dir has exactly one winner, so two writers that both see the
        // stale lock can't both remove-and-enter — the loser gets ENOENT and
        // falls back to normal mkdirSync contention. releaseLock also checks
        // the recorded PID and won't remove a lock reclaimed away from it, so an
        // over-long live holder can't free a newer holder's lock. (A fully
        // generation-safe reclaim under PID reuse would still need a token;
        // disproportionate for this low-contention single-machine tool — codex
        // CR #470 / PR #1295.)
        try {
          const dead = `${lockPath}.dead.${process.pid}`;
          renameSync(lockPath, dead);
          rmSync(dead, { recursive: true, force: true });
        } catch { /* another writer reclaimed it first — contend normally */ }
        continue;
      }
      if (Date.now() >= deadline) {
        throw new Error(`set-lane-override: lock timeout for ${file}`);
      }
      // Synchronous sleep — must not be async to prevent lock leaks.
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, backoffMs);
    }
  }
}

function releaseLock(file) {
  const lockPath = `${file}.lock`;
  // Release only a lock we still own. If a waiter reclaimed us as stale (we
  // exceeded LOCK_STALE_MS while alive), the dir now records the NEW holder's
  // PID — removing it would free a live holder's lock and admit a concurrent
  // writer that clobbers registry updates. An absent/unreadable owner = our
  // own lock before the best-effort owner write landed, so it is still ours to
  // release. (codex + CodeRabbit, PR #1295.)
  try {
    const owner = readFileSync(join(lockPath, 'owner'), 'utf8').trim();
    if (owner && Number(owner) !== process.pid) return;
  } catch { /* no/unreadable owner — our own lock; fall through to remove */ }
  try {
    rmSync(lockPath, { recursive: true, force: true });
  } catch (e) {
    if (e.code !== 'ENOENT') throw e;
  }
}

function sameAsSharedRegistry(file) {
  // Case-fold on the case-insensitive default filesystems — win32 (NTFS) AND
  // macOS (APFS/HFS+): `LANES.JSON` opens the same file as `lanes.json`.
  const ciFs = process.platform === 'win32' || process.platform === 'darwin';
  return ciFs
    ? resolve(file).toLowerCase() === resolve(SHARED_REGISTRY).toLowerCase()
    : resolve(file) === resolve(SHARED_REGISTRY);
}

export function validateProfileAllowlistTarget(file) {
  const target = file || DEFAULT_FILE;
  if (sameAsSharedRegistry(target)) {
    throw new Error(`set-lane-override: --file must not point at the shared registry (${SHARED_REGISTRY})`);
  }
  loadLocal(target);
  let probe = dirname(target);
  while (!existsSync(probe)) {
    const parent = dirname(probe);
    if (parent === probe) break;
    probe = parent;
  }
  try {
    if (!statSync(probe).isDirectory()) throw new Error('parent is not a directory');
    accessSync(probe, constants.W_OK);
    if (existsSync(target)) {
      if (!statSync(target).isFile()) throw new Error('target is not a regular file');
      accessSync(target, constants.W_OK);
    }
  } catch (e) {
    const code = e && e.code ? ` (${e.code})` : '';
    throw new Error(`set-lane-override: overlay target is not writable: ${target}${code}`);
  }
  return target;
}

function writeLocal(file, update) {
  if (sameAsSharedRegistry(file)) {
    throw new Error(`set-lane-override: --file must not point at the shared registry (${SHARED_REGISTRY})`);
  }
  mkdirSync(dirname(file), { recursive: true });
  acquireLock(file);
  try {
    const next = update(loadLocal(file));
    // Atomic write: a direct writeFileSync can be interrupted mid-write and
    // leave a truncated overlay that every later resolve run would fail to
    // parse; write to a pid-suffixed temp then renameSync (atomic on the same
    // filesystem), so readers only ever see the old or the new complete file.
    const tmp = `${file}.tmp.${process.pid}`;
    try {
      writeFileSync(tmp, JSON.stringify(next, null, 2) + '\n');
      renameSync(tmp, file);
    } catch (e) {
      // A failed renameSync (or writeFileSync) must not orphan the
      // pid-suffixed temp next to the overlay — remove it before the lock is
      // released in finally (CodeRabbit #1525 nit). force tolerates an
      // already-gone path (e.g. writeFileSync itself threw before creating it).
      // force tolerates ENOENT, but NOT an EPERM/EBUSY unlink (Windows) —
      // letting that throw would replace the real write/rename failure with a
      // cleanup error the caller can do nothing about (panel r1, codex-1+glm-2
      // converged). Cleanup is best-effort; `e` is always what surfaces.
      try { rmSync(tmp, { force: true }); } catch { /* leave the temp behind */ }
      throw e;
    }
  } finally {
    releaseLock(file);
  }
}

export function writeProfileAllowlist(file, laneIds, scopeLaneIds) {
  const target = validateProfileAllowlistTarget(file);
  let preservedLegacyGlobal = false;
  writeLocal(target, (local) => {
    preservedLegacyGlobal = Array.isArray(local.profileAllowlist)
      && !Array.isArray(local.profileAllowlistScope);
    return applyProfileAllowlist(local, laneIds, scopeLaneIds);
  });
  return preservedLegacyGlobal;
}

function main(argv) {
  let laneId = null;
  let probeKind = null;
  let file = DEFAULT_FILE;
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--file') {
      if (i + 1 >= argv.length) {
        throw new Error('Usage: set-lane-override.mjs <lane-id> <always|never> [--file <path>]');
      }
      file = argv[++i];
      continue;
    }
    if (laneId === null) { laneId = a; continue; }
    if (probeKind === null) { probeKind = a; continue; }
    throw new Error(`set-lane-override: unexpected arg: ${a}`);
  }
  if (!laneId || !probeKind) {
    throw new Error('Usage: set-lane-override.mjs <lane-id> <always|never> [--file <path>]');
  }
  if (probeKind !== 'always' && probeKind !== 'never') {
    throw new Error(`set-lane-override: probeKind must be 'always' or 'never' (got '${probeKind}')`);
  }
  // Read-only shared-registry contract: --file may point at any local overlay
  // or a distinct temp path (tests), but never at the shared lanes.json that
  // resolve.mjs treats as the base layer. writeLocal owns that guard, locking,
  // and the atomic sibling-temp rename for every overlay update.
  let extendedProfileAllowlist = false;
  writeLocal(file, (local) => {
    const next = applyLaneOverride(local, laneId, probeKind);
    extendedProfileAllowlist = Array.isArray(local.profileAllowlist)
      && Array.isArray(next.profileAllowlist)
      && !local.profileAllowlist.includes(laneId)
      && next.profileAllowlist.includes(laneId);
    return next;
  });
  const profileNote = extendedProfileAllowlist ? '; added to profileAllowlist' : '';
  process.stdout.write(`OK set-lane-override: lane '${laneId}' -> probe.kind=${probeKind}${profileNote} in ${file}\n`);
}

if (process.argv[1]?.endsWith('set-lane-override.mjs')) {
  try {
    main(process.argv.slice(2));
  } catch (e) {
    process.stderr.write(`${e.message}\n`);
    process.exit(1);
  }
}
