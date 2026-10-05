#!/usr/bin/env bash
# test-observability-grafana-manifest.sh — HIMMEL-4289: the opt-in
# `observability-grafana` himmelctl item (Prometheus + Grafana user units).
# Runs the REAL manifest, manifest-lint, probe, install-engine and
# status-report against fixture config/repo trees; no real service is touched.
#
# Cases: a lint + closed shape, b probe (not opted in / not linux / opted in
# present|degraded|absent via a stub install-grafana.sh), c status-report n/a,
# d install-engine plan (unrunnable until opted in, then bash install-grafana.sh).
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
manifest_path="$repo_root/scripts/install/manifest.json"
lint="$repo_root/scripts/install/manifest-lint.mjs"
probes_lib="$repo_root/scripts/himmelctl/lib/probes.js"
status_report_lib="$repo_root/scripts/himmelctl/lib/status-report.js"
install_engine_lib="$repo_root/scripts/himmelctl/lib/install-engine.js"
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; echo "$(basename "$0"): SKIPPED — 0 cases ran (jq not on PATH)"; exit 0; }

fail() { echo "FAIL: $1" >&2; exit 1; }
node_bin=$(command -v node)
work=$(mktemp -d "${TMPDIR:-/tmp}/himmel-obs-grafana-test.XXXXXX") || fail "mktemp -d failed"
trap 'rm -rf "$work"' EXIT

cfg_off="$work/config-off.json"
cfg_on="$work/config-on.json"
cfg_stack_only="$work/config-stack-only.json"
printf '{"version":1,"observability":{"grafana":true}}\n' > "$cfg_on"
printf '{"version":1,"observability":{"enabled":true}}\n' > "$cfg_stack_only"
export HIMMEL_LUNA_CONFIG_PATH="$cfg_off"

# ── case a: manifest item exists, lints, and the closed shape rejects an extra field
item=$(jq -c '[.items[] | select(.id == "observability-grafana")] | .[0] // empty' "$manifest_path")
[ -n "$item" ] || fail "case a: no observability-grafana item in manifest.json"
[ "$(echo "$item" | jq -r '.probe.type')" = "observability-grafana" ] || fail "case a: wrong probe.type: $item"
[ "$(echo "$item" | jq -r '.install.target')" = "grafana" ] || fail "case a: wrong install.target: $item"
[ "$(echo "$item" | jq -r '.deps | join(",")')" = "observability-stack" ] || fail "case a: must depend on the exporter item: $item"
out=$(MANIFEST_PATH="$manifest_path" "$node_bin" "$lint" 2>&1) || fail "case a: manifest should lint clean: $out"
bad="$work/manifest-bad.json"
jq '(.items[] | select(.id == "observability-grafana") | .probe) |= (. + {"bogus": true})' "$manifest_path" > "$bad"
out=$(MANIFEST_PATH="$bad" "$node_bin" "$lint" 2>&1) && fail "case a: lint accepted an unknown probe field: $out"
grep -q "unexpected field" <<< "$out" || fail "case a: lint rejection must name the unexpected field: $out"
echo "ok: case a — manifest item lints and its probe shape is closed"

# probe <config> <platform> <fixture-repo> -> JSON
probe() {
  HIMMEL_LUNA_CONFIG_PATH="$1" "$node_bin" -e "
const { runProbe } = require(process.argv[1]);
const item = { probe: { type: 'observability-grafana' } };
const ctx = { repoRoot: process.argv[3], targetPath: process.argv[3], scope: 'user', env: process.env, platform: process.argv[2] };
console.log(JSON.stringify(runProbe(item, ctx)));
" "$probes_lib" "$2" "$3"
}
# fixture repo whose install-grafana.sh status prints $1 and exits $2
fixture_repo() {
  local d="$work/repo-$RANDOM"
  mkdir -p "$d/scripts/observability"
  printf '#!/usr/bin/env bash\ncat <<EOF\n%s\nEOF\nexit %s\n' "$1" "$2" > "$d/scripts/observability/install-grafana.sh"
  echo "$d"
}

# ── case b: probe tri-state + clean absences
out=$(probe "$cfg_off" linux "$repo_root")
if ! { [ "$(echo "$out" | jq -r '.actual')" = absent ] && [ "$(echo "$out" | jq -r '.cleanAbsence')" = true ]; }; then
  fail "case b: not opted in must be a clean absence: $out"
fi
grep -q 'observability.grafana' <<< "$out" || fail "case b: detail must name observability.grafana: $out"
out=$(probe "$cfg_stack_only" linux "$repo_root")
[ "$(echo "$out" | jq -r '.cleanAbsence')" = true ] || fail "case b: the exporter opt-in alone must NOT opt in grafana: $out"
out=$(probe "$cfg_on" darwin "$repo_root")
if ! { [ "$(echo "$out" | jq -r '.actual')" = absent ] && [ "$(echo "$out" | jq -r '.cleanAbsence')" = true ]; }; then
  fail "case b: non-linux must be a clean absence: $out"
fi
ok_repo=$(fixture_repo "OK   service  a" 0)
out=$(probe "$cfg_on" linux "$ok_repo")
[ "$(echo "$out" | jq -r '.actual')" = present ] || fail "case b: status rc 0 must be present: $out"
part_repo=$(fixture_repo "OK   service  himmel-observability-prometheus.service registered
FAIL service  himmel-observability-grafana.service not registered
FAIL health  grafana no 200" 1)
out=$(probe "$cfg_on" linux "$part_repo")
[ "$(echo "$out" | jq -r '.actual')" = degraded ] || fail "case b: a partial failure must be degraded: $out"
grep -q 'grafana' <<< "$out" || fail "case b: degraded detail must name what failed: $out"
none_repo=$(fixture_repo "FAIL service  a
FAIL service  b
FAIL service  c
FAIL health  a
FAIL health  b
FAIL health  c" 1)
out=$(probe "$cfg_on" linux "$none_repo")
[ "$(echo "$out" | jq -r '.actual')" = absent ] || fail "case b: everything failing must be absent (never installed): $out"
[ "$(echo "$out" | jq -r '.cleanAbsence // empty')" = "" ] || fail "case b: an opted-in absence is a true alarm, no cleanAbsence: $out"
echo "ok: case b — probe: clean absences, present, degraded, absent"

# ── case c: status-report reads the clean absence as n/a with the opt-in remedy
out=$("$node_bin" -e "
const { statusReport } = require(process.argv[1]);
const manifest = { items: [{ id: 'observability-grafana', kind: 'scheduler', scopes: ['user'], profiles: ['core','all'], deps: [], probe: { type: 'observability-grafana' } }] };
const report = statusReport({ manifest, scope: 'user', targetPath: process.cwd(), answers: {}, state: { targets: {} } });
console.log(JSON.stringify(report.items.find((r) => r.id === 'observability-grafana')));
" "$status_report_lib")
if [ "$(uname -s)" = Linux ]; then
  [ "$(echo "$out" | jq -r '.severity')" = "n/a" ] || fail "case c: not opted in must read n/a: $out"
  grep -q '"observability": {"grafana": true}' <<< "$(echo "$out" | jq -r .detail)" || fail "case c: the remedy must show the opt-in key: $out"
  echo "ok: case c — status-report: not opted in reads n/a with the remedy"
else
  echo "ok: case c — skipped off Linux (the probe is Linux-only)"
fi

# ── case d: install-engine plan
plan() {
  HIMMEL_LUNA_CONFIG_PATH="$1" "$node_bin" -e "
const ie = require(process.argv[1]);
const item = { id: 'observability-grafana', deps: [], install: { type: 'observability', target: 'grafana' } };
const ctx = { repoRoot: process.cwd(), scope: 'user', profile: 'core', targetPath: process.cwd(), platform: process.argv[2], env: process.env };
console.log(JSON.stringify(ie.planInstall([item], ctx)[0]));
" "$install_engine_lib" "$2"
}
out=$(plan "$cfg_off" linux)
grep -q 'observability.*grafana' <<< "$(echo "$out" | jq -r '.unrunnable // empty')" || fail "case d: not opted in must be unrunnable naming the key: $out"
[ "$(echo "$out" | jq -r '.cmd // empty')" = "" ] || fail "case d: not opted in must carry no cmd: $out"
out=$(plan "$cfg_on" darwin)
if ! { [ -n "$(echo "$out" | jq -r '.unrunnable // empty')" ] && [ "$(echo "$out" | jq -r '.cmd // empty')" = "" ]; }; then
  fail "case d: non-linux must be unrunnable: $out"
fi
out=$(plan "$cfg_on" linux)
[ "$(echo "$out" | jq -r '.cmd')" = bash ] || fail "case d: opted in must plan bash: $out"
grep -qE 'observability/install-grafana\.sh install$' <<< "$(echo "$out" | jq -r '.args | join(" ")')" \
  || fail "case d: must run install-grafana.sh install: $out"
echo "ok: case d — install-engine: unrunnable until opted in, then bash install-grafana.sh install"

echo "test-observability-grafana-manifest: all cases passed"
