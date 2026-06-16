#!/usr/bin/env bash
# overnight/stop-marker — graceful-halt marker for /overnight-shift sessions.
#
# HIMMEL-137 (HIMMEL-32 child). The marker file is what `/overnight-shift`
# (and the overnight-mode runbook Phase 3 impl loop) polls between
# dispatches. When set, the dispatcher finishes the in-flight subagent +
# halts before starting the next one. No subprocess kills — graceful only.
# `/stop --hard` is a Claude-side action handled in the slash command body
# (calls TaskStop on in-flight subagents); this script handles the marker
# lifecycle only.
#
# Marker path: ~/.claude/.overnight-stop (single file, no content needed —
# existence is the signal). Stored under $HOME so it survives worktree
# pruning + cd between repos.
#
# Subcommands:
#   set     Touch the marker. Idempotent (no-op if already set).
#   check   Exit 0 if marker exists, 1 otherwise. Silent (script-friendly).
#   clear   Remove the marker. Idempotent. Aliases: reset, rm.
#   status  Print human-readable state to stdout. Always exits 0.
#
# Exit codes:
#   0  command succeeded (or check found marker present)
#   1  check found marker absent
#   2  usage / unknown subcommand
#   3  filesystem error (can't create/remove)
set -uo pipefail

MARKER_DIR="${OVERNIGHT_STOP_DIR:-$HOME/.claude}"
MARKER_PATH="$MARKER_DIR/.overnight-stop"

usage() {
    cat <<'EOF'
Usage: stop-marker.sh <set|check|clear|status>

Manages the ~/.claude/.overnight-stop marker file used by
/overnight-shift's dispatch loop. When set, the dispatcher halts
gracefully before the next subagent dispatch.

Subcommands:
  set       Touch the marker (idempotent).
  check     Silent. Exit 0 if marker exists, 1 otherwise.
  clear     Remove the marker (idempotent). Aliases: reset, rm.
  status    Print human-readable state. Always exits 0.

Environment:
  OVERNIGHT_STOP_DIR    Override marker directory. Default: $HOME/.claude.
EOF
}

cmd="${1:-}"
if [ -z "$cmd" ]; then
    usage >&2
    exit 2
fi

case "$cmd" in
    set)
        if ! mkdir -p "$MARKER_DIR" 2>/dev/null; then
            echo "ERR stop-marker: cannot create $MARKER_DIR" >&2
            exit 3
        fi
        if ! : > "$MARKER_PATH" 2>/dev/null; then
            echo "ERR stop-marker: cannot write $MARKER_PATH" >&2
            exit 3
        fi
        date -u +"%Y-%m-%dT%H:%M:%SZ" > "$MARKER_PATH" 2>/dev/null || true
        echo "stop-marker: SET at $MARKER_PATH"
        ;;
    check)
        [ -f "$MARKER_PATH" ] && exit 0 || exit 1
        ;;
    clear|reset|rm)
        if [ -f "$MARKER_PATH" ]; then
            if ! rm -f "$MARKER_PATH" 2>/dev/null; then
                echo "ERR stop-marker: cannot remove $MARKER_PATH" >&2
                exit 3
            fi
            echo "stop-marker: CLEARED $MARKER_PATH"
        else
            echo "stop-marker: already clear (no marker at $MARKER_PATH)"
        fi
        ;;
    status)
        if [ -f "$MARKER_PATH" ]; then
            ts=$(cat "$MARKER_PATH" 2>/dev/null || echo "?")
            echo "stop-marker: SET ($MARKER_PATH; armed at $ts)"
        else
            echo "stop-marker: CLEAR (no marker at $MARKER_PATH)"
        fi
        ;;
    -h|--help)
        usage
        ;;
    *)
        echo "ERR stop-marker: unknown subcommand '$cmd'" >&2
        usage >&2
        exit 2
        ;;
esac
exit 0
