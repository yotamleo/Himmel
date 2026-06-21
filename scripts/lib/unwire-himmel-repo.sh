#!/usr/bin/env bash
# unwire-himmel-repo.sh -- remove env.HIMMEL_REPO from a Claude Code settings.json
# (the inverse of wire-himmel-repo.sh; HIMMEL install/uninstall symmetry). All
# other env keys (HIMMEL_INITIATIVE, LUNA_VAULT_PATH, ...) are preserved; an env
# object left empty is pruned.
#
# Usage:
#   bash unwire-himmel-repo.sh <settings-json-path>
#
# Idempotent (absent key / absent file -> no-op), atomic (temp file + mv),
# refuses invalid JSON, preserves all sibling keys. Requires jq. Source it to
# call unwire_himmel_repo directly, or invoke via bash.
set -euo pipefail

unwire_himmel_repo() {
  local settings="$1"
  command -v jq >/dev/null 2>&1 || { echo "unwire-himmel-repo: jq required" >&2; return 1; }
  [ -f "$settings" ] || return 0
  local base
  base=$(cat "$settings")
  [ -z "$(printf '%s' "$base" | tr -d '[:space:]')" ] && return 0
  if ! printf '%s' "$base" | jq -e . >/dev/null 2>&1; then
    echo "unwire-himmel-repo: $settings is not valid JSON -- refusing to modify" >&2
    return 1
  fi
  printf '%s' "$base" | jq '
    del(.env.HIMMEL_REPO)
    | if (has("env") and (.env == {})) then del(.env) else . end
  ' > "$settings.unwirehr.tmp" && mv "$settings.unwirehr.tmp" "$settings"
  echo "  removed env.HIMMEL_REPO (if present) -> $settings"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  [ "$#" -eq 1 ] || { echo "usage: unwire-himmel-repo.sh <settings-json-path>" >&2; exit 2; }
  unwire_himmel_repo "$1"
fi
