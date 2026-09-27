#!/usr/bin/env bash
# unwire-hud-config.sh -- remove the claude-hud config himmel wrote (the inverse
# of the config drop in wire-statusline.sh; HIMMEL-3251):
# ${CLAUDE_CONFIG_DIR:-~/.claude}/plugins/claude-hud/config.json.
#
# Usage:
#   bash unwire-hud-config.sh <config-json-path> [dry_run] [himmel_root]
#
# Acts ONLY when display.customLineCommand runs himmel's hud-custom-lines.sh --
# the one field himmel's template sets that an operator's own hud config would
# not -- AND (HIMMEL-3334 I2, console ruling on judge J1269C) the file is
# byte-identical to himmel's own shipped template once substituted. This is
# the no-ledger fallback (no provenance row to ask instead), so a operator-
# added key alongside himmel's customLineCommand is kept, not lost with the
# rest of the file. Any other file (own config, unparseable) is left
# untouched and says why. Only config.json goes: the hud's runtime cache
# beside it is the plugin's own.
# ponytail: the byte-identity check compares against the plain template only,
# not the optional HIMMEL_STATUSLINE_ECON prefix wire-statusline.sh may have
# carried forward -- a prefixed-but-otherwise-himmel's-own file is kept
# rather than removed; HIMMEL-3334 follow-up if that false negative matters.
#
# Requires jq. Source it to call unwire_hud_config directly, or invoke via bash.
set -euo pipefail

# Also read by uninstall.sh's read-back so the two cannot drift.
# Anchored to the exact command shape wire-statusline.sh writes (the template's
# `bash "<path>/scripts/statusline/hud-custom-lines.sh"`, optionally behind the
# HIMMEL-3157 HIMMEL_STATUSLINE_ECON=<alnum> prefix), so an operator command that
# merely MENTIONS the script is never taken for himmel's.
_UNWIRE_HUD_PAT='^(HIMMEL_STATUSLINE_ECON=[A-Za-z0-9]+ )?bash "[^"]*/scripts/statusline/hud-custom-lines[.]sh"$'

unwire_hud_config() {
  local cfg="$1" dry="${2:-0}" himmel_root="${3:-}"
  command -v jq >/dev/null 2>&1 || { echo "unwire-hud-config: jq required" >&2; return 1; }
  if [ ! -e "$cfg" ] && [ ! -L "$cfg" ]; then
    echo "  no $cfg -- nothing to remove"
    return 0
  fi
  if ! jq -e --arg re "$_UNWIRE_HUD_PAT" '((.display.customLineCommand? // "") | tostring | test($re))' "$cfg" >/dev/null 2>&1; then
    echo "  kept $cfg -- not himmel's (no himmel customLineCommand, or not valid JSON)"
    return 0
  fi
  if [ -n "$himmel_root" ]; then
    local himmel_fwd="${himmel_root//\\//}"
    local hud_src="${himmel_fwd}/marketplace/plugins/claude-hud/config/himmel-config.json"
    if [ -f "$hud_src" ]; then
      local expected actual
      expected="$(cat "$hud_src")"
      expected="${expected//<himmel-path>/$himmel_fwd}"
      actual="$(cat "$cfg")"
      if [ "$actual" != "$expected" ]; then
        echo "  kept $cfg -- edited, not himmel's own template"
        return 0
      fi
    fi
  fi
  if [ "$dry" = "1" ]; then
    echo "DRY: would remove himmel hud config $cfg"
    return 0
  fi
  rm -f -- "$cfg" || return 1
  echo "  removed himmel hud config -> $cfg"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  if [ "$#" -lt 1 ] || [ "$#" -gt 3 ]; then
    echo "usage: unwire-hud-config.sh <config-json-path> [dry_run] [himmel_root]" >&2
    exit 2
  fi
  unwire_hud_config "$@"
fi
