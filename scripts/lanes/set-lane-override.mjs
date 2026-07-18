#!/usr/bin/env node
// scripts/lanes/set-lane-override.mjs — idempotent per-lane probe-override
// writer for scripts/lanes/lanes.local.json (HIMMEL-758, `himmelctl config`).
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
import { readFileSync, writeFileSync, existsSync, mkdirSync, rmSync, statSync, renameSync } from 'node:fs';
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
// Every other entry is returned unchanged (same object references) so a
// caller diffing before/after sees only the touched entry move.
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
  return { ...(local || {}), lanes: nextLanes };
}

function loadLocal(file) {
  if (!existsSync(file)) return { lanes: [] };
  try {
    const parsed = JSON.parse(readFileSync(file, 'utf8'));
    return (parsed && typeof parsed === 'object') ? parsed : { lanes: [] };
  } catch (e) {
    throw new Error(`set-lane-override: ${file} is not valid JSON: ${e.message}`);
  }
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
        try { rmSync(lockPath, { recursive: true, force: true }); } catch { /* lost the reclaim race */ }
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
  try {
    rmSync(`${file}.lock`, { recursive: true, force: true });
  } catch (e) {
    if (e.code !== 'ENOENT') throw e;
  }
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
  // resolve.mjs treats as the base layer. Compare case-insensitively on win32:
  // NTFS is case-insensitive, so a differently-cased --file (e.g. LANES.JSON)
  // opens the SAME physical file and must not slip past this guard.
  const _sameAsRegistry = (p) =>
    process.platform === 'win32'
      ? resolve(p).toLowerCase() === resolve(SHARED_REGISTRY).toLowerCase()
      : resolve(p) === resolve(SHARED_REGISTRY);
  if (_sameAsRegistry(file)) {
    throw new Error(`set-lane-override: --file must not point at the shared registry (${SHARED_REGISTRY})`);
  }
  mkdirSync(dirname(file), { recursive: true });
  acquireLock(file);
  try {
    const local = loadLocal(file);
    const next = applyLaneOverride(local, laneId, probeKind);
    // Atomic write: write a sibling temp file, then rename over the target.
    // writeFileSync(file, ...) truncates the live overlay before the new bytes
    // land, so an interruption/disk error would leave invalid JSON that
    // resolve.mjs then refuses to parse (die 2). rename() within the same dir is
    // atomic — a concurrent reader sees either the old file or the fully-written
    // new one, never a half-written truncation.
    const tmp = `${file}.tmp.${process.pid}`;
    writeFileSync(tmp, JSON.stringify(next, null, 2) + '\n');
    renameSync(tmp, file);
  } finally {
    releaseLock(file);
  }
  process.stdout.write(`OK set-lane-override: lane '${laneId}' -> probe.kind=${probeKind} in ${file}\n`);
}

if (process.argv[1]?.endsWith('set-lane-override.mjs')) {
  try {
    main(process.argv.slice(2));
  } catch (e) {
    process.stderr.write(`${e.message}\n`);
    process.exit(1);
  }
}
