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

LOG="${TMPDIR:-/tmp}/quiet-run-${LABEL}-$(date +%Y%m%d-%H%M%S)-$$.log"

{
    echo "=== quiet-run $LABEL @ $(date -Iseconds) ==="
    echo "cmd=$*"
    echo ""
} >>"$LOG"

START=$(date +%s)
if "$@" >>"$LOG" 2>&1; then
    DUR=$(( $(date +%s) - START ))
    echo "OK quiet-run $LABEL (${DUR}s, log: $LOG)"
    exit 0
else
    RC=$?
    DUR=$(( $(date +%s) - START ))
    echo "ERR quiet-run $LABEL exit=$RC (${DUR}s, log: $LOG)" >&2
    exit $RC
fi
