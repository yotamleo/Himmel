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

# --- T19: acquire CONSUMES (drops) THIS host's PENDING arms.jsonl ----------
# record(s) for this handover (HIMMEL-882; retention shape, round-3), and
# touches nothing else: a sibling record for the SAME host but a DIFFERENT
# handover, and a record for the SAME handover but a DIFFERENT host, must
# both survive untouched -- this is the lifecycle fix for arm-resume.sh's
# permanent rc=8 (a cross-host re-arm kept matching a stale record whose
# arm had long fired).
HO19="$HANDOVER_DIR/HIMMEL-856-test/next-session-19.md"
: > "$HO19"
HO19_SIBLING="$HANDOVER_DIR/HIMMEL-856-test/next-session-19b.md"
mkdir -p "$HANDOVER_DIR/.locks"
THIS_HOST=$(hostname 2>/dev/null || echo "${COMPUTERNAME:-${HOSTNAME:-unknown-host}}")
ARMS_REGISTRY="$HANDOVER_DIR/.locks/arms.jsonl"
{
    printf '{"host":"%s","handover":"%s","fire-at":"202601010000","task-name":"HIMMEL-Resume-t19-mine"}\n' "$THIS_HOST" "$HO19"
    printf '{"host":"%s","handover":"%s","fire-at":"202601010000","task-name":"HIMMEL-Resume-t19-sibling"}\n' "$THIS_HOST" "$HO19_SIBLING"
    printf '{"host":"other-host","handover":"%s","fire-at":"202601010000","task-name":"HIMMEL-Resume-t19-foreign"}\n' "$HO19"
} > "$ARMS_REGISTRY"
err="$(bash "$LIB" acquire "$HO19" "session-t19" 2>&1 1>/dev/null)"
rc=$?
if [ "$rc" -eq 0 ]; then
    pass "T19: acquire rc=0"
else
    fail "T19: acquire rc=0 (got $rc: $err)"
fi
if ! grep -q '"task-name":"HIMMEL-Resume-t19-mine"' "$ARMS_REGISTRY"; then
    pass "T19: this host's record for this handover was consumed (dropped)"
else
    fail "T19: this host's record was not consumed ($(cat "$ARMS_REGISTRY" 2>/dev/null))"
fi
if grep -q '"task-name":"HIMMEL-Resume-t19-sibling"' "$ARMS_REGISTRY"; then
    pass "T19: sibling handover's record (same host) untouched"
else
    fail "T19: sibling handover's record was WRONGLY dropped ($(cat "$ARMS_REGISTRY" 2>/dev/null))"
fi
if grep -q '"task-name":"HIMMEL-Resume-t19-foreign"' "$ARMS_REGISTRY"; then
    pass "T19: foreign host's record (same handover) untouched"
else
    fail "T19: foreign host's record was WRONGLY dropped ($(cat "$ARMS_REGISTRY" 2>/dev/null))"
fi
if [ "$(wc -l < "$ARMS_REGISTRY")" -eq 2 ]; then
    pass "T19: exactly the 2 bystander lines survive (no corruption/loss)"
else
    fail "T19: unexpected registry line count ($(cat "$ARMS_REGISTRY" 2>/dev/null))"
fi
if printf '%s' "$err" | grep -qi 'consumed'; then
    pass "T19: loud trail on the consumed stderr line"
else
    fail "T19: no loud trail for the consume rewrite ($err)"
fi
bash "$LIB" release "$HO19" "session-t19" >/dev/null 2>&1

# --- T20: acquire is a no-op on the arms registry when no record matches --
# (no arms.jsonl at all, and a registry with only non-matching records) --
# never errors, never fabricates a match.
HO20="$HANDOVER_DIR/HIMMEL-856-test/next-session-20.md"
: > "$HO20"
rm -f "$ARMS_REGISTRY"
bash "$LIB" acquire "$HO20" "session-t20" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && [ ! -f "$ARMS_REGISTRY" ]; then
    pass "T20: acquire with no arms.jsonl at all -- rc=0, no file created"
else
    fail "T20: acquire with no arms.jsonl (got rc=$rc, exists=$([ -f "$ARMS_REGISTRY" ] && echo yes || echo no))"
fi
bash "$LIB" release "$HO20" "session-t20" >/dev/null 2>&1

# --- T21: a registry WITHOUT a trailing newline never loses its final ------
# record on rewrite (HIMMEL-882 CR round-2 Critical, live-reproduced):
# `read` returns 1 at EOF-without-newline while still filling the variable,
# so without the `|| [ -n "$line" ]` guard the final record was silently
# DELETED. Two shapes: (a) final record is a NON-matching bystander -- must
# survive; (b) final record IS the matching one -- must be SEEN and
# consumed (loud trail), not silently skipped.
HO21="$HANDOVER_DIR/HIMMEL-856-test/next-session-21.md"
: > "$HO21"
{
    printf '{"host":"%s","handover":"%s","fire-at":"202601010000","task-name":"HIMMEL-Resume-t21-mine"}\n' "$THIS_HOST" "$HO21"
    printf '{"host":"other-host","handover":"unrelated.md","fire-at":"202601010000","task-name":"HIMMEL-Resume-t21-last"}'
} > "$ARMS_REGISTRY"   # NOTE: final record has NO trailing newline
bash "$LIB" acquire "$HO21" "session-t21" >/dev/null 2>&1
if grep -q '"task-name":"HIMMEL-Resume-t21-last"' "$ARMS_REGISTRY"; then
    pass "T21: final no-newline bystander record survives the rewrite"
else
    fail "T21: final no-newline record was DELETED ($(cat "$ARMS_REGISTRY" 2>/dev/null))"
fi
if ! grep -q '"task-name":"HIMMEL-Resume-t21-mine"' "$ARMS_REGISTRY"; then
    pass "T21: matching record still got consumed"
else
    fail "T21: matching record not consumed ($(cat "$ARMS_REGISTRY" 2>/dev/null))"
fi
bash "$LIB" release "$HO21" "session-t21" >/dev/null 2>&1
printf '{"host":"%s","handover":"%s","fire-at":"202601010000","task-name":"HIMMEL-Resume-t21-solo"}' \
    "$THIS_HOST" "$HO21" > "$ARMS_REGISTRY"   # single matching record, NO newline
err="$(bash "$LIB" acquire "$HO21" "session-t21b" 2>&1 1>/dev/null)"
if printf '%s' "$err" | grep -qi 'consumed' && ! grep -q 't21-solo' "$ARMS_REGISTRY"; then
    pass "T21: solo no-newline matching record was SEEN and consumed (loud trail)"
else
    fail "T21: solo no-newline record not consumed / no trail (err=$err reg=$(cat "$ARMS_REGISTRY" 2>/dev/null))"
fi
bash "$LIB" release "$HO21" "session-t21b" >/dev/null 2>&1

# --- T22: odd line shapes consume cleanly without corrupting bystanders ----
# (round-2 hardening, reshaped for round-3 retention: consumed lines are
# DROPPED whole, never edited, so trailing whitespace/CR after `}` and a
# missing closing brace cannot produce invalid JSON -- the field match is
# shape-insensitive). The bystander line must survive byte-identical.
HO22="$HANDOVER_DIR/HIMMEL-856-test/next-session-22.md"
: > "$HO22"
BYSTANDER22='{"host":"other-host","handover":"unrelated-22.md","fire-at":"202601010000","task-name":"HIMMEL-Resume-t22-bystander"}'
{
    printf '{"host":"%s","handover":"%s","fire-at":"202601010000","task-name":"HIMMEL-Resume-t22-ws"}   \n' "$THIS_HOST" "$HO22"
    printf '{"host":"%s","handover":"%s","task-name":"HIMMEL-Resume-t22-garbage"\n' "$THIS_HOST" "$HO22"
    printf '%s\n' "$BYSTANDER22"
} > "$ARMS_REGISTRY"
bash "$LIB" acquire "$HO22" "session-t22" >/dev/null 2>&1
if ! grep -q 'HIMMEL-Resume-t22-ws' "$ARMS_REGISTRY" && ! grep -q 'HIMMEL-Resume-t22-garbage' "$ARMS_REGISTRY"; then
    pass "T22: trailing-whitespace + no-brace matching lines both consumed"
else
    fail "T22: odd-shaped matching lines not consumed ($(cat "$ARMS_REGISTRY" 2>/dev/null))"
fi
if grep -qF "$BYSTANDER22" "$ARMS_REGISTRY" && [ "$(wc -l < "$ARMS_REGISTRY")" -eq 1 ]; then
    pass "T22: bystander line survives byte-identical"
else
    fail "T22: bystander corrupted/lost ($(cat "$ARMS_REGISTRY" 2>/dev/null))"
fi
bash "$LIB" release "$HO22" "session-t22" >/dev/null 2>&1

# --- T30: direct fired-GC coverage for the consume path (round-4 test-1) ---
# The legacy '"fired":"true"'-marked-line GC inside
# _ql_arms_registry_retire_fired (the unconditional `*'"fired":"true"'*)
# changed=1; continue` case, matched BEFORE the host/handover compare) had
# no direct test here -- only its twin in arm-resume.sh's rewriter got
# end-to-end coverage. Mirrors T22's odd-shape intent: seed a fired-marked
# line for THIS host's own handover plus an untouched (non-fired) bystander
# from another host, drive it through the real queue_lock_acquire path, and
# assert the fired line is gone while the bystander survives byte-identical.
HO30="$HANDOVER_DIR/HIMMEL-856-test/next-session-30.md"
: > "$HO30"
T30_BYSTANDER='{"host":"other-host","handover":"unrelated-30.md","fire-at":"202601010000","task-name":"HIMMEL-Resume-t30-bystander"}'
{
    printf '{"host":"%s","handover":"%s","fired":"true","fire-at":"202601010000","task-name":"HIMMEL-Resume-t30-fired"}\n' \
        "$THIS_HOST" "$HO30"
    printf '%s\n' "$T30_BYSTANDER"
} > "$ARMS_REGISTRY"
bash "$LIB" acquire "$HO30" "session-t30" >/dev/null 2>&1
if ! grep -q 'HIMMEL-Resume-t30-fired' "$ARMS_REGISTRY"; then
    pass "T30: legacy fired-marked line is GC'd on acquire (direct consume-path coverage)"
else
    fail "T30: fired-marked line survived consume ($(cat "$ARMS_REGISTRY" 2>/dev/null))"
fi
if grep -qF "$T30_BYSTANDER" "$ARMS_REGISTRY" && [ "$(wc -l < "$ARMS_REGISTRY")" -eq 1 ]; then
    pass "T30: non-fired bystander line survives byte-identical"
else
    fail "T30: bystander corrupted/lost ($(cat "$ARMS_REGISTRY" 2>/dev/null))"
fi
bash "$LIB" release "$HO30" "session-t30" >/dev/null 2>&1
rm -f "$ARMS_REGISTRY"

# --- T23: escaped-vs-raw compare (round-2): the registry stores JSON- ------
# escaped values (backslashes doubled), so a raw Windows backslash handover
# path must still match its own record and be consumed. acquire never stats
# the handover path, so a fake backslash path exercises this on every
# platform.
HO23='C:\fake\HIMMEL-882\next-session-23.md'
HO23_ESC=$(printf '%s' "$HO23" | sed -e 's/\\/\\\\/g')
printf '{"host":"%s","handover":"%s","fire-at":"202601010000","task-name":"HIMMEL-Resume-t23-bslash"}\n' \
    "$THIS_HOST" "$HO23_ESC" > "$ARMS_REGISTRY"
bash "$LIB" acquire "$HO23" "session-t23" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && ! grep -q 'HIMMEL-Resume-t23-bslash' "$ARMS_REGISTRY"; then
    pass "T23: backslash path matches its escaped record and is consumed"
else
    fail "T23: backslash-path record not consumed (rc=$rc reg=$(cat "$ARMS_REGISTRY" 2>/dev/null))"
fi
QUEUE_LOCK_FORCE_RELEASE=1 bash "$LIB" release "$HO23" >/dev/null 2>&1

# --- T24: the TAKEOVER acquire path also consumes (round-2 addendum) -------
# T19 covered the fresh-mkdir path only; the stale-takeover branch has its
# own retire call. Stale fixture per T9/T14: hand-crafted owner.json with
# an ancient heartbeat under the DEFAULT TTL.
HO24="$HANDOVER_DIR/HIMMEL-856-test/next-session-24.md"
: > "$HO24"
LOCKDIR24="$HANDOVER_DIR/.locks/queue/HIMMEL-856-test__next-session-24.lock"
mkdir -p "$LOCKDIR24"
printf '{"session":"dead-session","host":"old-host","handover":"%s","started":"2020-01-01T00:00:00Z","heartbeat":"2020-01-01T00:00:00Z"}\n' \
    "$HO24" > "$LOCKDIR24/owner.json"
printf '{"host":"%s","handover":"%s","fire-at":"202601010000","task-name":"HIMMEL-Resume-t24-takeover"}\n' \
    "$THIS_HOST" "$HO24" > "$ARMS_REGISTRY"
err="$(bash "$LIB" acquire "$HO24" "session-t24" 2>&1 1>/dev/null)"
rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$err" | grep -qi 'took over'; then
    pass "T24: acquire went through the stale-takeover path rc=0"
else
    fail "T24: expected a stale takeover (got rc=$rc: $err)"
fi
if ! grep -q 'HIMMEL-Resume-t24-takeover' "$ARMS_REGISTRY"; then
    pass "T24: takeover-path acquire consumed the record"
else
    fail "T24: takeover-path acquire did not consume ($(cat "$ARMS_REGISTRY" 2>/dev/null))"
fi
bash "$LIB" release "$HO24" "session-t24" >/dev/null 2>&1

# --- T25: concurrent rewriters lose no record (round-2 High) ---------------
# Two acquires on DIFFERENT handovers race the SAME arms.jsonl (one
# registry per handover root); pre-mutex, both did read-filter-rewrite-mv
# and the last mv won, losing the other's update. Modest hammer: 20 rounds,
# each with both records pending plus an untouchable bystander; after both
# acquires BOTH matching records must be consumed and the bystander must be
# the only survivor.
T25_BYSTANDER='{"host":"other-host","handover":"t25-bystander.md","fire-at":"202601010000","task-name":"HIMMEL-Resume-t25-bystander"}'
T25_BAD=""
t25_i=0
while [ "$t25_i" -lt 20 ]; do
    HOA="$HANDOVER_DIR/HIMMEL-856-test/race-a-$t25_i.md"
    HOB="$HANDOVER_DIR/HIMMEL-856-test/race-b-$t25_i.md"
    {
        printf '{"host":"%s","handover":"%s","fire-at":"202601010000","task-name":"HIMMEL-Resume-t25-a"}\n' "$THIS_HOST" "$HOA"
        printf '{"host":"%s","handover":"%s","fire-at":"202601010000","task-name":"HIMMEL-Resume-t25-b"}\n' "$THIS_HOST" "$HOB"
        printf '%s\n' "$T25_BYSTANDER"
    } > "$ARMS_REGISTRY"
    ( bash "$LIB" acquire "$HOA" "t25-a-$t25_i" >/dev/null 2>&1 ) &
    ( bash "$LIB" acquire "$HOB" "t25-b-$t25_i" >/dev/null 2>&1 ) &
    wait
    if [ "$(wc -l < "$ARMS_REGISTRY")" -ne 1 ] \
        || ! grep -qF "$T25_BYSTANDER" "$ARMS_REGISTRY"; then
        T25_BAD="round $t25_i: $(cat "$ARMS_REGISTRY" 2>/dev/null)"
        break
    fi
    t25_i=$((t25_i + 1))
done
if [ -z "$T25_BAD" ]; then
    pass "T25: no lost update across 20 concurrent-acquire rounds (bystander sole survivor)"
else
    fail "T25: concurrent rewrite lost an update ($T25_BAD)"
fi

# --- T26: write-failure fail-open (round-2 addendum): tmp create fails -> --
# WARN + acquire still succeeds + registry left untouched + mutex released.
# Portable trigger: source the lib in one bash so $$ is knowable, and plant
# a DIRECTORY at the exact "$reg.tmp.$$" path -- the `: >` redirection then
# fails on every platform (no chmod tricks, which don't hold on Windows).
HO26="$HANDOVER_DIR/HIMMEL-856-test/next-session-26.md"
: > "$HO26"
printf '{"host":"%s","handover":"%s","fire-at":"202601010000","task-name":"HIMMEL-Resume-t26-failopen"}\n' \
    "$THIS_HOST" "$HO26" > "$ARMS_REGISTRY"
t26_out=$(bash -c '. "$1"; mkdir -p "$2.tmp.$$"; queue_lock_acquire "$3" "sess-t26"; rc=$?; rmdir "$2.tmp.$$" 2>/dev/null; echo "RC=$rc"' _ "$LIB" "$ARMS_REGISTRY" "$HO26" 2>&1)
if printf '%s' "$t26_out" | grep -q 'RC=0' && printf '%s' "$t26_out" | grep -q 'release-token: sess-t26'; then
    pass "T26: acquire still succeeds when the registry rewrite cannot start"
else
    fail "T26: acquire failed on a registry write failure (out=$t26_out)"
fi
if printf '%s' "$t26_out" | grep -q 'could not rewrite the arms registry'; then
    pass "T26: loud WARN names the skipped consume"
else
    fail "T26: no WARN for the failed registry rewrite (out=$t26_out)"
fi
if grep -q 'HIMMEL-Resume-t26-failopen' "$ARMS_REGISTRY" && [ ! -d "$ARMS_REGISTRY.lock" ]; then
    pass "T26: registry untouched (record stays PENDING) and the arms mutex was released"
else
    fail "T26: registry altered or mutex leaked (reg=$(cat "$ARMS_REGISTRY" 2>/dev/null), lock-exists=$([ -d "$ARMS_REGISTRY.lock" ] && echo yes || echo no))"
fi
bash "$LIB" release "$HO26" "sess-t26" >/dev/null 2>&1
rm -f "$ARMS_REGISTRY"

# --- T27: owner-token mutex theft (HIMMEL-882 CR round-3 Critical, --------
# live-measured): a holder whose rewrite outlives the mutex's 60s mtime
# self-expiry gets RECLAIMED by a contending writer; pre-token, the slow
# holder's blind rmdir then released the THIEF's lock (third writer
# interleaves = silent lost update). Two layers:
# (a) the mutex protocol itself: backdate the held lock dir (fixed 2020
#     stamp, always >60s old), a second acquire reclaims it, and the
#     ORIGINAL holder's release must detect the token mismatch -> WARN +
#     leave the thief's lock in place;
# (b) the full rewrite path: with the mutex owner swapped mid-rewrite, the
#     acquire must SKIP its stale mv (registry unchanged), WARN, and still
#     rc=0 (fail-open).
HO27="$HANDOVER_DIR/HIMMEL-856-test/next-session-27.md"
: > "$HO27"
t27_out=$(bash -c '
    . "$1"
    reg="$2"
    _ql_arms_mutex_acquire "$reg" || { echo "NOACQ"; exit 1; }
    orig="$_QL_ARMS_MUTEX_TOKEN"
    touch -t 202001010000 "$reg.lock"   # 70s-backdated (fixed ancient stamp)
    if _ql_arms_mutex_acquire "$reg"; then echo "RECLAIMED"; fi
    thief="$_QL_ARMS_MUTEX_TOKEN"
    _ql_arms_mutex_release "$reg" "$orig"
    echo "REL_RC=$?"
    if [ -d "$reg.lock" ] && [ "$(cat "$reg.lock/owner" 2>/dev/null)" = "$thief" ]; then
        echo "THIEF_INTACT"
    fi
    _ql_arms_mutex_release "$reg" "$thief" >/dev/null 2>&1
' _ "$LIB" "$ARMS_REGISTRY" 2>&1)
if printf '%s' "$t27_out" | grep -q 'RECLAIMED'; then
    pass "T27: 70s-backdated held mutex is reclaimed by a contender"
else
    fail "T27: backdated mutex was not reclaimed (out=$t27_out)"
fi
if printf '%s' "$t27_out" | grep -q 'REL_RC=1' \
    && printf '%s' "$t27_out" | grep -q 'reclaimed by another writer' \
    && printf '%s' "$t27_out" | grep -q 'THIEF_INTACT'; then
    pass "T27: original holder detects the theft -> WARN + skips rmdir (thief lock intact)"
else
    fail "T27: theft not detected / thief lock clobbered (out=$t27_out)"
fi
printf '{"host":"%s","handover":"%s","fire-at":"202601010000","task-name":"HIMMEL-Resume-t27-victim"}\n' \
    "$THIS_HOST" "$HO27" > "$ARMS_REGISTRY"
# (b): stub the mutex acquire to a no-op holding a token that does NOT
# match the owner file (= the lock was reclaimed mid-rewrite) -- the mv
# must be skipped, no corruption, acquire still rc=0.
t27b_out=$(bash -c '
    . "$1"
    _ql_arms_mutex_acquire() { _QL_ARMS_MUTEX_TOKEN="orig-tok"; return 0; }
    mkdir -p "$2.lock"; printf "%s" "thief-tok" > "$2.lock/owner"
    queue_lock_acquire "$3" "sess-t27b"
    echo "RC=$?"
' _ "$LIB" "$ARMS_REGISTRY" "$HO27" 2>&1)
if printf '%s' "$t27b_out" | grep -q 'RC=0' \
    && printf '%s' "$t27b_out" | grep -q 'reclaimed by another writer' \
    && grep -q 'HIMMEL-Resume-t27-victim' "$ARMS_REGISTRY" \
    && [ "$(cat "$ARMS_REGISTRY.lock/owner" 2>/dev/null)" = "thief-tok" ]; then
    pass "T27: mid-rewrite theft skips the stale mv (no corruption) + acquire stays rc=0"
else
    fail "T27: stale mv not skipped or corruption (out=$t27b_out reg=$(cat "$ARMS_REGISTRY" 2>/dev/null))"
fi
rm -f "$ARMS_REGISTRY.lock/owner"; rmdir "$ARMS_REGISTRY.lock" 2>/dev/null
bash "$LIB" release "$HO27" "sess-t27b" >/dev/null 2>&1
rm -f "$ARMS_REGISTRY"

# --- T31: mutex staleness is RE-PROBED periodically, not just at tries==0 --
# (round-4 sfh-1, live-reproduced): pre-fix, _ql_arms_mutex_acquire probed
# the held lock's mtime staleness ONLY on the first contended iteration. A
# lock that was already ~56s old when the contender started is not yet
# stale at tries==0, so the pre-fix code never re-checked and burned its
# whole ~40-iteration retry budget without reclaiming a lock that crossed
# the 60s threshold mid-wait (an immediate follow-up call reclaimed it
# instantly). The fix re-probes every 10th iteration. Backdate a HELD
# (never-renewed) lock dir's mtime to a fixed ~58s-old absolute epoch stamp
# -- `touch -d "@<epoch>"`, NOT `touch -t`, which parses local wall-clock
# and would silently apply the host's UTC offset -- and assert the acquire
# reclaims it (rc=0) within its bounded retry budget rather than timing out
# (rc=1). The 58s margin is deliberate: it must stay <60s so the PRE-FIX
# single tries==0 probe misses it (the regression this guards), yet be high
# enough that a periodic re-probe crosses 60s within the loop's ~4s sleep
# floor (40 x 0.1s) on FAST platforms too. At 56s the crossing landed AFTER
# the last re-probe (try 30, ~3s -> 59s) on fast Linux -- only slow Windows
# (~8.7s loop) caught it, so CI flaked; at 58s, try 20/30 (>=2s/3s elapsed)
# reach >=60s on every platform.
HO31="$HANDOVER_DIR/HIMMEL-856-test/next-session-31.md"
: > "$HO31"
mkdir -p "$ARMS_REGISTRY.lock"
printf '%s' "stale-holder-tok" > "$ARMS_REGISTRY.lock/owner"
t31_epoch=$(( $(date -u +%s) - 58 ))
touch -d "@$t31_epoch" "$ARMS_REGISTRY.lock"
t31_out=$(bash -c '
    . "$1"
    _ql_arms_mutex_acquire "$2"
    echo "RC=$?"
    echo "TOK=$_QL_ARMS_MUTEX_TOKEN"
' _ "$LIB" "$ARMS_REGISTRY" 2>&1)
if printf '%s' "$t31_out" | grep -q '^RC=0$' && printf '%s' "$t31_out" | grep -q '^TOK=pid'; then
    pass "T31: a ~58s-stale mutex is reclaimed via periodic re-probe within the retry budget"
else
    fail "T31: ~58s-stale mutex was not reclaimed within budget (out=$t31_out)"
fi
rm -f "$ARMS_REGISTRY.lock/owner" 2>/dev/null; rmdir "$ARMS_REGISTRY.lock" 2>/dev/null
rm -f "$ARMS_REGISTRY"

# --- T28: rewrite perf smoke (round-3 Critical): a 300-line registry -------
# rewrite completes in <=5s. The pre-fix grep|head|sed pipelines cost
# ~185-200ms/LINE on Windows/Git-Bash (8+ forks each), so 300 lines
# exceeded the mutex's own 60s expiry; the pure-bash _hp_json_field
# extraction is zero-fork per line. A generous 5s bound still catches any
# O(n)-forks regression.
HO28="$HANDOVER_DIR/HIMMEL-856-test/next-session-28.md"
: > "$HO28"
{
    printf '{"host":"%s","handover":"%s","fire-at":"202601010000","task-name":"HIMMEL-Resume-t28-mine"}\n' "$THIS_HOST" "$HO28"
    t28_i=0
    while [ "$t28_i" -lt 299 ]; do
        printf '{"host":"other-host","handover":"bystander-%s.md","fire-at":"202601010000","task-name":"HIMMEL-Resume-t28-b%s"}\n' "$t28_i" "$t28_i"
        t28_i=$((t28_i + 1))
    done
} > "$ARMS_REGISTRY"
t28_start=$(date +%s)
bash "$LIB" acquire "$HO28" "session-t28" >/dev/null 2>&1
t28_elapsed=$(( $(date +%s) - t28_start ))
if [ "$t28_elapsed" -le 5 ]; then
    pass "T28: 300-line registry rewrite completed in ${t28_elapsed}s (<=5s)"
else
    fail "T28: 300-line rewrite took ${t28_elapsed}s (>5s -- O(n)-forks regression?)"
fi
if [ "$(wc -l < "$ARMS_REGISTRY")" -eq 299 ] && ! grep -q 't28-mine' "$ARMS_REGISTRY"; then
    pass "T28: all 299 bystanders survive, the matching record was consumed"
else
    fail "T28: registry wrong after big rewrite ($(wc -l < "$ARMS_REGISTRY") lines)"
fi
bash "$LIB" release "$HO28" "session-t28" >/dev/null 2>&1
rm -f "$ARMS_REGISTRY"

# --- T29: escaped-quote + backslash values round-trip (round-3: the -------
# parity-aware _hp_json_field replaces the round-2 extractor whose values
# mis-truncated at an escaped quote -- macOS/Linux paths may legally
# contain double quotes). Unit round-trip via the shared lib, then the
# real acquire flow consumes a record whose handover value carries \" and
# backslash runs.
t29_out=$(bash -c '
    . "$1"
    raw="we/ird \"quoted\" \\path\\with\\\\runs"
    _hp_json_escape "$raw"; esc="$_HP_ESC"
    line="{\"host\":\"h\",\"handover\":\"$esc\",\"task-name\":\"t\"}"
    _hp_json_field "$line" handover
    [ "$_HP_FIELD" = "$esc" ] && echo "ROUNDTRIP_OK"
    _hp_json_field "$line" task-name
    [ "$_HP_FIELD" = "t" ] && echo "NEXT_FIELD_OK"
' _ "$SCRIPT_DIR/../lib/handover-path.sh" 2>&1)
if printf '%s' "$t29_out" | grep -q 'ROUNDTRIP_OK' && printf '%s' "$t29_out" | grep -q 'NEXT_FIELD_OK'; then
    pass "T29: escaped-quote + backslash value round-trips through escape->extract"
else
    fail "T29: escaped-quote round-trip broken (out=$t29_out)"
fi
HO29='dir/we ird "quoted" \name-29.md'
t29_esc=$(bash -c '. "$1"; _hp_json_escape "$2"; printf "%s" "$_HP_ESC"' _ "$SCRIPT_DIR/../lib/handover-path.sh" "$HO29")
printf '{"host":"%s","handover":"%s","fire-at":"202601010000","task-name":"HIMMEL-Resume-t29-quoted"}\n' \
    "$THIS_HOST" "$t29_esc" > "$ARMS_REGISTRY"
bash "$LIB" acquire "$HO29" "session-t29" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && ! grep -q 'HIMMEL-Resume-t29-quoted' "$ARMS_REGISTRY"; then
    pass "T29: acquire consumes a record whose path value carries quotes + backslashes"
else
    fail "T29: quoted-path record not consumed (rc=$rc reg=$(cat "$ARMS_REGISTRY" 2>/dev/null))"
fi
QUEUE_LOCK_FORCE_RELEASE=1 bash "$LIB" release "$HO29" >/dev/null 2>&1
rm -f "$ARMS_REGISTRY"

# --- T32: takeover-claim mkdir co-winner loses the owner-file arbiter -----
# Simulate uutils returning rc=0 after another taker already created and
# branded the same claim. The loser must not remove the winner's claim or
# advance far enough to destroy the stale lock generation.
HO32="$HANDOVER_DIR/HIMMEL-856-test/next-session-32.md"
: > "$HO32"
LOCKDIR32="$HANDOVER_DIR/.locks/queue/HIMMEL-856-test__next-session-32.lock"
mkdir -p "$LOCKDIR32"
printf '{"session":"dead-session","host":"old-host","handover":"%s","started":"2020-01-01T00:00:00Z","heartbeat":"2020-01-01T00:00:00Z"}\n' \
    "$HO32" > "$LOCKDIR32/owner.json"
t32_out=$(bash -c '
    . "$1"
    lockdir="$2"
    claim="${lockdir}.claim"
    mkdir() {
        if [ "${1:-}" = "$claim" ]; then
            command mkdir -p "$claim"
            printf "%s" "winner-claim" > "$claim/owner"
            return 0
        fi
        command mkdir "$@"
    }
    queue_lock_acquire "$3" "loser-claim" >/dev/null 2>&1
    echo "RC=$?"
    echo "CLAIM_OWNER=$(cat "$claim/owner" 2>/dev/null)"
    echo "LOCK_OWNER=$(cat "$lockdir/owner.json" 2>/dev/null)"
' _ "$LIB" "$LOCKDIR32" "$HO32" 2>&1)
if printf '%s' "$t32_out" | grep -q '^RC=2$' \
    && printf '%s' "$t32_out" | grep -q '^CLAIM_OWNER=winner-claim$' \
    && printf '%s' "$t32_out" | grep -q 'LOCK_OWNER=.*"session":"dead-session"'; then
    pass "T32: claim-arbiter loser leaves winner claim + stale generation intact"
else
    fail "T32: claim-arbiter loser damaged winner state (out=$t32_out)"
fi
rm -rf "$LOCKDIR32" "${LOCKDIR32}.claim"

# --- T33: post-rm lockdir mkdir co-winner loses owner-file arbiter --------
# The first lockdir mkdir sees the stale fixture. On the post-rm mkdir,
# simulate a concurrent fresh winner plus uutils' false rc=0 for this loser.
# The loser must preserve both the winner's arbiter and owner.json.
HO33="$HANDOVER_DIR/HIMMEL-856-test/next-session-33.md"
: > "$HO33"
LOCKDIR33="$HANDOVER_DIR/.locks/queue/HIMMEL-856-test__next-session-33.lock"
mkdir -p "$LOCKDIR33"
printf '{"session":"dead-session","host":"old-host","handover":"%s","started":"2020-01-01T00:00:00Z","heartbeat":"2020-01-01T00:00:00Z"}\n' \
    "$HO33" > "$LOCKDIR33/owner.json"
t33_out=$(bash -c '
    . "$1"
    lockdir="$2"
    ho="$3"
    lockdir_mkdir_count=0
    mkdir() {
        if [ "${1:-}" = "$lockdir" ]; then
            lockdir_mkdir_count=$((lockdir_mkdir_count + 1))
            if [ "$lockdir_mkdir_count" -eq 2 ]; then
                command mkdir -p "$lockdir"
                printf "%s" "winner-reacquire" > "$lockdir/owner"
                printf "{\"session\":\"winner-reacquire\",\"host\":\"winner-host\",\"handover\":\"%s\",\"started\":\"2026-01-01T00:00:00Z\",\"heartbeat\":\"2026-01-01T00:00:00Z\"}\n" "$ho" > "$lockdir/owner.json"
                return 0
            fi
        fi
        command mkdir "$@"
    }
    queue_lock_acquire "$ho" "loser-reacquire" >/dev/null 2>&1
    echo "RC=$?"
    echo "ARBITER=$(cat "$lockdir/owner" 2>/dev/null)"
    echo "LOCK_OWNER=$(cat "$lockdir/owner.json" 2>/dev/null)"
    [ -e "${lockdir}.claim" ] && echo "CLAIM_LEFT=yes" || echo "CLAIM_LEFT=no"
' _ "$LIB" "$LOCKDIR33" "$HO33" 2>&1)
if printf '%s' "$t33_out" | grep -q '^RC=2$' \
    && printf '%s' "$t33_out" | grep -q '^ARBITER=winner-reacquire$' \
    && printf '%s' "$t33_out" | grep -q 'LOCK_OWNER=.*"session":"winner-reacquire"' \
    && printf '%s' "$t33_out" | grep -q '^CLAIM_LEFT=no$'; then
    pass "T33: post-rm arbiter loser leaves winner lock intact + drops own claim"
else
    fail "T33: post-rm arbiter loser damaged winner state (out=$t33_out)"
fi
rm -rf "$LOCKDIR33" "${LOCKDIR33}.claim"

echo "---"
echo "PASSED=$PASSED FAILED=$FAILED"
[ "$FAILED" = 0 ]
