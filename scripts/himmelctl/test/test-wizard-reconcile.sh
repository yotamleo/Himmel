#!/usr/bin/env bash
# test-wizard-reconcile.sh — hermetic tests for
# scripts/himmelctl/lib/state.js's reconcileTarget() (HIMMEL-755 A3): the
# state re-derivation path ensureTarget() deliberately lacks (it never
# re-derives an existing entry). Mirrors sibling test-wizard-state.sh
# conventions: a fake HOME + HIMMELCTL_CACHE_DIR fixture, node launched by
# absolute path, winpath for node.exe's MSYS-path blindness. state.js has no
# shell-out surface, so no HIMMELCTL_REPO_ROOT fixture is needed — the REAL
# scripts/install/manifest.json is read (read-only reference, safe).
#
# Covers:
#   a. a core/project fixture (derived via ensureTarget under profile 'core')
#      reconciled to {profile:'luna', scope:'project'} flips the luna-only
#      items (qmd-binary/qmd-index: profiles ["luna","all"]) enabled
#      false -> true.
#   b. a pre-set override on one item survives the reconcile unchanged.
#   c. handover-wiring keeps tracking cachedAnswers.handover.mode
#      independent of the profile/scope change (both before and after).
#   d. reconcileTarget mutates state in place (no explicit save() call
#      needed to see the change in the same in-memory object) and the
#      result round-trips through save()/load().
#   e. (CR fix, CodeRabbit round 15/16) lastEnsured normalizes a missing/
#      undefined/non-string existing value to null (present in serialized
#      JSON, not dropped) while preserving any genuinely-stored STRING
#      value unchanged.
#   f. (CR fix, CodeRabbit round 22) a malformed `overrides` on an existing
#      item — a truthy NON-object (a string, an array) — normalizes to {} on
#      rebuild instead of persisting through (the SAME bug class as e's
#      lastEnsured; state.js round 17, item 1). Valid-override preservation
#      stays case b's concern; this case covers ONLY the malformed shapes.

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
state_lib="$repo_root/scripts/himmelctl/lib/state.js"
manifest_path="$repo_root/scripts/install/manifest.json"
[ -f "$state_lib" ] || { echo "FAIL: $state_lib not found" >&2; exit 1; }
[ -f "$manifest_path" ] || { echo "FAIL: $manifest_path not found" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }

node_bin=$(command -v node)

work=$(mktemp -d)
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# winpath <path> — echo <path> unchanged on posix, or its Windows form on
# git-bash/MSYS/Cygwin (node.exe misresolves MSYS /tmp-style paths).
winpath() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) cygpath -m "$1" 2>/dev/null || printf '%s' "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}

# CR fix: paths passed via the ENVIRONMENT (STATE_LIB_PATH/MANIFEST_PATH),
# never interpolated into the node -e source string — a checkout path
# containing an apostrophe or backslash would otherwise break the inline JS
# on Windows Git Bash, macOS, or Linux alike.
STATE_LIB_PATH="$(winpath "$state_lib")"
MANIFEST_PATH="$(winpath "$manifest_path")"
export STATE_LIB_PATH MANIFEST_PATH

target_dir="$work/target"; mkdir -p "$target_dir"
home_dir="$work/home"; mkdir -p "$home_dir"
cache_dir="$work/cache"

out=$(cd "$target_dir" && HOME="$home_dir" HIMMELCTL_CACHE_DIR="$(winpath "$cache_dir")" "$node_bin" -e "
const state = require(process.env.STATE_LIB_PATH);
const manifest = JSON.parse(require('fs').readFileSync(process.env.MANIFEST_PATH, 'utf8'));

// core/project fixture: handover.mode='external' so handover-wiring reads
// enabled:true both before and after (case c asserts it stays tracking
// cachedAnswers.handover.mode, not the profile/scope change).
const answers = {
  role: 'adopter', tier: 'standard', scope: 'project',
  vault: { mode: 'none', path: '' },
  handover: { mode: 'external', path: '~/h' },
  pluginSet: 'lean', lanes: [], alwaysOn: false,
};

let s = state.load();
const target = state.ensureTarget(s, manifest, answers);

// sanity: under profile 'core', qmd-binary/qmd-index (profiles:['luna','all'])
// should be disabled before reconcile — fixture-drift guard.
if (target.items['qmd-binary'].enabled !== false) throw new Error('fixture drift: qmd-binary should start disabled under profile core');
if (target.items['handover-wiring'].enabled !== true) throw new Error('fixture drift: handover-wiring should start enabled (handover.mode=external)');

// case b setup: pre-set an override on one item BEFORE reconcile.
target.items['pre-commit-hooks'].overrides = { note: 'pre-set-override' };
state.save(s);

const before = JSON.parse(JSON.stringify(s));

const reconciled = state.reconcileTarget(s, manifest, answers, { profile: 'luna', scope: 'project' });
// CR fix: persist THIS reconcile immediately — case d's round-trip
// assertions below now read back exactly this result, instead of a second,
// redundant reconcile+save performed later in a separate node invocation.
state.save(s);

console.log(JSON.stringify({ before, after: s, reconciled }));
")

# ── case a: luna-only items flip false -> true ──────────────────────────────
echo "$out" | jq -e '.before.targets | to_entries[0].value.items["qmd-binary"].enabled == false' >/dev/null \
  || fail "case a: fixture-drift — qmd-binary should start disabled under profile core (got: $out)"
echo "$out" | jq -e '.reconciled.items["qmd-binary"].enabled == true' >/dev/null \
  || fail "case a: qmd-binary should flip to enabled:true after reconcile to profile luna (got: $out)"
echo "$out" | jq -e '.reconciled.items["qmd-index"].enabled == true' >/dev/null \
  || fail "case a: qmd-index should flip to enabled:true after reconcile to profile luna (got: $out)"
echo "$out" | jq -e '.reconciled.profile == "luna" and .reconciled.scope == "project"' >/dev/null \
  || fail "case a: reconciled entry should carry profile:luna, scope:project (got: $out)"
echo "ok: case a — reconcile to profile 'luna' flips luna-only items enabled:false->true"

# ── case b: a pre-set override survives the reconcile unchanged ────────────
echo "$out" | jq -e '.reconciled.items["pre-commit-hooks"].overrides == {"note":"pre-set-override"}' >/dev/null \
  || fail "case b: pre-commit-hooks override should survive reconcile unchanged (got: $out)"
echo "ok: case b — a pre-set override on one item survives reconcile unchanged"

# ── case c: handover-wiring keeps tracking cachedAnswers.handover.mode ─────
echo "$out" | jq -e '.reconciled.items["handover-wiring"].enabled == true' >/dev/null \
  || fail "case c: handover-wiring should stay enabled:true (handover.mode=external), independent of the profile change (got: $out)"
echo "ok: case c — handover-wiring keeps tracking cachedAnswers.handover.mode across the reconcile"

# ── case d: mutate-in-place + round-trip through save()/load() ─────────────
# CR fix: reads back the SAME reconcile already persisted above (inside the
# first node invocation, right after reconcileTarget()) — no second,
# redundant reconcile+save.
echo "$out" | jq -e '.after.targets | to_entries[0].value.profile == "luna"' >/dev/null \
  || fail "case d: reconcileTarget should mutate the passed state object in place (got: $out)"

statePath="$cache_dir/state.json"
[ -f "$statePath" ] || fail "case d: state.json was not written at $statePath"
loaded=$(cd "$target_dir" && HOME="$home_dir" HIMMELCTL_CACHE_DIR="$(winpath "$cache_dir")" "$node_bin" -e "
const state = require(process.env.STATE_LIB_PATH);
console.log(JSON.stringify(state.load()));
")
echo "$loaded" | jq -e '.targets | to_entries[0].value.profile == "luna"' >/dev/null \
  || fail "case d: reconciled profile should round-trip through save()/load() (got: $loaded)"
echo "$loaded" | jq -e '.targets | to_entries[0].value.items["pre-commit-hooks"].overrides == {"note":"pre-set-override"}' >/dev/null \
  || fail "case d: the preserved override should round-trip through save()/load() (got: $loaded)"
echo "ok: case d — reconcile mutates state in place and round-trips through save()/load()"

# ── case e (CR fix, CodeRabbit round 15, item 4): lastEnsured normalizes to
# null when missing, but is preserved when a real value is stored. The bug:
# `existing ? existing.lastEnsured : null` only guards the "no existing
# entry at all" case — an existing entry that itself lacks the field (a
# state file written before lastEnsured existed, or a malformed one) reads
# back `undefined`, which the ternary carries straight through. An
# `undefined` value is DROPPED by JSON.stringify, so the key vanishes from
# the serialized state entirely, violating the schema's `lastEnsured`
# contract. This test FAILS against the unfixed ternary — verified
# empirically during development (stash/pop the fix, rerun) — because that
# ternary never inspects `existing.lastEnsured` itself, only whether
# `existing` is truthy.
outE=$(cd "$target_dir" && HOME="$home_dir" HIMMELCTL_CACHE_DIR="$(winpath "$cache_dir")" "$node_bin" -e "
const state = require(process.env.STATE_LIB_PATH);
const manifest = JSON.parse(require('fs').readFileSync(process.env.MANIFEST_PATH, 'utf8'));
const answers = {
  role: 'adopter', tier: 'standard', scope: 'project',
  vault: { mode: 'none', path: '' },
  handover: { mode: 'none', path: '' },
  pluginSet: 'lean', lanes: [], alwaysOn: false,
};
let s = state.load();
const target = state.ensureTarget(s, manifest, answers);
const key = Object.keys(s.targets)[0];

// sub-case e1: existing entry missing lastEnsured entirely (simulates a
// pre-field state file, or a malformed one) -- must normalize to null, not
// carry undefined through.
delete s.targets[key].lastEnsured;
const r1 = state.reconcileTarget(s, manifest, answers, { profile: 'core', scope: 'project' });
// CR fix (test bug caught during development): reconcileTarget assigns
// state.targets[key] = entry AND returns that SAME entry object -- so
// r1 and s.targets[key] are aliases of one another. Snapshotting
// r1.lastEnsured into a primitive HERE, before the e2 mutation below
// touches s.targets[key] (== r1) directly, avoids the snapshot silently
// picking up e2's later value.
const r1lastEnsured = r1.lastEnsured;
const roundTripped1 = JSON.parse(JSON.stringify({ targets: s.targets }));
const hasKey1 = Object.prototype.hasOwnProperty.call(roundTripped1.targets[key], 'lastEnsured');

// sub-case e2: existing entry carries a real lastEnsured value -- must
// survive the reconcile unchanged.
s.targets[key].lastEnsured = '2026-01-01T00:00:00.000Z';
const r2 = state.reconcileTarget(s, manifest, answers, { profile: 'luna', scope: 'project' });
// Same aliasing caveat as r1 above -- snapshot NOW, before e3's mutation
// touches s.targets[key] (== r2) directly.
const r2lastEnsured = r2.lastEnsured;

// sub-case e3 (CR fix, CodeRabbit round 16, item 7 -- tighten): a
// MALFORMED state file could carry a non-string lastEnsured (a number, a
// stray object, a boolean) -- the old '!= null' check treated any of
// those as a 'genuine stored value' and passed it straight through,
// violating the schema's timestamp-string-or-null contract just as surely
// as undefined did. Must normalize to null too.
s.targets[key].lastEnsured = 12345;
const r3 = state.reconcileTarget(s, manifest, answers, { profile: 'core', scope: 'project' });

console.log(JSON.stringify({ r1lastEnsured, hasKey1, r2lastEnsured, r3lastEnsured: r3.lastEnsured }));
")
echo "$outE" | jq -e '.r1lastEnsured == null' >/dev/null \
  || fail "case e: a reconciled entry whose existing lastEnsured was missing entirely should normalize to null (got: $outE)"
echo "$outE" | jq -e '.hasKey1 == true' >/dev/null \
  || fail "case e: lastEnsured:null must round-trip through JSON.stringify as a PRESENT key, not be dropped as undefined would be (got: $outE)"
echo "$outE" | jq -e '.r2lastEnsured == "2026-01-01T00:00:00.000Z"' >/dev/null \
  || fail "case e: a genuinely-stored lastEnsured value must survive reconcile unchanged (got: $outE)"
echo "$outE" | jq -e '.r3lastEnsured == null' >/dev/null \
  || fail "case e: a non-string stored lastEnsured (e.g. a number) must normalize to null, not pass through (got: $outE)"
echo "ok: case e — lastEnsured normalizes missing/undefined/non-string to null (present in serialized JSON) while preserving any real stored string value"

# ── case f (CR fix, CodeRabbit round 22): a malformed `overrides` on an
# existing item — a truthy NON-object (a string, an array) — must normalize
# to a genuine plain object {} on rebuild, not persist through. This is the
# SAME bug class as case e's lastEnsured normalization: state.js round 17,
# item 1 narrowed `|| {}` (which only caught FALSY overrides) to a real
# typeof-object && !Array.isArray check, because a malformed truthy
# non-object used to pass straight through reconcileTarget into the rebuilt
# entry, violating the schema's `overrides` object contract. The valid
# override on pre-commit-hooks survives unchanged (case b) — this case
# covers ONLY the malformed shapes. ──────────────────────────────────────
outF=$(cd "$target_dir" && HOME="$home_dir" HIMMELCTL_CACHE_DIR="$(winpath "$cache_dir")" "$node_bin" -e "
const state = require(process.env.STATE_LIB_PATH);
const manifest = JSON.parse(require('fs').readFileSync(process.env.MANIFEST_PATH, 'utf8'));
const answers = {
  role: 'adopter', tier: 'standard', scope: 'project',
  vault: { mode: 'none', path: '' },
  handover: { mode: 'none', path: '' },
  pluginSet: 'lean', lanes: [], alwaysOn: false,
};
let s = state.load();
const target = state.ensureTarget(s, manifest, answers);
const key = Object.keys(s.targets)[0];

// sub-case f1: a STRING overrides (truthy, non-object) must normalize to {}.
// Same aliasing caveat as case e — reconcileTarget assigns state.targets[key]
// = entry AND returns that SAME object, so snapshot the reconciled overrides
// into a plain value HERE, before f2's mutation touches s.targets[key]
// (== r1) directly.
s.targets[key].items['pre-commit-hooks'].overrides = 'malformed-string';
const r1 = state.reconcileTarget(s, manifest, answers, { profile: 'core', scope: 'project' });
const r1Overrides = JSON.parse(JSON.stringify(r1.items['pre-commit-hooks'].overrides));

// sub-case f2: an ARRAY overrides (typeof 'object' but Array.isArray) must
// normalize to {} too — the round-17 guard explicitly excludes arrays.
s.targets[key].items['pre-commit-hooks'].overrides = ['malformed', 'array'];
const r2 = state.reconcileTarget(s, manifest, answers, { profile: 'luna', scope: 'project' });
const r2Overrides = JSON.parse(JSON.stringify(r2.items['pre-commit-hooks'].overrides));

console.log(JSON.stringify({ r1Overrides, r2Overrides }));
")
echo "$outF" | jq -e '.r1Overrides == {}' >/dev/null \
  || fail "case f: a STRING overrides must normalize to {} on rebuild (got: $outF)"
echo "$outF" | jq -e '.r2Overrides == {}' >/dev/null \
  || fail "case f: an ARRAY overrides must normalize to {} on rebuild (got: $outF)"
echo "ok: case f — a malformed (string/array) overrides normalizes to {} instead of persisting through the rebuild"

echo "PASS"
