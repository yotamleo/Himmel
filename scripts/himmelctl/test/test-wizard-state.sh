#!/usr/bin/env bash
# test-wizard-state.sh — hermetic tests for scripts/himmelctl/lib/state.js
# (HIMMEL-756 T1.3): target-keyed install state derived from the manifest +
# the wizard's cached install-profile answers. Mirrors sibling test-wizard-*
# suites: a fake HOME + HIMMELCTL_CACHE_DIR so nothing touches the real
# ~/.claude/himmel/, node launched by absolute path, winpath for node.exe's
# MSYS-path blindness. state.js has no shell-out surface (pure fs read/write
# against HIMMELCTL_CACHE_DIR), so no HIMMELCTL_REPO_ROOT fixture is needed —
# the REAL scripts/install/manifest.json is read (read-only reference, safe).
#
# Covers:
#   A. deriveTarget() — role=adopter, vault.mode=default-template (profile
#      "all"), scope=project: the golden-six manifest items (all∈profiles,
#      project∈scopes) are enabled:true; handover-wiring tracks
#      handover.mode (external -> true, none -> false) independent of
#      manifest membership.
#   B. ensureTarget() — one project target + one "user" target coexist in
#      the same state object with no key collision.
#   C. save()/load() round-trip byte-stably across two saves.

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

state_lib_w="$(winpath "$state_lib")"
manifest_w="$(winpath "$manifest_path")"

# ── Case A: deriveTarget() — golden-six + handover-wiring exception ────────
caseA_dir="$work/caseA-target"; mkdir -p "$caseA_dir"
homeA="$work/homeA"; mkdir -p "$homeA"
cacheA="$work/cacheA"

out=$(cd "$caseA_dir" && HOME="$homeA" HIMMELCTL_CACHE_DIR="$(winpath "$cacheA")" "$node_bin" -e "
const state = require('$state_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const answers = {
  role: 'adopter', tier: 'standard', scope: 'project',
  vault: { mode: 'default-template', path: '~/vault' },
  handover: { mode: 'external', path: '~/h' },
  pluginSet: 'lean', lanes: [], alwaysOn: false,
};
console.log(JSON.stringify(state.deriveTarget(manifest, answers)));
")

echo "$out" | jq -e '.profile == "all"' >/dev/null || fail "caseA: profile should be 'all' (got: $out)"
echo "$out" | jq -e '.scope == "project"' >/dev/null || fail "caseA: scope should be 'project' (got: $out)"
for id in pre-commit-hooks wiring-pretooluse wiring-statusline jira-cli-dist-build bitbucket-cli-build guardrail-scope; do
  echo "$out" | jq -e --arg id "$id" '.items[$id].enabled == true' >/dev/null \
    || fail "caseA: golden item '$id' should be enabled:true (got: $out)"
done
echo "$out" | jq -e '.items["handover-wiring"].enabled == true' >/dev/null \
  || fail "caseA: handover-wiring should be enabled:true when handover.mode=external (got: $out)"
echo "ok: caseA golden-six items + handover-wiring(external) all enabled:true"

outNone=$(cd "$caseA_dir" && HOME="$homeA" HIMMELCTL_CACHE_DIR="$(winpath "$cacheA")" "$node_bin" -e "
const state = require('$state_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const answers = {
  role: 'adopter', tier: 'standard', scope: 'project',
  vault: { mode: 'default-template', path: '~/vault' },
  handover: { mode: 'none', path: '' },
  pluginSet: 'lean', lanes: [], alwaysOn: false,
};
console.log(JSON.stringify(state.deriveTarget(manifest, answers)));
")
echo "$outNone" | jq -e '.items["handover-wiring"].enabled == false' >/dev/null \
  || fail "caseA: handover-wiring should be enabled:false when handover.mode=none (got: $outNone)"
echo "ok: caseA handover-wiring(none) -> disabled"

# ── Case B: ensureTarget() — project + user targets coexist, no collision ──
caseB_dir="$work/caseB-project"; mkdir -p "$caseB_dir"
homeB="$work/homeB"; mkdir -p "$homeB"
cacheB="$work/cacheB"

outB=$(cd "$caseB_dir" && HOME="$homeB" HIMMELCTL_CACHE_DIR="$(winpath "$cacheB")" "$node_bin" -e "
const state = require('$state_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const projectAnswers = { role:'adopter', tier:'standard', scope:'project', vault:{mode:'none',path:''}, handover:{mode:'inline',path:''}, pluginSet:'lean', lanes:[], alwaysOn:false };
const userAnswers = { role:'adopter', tier:'standard', scope:'user', vault:{mode:'none',path:''}, handover:{mode:'inline',path:''}, pluginSet:'lean', lanes:[], alwaysOn:false };
let s = state.load();
state.ensureTarget(s, manifest, projectAnswers);
state.ensureTarget(s, manifest, userAnswers);
state.save(s);
console.log(JSON.stringify(s));
")

keysCount=$(echo "$outB" | jq '.targets | keys | length')
[ "$keysCount" -eq 2 ] || fail "caseB: expected exactly 2 target keys (got $keysCount): $outB"
echo "$outB" | jq -e '.targets["user"]' >/dev/null || fail "caseB: missing the literal 'user' target key (got: $outB)"
echo "$outB" | jq -e '.targets["user"].scope == "user"' >/dev/null \
  || fail "caseB: 'user' target entry should have scope 'user' (got: $outB)"
echo "$outB" | jq -e '[.targets | to_entries[] | select(.key != "user")][0].value.scope == "project"' >/dev/null \
  || fail "caseB: the non-'user' target entry should have scope 'project' (got: $outB)"
echo "ok: caseB project + 'user' targets coexist in one state object, no key collision"

# ── Case C: save()/load() round-trip byte-stably across two saves ──────────
caseC_dir="$work/caseC-target"; mkdir -p "$caseC_dir"
homeC="$work/homeC"; mkdir -p "$homeC"
cacheC="$work/cacheC"

(cd "$caseC_dir" && HOME="$homeC" HIMMELCTL_CACHE_DIR="$(winpath "$cacheC")" "$node_bin" -e "
const state = require('$state_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const answers = { role:'adopter', tier:'standard', scope:'project', vault:{mode:'none',path:''}, handover:{mode:'inline',path:''}, pluginSet:'lean', lanes:[], alwaysOn:false };
let s = state.load();
state.ensureTarget(s, manifest, answers);
state.save(s);
")
statePathC="$cacheC/state.json"
[ -f "$statePathC" ] || fail "caseC: state.json was not written at $statePathC"
cp "$statePathC" "$work/state-save1.json"

(cd "$caseC_dir" && HOME="$homeC" HIMMELCTL_CACHE_DIR="$(winpath "$cacheC")" "$node_bin" -e "
const state = require('$state_lib_w');
let s = state.load();
state.save(s);
")
cmp -s "$work/state-save1.json" "$statePathC" \
  || fail "caseC: state.json should round-trip byte-identically across two saves"
echo "ok: caseC write->read round-trips byte-stably across two saves"

# ── Case D (HIMMEL-1017): ensureTarget() migrates a PRE-CHANGE existing
# target — it backfills manifest items the target's persisted `items` map
# doesn't yet carry (simulating a manifest that gained items after this
# target was first derived, e.g. an install predating this repo's most
# recent `himmel-update`), leaving every already-tracked item's enabled flag
# and overrides byte-for-byte untouched. ─────────────────────────────────────
caseD_dir="$work/caseD-target"; mkdir -p "$caseD_dir"
homeD="$work/homeD"; mkdir -p "$homeD"
cacheD="$work/cacheD"

outD=$(cd "$caseD_dir" && HOME="$homeD" HIMMELCTL_CACHE_DIR="$(winpath "$cacheD")" "$node_bin" -e "
const state = require('$state_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const answers = {
  role: 'adopter', tier: 'standard', scope: 'project',
  vault: { mode: 'default-template', path: '~/vault' },
  handover: { mode: 'external', path: '~/h' },
  pluginSet: 'lean', lanes: [], alwaysOn: false,
};

// Simulate a PRE-CHANGE state.json: derive against an OLDER manifest missing
// two real items (one that should end up enabled:true under this target's
// profile/scope — 'qmd-binary' — and one that should end up enabled:false —
// 'pre-commit-hooks', scope:['project'] only under profiles core/all, and
// this target's profile is 'all' from vault.mode default-template — wait,
// pre-commit-hooks IS profiles:['core','all'] so it WOULD be true; pick a
// genuinely-false one instead: a user-scope-only item under a project-scope
// target reads false regardless of profile).
const oldManifest = { schemaVersion: manifest.schemaVersion, harness: manifest.harness,
  items: manifest.items.filter((i) => i.id !== 'qmd-binary' && i.id !== 'graphify') };
if (oldManifest.items.length === manifest.items.length) throw new Error('fixture drift: expected the real manifest to still carry qmd-binary + graphify');

let s = state.load();
const preChange = state.ensureTarget(s, oldManifest, answers);
if (preChange.items['qmd-binary']) throw new Error('fixture drift: qmd-binary should be ABSENT from the pre-change derive');
if (preChange.items['graphify']) throw new Error('fixture drift: graphify should be ABSENT from the pre-change derive');
// Hand-set an override + a non-default enabled flag on an item that DOES
// survive the migration untouched — proves migration never re-derives
// already-tracked items.
preChange.items['pre-commit-hooks'].overrides = { note: 'pre-change-override' };
preChange.items['pre-commit-hooks'].enabled = false; // deliberately wrong vs. a fresh derive, to prove it survives verbatim
state.save(s);

const before = JSON.parse(JSON.stringify(s));

// Now ensureTarget against the CURRENT (full) manifest — the 'upgrade'.
const migrated = state.ensureTarget(s, manifest, answers);
state.save(s);

console.log(JSON.stringify({ before, after: s, migrated }));
")

echo "$outD" | jq -e '.migrated.items["qmd-binary"].enabled == true' >/dev/null \
  || fail "caseD: migrated qmd-binary should be backfilled enabled:true under profile 'all' (got: $outD)"
echo "ok: caseD — qmd-binary backfilled enabled:true"

# graphify is scope:["user"] only; this target is scope 'project', so its
# backfilled membership check (scopes.includes('project')) reads false —
# asserted explicitly so the migration's per-item rule (not just presence) is
# exercised in both directions.
echo "$outD" | jq -e '.migrated.items["graphify"].enabled == false' >/dev/null \
  || fail "caseD: migrated graphify (scope:user-only) should backfill enabled:false under a project-scope target (got: $outD)"
echo "ok: caseD — ensureTarget backfills missing manifest items (qmd-binary:true, graphify:false) into an existing target"

echo "$outD" | jq -e '.migrated.items["pre-commit-hooks"].enabled == false and .migrated.items["pre-commit-hooks"].overrides == {"note":"pre-change-override"}' >/dev/null \
  || fail "caseD: an already-tracked item (pre-commit-hooks) must survive migration byte-for-byte unchanged (got: $outD)"
echo "ok: caseD — an already-tracked item's enabled flag + overrides survive migration untouched"

migratedCount=$(echo "$outD" | jq '.migrated.items | keys | length')
manifestCount=$(jq '.items | length' "$manifest_path")
[ "$migratedCount" -eq "$manifestCount" ] || fail "caseD: migrated target should carry ALL $manifestCount manifest item ids (got $migratedCount)"
echo "ok: caseD — migrated target carries every manifest item id"

echo "$outD" | jq -e '.after.targets | to_entries[0].value.items["qmd-binary"].enabled == true' >/dev/null \
  || fail "caseD: the migration should round-trip through save() (got: $outD)"
echo "ok: caseD — migration round-trips through save()/load()"

# ── Case E (HIMMEL-1017 CR round): migration membership must key off the
# AUTHORITATIVE invocation scope (cachedAnswers.scope — the same value that
# picked which target entry we're even operating on), NEVER the target's own
# PERSISTED `.scope` field, which can independently drift (a hand-edit, a
# pre-schema-fix state file — the same class of defect `lastEnsured`/
# `overrides` already guard against). Repro: a project-scope target whose
# persisted `.scope` somehow reads "user" gains a project-ONLY item after an
# upgrade — the item must still backfill enabled:true (project scope really
# is desired here), not enabled:false (what a naive read of the stale
# persisted scope would produce, forever, since the item-exists guard skips
# it on every later run once wrongly backfilled). ─────────────────────────
caseE_dir="$work/caseE-target"; mkdir -p "$caseE_dir"
homeE="$work/homeE"; mkdir -p "$homeE"
cacheE="$work/cacheE"

outE=$(cd "$caseE_dir" && HOME="$homeE" HIMMELCTL_CACHE_DIR="$(winpath "$cacheE")" "$node_bin" -e "
const state = require('$state_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const answers = {
  role: 'adopter', tier: 'standard', scope: 'project',
  vault: { mode: 'none', path: '' },
  handover: { mode: 'none', path: '' },
  pluginSet: 'lean', lanes: [], alwaysOn: false,
};

// PRE-CHANGE state: derive against a manifest missing pre-commit-hooks
// (scopes:['project'], profiles:['core','all'] — desired under THIS
// target's real profile 'core' + authoritative scope 'project').
const oldManifest = { schemaVersion: manifest.schemaVersion, harness: manifest.harness,
  items: manifest.items.filter((i) => i.id !== 'pre-commit-hooks') };
if (oldManifest.items.length === manifest.items.length) throw new Error('fixture drift: expected the real manifest to still carry pre-commit-hooks');

let s = state.load();
const key = state.ensureTarget(s, oldManifest, answers) && Object.keys(s.targets)[0];
if (s.targets[key].items['pre-commit-hooks']) throw new Error('fixture drift: pre-commit-hooks should be ABSENT from the pre-change derive');
if (s.targets[key].scope !== 'project') throw new Error('fixture drift: freshly-derived scope should be project before corruption');

// Corrupt the PERSISTED .scope field only — cachedAnswers.scope (what
// ensureTarget uses to pick this very target key) stays 'project'
// throughout; only the target's own redundant copy drifts.
s.targets[key].scope = 'user';
state.save(s);

// The 'upgrade': ensureTarget against the CURRENT (full) manifest.
const migrated = state.ensureTarget(s, manifest, answers);
state.save(s);

console.log(JSON.stringify({ migrated }));
")

echo "$outE" | jq -e '.migrated.items["pre-commit-hooks"].enabled == true' >/dev/null \
  || fail "caseE: a project-only item backfilled under a target with a STALE persisted scope:'user' must still key off the AUTHORITATIVE invocation scope 'project' (got: $outE)"
echo "ok: caseE — migration membership uses the authoritative invocation scope, never a stale persisted target.scope"

echo "PASS"
