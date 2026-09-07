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
//         profile, scope, items: { <id>: { enabled, overrides } }, lastEnsured,
//         profileSource?: "explicit"
//       }
//   } }
// `profileSource` (HIMMEL-2349): PROVENANCE for `profile`/the `enabled`
// flags, not a value — absent means derived (ensureTarget's first-run
// derive, or migrateTargetItems' backfill); "explicit" means an operator
// ran reconcileTarget() (an explicit --profile, or a scope switch). See
// reconcileTarget()'s own comment for why this must be recorded rather than
// inferred from the profile value.
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

// Pure membership predicate (HIMMEL-2349): does `item` belong to
// `profile`+`scope`, per the manifest's own declared membership — with the
// ONE handover-wiring exception (membership alone can't see whether
// handover was actually wired, so that one item tracks
// cachedAnswers.handover.mode !== 'none' directly instead). Extracted out of
// deriveTarget/migrateTargetItems/reconcileTarget, which used to each carry
// their own copy of this exact formula — this is the ONE place it lives now;
// every caller below (and status-report.js's read-only additive overlay,
// HIMMEL-2349) calls this instead of re-inlining it.
function itemMembership(item, profile, scope, cachedAnswers) {
  if (item.id === 'handover-wiring') {
    return Boolean(cachedAnswers.handover) && cachedAnswers.handover.mode !== 'none';
  }
  return item.profiles.includes(profile) && item.scopes.includes(scope);
}

// Derive a fresh target entry from the manifest + cached wizard answers.
// Pure — never reads or writes state.json, never touches install-profile.json.
function deriveTarget(manifest, cachedAnswers) {
  const profile = profileForVault(cachedAnswers);
  const scope = cachedAnswers.scope;
  const items = {};
  for (const item of manifest.items) {
    const enabled = itemMembership(item, profile, scope, cachedAnswers);
    items[item.id] = { enabled, overrides: {} };
  }
  return { profile, scope, items, lastEnsured: null };
}

// Does `entry` carry a deliberate, recorded per-item decision? `overrides` is
// a bag of item-specific consent/decision flags (today the ONLY populated
// one is guardrail-block-global's `overrides.consent` — see cmdEnsure's
// ask-first gate in bin.js) — established from that ONE concrete usage: a
// non-empty overrides object means an operator's explicit choice was
// recorded for this item, and nothing automatic (additive re-derivation
// included) may silently second-guess it. An empty/absent overrides object
// carries no such choice.
function hasDeliberateOverride(entry) {
  return Boolean(entry && entry.overrides && typeof entry.overrides === 'object'
    && !Array.isArray(entry.overrides) && Object.keys(entry.overrides).length > 0);
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
    const enabled = itemMembership(item, target.profile, scope, cachedAnswers);
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
//
// HIMMEL-2349 (codex-1, Critical): stamps `profileSource: 'explicit'` on the
// entry — PROVENANCE, not value. Both call sites (bin.js's cmdEnsure Step 0,
// only reached when --profile was explicitly supplied; cmdScopeSet) are
// genuine operator decisions, unlike deriveTarget()/migrateTargetItems(),
// which leave this field absent (a target that has only ever been derived,
// never reconciled). additiveReconcile()/recordedDesired() below check this
// to skip a target the operator has explicitly reconciled — without it, an
// explicit downgrade (`ensure --profile core --prune`) couldn't survive the
// very next ordinary `ensure`: the additive overlay would see the recorded
// install-profile still covers the disabled items and silently turn them
// back on, reinstalling wiring the operator deliberately removed. Whether a
// target's category is "core because stale-derived" or "core because the
// operator asked for core" cannot be told from the VALUE alone — only from
// how it got there — so it must be recorded, not inferred.
function reconcileTarget(state, manifest, cachedAnswers, { profile, scope }) {
  const key = targetKeyForScope(scope);
  const existing = state.targets[key];
  const items = {};
  for (const item of manifest.items) {
    const enabled = itemMembership(item, profile, scope, cachedAnswers);
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
  const entry = { profile, scope, items, lastEnsured, profileSource: 'explicit' };
  state.targets[key] = entry;
  return entry;
}

// HIMMEL-2349 — additive-only desired-state overlay. Whether the CURRENTLY
// recorded install-profile (cachedAnswers, loaded fresh every status/ensure
// run — see helpers.js's cacheDir()/bin.js's loadProfile()) would enable
// `item` under a fresh membership check, for use ONLY as an OR on top of an
// already-persisted `entry.enabled` — never as a replacement (that
// destructive recompute is reconcileTarget()'s job, and only ever runs on an
// explicit --profile). This is the root-cause fix: an entry's `enabled`
// flag is derived ONCE (ensureTarget's first-run derive, or an explicit
// reconcile) and never revisited after — so a target stamped against a
// stale/thin cachedAnswers (e.g. before the operator's vault was set up)
// stays wrong forever even after the recorded profile is richer today.
// Skips any item carrying a deliberate override (hasDeliberateOverride
// above) — an explicit recorded decision must never be silently
// second-guessed by additive re-derivation. Pure: no fs I/O, no mutation.
// HIMMEL-2349 (retask 01S-A-2349-b73d): the manifest CATEGORY (core|luna|
// all) the additive overlay checks membership against — resolved from the
// RECORDED schema-v2 `profile` field (starter|luna|operator|custom), not
// from profileForVault(vault.mode). profileForVault only ever returns
// 'core' or 'all' — it treats `vault.mode:'existing'` (an operator pointing
// the wizard at a vault they ALREADY have) the same as `'none'` (no vault at
// all), so an operator with a real, working luna vault reads category
// 'core' and every luna-category item then reads "not enabled for this
// target (profile/scope)" — the operator's own incident, exactly. Schema v2
// records `profile` precisely to express which surface the operator runs;
// this is that field finally reaching desired-state computation instead of
// being re-derived from vault.mode. Manifest fact verified directly against
// scripts/install/manifest.json (48 items): every membership set is one of
// ["all","core"] (34), ["all","luna"] (11), or ["all","core","luna"] (3) —
// so `core ∪ luna == all` and 'all' is the correct superset for either
// luna-surface profile ('luna' alone would drop the 34 core-only items).
//   starter  -> core (the lean, no-luna-surface default)
//   luna     -> all  (this operator DOES run the luna surface)
//   operator -> all  (ditto — richest defaults, HIMMEL-2308's ROLE_PRESETS)
//   custom, missing, or unrecognised -> profileForVault(cachedAnswers)
//     (current, unchanged behaviour — a v1 record with no `profile` field
//     included, or a value this mapping doesn't yet know, falls back rather
//     than guessing). isStampedLunaVault() (bin.js) was considered as an
//     alternative/fallback signal for that last case — it's a live fs probe
//     against the actual vault path, and state.js is deliberately probe-free
//     (see this file's own header) — but is unused: the declarative
//     `profile` field already covers operator/luna/starter without any fs
//     read, and a v1 record's existing profileForVault() fallback is exactly
//     what the retask asked to leave unchanged.
function recordedProfileCategory(cachedAnswers) {
  const profile = cachedAnswers.profile;
  if (profile === 'starter') return 'core';
  if (profile === 'luna' || profile === 'operator') return 'all';
  return profileForVault(cachedAnswers);
}

// HIMMEL-2349 (codex-1): does `target` carry an explicit reconcile stamp
// (reconcileTarget()'s own comment)? One level up from
// hasDeliberateOverride() above — that one is a per-ITEM deliberate
// decision; this is the same posture for the whole TARGET. A target the
// operator has explicitly reconciled must never be silently re-derived by
// the additive overlay, exactly as an item's own override never is.
function hasExplicitProfile(target) {
  return Boolean(target && target.profileSource === 'explicit');
}

function recordedDesired(target, entry, item, cachedAnswers) {
  if (hasDeliberateOverride(entry)) return false;
  if (hasExplicitProfile(target)) return false;
  const profile = recordedProfileCategory(cachedAnswers);
  return itemMembership(item, profile, cachedAnswers.scope, cachedAnswers);
}

// The state-MUTATING counterpart of recordedDesired(), for `ensure` (the one
// verb allowed to persist): flips entry.enabled from false to true for every
// manifest item the CURRENTLY recorded cachedAnswers would enable — additive
// ONLY, exactly like migrateTargetItems() above (an already-enabled item, or
// one carrying an override, is left completely untouched; this NEVER turns
// an item off, unlike reconcileTarget()). Mutates `target.items` in place;
// returns { changed, added } so the caller can decide whether to persist and
// what to tell the operator (Fix A's "surface the reconcile in output"
// requirement — an operator must be able to SEE their recorded profile
// changed the answer, not merely observe the answer change). HIMMEL-2349
// (codex-1, Critical): a no-op entirely on a target carrying
// profileSource:'explicit' — recordedDesired() enforces this per item, so
// this is stated for the whole function's benefit, not a separate check.
// Without it, an explicit `ensure --profile core --prune` downgrade could
// not survive the very next ordinary `ensure`: this overlay would see the
// recorded install-profile still covers the just-disabled items and
// silently re-enable them, reinstalling wiring the operator deliberately
// removed — the bin.js caller ALSO skips calling this at all when the
// CURRENT run itself passes --profile (its own reconcile runs moments
// later and is authoritative, so this overlay's work would be discarded
// anyway).
function additiveReconcile(target, manifest, cachedAnswers) {
  let changed = false;
  const added = [];
  for (const item of manifest.items) {
    const entry = target.items[item.id];
    if (!entry || entry.enabled) continue;
    if (recordedDesired(target, entry, item, cachedAnswers)) {
      entry.enabled = true;
      changed = true;
      added.push(item.id);
    }
  }
  return { changed, added };
}

module.exports = {
  load, save, deriveTarget, ensureTarget, reconcileTarget, migrateTargetItems,
  itemMembership, hasDeliberateOverride, recordedDesired, additiveReconcile,
};
