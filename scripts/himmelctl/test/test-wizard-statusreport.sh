#!/usr/bin/env bash
# test-wizard-statusreport.sh — hermetic tests for the extracted
# scripts/himmelctl/lib/status-report.js statusReport() library (HIMMEL-755
# A2). Complements test-wizard-status-cmd/golden/multitarget.sh (which cover
# the CLI `status` command end-to-end through bin.js) by exercising the
# library directly via `node -e` + require — no bin.js invocation. Mirrors
# sibling test-wizard-*.sh conventions: a fake HOME + HIMMELCTL_CACHE_DIR/
# HIMMELCTL_REPO_ROOT fixture, node launched by absolute path, winpath for
# node.exe's MSYS-path blindness.
#
# Covers:
#   a. statusReport returns the shipped JSON shape ({schemaVersion, target,
#      items:[{id,kind,desired,actual,severity,detail}], summary}) for a
#      minimal 2-item fixture manifest (one desired+red, one not-desired),
#      with no persisted state.json for the target (proves the in-memory
#      deriveTarget() fallback path — no state.json write happens either).
#   b. parameterization: calling statusReport with an EXPLICIT
#      {scope:"user", targetPath} that differs from process.cwd() routes a
#      handover-dir-type probe's spawned-shell cwd to THAT targetPath (a
#      marker-file resolver stub proves it — two calls with two different
#      targetPath values read back two different marker contents), proving
#      the library never falls back to cwd/repoRoot on its own.
#   c. (CR fix) the uncached-derive fallback honors the EXPLICIT `scope`
#      argument, not `answers.scope`: calling statusReport with scope:"user"
#      while `answers.scope` is "project" (deliberately mismatched, no
#      persisted state) still reads a scope:["user"]-only item as
#      desired:true — proving deriveTarget() was driven off the caller's
#      scope, not silently off the stale answers object.
#   d. (CR fix, CodeRabbit round 22) a caller-provided UNSAVED reconciled
#      `state` whose desired flags DIFFER from disk: statusReport reports
#      the PASSED values (not the on-disk ones) and writes NO state.json.
#      Protects the `ensure --profile X --dry-run` preview path, which
#      passes an in-memory reconcile here without persisting it first — a
#      regression that made statusReport ignore `state` and re-load() would
#      silently read stale on-disk desired flags (the preview would lie).
#   e. (HIMMEL-1093, CR round 2) doc-guard-map's opt-in n/a downgrade fires
#      ONLY on a genuinely clean probe absence (marker sourced fine, just not
#      present) — a broken probe (resolver fails to source, probe.actual
#      'degraded') must read severity degraded end-to-end, never get
#      silently swallowed into the same friendly opt-in n/a message.
#   h. (HIMMEL-2176 CR fix, codex-4; extended for Stage-1 PR-C's S6) a
#      malformed ~/.himmel/config.json must surface at severity (degraded),
#      naming the config file, for ALL THREE config-desired-override items
#      (cadence-armed, bridge-health, bridge-persistence) — not vanish as a
#      silent "not enabled for this target" n/a row — while every OTHER item
#      in the same sweep still renders its normal probe result.
#   i. (HIMMEL-2176 Stage-1 PR-C, status item S6) bridge-persistence's own
#      cleanAbsence downgrade, exercised end-to-end through the REAL probe:
#      bridge.enabled:false reads n/a (opt-in hint), never red; bridge.
#      enabled:true with persistence missing stays severity degraded (a
#      warn) — proving the downgrade fires only on the red/absent branch,
#      never on an already-degraded probe result.
#   k. (HIMMEL-2349 CR fix) the recordedDesired() additive overlay (the
#      !passedState branch covered by case d's gating) must ALSO honor the
#      EXPLICIT `scope` argument, not `answers.scope` — the same rule case c
#      already pins for the deriveTarget() fallback. A scope:["user"]-only
#      item, answers.scope:"user" (mismatched) but called with the explicit
#      scope:"project" and no `state`, must read desired:false: evaluating
#      membership against answers.scope would wrongly enable it.

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
. "$repo_root/scripts/himmelctl/test/_hermetic-home.sh"  # HIMMEL-2350: shared winpath() -- dies loud on empty input/output instead of silently falling through to the operator's real home
status_report_lib="$repo_root/scripts/himmelctl/lib/status-report.js"
[ -f "$status_report_lib" ] || { echo "FAIL: $status_report_lib not found" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }

node_bin=$(command -v node)

# shellcheck source=lib/hermetic-path.sh
# shellcheck disable=SC1091
. "$repo_root/scripts/lib/hermetic-path.sh"

work=$(mktemp -d)
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# CR fix: every fixture path used inside a node -e script is passed via the
# ENVIRONMENT (exported once, read via process.env inside the script) rather
# than interpolated into the JS source string — a checkout path containing
# an apostrophe or backslash would otherwise break the inline JS on Windows
# Git Bash, macOS, or Linux alike.
STATUS_REPORT_LIB="$(winpath "$status_report_lib")"
export STATUS_REPORT_LIB

# CR fix (CodeRabbit round 22): case d passes a caller-built state to
# statusReport, so it also requires state.js directly (to persist the on-disk
# baseline + build the unsaved reconciled preview). state.js is a peer of
# status-report.js; if status-report.js is present, state.js is too.
state_lib="$repo_root/scripts/himmelctl/lib/state.js"
STATE_LIB_PATH="$(winpath "$state_lib")"
export STATE_LIB_PATH

# ── case a: shipped shape + no-persisted-state fallback ────────────────────
caseA_dir="$work/caseA-target"; mkdir -p "$caseA_dir"
homeA="$work/homeA"; mkdir -p "$homeA"
cacheA="$work/cacheA"; mkdir -p "$cacheA"

manifestA="$work/manifestA.json"
cat > "$manifestA" <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    {
      "id": "fixture-red",
      "kind": "hook",
      "scopes": ["project"],
      "profiles": ["core", "all"],
      "deps": [],
      "probe": { "type": "file-exists", "path": "missing.txt" }
    },
    {
      "id": "fixture-na",
      "kind": "hook",
      "scopes": ["project"],
      "profiles": ["luna"],
      "deps": [],
      "probe": { "type": "file-exists", "path": "also-missing.txt" }
    }
  ]
}
JSON
MANIFEST_A_PATH="$(winpath "$manifestA")"
export MANIFEST_A_PATH

outA=$(cd "$caseA_dir" && HOME="$homeA" USERPROFILE="$(winpath "$homeA")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheA")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cacheA")-luna-config.json" "$node_bin" -e "
const { statusReport } = require(process.env.STATUS_REPORT_LIB);
const manifest = JSON.parse(require('fs').readFileSync(process.env.MANIFEST_A_PATH, 'utf8'));
const answers = {
  role: 'adopter', tier: 'standard', scope: 'project',
  vault: { mode: 'none', path: '' },
  handover: { mode: 'none', path: '' },
  pluginSet: 'lean', lanes: [], alwaysOn: false,
};
const report = statusReport({ manifest, scope: 'project', targetPath: process.cwd(), answers });
console.log(JSON.stringify(report));
")

echo "$outA" | jq -e '.schemaVersion == 1' >/dev/null || fail "case a: schemaVersion should be 1 (got: $outA)"
echo "$outA" | jq -e '.target | type == "string"' >/dev/null || fail "case a: target should be a string (got: $outA)"
echo "$outA" | jq -e '.items | length == 2' >/dev/null || fail "case a: expected exactly 2 items (got: $outA)"
echo "$outA" | jq -e '.items[] | select(.id=="fixture-red") | .desired == true and .actual == "absent" and .severity == "red"' >/dev/null \
  || fail "case a: fixture-red should be desired:true, actual:absent, severity:red (got: $outA)"
echo "$outA" | jq -e '.items[] | select(.id=="fixture-na") | .desired == false and .actual == null and .severity == "n/a"' >/dev/null \
  || fail "case a: fixture-na should be desired:false, actual:null, severity:n/a (got: $outA)"
echo "$outA" | jq -e '.summary.red == 1 and .summary.na == 1 and .summary.degraded == 0 and .summary.green == 0' >/dev/null \
  || fail "case a: summary should be {red:1,na:1,degraded:0,green:0} (got: $(echo "$outA" | jq -c '.summary'))"
[ ! -f "$cacheA/state.json" ] || fail "case a: statusReport must never write state.json (no ensureTarget/save call)"
echo "ok: case a — statusReport returns the shipped shape; no persisted state -> in-memory deriveTarget fallback, zero writes"

# ── case b: parameterization — explicit {scope:user, targetPath} differing
# from cwd routes a handover-dir probe's spawned cwd to targetPath ─────────
fixtureRepoB="$work/repoB"
mkdir -p "$fixtureRepoB/scripts/lib"
cat > "$fixtureRepoB/scripts/lib/marker-resolver.sh" <<'SH'
handover_root() {
  if [ -f "./MARKER" ]; then cat ./MARKER; else echo "no-marker"; fi
}
SH
fixtureRepoB_w="$(winpath "$fixtureRepoB")"

manifestB="$work/manifestB.json"
cat > "$manifestB" <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    {
      "id": "custom-handover-probe",
      "kind": "wiring",
      "scopes": ["user"],
      "profiles": ["core", "all"],
      "deps": [],
      "probe": { "type": "handover-dir", "resolver": "scripts/lib/marker-resolver.sh" }
    }
  ]
}
JSON
MANIFEST_B_PATH="$(winpath "$manifestB")"
export MANIFEST_B_PATH

targetDirX="$work/target-x"; mkdir -p "$targetDirX"
printf 'marker-X' > "$targetDirX/MARKER"
targetDirY="$work/target-y"; mkdir -p "$targetDirY"
printf 'marker-Y' > "$targetDirY/MARKER"

homeB="$work/homeB"; mkdir -p "$homeB"
cacheB="$work/cacheB"; mkdir -p "$cacheB"

run_case_b() {
  local targetDir="$1"
  TARGET_PATH="$(winpath "$targetDir")" \
    HOME="$homeB" USERPROFILE="$(winpath "$homeB")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheB")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cacheB")-luna-config.json" HIMMELCTL_REPO_ROOT="$fixtureRepoB_w" "$node_bin" -e "
const { statusReport } = require(process.env.STATUS_REPORT_LIB);
const manifest = JSON.parse(require('fs').readFileSync(process.env.MANIFEST_B_PATH, 'utf8'));
const answers = {
  role: 'adopter', tier: 'standard', scope: 'user',
  vault: { mode: 'none', path: '' },
  handover: { mode: 'inline', path: '' },
  pluginSet: 'lean', lanes: [], alwaysOn: false,
};
const report = statusReport({ manifest, scope: 'user', targetPath: process.env.TARGET_PATH, answers });
console.log(JSON.stringify(report));
"
}

outX=$(run_case_b "$targetDirX")
outY=$(run_case_b "$targetDirY")

echo "$outX" | jq -e '.items[0].desired == true' >/dev/null || fail "case b: custom-handover-probe should be desired:true under profile 'core' (got: $outX)"
detailX=$(echo "$outX" | jq -r '.items[0].detail')
detailY=$(echo "$outY" | jq -r '.items[0].detail')
[ "$detailX" = "marker-X" ] || fail "case b: statusReport with targetPath=$targetDirX should read marker-X (got: $detailX): $outX"
[ "$detailY" = "marker-Y" ] || fail "case b: statusReport with targetPath=$targetDirY should read marker-Y (got: $detailY): $outY"
[ "$detailX" != "$detailY" ] || fail "case b: the two targetPath values should route the probe to different cwds (got identical detail: $detailX)"
echo "ok: case b — an explicit {scope:user, targetPath} differing from cwd routes the probe to that targetPath, proving parameterization"

# ── case c (CR fix): the uncached-derive fallback honors the EXPLICIT
# `scope` argument, not the (deliberately mismatched) `answers.scope` ──────
caseC_dir="$work/caseC-target"; mkdir -p "$caseC_dir"
homeC="$work/homeC"; mkdir -p "$homeC"
cacheC="$work/cacheC"; mkdir -p "$cacheC"

manifestC="$work/manifestC.json"
cat > "$manifestC" <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    {
      "id": "user-only-item",
      "kind": "hook",
      "scopes": ["user"],
      "profiles": ["core", "all"],
      "deps": [],
      "probe": { "type": "file-exists", "path": "missing.txt" }
    }
  ]
}
JSON
MANIFEST_C_PATH="$(winpath "$manifestC")"
export MANIFEST_C_PATH

outC=$(cd "$caseC_dir" && HOME="$homeC" USERPROFILE="$(winpath "$homeC")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheC")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cacheC")-luna-config.json" "$node_bin" -e "
const { statusReport } = require(process.env.STATUS_REPORT_LIB);
const manifest = JSON.parse(require('fs').readFileSync(process.env.MANIFEST_C_PATH, 'utf8'));
// answers.scope is 'project' — deliberately MISMATCHED with the explicit
// scope:'user' argument below. No persisted state.json exists for this
// target, so this exercises the uncached deriveTarget() fallback.
const answers = {
  role: 'adopter', tier: 'standard', scope: 'project',
  vault: { mode: 'none', path: '' },
  handover: { mode: 'none', path: '' },
  pluginSet: 'lean', lanes: [], alwaysOn: false,
};
const report = statusReport({ manifest, scope: 'user', targetPath: process.cwd(), answers });
console.log(JSON.stringify(report));
")
[ ! -f "$cacheC/state.json" ] || fail "case c: no persisted state should exist yet (this is the uncached-fallback path)"
echo "$outC" | jq -e '.items[0].desired == true' >/dev/null \
  || fail "case c: user-only-item (scopes:[user]) should read desired:true under the EXPLICIT scope:user, ignoring answers.scope='project' (got: $outC)"
echo "$outC" | jq -e '.items[0].severity == "red"' >/dev/null \
  || fail "case c: user-only-item should then be probed (severity:red, missing.txt absent) — proving it wasn't silently skipped as not-desired (got: $outC)"
echo "ok: case c — the uncached-derive fallback honors the explicit scope argument, not answers.scope"

# ── case d (CR fix, CodeRabbit round 22): a caller-provided UNSAVED reconciled
# `state` whose desired flags DIFFER from disk. statusReport must report the
# PASSED values (not the on-disk ones) AND write NO state.json — the contract
# `ensure --profile X --dry-run` relies on to preview an in-memory reconcile
# without persisting it first. The on-disk baseline is persisted HERE (drift-
# item ENABLED) only to give the passed preview something to differ FROM; the
# passed preview flips drift-item to DISABLED (unsaved). A regression that
# made statusReport ignore `state` and re-load() would report desired:true
# (the on-disk value) and the assertion below would catch it. ──────────────
caseD_dir="$work/caseD-target"; mkdir -p "$caseD_dir"
homeD="$work/homeD"; mkdir -p "$homeD"
cacheD="$work/cacheD"; mkdir -p "$cacheD"

manifestD="$work/manifestD.json"
cat > "$manifestD" <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    {
      "id": "drift-item",
      "kind": "hook",
      "scopes": ["project"],
      "profiles": ["core", "all"],
      "deps": [],
      "probe": { "type": "file-exists", "path": "missing.txt" }
    }
  ]
}
JSON
MANIFEST_D_PATH="$(winpath "$manifestD")"
export MANIFEST_D_PATH

outD=$(cd "$caseD_dir" && HOME="$homeD" USERPROFILE="$(winpath "$homeD")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheD")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cacheD")-luna-config.json" "$node_bin" -e "
const { statusReport } = require(process.env.STATUS_REPORT_LIB);
const stateLib = require(process.env.STATE_LIB_PATH);
const path = require('path');
const manifest = JSON.parse(require('fs').readFileSync(process.env.MANIFEST_D_PATH, 'utf8'));
const answers = {
  role: 'adopter', tier: 'standard', scope: 'project',
  vault: { mode: 'none', path: '' },
  handover: { mode: 'none', path: '' },
  pluginSet: 'lean', lanes: [], alwaysOn: false,
};

// Phase 1: persist the on-disk baseline — drift-item ENABLED (project/core).
// This is the 'disk' the passed preview deliberately differs from.
let disk = stateLib.load();
stateLib.ensureTarget(disk, manifest, answers);
stateLib.save(disk);

// Phase 2: build an UNSAVED reconciled preview — drift-item DISABLED. Loaded
// fresh from the just-written disk baseline (enabled:true) then flipped in
// memory ONLY (no save) — exactly the shape 'ensure --dry-run' hands over.
let preview = stateLib.load();
const key = path.resolve(process.cwd());
preview.targets[key].items['drift-item'].enabled = false;

// Snapshot the on-disk state (serialized) BEFORE the statusReport call, so
// the no-write assertion below compares like-for-like across the call.
const before = JSON.stringify(stateLib.load());

// Phase 3: statusReport with the caller-provided UNSAVED preview.
const report = statusReport({ manifest, scope: 'project', targetPath: process.cwd(), answers, state: preview });

// Re-read the disk AFTER and confirm it is byte-identical (statusReport wrote
// nothing) AND still carries the baseline (drift-item enabled:true), proving
// the preview was NOT persisted back.
const after = JSON.stringify(stateLib.load());
console.log(JSON.stringify({
  desired: report.items[0].desired,
  diskStillEnabled: stateLib.load().targets[key].items['drift-item'].enabled === true,
  stateUnchanged: before === after,
}));
")
echo "$outD" | jq -e '.desired == false' >/dev/null \
  || fail "case d: statusReport must report the PASSED (unsaved reconciled) desired:false, NOT the on-disk true (got: $outD)"
echo "$outD" | jq -e '.diskStillEnabled == true' >/dev/null \
  || fail "case d: the on-disk state must be UNCHANGED (drift-item still enabled:true) — statusReport must not persist the passed preview (got: $outD)"
echo "$outD" | jq -e '.stateUnchanged == true' >/dev/null \
  || fail "case d: statusReport must perform NO state.json write — the persisted baseline must stay byte-identical across the call (got: $outD)"
echo "ok: case d — statusReport honors a caller-provided UNSAVED reconciled state (reports its desired, not the on-disk one) and writes NO state.json"

# ── case e (HIMMEL-1093, CR round 2): doc-guard-map's opt-in n/a downgrade
# fires ONLY on a genuinely clean absence (marker not present, sourced fine),
# never on a broken probe. probes.js's cmd:is_himmel_dev now distinguishes
# "resolver failed to source" (degraded) from "sourced fine, marker absent"
# (absent) — this proves status-report.js's item.id==='doc-guard-map' branch
# only reaches the friendly-opt-in override for the latter. The CR's own
# glm-3/glm-4 findings (claiming 'degraded' also gets swallowed to n/a) were
# adjudicated DISPROVED by code inspection (statusReport's degraded branch is
# a separate `else if` that never falls into the red/n/a-override block) —
# this end-to-end case pins that as regression protection, not just the
# probes.js-level unit coverage in test-wizard-probes.sh. ─────────────────
caseE_dir="$work/caseE-target"; mkdir -p "$caseE_dir"
homeE="$work/homeE"; mkdir -p "$homeE"
cacheE="$work/cacheE"; mkdir -p "$cacheE"

manifestE="$work/manifestE.json"
cat > "$manifestE" <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    {
      "id": "doc-guard-map",
      "kind": "wiring",
      "scopes": ["project"],
      "profiles": ["core", "all"],
      "deps": [],
      "probe": { "type": "cmd:is_himmel_dev", "resolver": "scripts/guardrails/lib.sh" }
    }
  ]
}
JSON
MANIFEST_E_PATH="$(winpath "$manifestE")"
export MANIFEST_E_PATH

answersE() {
  cat <<'JS'
const answers = {
  role: 'adopter', tier: 'standard', scope: 'project',
  vault: { mode: 'none', path: '' },
  handover: { mode: 'none', path: '' },
  pluginSet: 'lean', lanes: [], alwaysOn: false,
};
JS
}

# ── e1: marker genuinely absent (sourced fine, rc 1) -> n/a, opt-in detail ──
fixtureRepoE1="$work/repoE1"; mkdir -p "$fixtureRepoE1/scripts/guardrails"
cat > "$fixtureRepoE1/scripts/guardrails/lib.sh" <<'SH'
is_himmel_dev_repo() { return 1; }
SH
fixtureRepoE1_w="$(winpath "$fixtureRepoE1")"
cacheE1="$work/cacheE1"; mkdir -p "$cacheE1"

outE1=$(cd "$caseE_dir" && HOME="$homeE" USERPROFILE="$(winpath "$homeE")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheE1")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cacheE1")-luna-config.json" HIMMELCTL_REPO_ROOT="$fixtureRepoE1_w" "$node_bin" -e "
const { statusReport } = require(process.env.STATUS_REPORT_LIB);
const manifest = JSON.parse(require('fs').readFileSync(process.env.MANIFEST_E_PATH, 'utf8'));
$(answersE)
const report = statusReport({ manifest, scope: 'project', targetPath: process.cwd(), answers });
console.log(JSON.stringify(report));
")
echo "$outE1" | jq -e '.items[0].actual == "absent"' >/dev/null \
  || fail "case e1: doc-guard-map probe.actual should be absent (marker genuinely absent) (got: $outE1)"
echo "$outE1" | jq -e '.items[0].severity == "n/a"' >/dev/null \
  || fail "case e1: doc-guard-map clean absence should downgrade to n/a, not red (got: $outE1)"
echo "$outE1" | jq -e '.items[0].detail | test("opt-in"; "i")' >/dev/null \
  || fail "case e1: doc-guard-map n/a detail should name it as opt-in (got: $outE1)"
echo "$outE1" | jq -e '.summary.red == 0' >/dev/null \
  || fail "case e1: doc-guard-map clean absence must not count toward summary.red (got: $outE1)"
echo "ok: case e1 — doc-guard-map with a genuinely absent marker (resolver sourced fine) downgrades to n/a"

# ── e2: resolver missing (probe wiring broken, rc 3) -> degraded, NEVER n/a ──
fixtureRepoE2="$work/repoE2"; mkdir -p "$fixtureRepoE2/scripts/guardrails"
# Deliberately NO scripts/guardrails/lib.sh — `.` fails to source it.
fixtureRepoE2_w="$(winpath "$fixtureRepoE2")"
cacheE2="$work/cacheE2"; mkdir -p "$cacheE2"

outE2=$(cd "$caseE_dir" && HOME="$homeE" USERPROFILE="$(winpath "$homeE")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheE2")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cacheE2")-luna-config.json" HIMMELCTL_REPO_ROOT="$fixtureRepoE2_w" "$node_bin" -e "
const { statusReport } = require(process.env.STATUS_REPORT_LIB);
const manifest = JSON.parse(require('fs').readFileSync(process.env.MANIFEST_E_PATH, 'utf8'));
$(answersE)
const report = statusReport({ manifest, scope: 'project', targetPath: process.cwd(), answers });
console.log(JSON.stringify(report));
")
echo "$outE2" | jq -e '.items[0].actual == "degraded"' >/dev/null \
  || fail "case e2: doc-guard-map probe.actual should be degraded (resolver failed to source) (got: $outE2)"
echo "$outE2" | jq -e '.items[0].severity == "degraded"' >/dev/null \
  || fail "case e2: doc-guard-map with a broken resolver must read severity degraded, NEVER n/a — proves status-report's opt-in override never reaches the degraded branch (got: $outE2)"
echo "$outE2" | jq -e '.items[0].detail | test("opt-in"; "i") | not' >/dev/null \
  || fail "case e2: a broken probe must NOT read the friendly opt-in message (got: $outE2)"
echo "$outE2" | jq -e '.summary.degraded == 1 and .summary.na == 0' >/dev/null \
  || fail "case e2: a broken doc-guard-map probe must count toward summary.degraded, not summary.na (got: $outE2)"
echo "ok: case e2 — doc-guard-map with a broken resolver (probe wiring failure) reads degraded, never silently swallowed to n/a"

# ── case f (HIMMEL-2176 Task 7a): the config-store desired-state bridge —
# an item's desired-state can ALSO come from ~/.himmel/config.json
# (luna.cadence.enabled), ADDITIVE to (never instead of) the state.json-
# derived signal. Three sub-cases: desired purely from the new config
# (state.json/deriveTarget alone would say false), desired purely from
# state.json (no config document at all — the pre-existing, unaffected
# path), and both absent (desired stays false, severity n/a). Uses a
# fixture manifest item literally named 'cadence-armed' — status-report.js's
# configDesiredOverride() dispatches on that exact id. ────────────────────
manifestF="$work/manifestF.json"
cat > "$manifestF" <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    {
      "id": "cadence-armed",
      "kind": "scheduler",
      "scopes": ["project"],
      "profiles": ["all"],
      "deps": [],
      "probe": { "type": "file-exists", "path": "missing.txt" }
    }
  ]
}
JSON
MANIFEST_F_PATH="$(winpath "$manifestF")"
export MANIFEST_F_PATH

run_case_f() {
  local homeDir="$1" cacheDir="$2" cfgPath="$3" vaultMode="$4"
  mkdir -p "$homeDir" "$cacheDir"
  local caseFDir="$homeDir-target"; mkdir -p "$caseFDir"
  ( cd "$caseFDir" && HOME="$homeDir" USERPROFILE="$(winpath "$homeDir")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheDir")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cfgPath")" "$node_bin" -e "
const { statusReport } = require(process.env.STATUS_REPORT_LIB);
const manifest = JSON.parse(require('fs').readFileSync(process.env.MANIFEST_F_PATH, 'utf8'));
// scope:'project' + vault.mode:'$vaultMode' derives profile 'core' (vault
// mode 'none') or 'all' (vault mode 'default-template' — helpers.js's
// profileForVault()); the fixture item is profiles:[all] only, so a 'core'
// profile deliberately does NOT grant it via membership alone — isolating
// the config-store override as the ONLY possible source of desired:true
// whenever vaultMode is 'none'.
const answers = {
  role: 'adopter', tier: 'standard', scope: 'project',
  vault: { mode: '$vaultMode', path: '' },
  handover: { mode: 'none', path: '' },
  pluginSet: 'lean', lanes: [], alwaysOn: false,
};
const report = statusReport({ manifest, scope: 'project', targetPath: process.cwd(), answers });
console.log(JSON.stringify(report));
" )
}

# f1: desired purely from the NEW config — profile 'core' (vault.mode:'none')
# would otherwise read desired:false for a luna-only item; luna.cadence.enabled
# in config.json alone must flip it to true.
homeF1="$work/homeF1"; cacheF1="$work/cacheF1"
cfgF1="$work/configF1.json"
cat > "$cfgF1" <<'JSON'
{"version":1,"luna":{"vaultPath":"/x","cadence":{"enabled":true,"schedules":{"fetchHealth":{"time":"01:30"},"harvest":{"time":"02:00"},"synthesize":{"time":"03:00"},"health":{"time":"04:00","day":"SUN"}},"models":{"harvest":"sonnet","synthesize":"sonnet","health":"haiku"}},"phi":{"declared":false}},"bridge":{"enabled":false,"envPath":"~/x/.env","whisper":{"cli":null,"model":"ggml-small.bin"}}}
JSON
outF1=$(run_case_f "$homeF1" "$cacheF1" "$cfgF1" "none")
echo "$outF1" | jq -e '.items[0].desired == true' >/dev/null \
  || fail "case f1: luna.cadence.enabled=true in config.json alone should flip desired:true even though profile membership says false (got: $outF1)"
echo "$outF1" | jq -e '.items[0].severity == "red"' >/dev/null \
  || fail "case f1: once desired via the config override, the item is genuinely probed (missing.txt absent -> red), not skipped (got: $outF1)"
echo "ok: case f1 — desired-state from the NEW config alone (state.json/profile membership would say false)"

# f2: desired purely from state.json/profile membership — NO config document
# at all (luna-config.js's load() falls back to defaultConfig(),
# cadence.enabled:false) — the pre-existing path, unaffected by 7a.
homeF2="$work/homeF2"; cacheF2="$work/cacheF2"
cfgF2Missing="$work/configF2-never-created.json"
outF2=$(run_case_f "$homeF2" "$cacheF2" "$cfgF2Missing" "default-template")
echo "$outF2" | jq -e '.items[0].desired == true' >/dev/null \
  || fail "case f2: profile 'all' (vault.mode:default-template) membership alone should read desired:true with no config document at all (got: $outF2)"
echo "ok: case f2 — desired-state from state.json/profile membership alone (no config document present)"

# f3: both absent — profile 'core' (no membership) AND no config document
# (defaultConfig(), cadence.enabled:false) — desired stays false, severity n/a.
homeF3="$work/homeF3"; cacheF3="$work/cacheF3"
cfgF3Missing="$work/configF3-never-created.json"
outF3=$(run_case_f "$homeF3" "$cacheF3" "$cfgF3Missing" "none")
echo "$outF3" | jq -e '.items[0].desired == false and .items[0].severity == "n/a"' >/dev/null \
  || fail "case f3: neither profile membership nor the config override should read desired:false, severity n/a (got: $outF3)"
echo "ok: case f3 — desired-state absent from BOTH sources reads desired:false, severity n/a"

# ── case g (HIMMEL-2176 Task 7, status item S2): luna-sources' severity
# remap. The underlying probe (Task 6, UNCHANGED) returns 'absent' for
# "nothing was evaluated" and 'degraded' for "a configured source is
# unhealthy" — status-report.js remaps these to severity degraded (warn) and
# red (fail) respectively for this ONE item id, the inverse of the generic
# mapping every other item uses. ──────────────────────────────────────────
manifestG="$work/manifestG.json"
cat > "$manifestG" <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    {
      "id": "luna-sources",
      "kind": "vault",
      "scopes": ["project"],
      "profiles": ["core", "all"],
      "deps": [],
      "probe": { "type": "luna-sources", "script": "does-not-exist.py", "sources": [] }
    }
  ]
}
JSON
MANIFEST_G_PATH="$(winpath "$manifestG")"
export MANIFEST_G_PATH
caseG_dir="$work/caseG-target"; mkdir -p "$caseG_dir"
homeG="$work/homeG"; mkdir -p "$homeG"
cacheG="$work/cacheG"; mkdir -p "$cacheG"
outG=$(cd "$caseG_dir" && HOME="$homeG" USERPROFILE="$(winpath "$homeG")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheG")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cacheG")-luna-config.json" "$node_bin" -e "
const { statusReport } = require(process.env.STATUS_REPORT_LIB);
const manifest = JSON.parse(require('fs').readFileSync(process.env.MANIFEST_G_PATH, 'utf8'));
const answers = {
  role: 'adopter', tier: 'standard', scope: 'project',
  vault: { mode: 'none', path: '' },
  handover: { mode: 'none', path: '' },
  pluginSet: 'lean', lanes: [], alwaysOn: false,
};
const report = statusReport({ manifest, scope: 'project', targetPath: process.cwd(), answers });
console.log(JSON.stringify(report));
")
echo "$outG" | jq -e '.items[0].actual == "absent" and .items[0].severity == "degraded"' >/dev/null \
  || fail "case g: luna-sources with an empty sources list (probe.actual absent = 'nothing evaluated') should read severity degraded (warn, not a wall of red) (got: $outG)"
echo "ok: case g — luna-sources' 'nothing configured' (probe.actual absent) reads severity degraded (warn), not red"

# ── case h (HIMMEL-2176 CR fix, codex-4): a malformed ~/.himmel/config.json
# must surface at severity, naming the file, for the two config-desired-
# override items — not be silently swallowed into a plain "not enabled" n/a
# row — while every OTHER item in the same sweep still renders normally. ──
manifestH="$work/manifestH.json"
cat > "$manifestH" <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    {
      "id": "cadence-armed",
      "kind": "scheduler",
      "scopes": ["project"],
      "profiles": ["luna", "all"],
      "deps": [],
      "probe": { "type": "file-exists", "path": "missing.txt" }
    },
    {
      "id": "bridge-health",
      "kind": "lane",
      "scopes": ["project"],
      "profiles": ["core", "all"],
      "deps": [],
      "probe": { "type": "file-exists", "path": "missing.txt" }
    },
    {
      "id": "bridge-persistence",
      "kind": "lane",
      "scopes": ["project"],
      "profiles": ["core", "all"],
      "deps": [],
      "probe": { "type": "file-exists", "path": "missing.txt" }
    },
    {
      "id": "fixture-control",
      "kind": "hook",
      "scopes": ["project"],
      "profiles": ["core", "all"],
      "deps": [],
      "probe": { "type": "file-exists", "path": "missing.txt" }
    }
  ]
}
JSON
MANIFEST_H_PATH="$(winpath "$manifestH")"
export MANIFEST_H_PATH

caseH_dir="$work/caseH-target"; mkdir -p "$caseH_dir"
homeH="$work/homeH"; mkdir -p "$homeH"
cacheH="$work/cacheH"; mkdir -p "$cacheH"
cfgH="$work/configH.json"
printf '{not valid json' > "$cfgH"
cfgH_w="$(winpath "$cfgH")"

outH=$(cd "$caseH_dir" && HOME="$homeH" USERPROFILE="$(winpath "$homeH")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheH")" HIMMEL_LUNA_CONFIG_PATH="$cfgH_w" "$node_bin" -e "
const { statusReport } = require(process.env.STATUS_REPORT_LIB);
const manifest = JSON.parse(require('fs').readFileSync(process.env.MANIFEST_H_PATH, 'utf8'));
const answers = {
  role: 'adopter', tier: 'standard', scope: 'project',
  vault: { mode: 'default-template', path: '' },
  handover: { mode: 'none', path: '' },
  pluginSet: 'lean', lanes: [], alwaysOn: false,
};
const report = statusReport({ manifest, scope: 'project', targetPath: process.cwd(), answers });
console.log(JSON.stringify(report));
")
echo "$outH" | jq --arg cfg "$cfgH_w" -e \
  '.items[] | select(.id=="cadence-armed") | .desired == true and .severity == "degraded" and (.detail | contains($cfg))' >/dev/null \
  || fail "case h: cadence-armed with a malformed config.json should surface severity degraded, naming the config file (got: $outH)"
echo "$outH" | jq --arg cfg "$cfgH_w" -e \
  '.items[] | select(.id=="bridge-health") | .desired == true and .severity == "degraded" and (.detail | contains($cfg))' >/dev/null \
  || fail "case h: bridge-health with a malformed config.json should surface severity degraded, naming the config file (got: $outH)"
echo "$outH" | jq --arg cfg "$cfgH_w" -e \
  '.items[] | select(.id=="bridge-persistence") | .desired == true and .severity == "degraded" and (.detail | contains($cfg))' >/dev/null \
  || fail "case h: bridge-persistence (HIMMEL-2176 Stage-1 PR-C, S6) with a malformed config.json should ALSO surface severity degraded, naming the config file — it joined CONFIG_OVERRIDE_ITEM_IDS alongside cadence-armed/bridge-health (got: $outH)"
echo "$outH" | jq -e '.items[] | select(.id=="fixture-control") | .severity == "red"' >/dev/null \
  || fail "case h: every OTHER item must still render its normal probe result despite the malformed config (got: $outH)"
echo "$outH" | jq -e '.summary.degraded == 3 and .summary.red == 1' >/dev/null \
  || fail "case h: summary should count the three config-error rows as degraded and the control item as red (got: $(echo "$outH" | jq -c '.summary'))"
echo "ok: case h — a malformed config.json surfaces at severity for all three config-desired-override items, naming the file, without swallowing the rest of the report"

# ── case i (HIMMEL-2176 Stage-1 PR-C, status item S6): bridge-persistence's
# OWN cleanAbsence downgrade — bridge.enabled:false must render n/a (opt-in
# hint), never red; bridge.enabled:true with persistence missing must stay
# 'degraded' (a warn), proving the downgrade only ever fires on the red
# branch (probe.actual:'absent'), never on 'degraded'. Runs the REAL
# bridge-persistence probe end-to-end (statusReport -> probes.js), not a
# file-exists fixture — ctxForItem() threads no `platform`, so this exercises
# the actual host platform's branch; a stubbed `pwsh` on PATH covers the
# win32 case this test host runs under (probes.js queries Get-ScheduledTask
# via helpers.js's resolvePowershell(), which PREFERS pwsh over powershell,
# as of retask stage1-build-6d2e round 12 — a hardcoded 'powershell' binary
# name would never resolve on a PowerShell-7-only machine; round 7 already
# moved this off schtasks' locale-dependent text output). ─────────────────
manifestI="$work/manifestI.json"
cat > "$manifestI" <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    {
      "id": "bridge-persistence",
      "kind": "lane",
      "scopes": ["project"],
      "profiles": ["core", "all"],
      "deps": [],
      "probe": { "type": "bridge-persistence" }
    }
  ]
}
JSON
MANIFEST_I_PATH="$(winpath "$manifestI")"
export MANIFEST_I_PATH

caseI_dir="$work/caseI-target"; mkdir -p "$caseI_dir"
homeI="$work/homeI"; mkdir -p "$homeI"
cacheI="$work/cacheI"; mkdir -p "$cacheI"

cfgIdisabled="$work/configI-disabled.json"
cat > "$cfgIdisabled" <<'JSON'
{"version":1,"luna":{"vaultPath":"/x","cadence":{"enabled":false,"schedules":{"fetchHealth":{"time":"01:30"},"harvest":{"time":"02:00"},"synthesize":{"time":"03:00"},"health":{"time":"04:00","day":"SUN"}},"models":{"harvest":"sonnet","synthesize":"sonnet","health":"haiku"}},"phi":{"declared":false}},"bridge":{"enabled":false,"envPath":"~/x/.env","whisper":{"cli":null,"model":"ggml-small.bin"}}}
JSON
cfgIenabled="$work/configI-enabled.json"
cat > "$cfgIenabled" <<'JSON'
{"version":1,"luna":{"vaultPath":"/x","cadence":{"enabled":false,"schedules":{"fetchHealth":{"time":"01:30"},"harvest":{"time":"02:00"},"synthesize":{"time":"03:00"},"health":{"time":"04:00","day":"SUN"}},"models":{"harvest":"sonnet","synthesize":"sonnet","health":"haiku"}},"phi":{"declared":false}},"bridge":{"enabled":true,"envPath":"~/x/.env","whisper":{"cli":null,"model":"ggml-small.bin"}}}
JSON

run_case_i() {
  local cfgPath="$1"; shift
  ( cd "$caseI_dir" && HOME="$homeI" USERPROFILE="$(winpath "$homeI")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheI")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cfgPath")" "$@" "$node_bin" -e "
const { statusReport } = require(process.env.STATUS_REPORT_LIB);
const manifest = JSON.parse(require('fs').readFileSync(process.env.MANIFEST_I_PATH, 'utf8'));
const answers = {
  role: 'adopter', tier: 'standard', scope: 'project',
  vault: { mode: 'default-template', path: '' },
  handover: { mode: 'none', path: '' },
  pluginSet: 'lean', lanes: [], alwaysOn: false,
};
const report = statusReport({ manifest, scope: 'project', targetPath: process.cwd(), answers });
console.log(JSON.stringify(report));
" )
}

# i1: bridge.enabled:false -> n/a, opt-in hint, never red.
outI1=$(run_case_i "$cfgIdisabled")
echo "$outI1" | jq -e '.items[0].desired == true and .items[0].actual == "absent" and .items[0].severity == "n/a"' >/dev/null \
  || fail "case i1: bridge-persistence with bridge.enabled=false should read severity n/a (cleanAbsence), never red (got: $outI1)"
echo "$outI1" | jq -e '.items[0].detail | test("opt-in"; "i")' >/dev/null \
  || fail "case i1: bridge-persistence n/a detail should name it as opt-in (got: $outI1)"
echo "$outI1" | jq -e '.summary.red == 0 and .summary.na == 1' >/dev/null \
  || fail "case i1: bridge-persistence clean absence must not count toward summary.red (got: $(echo "$outI1" | jq -c '.summary'))"
echo "ok: case i1 — bridge-persistence with bridge.enabled=false reads n/a (opt-in), never red"

# i2: bridge.enabled:true, Windows scheduler reports the task NOT registered
# -> stays 'degraded' (a warn), proving the n/a downgrade never fires here.
i2_stub="$work/i2-stub"; mkdir -p "$i2_stub"
cat > "$i2_stub/pwsh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$i2_stub/pwsh"
# CR fix (codex-2, retask stage1-build-6d2e round 12): resolvePowershell()
# PREFERS pwsh over powershell — scrubbing only 'powershell' off the REAL
# PATH left a real pwsh.exe (present on this test host) resolvable, so the
# probe queried the REAL Windows Task Scheduler instead of this stub
# (caught here: it returned an actual 'HimmelTelegramBridge' task on the
# operator's own machine). Both names must be scrubbed off the real PATH.
i2_path="$i2_stub:$(scrub_path "$PATH" powershell pwsh)"
outI2=$(run_case_i "$cfgIenabled" env PATH="$i2_path")
echo "$outI2" | jq -e '.items[0].desired == true and .items[0].actual == "degraded" and .items[0].severity == "degraded"' >/dev/null \
  || fail "case i2: bridge-persistence with bridge.enabled=true and persistence missing must stay severity degraded, never downgraded to n/a (got: $outI2)"
echo "$outI2" | jq -e '.items[0].detail | test("opt-in"; "i") | not' >/dev/null \
  || fail "case i2: a genuine bridge.enabled=true warn must NOT read the friendly opt-in n/a message (got: $outI2)"
echo "$outI2" | jq -e '.summary.degraded == 1 and .summary.na == 0' >/dev/null \
  || fail "case i2: a genuine bridge-persistence warn must count toward summary.degraded, not summary.na (got: $(echo "$outI2" | jq -c '.summary'))"
echo "ok: case i2 — bridge-persistence with bridge.enabled=true and persistence missing stays severity degraded, never silently swallowed to n/a"

# ── case j (HIMMEL-2305): telegram-bridge/hermes-lanes/codex-cli have no
# config.json flag of their own (unlike bridge-health/bridge-persistence/
# cadence-armed above) — their ONLY selection record is the recorded wizard
# answers (bridge.enabled, lanes). adopterProfileLib.resolveActiveFeatures()
# downgrades each to n/a when its feature was never selected, stays red when
# it was selected and the credential is genuinely absent, and — the fail-open
# control — stays red when `answers` itself is missing entirely (no profile
# to consult at all), preserving today's full-nag behavior rather than
# silently going quiet. ─────────────────────────────────────────────────────
manifestJ="$work/manifestJ.json"
cat > "$manifestJ" <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    {
      "id": "telegram-bridge",
      "kind": "lane",
      "scopes": ["project"],
      "profiles": ["core", "all"],
      "deps": [],
      "probe": { "type": "file-exists", "path": "missing.txt" }
    },
    {
      "id": "hermes-lanes",
      "kind": "lane",
      "scopes": ["project"],
      "profiles": ["core", "all"],
      "deps": [],
      "probe": { "type": "file-exists", "path": "missing.txt" }
    },
    {
      "id": "codex-cli",
      "kind": "dep",
      "scopes": ["project"],
      "profiles": ["core", "all"],
      "deps": [],
      "probe": { "type": "file-exists", "path": "missing.txt" }
    }
  ]
}
JSON
MANIFEST_J_PATH="$(winpath "$manifestJ")"
export MANIFEST_J_PATH
caseJ_dir="$work/caseJ-target"; mkdir -p "$caseJ_dir"
homeJ="$work/homeJ"; mkdir -p "$homeJ"
cacheJ="$work/cacheJ"; mkdir -p "$cacheJ"

# j1: none of bridge/hermes/codex ever selected -> all three n/a (opt-in).
outJ1=$(cd "$caseJ_dir" && HOME="$homeJ" USERPROFILE="$(winpath "$homeJ")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheJ")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cacheJ")-luna-config.json" "$node_bin" -e "
const { statusReport } = require(process.env.STATUS_REPORT_LIB);
const manifest = JSON.parse(require('fs').readFileSync(process.env.MANIFEST_J_PATH, 'utf8'));
const answers = {
  role: 'adopter', tier: 'standard', scope: 'project',
  vault: { mode: 'none', path: '' },
  handover: { mode: 'none', path: '' },
  pluginSet: 'lean', lanes: [], alwaysOn: false,
};
const report = statusReport({ manifest, scope: 'project', targetPath: process.cwd(), answers });
console.log(JSON.stringify(report));
")
echo "$outJ1" | jq -e '[.items[] | select(.severity != "n/a")] | length == 0' >/dev/null \
  || fail "case j1: telegram-bridge/hermes-lanes/codex-cli must all read n/a when none was ever selected (got: $outJ1)"
echo "$outJ1" | jq -e '.items[] | select(.id=="telegram-bridge") | .detail | test("opt-in"; "i")' >/dev/null \
  || fail "case j1: telegram-bridge n/a detail should name it opt-in (got: $outJ1)"
echo "$outJ1" | jq -e '.summary.red == 0 and .summary.na == 3' >/dev/null \
  || fail "case j1: none-selected must not count toward summary.red (got: $(echo "$outJ1" | jq -c '.summary'))"
echo "ok: case j1 — telegram-bridge/hermes-lanes/codex-cli all read n/a when their feature was never selected"

# j2: bridge selected + hermes lane selected -> telegram-bridge and
# hermes-lanes stay red (genuinely absent credential/install), codex-cli
# (not selected) stays n/a.
outJ2=$(cd "$caseJ_dir" && HOME="$homeJ" USERPROFILE="$(winpath "$homeJ")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheJ")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cacheJ")-luna-config.json" "$node_bin" -e "
const { statusReport } = require(process.env.STATUS_REPORT_LIB);
const manifest = JSON.parse(require('fs').readFileSync(process.env.MANIFEST_J_PATH, 'utf8'));
const answers = {
  role: 'adopter', tier: 'standard', scope: 'project',
  vault: { mode: 'none', path: '' },
  handover: { mode: 'none', path: '' },
  pluginSet: 'lean', lanes: ['hermes'], alwaysOn: false,
  bridge: { enabled: true },
};
const report = statusReport({ manifest, scope: 'project', targetPath: process.cwd(), answers });
console.log(JSON.stringify(report));
")
echo "$outJ2" | jq -e '.items[] | select(.id=="telegram-bridge") | .severity == "red"' >/dev/null \
  || fail "case j2: telegram-bridge selected (bridge.enabled) + genuinely absent must stay red (got: $outJ2)"
echo "$outJ2" | jq -e '.items[] | select(.id=="hermes-lanes") | .severity == "red"' >/dev/null \
  || fail "case j2: hermes-lanes selected (lanes:[hermes]) + genuinely absent must stay red (got: $outJ2)"
echo "$outJ2" | jq -e '.items[] | select(.id=="codex-cli") | .severity == "n/a"' >/dev/null \
  || fail "case j2: codex-cli (not selected) must still read n/a even when hermes/bridge are selected (got: $outJ2)"
echo "ok: case j2 — a selected feature's genuinely-absent credential stays red; an unselected sibling stays n/a"

# j3 (fail-open control): no `answers` object at all (statusReport called
# with none) must NOT be treated as "nothing selected" — it must keep
# TODAY'S full-nag behavior (severity stays red), since resolveActiveFeatures
# fails open (null) rather than fabricating an empty feature set.
outJ3=$(cd "$caseJ_dir" && HOME="$homeJ" USERPROFILE="$(winpath "$homeJ")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheJ")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cacheJ")-luna-config.json" "$node_bin" -e "
const { statusReport } = require(process.env.STATUS_REPORT_LIB);
const manifest = JSON.parse(require('fs').readFileSync(process.env.MANIFEST_J_PATH, 'utf8'));
const report = statusReport({ manifest, scope: 'project', targetPath: process.cwd() });
console.log(JSON.stringify(report));
")
echo "$outJ3" | jq -e '[.items[] | select(.severity != "red")] | length == 0' >/dev/null \
  || fail "case j3: with no answers object at all, telegram-bridge/hermes-lanes/codex-cli must ALL stay red (fail-open to nagging), not go quiet (got: $outJ3)"
echo "ok: case j3 — no recorded profile at all fails open to full-nag behavior, never silently quiet"

# ── case k (HIMMEL-2349 CR fix): the recordedDesired() additive overlay must
# honor the EXPLICIT `scope` argument, not `answers.scope` — the same rule
# case c already pins for the deriveTarget() fallback (status-report.js:163),
# reintroduced ~90 lines below at the recordedDesired() call site. Fixture
# item is scopes:["user"] only, profiles:["core","all"] (so profile
# membership always matches — scope is the ONLY discriminator). answers.scope
# is 'user' (deliberately mismatched); the call itself uses the explicit
# scope:'project'. No persisted state.json and no caller `state` — first-run
# deriveTarget() fallback (already scope-correct per case c) leaves the item
# entry.enabled:false, so the ONLY way it could read desired:true is the
# recordedDesired() overlay evaluating membership against the wrong
# (answers.scope:'user') scope instead of the explicit 'project' one. ──────
manifestK="$work/manifestK.json"
cat > "$manifestK" <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    {
      "id": "user-scoped-item",
      "kind": "hook",
      "scopes": ["user"],
      "profiles": ["core", "all"],
      "deps": [],
      "probe": { "type": "file-exists", "path": "missing.txt" }
    }
  ]
}
JSON
MANIFEST_K_PATH="$(winpath "$manifestK")"
export MANIFEST_K_PATH

caseK_dir="$work/caseK-target"; mkdir -p "$caseK_dir"
homeK="$work/homeK"; mkdir -p "$homeK"
cacheK="$work/cacheK"; mkdir -p "$cacheK"

outK=$(cd "$caseK_dir" && HOME="$homeK" USERPROFILE="$(winpath "$homeK")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheK")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cacheK")-luna-config.json" "$node_bin" -e "
const { statusReport } = require(process.env.STATUS_REPORT_LIB);
const manifest = JSON.parse(require('fs').readFileSync(process.env.MANIFEST_K_PATH, 'utf8'));
// answers.scope is 'user' — deliberately MISMATCHED with the explicit
// scope:'project' argument below. No persisted state.json, no caller
// \`state\` — exercises the recordedDesired() overlay (!passedState branch).
const answers = {
  role: 'adopter', tier: 'standard', scope: 'user',
  vault: { mode: 'none', path: '' },
  handover: { mode: 'none', path: '' },
  pluginSet: 'lean', lanes: [], alwaysOn: false,
};
const report = statusReport({ manifest, scope: 'project', targetPath: process.cwd(), answers });
console.log(JSON.stringify(report));
")
[ ! -f "$cacheK/state.json" ] || fail "case k: no persisted state should exist yet (this is the uncached-fallback + overlay path)"
echo "$outK" | jq -e '.items[0].desired == false' >/dev/null \
  || fail "case k: user-scoped-item (scopes:[user]) should read desired:false under the EXPLICIT scope:project, even though answers.scope='user' would otherwise enable it via the recordedDesired() overlay (got: $outK)"
echo "$outK" | jq -e '.items[0].severity == "n/a"' >/dev/null \
  || fail "case k: user-scoped-item should then NOT be probed (severity:n/a) — proving it wasn't wrongly enabled by the overlay (got: $outK)"
echo "ok: case k — the recordedDesired() additive overlay honors the explicit scope argument, not answers.scope"

echo "PASS"
