#!/usr/bin/env bash
# bus-deliver-sessionstart.sh — SessionStart mirror of bus-deliver-hook.sh
# (HIMMEL-4828). A resumed or fresh session gets any waiting bus mail up front
# instead of at its first tool call. Same gate, same worker, same cursor: the
# worker reads hook_event_name from stdin and prints plain text for SessionStart,
# so a record delivered here is never re-delivered by the PostToolUse hook.
# Dark unless HIMMEL_BUS_NAME is set; fails open, always exit 0.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 0
bash "$HERE/bus-deliver-hook.sh"
exit 0
