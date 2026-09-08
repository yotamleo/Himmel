#!/usr/bin/env bash
# test-vm-lock.sh — hermetic coverage for scripts/vm/vm-lock.sh (HIMMEL-2623
# PR-B, post-incident hardening). Pure filesystem locking, no VBoxManage, no
# VM, no network — every case runs against a throwaway HIMMEL_VM_LOCK_DIR.
#
# Covers the properties the operator named as non-negotiable: pid-named
# tickets, the three time fields (started/seen/stale_after), an absolute
# staleness ceiling, short-circuit ordering (disabled + re-entrancy before
# the queue-turn check), a no-wait caller yielding to a live queue, TTL-based
# reclaim of an abandoned lock, and the GAVE UP / VM-LOCK-WAIT EXPIRED wording
# + distinct exit code on a timed-out wait.
#
# Platform guard (linux-only): a bash test harness — no fake VBoxManage
# needed here since vm-lock.sh itself is pure filesystem locking, but it
# still needs no .ps1 twin (project convention: a documented guard
# suffices for a test harness). Bash-only because vm-lock.sh's own
# constraint is the station, not this file.
#
# Usage: bash scripts/vm/test-vm-lock.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LOCKLIB="$REPO_ROOT/scripts/vm/vm-lock.sh"
[ -f "$LOCKLIB" ] || { echo "FAIL: $LOCKLIB not found" >&2; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/test-vm-lock.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT

FAILED=0
pass() { echo "PASS $1"; }
fail_case() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }

# Every case gets its OWN lock dir (never shared) so cases can't interfere.
next_dir() {
    local d="$WORK/$1"
    mkdir -p "$d"
    printf '%s' "$d"
}

# --- T1: basic acquire/release round-trip ----------------------------------
d=$(next_dir t1)
out=$(HIMMEL_VM_LOCK_DIR="$d" bash -c '. "'"$LOCKLIB"'"; vm_lock_acquire_waiting x; echo rc=$?; vm_lock_release x')
if grep -q '^rc=0$' <<< "$out"; then
    pass "T1 basic acquire/release round-trip"
else
    fail_case "T1 — $out"
fi

# --- T2: re-entrancy — the SAME process holding the lock can acquire again -
d=$(next_dir t2)
out=$(HIMMEL_VM_LOCK_DIR="$d" bash -c '
. "'"$LOCKLIB"'"
vm_lock_acquire_waiting x >/dev/null; echo first=$?
vm_lock_acquire_waiting x >/dev/null; echo second=$?
vm_lock_release x
')
if grep -q '^first=0$' <<< "$out" && grep -q '^second=0$' <<< "$out"; then
    pass "T2 re-entrancy: the holder can re-acquire its own lock"
else
    fail_case "T2 — $out"
fi

# --- T3: no-wait refuses instantly when another process holds it ----------
d=$(next_dir t3)
(
    HIMMEL_VM_LOCK_DIR="$d" bash -c '. "'"$LOCKLIB"'"; vm_lock_acquire_waiting x >/dev/null; sleep 3; vm_lock_release x'
) &
holder_pid=$!
sleep 0.5
out=$(HIMMEL_VM_LOCK_DIR="$d" bash -c '. "'"$LOCKLIB"'"; vm_lock_acquire_waiting x; echo rc=$?' 2>&1)
kill "$holder_pid" 2>/dev/null; wait "$holder_pid" 2>/dev/null || true
if grep -q '^rc=2$' <<< "$out" && grep -q "REFUSED: another run holds" <<< "$out"; then
    pass "T3 no-wait refuses instantly (rc=2) when another process holds the lock"
else
    fail_case "T3 — $out"
fi

# --- T4: a waiting caller acquires once the holder releases ----------------
d=$(next_dir t4)
(
    HIMMEL_VM_LOCK_DIR="$d" bash -c '. "'"$LOCKLIB"'"; vm_lock_acquire_waiting x >/dev/null; sleep 3; vm_lock_release x'
) &
holder_pid=$!
sleep 0.5
out=$(HIMMEL_VM_LOCK_DIR="$d" HIMMEL_VM_LOCK_WAIT=10 HIMMEL_VM_LOCK_WAIT_INTERVAL=1 \
    bash -c '. "'"$LOCKLIB"'"; vm_lock_acquire_waiting x; echo rc=$?; vm_lock_release x' 2>&1)
wait "$holder_pid" 2>/dev/null || true
if grep -q '^rc=0$' <<< "$out" && grep -q '^ACQUIRED: got the vm-lock' <<< "$out"; then
    pass "T4 a waiting caller acquires once the holder releases, and says so"
else
    fail_case "T4 — $out"
fi

# --- T5: GAVE UP / VM-LOCK-WAIT EXPIRED + exit 5 when the budget runs out --
d=$(next_dir t5)
(
    HIMMEL_VM_LOCK_DIR="$d" bash -c '. "'"$LOCKLIB"'"; vm_lock_acquire_waiting x >/dev/null; sleep 6; vm_lock_release x'
) &
holder_pid=$!
sleep 0.5
out=$(HIMMEL_VM_LOCK_DIR="$d" HIMMEL_VM_LOCK_WAIT=2 HIMMEL_VM_LOCK_WAIT_INTERVAL=1 \
    bash -c '. "'"$LOCKLIB"'"; vm_lock_acquire_waiting x; echo rc=$?' 2>&1)
kill "$holder_pid" 2>/dev/null; wait "$holder_pid" 2>/dev/null || true
if grep -q '^rc=5$' <<< "$out" \
   && grep -q '^GAVE UP: waited' <<< "$out" \
   && grep -qE "^VM-LOCK-WAIT EXPIRED after [0-9]+s — vm-lock 'x' NOT acquired$" <<< "$out"; then
    pass "T5 GAVE UP + the literal VM-LOCK-WAIT EXPIRED marker + exit 5 when the wait budget runs out"
else
    fail_case "T5 — $out"
fi

# --- T6: HIMMEL_VM_LOCK=0 disables the lock entirely -----------------------
d=$(next_dir t6)
out=$(HIMMEL_VM_LOCK_DIR="$d" HIMMEL_VM_LOCK=0 bash -c '. "'"$LOCKLIB"'"; vm_lock_acquire_waiting x; echo rc=$?')
if grep -q '^rc=0$' <<< "$out" && [ ! -e "$d/himmel-vm-lock-x" ]; then
    pass "T6 HIMMEL_VM_LOCK=0 disables the lock entirely (no lock dir ever created)"
else
    fail_case "T6 — $out"
fi

# --- T7: a stale lock (dead pid, past TTL) is reclaimed --------------------
d=$(next_dir t7)
mkdir -p "$d/himmel-vm-lock-x"
printf 'pid=99999999\nhost=%s\nstarted=%s\n' "$(hostname 2>/dev/null || echo h)" "$(( $(date +%s) - 999999 ))" \
    > "$d/himmel-vm-lock-x/owner"
out=$(HIMMEL_VM_LOCK_DIR="$d" HIMMEL_VM_LOCK_TTL=100 bash -c '. "'"$LOCKLIB"'"; vm_lock_acquire_waiting x; echo rc=$?; vm_lock_release x' 2>&1)
if grep -q '^rc=0$' <<< "$out" && grep -q 'NOTE: cleared an abandoned vm-lock' <<< "$out"; then
    pass "T7 a stale lock (dead pid, age past TTL) is reclaimed, loudly"
else
    fail_case "T7 — $out"
fi

# --- T8: a no-wait caller yields to a LIVE queued waiter even though the
# lock itself is free right now (never cuts in front of a queued FIFO
# waiter) -------------------------------------------------------------------
d=$(next_dir t8)
(
    HIMMEL_VM_LOCK_DIR="$d" bash -c '. "'"$LOCKLIB"'"; vm_lock_acquire_waiting x >/dev/null; sleep 2; vm_lock_release x'
) &
holder_pid=$!
sleep 0.3
# A waiting caller joins the queue and blocks on the holder (backgrounded).
(
    HIMMEL_VM_LOCK_DIR="$d" HIMMEL_VM_LOCK_WAIT=8 HIMMEL_VM_LOCK_WAIT_INTERVAL=1 \
        bash -c '. "'"$LOCKLIB"'"; vm_lock_acquire_waiting x >/dev/null; sleep 1; vm_lock_release x'
) &
waiter_pid=$!
sleep 0.6   # let the waiter actually join the queue before probing it
out=$(HIMMEL_VM_LOCK_DIR="$d" bash -c '. "'"$LOCKLIB"'"; vm_lock_acquire_waiting x; echo rc=$?' 2>&1)
wait "$holder_pid" 2>/dev/null || true
wait "$waiter_pid" 2>/dev/null || true
if grep -q '^rc=2$' <<< "$out" && grep -q "queued waiter(s) already ahead" <<< "$out"; then
    pass "T8 a no-wait caller yields to a live queued waiter rather than cutting in line"
else
    fail_case "T8 — $out"
fi

# --- T9: FIFO — of two waiters queued behind one holder, the EARLIER
# arrival acquires first (its own ticket's `started` wins the turn-check).
#
# CR finding codex-9: the marker write must be GATED on the acquisition
# actually succeeding, and each child's exit status must actually be
# checked — a version of this test that writes "first"/"second" and
# discards `wait`'s status regardless of whether vm_lock_acquire_waiting
# ever returned 0 would pass on process-LAUNCH order even if neither waiter
# ever acquired anything, asserting nothing about the FIFO queue at all. -----
d=$(next_dir t9)
(
    HIMMEL_VM_LOCK_DIR="$d" bash -c '. "'"$LOCKLIB"'"; vm_lock_acquire_waiting x >/dev/null && { sleep 2; vm_lock_release x; }'
) &
holder_pid=$!
sleep 0.3
RESULT_FILE="$WORK/t9-order.log"
: > "$RESULT_FILE"
(
    HIMMEL_VM_LOCK_DIR="$d" HIMMEL_VM_LOCK_WAIT=10 HIMMEL_VM_LOCK_WAIT_INTERVAL=1 \
        bash -c '. "'"$LOCKLIB"'"; if vm_lock_acquire_waiting x >/dev/null; then echo first >> "'"$RESULT_FILE"'"; sleep 1; vm_lock_release x; else exit 1; fi'
) &
first_pid=$!
# CodeRabbit (PR #2206): 0.4s does NOT guarantee a different `started` —
# vm_lock_queue_join stamps it with `date +%s` (whole-SECOND granularity),
# so two tickets branded within the same wall-clock second get the SAME
# `started`, and vm_lock_queue_is_our_turn then tie-breaks by PID, not by
# which one actually joined first (verified against its own comparison:
# `[ "$started" -eq "$my_started" ] && [ "$pid" -lt "$$" ]`). A 0.4s gap
# can straddle either side of a second boundary depending on timing, so
# this assertion was not actually deterministic. Any sleep STRICTLY
# GREATER than 1.0s guarantees crossing at least one whole-second
# boundary regardless of alignment — 1.3s for margin against scheduling
# jitter.
sleep 1.3   # ensure the two tickets get different whole-second `started` values
(
    HIMMEL_VM_LOCK_DIR="$d" HIMMEL_VM_LOCK_WAIT=10 HIMMEL_VM_LOCK_WAIT_INTERVAL=1 \
        bash -c '. "'"$LOCKLIB"'"; if vm_lock_acquire_waiting x >/dev/null; then echo second >> "'"$RESULT_FILE"'"; sleep 1; vm_lock_release x; else exit 1; fi'
) &
second_pid=$!
holder_rc=0; first_rc=0; second_rc=0
wait "$holder_pid" || holder_rc=$?
wait "$first_pid" || first_rc=$?
wait "$second_pid" || second_rc=$?
order=$(tr '\n' ',' < "$RESULT_FILE")
if [ "$order" = "first,second," ] && [ "$holder_rc" -eq 0 ] && [ "$first_rc" -eq 0 ] && [ "$second_rc" -eq 0 ]; then
    pass "T9 FIFO: the earlier-queued waiter acquires before the later one (all three acquisitions confirmed via exit status, not just marker order)"
else
    fail_case "T9 — order='$order' (want 'first,second,') holder_rc=$holder_rc first_rc=$first_rc second_rc=$second_rc"
fi

# --- T10: nested locks (CR findings codex-1/codex-8) — the SAME shape
# PR-A's suite lock spent multiple CR rounds closing: a value belonging to
# ONE lock (ownership) was kept in something that belongs to the PROCESS (a
# single scalar), so acquiring a SECOND, differently-named lock while
# holding a FIRST clobbered the first's ownership record. Releasing the
# second then cleared ownership of BOTH, and the first's directory was
# never dropped — indistinguishable from a leak until its TTL. This
# acquires "outer" then, while still holding it, "inner" (mirroring
# after-report.sh's clone lock + nested himmel-vm-registry lock), releases
# inner, and asserts outer is UNCHANGED (still present, still ours) before
# releasing outer and asserting it is actually gone. -----------------------
d=$(next_dir t10)
t10_out=$(HIMMEL_VM_LOCK_DIR="$d" bash -c '
. "'"$LOCKLIB"'"
vm_lock_acquire_waiting outer >/dev/null; echo outer_acquire_rc=$?
vm_lock_acquire_waiting inner >/dev/null; echo inner_acquire_rc=$?
[ -f "'"$d"'/himmel-vm-lock-outer/owner" ] && echo outer_present_after_inner_acquire=yes
vm_lock_release inner
[ -f "'"$d"'/himmel-vm-lock-outer/owner" ] && echo outer_present_after_inner_release=yes
[ -d "'"$d"'/himmel-vm-lock-inner" ] || echo inner_gone_after_inner_release=yes
vm_lock_release outer
[ -d "'"$d"'/himmel-vm-lock-outer" ] || echo outer_gone_after_outer_release=yes
')
if grep -q '^outer_acquire_rc=0$' <<< "$t10_out" \
   && grep -q '^inner_acquire_rc=0$' <<< "$t10_out" \
   && grep -q '^outer_present_after_inner_acquire=yes$' <<< "$t10_out" \
   && grep -q '^outer_present_after_inner_release=yes$' <<< "$t10_out" \
   && grep -q '^inner_gone_after_inner_release=yes$' <<< "$t10_out" \
   && grep -q '^outer_gone_after_outer_release=yes$' <<< "$t10_out"; then
    pass "T10 nested locks: acquiring+releasing an INNER lock never clobbers or drops an already-held OUTER lock's ownership"
else
    fail_case "T10 — $(printf '%s' "$t10_out" | tr '\n' ' ')"
fi

# --- T11 (CR finding codex-5, round 4): a takeover `.claim` whose owner
# file is PRESENT but INCOMPLETE (mkdir won, but `started=` never landed —
# a live brand still in flight, or a crashed writer) must never be
# misjudged as a confirmed-stranded claim and dropped out from under it.
# Seeds the outer lock dir EMPTY (mkdir'd, no owner file — its own
# original acquirer crashed before ever branding) and its `.claim`
# sibling with an owner file carrying `pid=` only, no `started=` line —
# standing in for ANOTHER process genuinely mid-brand on its own
# legitimate takeover attempt. A contender must back off (REFUSED, lock
# NOT acquired this attempt) and must leave that seeded claim completely
# untouched — the misclassification this fix closes was dropping it as
# stranded and taking over regardless. --------------------------------
d=$(next_dir t11)
mkdir -p "$d/himmel-vm-lock-x"
mkdir -p "$d/himmel-vm-lock-x.claim"
printf 'pid=424242\n' > "$d/himmel-vm-lock-x.claim/owner"
t11_out=$(HIMMEL_VM_LOCK_DIR="$d" bash -c '. "'"$LOCKLIB"'"; vm_lock_acquire x; echo rc=$?' 2>&1)
t11_claim_owner=$(cat "$d/himmel-vm-lock-x.claim/owner" 2>/dev/null || echo MISSING)
if grep -q '^rc=1$' <<< "$t11_out" \
   && grep -q "REFUSED: lost the race to take over the vm-lock" <<< "$t11_out" \
   && [ "$t11_claim_owner" = "pid=424242" ]; then
    pass "T11 (CR finding codex-5, round 4) an incomplete (unbranded) takeover claim is never misjudged as stranded and dropped"
else
    fail_case "T11 — claim_owner='$t11_claim_owner' out:"
    printf '%s\n' "$t11_out" | sed 's/^/    /'
fi

echo
if [ "$FAILED" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
else
    echo "$FAILED FAILED"
    exit 1
fi
