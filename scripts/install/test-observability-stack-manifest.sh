#!/usr/bin/env bash
# test-observability-stack-manifest.sh — regression guard for HIMMEL-2326
# (observability stack has zero install-manifest coverage).
#
# Mirrors test-himmel-ops-plugin-enablement.sh's structure exactly: a
# handful of self-contained cases run against the REAL manifest.json/
# manifest-lint.mjs/probes.js, no fixture harness invented.
#
# Cases:
#   a. manifest.json still lints clean.
#   b. manifest.json carries an "observability-stack" item wired to
#      probe.type:observability-stack and install.type:observability
#      (target:stack) — the item this ticket exists to add.
#   c. a malformed observability-stack probe descriptor (an unknown extra
#      field) is REJECTED by manifest-lint — the closed-shape check.
#   d. probeObservabilityStack (the REAL function) returns present/degraded/
#      absent for three fixture win32 scheduled-task states, stubbing
#      Get-ScheduledTask via HIMMELCTL_POWERSHELL (never a real schtasks
#      spawn) — proving the tri-state honesty (all four up -> present, a
#      partial family -> degraded naming which task, none registered ->
#      absent).
#   e. on a non-win32 platform the probe reads absent, honestly naming the
#      Phase-A-is-win32-only reason (HIMMEL-922 / HIMMEL-2333) — never
#      present, never a repairable-looking degraded.
#   f. status-report.js's severity mapping: win32 + probe.actual:absent
#      stays 'red' — a TRUE alarm, since (unlike graphify-mcp/doc-guard-map)
#      this item carries a real install descriptor `himmelctl ensure` can
#      converge (HIMMEL-2326 RETASK).
#   g. status-report.js's severity mapping: posix + probe.actual:absent is
#      downgraded to 'n/a' — the operator can never converge this on posix,
#      so it must not read as an alarm (HIMMEL-2326 RETASK). Proves the
#      false-red class the doc-guard-map/graphify-mcp precedent blocks
#      already fixed doesn't reopen for this item.
#   h. status-report.js's severity mapping: probe.actual:degraded stays
#      'degraded' on BOTH win32 and posix — proves the n/a downgrade is
#      scoped to 'absent' only and can never swallow a real partial-install
#      warning.
#   i. drift guard (HIMMEL-2326 CR round 1, codex-2): probes.js's
#      OBSERVABILITY_TASK_NAMES is extracted from source and asserted EQUAL
#      to restart-stack.sh's own himmel-observability-* hard allowlist
#      (~L190-216) — the probe's comment claims the two never drift apart;
#      this case is what makes that claim true instead of asserted on
#      faith. Both extractions are guarded against silently yielding an
#      empty set (a broken pattern must fail loudly, not vacuously "pass"
#      by comparing empty-to-empty).
#   j. install-engine.js's dispatch for install.type:observability (HIMMEL-2326
#      CR round 4, codex-2): planInstall() with an injected ctx.platform (no
#      global process.platform stubbing needed — install-engine.js reads
#      ctx.platform directly) resolves to a pwsh invocation naming
#      install-stack.ps1 + -RepoRoot on win32, and to an `unrunnable` entry
#      (never a cmd/args spawn shape at all) naming the win32-only gap and
#      HIMMEL-2333 on posix — asserted on the returned descriptor, not on
#      side effects.
# shellcheck disable=SC2016  # case k's stub scripts expand $* / $OBS_* when THEY run, not here
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
manifest_path="$repo_root/scripts/install/manifest.json"
lint="$repo_root/scripts/install/manifest-lint.mjs"
probes_lib="$repo_root/scripts/himmelctl/lib/probes.js"
status_report_lib="$repo_root/scripts/himmelctl/lib/status-report.js"
restart_stack_lib="$repo_root/scripts/observability/restart-stack.sh"
install_engine_lib="$repo_root/scripts/himmelctl/lib/install-engine.js"
[ -f "$manifest_path" ] || { echo "FAIL: $manifest_path not found" >&2; exit 1; }
[ -f "$restart_stack_lib" ] || { echo "FAIL: $restart_stack_lib not found" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; echo "$(basename "$0"): SKIPPED — 0 cases ran (jq not on PATH)"; exit 0; }

fail() { echo "FAIL: $1" >&2; exit 1; }
node_bin=$(command -v node)

work=$(mktemp -d "${TMPDIR:-/tmp}/himmel-obs-stack-test.XXXXXX") || fail "mktemp -d failed"
[ -n "$work" ] || fail "mktemp -d produced an empty path"
trap 'rm -rf "$work"' EXIT

# HIMMEL-4341: posix is opt-in via observability.enabled in the luna config.
# Pin BOTH fixtures so no case ever reads the operator's real config file.
cfg_off="$work/config-off.json"   # absent file = defaults = not opted in
cfg_on="$work/config-on.json"
printf '{"version":1,"observability":{"enabled":true}}\n' > "$cfg_on"
export HIMMEL_LUNA_CONFIG_PATH="$cfg_off"

# winpath <path> — MSYS/Git-Bash paths confuse node's own path resolution
# when handed straight through; convert to a Windows-form path there, pass
# through unchanged elsewhere. Mirrors test-wizard-manifest-v2.sh's own
# helper.
winpath() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) cygpath -m "$1" 2>/dev/null || printf '%s' "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}

# ── case a: manifest.json still lints clean ─────────────────────────────
outA=$(MANIFEST_PATH="$(winpath "$manifest_path")" "$node_bin" "$(winpath "$lint")" 2>&1) \
  || fail "case a: manifest.json should lint clean (got): $outA"
echo "ok: case a — manifest.json lints clean"

# ── case b: manifest.json has an observability-stack item wired to the
# new probe.type + install.type ──────────────────────────────────────────
obsItem=$(jq -c '[.items[] | select(.id == "observability-stack")] | .[0] // empty' "$manifest_path")
[ -n "$obsItem" ] || fail "case b: manifest.json has no 'observability-stack' item — HIMMEL-2326 regression"
[ "$(echo "$obsItem" | jq -r '.probe.type')" = "observability-stack" ] \
  || fail "case b: observability-stack item's probe.type must be 'observability-stack', got: $obsItem"
[ "$(echo "$obsItem" | jq -r '.install.type')" = "observability" ] \
  || fail "case b: observability-stack item's install.type must be 'observability', got: $obsItem"
[ "$(echo "$obsItem" | jq -r '.install.target')" = "stack" ] \
  || fail "case b: observability-stack item's install.target must be 'stack', got: $obsItem"
echo "ok: case b — manifest.json has an observability-stack item probing observability-stack, install.type:observability target:stack"

# ── case c: a malformed probe descriptor (unknown extra field) is
# REJECTED — closed-shape check ──────────────────────────────────────────
badManifest="$work/manifest-bad-probe.json"
jq '(.items[] | select(.id == "observability-stack") | .probe) |= (. + {"bogus": true})' \
  "$manifest_path" > "$badManifest"
outC=$(MANIFEST_PATH="$(winpath "$badManifest")" "$node_bin" "$(winpath "$lint")" 2>&1) && \
  fail "case c: manifest-lint should have REJECTED an observability-stack probe with an unknown 'bogus' field, but it exited 0: $outC"
outC_match=$(printf '%s' "$outC" | grep -E "unexpected field" || true)
[ -n "$outC_match" ] \
  || fail "case c: manifest-lint's rejection should name the unexpected field, got: $outC"
echo "ok: case c — a malformed observability-stack probe descriptor (extra field) is rejected"

# ── case d: probeObservabilityStack's real tri-state logic, stubbing
# Get-ScheduledTask via HIMMELCTL_POWERSHELL (never a real schtasks spawn) ─
stubPs="$work/stub-pwsh.sh"
cat > "$stubPs" <<'STUB'
#!/usr/bin/env bash
case "${OBS_STUB_FIXTURE:-}" in
  present)
    printf 'himmel-observability-flow-exporter:Ready\n'
    printf 'himmel-observability-grafana:Running\n'
    printf 'himmel-observability-prometheus:Ready\n'
    printf 'himmel-observability-windows-exporter:Ready\n'
    ;;
  degraded)
    printf 'himmel-observability-flow-exporter:Ready\n'
    printf 'himmel-observability-grafana:Ready\n'
    printf 'himmel-observability-prometheus:Disabled\n'
    ;;
  absent)
    printf 'NONE\n'
    ;;
esac
exit 0
STUB
chmod +x "$stubPs"

outD=$("$node_bin" -e "
const { runProbe } = require(process.argv[1]);
const item = { probe: { type: 'observability-stack' } };
const baseEnv = Object.assign({}, process.env, { HIMMELCTL_POWERSHELL: process.argv[2] });
function run(fixture) {
  const env = Object.assign({}, baseEnv, { OBS_STUB_FIXTURE: fixture });
  return runProbe(item, { repoRoot: process.cwd(), targetPath: process.cwd(), scope: 'user', env, platform: 'win32' });
}
console.log(JSON.stringify({ present: run('present'), degraded: run('degraded'), absent: run('absent') }));
" "$(winpath "$probes_lib")" "$(winpath "$stubPs")")

[ "$(echo "$outD" | jq -r '.present.actual')" = "present" ] \
  || fail "case d: all four Ready/Running tasks must probe 'present', got: $outD"
[ "$(echo "$outD" | jq -r '.degraded.actual')" = "degraded" ] \
  || fail "case d: a partial family (flow-exporter/grafana up, prometheus Disabled, windows-exporter missing) must probe 'degraded', got: $outD"
degradedDetail=$(echo "$outD" | jq -r '.degraded.detail')
degradedDetail_windowsExporterMatch=$(printf '%s' "$degradedDetail" | grep -E "windows-exporter" || true)
[ -n "$degradedDetail_windowsExporterMatch" ] \
  || fail "case d: the degraded detail must name the missing windows-exporter task, got: $degradedDetail"
degradedDetail_disabledMatch=$(printf '%s' "$degradedDetail" | grep -E "Disabled" || true)
[ -n "$degradedDetail_disabledMatch" ] \
  || fail "case d: the degraded detail must name the Disabled prometheus task, got: $degradedDetail"
[ "$(echo "$outD" | jq -r '.absent.actual')" = "absent" ] \
  || fail "case d: zero registered tasks must probe 'absent', got: $outD"
echo "ok: case d — probeObservabilityStack returns present/degraded/absent for the three fixture states, naming which task(s) are the problem when degraded"

# ── case e: on posix NOT opted in, the probe reads a CLEAN absence naming
# the opt-in key — never present, never degraded (HIMMEL-4341) ──────────────
outE=$("$node_bin" -e "
const { runProbe } = require(process.argv[1]);
const item = { probe: { type: 'observability-stack' } };
const ctx = { repoRoot: process.cwd(), targetPath: process.cwd(), scope: 'user', env: process.env, platform: 'linux' };
console.log(JSON.stringify(runProbe(item, ctx)));
" "$(winpath "$probes_lib")")
[ "$(echo "$outE" | jq -r '.actual')" = "absent" ] \
  || fail "case e: posix not opted in must probe 'absent', got: $outE"
[ "$(echo "$outE" | jq -r '.cleanAbsence')" = "true" ] \
  || fail "case e: posix not opted in must carry cleanAbsence:true, got: $outE"
grep -q 'observability.enabled' <<< "$outE" \
  || fail "case e: the detail must name observability.enabled, got: $outE"
echo "ok: case e — posix not opted in reads a clean absence naming observability.enabled"

# ── cases f/g/h: status-report.js's severity mapping for observability-stack
# (HIMMEL-2326 RETASK) — runs the REAL statusReport() end to end, filtered
# to just this item, with a synthetic empty state (never touches the real
# operator's ~/.himmel state.json) so scope:'user' + profiles:[core,all]
# derives desired:true via state.js's own deriveTarget(). Get-ScheduledTask
# is stubbed via HIMMELCTL_POWERSHELL (never a real schtasks spawn); the
# posix cases monkeypatch process.platform inside the (isolated, disposable)
# child node process — this repo's real dev host stays untouched. ──────────
stubAbsent="$work/stub-pwsh-absent.sh"
cat > "$stubAbsent" <<'STUB'
#!/usr/bin/env bash
printf 'NONE\n'
exit 0
STUB
chmod +x "$stubAbsent"

stubDegraded="$work/stub-pwsh-degraded.sh"
cat > "$stubDegraded" <<'STUB'
#!/usr/bin/env bash
printf 'himmel-observability-flow-exporter:Ready\n'
printf 'himmel-observability-grafana:Ready\n'
exit 0
STUB
chmod +x "$stubDegraded"

status_report_probe() {
  # $1 = HIMMELCTL_POWERSHELL stub path, $2 = 'win32' or 'posix'
  # CR round 4 (codex-1, Critical): the override MUST be set explicitly for
  # BOTH branches — a prior version left it "" for win32, so
  # process.argv[2] was falsy and Object.defineProperty never ran, meaning
  # the win32 case silently read the REAL host's process.platform instead
  # of a forced one. That passed by accident on this Windows dev host and
  # would FAIL on a Linux host (HIMMEL-2277 heads there). Never leave a
  # branch depending on the ambient host platform.
  local platform_override="win32"
  [ "$2" = "posix" ] && platform_override="linux"
  # status-report.js's ctxForItem() never threads a platform field into ctx
  # (HIMMEL-2326 RETASK, confirmed while fixing HIMMEL-2642) — the ONLY way
  # to force win32 here is the process.platform monkeypatch above. That also
  # flips what resolveProbeBash() -> resolveHookBash() -> resolveBash() sees,
  # so on a REAL non-Windows host the forced-win32 case would search
  # Windows Git-Bash candidate paths, find nothing, and spawnBashProbe
  # synthesizes a "no usable bash found" spawn error that reads 'degraded' —
  # masking the severity mapping case f exists to test. Pin HIMMELCTL_BASH
  # to the real bash so the probe's Get-ScheduledTask spawn resolves
  # regardless of which host this runs on or which platform is forced.
  HIMMELCTL_POWERSHELL="$(winpath "$1")" HIMMELCTL_BASH="$(command -v bash)" "$node_bin" -e "
if (process.argv[2]) { Object.defineProperty(process, 'platform', { value: process.argv[2] }); }
const { statusReport } = require(process.argv[1]);
const manifest = { items: [{ id: 'observability-stack', kind: 'scheduler', scopes: ['user'], profiles: ['core','all'], deps: [], probe: { type: 'observability-stack' } }] };
const report = statusReport({ manifest, scope: 'user', targetPath: process.cwd(), answers: {}, state: { targets: {} } });
console.log(JSON.stringify(report.items.find((r) => r.id === 'observability-stack')));
" "$(winpath "$status_report_lib")" "$platform_override"
}

# ── case f: win32 + absent -> red ────────────────────────────────────────
outF=$(status_report_probe "$stubAbsent" win32)
[ "$(echo "$outF" | jq -r '.severity')" = "red" ] \
  || fail "case f: win32 + probe.actual:absent must stay severity:red (a true, convergeable alarm — this item has a real install descriptor), got: $outF"
echo "ok: case f — status-report.js: win32 + absent stays severity:red"

# ── case g: posix + not opted in -> n/a, remedy names the key ────────────
outG=$(status_report_probe "$stubAbsent" posix)
[ "$(echo "$outG" | jq -r '.severity')" = "n/a" ] \
  || fail "case g: posix not opted in must read severity:n/a (never nag every adopter), got: $outG"
detailG=$(echo "$outG" | jq -r '.detail')
grep -q '"observability": {"enabled": true}' <<< "$detailG" \
  || fail "case g: the n/a remedy must show how to set observability.enabled, got: $outG"
echo "ok: case g — status-report.js: posix not opted in reads severity:n/a with the opt-in remedy"

# ── case h: degraded stays degraded on BOTH platforms — the n/a downgrade
# never swallows a real partial-install warning. The REAL probe can never
# emit 'degraded' on posix (Phase A honesty: posix always reads absent —
# see case e), so this stubs probesLib.runProbe directly (module-cache
# monkeypatch: mutating the SAME exports object status-report.js's own
# internal `require('./probes.js')` resolves to) to exercise
# status-report.js's severity mapping in isolation from the probe's own
# platform gating — proving the n/a downgrade is scoped to probe.actual,
# never to process.platform directly ──────────────────────────────────────
status_report_degraded_stub() {
  # $1 = process.platform value to force
  "$node_bin" -e "
Object.defineProperty(process, 'platform', { value: process.argv[2] });
const probesLib = require(process.argv[1]);
probesLib.runProbe = () => ({ actual: 'degraded', detail: 'stub: partial install' });
const { statusReport } = require(process.argv[3]);
const manifest = { items: [{ id: 'observability-stack', kind: 'scheduler', scopes: ['user'], profiles: ['core','all'], deps: [], probe: { type: 'observability-stack' } }] };
const report = statusReport({ manifest, scope: 'user', targetPath: process.cwd(), answers: {}, state: { targets: {} } });
console.log(JSON.stringify(report.items.find((r) => r.id === 'observability-stack')));
" "$(winpath "$probes_lib")" "$1" "$(winpath "$status_report_lib")"
}
outH_win=$(status_report_degraded_stub win32)
[ "$(echo "$outH_win" | jq -r '.severity')" = "degraded" ] \
  || fail "case h: win32 + probe.actual:degraded must stay severity:degraded, got: $outH_win"
outH_posix=$(status_report_degraded_stub linux)
[ "$(echo "$outH_posix" | jq -r '.severity')" = "degraded" ] \
  || fail "case h: posix + probe.actual:degraded must ALSO stay severity:degraded (the n/a downgrade is scoped to 'absent' only), got: $outH_posix"
echo "ok: case h — status-report.js: degraded stays severity:degraded on both win32 and posix"

# ── case i: drift guard (HIMMEL-2326 CR round 1, codex-2) — probes.js's
# OBSERVABILITY_TASK_NAMES must equal restart-stack.sh's own
# himmel-observability-* hard allowlist. Extraction is TEXT-based on both
# sides (never `require`s probes.js's internal, unexported array; never
# sources/evals restart-stack.sh) — a formatting change upstream that breaks
# the pattern must yield an EMPTY set, which the guards below turn into a
# loud FAIL rather than a vacuous empty-equals-empty pass ─────────────────
# CR self-fix: `|| true` on each whole pipeline is REQUIRED, not cosmetic —
# under top-level `set -e`, a plain `var=$(pipeline)` assignment whose
# pipeline legitimately matches zero lines (pipefail turns that into a
# nonzero pipeline status) aborts the SCRIPT right here, before the
# `[ -n ... ] || fail` guard below ever runs — silently, with no FAIL
# message at all. Verified empirically while building this case: an
# unguarded version died with rc=1 and NO output the moment the extraction
# pattern was faulted to match nothing. `|| true` neutralizes that so the
# explicit, informative guard below is what actually fires.
restartStackNames=$( (grep -oE 'TASK_NAME="himmel-observability-[A-Za-z0-9_-]+"' "$restart_stack_lib" \
  | sed -E 's/^TASK_NAME="(.*)"$/\1/' | sort -u) || true)
[ -n "$restartStackNames" ] \
  || fail "case i: extracted ZERO task names from restart-stack.sh's allowlist ($restart_stack_lib) — the TASK_NAME=\"himmel-observability-...\" extraction pattern is broken, this is NOT a genuinely empty family"

probesNames=$( (awk '/const OBSERVABILITY_TASK_NAMES = \[/,/\];/' "$probes_lib" \
  | grep -oE "'himmel-observability-[A-Za-z0-9_-]+'" | tr -d "'" | sort -u) || true)
[ -n "$probesNames" ] \
  || fail "case i: extracted ZERO task names from probes.js's OBSERVABILITY_TASK_NAMES ($probes_lib) — the extraction pattern is broken, this is NOT a genuinely empty list"

onlyInRestartStack=$(comm -23 <(printf '%s\n' "$restartStackNames") <(printf '%s\n' "$probesNames"))
onlyInProbes=$(comm -13 <(printf '%s\n' "$restartStackNames") <(printf '%s\n' "$probesNames"))
if [ -n "$onlyInRestartStack" ] || [ -n "$onlyInProbes" ]; then
  fail "case i: OBSERVABILITY_TASK_NAMES (probes.js) has drifted from restart-stack.sh's himmel-observability-* allowlist — only in restart-stack.sh: [$onlyInRestartStack]; only in probes.js: [$onlyInProbes]"
fi
echo "ok: case i — OBSERVABILITY_TASK_NAMES (probes.js) matches restart-stack.sh's himmel-observability-* task allowlist exactly (drift-guarded)"

# ── case j: install-engine.js's dispatch for install.type:observability
# (HIMMEL-2326 CR round 4, codex-2) — drives planInstall() with an injected
# ctx.platform (install-engine.js reads ctx.platform, not process.platform,
# so no global stubbing is needed) and asserts on the RETURNED descriptor
# only, never on a real spawn ──────────────────────────────────────────────
outJ=$("$node_bin" -e "
const ie = require(process.argv[1]);
const item = { id: 'observability-stack', deps: [], install: { type: 'observability', target: 'stack' } };
function plan(platform) {
  const ctx = { repoRoot: process.cwd(), scope: 'user', profile: 'core', targetPath: process.cwd(), platform, env: process.env };
  return ie.planInstall([item], ctx)[0];
}
console.log(JSON.stringify({ win32: plan('win32'), posix: plan('linux') }));
" "$(winpath "$install_engine_lib")")

winArgs=$(echo "$outJ" | jq -r '.win32.args | join(" ")')
grep -qE -- <<<"$winArgs" '-File' \
  || fail "case j: win32 plan entry args must include -File, got args: $winArgs (full: $outJ)"
grep -qE 'install-stack\.ps1' <<<"$winArgs" \
  || fail "case j: win32 plan entry's -File arg must name install-stack.ps1, got args: $winArgs (full: $outJ)"
grep -qE -- <<<"$winArgs" '-RepoRoot' \
  || fail "case j: win32 plan entry args must include -RepoRoot, got args: $winArgs (full: $outJ)"
[ "$(echo "$outJ" | jq -r '.win32.unrunnable // empty')" = "" ] \
  || fail "case j: win32 plan entry must NOT be unrunnable, got: $outJ"
echo "ok: case j (win32) — install-engine.js dispatches install.type:observability to pwsh -File .../install-stack.ps1 -RepoRoot"

posixUnrunnable=$(echo "$outJ" | jq -r '.posix.unrunnable // empty')
[ -n "$posixUnrunnable" ] \
  || fail "case j: posix plan entry must be unrunnable when not opted in, got: $outJ"
grep -q 'observability.*enabled' <<< "$posixUnrunnable" \
  || fail "case j: posix unrunnable reason must name the opt-in key, got: $posixUnrunnable"
[ "$(echo "$outJ" | jq -r '.posix.cmd // empty')" = "" ] \
  || fail "case j: posix not opted in must carry NO cmd (ensure never enables a service unasked), got: $outJ"
echo "ok: case j (posix, not opted in) — install-engine.js returns unrunnable naming the opt-in key, no cmd"

outJ2=$(HIMMEL_LUNA_CONFIG_PATH="$cfg_on" "$node_bin" -e "
const ie = require(process.argv[1]);
const item = { id: 'observability-stack', deps: [], install: { type: 'observability', target: 'stack' } };
const ctx = { repoRoot: process.cwd(), scope: 'user', profile: 'core', targetPath: process.cwd(), platform: 'linux', env: process.env };
console.log(JSON.stringify(ie.planInstall([item], ctx)[0]));
" "$(winpath "$install_engine_lib")")
[ "$(echo "$outJ2" | jq -r '.cmd')" = "bash" ] \
  || fail "case j: posix opted in must plan a bash cmd, got: $outJ2"
argsJ2=$(echo "$outJ2" | jq -r '.args | join(" ")')
grep -qE 'observability[/\\]install-stack\.sh install$' <<< "$argsJ2" \
  || fail "case j: posix opted in must run install-stack.sh install, got: $outJ2"
echo "ok: case j (posix, opted in) — install-engine.js plans bash install-stack.sh install"

# ── case k: opted-in posix probe against a fixture repo, systemctl/curl/
# doctor-cadence stubbed (never a real service, never the network). Also
# asserts the probe is read-only (no enable/start/restart) and bounded ───
fake="$work/fakerepo"; fbin="$work/fbin"; fcalls="$work/calls.log"
mkdir -p "$fake/scripts/observability" "$fbin"
cp "$repo_root/scripts/observability/install-stack.sh" "$fake/scripts/observability/"
printf '#!/bin/sh\necho Linux\n' > "$fbin/uname"
printf '#!/bin/sh\necho "systemctl $*" >> "%s"\n[ -z "$OBS_SVC_DOWN" ]\n' "$fcalls" > "$fbin/systemctl"
printf '#!/bin/sh\necho "launchctl $*" >> "%s"\n[ -z "$OBS_SVC_DOWN" ]\n' "$fcalls" > "$fbin/launchctl"
printf '#!/bin/sh\nif [ -n "$OBS_HEALTH_DOWN" ]; then printf 000; else printf 200; fi\n' > "$fbin/curl"
printf '#!/bin/sh\nif [ -n "$OBS_CADENCE_DOWN" ]; then echo NOT-ARMED; else echo ARMED; fi\n' > "$fake/scripts/doctor-cadence.sh"
chmod +x "$fbin"/*
k_probe() {
  # $@ = VAR=1 overrides for the stubs
  : > "$fcalls"
  env "$@" HIMMEL_LUNA_CONFIG_PATH="$cfg_on" PATH="$fbin:$PATH" HOME="$work" "$node_bin" -e "
const { runProbe } = require(process.argv[1]);
console.log(JSON.stringify(runProbe({ probe: { type: 'observability-stack' } }, { repoRoot: process.argv[2], targetPath: process.cwd(), scope: 'user', env: process.env, platform: 'linux' })));
" "$(winpath "$probes_lib")" "$(winpath "$fake")"
}
[ "$(k_probe X=1 | jq -r '.actual')" = "present" ] || fail "case k: registered + healthy + cadence armed must probe present"
mutating_re='systemctl --user (enable|start|restart|daemon-reload|disable)|launchctl (bootstrap|enable|bootout|kickstart)'
# positive control: the matcher must hit a planted mutating call, or "no match" below proves nothing
grep -qE "$mutating_re" <<< "systemctl --user enable himmel-flow-exporter.service" \
  || fail "case k: the read-only matcher failed to match a planted mutating command"
rc_ro=0; grep -qE "$mutating_re" "$fcalls" || rc_ro=$?
[ "$rc_ro" = 1 ] || fail "case k: the probe must be read-only (grep rc=$rc_ro; 0=mutation seen, 2=grep error), saw: $(cat "$fcalls")"
[ "$(k_probe OBS_SVC_DOWN=1 OBS_HEALTH_DOWN=1 | jq -r '.actual')" = "absent" ] || fail "case k: service + health down must probe absent (not installed)"
outK=$(k_probe OBS_CADENCE_DOWN=1)
[ "$(echo "$outK" | jq -r '.actual')" = "degraded" ] || fail "case k: cadence unarmed must probe degraded, got: $outK"
grep -q 'doctor-cadence' <<< "$outK" || fail "case k: degraded detail must name doctor-cadence, got: $outK"
[ "$(k_probe OBS_HEALTH_DOWN=1 | jq -r '.actual')" = "degraded" ] || fail "case k: service up but exporter unhealthy must probe degraded"
# bounded: a hanging status script reads degraded within the probe timeout
printf '#!/bin/sh\nsleep 30\n' > "$fbin/curl"; chmod +x "$fbin/curl"
outT=$(k_probe HIMMELCTL_PROBE_TIMEOUT_SECS=1 X=1)
[ "$(echo "$outT" | jq -r '.actual')" = "degraded" ] || fail "case k: a hanging status must read degraded, got: $outT"
grep -q 'timed out' <<< "$outT" || fail "case k: the hanging-status detail must say 'timed out', got: $outT"
echo "ok: case k — opted-in posix probe: present/absent/degraded from install-stack.sh status, read-only, bounded"

# ── case l: himmel-update never converges it (DRIFT_CONVERGE_IDS allow-list) ─
convergeIds=$(grep -E '^DRIFT_CONVERGE_IDS=' "$repo_root/scripts/himmel-update.sh" || true)
[ -n "$convergeIds" ] || fail "case l: could not find DRIFT_CONVERGE_IDS in himmel-update.sh"
if grep -q 'observability-stack' <<< "$convergeIds"; then
  fail "case l: himmel-update must never auto-converge observability-stack, saw: $convergeIds"
fi
echo "ok: case l — observability-stack is not in himmel-update's DRIFT_CONVERGE_IDS"

echo "PASS"
