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
import { readFileSync, writeFileSync, existsSync, mkdirSync, renameSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const DEFAULT_FILE = join(SCRIPT_DIR, 'lanes.local.json');

// applyLaneOverride(local, laneId, probeKind) -> new local registry object.
// Pure (no I/O): replaces the matching-id entry's `probe`, or appends a new
// { id, probe } entry when laneId isn't already present in `local.lanes`.
// Every other entry is returned unchanged (same object references) so a
// caller diffing before/after sees only the touched entry move.
export function applyLaneOverride(local, laneId, probeKind) {
  const lanes = (local && Array.isArray(local.lanes)) ? local.lanes : [];
  const idx = lanes.findIndex((l) => l && l.id === laneId);
  const entry = { id: laneId, probe: { kind: probeKind } };
  const nextLanes = idx === -1
    ? [...lanes, entry]
    : lanes.map((l, i) => (i === idx ? entry : l));
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

function main(argv) {
  let laneId = null;
  let probeKind = null;
  let file = DEFAULT_FILE;
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--file') { file = argv[++i]; continue; }
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
  const local = loadLocal(file);
  const next = applyLaneOverride(local, laneId, probeKind);
  mkdirSync(dirname(file), { recursive: true });
  // Atomic write: write a sibling temp file, then rename over the target.
  // writeFileSync(file, ...) truncates the live overlay before the new bytes
  // land, so an interruption/disk error would leave invalid JSON that
  // resolve.mjs then refuses to parse (die 2). rename() within the same dir is
  // atomic — a concurrent reader sees either the old file or the fully-written
  // new one, never a half-written truncation.
  const tmp = `${file}.tmp.${process.pid}`;
  writeFileSync(tmp, JSON.stringify(next, null, 2) + '\n');
  renameSync(tmp, file);
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
