#!/usr/bin/env bash
# wire-luna-vault.sh -- set env.LUNA_VAULT_PATH in a Claude Code settings.json to
# the scaffolded luna vault path (HIMMEL-458). The end-session-wiki resolver
# reads LUNA_VAULT_PATH from the process env (scripts/lib/vault-resolve.sh step
# 3); adopt.sh calls this after scaffolding so the resolver finds the vault the
# operator actually created without a manual export. Sibling of
# wire-himmel-repo.sh -- same shape, different key.
#
# Usage:
#   bash wire-luna-vault.sh <settings-json-path> <vault-path>
#
# Sets:
#   .env.LUNA_VAULT_PATH = "<vault-path forward-slashed>"   (all other .env keys
#   preserved -- HIMMEL_REPO / HIMMEL_INITIATIVE etc. are never clobbered).
#
# Idempotent (re-setting the same value is a no-op), atomic (temp file + mv),
# non-destructive (other keys preserved; file + parent dir created if absent).
# Requires jq. Source it to call wire_luna_vault directly, or invoke via bash
# (the BASH_SOURCE guard below supports both).
set -euo pipefail

wire_luna_vault() {
  local settings="$1" vault="$2"
  command -v jq >/dev/null 2>&1 || { echo "wire-luna-vault: jq required" >&2; return 1; }

  # Forward-slash the vault path so the stored value is a valid Git-Bash path
  # even when a caller passes a Windows backslash path.
  local vault_fwd="${vault//\\//}"

  mkdir -p "$(dirname "$settings")"
  local base="{}"
  if [ -s "$settings" ]; then
    base=$(cat "$settings")
    # An empty / whitespace-only file -> treat as {} (jq would choke on it).
    # A non-empty but INVALID file -> refuse, rather than clobber data.
    if [ -z "$(printf '%s' "$base" | tr -d '[:space:]')" ]; then
      base="{}"
    elif ! printf '%s' "$base" | jq -e . >/dev/null 2>&1; then
      echo "wire-luna-vault: $settings is not valid JSON -- refusing to overwrite" >&2
      return 1
    fi
  fi

  printf '%s' "$base" | jq --arg vault "$vault_fwd" \
    '.env = ((.env // {}) + { LUNA_VAULT_PATH: $vault })' \
    > "$settings.lunavault.tmp" && mv "$settings.lunavault.tmp" "$settings"
  echo "  set env.LUNA_VAULT_PATH -> $settings"
}

# Allow both `source wire-luna-vault.sh` (to call wire_luna_vault directly) and
# direct invocation `bash wire-luna-vault.sh <settings> <vault>`.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  if [ "$#" -ne 2 ]; then
    echo "usage: wire-luna-vault.sh <settings-json-path> <vault-path>" >&2
    exit 2
  fi
  wire_luna_vault "$1" "$2"
fi
