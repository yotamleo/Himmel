#!/usr/bin/env bash
# reap-mcp-fleet.sh (HIMMEL-741) - thin twin of reap-mcp-fleet.ps1.
#
# The Codex MCP-fleet flood is a Windows-process-tree problem (Win32_Process
# ancestry walk). The real logic lives in the .ps1; on Windows this forwards to
# pwsh, on every other platform it is a no-op (nothing to reap - Codex on
# mac/Linux reaps its own children). Kept only to satisfy the .ps1/.sh twin
# convention and give a stable cross-platform entrypoint.
#
#   scripts/codex/reap-mcp-fleet.sh          # report-only (default)
#   scripts/codex/reap-mcp-fleet.sh --kill   # forwards -Kill to the .ps1
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PS1="$SCRIPT_DIR/reap-mcp-fleet.ps1"

case "${OSTYPE:-$(uname -s 2>/dev/null || echo unknown)}" in
  msys*|cygwin*|win32*|MINGW*|MSYS*) ;;
  *)
    echo "[reap-mcp-fleet] non-Windows platform - the Codex MCP-fleet flood is Windows-only; nothing to do."
    exit 0
    ;;
esac

PWSH_BIN=""
for c in pwsh pwsh.exe powershell.exe; do
  if command -v "$c" >/dev/null 2>&1; then PWSH_BIN="$c"; break; fi
done
if [ -z "$PWSH_BIN" ]; then
  echo "ERR: pwsh not found on PATH - run scripts/codex/reap-mcp-fleet.ps1 directly." >&2
  exit 1
fi

PS_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --kill) PS_ARGS+=("-Kill") ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ERR: unknown argument: $arg" >&2; exit 1 ;;
  esac
done

# Guard the empty-array expansion (bash 3.2 + set -u treats "${a[@]}" on an
# empty array as an unbound variable).
exec "$PWSH_BIN" -NoProfile -ExecutionPolicy Bypass -File "$PS1" ${PS_ARGS[@]+"${PS_ARGS[@]}"}
