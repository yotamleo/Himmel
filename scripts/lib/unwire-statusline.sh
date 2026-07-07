#!/usr/bin/env bash
# unwire-statusline.sh -- roll back the himmel statusLine in a Claude Code
# settings.json (the inverse of wire-statusline.sh; HIMMEL install/uninstall
# symmetry). Acts ONLY when .statusLine points at a himmel statusLine -- the hud
# renderer (marketplace/plugins/claude-hud/dist/index.js; HIMMEL-718), the
# where-are-we wrapper (HIMMEL-538), or the older vendored bar -- a user's own
# custom statusLine is left untouched.
#
# Usage:
#   bash unwire-statusline.sh <settings-json-path> [himmel-path]
#
# With a himmel path -> REPOINT .statusLine.command to the bash-bar fallback
#   (bash "<himmel>/scripts/where-are-we/statusline.sh"; the HIMMEL-718 migration
#   rollback -- the .env.CLAUDE_HUD_ALLOW_EXTRA_CMD gate is left in place, being
#   harmless when the bash bar renders).
# Without a himmel path -> REMOVE .statusLine entirely (the uninstall path).
#
# Idempotent (absent key / absent file -> no-op), atomic (temp file + mv),
# refuses invalid JSON, preserves all sibling keys. Requires jq. Source it to
# call unwire_statusline directly, or invoke via bash.
set -euo pipefail

unwire_statusline() {
  local settings="$1" himmel="${2:-}"
  command -v jq >/dev/null 2>&1 || { echo "unwire-statusline: jq required" >&2; return 1; }
  [ -f "$settings" ] || return 0
  local base
  base=$(cat "$settings")
  [ -z "$(printf '%s' "$base" | tr -d '[:space:]')" ] && return 0
  if ! printf '%s' "$base" | jq -e . >/dev/null 2>&1; then
    echo "unwire-statusline: $settings is not valid JSON -- refusing to modify" >&2
    return 1
  fi
  # Matches the himmel statusLine in any of its shapes; a user's own custom
  # statusLine matches none and is left alone.
  local match_re='marketplace/plugins/claude-hud/dist/index[.]js|scripts/(statusline/bin/statusline|where-are-we/statusline)[.]sh'
  if [ -n "$himmel" ]; then
    local himmel_fwd="${himmel//\\//}"
    local cmd="bash \"${himmel_fwd}/scripts/where-are-we/statusline.sh\""
    printf '%s' "$base" | jq --arg re "$match_re" --arg cmd "$cmd" '
      if ((.statusLine.command? // "") | test($re))
      then .statusLine.command = $cmd else . end
    ' > "$settings.unwiresl.tmp" || { rm -f "$settings.unwiresl.tmp"; return 1; }
    mv "$settings.unwiresl.tmp" "$settings" || return 1
    echo "  repointed himmel statusLine to bash-bar fallback (if present) -> $settings"
  else
    printf '%s' "$base" | jq --arg re "$match_re" '
      if ((.statusLine.command? // "") | test($re))
      then del(.statusLine) else . end
    ' > "$settings.unwiresl.tmp" || { rm -f "$settings.unwiresl.tmp"; return 1; }
    mv "$settings.unwiresl.tmp" "$settings" || return 1
    echo "  removed himmel statusLine (if present) -> $settings"
  fi
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "usage: unwire-statusline.sh <settings-json-path> [himmel-path]" >&2; exit 2
  fi
  unwire_statusline "$1" "${2:-}"
fi
