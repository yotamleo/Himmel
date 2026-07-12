#!/usr/bin/env bash
# Drift guard: every locally-vendored @himmel marketplace plugin
# (marketplace/.claude-plugin/marketplace.json entries with a local "./…"
# string source) MUST be enabled in docs/setup/settings-template.json as
# "<name>@himmel": true. That template is the SINGLE list install-plugins.sh
# (and adopt.sh, at every scope and for both core/all profiles) installs from.
# A plugin added to the marketplace but not the template is silently never
# installed by adopt — and install-plugins' post-install verify only checks the
# template's own list, so it falsely reports success. This is exactly how 5
# himmel plugins shipped uninstallable-by-adopt for one drift.
# Externally-sourced plugins (object "source", e.g. claude-obsidian served from
# its own marketplace) are curated separately and exempt.
# Fail-closed on detected drift; skips (exit 0) only when jq or an input file
# is unavailable. Inputs env-overridable for testing. bash 3.2-safe.
set -euo pipefail

MARKET_JSON="${HIMMEL_MARKETPLACE_JSON:-marketplace/.claude-plugin/marketplace.json}"
TEMPLATE_JSON="${HIMMEL_SETTINGS_TEMPLATE:-docs/setup/settings-template.json}"

command -v jq >/dev/null 2>&1 || { echo "template-plugins-check: jq not on PATH — skipping"; exit 0; }
[ -f "$MARKET_JSON" ]   || { echo "template-plugins-check: $MARKET_JSON missing — skipping"; exit 0; }
[ -f "$TEMPLATE_JSON" ] || { echo "template-plugins-check: $TEMPLATE_JSON missing — skipping"; exit 0; }

# Locally-vendored himmel plugins = entries whose source is a string ("./…").
# tr -d '\r': jq emits CRLF on Windows; a trailing \r corrupts the key match.
local_plugins="$(jq -r '.plugins[] | select((.source|type)=="string") | .name' "$MARKET_JSON" | tr -d '\r')"

missing=""
while IFS= read -r name; do
  [ -z "$name" ] && continue
  if [ "$(jq -r --arg k "$name@himmel" '(.enabledPlugins[$k] // false)' "$TEMPLATE_JSON" | tr -d '\r')" != "true" ]; then
    missing="$missing  $name@himmel
"
  fi
done <<EOF
$local_plugins
EOF

if [ -n "$missing" ]; then
  echo "ERR template-plugins-check: @himmel plugins missing from $TEMPLATE_JSON enabledPlugins:" >&2
  printf '%s' "$missing" >&2
  echo "    These ship in the himmel marketplace but adopt.sh/install-plugins.sh will never install them." >&2
  echo "    Add each as \"<name>@himmel\": true to enabledPlugins (or, if intentionally excluded," >&2
  echo "    give it an object source in marketplace.json so it is curated separately)." >&2
  exit 1
fi

echo "template-plugins-check: all locally-vendored @himmel plugins present in settings-template.json"
