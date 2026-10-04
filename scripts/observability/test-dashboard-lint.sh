#!/usr/bin/env bash
# test-dashboard-lint.sh — HIMMEL-4292: static lint for the provisioned
# himmel health dashboard (dashboards/himmel-health.json).
#
# Checks, each with a positive control (a broken copy the lint must reject):
#   1. the file is valid JSON with uid himmel-health;
#   2. panel ids are unique (row-nested panels included);
#   3. every metric a PromQL expr names is one flow-exporter.ts emits via
#      addFamily(...), or a Prometheus built-in (ALERTS, up) — a dashboard must
#      never chart a series that does not exist;
#   4. every datasource reference is the provisioned Prometheus uid read from
#      provisioning/datasources/prometheus.yaml — no ${DS_*} variable, no
#      hard-coded uid that drifts from provisioning;
#   5. the dashboard provider ships INERT: provisioning/dashboards/ carries
#      himmel-dashboards.yaml.tmpl (rendered by the Linux installer,
#      HIMMEL-4289) and NO active *.yaml/*.yml. restart-stack.sh syncs
#      provisioning/ wholesale onto the station, and a provider whose path is
#      missing there breaks Grafana provisioning (console ruling 2026-10-04).
# Reads repo files only; writes broken copies into its own mktemp -d dir.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DASH="$SCRIPT_DIR/dashboards/himmel-health.json"
EXPORTER="$SCRIPT_DIR/flow-exporter.ts"
DS_YAML="$SCRIPT_DIR/provisioning/datasources/prometheus.yaml"
PROV_DASH_DIR="$SCRIPT_DIR/provisioning/dashboards"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT

# lint <dashboard.json> — prints one line per violation, exits 1 on any.
lint() {
    node - "$1" "$EXPORTER" "$DS_YAML" <<'NODE'
const fs = require("fs");
const [dashPath, exporterPath, dsPath] = process.argv.slice(2);
const errs = [];
let dash;
try { dash = JSON.parse(fs.readFileSync(dashPath, "utf8")); }
catch (e) { console.log(`invalid JSON: ${e.message}`); process.exit(1); }
if (dash.uid !== "himmel-health") errs.push(`uid is ${JSON.stringify(dash.uid)}, want "himmel-health"`);

const src = fs.readFileSync(exporterPath, "utf8");
const known = new Set(["ALERTS", "up"]);
for (const m of src.matchAll(/addFamily\(\s*\w+,\s*"([a-zA-Z_:][a-zA-Z0-9_:]*)"/g)) known.add(m[1]);
if (known.size < 10) errs.push(`only ${known.size} metric names parsed from flow-exporter.ts`);

const dsUid = (fs.readFileSync(dsPath, "utf8").match(/^\s*uid:\s*(\S+)\s*$/m) || [])[1];
if (!dsUid) errs.push("no uid in provisioning/datasources/prometheus.yaml");

const panels = [];
(function walk(list) { for (const p of list || []) { panels.push(p); walk(p.panels); } })(dash.panels);
if (panels.length === 0) errs.push("dashboard has no panels");

const seen = new Map();
for (const p of panels) {
  if (typeof p.id !== "number") { errs.push(`panel "${p.title}" has no numeric id`); continue; }
  if (seen.has(p.id)) errs.push(`duplicate panel id ${p.id}: "${seen.get(p.id)}" and "${p.title}"`);
  seen.set(p.id, p.title);
}

const checkDs = (ds, where) => {
  if (ds === undefined) return;
  if (typeof ds !== "object" || ds === null || ds.type !== "prometheus" || ds.uid !== dsUid)
    errs.push(`${where}: datasource ${JSON.stringify(ds)} is not {type: prometheus, uid: ${dsUid}}`);
};

// Identifiers a PromQL expr uses that are NOT metric names.
const KEYWORDS = new Set(["and", "or", "unless", "by", "without", "on", "ignoring",
  "group_left", "group_right", "bool", "offset", "inf", "nan"]);
const metricsOf = (expr) => Array.from(expr
  .replace(/"(?:[^"\\]|\\.)*"/g, " ")          // string literals
  .replace(/\{[^}]*\}/g, " ")                    // label matchers
  .replace(/\[[^\]]*\]/g, " ")                   // range / subquery selectors
  .replace(/\b(?:by|without|on|ignoring|group_left|group_right)\s*\([^)]*\)/g, " ")
  .replace(/\$\w+/g, " ")                        // Grafana variables ($__interval)
  .replace(/\b\d[\w.]*/g, " ")                   // numbers and durations
  // Whole identifiers; one followed by "(" is a function call, not a metric.
  .matchAll(/([a-zA-Z_:][a-zA-Z0-9_:]*)(\s*\()?/g))
  .filter((m) => !m[2] && !KEYWORDS.has(m[1].toLowerCase()))
  .map((m) => m[1]);

let exprs = 0;
for (const p of panels) {
  checkDs(p.datasource, `panel ${p.id}`);
  for (const t of p.targets || []) {
    checkDs(t.datasource, `panel ${p.id} target ${t.refId}`);
    if (typeof t.expr !== "string" || !t.expr.trim()) { errs.push(`panel ${p.id} target ${t.refId}: empty expr`); continue; }
    exprs++;
    for (const m of metricsOf(t.expr)) if (!known.has(m)) errs.push(`panel ${p.id} ("${p.title}"): unknown metric "${m}" in ${t.expr}`);
  }
}
if (exprs === 0) errs.push("no PromQL exprs found");
if (/\$\{?DS_/.test(JSON.stringify(dash))) errs.push("dashboard uses a ${DS_*} datasource variable");

for (const e of errs) console.log(e);
process.exit(errs.length ? 1 : 0);
NODE
}

echo "== real dashboard passes the lint"
if [ ! -f "$DASH" ]; then
    fail "dashboards/himmel-health.json exists" "missing: $DASH"
else
    out="$(lint "$DASH")"; rc=$?
    if [ "$rc" -eq 0 ]; then pass "himmel-health.json lints clean"; else fail "himmel-health.json lints clean" "$out"; fi

    # Positive controls: each check must be able to fail.
    echo "== positive controls (broken copies must be rejected)"
    control() { # control <name> <expected-substring> <node mutation of d>
        local name="$1" want="$2" mut="$3" f="$TMP/$1.json" out rc
        node -e 'const fs=require("fs");const d=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));const all=[];(function w(l){for(const p of l||[]){all.push(p);w(p.panels);}})(d.panels);const withExpr=all.find(p=>(p.targets||[]).length);'"$mut"';fs.writeFileSync(process.argv[2],JSON.stringify(d));' "$DASH" "$f"
        out="$(lint "$f")"; rc=$?
        if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF "$want"; then pass "rejects $name"; else fail "rejects $name" "rc=$rc out=$out"; fi
    }
    control unknown-metric 'unknown metric "himmel_made_up_total"' 'withExpr.targets[0].expr="sum(himmel_made_up_total)"'
    control duplicate-id 'duplicate panel id' 'all[1].id=all[0].id'
    control drifted-uid 'is not {type: prometheus' 'withExpr.datasource={type:"prometheus",uid:"P1809F7CD0C75ACF3"}'
    # shellcheck disable=SC2016 # a literal ${DS_PROMETHEUS} is the point
    control ds-variable 'DS_' 'withExpr.targets[0].datasource={type:"prometheus",uid:"${DS_PROMETHEUS}"}'
    control wrong-uid 'want "himmel-health"' 'd.uid="war-room"'
    printf '{"uid":' > "$TMP/broken.json"
    out="$(lint "$TMP/broken.json")"; rc=$?
    if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF 'invalid JSON'; then pass "rejects invalid JSON"; else fail "rejects invalid JSON" "rc=$rc out=$out"; fi
fi

echo "== dashboard provider ships inert"
if [ -f "$PROV_DASH_DIR/himmel-dashboards.yaml.tmpl" ] && grep -qF '@HIMMEL_DASHBOARDS_DIR@' "$PROV_DASH_DIR/himmel-dashboards.yaml.tmpl"; then
    pass "provider template carries the @HIMMEL_DASHBOARDS_DIR@ token"
else
    fail "provider template carries the @HIMMEL_DASHBOARDS_DIR@ token" "missing or untokenised: $PROV_DASH_DIR/himmel-dashboards.yaml.tmpl"
fi
active="$(find "$PROV_DASH_DIR" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) | sort)"
if [ -z "$active" ]; then pass "no active provider yaml under provisioning/dashboards/"; else fail "no active provider yaml under provisioning/dashboards/" "$active"; fi

echo
echo "===================================="
echo "test-dashboard-lint: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
