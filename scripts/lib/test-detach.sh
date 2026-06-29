#!/usr/bin/env bash
# test-detach.sh — regression test for scripts/lib/detach.sh (HIMMEL-623).
#
# Usage: bash scripts/lib/test-detach.sh
#
# Guards the two properties detach_run must hold so a SessionEnd hook never
# overruns its budget (the recurring "Hook cancelled"):
#   1. detach_run RETURNS IMMEDIATELY — independent of how long the child runs.
#      The HIMMEL-623 bug: on MSYS (no setsid) the old ( cmd & ) double-fork let
#      the shell INTERMITTENTLY wait for the backgrounded child at exit, so a
#      slow child blocked the caller. `disown` removes the job from the shell's
#      table so neither the call nor the caller's exit waits for it.
#   2. The child STILL RUNS to completion after the caller returns (detach must
#      not drop the work — the refresh/crystallization has to land).
#
# Timing uses the bash `SECONDS` builtin (integer, portable — avoids macOS
# `date +%N` which BSD date does not support). A working detach returns in 0-1s
# even with a multi-second child; a blocking one returns in ~CHILD_SECS.
#
# Exit: 0 = all pass, 1 = at least one failed.
set -uo pipefail

LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$LIB_DIR/detach.sh"

PASSED=0
FAILED=0
pass() { echo "PASS $1"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

CHILD_SECS=4
MARKER="$TMP/child-done"

# --- Case 1: detach_run returns fast, independent of child duration ----------
SECONDS=0
detach_run sh -c "sleep $CHILD_SECS; : > '$MARKER'"
elapsed=$SECONDS
if [ "$elapsed" -lt 2 ]; then
    pass "detach_run returns immediately (${elapsed}s) with a ${CHILD_SECS}s child"
else
    fail "detach_run blocked ${elapsed}s on a ${CHILD_SECS}s child (HIMMEL-623 regression)"
fi

# --- Case 2: the detached child still completes after the caller returns ------
i=0
while [ ! -e "$MARKER" ] && [ "$i" -lt 60 ]; do sleep 0.2; i=$((i + 1)); done
if [ -e "$MARKER" ]; then
    pass "detached child ran to completion (marker landed)"
else
    fail "detached child never completed (work dropped)"
fi

# --- Case 3: a CALLER THAT EXITS does not wait for the child (the real bug) ---
# HIMMEL-623 manifests at shell EXIT, not at the detach_run call (the old
# ( cmd & ) double-fork also returned from the call immediately). The meaningful
# guard is: a child shell that sources the lib, detach_runs a slow child, and
# EXITS must terminate FAST — independent of the child's duration. We force the
# no-setsid fallback (DETACH_NO_SETSID=1) so this exercises the disown branch the
# fix lives in even on a Linux box that has setsid. (On Linux a non-interactive
# shell never exit-waits, so this passes either way there; on Windows/macOS it is
# the case that actually distinguishes the fix from the old exit-wait bug.)
MARKER3="$TMP/exit-child-done"
SECONDS=0
DETACH_NO_SETSID=1 bash -c ". '$LIB_DIR/detach.sh'; detach_run sh -c \"sleep $CHILD_SECS; : > '$MARKER3'\""
exit_elapsed=$SECONDS
if [ "$exit_elapsed" -lt 2 ]; then
    pass "caller shell exits immediately (${exit_elapsed}s), not waiting for the ${CHILD_SECS}s child"
else
    fail "caller shell blocked ${exit_elapsed}s at exit on a ${CHILD_SECS}s child (HIMMEL-623 regression)"
fi
i=0
while [ ! -e "$MARKER3" ] && [ "$i" -lt 60 ]; do sleep 0.2; i=$((i + 1)); done
if [ -e "$MARKER3" ]; then
    pass "no-setsid fallback: child still completed after the caller exited"
else
    fail "no-setsid fallback: child never completed (disown dropped the work)"
fi

echo "---"
echo "PASSED=$PASSED FAILED=$FAILED"
[ "$FAILED" = 0 ]
