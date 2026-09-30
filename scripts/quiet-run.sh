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
# HIMMEL-3914: refuse a chokepoint seam that differs from the session's launch env.
_csg_lib="$(dirname "${BASH_SOURCE[0]}")/lib/chokepoint-seam-guard.sh"
# shellcheck source=scripts/lib/chokepoint-seam-guard.sh
# shellcheck disable=SC1091
if ! { [ -r "$_csg_lib" ] && . "$_csg_lib"; }; then
    echo "quiet-run.sh: cannot load $_csg_lib - refusing (HIMMEL-3914)" >&2
    exit 96
fi
chokepoint_seam_guard scripts/quiet-run.sh

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

# HIMMEL-1818: label `suite` is a suite chokepoint -- whatever it runs (bash
# test-*.sh, bun test, node --test) takes a slot of the machine-wide suite
# budget first, and a busy budget fails loud with rc 75 (SUITE_LOCK_WAIT=<n>
# waits instead). A missing lib refuses rather than running unbudgeted.
if [ "$LABEL" = "suite" ]; then
    SEM_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-semaphore.sh"
    # shellcheck source=lib/suite-semaphore.sh
    if ! { [ -r "$SEM_LIB" ] && . "$SEM_LIB"; } 2>/dev/null; then
        echo "ERR quiet-run: label 'suite' needs $SEM_LIB (HIMMEL-1818)" >&2
        exit 2
    fi
    SEM_RC=0
    suite_sem_acquire suite "bash scripts/quiet-run.sh suite -- $*" || SEM_RC=$?
    [ "$SEM_RC" -eq 0 ] || exit "$SEM_RC"
    trap suite_sem_release EXIT
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
# quiet-run still orphans its command; a command that calls setsid/setpgid
# leaves the group and escapes the reap; and a caller that started quiet-run as
# a non-interactive `&` job handed it SIGINT already ignored, which bash cannot
# trap (TERM/HUP still reap). With a tty on stdin the command stays in the
# foreground group instead: a background group that reads the terminal is
# stopped by SIGTTIN, and ^C already reaches the whole foreground group there,
# so that path keeps the pre-HIMMEL-2221 shape (a `kill <pid>` of the wrapper
# alone still orphans it). A command that opens /dev/tty while stdin is not a
# tty is stopped the same way in the grouped path.
# shellcheck disable=SC2329,SC2317  # invoked only through the traps below
reap() {
    local sig="$1" code="$2" i=0
    trap '' TERM INT HUP
    # A signal can land between the spawn and `CHILD=$!`; $! still names the job.
    CHILD="${CHILD:-${!:-}}"
    if [ -z "$CHILD" ]; then
        echo "ERR quiet-run $LABEL killed by $sig before the command started (log: $LOG)" >&2
        exit "$code"
    fi
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
RC=0
if [ -t 0 ]; then
    "$@" >>"$LOG" 2>&1 || RC=$?
else
    CHILD=""
    trap 'reap TERM 143' TERM
    trap 'reap INT 130' INT
    trap 'reap HUP 129' HUP
    set -m
    "$@" >>"$LOG" 2>&1 &
    CHILD=$!
    wait "$CHILD" || RC=$?
fi
if [ "$RC" -eq 0 ]; then
    DUR=$(( $(date +%s) - START ))
    echo "OK quiet-run $LABEL (${DUR}s, log: $LOG)"
    exit 0
else
    DUR=$(( $(date +%s) - START ))
    echo "ERR quiet-run $LABEL exit=$RC (${DUR}s, log: $LOG)" >&2
    exit $RC
fi
