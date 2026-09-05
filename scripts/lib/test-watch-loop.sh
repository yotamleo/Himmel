#!/usr/bin/env bash
# scripts/lib/test-watch-loop.sh -- tests for scripts/lib/watch-loop.sh
# (HIMMEL-1820).
#
# Usage: bash scripts/lib/test-watch-loop.sh
#
# Required cases, from the ticket:
#   1. a loop whose --parent-pid is killed EXITS ON ITS OWN within one
#      interval -- verified by ACTUALLY KILLING a spawned parent (the
#      acceptance criterion; inspecting the source proves nothing);
#   2. a TTL-bounded loop exits at its TTL;
#   3. --max-iterations is honoured (exactly N runs, then stop, well
#      before the TTL backstop).
# Plus a usage contract case (missing --parent-pid -> exit 2).
#
# Timing: intervals of 1s and TTLs of a few seconds so the suite finishes
# in seconds; bounds get slack for scheduler jitter on a loaded box. The
# elapsed time comes from the bash SECONDS builtin (integer, portable --
# no `date +%N`, which BSD date lacks).
#
# REAPING: every process this suite spawns is killed and waited on any
# exit path (trap cleanup) -- a test suite for self-terminating watchers
# must not leave orphaned ones behind (the very bug being fixed). Note a
# background child that exits un-waited stays a zombie, and `kill -0` on a
# zombie succeeds -- which is why the pre-kill liveness check reads the
# reason LINE, not kill -0 (HIMMEL-1338 documents the same trap).
#
# Exit: 0 = all pass, 1 = at least one failed.
set -uo pipefail

LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
WATCH_LOOP="$LIB_DIR/watch-loop.sh"
[ -f "$WATCH_LOOP" ] || { echo "FAIL: $WATCH_LOOP not found"; exit 1; }

PASSED=0
FAILED=0
pass() { printf 'PASS %s\n' "$1"; PASSED=$((PASSED + 1)); }
fail() { printf 'FAIL %s\n' "$1"; FAILED=$((FAILED + 1)); }

TMP="$(mktemp -d)"

# Per-case watcher (W*) and parent (P*) pids; all reaped by the trap.
W1="" P1="" W2="" P2="" W3="" P3="" P5="" W6="" P6=""
cleanup() {
    local _p
    for _p in "$W1" "$P1" "$W2" "$P2" "$W3" "$P3" "$P5" "$W6" "$P6"; do
        [ -n "$_p" ] && kill "$_p" 2>/dev/null
    done
    wait 2>/dev/null
    rm -rf "$TMP"
}
trap cleanup EXIT

# --- Case 1: killing the parent stops the loop within one interval ----------
echo "== case 1: loop exits on its own after its parent pid is killed =="
sleep 30 &
P1=$!
MARK1="$TMP/tick1"
LOG1="$TMP/log1"
bash "$WATCH_LOOP" --parent-pid "$P1" --interval 1 --ttl 30 \
    -- sh -c "printf 'tick\n' >> '$MARK1'" > "$LOG1" 2>&1 &
W1=$!

# Wait for at least one iteration to land, prove the loop was still serving
# the LIVE parent at that moment (no exit reason yet), then kill the parent.
i=0
while [ ! -s "$MARK1" ] && [ "$i" -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
if [ -s "$MARK1" ]; then
    pass "loop ran at least one iteration while the parent lived"
else
    fail "loop never ran an iteration before the parent was killed"
fi
if grep -q 'watch-loop: exiting' "$LOG1"; then
    fail "loop stopped BEFORE the parent died (premature exit)"
    printf '%s\n' "$(cat "$LOG1")"
else
    pass "loop was still running right before the parent died"
fi

kill "$P1"
wait "$P1" 2>/dev/null
SECONDS=0
wait "$W1"
rc1=$?
elapsed1=$SECONDS
if [ "$rc1" -eq 0 ]; then
    pass "loop exited 0 after its parent died"
else
    fail "loop exit code $rc1 after parent death (expected 0)"
fi
if grep -q 'watch-loop: exiting (parent-gone)' "$LOG1"; then
    pass "loop named its stop reason (parent-gone)"
else
    fail "no parent-gone reason line: $(cat "$LOG1")"
fi
# One 1s interval plus wake-up slack. The failure mode this guards against
# is the loop serving a dead owner until the 30s TTL -- so anything well
# under the TTL still distinguishes them, and 5s leaves room for a loaded
# box without letting the bug through.
if [ "$elapsed1" -le 5 ]; then
    pass "loop self-terminated within ~one interval of the parent dying (${elapsed1}s)"
else
    fail "loop took ${elapsed1}s to notice its parent died (interval is 1s, TTL 30s)"
fi
W1="" P1=""

# --- Case 2: TTL-bounded loop exits at its TTL ------------------------------
echo "== case 2: loop exits at its TTL =="
sleep 30 &
P2=$!
MARK2="$TMP/tick2"
LOG2="$TMP/log2"
SECONDS=0
bash "$WATCH_LOOP" --parent-pid "$P2" --ttl 2 --interval 1 \
    -- sh -c "printf 'tick\n' >> '$MARK2'" > "$LOG2" 2>&1
rc2=$?
elapsed2=$SECONDS
kill "$P2" 2>/dev/null
wait "$P2" 2>/dev/null
P2=""
if [ "$rc2" -eq 0 ] && grep -q 'watch-loop: exiting (ttl)' "$LOG2"; then
    pass "ttl-bounded loop exited 0 naming ttl"
else
    fail "ttl case rc=$rc2 log: $(cat "$LOG2")"
fi
if [ "$elapsed2" -ge 2 ] && [ "$elapsed2" -le 8 ]; then
    pass "loop ran ~its TTL then stopped (${elapsed2}s, TTL 2s)"
else
    fail "loop elapsed ${elapsed2}s on a 2s TTL (early exit or runaway)"
fi
if [ -s "$MARK2" ]; then
    pass "ttl loop ran its probe while the parent lived"
else
    fail "ttl loop never ran its probe"
fi

# --- Case 3: --max-iterations is honoured -----------------------------------
echo "== case 3: --max-iterations stops the loop after exactly N runs =="
sleep 30 &
P3=$!
MARK3="$TMP/tick3"
LOG3="$TMP/log3"
SECONDS=0
bash "$WATCH_LOOP" --parent-pid "$P3" --max-iterations 3 --interval 1 --ttl 60 \
    -- sh -c "printf 'tick\n' >> '$MARK3'" > "$LOG3" 2>&1
rc3=$?
elapsed3=$SECONDS
kill "$P3" 2>/dev/null
wait "$P3" 2>/dev/null
P3=""
if [ "$rc3" -eq 0 ] && grep -q 'watch-loop: exiting (max-iterations)' "$LOG3"; then
    pass "max-iterations loop exited 0 naming max-iterations"
else
    fail "max-iterations case rc=$rc3 log: $(cat "$LOG3")"
fi
ticks3="$(grep -c tick "$MARK3" || true)"
if [ "$ticks3" = 3 ]; then
    pass "probe ran exactly 3 times"
else
    fail "probe ran ${ticks3:-0} times (expected 3)"
fi
if [ "$elapsed3" -le 10 ]; then
    pass "loop stopped after the 3rd iteration (${elapsed3}s), not at the 60s TTL"
else
    fail "loop took ${elapsed3}s for 3 iterations (interval 1s -- runaway?)"
fi

# --- Case 4: usage contract -- --parent-pid is required ---------------------
echo "== case 4: missing --parent-pid is a usage error =="
LOG4="$TMP/log4"
bash "$WATCH_LOOP" --interval 1 --ttl 5 -- true > "$LOG4" 2>&1
rc4=$?
if [ "$rc4" -eq 2 ]; then
    pass "missing --parent-pid rejected with exit 2"
else
    fail "missing --parent-pid gave rc=$rc4 (expected 2): $(cat "$LOG4")"
fi

# --- Case 5: a hung probe cannot block the loop past its TTL (CR: HIMMEL-1820,
#             codex-1) -- without _wl_timeout, the FIRST `"$@"` call below
#             (sleep 30) would block the loop for 30s before it ever
#             re-checked the 2s TTL, defeating self-termination.
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
    echo "== case 5: a hung probe is bounded by the TTL, never blocks the loop indefinitely =="
    sleep 30 &
    P5=$!
    LOG5="$TMP/log5"
    SECONDS=0
    bash "$WATCH_LOOP" --parent-pid "$P5" --ttl 2 --interval 1 \
        -- sleep 30 > "$LOG5" 2>&1
    rc5=$?
    elapsed5=$SECONDS
    kill "$P5" 2>/dev/null
    wait "$P5" 2>/dev/null
    P5=""
    if [ "$rc5" -eq 0 ] && grep -q 'watch-loop: exiting (ttl)' "$LOG5"; then
        pass "loop with a hung (sleep 30) probe still exited 0 naming ttl"
    else
        fail "hung-probe case rc=$rc5 log: $(cat "$LOG5")"
    fi
    # The probe is bounded to --interval (never the TTL -- see case 6), so
    # the loop can be blocked by at most one extra interval beyond its own
    # TTL check -- never indefinitely.
    if [ "$elapsed5" -le 8 ]; then
        pass "hung probe did not block the loop past ~2x its TTL (${elapsed5}s, TTL 2s)"
    else
        fail "hung probe blocked the loop for ${elapsed5}s (TTL 2s) -- probe-level timeout regression?"
    fi

    # --- Case 6: a parent dying MID-PROBE is still noticed within about one
    #             interval, not the (much larger) TTL (CR: HIMMEL-1820,
    #             codex-1 round 3) -- bounding the probe by the remaining TTL
    #             instead of --interval would let a hung probe mask a dead
    #             parent for up to that whole remaining TTL, which breaks the
    #             "noticed within about one interval" acceptance criterion
    #             case 1 above establishes.
    echo "== case 6: parent dies mid-(hung)-probe -> still noticed within ~one interval, not the TTL =="
    sleep 30 &
    P6=$!
    LOG6="$TMP/log6"
    SECONDS=0
    bash "$WATCH_LOOP" --parent-pid "$P6" --ttl 30 --interval 1 \
        -- sleep 30 > "$LOG6" 2>&1 &
    W6=$!
    sleep 0.3
    kill "$P6"
    wait "$P6" 2>/dev/null
    P6=""
    wait "$W6"
    rc6=$?
    elapsed6=$SECONDS
    W6=""
    if [ "$rc6" -eq 0 ] && grep -q 'watch-loop: exiting (parent-gone)' "$LOG6"; then
        pass "loop noticed the mid-probe parent death (parent-gone, not ttl)"
    else
        fail "case 6 rc=$rc6 log: $(cat "$LOG6")"
    fi
    if [ "$elapsed6" -le 5 ]; then
        pass "mid-probe parent death noticed within ~one interval (${elapsed6}s), not the 30s TTL"
    else
        fail "mid-probe parent death took ${elapsed6}s to notice (TTL 30s) -- probe bound reverted to TTL?"
    fi
else
    pass "case 5 -> (skipped: no timeout/gtimeout on this host)"
    pass "case 6 -> (skipped: no timeout/gtimeout on this host)"
fi

echo "---"
printf 'PASSED=%d FAILED=%d\n' "$PASSED" "$FAILED"
[ "$FAILED" = 0 ]
