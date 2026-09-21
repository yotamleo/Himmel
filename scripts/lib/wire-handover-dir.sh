#!/usr/bin/env bash
# wire-handover-dir.sh -- set env.HANDOVER_DIR in a Claude Code settings.json
# to the handover state root (HIMMEL-839). handover_root()
# (scripts/lib/handover-path.sh) reads HANDOVER_DIR straight from the process
# env, so wiring it into settings.json's env stanza makes Mode B (external
# state repo) resolve correctly for every session under this scope, without a
# manual .env edit or shell export. adopt.sh calls this after scaffolding the
# luna vault (--profile luna|all) so a fresh adopter's handover state lands in
# the vault instead of silently defaulting to the inline <repo-root>/handovers/
# stub (observed on a fresh ubuntu_new install with no prior state, HIMMEL-839
# defect 2). Sibling of wire-luna-vault.sh -- same shape, different key.
#
# Usage:
#   bash wire-handover-dir.sh <settings-json-path> <handover-dir>
#
# Sets:
#   .env.HANDOVER_DIR = "<handover-dir forward-slashed>"   (all other .env keys
#   preserved -- LUNA_VAULT_PATH / HIMMEL_REPO etc. are never clobbered).
#
# Idempotent (re-setting the same value is a no-op), atomic (temp file + mv),
# non-destructive (other keys preserved; file + parent dir created if absent).
# Requires jq. Source it to call wire_handover_dir directly, or invoke via bash
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
_wire_handover_dir_scope() {
  local d c
  d="$(cd "$(dirname "$1")" && pwd -P)"
  for c in "${CLAUDE_CONFIG_DIR:-}" "$HOME/.claude"; do
    if [ -n "$c" ] && [ "$d" = "$(cd "$c" 2>/dev/null && pwd -P)" ]; then echo user; return 0; fi
  done
  echo project
}

# _wire_handover_dir_record <settings> <pre-write settings JSON> <env key> <value>
_wire_handover_dir_record() {
  local settings="$1" base="$2" key="$3" val="$4" scope new old op had_env
  local -a pre
  scope="$(_wire_handover_dir_scope "$settings")" || return 1
  new="$(jq -nc --arg v "$val" '$v')"
  had_env="$(printf '%s' "$base" | jq -r 'if .env == null then "0" else "1" end')"
  old="$(printf '%s' "$base" | jq -c --arg k "$key" 'select((.env | type == "object") and (.env | has($k))) | .env[$k]')"
  if [ -z "$old" ]; then op=create; pre=(--pre-absent)
  elif [ "$(printf '%s' "$old" | jq -cS .)" = "$new" ]; then op=noop; pre=(--pre-json "$old")
  else op=replace; pre=(--pre-json "$old" --backup); fi
  if [ "$had_env" = 0 ]; then
    prov_record create json-key "$settings" --unit /env --scope "$scope" --class code \
      --row "$scope-settings" --writer wire-handover-dir.sh --pre-absent \
      --post-json "$(jq -c .env "$settings")" || return 1
  fi
  prov_record "$op" json-key "$settings" --unit "/env/$key" --scope "$scope" --class code \
    --row "$scope-settings" --writer wire-handover-dir.sh "${pre[@]}" --post-json "$new"
}

wire_handover_dir() {
  local settings="$1" hdir="$2"
  command -v jq >/dev/null 2>&1 || { echo "wire-handover-dir: jq required" >&2; return 1; }

  # Forward-slash the path so the stored value is a valid Git-Bash path even
  # when a caller passes a Windows backslash path.
  local hdir_fwd="${hdir//\\//}"

  mkdir -p "$(dirname "$settings")"
  local base="{}"
  if [ -s "$settings" ]; then
    base=$(cat "$settings")
    # An empty / whitespace-only file -> treat as {} (jq would choke on it).
    # A non-empty but INVALID file -> refuse, rather than clobber data.
    if [ -z "$(printf '%s' "$base" | tr -d '[:space:]')" ]; then
      base="{}"
    elif ! printf '%s' "$base" | jq -e . >/dev/null 2>&1; then
      echo "wire-handover-dir: $settings is not valid JSON -- refusing to overwrite" >&2
      return 1
    fi
  fi

  if printf '%s' "$base" | jq --arg hdir "$hdir_fwd" \
    '.env = ((.env // {}) + { HANDOVER_DIR: $hdir })' \
    > "$settings.handoverdir.tmp" && mv "$settings.handoverdir.tmp" "$settings"; then
    _wire_handover_dir_record "$settings" "$base" HANDOVER_DIR "$hdir_fwd" \
      || echo "wire-handover-dir: warning: provenance record failed (env.HANDOVER_DIR is wired; uninstall will keep it)" >&2
  fi
  echo "  set env.HANDOVER_DIR -> $settings"
}

# Allow both `source wire-handover-dir.sh` (to call wire_handover_dir directly)
# and direct invocation `bash wire-handover-dir.sh <settings> <handover-dir>`.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  if [ "$#" -ne 2 ]; then
    echo "usage: wire-handover-dir.sh <settings-json-path> <handover-dir>" >&2
    exit 2
  fi
  wire_handover_dir "$1" "$2"
fi
