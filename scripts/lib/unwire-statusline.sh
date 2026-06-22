#!/usr/bin/env bash
# unwire-statusline.sh -- remove the himmel statusLine from a Claude Code
# settings.json (the inverse of wire-statusline.sh; HIMMEL install/uninstall
# symmetry). Removes .statusLine ONLY when it points at the himmel statusline
# binary -- a user's own custom statusLine is left untouched.
#
# Usage:
#   bash unwire-statusline.sh <settings-json-path>
#
# Idempotent (absent key / absent file -> no-op), atomic (temp file + mv),
# refuses invalid JSON, preserves all sibling keys. Requires jq. Source it to
# call unwire_statusline directly, or invoke via bash.
set -euo pipefail

unwire_statusline() {
  local settings="$1"
  command -v jq >/dev/null 2>&1 || { echo "unwire-statusline: jq required" >&2; return 1; }
  [ -f "$settings" ] || return 0
  local base
  base=$(cat "$settings")
  [ -z "$(printf '%s' "$base" | tr -d '[:space:]')" ] && return 0
  if ! printf '%s' "$base" | jq -e . >/dev/null 2>&1; then
    echo "unwire-statusline: $settings is not valid JSON -- refusing to modify" >&2
    return 1
  fi
  # Match either the himmel wrapper (scripts/where-are-we/statusline.sh,
  # HIMMEL-538) or the older vendored path (scripts/statusline/bin/statusline.sh,
  # for sessions wired before the wrapper landed) — both are "the himmel
  # statusLine". A user's own custom statusLine matches neither and is left alone.
  printf '%s' "$base" | jq '
    if ((.statusLine.command? // "") | test("scripts/(statusline/bin/statusline|where-are-we/statusline)[.]sh"))
    then del(.statusLine) else . end
  ' > "$settings.unwiresl.tmp" && mv "$settings.unwiresl.tmp" "$settings"
  echo "  removed himmel statusLine (if present) -> $settings"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  [ "$#" -eq 1 ] || { echo "usage: unwire-statusline.sh <settings-json-path>" >&2; exit 2; }
  unwire_statusline "$1"
fi
