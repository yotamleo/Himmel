#!/usr/bin/env bash
# wire-statusline.sh — single source of truth for wiring the himmel statusLine
# into a Claude Code settings.json (HIMMEL-359). Used by adopt.sh, setup.sh,
# and machine-setup/ubuntu.sh so the command string + merge logic live in one
# place instead of being duplicated per installer.
#
# Usage:
#   bash wire-statusline.sh <settings-json-path> <himmel-path>
#
# Sets:
#   .statusLine = { type: "command",
#                   command: "bash \"<himmel>/scripts/statusline/bin/statusline.sh\"" }
#
# Idempotent (re-setting the same value is a no-op), atomic (temp file + mv),
# and non-destructive (all other keys preserved; file + parent dir created if
# absent). Requires jq. The statusline binary is referenced by absolute path —
# it is vendored in the himmel clone, never copied per-repo.
set -euo pipefail

wire_statusline() {
  local settings="$1" himmel="$2"
  command -v jq >/dev/null 2>&1 || { echo "wire-statusline: jq required" >&2; return 1; }

  # Forward-slash the himmel path so the `bash "..."` command is valid even
  # when a caller passes a Windows backslash path (Git Bash tolerates /c/... ).
  local himmel_fwd="${himmel//\\//}"
  local cmd="bash \"${himmel_fwd}/scripts/statusline/bin/statusline.sh\""

  mkdir -p "$(dirname "$settings")"
  local base="{}"
  if [ -s "$settings" ]; then
    base=$(cat "$settings")
    # An empty / whitespace-only file → treat as {} (jq would choke on it).
    # A non-empty but INVALID file → refuse, rather than clobber data.
    if [ -z "$(printf '%s' "$base" | tr -d '[:space:]')" ]; then
      base="{}"
    elif ! printf '%s' "$base" | jq -e . >/dev/null 2>&1; then
      echo "wire-statusline: $settings is not valid JSON — refusing to overwrite" >&2
      return 1
    fi
  fi

  printf '%s' "$base" | jq --arg cmd "$cmd" \
    '.statusLine = { type: "command", command: $cmd }' \
    > "$settings.statusline.tmp" && mv "$settings.statusline.tmp" "$settings"
  echo "  wired statusLine → $settings"
}

# Allow both `source wire-statusline.sh` (to call wire_statusline directly) and
# direct invocation `bash wire-statusline.sh <settings> <himmel>`.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  if [ "$#" -ne 2 ]; then
    echo "usage: wire-statusline.sh <settings-json-path> <himmel-path>" >&2
    exit 2
  fi
  wire_statusline "$1" "$2"
fi
