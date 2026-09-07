#!/usr/bin/env bash
# agent-runtime-census.sh (HIMMEL-1988) - thin launcher for the report-only
# Windows agent-runtime census (agent-runtime-census.ps1).
#
# The census reads Win32_Process, the Windows memory performance counters and
# poolmon - all Windows-only surfaces - so there is no non-Windows twin to
# fall back to (unlike reap-mcp-fleet.sh, whose descendant walk is portable).
# On any other platform this exits non-zero with that message rather than
# pretending to have collected evidence.
#
# Every argument is forwarded verbatim to the .ps1, e.g.
#   scripts/observability/agent-runtime-census.sh -Label claude-swarm
#   scripts/observability/agent-runtime-census.sh -Label codex -Loop -IntervalSec 300 -MaxSnapshots 12
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PS1_PATH="$SCRIPT_DIR/agent-runtime-census.ps1"

case "${OSTYPE:-$(uname -s 2>/dev/null || echo unknown)}" in
    msys*|cygwin*|win32*|MINGW*|MSYS*) ;;
    *)
        echo "ERR agent-runtime-census: Windows-only (Win32_Process + Get-Counter + poolmon). Nothing was collected." >&2
        exit 2
        ;;
esac

PWSH_BIN=""
for c in powershell.exe pwsh pwsh.exe; do
    if command -v "$c" >/dev/null 2>&1; then PWSH_BIN="$c"; break; fi
done
if [ -z "$PWSH_BIN" ]; then
    echo "ERR agent-runtime-census: no powershell/pwsh on PATH - run $PS1_PATH directly." >&2
    exit 2
fi

if command -v cygpath >/dev/null 2>&1; then
    PS1_PATH="$(cygpath -w "$PS1_PATH")"
fi

"$PWSH_BIN" -NoProfile -ExecutionPolicy Bypass -File "$PS1_PATH" "$@"
