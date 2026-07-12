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

echo "PASS"
