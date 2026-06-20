#!/usr/bin/env bash
# Smoke test for check-template-himmel-plugins.sh. Drives the guard with
# fixture marketplace.json + settings-template.json via its env-override seams.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$HERE/check-template-himmel-plugins.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# A locally-vendored plugin (handover, obsidian-triage) plus an externally
# sourced one (claude-obsidian, object source) that must be EXEMPT.
cat > "$tmp/market.json" <<'JSON'
{"name":"himmel","plugins":[
  {"name":"handover","source":"./plugins/handover"},
  {"name":"obsidian-triage","source":"./plugins/obsidian-triage"},
  {"name":"claude-obsidian","source":{"source":"github","repo":"x/y"}}
]}
JSON

run_guard() { HIMMEL_MARKETPLACE_JSON="$tmp/market.json" HIMMEL_SETTINGS_TEMPLATE="$1" bash "$GUARD"; }

# Case 1: template missing obsidian-triage@himmel → expect FAIL (exit 1).
printf '{"enabledPlugins":{"handover@himmel":true}}' > "$tmp/tmpl.json"
if run_guard "$tmp/tmpl.json" >/dev/null 2>&1; then
  echo "FAIL: guard passed despite missing obsidian-triage@himmel"; exit 1
fi
echo "ok: drift detected"

# Case 2: all locally-vendored present, claude-obsidian exempt → expect PASS.
printf '{"enabledPlugins":{"handover@himmel":true,"obsidian-triage@himmel":true}}' > "$tmp/tmpl.json"
if ! run_guard "$tmp/tmpl.json" >/dev/null 2>&1; then
  echo "FAIL: guard failed on a complete template"; exit 1
fi
echo "ok: complete template passes"

# Case 3: missing input file → fail-OPEN skip (exit 0). Pins the deliberate
# skip contract: the always_run hook must not start blocking commits in a
# partial checkout where an input is absent.
if ! run_guard "$tmp/does-not-exist.json" >/dev/null 2>&1; then
  echo "FAIL: guard did not skip (exit 0) on a missing template file"; exit 1
fi
echo "ok: missing input skips"

echo "PASS: check-template-himmel-plugins smoke test"
