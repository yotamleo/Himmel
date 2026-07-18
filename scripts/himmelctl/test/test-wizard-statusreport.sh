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

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
status_report_lib="$repo_root/scripts/himmelctl/lib/status-report.js"
[ -f "$status_report_lib" ] || { echo "FAIL: $status_report_lib not found" >&2; exit 1; }
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

outA=$(cd "$caseA_dir" && HOME="$homeA" HIMMELCTL_CACHE_DIR="$(winpath "$cacheA")" "$node_bin" -e "
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
    HOME="$homeB" HIMMELCTL_CACHE_DIR="$(winpath "$cacheB")" HIMMELCTL_REPO_ROOT="$fixtureRepoB_w" "$node_bin" -e "
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

outC=$(cd "$caseC_dir" && HOME="$homeC" HIMMELCTL_CACHE_DIR="$(winpath "$cacheC")" "$node_bin" -e "
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

outD=$(cd "$caseD_dir" && HOME="$homeD" HIMMELCTL_CACHE_DIR="$(winpath "$cacheD")" "$node_bin" -e "
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

echo "PASS"
