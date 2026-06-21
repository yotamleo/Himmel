#!/usr/bin/env bash
# unwire-luna-vault.sh -- remove env.LUNA_VAULT_PATH from a Claude Code
# settings.json (the inverse of wire-luna-vault.sh; HIMMEL install/uninstall
# symmetry). Written by `adopt --profile luna/all`, so this matters for
# luna-scaffolded installs. All other env keys are preserved; an env object left
# empty is pruned.
#
# Usage:
#   bash unwire-luna-vault.sh <settings-json-path>
#
# Idempotent (absent key / absent file -> no-op), atomic (temp file + mv),
# refuses invalid JSON, preserves all sibling keys. Requires jq. Source it to
# call unwire_luna_vault directly, or invoke via bash.
set -euo pipefail

unwire_luna_vault() {
  local settings="$1"
  command -v jq >/dev/null 2>&1 || { echo "unwire-luna-vault: jq required" >&2; return 1; }
  [ -f "$settings" ] || return 0
  local base
  base=$(cat "$settings")
  [ -z "$(printf '%s' "$base" | tr -d '[:space:]')" ] && return 0
  if ! printf '%s' "$base" | jq -e . >/dev/null 2>&1; then
    echo "unwire-luna-vault: $settings is not valid JSON -- refusing to modify" >&2
    return 1
  fi
  printf '%s' "$base" | jq '
    del(.env.LUNA_VAULT_PATH)
    | if (has("env") and (.env == {})) then del(.env) else . end
  ' > "$settings.unwirelv.tmp" && mv "$settings.unwirelv.tmp" "$settings"
  echo "  removed env.LUNA_VAULT_PATH (if present) -> $settings"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  [ "$#" -eq 1 ] || { echo "usage: unwire-luna-vault.sh <settings-json-path>" >&2; exit 2; }
  unwire_luna_vault "$1"
fi
