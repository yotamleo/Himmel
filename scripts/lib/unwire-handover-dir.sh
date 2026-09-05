#!/usr/bin/env bash
# unwire-handover-dir.sh -- remove env.HANDOVER_DIR from a Claude Code
# settings.json (the inverse of wire-handover-dir.sh; HIMMEL install/uninstall
# symmetry). Written by `adopt --profile luna/all`, so this matters for
# luna-scaffolded installs. All other env keys are preserved; an env object
# left empty is pruned.
#
# Usage:
#   bash unwire-handover-dir.sh <settings-json-path>
#
# Idempotent (absent key / absent file -> no-op), atomic (temp file + mv),
# refuses invalid JSON, preserves all sibling keys. Requires jq. Source it to
# call unwire_handover_dir directly, or invoke via bash.
set -euo pipefail

unwire_handover_dir() {
  local settings="$1"
  command -v jq >/dev/null 2>&1 || { echo "unwire-handover-dir: jq required" >&2; return 1; }
  [ -f "$settings" ] || return 0
  local base
  base=$(cat "$settings")
  [ -z "$(printf '%s' "$base" | tr -d '[:space:]')" ] && return 0
  if ! printf '%s' "$base" | jq -e . >/dev/null 2>&1; then
    echo "unwire-handover-dir: $settings is not valid JSON -- refusing to modify" >&2
    return 1
  fi
  printf '%s' "$base" | jq '
    del(.env.HANDOVER_DIR)
    | if (has("env") and (.env == {})) then del(.env) else . end
  ' > "$settings.unwirehd.tmp" && mv "$settings.unwirehd.tmp" "$settings"
  echo "  removed env.HANDOVER_DIR (if present) -> $settings"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  [ "$#" -eq 1 ] || { echo "usage: unwire-handover-dir.sh <settings-json-path>" >&2; exit 2; }
  unwire_handover_dir "$1"
fi
