#!/usr/bin/env bash
# test-shared-branch-lock.sh -- regression test for scripts/lib/shared-branch-lock.sh
# (HIMMEL-800).
#
# Usage: bash scripts/lib/test-shared-branch-lock.sh
# Exit:  0 = all pass, 1 = one or more failures.
#
# Hermetic: builds its own temp git repo (+ a second worktree of it) under
# mktemp -d, never touches the real himmel repo or $HOME. Cleaned up with a
# trap on EXIT.
#
# Invokes the library as a SUBPROCESS (bash shared-branch-lock.sh <verb> ...)
# rather than sourcing it -- the contract under test is the CLI exit-code
# table, and test 7 (cross-worktree collision) needs two independent
# processes racing the same mkdir the way the real lanes will.

set -uo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone. (HIMMEL-1430.)
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$LIB_DIR/shared-branch-lock.sh"

PASSED=0
FAILED=0
pass() { echo "PASS: $1"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL: $1"; FAILED=$((FAILED + 1)); }

TMPDIR_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

REPO="$TMPDIR_ROOT/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "Test User"
: > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -q -m "init"

# --- T1: acquire succeeds, owner.json has pid+lane+branch -------------------
out="$(bash "$LIB" acquire "$REPO" "feat/t1" "lane-a" 2>&1)"
rc=$?
lockdir="$(cd "$REPO" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/himmel-shared-branch/feat-t1.lock"
if [ "$rc" -eq 0 ]; then
    pass "T1: acquire rc=0"
else
    fail "T1: acquire rc=0 (got $rc: $out)"
fi
if [ -f "$lockdir/owner.json" ] \
    && grep -q '"pid"' "$lockdir/owner.json" \
    && grep -q '"lane":"lane-a"' "$lockdir/owner.json" \
    && grep -q '"branch":"feat/t1"' "$lockdir/owner.json"; then
    pass "T1: owner.json has pid+lane+branch"
else
    fail "T1: owner.json missing/incomplete ($(cat "$lockdir/owner.json" 2>/dev/null || echo 'MISSING'))"
fi

# --- T2: second acquire on same branch -> rc 11, holder info on stderr ------
err="$(bash "$LIB" acquire "$REPO" "feat/t1" "lane-b" 2>&1 1>/dev/null)"
rc=$?
if [ "$rc" -eq 11 ]; then
    pass "T2: second acquire rc=11"
else
    fail "T2: second acquire rc=11 (got $rc)"
fi
if grepq "$err" '"lane":"lane-a"' && grepq "$err" -i "recovery"; then
    pass "T2: stderr has holder info + recovery hint"
else
    fail "T2: stderr missing holder info / recovery hint: $err"
fi

# --- T3: release -> rc 0; then acquire succeeds again ------------------------
bash "$LIB" release "$REPO" "feat/t1" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
    pass "T3: release rc=0"
else
    fail "T3: release rc=0 (got $rc)"
fi
bash "$LIB" acquire "$REPO" "feat/t1" "lane-c" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
    pass "T3: re-acquire after release rc=0"
else
    fail "T3: re-acquire after release rc=0 (got $rc)"
fi
bash "$LIB" release "$REPO" "feat/t1" >/dev/null 2>&1

# --- T4: release when no lock exists -> rc 0 (idempotent) --------------------
bash "$LIB" release "$REPO" "feat/never-locked" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
    pass "T4: release of absent lock rc=0 (idempotent)"
else
    fail "T4: release of absent lock rc=0 (got $rc)"
fi

# --- T5: status -> free rc0 when free; rc11 + owner contents when held ------
out="$(bash "$LIB" status "$REPO" "feat/t5" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "free" ]; then
    pass "T5: status free rc=0"
else
    fail "T5: status free rc=0 + 'free' (got rc=$rc out=$out)"
fi
bash "$LIB" acquire "$REPO" "feat/t5" "lane-d" >/dev/null 2>&1
out="$(bash "$LIB" status "$REPO" "feat/t5" 2>&1)"
rc=$?
if [ "$rc" -eq 11 ] && grepq "$out" '"lane":"lane-d"'; then
    pass "T5: status held rc=11 + owner contents"
else
    fail "T5: status held rc=11 + owner contents (got rc=$rc out=$out)"
fi
bash "$LIB" release "$REPO" "feat/t5" >/dev/null 2>&1

# --- T6: slug escaping collision -- "feat/x.y_z" and "feat-x-y-z" -----------
# Documented known coarseness: both slug to "feat-x-y-z", so they share one
# lock. The second acquire must therefore see rc=11, not rc=0.
bash "$LIB" acquire "$REPO" "feat/x.y_z" "lane-e" >/dev/null 2>&1
rc1=$?
bash "$LIB" acquire "$REPO" "feat-x-y-z" "lane-f" >/dev/null 2>&1
rc2=$?
if [ "$rc1" -eq 0 ] && [ "$rc2" -eq 11 ]; then
    pass "T6: slug collision -- second differently-punctuated branch rc=11"
else
    fail "T6: slug collision -- expected rc1=0 rc2=11, got rc1=$rc1 rc2=$rc2"
fi
bash "$LIB" release "$REPO" "feat/x.y_z" >/dev/null 2>&1

# --- T7: same lock namespace across worktrees ---------------------------------
WT="$TMPDIR_ROOT/wt"
git -C "$REPO" worktree add -q "$WT" -b "wt-branch" >/dev/null 2>&1
bash "$LIB" acquire "$WT" "feat/t7" "lane-g" >/dev/null 2>&1
rc1=$?
bash "$LIB" acquire "$REPO" "feat/t7" "lane-h" >/dev/null 2>&1
rc2=$?
if [ "$rc1" -eq 0 ] && [ "$rc2" -eq 11 ]; then
    pass "T7: worktree-acquired lock visible from primary checkout (rc=11)"
else
    fail "T7: worktree/primary lock namespace mismatch (rc1=$rc1 rc2=$rc2)"
fi
bash "$LIB" release "$REPO" "feat/t7" >/dev/null 2>&1

# --- T8: usage errors ----------------------------------------------------------
bash "$LIB" acquire "$REPO" "feat/t8" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 2 ]; then
    pass "T8: acquire missing <lane> arg rc=2"
else
    fail "T8: acquire missing <lane> arg rc=2 (got $rc)"
fi
bash "$LIB" acquire >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 2 ]; then
    pass "T8: acquire with no args rc=2"
else
    fail "T8: acquire with no args rc=2 (got $rc)"
fi
NON_GIT="$TMPDIR_ROOT/not-a-repo"
mkdir -p "$NON_GIT"
bash "$LIB" acquire "$NON_GIT" "feat/t8" "lane-i" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 2 ]; then
    pass "T8: acquire against non-git dir rc=2"
else
    fail "T8: acquire against non-git dir rc=2 (got $rc)"
fi

# --- T9: acquire whose lock ROOT cannot be created -> rc 2, NOT rc 11 (C2) ---
# Portable simulation: plant a FILE where the lock root dir must go, so
# `mkdir -p <lockroot>` and the subsequent `mkdir <lockdir>` both fail for a
# real reason (a file is in the way) rather than "already held". The refusal
# must be rc 2 (genuine mkdir failure), not rc 11 (already held).
T9_COMMON="$(cd "$REPO" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
T9_ROOT="$T9_COMMON/himmel-shared-branch"
rm -rf "$T9_ROOT"
: > "$T9_ROOT"   # a FILE where the lock-root dir is expected
err="$(bash "$LIB" acquire "$REPO" "feat/t9" "lane-j" 2>&1 1>/dev/null)"
rc=$?
if [ "$rc" -eq 2 ]; then
    pass "T9: acquire with a file blocking the lock root rc=2 (not 11)"
else
    fail "T9: acquire with a file blocking the lock root rc=2 (got $rc: $err)"
fi
if grepq "$err" -i "cannot create lock dir"; then
    pass "T9: rc-2 refusal names the real mkdir failure"
else
    fail "T9: rc-2 refusal missing the real mkdir error: $err"
fi
rm -f "$T9_ROOT"   # clear the blocking file so nothing else trips on it

# --- T10: release of an absent lock stays rc 0 (idempotent, C1 contract) -----
# The C1 change adds an rc-3 "still exists after rm" path; assert the common
# case (nothing to remove) still returns rc 0 so idempotency is preserved.
bash "$LIB" release "$REPO" "feat/t10-never-locked" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
    pass "T10: release of absent lock stays rc=0 (rc-3 path is failure-only)"
else
    fail "T10: release of absent lock rc=0 (got $rc)"
fi

# --- T11: acquire-wait reclaims a lock older than the TTL -------------------
# The CLI contract: a holder that died without releasing must not wedge the
# branch forever, and the reclaim must leave a loud trail.
lockdir="$(cd "$REPO" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/himmel-shared-branch/feat-t11.lock"
bash "$LIB" acquire "$REPO" "feat/t11" "dead-lane" >/dev/null 2>&1
printf '{"pid":1,"lane":"dead-lane","branch":"feat/t11","acquired_at":"2026-01-01T00:00:00Z","acquired_epoch":%s}\n' \
    "$(( $(date +%s) - 4000 ))" > "$lockdir/owner.json"
out="$(bash "$LIB" acquire-wait "$REPO" "feat/t11" "new-lane" 2 300 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && grepq "$out" -F 'RECLAIMING a stale lock' &&
   grep -q '"lane":"new-lane"' "$lockdir/owner.json"; then
    pass "T11: acquire-wait reclaims a lock past its TTL and says so"
else
    fail "T11: stale reclaim (rc=$rc, out=$out, owner=$(cat "$lockdir/owner.json" 2>/dev/null))"
fi

# --- T12: reclamation never steals a lock that changed hands ---------------
# HIMMEL-1558 CR (codex-1): between judging a lock stale and taking it away,
# the holder can release and another writer acquire — an unconditional rm
# would delete that LIVE lock and put two writers on the resource. This case
# sources the library instead of driving the CLI, because the window is INSIDE
# a single acquire-wait call and no sequence of CLI invocations can open it.
# shellcheck source=scripts/lib/shared-branch-lock.sh
# shellcheck disable=SC1090,SC1091
. "$LIB"
lockdir="$(cd "$REPO" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/himmel-shared-branch/feat-t12.lock"
bash "$LIB" acquire "$REPO" "feat/t12" "live-lane" >/dev/null 2>&1
if _sbl_reclaim "$lockdir" '{"pid":999,"lane":"someone-else","acquired_epoch":1}'; then
    fail "T12: reclaim must REFUSE when the holder record is not the one judged stale"
else
    pass "T12: reclaim refuses when the lock changed hands"
fi
if [ -d "$lockdir" ] && grep -q '"lane":"live-lane"' "$lockdir/owner.json" 2>/dev/null; then
    pass "T12: the live holder's lock survives the refused reclaim intact"
else
    fail "T12: a refused reclaim deleted or replaced the live lock ($(cat "$lockdir/owner.json" 2>/dev/null || echo MISSING))"
fi

# --- T13: release-if-owner is conditional AND has no check-then-act window --
# HIMMEL-1558 CR round 2 (codex-3): a holder that reads the owner record and
# then calls plain `release` can have the lock reclaimed in between and delete
# the NEW holder's lock. release-if-owner compares the record while the
# directory is exclusively its own, so a stranger's lock is refused (rc 3) and
# left intact, while the true owner's release still succeeds.
lockdir="$(cd "$REPO" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/himmel-shared-branch/feat-t13.lock"
bash "$LIB" acquire "$REPO" "feat/t13" "holder-lane" >/dev/null 2>&1
out="$(bash "$LIB" release-if-owner "$REPO" "feat/t13" '{"pid":999,"lane":"someone-else"}' 2>&1)"
rc=$?
if [ "$rc" -eq 3 ] && grepq "$out" -F 'NOT releasing'; then
    pass "T13: release-if-owner refuses (rc=3) when the record is not ours"
else
    fail "T13: release-if-owner should refuse rc=3 (got rc=$rc, out=$out)"
fi
if [ -d "$lockdir" ]; then
    pass "T13: the other holder's lock survives the refused release"
else
    fail "T13: a refused release deleted the lock"
fi
owner="$(cat "$lockdir/owner.json" 2>/dev/null)"
rc=0
bash "$LIB" release-if-owner "$REPO" "feat/t13" "$owner" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ] && [ ! -d "$lockdir" ]; then
    pass "T13: release-if-owner releases when the record IS ours"
else
    fail "T13: owner-matched release should free the lock (rc=$rc, dir=$([ -d "$lockdir" ] && echo present || echo gone))"
fi
# CR round 8 (codex-1): rc 0 is the caller's PROOF that its critical section
# was mutually excluded, so an ABSENT lock must NOT report success. A run that
# still held the lock would find the directory present; absence means it was
# TTL-reclaimed and the reclaimer already released, i.e. the caller's work was
# NOT excluded. rc 0 there let a starved marker writer's push proceed after
# clobbering a newer certificate.
rc=0
bash "$LIB" release-if-owner "$REPO" "feat/t13" "$owner" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 3 ]; then
    pass "T13: release-if-owner on an absent lock is rc=3, not a false proof of exclusion"
else
    fail "T13: release-if-owner on an absent lock should be rc=3 (got $rc)"
fi

echo "---"
echo "PASSED=$PASSED FAILED=$FAILED"
[ "$FAILED" = 0 ]
