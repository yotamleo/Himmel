#!/usr/bin/env bash
# Tests for scripts/lib/suite-semaphore.sh, the machine-wide suite concurrency
# budget (HIMMEL-1818), through its two chokepoints: scripts/quiet-run.sh
# (label `suite`) and scripts/ci/run-shell-tests.sh.
#
# Pinned:
#   - a second concurrent suite fails loud: rc 75, naming the holder's pid and
#     label, and the exact retry shape (SUITE_LOCK_WAIT=60 ...);
#   - SUITE_LOCK_WAIT=<n> waits for the slot instead;
#   - a killed runner's stale slot is reclaimed (dead pid, identity mismatch,
#     TTL expiry);
#   - re-entrancy is honoured only for a DESCENDANT of the slot owner: a nested
#     quiet-run under the holder proceeds, a forged HIMMEL_SUITE_SLOT_HELD from
#     an unrelated process does not;
#   - HIMMEL_SUITE_SLOTS=N admits N concurrent suites;
#   - run-shell-tests.sh takes a slot too;
#   - the default (HIMMEL_SUITE_SLOTS unset) admits 3 concurrent suites;
#   - SUITE_LOCK_WAIT with a leading zero (octal-looking) is read as decimal.
#
# Every case runs against its own sandbox HIMMEL_SUITE_SEMAPHORE_DIR, with the
# outer runner's HIMMEL_SUITE_SLOT_HELD removed, so the slot this suite itself
# runs under is never touched.
#
# Usage: bash scripts/lib/test-suite-semaphore.sh
# Exit codes: 0 -- all cases passed; 1 -- at least one failed
# Platform guard (gitbash-only): POSIX bash 3.2+, ps, coreutils. ASCII only.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
QUIET_RUN="$REPO_ROOT/scripts/quiet-run.sh"
RUNNER="$REPO_ROOT/scripts/ci/run-shell-tests.sh"

FAILED=0
CASES=0
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/test-suite-semaphore.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
BG_PIDS=''
# shellcheck disable=SC2329,SC2317  # invoked via trap
cleanup() {
    local p
    for p in $BG_PIDS; do
        kill -TERM "$p" 2>/dev/null || true
    done
    for p in $BG_PIDS; do
        wait "$p" 2>/dev/null || true
    done
    rm -rf "$SCRATCH"
}
trap cleanup EXIT

pass() { CASES=$((CASES + 1)); echo "PASS $1"; }
fail() { CASES=$((CASES + 1)); FAILED=$((FAILED + 1)); echo "FAIL $1"; }

# new_sem -- a fresh sandbox semaphore dir per case.
N_SEM=0
new_sem() {
    N_SEM=$((N_SEM + 1))
    SEM="$SCRATCH/sem-$N_SEM"
}

# qr <sem> [VAR=VAL ...] -- <cmd...>: quiet-run `suite` against sandbox <sem>,
# stdin from /dev/null (the non-tty, own-process-group path legs use).
qr() {
    local sem="$1"; shift
    local -a envs=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
    shift
    env -u HIMMEL_SUITE_SLOT_HELD -u SUITE_LOCK_WAIT -u HIMMEL_SUITE_SLOTS \
        HIMMEL_SUITE_SEMAPHORE_DIR="$sem" ${envs[@]+"${envs[@]}"} \
        bash "$QUIET_RUN" suite -- "$@" </dev/null
}

# wait_file <path> -- up to ~10s for <path> to exist.
wait_file() {
    local i=0
    while [ ! -e "$1" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
    [ -e "$1" ]
}

# start_holder <sem> <tag> [VAR=VAL ...] -- a backgrounded quiet-run suite that
# holds a slot until its sleeper is killed. Sets HOLDER (quiet-run pid) and
# SLEEPER_FILE (holds the sleeper's pid once it is running).
start_holder() {
    local sem="$1" tag="$2"; shift 2
    SLEEPER_FILE="$SCRATCH/sleeper-$tag.pid"
    # shellcheck disable=SC2016  # $$ and $0 expand in the inner sh
    qr "$sem" "$@" -- sh -c 'echo $$ >"$0"; exec sleep 60' "$SLEEPER_FILE" >/dev/null 2>&1 &
    HOLDER=$!
    BG_PIDS="$BG_PIDS $HOLDER"
    wait_file "$SLEEPER_FILE"
    # $! names the backgrounded subshell; the slot owner is quiet-run itself.
    QR_PID=$(sed -n 's/^pid=//p' "$sem"/slot-*/owner 2>/dev/null | tail -1)
}

# stop_holder -- kill the sleeper so the holder exits normally (releasing).
stop_holder() {
    local sp
    sp=$(cat "$SLEEPER_FILE" 2>/dev/null) || sp=''
    [ -n "$sp" ] && kill -TERM "$sp" 2>/dev/null
    wait "$HOLDER" 2>/dev/null || true
}

# --- 1: a second concurrent suite fails loud (rc 75) ---
new_sem
start_holder "$SEM" one HIMMEL_SUITE_SLOTS=1
ERR=$(qr "$SEM" HIMMEL_SUITE_SLOTS=1 -- true 2>&1 >/dev/null); RC=$?
if [ "$RC" = "75" ] \
   && grep -q "pid ${QR_PID:-none}" <<<"$ERR" \
   && grep -q "label suite" <<<"$ERR" \
   && grep -qF "SUITE_LOCK_WAIT=60 bash scripts/quiet-run.sh suite -- true" <<<"$ERR"; then
    pass "second concurrent suite -> rc 75 naming holder pid, label and retry shape"
else
    fail "second concurrent suite -- expected rc 75 + holder pid ${QR_PID:-none} + retry line, got rc=$RC err: $ERR"
fi

# --- 2: the holder releases its slot on a normal exit ---
stop_holder
if [ ! -e "$SEM/slot-1" ]; then
    pass "holder releases its slot on exit"
else
    fail "holder left $SEM/slot-1 behind after exiting"
fi
if qr "$SEM" -- true >/dev/null 2>&1 && [ ! -e "$SEM/slot-1" ]; then
    pass "a suite after the holder exits proceeds"
else
    fail "a suite after the holder exits did not proceed"
fi

# --- 3: SUITE_LOCK_WAIT=<n> waits for the slot ---
new_sem
start_holder "$SEM" wait HIMMEL_SUITE_SLOTS=1
( sleep 1; kill -TERM "$(cat "$SLEEPER_FILE")" 2>/dev/null ) &
BG_PIDS="$BG_PIDS $!"
if qr "$SEM" HIMMEL_SUITE_SLOTS=1 SUITE_LOCK_WAIT=20 -- true >/dev/null 2>&1; then
    pass "SUITE_LOCK_WAIT=20 waits for the busy slot, then proceeds"
else
    fail "SUITE_LOCK_WAIT=20 did not acquire after the holder released"
fi
wait "$HOLDER" 2>/dev/null || true

# --- 4: a KILLED runner's stale slot is reclaimed ---
new_sem
start_holder "$SEM" killed HIMMEL_SUITE_SLOTS=1
kill -KILL "${QR_PID:-none}" 2>/dev/null
wait "$HOLDER" 2>/dev/null || true
kill -TERM "$(cat "$SLEEPER_FILE")" 2>/dev/null || true
ERR=$(qr "$SEM" HIMMEL_SUITE_SLOTS=1 -- true 2>&1 >/dev/null); RC=$?
if [ "$RC" = "0" ] && grep -q "reclaimed" <<<"$ERR"; then
    pass "kill -9'd runner's stale slot is reclaimed"
else
    fail "stale slot of a kill -9'd runner -- expected rc 0 + reclaimed note, got rc=$RC err: $ERR"
fi

# --- 5: a live pid whose identity no longer matches (pid reuse) is reclaimed ---
new_sem
mkdir -p "$SEM/slot-1"
printf 'pid=%s\nidentity=posix:not-this-process\nlabel=suite\nstarted=%s\n' "$$" "$(date +%s)" >"$SEM/slot-1/owner"
if qr "$SEM" -- true >/dev/null 2>&1 && [ ! -e "$SEM/slot-1" ]; then
    pass "slot whose owner identity mismatches (pid reuse) is reclaimed"
else
    fail "slot whose owner identity mismatches was not reclaimed"
fi

# --- 6: a slot past HIMMEL_SUITE_SLOT_TTL is reclaimed even if the pid lives ---
new_sem
start_holder "$SEM" ttl HIMMEL_SUITE_SLOTS=1
ERR=$(qr "$SEM" HIMMEL_SUITE_SLOTS=1 HIMMEL_SUITE_SLOT_TTL=1 SUITE_LOCK_WAIT=5 -- true 2>&1 >/dev/null); RC=$?
if [ "$RC" = "0" ] && grep -q reclaimed <<<"$ERR"; then
    pass "slot older than HIMMEL_SUITE_SLOT_TTL is reclaimed"
else
    fail "slot older than HIMMEL_SUITE_SLOT_TTL was not reclaimed -- rc=$RC: $ERR"
fi
stop_holder

# --- 7: re-entrancy -- a quiet-run nested under the holder proceeds ---
new_sem
# shellcheck disable=SC2016  # $0 expands in the inner sh
OUT=$(qr "$SEM" -- sh -c 'bash "$0" suite -- true' "$QUIET_RUN" 2>&1); RC=$?
if [ "$RC" = "0" ]; then
    pass "nested quiet-run under the slot holder proceeds (re-entrant)"
else
    fail "nested quiet-run under the slot holder -- expected rc 0, got rc=$RC: $OUT"
fi

# --- 8: a FORGED HIMMEL_SUITE_SLOT_HELD (not a descendant) is not honoured ---
new_sem
start_holder "$SEM" forged HIMMEL_SUITE_SLOTS=1
ERR=$(qr "$SEM" HIMMEL_SUITE_SLOTS=1 HIMMEL_SUITE_SLOT_HELD="$SEM/slot-1" -- true 2>&1 >/dev/null); RC=$?
if [ "$RC" = "75" ]; then
    pass "forged HIMMEL_SUITE_SLOT_HELD from a non-descendant is refused (rc 75)"
else
    fail "forged HIMMEL_SUITE_SLOT_HELD -- expected rc 75, got rc=$RC err: $ERR"
fi
stop_holder

# --- 9: HIMMEL_SUITE_SLOTS=2 admits two, refuses the third ---
new_sem
start_holder "$SEM" two-a HIMMEL_SUITE_SLOTS=2
H1=$HOLDER; S1=$SLEEPER_FILE
start_holder "$SEM" two-b HIMMEL_SUITE_SLOTS=2
H2=$HOLDER
if [ -e "$SEM/slot-1" ] && [ -e "$SEM/slot-2" ]; then
    pass "HIMMEL_SUITE_SLOTS=2 admits two concurrent suites"
else
    fail "HIMMEL_SUITE_SLOTS=2 did not admit two concurrent suites"
fi
qr "$SEM" HIMMEL_SUITE_SLOTS=2 -- true >/dev/null 2>&1; RC=$?
if [ "$RC" = "75" ]; then
    pass "HIMMEL_SUITE_SLOTS=2 refuses the third (rc 75)"
else
    fail "HIMMEL_SUITE_SLOTS=2 third suite -- expected rc 75, got rc=$RC"
fi
stop_holder
HOLDER=$H1; SLEEPER_FILE=$S1
stop_holder
wait "$H2" 2>/dev/null || true

# --- 10: run-shell-tests.sh takes a slot too ---
new_sem
FIX="$SCRATCH/fixture-root"
mkdir -p "$FIX"
printf '#!/usr/bin/env bash\nexit 0\n' >"$FIX/test-ok.sh"
start_holder "$SEM" runner HIMMEL_SUITE_SLOTS=1
env -u HIMMEL_SUITE_SLOT_HELD -u HIMMEL_SUITE_LOCK_HELD -u SUITE_LOCK_WAIT \
    HIMMEL_SUITE_SEMAPHORE_DIR="$SEM" HIMMEL_SUITE_SLOTS=1 TMPDIR="$SCRATCH" HIMMEL_RUNTIME_PREFLIGHT=0 \
    bash "$RUNNER" "$FIX" >"$SCRATCH/runner.out" 2>&1 </dev/null; RC=$?
if [ "$RC" = "75" ]; then
    pass "run-shell-tests.sh refuses while another suite holds the slot (rc 75)"
else
    fail "run-shell-tests.sh under a busy slot -- expected rc 75, got rc=$RC: $(tail -5 "$SCRATCH/runner.out")"
fi
stop_holder

# --- 11: default (HIMMEL_SUITE_SLOTS unset) admits 3, refuses the 4th ---
new_sem
start_holder "$SEM" def-a
H1=$HOLDER; S1=$SLEEPER_FILE
start_holder "$SEM" def-b
H2=$HOLDER; S2=$SLEEPER_FILE
start_holder "$SEM" def-c
H3=$HOLDER
if [ -e "$SEM/slot-1" ] && [ -e "$SEM/slot-2" ] && [ -e "$SEM/slot-3" ]; then
    pass "default HIMMEL_SUITE_SLOTS admits 3 concurrent suites"
else
    fail "default HIMMEL_SUITE_SLOTS did not admit 3 concurrent suites"
fi
qr "$SEM" -- true >/dev/null 2>&1; RC=$?
if [ "$RC" = "75" ]; then
    pass "default HIMMEL_SUITE_SLOTS refuses the 4th (rc 75)"
else
    fail "default HIMMEL_SUITE_SLOTS 4th suite -- expected rc 75, got rc=$RC"
fi
stop_holder
HOLDER=$H2; SLEEPER_FILE=$S2
stop_holder
HOLDER=$H1; SLEEPER_FILE=$S1
stop_holder
wait "$H3" 2>/dev/null || true

# --- 12: SUITE_LOCK_WAIT with a leading zero is read as decimal, not octal.
# A bad base-8 arithmetic expansion aborts suite_sem_acquire before it ever
# tries the slot, and the caller reads that abort as success -- the busy
# budget is silently BYPASSED instead of waited out. Pin on wall-clock: a
# correct wait blocks until the holder releases (>= 1s); the bypass returns
# almost instantly. ---
new_sem
start_holder "$SEM" octal HIMMEL_SUITE_SLOTS=1
( sleep 1; kill -TERM "$(cat "$SLEEPER_FILE")" 2>/dev/null ) &
BG_PIDS="$BG_PIDS $!"
START=$(date +%s)
qr "$SEM" HIMMEL_SUITE_SLOTS=1 SUITE_LOCK_WAIT=08 -- true >/dev/null 2>&1; RC=$?
ELAPSED=$(( $(date +%s) - START ))
if [ "$RC" = "0" ] && [ "$ELAPSED" -ge 1 ]; then
    pass "SUITE_LOCK_WAIT=08 (leading zero) waits for the holder (${ELAPSED}s) instead of bypassing the budget"
else
    fail "SUITE_LOCK_WAIT=08 (leading zero) -- expected rc 0 after >=1s wait, got rc=$RC after ${ELAPSED}s (a fast rc 0 means the budget was silently bypassed)"
fi
wait "$HOLDER" 2>/dev/null || true

# --- 13: run-shell-tests.sh releases its slot on a successful run (the EXIT
# trap's `suite_sem_release` call) -- a leaked slot here would starve every
# later suite on the machine, not just this tree's own re-runs. ---
new_sem
env -u HIMMEL_SUITE_SLOT_HELD -u HIMMEL_SUITE_LOCK_HELD -u SUITE_LOCK_WAIT \
    HIMMEL_SUITE_SEMAPHORE_DIR="$SEM" HIMMEL_SUITE_SLOTS=1 TMPDIR="$SCRATCH" HIMMEL_RUNTIME_PREFLIGHT=0 \
    bash "$RUNNER" "$FIX" >"$SCRATCH/runner-ok.out" 2>&1 </dev/null; RC=$?
if [ "$RC" = "0" ] && [ ! -e "$SEM/slot-1" ]; then
    pass "run-shell-tests.sh releases its semaphore slot on a successful run"
else
    fail "run-shell-tests.sh slot release -- expected rc 0 + no slot-1, got rc=$RC slot-1=$([ -e "$SEM/slot-1" ] && echo present || echo absent): $(tail -5 "$SCRATCH/runner-ok.out")"
fi

# --- 14: _suite_sem_try's owner-file write is unchecked -- if the printf/mv
# pipeline that records the owner fails (permission denied, disk full), the
# mkdir'd slot dir is left behind with no owner file, yet the function still
# returns 0 and exports HIMMEL_SUITE_SLOT_HELD as if the slot were legitimately
# claimed. Force the write to fail with umask 0777 on the mkdir'd slot dir
# (mkdir needs write+exec on the PARENT, not the new dir itself, so mkdir still
# succeeds; writing inside a 000-mode dir then fails). ---
new_sem
mkdir -p "$SEM"
(
    . "$REPO_ROOT/scripts/lib/suite-semaphore.sh"
    umask 0777
    _suite_sem_try "$SEM/slot-1" testlabel
    echo "rc=$? held=$HIMMEL_SUITE_SLOT_HELD"
) >"$SCRATCH/try14.out" 2>/dev/null
TRY_RC=$(sed -n 's/^rc=\([0-9]*\).*/\1/p' "$SCRATCH/try14.out")
if [ "$TRY_RC" = "0" ] && [ -e "$SEM/slot-1/owner" ]; then
    fail "_suite_sem_try -- unwritable slot: expected rc!=0 and no dir left behind, got rc=$TRY_RC with an owner file present (should be impossible if this is failing correctly)"
elif [ "$TRY_RC" = "0" ] && [ ! -e "$SEM/slot-1/owner" ]; then
    fail "_suite_sem_try -- unwritable slot: got rc=0 (claimed success) with NO owner file written -- an ownerless slot was claimed as held"
elif [ -d "$SEM/slot-1" ]; then
    fail "_suite_sem_try -- unwritable slot: rc=$TRY_RC (failure correctly reported) but the mkdir'd slot dir was left behind, still blocking that slot"
else
    pass "_suite_sem_try reports failure and cleans up the slot when the owner-file write fails"
fi

# --- 15: HIMMEL_SUITE_SLOTS=00 (all-zero, not the single digit "0" the uint
# helper already special-cases) must fall back to the default budget, not
# silently provide a 0-slot pool that reports "busy" on the very first try. ---
new_sem
OUT=$(HIMMEL_SUITE_SEMAPHORE_DIR="$SEM" HIMMEL_SUITE_SLOTS=00 bash "$QUIET_RUN" suite -- true 2>&1 </dev/null); RC=$?
if [ "$RC" = "0" ]; then
    pass "HIMMEL_SUITE_SLOTS=00 falls back to the default budget instead of a 0-slot pool"
else
    fail "HIMMEL_SUITE_SLOTS=00 -- expected rc 0 (default budget), got rc=$RC: $OUT"
fi

if [ "$FAILED" -eq 0 ]; then
    echo "OK: all $CASES cases passed"
    exit 0
fi
echo "FAILED: $FAILED of $CASES cases failed"
exit 1
