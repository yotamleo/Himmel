#!/usr/bin/env bash
# test-queue-lock.sh -- regression test for scripts/handover/queue-lock.sh
# (HIMMEL-856 phase 1).
#
# Usage: bash scripts/handover/test-queue-lock.sh
# Exit:  0 = all pass, 1 = one or more failures.
#
# Hermetic: points HANDOVER_DIR at a fresh mktemp -d for every test (never
# touches the real handover root / HOME). Cleaned up with a trap on EXIT.
# Invokes the script as a SUBPROCESS (bash queue-lock.sh <verb> ...) since
# the contract under test is the CLI exit-code table.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/queue-lock.sh"

PASSED=0
FAILED=0
pass() { echo "PASS: $1"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL: $1"; FAILED=$((FAILED + 1)); }

TMPDIR_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

HANDOVER_DIR="$TMPDIR_ROOT/handovers"
mkdir -p "$HANDOVER_DIR"
export HANDOVER_DIR
unset QUEUE_LOCK_TAKEOVER QUEUE_LOCK_TTL_SECONDS

HO1="$HANDOVER_DIR/HIMMEL-856-test/next-session-1.md"
mkdir -p "$(dirname "$HO1")"
: > "$HO1"

# --- T1: acquire succeeds, owner.json has all fields ------------------------
out="$(bash "$LIB" acquire "$HO1" "session-a" 2>&1)"
rc=$?
lockdir="$HANDOVER_DIR/.locks/queue/HIMMEL-856-test__next-session-1.lock"
if [ "$rc" -eq 0 ]; then
    pass "T1: acquire rc=0"
else
    fail "T1: acquire rc=0 (got $rc: $out)"
fi
if [ -f "$lockdir/owner.json" ] \
    && grep -q '"session":"session-a"' "$lockdir/owner.json" \
    && grep -q '"handover":"' "$lockdir/owner.json" \
    && grep -q '"started":"' "$lockdir/owner.json" \
    && grep -q '"heartbeat":"' "$lockdir/owner.json"; then
    pass "T1: owner.json has session+handover+started+heartbeat"
else
    fail "T1: owner.json missing/incomplete ($(cat "$lockdir/owner.json" 2>/dev/null || echo 'MISSING'))"
fi
if printf '%s' "$out" | grep -q '^release-token: session-a$'; then
    pass "T1: acquire prints the release-token line"
else
    fail "T1: acquire output missing 'release-token: session-a' (got: $out)"
fi

# --- T2: second acquire while FRESH -> rc 2, holder info + override hint ----
err="$(bash "$LIB" acquire "$HO1" "session-b" 2>&1 1>/dev/null)"
rc=$?
if [ "$rc" -eq 2 ]; then
    pass "T2: second acquire while FRESH rc=2"
else
    fail "T2: second acquire while FRESH rc=2 (got $rc: $err)"
fi
if printf '%s' "$err" | grep -q 'session=session-a' && printf '%s' "$err" | grep -qi 'QUEUE_LOCK_TAKEOVER'; then
    pass "T2: stderr has holder info + takeover override hint"
else
    fail "T2: stderr missing holder info / override hint: $err"
fi

# --- T3: status FRESH -> rc 11 + owner contents ------------------------------
out="$(bash "$LIB" status "$HO1" 2>&1)"
rc=$?
if [ "$rc" -eq 11 ] && printf '%s' "$out" | grep -q '"session":"session-a"' && printf '%s' "$out" | grep -qi 'FRESH'; then
    pass "T3: status held-FRESH rc=11 + owner contents"
else
    fail "T3: status held-FRESH rc=11 + owner contents (got rc=$rc out=$out)"
fi

# --- T4: heartbeat by the wrong session is refused; by the right one succeeds
err="$(bash "$LIB" heartbeat "$HO1" "session-b" 2>&1 1>/dev/null)"
rc=$?
if [ "$rc" -eq 2 ]; then
    pass "T4: heartbeat by wrong session rc=2"
else
    fail "T4: heartbeat by wrong session rc=2 (got $rc)"
fi
bash "$LIB" heartbeat "$HO1" "session-a" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
    pass "T4: heartbeat by holder session rc=0"
else
    fail "T4: heartbeat by holder session rc=0 (got $rc)"
fi

# --- T5: release by the wrong session is refused; by the right one succeeds -
err="$(bash "$LIB" release "$HO1" "session-b" 2>&1 1>/dev/null)"
rc=$?
if [ "$rc" -eq 2 ]; then
    pass "T5: release by wrong session rc=2"
else
    fail "T5: release by wrong session rc=2 (got $rc: $err)"
fi
if [ -d "$lockdir" ]; then
    pass "T5: lock still held after refused release"
else
    fail "T5: lock was released despite session mismatch (C1 violation)"
fi
bash "$LIB" release "$HO1" "session-a" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && [ ! -d "$lockdir" ]; then
    pass "T5: release by holder session rc=0, lock dir gone"
else
    fail "T5: release by holder session rc=0 + gone (got rc=$rc, dir-exists=$([ -d "$lockdir" ] && echo yes || echo no))"
fi

# --- T6: release of an absent lock (with a token) is idempotent (rc 0) ------
bash "$LIB" release "$HO1" "any-token" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
    pass "T6: release of absent lock rc=0 (idempotent)"
else
    fail "T6: release of absent lock rc=0 (got $rc)"
fi

# --- T7: status free -> rc 0, "free" ----------------------------------------
out="$(bash "$LIB" status "$HO1" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "free" ]; then
    pass "T7: status free rc=0 + 'free'"
else
    fail "T7: status free rc=0 + 'free' (got rc=$rc out=$out)"
fi

# --- T8: re-acquire after release succeeds -----------------------------------
bash "$LIB" acquire "$HO1" "session-c" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
    pass "T8: re-acquire after release rc=0"
else
    fail "T8: re-acquire after release rc=0 (got $rc)"
fi

# --- T9: stale takeover -- QUEUE_LOCK_TTL_SECONDS=0 makes any lock STALE ----
out="$(QUEUE_LOCK_TTL_SECONDS=0 bash "$LIB" status "$HO1" 2>&1)"
rc=$?
if [ "$rc" -eq 12 ] && printf '%s' "$out" | grep -qi 'STALE'; then
    pass "T9: status STALE under TTL=0 rc=12"
else
    fail "T9: status STALE under TTL=0 rc=12 (got rc=$rc out=$out)"
fi
err="$(QUEUE_LOCK_TTL_SECONDS=0 bash "$LIB" acquire "$HO1" "session-d" 2>&1 1>/dev/null)"
rc=$?
if [ "$rc" -eq 0 ]; then
    pass "T9: acquire over a STALE lock (TTL=0) rc=0 (auto-takeover)"
else
    fail "T9: acquire over a STALE lock rc=0 (got $rc: $err)"
fi
if grep -q 'session-c' "$lockdir/takeovers.log" 2>/dev/null && grep -q 'session-d' "$lockdir/takeovers.log" 2>/dev/null; then
    pass "T9: takeovers.log records previous + new holder"
else
    fail "T9: takeovers.log missing or incomplete ($(cat "$lockdir/takeovers.log" 2>/dev/null || echo MISSING))"
fi
if grep -q '"session":"session-d"' "$lockdir/owner.json" 2>/dev/null; then
    pass "T9: owner.json now shows the new holder"
else
    fail "T9: owner.json not updated after takeover"
fi
bash "$LIB" release "$HO1" "session-d" >/dev/null 2>&1

# --- T10: forced takeover of a still-FRESH lock via QUEUE_LOCK_TAKEOVER=1 ---
bash "$LIB" acquire "$HO1" "session-e" >/dev/null 2>&1
err="$(QUEUE_LOCK_TAKEOVER=1 bash "$LIB" acquire "$HO1" "session-f" 2>&1 1>/dev/null)"
rc=$?
if [ "$rc" -eq 0 ]; then
    pass "T10: forced takeover of a FRESH lock (QUEUE_LOCK_TAKEOVER=1) rc=0"
else
    fail "T10: forced takeover of a FRESH lock rc=0 (got $rc: $err)"
fi
if printf '%s' "$err" | grep -qi 'forced'; then
    pass "T10: forced-takeover message names the reason"
else
    fail "T10: forced-takeover message missing 'forced' reason: $err"
fi
bash "$LIB" release "$HO1" "session-f" >/dev/null 2>&1

# --- T11: distinct handover paths get DISTINCT locks (sibling queues) -------
HO2="$HANDOVER_DIR/HIMMEL-856-test/next-session-2.md"
: > "$HO2"
bash "$LIB" acquire "$HO1" "session-g" >/dev/null 2>&1
rc1=$?
bash "$LIB" acquire "$HO2" "session-h" >/dev/null 2>&1
rc2=$?
if [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ]; then
    pass "T11: sibling handovers (next-session-1 vs -2) get independent locks"
else
    fail "T11: sibling handovers expected both rc=0, got rc1=$rc1 rc2=$rc2"
fi
bash "$LIB" release "$HO1" "session-g" >/dev/null 2>&1
bash "$LIB" release "$HO2" "session-h" >/dev/null 2>&1

# --- T12: usage errors --------------------------------------------------------
bash "$LIB" acquire >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 1 ]; then
    pass "T12: acquire with no args rc=1"
else
    fail "T12: acquire with no args rc=1 (got $rc)"
fi
bash "$LIB" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 1 ]; then
    pass "T12: no verb at all rc=1"
else
    fail "T12: no verb at all rc=1 (got $rc)"
fi
bash "$LIB" bogus-verb "$HO1" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 1 ]; then
    pass "T12: unknown verb rc=1"
else
    fail "T12: unknown verb rc=1 (got $rc)"
fi

# --- T13: concurrent acquire race -- exactly one of two subshells wins ------
HO3="$HANDOVER_DIR/HIMMEL-856-test/next-session-3.md"
: > "$HO3"
OUT_A="$TMPDIR_ROOT/race-a.rc"
OUT_B="$TMPDIR_ROOT/race-b.rc"
( bash "$LIB" acquire "$HO3" "racer-a" >/dev/null 2>&1; echo $? > "$OUT_A" ) &
( bash "$LIB" acquire "$HO3" "racer-b" >/dev/null 2>&1; echo $? > "$OUT_B" ) &
wait
rc_a="$(cat "$OUT_A")"
rc_b="$(cat "$OUT_B")"
# Exactly one rc=0 (winner) and one rc=2 (loser, FRESH refusal) -- order is
# a race, so accept either winner.
if { [ "$rc_a" -eq 0 ] && [ "$rc_b" -eq 2 ]; } || { [ "$rc_a" -eq 2 ] && [ "$rc_b" -eq 0 ]; }; then
    pass "T13: concurrent acquire -- exactly one winner (rc_a=$rc_a rc_b=$rc_b)"
else
    fail "T13: concurrent acquire -- expected one 0 and one 2, got rc_a=$rc_a rc_b=$rc_b"
fi
# The race winner's token is unknown here -- use the emergency override.
QUEUE_LOCK_FORCE_RELEASE=1 bash "$LIB" release "$HO3" >/dev/null 2>&1

# --- T14: concurrent STALE-takeover race -- exactly one taker wins ----------
# (HIMMEL-856 CR, codex-2: the takeover must be an atomic rename-then-acquire,
# never an in-place owner.json rewrite that lets both takers "win".)
# The stale lock is hand-crafted with an ANCIENT heartbeat under the DEFAULT
# TTL -- deliberately not QUEUE_LOCK_TTL_SECONDS=0, which would make the
# winner's brand-new lock instantly stale too and legitimize a second
# takeover, turning the exactly-one-winner assertion into a coin flip.
HO4="$HANDOVER_DIR/HIMMEL-856-test/next-session-4.md"
: > "$HO4"
LOCKDIR4="$HANDOVER_DIR/.locks/queue/HIMMEL-856-test__next-session-4.lock"
mkdir -p "$LOCKDIR4"
printf '{"session":"dead-session","host":"old-host","handover":"%s","started":"2020-01-01T00:00:00Z","heartbeat":"2020-01-01T00:00:00Z"}\n' \
    "$HO4" > "$LOCKDIR4/owner.json"
T14_A_RC="$TMPDIR_ROOT/t14-a.rc"; T14_A_ERR="$TMPDIR_ROOT/t14-a.err"
T14_B_RC="$TMPDIR_ROOT/t14-b.rc"; T14_B_ERR="$TMPDIR_ROOT/t14-b.err"
( bash "$LIB" acquire "$HO4" "taker-a" >/dev/null 2>"$T14_A_ERR"; echo $? > "$T14_A_RC" ) &
( bash "$LIB" acquire "$HO4" "taker-b" >/dev/null 2>"$T14_B_ERR"; echo $? > "$T14_B_RC" ) &
wait
rc_a="$(cat "$T14_A_RC")"
rc_b="$(cat "$T14_B_RC")"
if { [ "$rc_a" -eq 0 ] && [ "$rc_b" -eq 2 ]; } || { [ "$rc_a" -eq 2 ] && [ "$rc_b" -eq 0 ]; }; then
    pass "T14: concurrent stale-takeover -- exactly one winner (rc_a=$rc_a rc_b=$rc_b)"
else
    fail "T14: concurrent stale-takeover -- expected one 0 and one 2, got rc_a=$rc_a rc_b=$rc_b"
fi
if [ "$rc_a" -eq 0 ]; then
    winner="taker-a"; loser_err="$T14_B_ERR"
else
    winner="taker-b"; loser_err="$T14_A_ERR"
fi
if grep -q "\"session\":\"$winner\"" "$LOCKDIR4/owner.json" 2>/dev/null; then
    pass "T14: owner.json shows exactly the winning taker ($winner)"
else
    fail "T14: owner.json does not show the winner ($(cat "$LOCKDIR4/owner.json" 2>/dev/null || echo MISSING))"
fi
if grep -q 'dead-session' "$LOCKDIR4/takeovers.log" 2>/dev/null && grep -q "$winner" "$LOCKDIR4/takeovers.log" 2>/dev/null; then
    pass "T14: takeovers.log carries old holder + winner"
elif [ ! -f "$LOCKDIR4/takeovers.log" ] && grep -q "\"session\":\"$winner\"" "$LOCKDIR4/owner.json" 2>/dev/null; then
    # Rare legal interleaving: the rc-0 acquirer's INITIAL mkdir landed in
    # the claim-holder's rm->mkdir gap, so it acquired via the FRESH path
    # (no trail written -- there was no lock dir when it arrived). The
    # exactly-one-winner property (the actual codex-2 contract) still held.
    pass "T14: fresh-path winner in the rm->mkdir gap (no trail required)"
else
    fail "T14: takeovers.log missing/incomplete ($(cat "$LOCKDIR4/takeovers.log" 2>/dev/null || echo MISSING))"
fi
if grep -qi 'held' "$loser_err" 2>/dev/null; then
    pass "T14: loser reports held-by-other"
else
    fail "T14: loser stderr missing held-by-other report ($(cat "$loser_err" 2>/dev/null))"
fi
# No takeover-claim debris left behind (every exit path drops the claim).
T14_DEBRIS=""
for _g in "$HANDOVER_DIR"/.locks/queue/*.claim "$HANDOVER_DIR"/.locks/queue/*.taken.*; do
    [ -e "$_g" ] && T14_DEBRIS="$_g"
done
if [ -n "$T14_DEBRIS" ]; then
    fail "T14: takeover-claim debris leaked ($T14_DEBRIS)"
else
    pass "T14: no takeover-claim debris left in .locks/queue/"
fi
bash "$LIB" release "$HO4" "$winner" >/dev/null 2>&1

# --- T15: mandatory session token on release/heartbeat (HIMMEL-856 CR C1) ---
HO15="$HANDOVER_DIR/HIMMEL-856-test/next-session-15.md"
: > "$HO15"
LOCKDIR15="$HANDOVER_DIR/.locks/queue/HIMMEL-856-test__next-session-15.lock"
bash "$LIB" acquire "$HO15" "session-t15" >/dev/null 2>&1
err="$(bash "$LIB" release "$HO15" 2>&1 1>/dev/null)"
rc=$?
if [ "$rc" -eq 2 ] && [ -d "$LOCKDIR15" ]; then
    pass "T15: token-less release refused rc=2, lock still held"
else
    fail "T15: token-less release refused rc=2 + held (got rc=$rc, dir-exists=$([ -d "$LOCKDIR15" ] && echo yes || echo no))"
fi
if printf '%s' "$err" | grep -q 'session-t15' && printf '%s' "$err" | grep -q 'QUEUE_LOCK_FORCE_RELEASE'; then
    pass "T15: refusal names the current holder + the emergency override"
else
    fail "T15: refusal missing holder info / override hint: $err"
fi
bash "$LIB" heartbeat "$HO15" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 2 ]; then
    pass "T15: token-less heartbeat refused rc=2"
else
    fail "T15: token-less heartbeat refused rc=2 (got $rc)"
fi
err="$(QUEUE_LOCK_FORCE_RELEASE=1 bash "$LIB" release "$HO15" 2>&1 1>/dev/null)"
rc=$?
if [ "$rc" -eq 0 ] && [ ! -d "$LOCKDIR15" ]; then
    pass "T15: QUEUE_LOCK_FORCE_RELEASE=1 releases without a token"
else
    fail "T15: forced release rc=0 + gone (got rc=$rc)"
fi
if grep -q 'FORCED RELEASE' "$HANDOVER_DIR/.locks/queue/takeovers.log" 2>/dev/null \
    && grep -q 'session-t15' "$HANDOVER_DIR/.locks/queue/takeovers.log" 2>/dev/null; then
    pass "T15: forced release logged to the queue-level takeovers.log"
else
    fail "T15: queue-level takeovers.log missing the forced-release record ($(cat "$HANDOVER_DIR/.locks/queue/takeovers.log" 2>/dev/null || echo MISSING))"
fi

# --- T16: failed owner.json write never reports acquired (HIMMEL-856 CR C3) -
# Source the script (the sourcing guard skips main) and override the atomic
# writer to fail; acquire must return non-zero and remove the lock dir.
HO16="$HANDOVER_DIR/HIMMEL-856-test/next-session-16.md"
: > "$HO16"
LOCKDIR16="$HANDOVER_DIR/.locks/queue/HIMMEL-856-test__next-session-16.lock"
t16_out=$(bash -c '. "$1"; _ql_write_owner() { return 1; }; queue_lock_acquire "$2" "sess-t16"; echo "RC=$?"' _ "$LIB" "$HO16" 2>&1)
if printf '%s' "$t16_out" | grep -q 'RC=1' && [ ! -d "$LOCKDIR16" ]; then
    pass "T16: failed owner write -> rc=1 and the lock dir is removed"
else
    fail "T16: failed owner write (out=$t16_out, dir-exists=$([ -d "$LOCKDIR16" ] && echo yes || echo no))"
fi
if printf '%s' "$t16_out" | grep -q 'acquire FAILED' && ! printf '%s' "$t16_out" | grep -q 'release-token:'; then
    pass "T16: loud failure, no acquired/token line emitted"
else
    fail "T16: failure output wrong (no loud error, or a token line leaked): $t16_out"
fi

# --- T17: status names a CORRUPT lock dir distinctly (HIMMEL-856 CR imp-c) --
HO17="$HANDOVER_DIR/HIMMEL-856-test/next-session-17.md"
: > "$HO17"
LOCKDIR17="$HANDOVER_DIR/.locks/queue/HIMMEL-856-test__next-session-17.lock"
mkdir -p "$LOCKDIR17"   # lock dir with NO owner.json = corrupt
out="$(bash "$LIB" status "$HO17" 2>&1)"
rc=$?
if [ "$rc" -eq 11 ] && printf '%s' "$out" | grep -q 'CORRUPT'; then
    pass "T17: corrupt lock dir -> rc=11 (fail-closed) and says CORRUPT"
else
    fail "T17: corrupt lock dir status (got rc=$rc out=$out)"
fi
QUEUE_LOCK_FORCE_RELEASE=1 bash "$LIB" release "$HO17" >/dev/null 2>&1

# --- T18: status aging warning past half-TTL; WARN on unparsable heartbeat --
HO18="$HANDOVER_DIR/HIMMEL-856-test/next-session-18.md"
: > "$HO18"
LOCKDIR18="$HANDOVER_DIR/.locks/queue/HIMMEL-856-test__next-session-18.lock"
mkdir -p "$LOCKDIR18"
# Heartbeat 2020-01-01: age ~2.05e8s. TTL=300000000 (3e8): half=1.5e8 < age
# < ttl -> FRESH but AGING.
printf '{"session":"ager","host":"h","handover":"%s","started":"2020-01-01T00:00:00Z","heartbeat":"2020-01-01T00:00:00Z"}\n' \
    "$HO18" > "$LOCKDIR18/owner.json"
err="$(QUEUE_LOCK_TTL_SECONDS=300000000 bash "$LIB" status "$HO18" 2>&1 1>/dev/null)"
rc=$?
if [ "$rc" -eq 11 ] && printf '%s' "$err" | grep -qi 'AGING'; then
    pass "T18: FRESH lock past half-TTL warns AGING (rc stays 11)"
else
    fail "T18: aging warning (got rc=$rc err=$err)"
fi
printf '{"session":"ager","host":"h","handover":"%s","started":"garbage","heartbeat":"garbage"}\n' \
    "$HO18" > "$LOCKDIR18/owner.json"
err="$(bash "$LIB" status "$HO18" 2>&1 1>/dev/null)"
rc=$?
if [ "$rc" -eq 11 ] && printf '%s' "$err" | grep -qi 'could not parse heartbeat'; then
    pass "T18: unparsable heartbeat -> WARN + treated FRESH (rc=11)"
else
    fail "T18: unparsable-heartbeat warn (got rc=$rc err=$err)"
fi
QUEUE_LOCK_FORCE_RELEASE=1 bash "$LIB" release "$HO18" >/dev/null 2>&1

echo "---"
echo "PASSED=$PASSED FAILED=$FAILED"
[ "$FAILED" = 0 ]
