#!/usr/bin/env bash
# Unit tests for the tri-state contract of proc_tree_process_alive and
# proc_tree_process_identity_matches in scripts/lib/proc-tree.sh (HIMMEL-1520).
#
# THE BUG: proc_tree_process_alive used a bare `[ -d /proc/$pid ]` on
# Windows/MSYS and a bare `kill -0 2>/dev/null` on POSIX. Both collapse
# "confirmed gone" and "the probe was refused/unavailable" into the same
# nonzero rc, which proc_tree_process_identity_matches then laundered into a
# CONFIRMED mismatch/exit (rc 1) even when the probe had told it nothing.
# proc_tree_terminate trusts that rc 1 to send a KILL signal, so a refused
# probe could be misread as green light. The existing suite passed while this
# bug was live -- it stubs proc_tree_process_identity_matches wholesale, never
# reaching proc_tree_process_alive -- so every case below calls the REAL
# proc_tree_process_alive and the REAL proc_tree_process_identity_matches.
#
# Windows/MSYS arm: proc_tree_is_windows is forced true so T1-T6 exercise the
# real branch end to end via the _PROC_TREE_PROC_ROOT seam on every platform,
# rather than relying on the ambient host or a real /proc that cannot be made
# unreadable from a portable test.
#
# POSIX (kill -0) arm: proc_tree_is_windows is forced false to reach it on
# this Windows box. T7 gets a genuine ESRCH from the real `kill` builtin
# against a pid that cannot exist. A genuine EPERM is not reachable here --
# MSYS bash's `kill` builtin reports "No such process" for any pid outside
# its own reachable set rather than emulating a permission distinction (see
# the probe recorded below T7). T8 instead shadows `kill` with a function
# (avenue #2 from the brief: "injecting a fake kill into the function's
# lookup path"), which bash resolves before the builtin for a bare `kill`
# call -- exactly how proc_tree_process_alive invokes it -- so the call still
# goes through the real proc_tree_process_alive, only the OS-level kill(2)
# underneath is faked.
# shellcheck disable=SC2218  # T11 below re-defines proc_tree_process_identity_matches
# (already sourced from proc-tree.sh, real at T4-T6b) as a stub to confirm
# delegation; shellcheck's whole-file scan misreads the earlier REAL calls as
# forward references to that later local redefinition.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/himmel-proc-tree.XXXXXX")"
fails=0

cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

check() {
    if [ "$2" = "$3" ]; then
        echo "ok - $1"
    else
        echo "FAIL - $1: got [$2] want [$3]"
        fails=$((fails + 1))
    fi
}

# shellcheck source=proc-tree.sh
# shellcheck disable=SC1091
. "$HERE/proc-tree.sh"

# --- Windows/MSYS arm: real proc_tree_process_alive via the proc-root seam ----
# shellcheck disable=SC2317,SC2329  # invoked indirectly by proc_tree_process_alive below.
proc_tree_is_windows() { return 0; }

# T1: pid entry present under the proc root -> alive (rc 0).
_PROC_TREE_PROC_ROOT="$tmp/proc-alive"
mkdir -p "$_PROC_TREE_PROC_ROOT/4242"
rc=0; proc_tree_process_alive 4242 || rc=$?
check "T1 windows arm: pid dir present -> alive" "$rc" "0"

# T2: proc root readable, pid entry genuinely missing -> CONFIRMED absent (rc 1).
_PROC_TREE_PROC_ROOT="$tmp/proc-readable"
mkdir -p "$_PROC_TREE_PROC_ROOT"
rc=0; proc_tree_process_alive 9999 || rc=$?
check "T2 windows arm: readable root, missing pid -> confirmed absent (1)" "$rc" "1"

# T3: THE BUG. proc root itself unreadable/absent -> probe UNAVAILABLE (rc 2),
# never confirmed absence. Same missing pid as T2; only the root's own
# existence differs, and that alone must flip the verdict from 1 to 2.
_PROC_TREE_PROC_ROOT="$tmp/proc-root-does-not-exist"
rc=0; proc_tree_process_alive 9999 || rc=$?
check "T3 windows arm: unreadable root -> probe unavailable (2), NOT confirmed (1)" "$rc" "2"

# T3b (CR round 2): proc root READABLE but NOT SEARCHABLE. On POSIX the search
# (execute) bit is what permits stat-ing "$root/$pid", so without it the pid
# probe fails for a process that is genuinely THERE -- and a root that only
# passes -r would be reported as confirmed absence. Must be rc 2.
# The chmod is verified to have actually taken effect rather than assumed:
# MSYS/NTFS does not honour it, and a test that silently proves nothing is
# worse than one that says it was skipped.
_PROC_TREE_PROC_ROOT="$tmp/proc-no-search"
mkdir -p "$_PROC_TREE_PROC_ROOT/4242"
chmod 400 "$_PROC_TREE_PROC_ROOT" 2>/dev/null || true
if [ -r "$_PROC_TREE_PROC_ROOT" ] && [ ! -x "$_PROC_TREE_PROC_ROOT" ]; then
    rc=0; proc_tree_process_alive 4242 || rc=$?
    check "T3b windows arm: readable but unsearchable root -> probe unavailable (2)" "$rc" "2"
else
    printf 'skip - T3b readable-but-unsearchable root (this filesystem does not honour chmod 400 on a directory)\n'
fi
chmod 700 "$_PROC_TREE_PROC_ROOT" 2>/dev/null || true

# T4: proc_tree_process_identity_matches must propagate T2's confirmed absence
# as its own confirmed-mismatch/exit contract (rc 1), through the real
# proc_tree_process_alive.
_PROC_TREE_PROC_ROOT="$tmp/proc-readable"
rc=0; proc_tree_process_identity_matches 9999 "some-identity" || rc=$?
check "T4 identity_matches: confirmed absence -> rc 1" "$rc" "1"

# T5: THE core regression case. proc_tree_process_identity_matches must NOT
# report T3's probe-unavailable state as a confirmed mismatch/exit. Before
# this fix, T3's scenario returned 1 from proc_tree_process_alive (same as
# T2), and identity_matches laundered it straight into "confirmed" rc 1 --
# exactly the HIMMEL-1501-class defect this ticket closes one layer down.
_PROC_TREE_PROC_ROOT="$tmp/proc-root-does-not-exist"
rc=0; proc_tree_process_identity_matches 9999 "some-identity" || rc=$?
check "T5 identity_matches: probe unavailable -> rc 2, NEVER confirmed (1)" "$rc" "2"

# T6: alive + identity check runs through to proc_tree_process_identity, whose
# own POSIX/Windows probing is orthogonal to this fix -- stub only that leaf
# fetch (not identity_matches itself) to pin the 0/1 split once alive_rc=0.
_PROC_TREE_PROC_ROOT="$tmp/proc-alive"
# shellcheck disable=SC2317,SC2329  # invoked indirectly by proc_tree_process_identity_matches below.
proc_tree_process_identity() { printf 'stub-identity\n'; }
rc=0; proc_tree_process_identity_matches 4242 "stub-identity" || rc=$?
check "T6 identity_matches: alive + identity match -> rc 0" "$rc" "0"
rc=0; proc_tree_process_identity_matches 4242 "other-identity" || rc=$?
check "T6b identity_matches: alive + identity mismatch -> rc 1" "$rc" "1"
unset -f proc_tree_process_identity

# --- POSIX (kill -0) arm, forced on this Windows box --------------------------
proc_tree_is_windows() { return 1; }

# T7: genuine ESRCH via the real kill builtin against a pid that cannot exist.
rc=0; proc_tree_process_alive 2147483647 || rc=$?
check "T7 posix arm: genuine ESRCH -> confirmed absent (1)" "$rc" "1"

# T8: EPERM simulated by shadowing `kill` with a function -- bash resolves a
# bare `kill` call to a function before the builtin, which is exactly how
# proc_tree_process_alive invokes it, so this still reaches the real
# proc_tree_process_alive and only fakes what kill(2) reports underneath.
# (A genuine OS-level EPERM was not reachable on this machine: MSYS bash's
# kill builtin reports "No such process" for any pid outside its own
# reachable set for every pid probed, including pid 1 -- there is no
# permission-refused case to provoke without a foreign-owned live process.)
# shellcheck disable=SC2317,SC2329  # invoked indirectly by proc_tree_process_alive's bare `kill -0` call.
kill() {
    echo "kill: ($1) - Operation not permitted" >&2
    return 1
}
rc=0; proc_tree_process_alive 4242 || rc=$?
check "T8 posix arm: simulated EPERM -> probe unavailable (2), NOT confirmed" "$rc" "2"
unset -f kill

# --- proc_tree_liveness_matches (HIMMEL-1838/HIMMEL-3778) ---------------------
# An empty expected identity means the identity probe FAILED AT RECORD TIME
# (e.g. `ps` unavailable when the owner was branded), not that the pid is
# unprobeable now -- so liveness_matches must fall back to the identity-free
# proc_tree_process_alive rather than returning identity_matches' unconditional
# 2 for an empty expected (line 147 above). Still the POSIX (kill -0) arm.

# T9: empty identity + a pid confirmed gone via the real kill builtin -> falls
# back to proc_tree_process_alive's confirmed-absent contract (rc 1), not the
# "probe unavailable" rc 2 that proc_tree_process_identity_matches alone would
# give an empty expected.
rc=0; proc_tree_liveness_matches 2147483647 "" || rc=$?
check "T9 liveness_matches: empty identity + confirmed-gone pid -> rc 1" "$rc" "1"

# T10: empty identity + this test's own live pid ($$) -> rc 0. A dead holder's
# empty-identity slot must not block reclaim, but a genuinely live one -- e.g.
# a holder's own child probing its ancestor -- must not be refused either.
rc=0; proc_tree_liveness_matches $$ "" || rc=$?
check "T10 liveness_matches: empty identity + live pid -> rc 0 (own-process not refused)" "$rc" "0"

# T11: a NON-empty expected identity must delegate to
# proc_tree_process_identity_matches rather than reimplementing its logic --
# stub it to a distinguishable rc and confirm liveness_matches propagates that
# exact rc unchanged, proving delegation rather than a second code path.
# shellcheck disable=SC2317,SC2329  # invoked indirectly by proc_tree_liveness_matches below.
proc_tree_process_identity_matches() { return 1; }
rc=0; proc_tree_liveness_matches 4242 "some-identity" || rc=$?
check "T11 liveness_matches: non-empty identity delegates to identity_matches (rc 1 propagated)" "$rc" "1"
unset -f proc_tree_process_identity_matches

# --- proc_tree_process_identity: TZ/COLUMNS independence (HIMMEL-3791 judge
# finding J1396A). The identity is `ps -o lstart= -o command=`; lstart is
# printed in the caller's TZ and command is truncated to the caller's COLUMNS,
# so a live holder recorded in one environment looked "dead" to a contender
# reading it in another -- a false-positive double-acquire. Real background
# process, real ps, no stubs.
#
# T6/T11 above stub proc_tree_process_identity /
# proc_tree_process_identity_matches then `unset -f` them -- unset -f removes
# a function outright, it does not restore whatever definition preceded the
# stub, so the REAL implementations sourced at the top of this file are gone
# from here on unless re-sourced.
# shellcheck source=proc-tree.sh
# shellcheck disable=SC1091
. "$HERE/proc-tree.sh"

sleep 60 & livepid=$!

# T12: identity recorded under TZ=Asia/Jerusalem, judged under TZ=UTC, must
# still match -- before the fix this diverged and liveness_matches judged a
# live process dead (rc 1).
recorded=$(TZ=Asia/Jerusalem proc_tree_process_identity "$livepid")
check "T12 identity: ps probe recorded a nonempty identity (not a vacuous pass)" "$([ -n "$recorded" ] && echo 1 || echo 0)" "1"
rc=0; TZ=UTC proc_tree_liveness_matches "$livepid" "$recorded" || rc=$?
check "T12 identity: TZ mismatch (recorded JLM, judged UTC) still matches live pid -> rc 0" "$rc" "0"
kill "$livepid" 2>/dev/null

# T13: identity recorded under a narrow COLUMNS, judged under a wide one, must
# still match -- before the fix, ps truncated `command` to the narrower width
# and the two strings diverged. A short argv (e.g. bare `sleep 60`) is already
# shorter than a narrow COLUMNS and never triggers ps's truncation, so this
# needs a long argv to actually exercise the width cut.
long_arg=$(printf 'A%.0s' $(seq 1 200))
bash -c 'while :; do sleep 5; done' "$long_arg" & livepid=$!
recorded=$(COLUMNS=20 proc_tree_process_identity "$livepid")
check "T13 identity: ps probe recorded a nonempty identity (not a vacuous pass)" "$([ -n "$recorded" ] && echo 1 || echo 0)" "1"
rc=0; COLUMNS=200 proc_tree_liveness_matches "$livepid" "$recorded" || rc=$?
check "T13 identity: COLUMNS mismatch (recorded 20, judged 200) still matches live pid -> rc 0" "$rc" "0"

kill "$livepid" 2>/dev/null

if [ "$fails" -eq 0 ]; then
    echo "ALL PASS"
else
    echo "$fails FAILED"
    exit 1
fi
