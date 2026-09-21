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

# HIMMEL-3332: record the settings write in the install-provenance ledger
# (docs/internals/install-provenance.md). Runs after the mv with the PRE-write
# JSON in $2: a new key is `create`, the same value is `noop`, a different one
# is `replace` with the prior value backed up. A wire that had to create `.env`
# also records `/env`, so uninstall may drop the emptied parent.
# shellcheck source=scripts/lib/provenance.sh
. "$(dirname "${BASH_SOURCE[0]}")/provenance.sh"

# user when the settings file sits in the Claude config dir, else project.
_wire_luna_vault_scope() {
  local d c
  d="$(cd "$(dirname "$1")" && pwd -P)"
  for c in "${CLAUDE_CONFIG_DIR:-}" "$HOME/.claude"; do
    if [ -n "$c" ] && [ "$d" = "$(cd "$c" 2>/dev/null && pwd -P)" ]; then echo user; return 0; fi
  done
  echo project
}

# _wire_luna_vault_record <settings> <pre-write settings JSON> <env key> <value>
_wire_luna_vault_record() {
  local settings="$1" base="$2" key="$3" val="$4" scope new old op had_env
  local -a pre
  scope="$(_wire_luna_vault_scope "$settings")" || return 1
  new="$(jq -nc --arg v "$val" '$v')"
  had_env="$(printf '%s' "$base" | jq -r 'if .env == null then "0" else "1" end')"
  old="$(printf '%s' "$base" | jq -c --arg k "$key" 'select((.env | type == "object") and (.env | has($k))) | .env[$k]')"
  if [ -z "$old" ]; then op=create; pre=(--pre-absent)
  elif [ "$(printf '%s' "$old" | jq -cS .)" = "$new" ]; then op=noop; pre=(--pre-json "$old")
  else op=replace; pre=(--pre-json "$old" --backup); fi
  if [ "$had_env" = 0 ]; then
    prov_record create json-key "$settings" --unit /env --scope "$scope" --class code \
      --row "$scope-settings" --writer wire-luna-vault.sh --pre-absent \
      --post-json "$(jq -c .env "$settings")" || return 1
  fi
  prov_record "$op" json-key "$settings" --unit "/env/$key" --scope "$scope" --class code \
    --row "$scope-settings" --writer wire-luna-vault.sh "${pre[@]}" --post-json "$new"
}

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

  if printf '%s' "$base" | jq --arg vault "$vault_fwd" \
    '.env = ((.env // {}) + { LUNA_VAULT_PATH: $vault })' \
    > "$settings.lunavault.tmp" && mv "$settings.lunavault.tmp" "$settings"; then
    _wire_luna_vault_record "$settings" "$base" LUNA_VAULT_PATH "$vault_fwd" \
      || echo "wire-luna-vault: warning: provenance record failed (env.LUNA_VAULT_PATH is wired; uninstall will keep it)" >&2
  else
    return 1   # the write failed: never echo success (matches the pre-record `&&` under set -e)
  fi
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
