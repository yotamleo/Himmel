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

// Backfill any manifest item IDs an existing target entry doesn't yet carry
// (HIMMEL-1017): ensureTarget's derive-if-missing path only ever runs ONCE,
// on a target's first-ever encounter — a manifest item added to
// scripts/install/manifest.json AFTER that point never gets an `items` entry
// on an already-existing target, so it reads `entry === undefined` in
// statusReport (desired:false, "not enabled for this target") forever, on
// every future run, until the target is deleted and re-derived from scratch.
// This is the missing state-schema migration: for each manifest item the
// target's `items` map doesn't yet carry, derive its `enabled` flag with the
// SAME pure membership rule deriveTarget() uses (the handover-wiring
// exception included). Every item already present in `target.items` is left
// completely untouched — enabled flags, overrides, all of it. Mutates
// `target.items` in place; returns true if anything was added, so a caller
// can decide whether the mutation needs persisting.
//
// CR fix (HIMMEL-1017 CR round): scope membership is checked against
// cachedAnswers.scope — the AUTHORITATIVE invocation scope (the exact value
// ensureTarget() used to compute the target's own key) — never
// `target.scope`. `target.scope` is a persisted, independently-editable
// copy of that same fact (same class of drift risk as `lastEnsured`/
// `overrides` above, or `target.scope` vs the invocation scope in
// cmdEnsure's own Step 0 comment on reconcileTarget): a state.json entry
// keyed under a project path but whose persisted `.scope` field somehow read
// "user" (hand-edit, schema drift) used to backfill every project-only new
// item disabled — and, once backfilled, `ensureTarget`'s own
// `if (target.items[item.id]) continue` guard means that wrong value is
// never revisited on a later run. `target.profile`, in contrast, genuinely
// CAN diverge intentionally from a fresh derive (an explicit `ensure
// --profile` reconcile) — that one is still read from the persisted target,
// matching this function's "existing item state is never second-guessed"
// contract.
function migrateTargetItems(target, manifest, cachedAnswers) {
  const scope = cachedAnswers.scope;
  let changed = false;
  for (const item of manifest.items) {
    if (target.items[item.id]) continue;
    let enabled = item.profiles.includes(target.profile) && item.scopes.includes(scope);
    if (item.id === 'handover-wiring') {
      enabled = Boolean(cachedAnswers.handover) && cachedAnswers.handover.mode !== 'none';
    }
    target.items[item.id] = { enabled, overrides: {} };
    changed = true;
  }
  return changed;
}

// Add the derived entry for this target if missing; return the (possibly
// pre-existing) entry either way. An existing entry is never re-derived —
// its profile/scope and every already-tracked item's enabled/overrides are
// left alone (re-deriving/repairing those belongs to reconcileTarget(), not
// this first-run seam) — but it IS migrated: any manifest item ID missing
// from its `items` map gets backfilled via migrateTargetItems() above, so an
// existing target never silently loses visibility into a newly-added
// manifest item.
function ensureTarget(state, manifest, cachedAnswers) {
  const key = targetKeyForScope(cachedAnswers.scope);
  if (!state.targets[key]) {
    state.targets[key] = deriveTarget(manifest, cachedAnswers);
  } else {
    migrateTargetItems(state.targets[key], manifest, cachedAnswers);
  }
  return state.targets[key];
}

// The re-derivation path ensureTarget() deliberately lacks (its own module
// header): recompute an existing (or not-yet-persisted) target's
// profile/scope + every item's `enabled` flag against a REQUESTED
// {profile, scope} pair — the SAME pure membership rule deriveTarget() uses
// (item.profiles.includes(profile) && item.scopes.includes(scope)), with the
// same handover-wiring exception, driven off cachedAnswers.handover.mode
// (independent of the requested profile/scope — an item can be "wired" or
// not regardless of which profile a target converges to). Each item's
// existing `overrides` are read as-is and written back UNCHANGED — reconcile
// only ever touches `enabled`, never overrides. Mutates `state` in place;
// the caller is responsible for state.save(). Returns the reconciled entry.
function reconcileTarget(state, manifest, cachedAnswers, { profile, scope }) {
  const key = targetKeyForScope(scope);
  const existing = state.targets[key];
  const items = {};
  for (const item of manifest.items) {
    let enabled = item.profiles.includes(profile) && item.scopes.includes(scope);
    if (item.id === 'handover-wiring') {
      enabled = Boolean(cachedAnswers.handover) && cachedAnswers.handover.mode !== 'none';
    }
    const existingItem = existing && existing.items && existing.items[item.id];
    // CR fix (CodeRabbit round 17, item 1): `|| {}` only catches FALSY
    // overrides — a malformed state file carrying a truthy non-object
    // (a string, an array, a number) passed straight through and got
    // persisted back into the rebuilt entry, violating the schema's
    // `overrides` object contract. Exactly the `lastEnsured` bug class
    // fixed below (round 15/16), applied unevenly: normalize to a genuine
    // plain object, preserving any valid override mapping untouched.
    const rawOverrides = existingItem && existingItem.overrides;
    const overrides = (rawOverrides && typeof rawOverrides === 'object' && !Array.isArray(rawOverrides))
      ? rawOverrides
      : {};
    items[item.id] = { enabled, overrides };
  }
  // CR fix (CodeRabbit round 15, item 4): `existing.lastEnsured` can itself
  // be `undefined` (an existing entry predating this field, or a malformed
  // state file) — carrying that through verbatim serializes as a MISSING
  // key, violating the schema's `lastEnsured` contract. Normalize to `null`
  // whenever it isn't a genuine stored value, while still preserving any
  // valid stored value untouched.
  //
  // CR fix (CodeRabbit round 16, item 7 — tighten): "genuine stored value"
  // is narrowed from "anything non-null" to "a string" specifically — the
  // schema's `lastEnsured` field is a timestamp string (or null), so a
  // malformed state file carrying a number/object/boolean through would
  // otherwise pass the old `!= null` check and violate the schema just as
  // surely as `undefined` did.
  const lastEnsured = (existing && typeof existing.lastEnsured === 'string') ? existing.lastEnsured : null;
  const entry = { profile, scope, items, lastEnsured };
  state.targets[key] = entry;
  return entry;
}

module.exports = { load, save, deriveTarget, ensureTarget, reconcileTarget, migrateTargetItems };
