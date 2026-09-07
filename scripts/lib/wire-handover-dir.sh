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

  printf '%s' "$base" | jq --arg hdir "$hdir_fwd" \
    '.env = ((.env // {}) + { HANDOVER_DIR: $hdir })' \
    > "$settings.handoverdir.tmp" && mv "$settings.handoverdir.tmp" "$settings"
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
