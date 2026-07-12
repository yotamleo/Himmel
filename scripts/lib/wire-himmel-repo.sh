#!/usr/bin/env bash
# wire-himmel-repo.sh -- set env.HIMMEL_REPO in a Claude Code settings.json to
# the himmel clone path (HIMMEL-453). The leg resolver + minerva transport anchor
# to HIMMEL_REPO (marketplace/plugins/himmel-ops/scripts/legs.sh); setup.sh and
# adopt.sh call this so it is set without a manual export. Sibling of
# wire-statusline.sh -- same shape, different key.
#
# Usage:
#   bash wire-himmel-repo.sh <settings-json-path> <himmel-path>
#
# Sets:
#   .env.HIMMEL_REPO = "<himmel-path forward-slashed>"   (all other .env keys
#   preserved -- HIMMEL_INITIATIVE etc. are never clobbered).
#
# Idempotent (re-setting the same value is a no-op), atomic (temp file + mv),
# non-destructive (other keys preserved; file + parent dir created if absent).
# Requires jq. Invoked via bash, never sourced.
set -euo pipefail

wire_himmel_repo() {
  local settings="$1" himmel="$2"
  command -v jq >/dev/null 2>&1 || { echo "wire-himmel-repo: jq required" >&2; return 1; }

  # Forward-slash the himmel path so the stored value is a valid Git-Bash path
  # even when a caller passes a Windows backslash path.
  local himmel_fwd="${himmel//\\//}"

  mkdir -p "$(dirname "$settings")"
  local base="{}"
  if [ -s "$settings" ]; then
    base=$(cat "$settings")
    # An empty / whitespace-only file -> treat as {} (jq would choke on it).
    # A non-empty but INVALID file -> refuse, rather than clobber data.
    if [ -z "$(printf '%s' "$base" | tr -d '[:space:]')" ]; then
      base="{}"
    elif ! printf '%s' "$base" | jq -e . >/dev/null 2>&1; then
      echo "wire-himmel-repo: $settings is not valid JSON -- refusing to overwrite" >&2
      return 1
    fi
  fi

  printf '%s' "$base" | jq --arg repo "$himmel_fwd" \
    '.env = ((.env // {}) + { HIMMEL_REPO: $repo })' \
    > "$settings.himmelrepo.tmp" && mv "$settings.himmelrepo.tmp" "$settings"
  echo "  set env.HIMMEL_REPO -> $settings"
}

# Allow both `source wire-himmel-repo.sh` (to call wire_himmel_repo directly) and
# direct invocation `bash wire-himmel-repo.sh <settings> <himmel>`.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  if [ "$#" -ne 2 ]; then
    echo "usage: wire-himmel-repo.sh <settings-json-path> <himmel-path>" >&2
    exit 2
  fi
  wire_himmel_repo "$1" "$2"
fi
