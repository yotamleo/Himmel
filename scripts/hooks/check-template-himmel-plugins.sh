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
#
# Second guard (HIMMEL-2691): every marketplace SUFFIX named by an
# enabledPlugins key ("<plugin>@<marketplace>") must have a matching
# extraKnownMarketplaces entry. install-plugins.sh registers marketplaces
# ONLY from extraKnownMarketplaces, then installs every enabledPlugins key —
# so a plugin whose marketplace was never registered can never install, and
# the post-install presence-verify fails the whole run. This is exactly how
# settings-template.json enabled 5 claude-plugins-official plugins
# (superpowers, context7, coderabbit, playwright, typescript-lsp) without ever
# declaring that marketplace, breaking `himmelctl install` on a fresh machine.
#
# Fail-closed on detected drift; skips (exit 0) only when jq is unavailable or
# an input file is MISSING (fresh clone / CI without it — a legitimate skip).
# An input that EXISTS but is unreadable is not a skip: it would otherwise read
# as empty and the drift checks below would see two empty sets and report a
# false PASS, so that case fails closed (exit 1) with a named diagnostic.
# Inputs env-overridable for testing. bash 3.2-safe.
set -euo pipefail

MARKET_JSON="${HIMMEL_MARKETPLACE_JSON:-marketplace/.claude-plugin/marketplace.json}"
TEMPLATE_JSON="${HIMMEL_SETTINGS_TEMPLATE:-docs/setup/settings-template.json}"

command -v jq >/dev/null 2>&1 || { echo "template-plugins-check: jq not on PATH — skipping"; exit 0; }

[ -f "$MARKET_JSON" ] || { echo "template-plugins-check: $MARKET_JSON missing — skipping"; exit 0; }
if [ ! -r "$MARKET_JSON" ]; then
  echo "ERR template-plugins-check: $MARKET_JSON exists but is unreadable — refusing to skip (fail-closed)." >&2
  exit 1
fi

[ -f "$TEMPLATE_JSON" ] || { echo "template-plugins-check: $TEMPLATE_JSON missing — skipping"; exit 0; }
if [ ! -r "$TEMPLATE_JSON" ]; then
  echo "ERR template-plugins-check: $TEMPLATE_JSON exists but is unreadable — refusing to skip (fail-closed)." >&2
  exit 1
fi

fail=0

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
  fail=1
fi

# Every "<plugin>@<marketplace>" suffix in enabledPlugins vs. every registered
# extraKnownMarketplaces key. comm -13: lines only in set 2 (enabled suffixes),
# not in set 1 (known marketplaces) — both sorted first, comm's own requirement.
known_markets="$(jq -r '.extraKnownMarketplaces // {} | keys[]' "$TEMPLATE_JSON" | tr -d '\r' | sort -u)"
enabled_suffixes="$(jq -r '.enabledPlugins // {} | keys[]' "$TEMPLATE_JSON" | sed 's/.*@//' | tr -d '\r' | sort -u)"
unregistered="$(comm -13 <(printf '%s\n' "$known_markets") <(printf '%s\n' "$enabled_suffixes") | sed '/^$/d')"

if [ -n "$unregistered" ]; then
  echo "ERR template-plugins-check: enabledPlugins names a marketplace with no extraKnownMarketplaces entry:" >&2
  printf '%s\n' "$unregistered" | sed 's/^/  /' >&2
  echo "    install-plugins.sh registers marketplaces from extraKnownMarketplaces, THEN installs" >&2
  echo "    every enabledPlugins key — an unregistered marketplace's plugins can never install." >&2
  echo "    Add \"<marketplace>\": { \"source\": {...}, \"autoUpdate\": true } to extraKnownMarketplaces." >&2
  fail=1
fi

[ "$fail" -eq 0 ] || exit 1

echo "template-plugins-check: all locally-vendored @himmel plugins present, all enabledPlugins marketplaces registered"
