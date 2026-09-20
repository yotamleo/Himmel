#!/usr/bin/env bash
# unwire-hud-config.sh -- remove the claude-hud config himmel wrote (the inverse
# of the config drop in wire-statusline.sh; HIMMEL-3251):
# ${CLAUDE_CONFIG_DIR:-~/.claude}/plugins/claude-hud/config.json.
#
# Usage:
#   bash unwire-hud-config.sh <config-json-path> [dry_run]
#
# Acts ONLY when display.customLineCommand runs himmel's hud-custom-lines.sh --
# the one field himmel's template sets that an operator's own hud config would
# not. Any other file (own config, unparseable) is left untouched and says why.
# Only config.json goes: the hud's runtime cache beside it is the plugin's own.
# ponytail: an operator's hand edits to a himmel-wired config.json go with it;
# every wire-statusline run (each himmel-update) rewrites the file from the
# template already, so nothing durable is lost.
#
# Requires jq. Source it to call unwire_hud_config directly, or invoke via bash.
set -euo pipefail

# Also read by uninstall.sh's read-back so the two cannot drift.
_UNWIRE_HUD_PAT='scripts/statusline/hud-custom-lines[.]sh'

unwire_hud_config() {
  local cfg="$1" dry="${2:-0}"
  command -v jq >/dev/null 2>&1 || { echo "unwire-hud-config: jq required" >&2; return 1; }
  if [ ! -e "$cfg" ] && [ ! -L "$cfg" ]; then
    echo "  no $cfg -- nothing to remove"
    return 0
  fi
  if ! jq -e --arg re "$_UNWIRE_HUD_PAT" '((.display.customLineCommand? // "") | tostring | test($re))' "$cfg" >/dev/null 2>&1; then
    echo "  kept $cfg -- not himmel's (no himmel customLineCommand, or not valid JSON)"
    return 0
  fi
  if [ "$dry" = "1" ]; then
    echo "DRY: would remove himmel hud config $cfg"
    return 0
  fi
  rm -f -- "$cfg" || return 1
  echo "  removed himmel hud config -> $cfg"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "usage: unwire-hud-config.sh <config-json-path> [dry_run]" >&2
    exit 2
  fi
  unwire_hud_config "$@"
fi
