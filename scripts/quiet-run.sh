#!/usr/bin/env bash
# Run any noisy command, suppress output, print one OK/ERR line + log path.
# Use to wrap verbose commands (npm install, build, test) so they don't spam
# the session context. Caller can grep the log if more detail is needed.
#
# Usage:
#   ./scripts/quiet-run.sh <label> -- <command...>
#
# Examples:
#   ./scripts/quiet-run.sh npm-install -- npm install
#   ./scripts/quiet-run.sh pytest -- pytest -xvs tests/
set -euo pipefail

usage() {
    echo "Usage: $0 <label> -- <command...>" >&2
    exit 2
}

[ $# -lt 3 ] && usage

LABEL="$1"; shift
if [ "$1" != "--" ]; then
    echo "ERR quiet-run: expected '--' between label and command, got: $1" >&2
    usage
fi
shift

for arg in "$@"; do
    case "$arg" in
        ..|../*|*/..|*/../*)
            echo "ERR quiet-run: refusing '..' path component in argv: $arg" >&2
            exit 2
            ;;
    esac
done

if [ "$LABEL" = "suite" ] && [ "${1:-}" = "bash" ]; then
    SUITE_PATH="${2:-}"
    BASENAME="${SUITE_PATH##*/}"
    case "$BASENAME" in
        test-*.sh) : ;;
        *)
            echo "ERR quiet-run: label 'suite' requires a tracked test-*.sh, got: $SUITE_PATH" >&2
            exit 2
            ;;
    esac
    if TOPLEVEL_ERR=$(LC_ALL=C git rev-parse --show-toplevel 2>&1 1>/dev/null); then
        REPO_TOPLEVEL=$(LC_ALL=C git rev-parse --show-toplevel)
        while [ "${SUITE_PATH#./}" != "$SUITE_PATH" ]; do
            SUITE_PATH="${SUITE_PATH#./}"
        done
        # HIMMEL-3181: on Git-Bash git prints the toplevel in mixed form
        # (D:/a/repo) while a caller's absolute path is POSIX (/d/a/repo);
        # strip either. Never empty (an empty pattern would match every path).
        REPO_TOPLEVEL_POSIX="$REPO_TOPLEVEL"
        if command -v cygpath >/dev/null 2>&1; then
            REPO_TOPLEVEL_POSIX=$(cygpath -u "$REPO_TOPLEVEL" 2>/dev/null) || REPO_TOPLEVEL_POSIX="$REPO_TOPLEVEL"
            [ -n "$REPO_TOPLEVEL_POSIX" ] || REPO_TOPLEVEL_POSIX="$REPO_TOPLEVEL"
        fi
        case "$SUITE_PATH" in
            "$REPO_TOPLEVEL"/*|"$REPO_TOPLEVEL_POSIX"/*)
                case "$SUITE_PATH" in
                    "$REPO_TOPLEVEL"/*) SUITE_PATH="${SUITE_PATH#"$REPO_TOPLEVEL"/}" ;;
                    *) SUITE_PATH="${SUITE_PATH#"$REPO_TOPLEVEL_POSIX"/}" ;;
                esac
                TRACKED_MATCH=$(git -C "$REPO_TOPLEVEL" --literal-pathspecs ls-files -- "$SUITE_PATH" 2>/dev/null)
                ;;
            *)
                TRACKED_MATCH=$(git --literal-pathspecs ls-files -- "$SUITE_PATH" 2>/dev/null)
                ;;
        esac
        if [ "$TRACKED_MATCH" != "$SUITE_PATH" ]; then
            echo "ERR quiet-run: label 'suite' requires a tracked test-*.sh, got: $SUITE_PATH" >&2
            exit 2
        fi
    else
        case "$TOPLEVEL_ERR" in
            *"not a git repository (or any"*)
                echo "quiet-run: not a git repo — skipping tracked-file check for label 'suite'" >&2
                ;;
            *)
                echo "ERR quiet-run: label 'suite' tracked-file check failed unexpectedly: $TOPLEVEL_ERR" >&2
                exit 2
                ;;
        esac
    fi
fi

LOG="${TMPDIR:-/tmp}/quiet-run-${LABEL}-$(date +%Y%m%d-%H%M%S)-$$.log"

{
    echo "=== quiet-run $LABEL @ $(date -Iseconds) ==="
    echo "cmd=$*"
    echo ""
} >>"$LOG"

# HIMMEL-2221: a wrapper that dies leaves its command (and everything that
# command spawned) running with no owning session. Run the command as its own
# process group (`set -m`; unlike a bare `&` it keeps stdin) and, on
# TERM/INT/HUP, reap that whole group before exiting 128+signal.
# ponytail: SIGKILL of the wrapper itself cannot be trapped, so a kill -9'd
# quiet-run still orphans its command; and a command that calls setsid/setpgid
# leaves the group and escapes the reap.
# shellcheck disable=SC2329,SC2317  # invoked only through the traps below
reap() {
    local sig="$1" code="$2" i=0
    trap '' TERM INT HUP
    kill -TERM -- "-$CHILD" 2>/dev/null || true
    while kill -0 -- "-$CHILD" 2>/dev/null && [ "$i" -lt 20 ]; do
        sleep 0.25
        i=$((i + 1))
    done
    kill -KILL -- "-$CHILD" 2>/dev/null || true
    wait "$CHILD" 2>/dev/null || true
    echo "ERR quiet-run $LABEL killed by $sig (log: $LOG)" >&2
    exit "$code"
}

START=$(date +%s)
set -m
"$@" >>"$LOG" 2>&1 &
CHILD=$!
trap 'reap TERM 143' TERM
trap 'reap INT 130' INT
trap 'reap HUP 129' HUP
if wait "$CHILD"; then
    DUR=$(( $(date +%s) - START ))
    echo "OK quiet-run $LABEL (${DUR}s, log: $LOG)"
    exit 0
else
    RC=$?
    DUR=$(( $(date +%s) - START ))
    echo "ERR quiet-run $LABEL exit=$RC (${DUR}s, log: $LOG)" >&2
    exit $RC
fi
