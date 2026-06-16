#!/usr/bin/env bash
# Open a new Warp window or tab at a specific directory, optionally pre-loading
# a command. Quiet-mode default: prints one OK/ERR line and a log path.
#
# Usage:
#   ./scripts/open-in-warp.sh <directory> [--verbose] [-- <command...>]
#
# Examples:
#   ./scripts/open-in-warp.sh .claude/worktrees/feat+squash-merge-detection
#   ./scripts/open-in-warp.sh ~/my-repo -- npm test
#
# Override the binary location via WARP_EXE env var.
set -euo pipefail

usage() {
    echo "Usage: $0 <directory> [--verbose] [-- <command...>]" >&2
    exit 2
}

[ $# -lt 1 ] && usage

DIR=""
VERBOSE=0
CMD=""
while [ $# -gt 0 ]; do
    case "$1" in
        --verbose|-v) VERBOSE=1; shift ;;
        -h|--help) usage ;;
        --) shift; CMD="$*"; break ;;
        -*) echo "Unknown flag: $1" >&2; usage ;;
        *)
            if [ -z "$DIR" ]; then DIR="$1"; shift
            else echo "ERR open-in-warp: unexpected positional arg: $1" >&2; usage; fi
            ;;
    esac
done

[ -z "$DIR" ] && usage

LOG="${TMPDIR:-/tmp}/open-in-warp-$(date +%Y%m%d-%H%M%S)-$$.log"

if [ ! -d "$DIR" ]; then
    echo "ERR open-in-warp: directory does not exist: $DIR" >&2
    exit 1
fi

WARP_EXE="${WARP_EXE:-${LOCALAPPDATA:-$HOME/AppData/Local}/Programs/Warp/warp.exe}"
if [ -n "${MSYSTEM:-}" ] && [[ "$WARP_EXE" == /c/* ]]; then
    WARP_EXE="C:${WARP_EXE#/c}"
fi
if [ ! -f "$WARP_EXE" ]; then
    echo "ERR open-in-warp: warp.exe not found at $WARP_EXE (override with WARP_EXE=...)" >&2
    exit 1
fi

# Group the alternation so the trailing `pwd` doesn't run unconditionally and
# concatenate two paths into ABS_DIR (left-associative && / || gotcha on bash).
ABS_DIR=$( (cd "$DIR" && pwd -W) 2>/dev/null || (cd "$DIR" && pwd) )

# warp:// deep-link scheme: new_tab with path + optional command.
if [ -n "$CMD" ]; then
    ENCODED=$(printf '%s' "$CMD" | sed 's/%/%25/g; s/ /%20/g; s/&/%26/g')
    URI="warp://action/new_tab?path=${ABS_DIR// /%20}&command=${ENCODED}"
else
    URI="warp://action/new_tab?path=${ABS_DIR// /%20}"
fi

{
    echo "=== open-in-warp $(date -Iseconds) ==="
    echo "dir=$ABS_DIR"
    echo "cmd=$CMD"
    echo "uri=$URI"
} >>"$LOG"

if command -v cmd >/dev/null 2>&1; then
    if [ $VERBOSE -eq 1 ]; then
        cmd //c start "" "$URI" 2>&1 | tee -a "$LOG"
    else
        cmd //c start "" "$URI" >>"$LOG" 2>&1 || {
            echo "ERR open-in-warp: failed to launch (log: $LOG)" >&2
            exit 1
        }
    fi
else
    "$WARP_EXE" "$URI" >>"$LOG" 2>&1 &
fi

CMD_SUFFIX=""
[ -n "$CMD" ] && CMD_SUFFIX=" cmd=\"$CMD\""
echo "OK open-in-warp: $ABS_DIR${CMD_SUFFIX} (log: $LOG)"
