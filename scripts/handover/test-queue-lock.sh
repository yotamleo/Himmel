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

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone. (HIMMEL-1430.)
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/queue-lock.sh"
# shellcheck source=../lib/py-armor.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/py-armor.sh"
# shellcheck source=../lib/handover-path.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/handover-path.sh"

PASSED=0
FAILED=0
pass() { echo "PASS: $1"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL: $1"; FAILED=$((FAILED + 1)); }

TMPDIR_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

HANDOVER_DIR="$TMPDIR_ROOT/handovers"
mkdir -p "$HANDOVER_DIR"
export HANDOVER_DIR

# HIMMEL-2813: `acquire` persists the release token under XDG_RUNTIME_DIR,
# so this suite MUST point that at a temp dir too -- otherwise every acquire
# in every test writes into the operator's real /run/user/<uid>/ runtime dir.
# Same hermeticity rule as HANDOVER_DIR above: never the real thing.
XDG_RUNTIME_DIR="$TMPDIR_ROOT/xdg"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
export XDG_RUNTIME_DIR
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
if grepq "$out" '^release-token: session-a$'; then
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
if grepq "$err" 'session=session-a' && grepq "$err" -i 'QUEUE_LOCK_TAKEOVER'; then
    pass "T2: stderr has holder info + takeover override hint"
else
    fail "T2: stderr missing holder info / override hint: $err"
fi

# --- T3: status FRESH -> rc 11 + owner contents ------------------------------
out="$(bash "$LIB" status "$HO1" 2>&1)"
rc=$?
if [ "$rc" -eq 11 ] && grepq "$out" '"session":"session-a"' && grepq "$out" -i 'FRESH'; then
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

# --- T6: release of an absent lock (with a token) reports it, rc 3 ---------
# CONTRACT CHANGE (HIMMEL-2861): this used to be a silent rc=0 "idempotent"
# release. Idempotency was indistinguishable from the failure it hid -- a
# release that looked in the wrong handover root also found nothing and
# also said 0, so six legs on 2026-09-09 reported a clean wrap over a lock
# that was still HELD. Nothing-released is now its own exit code.
out="$(bash "$LIB" release "$HO1" "any-token" 2>&1)"
rc=$?
if [ "$rc" -eq 3 ]; then
    pass "T6: release of absent lock rc=3 (nothing was released)"
else
    fail "T6: release of absent lock rc=3 (got $rc: $out)"
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
if [ "$rc" -eq 12 ] && grepq "$out" -i 'STALE'; then
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
if grepq "$err" -i 'forced'; then
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
# HIMMEL-2813: acquire now also PERSISTS the token, and a token-less
# release legitimately recalls it. T15's contract is the one that did not
# change -- with no token available ANYWHERE, release/heartbeat still
# refuse rc=2 -- so drop the persisted copy first and assert exactly that.
# (T56 covers the recall path, T61 the no-file refusal from the other side.)
rm -f "$XDG_RUNTIME_DIR/himmel-queue-lock/"*
err="$(bash "$LIB" release "$HO15" 2>&1 1>/dev/null)"
rc=$?
if [ "$rc" -eq 2 ] && [ -d "$LOCKDIR15" ]; then
    pass "T15: token-less release refused rc=2, lock still held"
else
    fail "T15: token-less release refused rc=2 + held (got rc=$rc, dir-exists=$([ -d "$LOCKDIR15" ] && echo yes || echo no))"
fi
if grepq "$err" 'session-t15' && grepq "$err" 'QUEUE_LOCK_FORCE_RELEASE'; then
    pass "T15: refusal names the current holder + the emergency override"
else
    fail "T15: refusal missing holder info / override hint: $err"
fi
rm -f "$XDG_RUNTIME_DIR/himmel-queue-lock/"*
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
if grepq "$t16_out" 'RC=1' && [ ! -d "$LOCKDIR16" ]; then
    pass "T16: failed owner write -> rc=1 and the lock dir is removed"
else
    fail "T16: failed owner write (out=$t16_out, dir-exists=$([ -d "$LOCKDIR16" ] && echo yes || echo no))"
fi
if grepq "$t16_out" 'acquire FAILED' && ! grepq "$t16_out" 'release-token:'; then
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
if [ "$rc" -eq 11 ] && grepq "$out" 'CORRUPT'; then
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
if [ "$rc" -eq 11 ] && grepq "$err" -i 'AGING'; then
    pass "T18: FRESH lock past half-TTL warns AGING (rc stays 11)"
else
    fail "T18: aging warning (got rc=$rc err=$err)"
fi
printf '{"session":"ager","host":"h","handover":"%s","started":"garbage","heartbeat":"garbage"}\n' \
    "$HO18" > "$LOCKDIR18/owner.json"
err="$(bash "$LIB" status "$HO18" 2>&1 1>/dev/null)"
rc=$?
if [ "$rc" -eq 11 ] && grepq "$err" -i 'could not parse heartbeat'; then
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
if grepq "$err" -i 'consumed'; then
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
if grepq "$err" -i 'consumed' && ! grep -q 't21-solo' "$ARMS_REGISTRY"; then
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

# --- T31: new-format canonical key consumes the RIGHT record (HIMMEL-1344) --
# The record's raw handover spelling deliberately differs from the acquire
# argument. Matching must use handover-key, drop only this host's target row,
# and leave the sibling key untouched. Fired records are retained by deletion
# in the current format, so disappearance is the consume-on-fire proof.
HO31="$HANDOVER_DIR/HIMMEL-856-test/next-session-31.md"
HO31_ALT="$HANDOVER_DIR/HIMMEL-856-test/../HIMMEL-856-test/next-session-31.md"
HO31_SIB="$HANDOVER_DIR/HIMMEL-856-test/next-session-31b.md"
: > "$HO31"
: > "$HO31_SIB"
HO31_KEY=$(_arm_registry_identity_path "$HO31" "$HANDOVER_DIR")
HO31_SIB_KEY=$(_arm_registry_identity_path "$HO31_SIB" "$HANDOVER_DIR")
{
    printf '{"host":"%s","handover":"%s","handover-key":"%s","ticket":"HIMMEL-1344","fire-at":"202601010000","task-name":"HIMMEL-Resume-t31-target"}\n' \
        "$THIS_HOST" "$HO31_ALT" "$HO31_KEY"
    printf '{"host":"%s","handover":"%s","handover-key":"%s","ticket":"HIMMEL-1344","fire-at":"202601010000","task-name":"HIMMEL-Resume-t31-sibling"}\n' \
        "$THIS_HOST" "$HO31_SIB" "$HO31_SIB_KEY"
} > "$ARMS_REGISTRY"
err="$(bash "$LIB" acquire "$HO31" "session-t31" 2>&1 1>/dev/null)"
rc=$?
if [ "$rc" -eq 0 ] && ! grep -q 'HIMMEL-Resume-t31-target' "$ARMS_REGISTRY"; then
    pass "T31: canonical key consumes alternate-spelling target record"
else
    fail "T31: canonical target was not consumed (rc=$rc err=$err reg=$(cat "$ARMS_REGISTRY" 2>/dev/null))"
fi
if grep -q 'HIMMEL-Resume-t31-sibling' "$ARMS_REGISTRY" && [ "$(wc -l < "$ARMS_REGISTRY")" -eq 1 ]; then
    pass "T31: sibling canonical key survives untouched"
else
    fail "T31: wrong record consumed or sibling corrupted ($(cat "$ARMS_REGISTRY" 2>/dev/null))"
fi
bash "$LIB" release "$HO31" "session-t31" >/dev/null 2>&1

# --- T31b: legacy raw-only alternate spelling is still consumed -----------
# Migration coverage for records written before HIMMEL-1344: no handover-key
# exists, so acquire must canonicalize the stored raw spelling and retire it.
printf '{"host":"%s","handover":"%s","fire-at":"202601010000","task-name":"HIMMEL-Resume-t31b-legacy"}\n' \
    "$THIS_HOST" "$HO31_ALT" > "$ARMS_REGISTRY"
err="$(bash "$LIB" acquire "$HO31" "session-t31b" 2>&1 1>/dev/null)"
rc=$?
if [ "$rc" -eq 0 ] && ! grep -q 'HIMMEL-Resume-t31b-legacy' "$ARMS_REGISTRY"; then
    pass "T31b: legacy raw-only alternate spelling is consumed during migration"
else
    fail "T31b: legacy alternate-spelling record was not consumed (rc=$rc err=$err reg=$(cat "$ARMS_REGISTRY" 2>/dev/null))"
fi
bash "$LIB" release "$HO31" "session-t31b" >/dev/null 2>&1

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
if [ "$rc" -eq 0 ] && grepq "$err" -i 'took over'; then
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
if grepq "$t26_out" 'RC=0' && grepq "$t26_out" 'release-token: sess-t26'; then
    pass "T26: acquire still succeeds when the registry rewrite cannot start"
else
    fail "T26: acquire failed on a registry write failure (out=$t26_out)"
fi
if grepq "$t26_out" 'could not rewrite the arms registry'; then
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
if grepq "$t27_out" 'RECLAIMED'; then
    pass "T27: 70s-backdated held mutex is reclaimed by a contender"
else
    fail "T27: backdated mutex was not reclaimed (out=$t27_out)"
fi
if grepq "$t27_out" 'REL_RC=1' \
    && grepq "$t27_out" 'reclaimed by another writer' \
    && grepq "$t27_out" 'THIEF_INTACT'; then
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
if grepq "$t27b_out" 'RC=0' \
    && grepq "$t27b_out" 'reclaimed by another writer' \
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
if grepq "$t31_out" '^RC=0$' && grepq "$t31_out" '^TOK=pid'; then
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

# --- T28b: SAME-HOST legacy rewrite against the real mutex lease -----------
# T28 above measures the fork-FREE path only: its 299 bystanders are
# other-host, and queue-lock.sh calls _hp_arms_record_matches_path exclusively
# for rows whose host matches this one, so those bystanders never reach the
# matcher at all. The expensive path is same-host legacy rows: each one that
# does not match exactly falls through to the canonical-migration fallback,
# which spends a command substitution on _arm_registry_identity_path, and that
# forks realpath plus cygpath/tr on Windows -- per record, INSIDE the arms
# mutex. Blowing the mutex lease is not a slow test, it is a discarded rewrite:
# the arm stays pending-but-unregistered, or a fired record never clears.
#
# So this case is deliberately pinned to the LEASE, not to an ambition
# (HIMMEL-1344 CR round). It ALWAYS prints the measurement, WARNs at the
# halfway mark so a slow drift is visible before it bites, and FAILs only when
# the rewrite approaches the lease itself -- the point at which the behaviour
# under test genuinely breaks. That is why a wall-clock bound is legitimate
# here and is not a second T28 (see HIMMEL-1661): crossing it IS the failure
# mode, and the budget is an order of magnitude above the noise.
t28b_lease=$(sed -n 's/^_QL_ARMS_MUTEX_STALE_SECS=\([0-9][0-9]*\).*/\1/p' "$LIB" | head -1)
if [ -z "$t28b_lease" ]; then
    fail "T28b: cannot read _QL_ARMS_MUTEX_STALE_SECS from $LIB -- the lease constant moved or was renamed; re-point this test at it"
else
    HO28B="$HANDOVER_DIR/HIMMEL-856-test/next-session-28b.md"
    : > "$HO28B"
    {
        printf '{"host":"%s","handover":"%s","fire-at":"202601010000","task-name":"HIMMEL-Resume-t28b-mine"}\n' "$THIS_HOST" "$HO28B"
        t28b_i=0
        while [ "$t28b_i" -lt 299 ]; do
            # SAME host, legacy shape (no handover-key) -> every one of these
            # reaches the canonicalizing fallback.
            printf '{"host":"%s","handover":"%s/bystander-%s.md","fire-at":"202601010000","task-name":"HIMMEL-Resume-t28b-b%s"}\n' "$THIS_HOST" "$HANDOVER_DIR" "$t28b_i" "$t28b_i"
            t28b_i=$((t28b_i + 1))
        done
    } > "$ARMS_REGISTRY"
    t28b_start=$(date +%s)
    bash "$LIB" acquire "$HO28B" "session-t28b" >/dev/null 2>&1
    t28b_elapsed=$(( $(date +%s) - t28b_start ))
    t28b_warn=$(( t28b_lease / 2 ))
    echo "MEASURE T28b: 300-row SAME-HOST legacy rewrite took ${t28b_elapsed}s (mutex lease ${t28b_lease}s, warn >${t28b_warn}s)"
    if [ "$t28b_elapsed" -ge "$t28b_lease" ]; then
        fail "T28b: same-host legacy rewrite took ${t28b_elapsed}s, at/over the ${t28b_lease}s mutex lease -- the rewrite can be discarded and an arm left pending-but-unregistered"
    else
        if [ "$t28b_elapsed" -gt "$t28b_warn" ]; then
            echo "WARN T28b: ${t28b_elapsed}s is past half the ${t28b_lease}s lease -- per-record forking is trending toward the lease; see the hoist/memoize follow-up"
        fi
        pass "T28b: same-host legacy rewrite stayed under the ${t28b_lease}s mutex lease (${t28b_elapsed}s)"
    fi
    if [ "$(wc -l < "$ARMS_REGISTRY")" -eq 299 ] && ! grep -q 't28b-mine' "$ARMS_REGISTRY"; then
        pass "T28b: all 299 same-host bystanders survive, the matching record was consumed"
    else
        fail "T28b: registry wrong after same-host rewrite ($(wc -l < "$ARMS_REGISTRY") lines)"
    fi
    bash "$LIB" release "$HO28B" "session-t28b" >/dev/null 2>&1
    rm -f "$ARMS_REGISTRY"
fi

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
if grepq "$t29_out" 'ROUNDTRIP_OK' && grepq "$t29_out" 'NEXT_FIELD_OK'; then
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
if grepq "$t32_out" '^RC=2$' \
    && grepq "$t32_out" '^CLAIM_OWNER=winner-claim$' \
    && grepq "$t32_out" 'LOCK_OWNER=.*"session":"dead-session"'; then
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
if grepq "$t33_out" '^RC=2$' \
    && grepq "$t33_out" '^ARBITER=winner-reacquire$' \
    && grepq "$t33_out" 'LOCK_OWNER=.*"session":"winner-reacquire"' \
    && grepq "$t33_out" '^CLAIM_LEFT=no$'; then
    pass "T33: post-rm arbiter loser leaves winner lock intact + drops own claim"
else
    fail "T33: post-rm arbiter loser damaged winner state (out=$t33_out)"
fi
rm -rf "$LOCKDIR33" "${LOCKDIR33}.claim"

# --- T34: consume path survives a pre-HIMMEL-1344 handover-path.sh ---------
# queue-lock.sh's fallbacks must let `acquire` survive a partially-deployed
# library that still exports handover_root + JSON helpers but deliberately
# lacks the HIMMEL-1344 identity + matcher. The test-owned fixture pins that
# property; deriving it from main would silently stop testing skew after merge.
FAKE_QL="$TMPDIR_ROOT/fake-ql-pre1344"
PRE_1344_LIB="$SCRIPT_DIR/fixtures/handover-path-pre-himmel-1344.sh"
mkdir -p "$FAKE_QL/handover" "$FAKE_QL/lib"
cp "$SCRIPT_DIR/queue-lock.sh" "$FAKE_QL/handover/queue-lock.sh"
cp "$SCRIPT_DIR/../lib/py-armor.sh" "$FAKE_QL/lib/py-armor.sh"
if cp "$PRE_1344_LIB" "$FAKE_QL/lib/handover-path.sh" \
    && ! grep -q '^_arm_registry_identity_path()' "$FAKE_QL/lib/handover-path.sh" \
    && ! grep -q '^_hp_arms_record_matches_path()' "$FAKE_QL/lib/handover-path.sh"; then
    HO34="$HANDOVER_DIR/HIMMEL-856-test/next-session-34.md"
    : > "$HO34"
    printf '{"host":"%s","handover":"%s","fire-at":"202601010000","task-name":"HIMMEL-Resume-t34"}\n' \
        "$THIS_HOST" "$HO34" > "$ARMS_REGISTRY"
    err="$(bash "$FAKE_QL/handover/queue-lock.sh" acquire "$HO34" "session-t34" 2>&1 1>/dev/null)"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        pass "T34: acquire against a pre-1344 handover-path.sh does not abort"
    else
        fail "T34: acquire against a pre-1344 handover-path.sh aborted (rc=$rc: $err)"
    fi
    bash "$FAKE_QL/handover/queue-lock.sh" release "$HO34" "session-t34" >/dev/null 2>&1
else
    fail "T34: pre-1344 fixture missing or unexpectedly defines HIMMEL-1344 helpers"
fi
rm -f "$ARMS_REGISTRY"


# --- T35: close-evidence emit fires on a real release, NEVER on a force ----
# HIMMEL-2294. `_ql_emit_close_evidence` declares THIS session closable so
# flow-exporter.ts can drop it from session_dead_total. Two invariants, and
# the NEGATIVE one is the load-bearing half: a force-release is a stranger
# cleaning up someone else's stranded lock, so emitting there would key a
# close row to the CLEANER's still-live session and permanently exempt it
# from the gauge -- a false negative in the very alert this reconciler
# fixes. Nothing else guards that, and it is a one-line "helpful" edit away
# from regressing. `bun` is stubbed via a PATH shim script (NOT a shell
# function -- CR fix codex-2 wraps the real call in `timeout` when present,
# and `timeout` execs its command directly, so a shell function defined in
# the same process is invisible to it; a PATH-resolvable executable is not)
# so the probe records the call without ever spawning the real writer or
# touching a ledger, whichever branch `_ql_emit_close_evidence` takes.
HO35="$HANDOVER_DIR/HIMMEL-856-test/next-session-35.md"
: > "$HO35"
T35_PROBE="$TMPDIR_ROOT/t35-emit-probe"
T35_BIN="$TMPDIR_ROOT/t35-bin"
mkdir -p "$T35_BIN"
cat > "$T35_BIN/bun" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$T35_PROBE_FILE"
EOF
chmod +x "$T35_BIN/bun"
t35_out=$(bash -c '
    . "$1"
    ho="$2"
    probe="$3"
    bindir="$4"
    export PATH="$bindir:$PATH"
    export T35_PROBE_FILE="$probe"
    queue_lock_acquire "$ho" "session-t35" >/dev/null 2>&1
    queue_lock_release "$ho" "session-t35" >/dev/null 2>&1
    echo "NORMAL_RC=$?"
    echo "NORMAL_EMITS=$( [ -f "$probe" ] && wc -l < "$probe" | tr -d " " || echo 0 )"
    echo "NORMAL_ARGS=$(cat "$probe" 2>/dev/null)"
    rm -f "$probe"
    queue_lock_acquire "$ho" "session-t35b" >/dev/null 2>&1
    QUEUE_LOCK_FORCE_RELEASE=1 queue_lock_release "$ho" >/dev/null 2>&1
    echo "FORCE_RC=$?"
    echo "FORCE_EMITS=$( [ -f "$probe" ] && wc -l < "$probe" | tr -d " " || echo 0 )"
' _ "$LIB" "$HO35" "$T35_PROBE" "$T35_BIN" 2>&1)
if grepq "$t35_out" '^NORMAL_RC=0$' \
    && grepq "$t35_out" '^NORMAL_EMITS=1$' \
    && grepq "$t35_out" '^NORMAL_ARGS=.*session-close --evidence queue_lock_release' \
    && grepq "$t35_out" '^FORCE_RC=0$' \
    && grepq "$t35_out" '^FORCE_EMITS=0$'; then
    pass "T35: close evidence emitted on token release, never on force-release"
else
    fail "T35: close-evidence emit contract broken (out=$t35_out)"
fi
rm -f "$T35_PROBE"
rm -rf "$T35_BIN"

# --- T36: idle-warn "possibly stuck on a prompt" (HIMMEL-2381) -------------
# A FRESH lock (age < ttl) whose heartbeat exceeds QUEUE_LOCK_IDLE_WARN_SECONDS
# (default 2700s) warns distinctly from the half-TTL AGING warning (T18) --
# the idle-warn threshold is meant to catch a hung interactive-permission
# prompt within minutes, well before the hours-scale TTL/aging thresholds
# would say anything.
HO36="$HANDOVER_DIR/HIMMEL-856-test/next-session-36.md"
: > "$HO36"
LOCKDIR36="$HANDOVER_DIR/.locks/queue/HIMMEL-856-test__next-session-36.lock"
mkdir -p "$LOCKDIR36"
t36_hb=$(date -u -d "@$(( $(date -u +%s) - 3000 ))" +%Y-%m-%dT%H:%M:%SZ)
printf '{"session":"idler","host":"h","handover":"%s","started":"%s","heartbeat":"%s"}\n' \
    "$HO36" "$t36_hb" "$t36_hb" > "$LOCKDIR36/owner.json"
# age ~3000s: past the default 2700s idle-warn but far short of the default
# 21600s TTL (half=10800s), so idle-warn fires and AGING must not.
err=$(bash "$LIB" status "$HO36" 2>&1 1>/dev/null)
rc=$?
if [ "$rc" -eq 11 ] && grepq "$err" -i 'possibly stuck on a prompt' && ! grepq "$err" -i 'AGING'; then
    pass "T36: FRESH lock past idle-warn (default 2700s) warns 'possibly stuck on a prompt', not AGING"
else
    fail "T36: idle-warn warning (got rc=$rc err=$err)"
fi
# QUEUE_LOCK_IDLE_WARN_SECONDS override: raising the threshold above the
# observed age must silence the warning.
err=$(QUEUE_LOCK_IDLE_WARN_SECONDS=9000 bash "$LIB" status "$HO36" 2>&1 1>/dev/null)
rc=$?
if [ "$rc" -eq 11 ] && ! grepq "$err" -i 'possibly stuck on a prompt'; then
    pass "T36: QUEUE_LOCK_IDLE_WARN_SECONDS override raises the threshold (no warning below it)"
else
    fail "T36: idle-warn override (got rc=$rc err=$err)"
fi
QUEUE_LOCK_FORCE_RELEASE=1 bash "$LIB" release "$HO36" >/dev/null 2>&1

# --- T37: sweep with no locks at all -> rc=0, explicit "no held locks" ----
# (HIMMEL-2369). A fresh handover root under its own mktemp dir, never
# touching the real ~/.himmel / ~/.claude state -- verify the resolved root
# is actually this fixture before asserting on it (this suite has clobbered
# real user state before by leaving an env var empty).
SWEEP_ROOT="$TMPDIR_ROOT/sweep-root"
mkdir -p "$SWEEP_ROOT"
resolved_root=$(HANDOVER_DIR="$SWEEP_ROOT" bash -c '. "$1"; handover_root_ensure' _ "$SCRIPT_DIR/../lib/handover-path.sh")
if [ "$resolved_root" = "$SWEEP_ROOT" ]; then
    pass "T37: fixture root actually resolves as the handover root (not real state)"
else
    fail "T37: handover_root_ensure resolved '$resolved_root', expected '$SWEEP_ROOT' -- refusing to proceed with sweep fixtures"
fi
out="$(HANDOVER_DIR="$SWEEP_ROOT" bash "$LIB" status --sweep 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && grepq "$out" '^sweep: no held locks$'; then
    pass "T37: sweep with no locks at all -> rc=0, explicit no-held-locks line"
else
    fail "T37: sweep with no locks (got rc=$rc out=$out)"
fi

# --- T38: sweep with a FRESH lock -> present, NOT flagged -------------------
SWEEP_QDIR="$SWEEP_ROOT/.locks/queue"
mkdir -p "$SWEEP_QDIR"
FRESH_SLUG="HIMMEL-2369-test__fresh"
FRESH_LOCKDIR="$SWEEP_QDIR/$FRESH_SLUG.lock"
mkdir -p "$FRESH_LOCKDIR"
fresh_hb="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"session":"sweep-fresh","host":"h","handover":"fresh.md","started":"%s","heartbeat":"%s"}\n' \
    "$fresh_hb" "$fresh_hb" > "$FRESH_LOCKDIR/owner.json"
out="$(HANDOVER_DIR="$SWEEP_ROOT" bash "$LIB" status --sweep 2>&1)"
rc=$?
if [ -n "$out" ] && grepq "$out" "$FRESH_SLUG"; then
    pass "T38: positive control -- sweep output is non-empty and names the fresh fixture slug"
else
    fail "T38: sweep output missing/empty, or missing the fresh slug (out=$out)"
fi
if [ "$rc" -eq 0 ] && grepq "$out" "slug=$FRESH_SLUG session=sweep-fresh host=h" && ! grepq "$out" "$FRESH_SLUG.*IDLE-HELD"; then
    pass "T38: FRESH lock present in sweep output, NOT flagged, rc=0"
else
    fail "T38: FRESH lock should be present + unflagged, rc=0 (got rc=$rc out=$out)"
fi
rm -rf "$FRESH_LOCKDIR"

# --- T39: sweep with an OLD lock -> flagged IDLE-HELD?, rc=20 --------------
OLD_SLUG="HIMMEL-2369-test__old"
OLD_LOCKDIR="$SWEEP_QDIR/$OLD_SLUG.lock"
mkdir -p "$OLD_LOCKDIR"
# Fixed ancient literal (same convention as T9/T14/T18/T24/T32/T33 -- NOT
# `date -d`, which is GNU-only and breaks on BSD/macOS, codex-4). The sweep
# has no half-TTL AGING check to disambiguate from (unlike T36), so an
# ancient fixed date is unambiguous: it is well past the idle-warn threshold
# and needs no date arithmetic at all.
printf '{"session":"sweep-old","host":"h","handover":"old.md","started":"2020-01-01T00:00:00Z","heartbeat":"2020-01-01T00:00:00Z"}\n' \
    > "$OLD_LOCKDIR/owner.json"
out="$(HANDOVER_DIR="$SWEEP_ROOT" bash "$LIB" status --sweep 2>&1)"
rc=$?
if [ "$rc" -eq 20 ] && grepq "$out" "slug=$OLD_SLUG session=sweep-old host=h" && grepq "$out" "$OLD_SLUG.*IDLE-HELD"; then
    pass "T39: OLD lock (heartbeat past idle-warn threshold) flagged IDLE-HELD?, rc=20"
else
    fail "T39: OLD lock should be flagged, rc=20 (got rc=$rc out=$out)"
fi

# --- T40: fresh + old together -- BOTH lines appear, flagged one does not --
# suppress the other (the load-bearing property: exactly the check that
# proves a flagged lock does not hide its siblings).
mkdir -p "$FRESH_LOCKDIR"
printf '{"session":"sweep-fresh","host":"h","handover":"fresh.md","started":"%s","heartbeat":"%s"}\n' \
    "$fresh_hb" "$fresh_hb" > "$FRESH_LOCKDIR/owner.json"
out="$(HANDOVER_DIR="$SWEEP_ROOT" bash "$LIB" status --sweep 2>&1)"
rc=$?
if [ "$rc" -eq 20 ]; then
    pass "T40: fresh+old together -> rc=20 (at least one flagged)"
else
    fail "T40: fresh+old together should be rc=20 (got $rc)"
fi
if grepq "$out" "slug=$FRESH_SLUG.*status=OK" && grepq "$out" "slug=$OLD_SLUG.*status=IDLE-HELD"; then
    pass "T40: BOTH lines present -- flagged lock does not suppress the unflagged one"
else
    fail "T40: expected both a status=OK fresh line and an IDLE-HELD old line (out=$out)"
fi

# --- T41: negative control -- a very high QUEUE_LOCK_IDLE_WARN_SECONDS -----
# un-flags the OLD lock and drops the exit code to 0, proving the flag
# tracks the knob rather than being hardcoded (mirrors T36's override check).
# OLD_LOCKDIR's heartbeat is the fixed "2020-01-01T00:00:00Z" literal (its
# age is ~2e8s and growing every year this suite runs), so the override
# must clear that, not just a few thousand seconds -- 999999999s (~31.7yr)
# comfortably outlives it.
out="$(HANDOVER_DIR="$SWEEP_ROOT" QUEUE_LOCK_IDLE_WARN_SECONDS=999999999 bash "$LIB" status --sweep 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && ! grepq "$out" 'IDLE-HELD'; then
    pass "T41: negative control -- QUEUE_LOCK_IDLE_WARN_SECONDS raised above every age -> nothing flagged, rc=0"
else
    fail "T41: negative control failed (got rc=$rc out=$out)"
fi
rm -rf "$FRESH_LOCKDIR" "$OLD_LOCKDIR"

# --- T42: corrupt locks (missing owner.json, and garbage content) are ------
# reported on their own line rather than skipped silently, and do not abort
# the sweep -- a fresh sibling lock still appears.
CORRUPT1_SLUG="HIMMEL-2369-test__corrupt-missing"
CORRUPT1_LOCKDIR="$SWEEP_QDIR/$CORRUPT1_SLUG.lock"
mkdir -p "$CORRUPT1_LOCKDIR"   # no owner.json at all
# Backdate past _QL_SWEEP_CORRUPT_GRACE_SECS (HIMMEL-2369 CR round-2,
# codex-2): a FRESHLY-created missing-owner dir is now INDETERMINATE, not
# CORRUPT (see T44) -- this fixture needs to be a genuinely OLD miss to
# still exercise the CORRUPT path T42 is about.
t42_grace=$(sed -n 's/^_QL_SWEEP_CORRUPT_GRACE_SECS=\([0-9][0-9]*\).*/\1/p' "$LIB" | head -1)
touch -d "@$(( $(date -u +%s) - ${t42_grace:-5} - 60 ))" "$CORRUPT1_LOCKDIR"
CORRUPT2_SLUG="HIMMEL-2369-test__corrupt-garbage"
CORRUPT2_LOCKDIR="$SWEEP_QDIR/$CORRUPT2_SLUG.lock"
mkdir -p "$CORRUPT2_LOCKDIR"
printf 'not json at all' > "$CORRUPT2_LOCKDIR/owner.json"
mkdir -p "$FRESH_LOCKDIR"
printf '{"session":"sweep-fresh","host":"h","handover":"fresh.md","started":"%s","heartbeat":"%s"}\n' \
    "$fresh_hb" "$fresh_hb" > "$FRESH_LOCKDIR/owner.json"
out="$(HANDOVER_DIR="$SWEEP_ROOT" bash "$LIB" status --sweep 2>&1)"
rc=$?
if grepq "$out" "slug=$CORRUPT1_SLUG.*CORRUPT" && grepq "$out" "slug=$CORRUPT2_SLUG.*CORRUPT"; then
    pass "T42: both a missing-owner.json lock and a garbage-content lock are reported CORRUPT"
else
    fail "T42: corrupt locks not both reported (out=$out)"
fi
if grepq "$out" "slug=$FRESH_SLUG.*status=OK"; then
    pass "T42: a corrupt lock does not abort the sweep -- the fresh sibling still appears"
else
    fail "T42: fresh sibling missing from sweep output after corrupt locks were present (out=$out)"
fi
if [ "$rc" -eq 20 ]; then
    pass "T42: at least one CORRUPT lock -> rc=20 (corrupt counts as flagged, same fail-closed posture as the single-queue status path)"
else
    fail "T42: expected rc=20 with corrupt locks present (got $rc)"
fi
rm -rf "$CORRUPT1_LOCKDIR" "$CORRUPT2_LOCKDIR" "$FRESH_LOCKDIR"

# --- T43: a partially-parseable owner is NOT healthy just because one -----
# field survived (HIMMEL-2369 CR round-1, codex-1): the CORRUPT check only
# trips when session/host/heartbeat are ALL empty, so an owner.json missing
# just its heartbeat -- or one where the heartbeat is present but garbage --
# used to fall through to status=OK age=unknown, a clean-looking verdict for
# a lock this sweep could not actually assess. Both shapes must now be
# FLAGGED (status=UNKNOWN) and the sweep must exit 20, never 0.
SESSIONONLY_SLUG="HIMMEL-2369-test__session-only"
SESSIONONLY_LOCKDIR="$SWEEP_QDIR/$SESSIONONLY_SLUG.lock"
mkdir -p "$SESSIONONLY_LOCKDIR"
printf '{"session":"sweep-sessiononly"}\n' > "$SESSIONONLY_LOCKDIR/owner.json"
out="$(HANDOVER_DIR="$SWEEP_ROOT" bash "$LIB" status --sweep 2>&1)"
rc=$?
if [ "$rc" -eq 20 ] && grepq "$out" "slug=$SESSIONONLY_SLUG.*status=UNKNOWN"; then
    pass "T43: owner.json retaining ONLY session (no heartbeat at all) is flagged UNKNOWN, rc=20"
else
    fail "T43: session-only owner should be flagged UNKNOWN, rc=20 (got rc=$rc out=$out)"
fi
rm -rf "$SESSIONONLY_LOCKDIR"

BADHB_SLUG="HIMMEL-2369-test__heartbeat-unparsable"
BADHB_LOCKDIR="$SWEEP_QDIR/$BADHB_SLUG.lock"
mkdir -p "$BADHB_LOCKDIR"
printf '{"heartbeat":"not-a-real-timestamp"}\n' > "$BADHB_LOCKDIR/owner.json"
out="$(HANDOVER_DIR="$SWEEP_ROOT" bash "$LIB" status --sweep 2>&1)"
rc=$?
if [ "$rc" -eq 20 ] && grepq "$out" "slug=$BADHB_SLUG.*status=UNKNOWN"; then
    pass "T43: owner.json retaining ONLY an unparsable heartbeat is flagged UNKNOWN, rc=20"
else
    fail "T43: unparsable-heartbeat-only owner should be flagged UNKNOWN, rc=20 (got rc=$rc out=$out)"
fi
rm -rf "$BADHB_LOCKDIR"

# Negative control MUST still pass unchanged: a genuinely healthy old lock
# (parseable heartbeat, just old) stays unflagged under a high threshold --
# proving the codex-1 fix is "fail-closed on unassessable", not "flag
# everything".
mkdir -p "$OLD_LOCKDIR"
printf '{"session":"sweep-old","host":"h","handover":"old.md","started":"2020-01-01T00:00:00Z","heartbeat":"2020-01-01T00:00:00Z"}\n' \
    > "$OLD_LOCKDIR/owner.json"
out="$(HANDOVER_DIR="$SWEEP_ROOT" QUEUE_LOCK_IDLE_WARN_SECONDS=999999999 bash "$LIB" status --sweep 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && ! grepq "$out" 'IDLE-HELD' && ! grepq "$out" 'UNKNOWN' && ! grepq "$out" 'CORRUPT'; then
    pass "T43: negative control still holds -- a genuinely healthy old (but parseable) lock stays unflagged under a raised threshold"
else
    fail "T43: negative control regressed -- a parseable old lock should stay unflagged (got rc=$rc out=$out)"
fi
rm -rf "$OLD_LOCKDIR"

# --- T44: sweep race window -- missing owner.json is NOT always CORRUPT ----
# (HIMMEL-2369 CR round-2, codex-2): acquire creates the lock DIR then
# writes owner.json a moment later; a sweep landing in that routine,
# sub-second window must not cry wolf on a healthy in-flight acquire. The
# discriminator is the lock dir's own mtime (py_armor_mtime) -- an empirical
# precheck confirms it actually reports a fresh dir as fresh on THIS box
# first (mirrors last round's live `date -d` check), before trusting the
# sweep's own use of it. A dir younger than _QL_SWEEP_CORRUPT_GRACE_SECS
# reads INDETERMINATE and does not flag; a dir older than it still reads
# CORRUPT and still flags -- fail-closed for genuine corruption is
# unchanged.
T44_GRACE=$(sed -n 's/^_QL_SWEEP_CORRUPT_GRACE_SECS=\([0-9][0-9]*\).*/\1/p' "$LIB" | head -1)
if [ -z "$T44_GRACE" ]; then
    fail "T44: cannot read _QL_SWEEP_CORRUPT_GRACE_SECS from $LIB -- the grace constant moved or was renamed; re-point this test at it"
else
    T44_PROBE_DIR="$TMPDIR_ROOT/t44-mtime-probe"
    mkdir -p "$T44_PROBE_DIR"
    t44_probe_mtime=$(bash -c '. "$1"; py_armor_mtime "$2"' _ "$SCRIPT_DIR/../lib/py-armor.sh" "$T44_PROBE_DIR")
    t44_probe_age=-1
    [ -n "$t44_probe_mtime" ] && t44_probe_age=$(( $(date -u +%s) - t44_probe_mtime ))
    if [ "$t44_probe_age" -ge 0 ] && [ "$t44_probe_age" -lt "$T44_GRACE" ]; then
        pass "T44: py_armor_mtime precheck -- a freshly-created dir reports as fresh on this box (age=${t44_probe_age}s)"
    else
        fail "T44: py_armor_mtime precheck failed (mtime=$t44_probe_mtime age=$t44_probe_age) -- the age mechanism this fix relies on may not behave as expected here"
    fi

    YOUNG_SLUG="HIMMEL-2369-test__missing-owner-young"
    YOUNG_LOCKDIR="$SWEEP_QDIR/$YOUNG_SLUG.lock"
    mkdir -p "$YOUNG_LOCKDIR"   # freshly created, NO owner.json -- simulates acquire mid-flight
    out="$(HANDOVER_DIR="$SWEEP_ROOT" bash "$LIB" status --sweep 2>&1)"
    rc=$?
    if grepq "$out" "slug=$YOUNG_SLUG.*status=INDETERMINATE" && ! grepq "$out" "slug=$YOUNG_SLUG.*CORRUPT"; then
        pass "T44: a YOUNG lock dir with no owner.json yet is INDETERMINATE, not CORRUPT"
    else
        fail "T44: young missing-owner lock should be INDETERMINATE (got rc=$rc out=$out)"
    fi
    if [ "$rc" -eq 0 ]; then
        pass "T44: a lone INDETERMINATE lock does not flag the sweep (rc=0)"
    else
        fail "T44: INDETERMINATE alone should not raise rc (got rc=$rc)"
    fi
    rm -rf "$YOUNG_LOCKDIR"

    OLDMISS_SLUG="HIMMEL-2369-test__missing-owner-old"
    OLDMISS_LOCKDIR="$SWEEP_QDIR/$OLDMISS_SLUG.lock"
    mkdir -p "$OLDMISS_LOCKDIR"
    # touch -d "@<epoch>" (NOT `date -d` arithmetic on a heartbeat string --
    # codex-4 last round; this is the SAME idiom T31 already uses to backdate
    # a lock dir's mtime, proven to work on this box).
    t44_old_epoch=$(( $(date -u +%s) - T44_GRACE - 60 ))
    touch -d "@$t44_old_epoch" "$OLDMISS_LOCKDIR"
    out="$(HANDOVER_DIR="$SWEEP_ROOT" bash "$LIB" status --sweep 2>&1)"
    rc=$?
    if [ "$rc" -eq 20 ] && grepq "$out" "slug=$OLDMISS_SLUG.*status=CORRUPT"; then
        pass "T44: an OLD lock dir with no owner.json (past the grace window) is still CORRUPT, rc=20"
    else
        fail "T44: old missing-owner lock should stay CORRUPT + rc=20 (got rc=$rc out=$out)"
    fi
    rm -rf "$OLDMISS_LOCKDIR"
fi

# --- T45: sweep output escaping (HIMMEL-2369 CR round-2, codex-3) ----------
# slug/session/host are filesystem- or owner-controlled; a raw space or a
# literal embedded newline in a value must not forge or split the
# documented one-record-per-line contract. Every line the sweep prints
# starts with "slug=", so if a newline split a record, the total line
# count would exceed the count of "slug="-prefixed lines.
SPACE_SLUG="HIMMEL-2369-test__esc-space"
SPACE_LOCKDIR="$SWEEP_QDIR/$SPACE_SLUG.lock"
mkdir -p "$SPACE_LOCKDIR"
esc_hb="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"session":"bad session","host":"h","handover":"x.md","started":"%s","heartbeat":"%s"}\n' \
    "$esc_hb" "$esc_hb" > "$SPACE_LOCKDIR/owner.json"

NL_SLUG="HIMMEL-2369-test__esc-newline"
NL_LOCKDIR="$SWEEP_QDIR/$NL_SLUG.lock"
mkdir -p "$NL_LOCKDIR"
printf '{"session":"bad\nsession","host":"h","handover":"x.md","started":"%s","heartbeat":"%s"}\n' \
    "$esc_hb" "$esc_hb" > "$NL_LOCKDIR/owner.json"

out="$(HANDOVER_DIR="$SWEEP_ROOT" bash "$LIB" status --sweep 2>&1)"
t45_lines=$(printf '%s\n' "$out" | wc -l)
t45_slug_lines=$(printf '%s\n' "$out" | grep -c '^slug=')
if [ "$t45_lines" -eq "$t45_slug_lines" ]; then
    pass "T45: every line of sweep output is a slug= record -- no stray line from an embedded space/newline"
else
    fail "T45: sweep output has a non-slug= line (space/newline forged or split a record): $out"
fi
if grepq "$out" "slug=$SPACE_SLUG session=bad_session " && grepq "$out" "slug=$NL_SLUG session=bad_session "; then
    pass "T45: a raw space and a raw embedded newline in session are both folded, not passed through raw"
else
    fail "T45: escaping did not neutralize the space/newline session values (out=$out)"
fi
rm -rf "$SPACE_LOCKDIR" "$NL_LOCKDIR"

# --- T46-T52: cross-root release/heartbeat (HIMMEL-2861) --------------------
# Six legs on 2026-09-09 wrapped with `release <doc> <token>` reporting
# nothing held (rc=0) while the lock they had acquired stayed HELD: the
# acquire ran with HANDOVER_DIR exported, the release at wrap was issued
# from the leg's WORKTREE cwd WITHOUT it, handover_root then resolved that
# repo's inline handovers/ instead, and the lookup missed a root it never
# looked in. T46b is that reproduction -- RED against the pre-fix script.
X_STATE="$TMPDIR_ROOT/2861-state"          # the state repo holding the real root
mkdir -p "$X_STATE/handovers/yotamleo/himmel"
X_ROOT="$(cd "$X_STATE/handovers" && pwd)" # the root the acquire runs under
X_DOC="$X_ROOT/yotamleo/himmel/HIMMEL-2861-legN114-RESUME.md"
: > "$X_DOC"
X_LOCKDIR="$X_ROOT/.locks/queue/yotamleo__himmel__HIMMEL-2861-legN114-RESUME.lock"

# The leg's worktree: its OWN inline handovers/ is what handover_root
# resolves to once HANDOVER_DIR is gone.
X_WT="$TMPDIR_ROOT/2861-worktree"
mkdir -p "$X_WT/handovers"
git -C "$X_WT" init -q >/dev/null 2>&1

# Registries: one naming the state repo (so the fallback has a candidate),
# one naming nobody (the negative control). HANDOVER_REGISTRY keeps both
# hermetic -- the real $HOME registry is never read.
X_REG="$TMPDIR_ROOT/2861-registry.json"
printf '{"repos":{"state":{"path":"%s","user":"yotamleo","branch_prefix":"handover/"}}}\n' \
    "$X_STATE" > "$X_REG"
X_REG_EMPTY="$TMPDIR_ROOT/2861-registry-empty.json"
printf '{"repos":{}}\n' > "$X_REG_EMPTY"

# release/heartbeat exactly as a leg issues them at wrap: from the worktree
# cwd, HANDOVER_DIR gone, token in hand.
x_from_worktree() {
    (
        cd "$X_WT" || exit 9
        unset HANDOVER_DIR
        HANDOVER_REGISTRY="$1" bash "$LIB" "$2" "$X_DOC" "$3" 2>&1
    )
}

x_tok="$(HANDOVER_DIR="$X_ROOT" bash "$LIB" acquire "$X_DOC" "legN114" 2>/dev/null \
    | sed -n 's/^release-token: //p')"
if [ "$x_tok" = "legN114" ] && [ -f "$X_LOCKDIR/owner.json" ]; then
    pass "T46: setup -- acquire under the state root holds the lock"
else
    fail "T46: setup -- acquire under the state root did not hold the lock (tok='$x_tok')"
fi

# --- T46a: NEGATIVE CONTROL -- no candidate root names the real root -------
# The cross-root fallback must not conjure a lock out of nowhere: with a
# registry that knows nothing, the same release still finds nothing. This
# is what makes T46b evidence about the registry candidate specifically.
out="$(x_from_worktree "$X_REG_EMPTY" release "$x_tok")"
rc=$?
if [ "$rc" -ne 0 ] && [ -f "$X_LOCKDIR/owner.json" ]; then
    pass "T46a: negative control -- unknown root: release rc=$rc (non-zero) and the lock stays HELD"
else
    fail "T46a: negative control -- expected non-zero + lock intact (rc=$rc, lock=$([ -f "$X_LOCKDIR/owner.json" ] && echo held || echo GONE): $out)"
fi

# --- T46b: the HIMMEL-2861 reproduction -- release from the worktree cwd ---
out="$(x_from_worktree "$X_REG" release "$x_tok")"
rc=$?
if [ "$rc" -eq 0 ]; then
    pass "T46b: release from a worktree cwd without HANDOVER_DIR rc=0"
else
    fail "T46b: release from a worktree cwd without HANDOVER_DIR rc=0 (got $rc: $out)"
fi
if [ ! -d "$X_LOCKDIR" ]; then
    pass "T46b: the lock under the ACQUIRE-time root is actually released"
else
    fail "T46b: the lock under the acquire-time root is STILL HELD -- the release looked in the wrong root ($out)"
fi
if grepq "$out" '^WARN queue-lock: cwd resolves root ' \
    && grepq "$out" -F "$X_WT/handovers" && grepq "$out" -F "$X_ROOT"; then
    pass "T46b: ONE WARN names both the cwd-resolved root and the recorded root"
else
    fail "T46b: WARN missing or does not name both roots: $out"
fi
if [ "$(printf '%s\n' "$out" | grep -c '^WARN queue-lock: cwd resolves root ')" -eq 1 ]; then
    pass "T46b: the cross-root WARN is printed exactly once"
else
    fail "T46b: the cross-root WARN is not printed exactly once: $out"
fi

# --- T47: heartbeat resolves across roots the same way ---------------------
x_tok="$(HANDOVER_DIR="$X_ROOT" bash "$LIB" acquire "$X_DOC" "legN114hb" 2>/dev/null \
    | sed -n 's/^release-token: //p')"
out="$(x_from_worktree "$X_REG" heartbeat "$x_tok")"
rc=$?
if [ "$rc" -eq 0 ] && grepq "$(cat "$X_LOCKDIR/owner.json" 2>/dev/null)" '"session":"legN114hb"'; then
    pass "T47: heartbeat from a worktree cwd refreshes the lock under the acquire-time root"
else
    fail "T47: heartbeat from a worktree cwd rc=0 expected (got $rc: $out)"
fi
HANDOVER_DIR="$X_ROOT" bash "$LIB" release "$X_DOC" "$x_tok" >/dev/null 2>&1

# --- T48: a genuine no-lock release exits NON-ZERO -------------------------
# Pre-2861 this was a silent rc=0, which every leg and the console read as
# "released cleanly" -- the exact reason six orphaned locks went unnoticed.
out="$(HANDOVER_DIR="$X_ROOT" bash "$LIB" release "$X_DOC" "nobody-holds-this" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ]; then
    pass "T48: release with no lock anywhere exits non-zero (rc=$rc)"
else
    fail "T48: release with no lock anywhere still exits 0 -- a lost lock reads as clean"
fi
if grepq "$out" -i 'no lock held'; then
    pass "T48: it says so on stderr"
else
    fail "T48: no 'no lock held' message: $out"
fi

# --- T49: BACKWARD COMPAT -- a lock dir written by the pre-2861 script -----
# (no `root` marker file) must still status/heartbeat/release normally.
x_tok="$(HANDOVER_DIR="$X_ROOT" bash "$LIB" acquire "$X_DOC" "legacy-sess" 2>/dev/null \
    | sed -n 's/^release-token: //p')"
rm -f "$X_LOCKDIR/root"
HANDOVER_DIR="$X_ROOT" bash "$LIB" status "$X_DOC" >/dev/null 2>&1
t49_status_rc=$?
HANDOVER_DIR="$X_ROOT" bash "$LIB" heartbeat "$X_DOC" "$x_tok" >/dev/null 2>&1
t49_hb_rc=$?
out="$(HANDOVER_DIR="$X_ROOT" bash "$LIB" release "$X_DOC" "$x_tok" 2>&1)"
t49_rel_rc=$?
if [ "$t49_status_rc" -eq 11 ] && [ "$t49_hb_rc" -eq 0 ] && [ "$t49_rel_rc" -eq 0 ] \
    && [ ! -d "$X_LOCKDIR" ]; then
    pass "T49: an old-format lock dir (no root marker) still status/heartbeat/releases (11/0/0)"
else
    fail "T49: old-format lock dir broke (status=$t49_status_rc heartbeat=$t49_hb_rc release=$t49_rel_rc: $out)"
fi

# --- T50: acquire records the resolved root inside the lock dir ------------
x_tok="$(HANDOVER_DIR="$X_ROOT" bash "$LIB" acquire "$X_DOC" "root-marker" 2>/dev/null \
    | sed -n 's/^release-token: //p')"
if [ -f "$X_LOCKDIR/root" ] && [ "$(cat "$X_LOCKDIR/root" 2>/dev/null)" = "$X_ROOT" ]; then
    pass "T50: acquire records the resolved root in <lockdir>/root"
else
    fail "T50: <lockdir>/root missing or wrong (got '$(cat "$X_LOCKDIR/root" 2>/dev/null)', want '$X_ROOT')"
fi

# --- T51: the stdout contract survives -- release-token is the LAST line ---
# The console kit greps this line out of the acquire output; a WARN or any
# other addition must never land after it.
HANDOVER_DIR="$X_ROOT" bash "$LIB" release "$X_DOC" "$x_tok" >/dev/null 2>&1
out="$(HANDOVER_DIR="$X_ROOT" bash "$LIB" acquire "$X_DOC" "last-line" 2>/dev/null)"
if [ "$(printf '%s\n' "$out" | tail -1)" = "release-token: last-line" ]; then
    pass "T51: 'release-token: <token>' is still the LAST stdout line of acquire"
else
    fail "T51: acquire's last stdout line is not the release-token line (got: $out)"
fi

# --- T52: the force-release path is unchanged -- cwd root only, rc=0 -------
# QUEUE_LOCK_FORCE_RELEASE has no token, so it gets no cross-root search
# (nothing would prove the foreign lock is the caller's); it still exits 0
# on nothing-found, which is what the console's sweep-and-force loop reads.
out="$(
    cd "$X_WT" || exit 9
    unset HANDOVER_DIR
    QUEUE_LOCK_FORCE_RELEASE=1 HANDOVER_REGISTRY="$X_REG" bash "$LIB" release "$X_DOC" 2>&1
)"
rc=$?
if [ "$rc" -eq 0 ] && [ -f "$X_LOCKDIR/owner.json" ]; then
    pass "T52: force-release stays cwd-root-only and rc=0 on nothing-found (unchanged)"
else
    fail "T52: force-release path changed (rc=$rc, lock=$([ -f "$X_LOCKDIR/owner.json" ] && echo held || echo GONE): $out)"
fi
out="$(HANDOVER_DIR="$X_ROOT" QUEUE_LOCK_FORCE_RELEASE=1 bash "$LIB" release "$X_DOC" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && [ ! -d "$X_LOCKDIR" ] \
    && grepq "$(cat "$X_ROOT/.locks/queue/takeovers.log" 2>/dev/null)" 'FORCED RELEASE of session=last-line'; then
    pass "T52: force-release under the right root still releases and logs to takeovers.log"
else
    fail "T52: force-release under the right root regressed (rc=$rc: $out)"
fi

# --- T53: a COMPACT single-line registry yields EVERY repo, not just the ---
# last (HIMMEL-2861 CR round 1, codex-1). A line-anchored `sed -n s///p`
# matches at most once per line and its leading `.*` is greedy, so compact
# JSON -- valid, and what any programmatic rewriter emits -- dropped every
# repo but the last out of the candidate list, leaving those roots' locks
# unreleasable from another cwd.
X_REG_COMPACT="$TMPDIR_ROOT/2861-registry-compact.json"
mkdir -p "$TMPDIR_ROOT/2861-decoy/handovers"
printf '{"repos":{"decoy":{"path":"%s"},"state":{"path":"%s"}}}\n' \
    "$TMPDIR_ROOT/2861-decoy" "$X_STATE" > "$X_REG_COMPACT"
x_tok="$(HANDOVER_DIR="$X_ROOT" bash "$LIB" acquire "$X_DOC" "compact-reg" 2>/dev/null \
    | sed -n 's/^release-token: //p')"
out="$(x_from_worktree "$X_REG_COMPACT" release "$x_tok")"
rc=$?
if [ "$rc" -eq 0 ] && [ ! -d "$X_LOCKDIR" ]; then
    pass "T53: a compact one-line registry still yields the state root (every entry parsed, not just the last)"
else
    fail "T53: compact registry dropped the non-final repo entry (rc=$rc: $out)"
fi
# The state repo is deliberately the LAST entry above; put it FIRST to prove
# the parse is not simply picking one fixed position.
printf '{"repos":{"state":{"path":"%s"},"decoy":{"path":"%s"}}}\n' \
    "$X_STATE" "$TMPDIR_ROOT/2861-decoy" > "$X_REG_COMPACT"
x_tok="$(HANDOVER_DIR="$X_ROOT" bash "$LIB" acquire "$X_DOC" "compact-reg-2" 2>/dev/null \
    | sed -n 's/^release-token: //p')"
out="$(x_from_worktree "$X_REG_COMPACT" release "$x_tok")"
rc=$?
if [ "$rc" -eq 0 ] && [ ! -d "$X_LOCKDIR" ]; then
    pass "T53: ...and when the state repo is the FIRST compact entry too"
else
    fail "T53: compact registry dropped the leading repo entry (rc=$rc: $out)"
fi

# --- T54: a STRANGER's lock on the same slug in the cwd root does not -----
# hide our own lock in another root (HIMMEL-2861 CR round 1, codex-2).
# Two roots can carry the same slug; the cross-root search must trigger on
# "the lock here is not ours", not merely on "there is no lock here".
x_tok="$(HANDOVER_DIR="$X_ROOT" bash "$LIB" acquire "$X_DOC" "mine-elsewhere" 2>/dev/null \
    | sed -n 's/^release-token: //p')"
# The stranger's lock is acquired by a REAL acquire from the worktree cwd,
# not hand-placed: the slug is the doc path relativized against ITS OWN root,
# so a hand-built path would land where the cwd root never looks and would
# test nothing. Its lock dir is then the only one under that root.
x_from_worktree "$X_REG_EMPTY" acquire "a-stranger" >/dev/null 2>&1
X_WT_LOCKDIR=""
for x_d in "$X_WT/handovers/.locks/queue/"*.lock; do
    if [ -d "$x_d" ]; then X_WT_LOCKDIR="$x_d"; break; fi
done
if [ -n "$X_WT_LOCKDIR" ] && grepq "$(cat "$X_WT_LOCKDIR/owner.json" 2>/dev/null)" '"session":"a-stranger"'; then
    pass "T54: setup -- a stranger holds this queue's slug under the WORKTREE's own root"
else
    fail "T54: setup -- the stranger's acquire under the worktree root did not take (dir='$X_WT_LOCKDIR')"
fi

out="$(x_from_worktree "$X_REG" heartbeat "$x_tok")"
rc=$?
if [ "$rc" -eq 0 ] && grepq "$(cat "$X_LOCKDIR/owner.json" 2>/dev/null)" '"session":"mine-elsewhere"'; then
    pass "T54: heartbeat looks past a stranger's same-slug lock in the cwd root and refreshes ours"
else
    fail "T54: heartbeat stopped at the stranger's lock (rc=$rc: $out)"
fi
out="$(x_from_worktree "$X_REG" release "$x_tok")"
rc=$?
if [ "$rc" -eq 0 ] && [ ! -d "$X_LOCKDIR" ] && [ -f "$X_WT_LOCKDIR/owner.json" ]; then
    pass "T54: release takes OUR lock in the other root and leaves the stranger's untouched"
else
    fail "T54: release did not resolve past the stranger's lock (rc=$rc, stranger=$([ -f "$X_WT_LOCKDIR/owner.json" ] && echo intact || echo REMOVED): $out)"
fi

# --- T55: NEGATIVE CONTROL for T54 -- a stranger's lock with no lock of ---
# ours anywhere still gets today's rc=2 refusal, never a silent pass and
# never a cross-root steal.
out="$(x_from_worktree "$X_REG" release "not-my-token")"
rc=$?
if [ "$rc" -eq 2 ] && grepq "$out" 'held by session=a-stranger' && [ -f "$X_WT_LOCKDIR/owner.json" ]; then
    pass "T55: negative control -- a stranger's lock and no lock of ours still refuses rc=2, lock intact"
else
    fail "T55: expected rc=2 'held by session=a-stranger' with the lock intact (rc=$rc: $out)"
fi
rm -f "$X_WT_LOCKDIR/owner.json"
rmdir "$X_WT_LOCKDIR" 2>/dev/null || true

# --- T56-T64: per-session token persistence (HIMMEL-2813) ------------------
# Two certifier legs lost their release token to a mid-leg autocompact on
# 2026-09-07/08 and had to force-release, putting a routine wrap into
# takeovers.log -- a file that is supposed to be the audit trail for genuine
# takeovers. `acquire` now also writes the token to a per-user file, and a
# token-less release/heartbeat reads it back. Every fixture below points
# XDG_RUNTIME_DIR at a temp dir, so the real one is never touched.
P_ROOT="$TMPDIR_ROOT/2813-root"
mkdir -p "$P_ROOT/yotamleo/himmel"
P_DOC="$P_ROOT/yotamleo/himmel/HIMMEL-2813-RESUME.md"
: > "$P_DOC"
P_LOCKDIR="$P_ROOT/.locks/queue/yotamleo__himmel__HIMMEL-2813-RESUME.lock"
P_XDG="$TMPDIR_ROOT/2813-xdg"
mkdir -p "$P_XDG"
chmod 700 "$P_XDG"
P_TOKDIR="$P_XDG/himmel-queue-lock"

# p_ql <verb> [args...] -- the script with both temp roots in scope.
p_ql() { XDG_RUNTIME_DIR="$P_XDG" HANDOVER_DIR="$P_ROOT" bash "$LIB" "$@"; }
# p_token_file -- the single file under the token dir, or "" when empty.
p_token_file() {
    local f
    for f in "$P_TOKDIR"/*; do
        if [ -f "$f" ]; then printf '%s' "$f"; return 0; fi
    done
    return 1
}

# --- T56: acquire persists the token; a token-less release uses it ---------
out="$(p_ql acquire "$P_DOC" "persist-a" 2>&1)"
if grepq "$out" '^release-token: persist-a$' && [ -n "$(p_token_file)" ]; then
    pass "T56: acquire persists the token to the per-session file"
else
    fail "T56: no token file after acquire (out=$out)"
fi
p56_file="$(p_token_file)"
if [ "$(cat "$p56_file" 2>/dev/null)" = "persist-a" ]; then
    pass "T56: the persisted file holds the SAME token acquire printed"
else
    fail "T56: persisted token mismatch (got '$(cat "$p56_file" 2>/dev/null)')"
fi
out="$(p_ql release "$P_DOC" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && [ ! -d "$P_LOCKDIR" ]; then
    pass "T56: release with NO token on argv succeeds and releases the lock"
else
    fail "T56: token-less release failed (rc=$rc: $out)"
fi
if grepq "$out" "^queue-lock: token read from $P_TOKDIR/"; then
    pass "T56: it SAYS on stderr which file the token came from"
else
    fail "T56: no 'token read from <path>' line: $out"
fi
if [ -z "$(p_token_file)" ]; then
    pass "T56: the token file is removed on release"
else
    fail "T56: the token file survived the release ($(p_token_file))"
fi

# --- T57: the file is 0600 inside a 0700 dir ------------------------------
# The token is a capability to release someone else's lock, and the /tmp
# fallback below is world-writable, so the modes are load-bearing.
p_ql acquire "$P_DOC" "persist-modes" >/dev/null 2>&1
p57_file="$(p_token_file)"
p57_dmode="$(stat -c '%a' "$P_TOKDIR" 2>/dev/null || stat -f '%Lp' "$P_TOKDIR" 2>/dev/null)"  # gnu-ok: GNU -c paired with BSD -f on this line
p57_fmode="$(stat -c '%a' "$p57_file" 2>/dev/null || stat -f '%Lp' "$p57_file" 2>/dev/null)"  # gnu-ok: GNU -c paired with BSD -f on this line
if [ "$p57_dmode" = "700" ] && [ "$p57_fmode" = "600" ]; then
    pass "T57: token dir is 0700 and the token file is 0600"
else
    fail "T57: wrong modes (dir=$p57_dmode file=$p57_fmode)"
fi

# --- T58: an explicit argv token WINS over the file -----------------------
# The persisted token is valid and sitting right there; a WRONG argv token
# must still be refused rc=2, exactly as before HIMMEL-2813. This is what
# makes the file a fallback rather than a bypass.
out="$(p_ql release "$P_DOC" "not-the-holder" 2>&1)"
rc=$?
if [ "$rc" -eq 2 ] && grepq "$out" 'held by session=persist-modes'; then
    pass "T58: a WRONG argv token is still refused rc=2 even with a valid token file present"
else
    fail "T58: expected rc=2 'held by session=persist-modes' (rc=$rc: $out)"
fi
if ! grepq "$out" 'token read from'; then
    pass "T58: ...and the file was not even consulted (argv wins)"
else
    fail "T58: the file was consulted despite an argv token: $out"
fi
if [ -d "$P_LOCKDIR" ]; then
    pass "T58: the lock is intact after the refusal"
else
    fail "T58: the refused release removed the lock"
fi

# --- T59: heartbeat recalls the token the same way ------------------------
out="$(p_ql heartbeat "$P_DOC" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && grepq "$out" '^queue-lock: token read from '; then
    pass "T59: heartbeat with no argv token recalls the persisted one and says so"
else
    fail "T59: token-less heartbeat failed (rc=$rc: $out)"
fi

# --- T60: the happy path never touches takeovers.log ----------------------
# The whole point of the ticket: a routine wrap must stop landing in the
# file that is supposed to record genuine takeovers.
if [ ! -f "$P_ROOT/.locks/queue/takeovers.log" ]; then
    pass "T60: takeovers.log does not exist after acquire+heartbeat+token-less release"
else
    fail "T60: takeovers.log was written by the happy path: $(cat "$P_ROOT/.locks/queue/takeovers.log")"
fi
p_ql release "$P_DOC" >/dev/null 2>&1

# --- T61: NO token file -> today's token-less refusal, unchanged ----------
p_ql acquire "$P_DOC" "no-file-sess" >/dev/null 2>&1
p61_file="$(p_token_file)"
rm -f "$p61_file"
out="$(p_ql release "$P_DOC" 2>&1)"
rc=$?
if [ "$rc" -eq 2 ] && grepq "$out" 'release requires the session token' \
    && grepq "$out" 'QUEUE_LOCK_FORCE_RELEASE=1'; then
    pass "T61: with no token file, the token-less refusal (rc=2 + override hint) is unchanged"
else
    fail "T61: expected the unchanged rc=2 refusal (rc=$rc: $out)"
fi
if [ -d "$P_LOCKDIR" ]; then
    pass "T61: the lock is intact after that refusal"
else
    fail "T61: the refused release removed the lock"
fi

# --- T62: a STALE token file that does not match the holder --------------
# Recalling it must change nothing about the outcome: the holder check still
# refuses rc=2, it just names the file it tried.
printf '%s\n' 'a-stale-token' > "$P_TOKDIR/$(basename "$p61_file")"
out="$(p_ql release "$P_DOC" 2>&1)"
rc=$?
if [ "$rc" -eq 2 ] && grepq "$out" 'held by session=no-file-sess' && [ -d "$P_LOCKDIR" ]; then
    pass "T62: a stale token file is recalled but still refused rc=2, lock intact"
else
    fail "T62: expected rc=2 'held by session=no-file-sess' with the lock intact (rc=$rc: $out)"
fi

# --- T63: force-release is unchanged and still logs to takeovers.log ------
out="$(XDG_RUNTIME_DIR="$P_XDG" HANDOVER_DIR="$P_ROOT" QUEUE_LOCK_FORCE_RELEASE=1 \
    bash "$LIB" release "$P_DOC" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && [ ! -d "$P_LOCKDIR" ] \
    && grepq "$(cat "$P_ROOT/.locks/queue/takeovers.log" 2>/dev/null)" 'FORCED RELEASE of session=no-file-sess'; then
    pass "T63: force-release still releases and still logs the FORCED entry"
else
    fail "T63: force-release regressed (rc=$rc: $out)"
fi
if ! grepq "$out" 'token read from'; then
    pass "T63: force-release never consults the token file (it needs no token)"
else
    fail "T63: force-release consulted the token file: $out"
fi
rm -f "$P_TOKDIR"/*

# --- T64: a token dir that is NOT ours is refused, not used --------------
# The /tmp fallback is world-writable. A dir another user pre-created there
# would collect every token this host writes, so a dir whose mode is not
# 0700 must be declined -- degrading to the pre-2813 argv-only behaviour
# rather than leaking the token into it.
P_XDG_BAD="$TMPDIR_ROOT/2813-xdg-bad"
mkdir -p "$P_XDG_BAD/himmel-queue-lock"
chmod 777 "$P_XDG_BAD/himmel-queue-lock"
out="$(XDG_RUNTIME_DIR="$P_XDG_BAD" HANDOVER_DIR="$P_ROOT" \
    bash "$LIB" acquire "$P_DOC" "bad-dir-sess" 2>&1)"
rc=$?
p64_written=0
for f in "$P_XDG_BAD/himmel-queue-lock"/*; do
    [ -f "$f" ] && p64_written=1
done
if [ "$rc" -eq 0 ] && grepq "$out" '^release-token: bad-dir-sess$' && [ "$p64_written" -eq 0 ]; then
    pass "T64: a world-writable token dir is declined -- acquire still succeeds, no token written into it"
else
    fail "T64: token leaked into a 0777 dir, or acquire broke (rc=$rc written=$p64_written: $out)"
fi
out="$(XDG_RUNTIME_DIR="$P_XDG_BAD" HANDOVER_DIR="$P_ROOT" bash "$LIB" release "$P_DOC" 2>&1)"
rc=$?
if [ "$rc" -eq 2 ] && grepq "$out" 'release requires the session token'; then
    pass "T64: ...and a token-less release there falls back to the unchanged rc=2 refusal"
else
    fail "T64: expected the unchanged rc=2 refusal from a declined token dir (rc=$rc: $out)"
fi
XDG_RUNTIME_DIR="$P_XDG_BAD" HANDOVER_DIR="$P_ROOT" QUEUE_LOCK_FORCE_RELEASE=1 \
    bash "$LIB" release "$P_DOC" >/dev/null 2>&1

echo "---"
echo "PASSED=$PASSED FAILED=$FAILED"
[ "$FAILED" = 0 ]
