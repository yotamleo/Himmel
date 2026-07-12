'use strict';
// scripts/himmelctl/lib/state.js — target-keyed install state (HIMMEL-756
// T1.3). Reads/writes <cacheDir()>/state.json, himmelctl's OWN record of
// "what does this target look like right now" — a SEPARATE artifact from the
// wizard's install-profile.json cache (the ANSWERS that drove an install),
// which this module never reads or mutates directly (callers pass the
// already-loaded answers object in).
//
// Shape:
//   { schemaVersion: 1, harness: "claude", targets: {
//       "<targetPathAbs>" | "user": {
//         profile, scope, items: { <id>: { enabled, overrides } }, lastEnsured
//       }
//   } }
//
// Derivation (first run for a target with no entry) is PURE manifest
// membership: profile = profileForVault(cachedAnswers) (lib/helpers.js), and
// an item's enabled = item.profiles.includes(profile) &&
// item.scopes.includes(scope) — with exactly ONE exception: `handover-wiring`
// tracks cachedAnswers.handover.mode !== 'none' directly (membership alone
// can't see whether handover was actually wired). No role/pluginSet
// branching here — explicitly Phase 2 (a later HIMMEL-756 follow-on).
//
// HIMMELCTL_CACHE_DIR overrides the cache dir (see lib/helpers.js) — the same
// seam hermetic tests use to redirect ~/.claude/himmel/ under Git Bash, where
// HOME does not propagate into node.exe children.

const fs = require('fs');
const path = require('path');
const { cacheDir, profileForVault } = require('./helpers.js');

function statePath() {
  return path.join(cacheDir(), 'state.json');
}

function emptyState() {
  return { schemaVersion: 1, harness: 'claude', targets: {} };
}

// Load the on-disk state, or an empty schema-shaped default when no
// state.json exists yet (first run). A malformed file surfaces its parse
// error to the caller rather than silently resetting to empty — state.json
// is himmelctl's own artifact, and a corrupt copy should be investigated,
// not discarded.
function load() {
  const p = statePath();
  if (!fs.existsSync(p)) return emptyState();
  return JSON.parse(fs.readFileSync(p, 'utf8'));
}

// Persist `state` via atomic temp-file + rename — mirrors
// scripts/lib/register-auto-arm-hook.sh's `$SETTINGS.tmp` + `mv` pattern for
// settings.json, so a crash mid-write never leaves a truncated state.json.
// 2-space indent + trailing newline (matches bin.js's serialize()); a saved
// state.json round-trips byte-identically across repeated saves of the same
// object (JS objects preserve string-key insertion order, so re-stringifying
// a just-parsed object reproduces the same key order it was read in).
function save(state) {
  const dir = cacheDir();
  fs.mkdirSync(dir, { recursive: true });
  const p = statePath();
  const tmp = `${p}.tmp-${process.pid}`;
  fs.writeFileSync(tmp, JSON.stringify(state, null, 2) + '\n');
  fs.renameSync(tmp, p);
}

// The state.targets key for a given scope: project scope keys off the
// current project directory (absolute — mirrors bin.js's
// settingsPathForScope()/adopt.sh's own --target default of $PWD, since
// install-profile.json itself carries no per-project target path); user
// scope is always the literal string "user".
function targetKeyForScope(scope) {
  return scope === 'user' ? 'user' : path.resolve(process.cwd());
}

// Derive a fresh target entry from the manifest + cached wizard answers.
// Pure — never reads or writes state.json, never touches install-profile.json.
function deriveTarget(manifest, cachedAnswers) {
  const profile = profileForVault(cachedAnswers);
  const scope = cachedAnswers.scope;
  const items = {};
  for (const item of manifest.items) {
    let enabled = item.profiles.includes(profile) && item.scopes.includes(scope);
    if (item.id === 'handover-wiring') {
      enabled = Boolean(cachedAnswers.handover) && cachedAnswers.handover.mode !== 'none';
    }
    items[item.id] = { enabled, overrides: {} };
  }
  return { profile, scope, items, lastEnsured: null };
}

// Add the derived entry for this target if missing; return the (possibly
// pre-existing) entry either way. Never overwrites an existing entry — a
// target that already has state is left alone (re-deriving/repairing belongs
// to a later reconcile path, not this first-run seam).
function ensureTarget(state, manifest, cachedAnswers) {
  const key = targetKeyForScope(cachedAnswers.scope);
  if (!state.targets[key]) {
    state.targets[key] = deriveTarget(manifest, cachedAnswers);
  }
  return state.targets[key];
}

module.exports = { load, save, deriveTarget, ensureTarget };
