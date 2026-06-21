#!/usr/bin/env bash
# test-branch-shipped.sh — self-contained tests for branch_has_merged_pr.
#
# Usage: bash scripts/lib/test-branch-shipped.sh
# Exit:  0 = all pass, 1 = one or more failures.
#
# Strategy: write tiny GH_CMD stub scripts into a temp dir, export
# FORGE=github + GH_CMD=<stub>, source branch-shipped.sh, call
# branch_has_merged_pr, assert the rc.  All stubs and state live in
# a mktemp'd dir that is cleaned up on exit.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── temp dir setup ────────────────────────────────────────────────────────────
TMPDIR_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

# A fake "primary worktree dir" for tests that need one (must look like a
# git dir so forge_detect via FORGE=github doesn't try to read origin).
PRIMARY_DIR="$TMPDIR_ROOT/primary"
mkdir -p "$PRIMARY_DIR/.git"

# ── test harness ──────────────────────────────────────────────────────────────
_pass=0
_fail=0

assert_rc() {
    local test_name="$1"
    local expected_rc="$2"
    local actual_rc="$3"
    if [ "$actual_rc" -eq "$expected_rc" ]; then
        echo "PASS: $test_name (rc=$actual_rc)"
        _pass=$(( _pass + 1 ))
    else
        echo "FAIL: $test_name — expected rc=$expected_rc got rc=$actual_rc"
        _fail=$(( _fail + 1 ))
    fi
}

# Write a GH_CMD stub script.  args: stub_path body
write_stub() {
    local stub_path="$1"; shift
    printf '%s\n' '#!/usr/bin/env bash' "$@" > "$stub_path"
    chmod +x "$stub_path"
}

# Source the library under test.  Must be RED before branch-shipped.sh exists.
BRANCH_SHIPPED_LIB="$SCRIPT_DIR/branch-shipped.sh"
# shellcheck source=scripts/lib/branch-shipped.sh
# shellcheck disable=SC1091
if ! . "$BRANCH_SHIPPED_LIB" 2>/dev/null; then
    echo "SKIP: $BRANCH_SHIPPED_LIB not found — tests would all fail with source error"
    echo "      Create scripts/lib/branch-shipped.sh, then re-run this test."
    exit 1
fi

# ── T1: count "2" on stdout, exit 0 → rc 0 (merged) ─────────────────────────
stub_t1="$TMPDIR_ROOT/gh-t1"
write_stub "$stub_t1" 'echo "2"' 'exit 0'
export FORGE=github GH_CMD="$stub_t1"
branch_has_merged_pr "feat/some-branch" "$PRIMARY_DIR"; _rc=$?
assert_rc "T1: count=2 exit=0 -> rc 0" 0 $_rc

# ── T2: count "0", exit 0 → rc 1 (not merged) ───────────────────────────────
stub_t2="$TMPDIR_ROOT/gh-t2"
write_stub "$stub_t2" 'echo "0"' 'exit 0'
export GH_CMD="$stub_t2"
branch_has_merged_pr "feat/some-branch" "$PRIMARY_DIR"; _rc=$?
assert_rc "T2: count=0 exit=0 -> rc 1" 1 $_rc

# ── T3: stub exits non-zero (unauthed/offline gh shape: nonzero, empty stdout)
stub_t3="$TMPDIR_ROOT/gh-t3"
write_stub "$stub_t3" 'exit 1'
export GH_CMD="$stub_t3"
branch_has_merged_pr "feat/some-branch" "$PRIMARY_DIR"; _rc=$?
assert_rc "T3: stub exit=1 empty stdout -> rc 2 (fail-open)" 2 $_rc

# ── T4: stub exits 0 with EMPTY stdout → rc 2 (defensive) ───────────────────
stub_t4="$TMPDIR_ROOT/gh-t4"
write_stub "$stub_t4" 'echo ""' 'exit 0'
export GH_CMD="$stub_t4"
branch_has_merged_pr "feat/some-branch" "$PRIMARY_DIR"; _rc=$?
assert_rc "T4: exit=0 empty stdout -> rc 2 (defensive)" 2 $_rc

# ── T5: stub exits 0 with garbage ("abc") → rc 2 (numeric-payload guard) ────
stub_t5="$TMPDIR_ROOT/gh-t5"
write_stub "$stub_t5" 'echo "abc"' 'exit 0'
export GH_CMD="$stub_t5"
branch_has_merged_pr "feat/some-branch" "$PRIMARY_DIR"; _rc=$?
assert_rc "T5: exit=0 garbage stdout -> rc 2 (numeric guard)" 2 $_rc

# ── T6: timeout case — stub sleeps 30, BRANCH_SHIPPED_TIMEOUT=1 → rc 2, bounded
# Only run the bounded-timeout assertions when a timeout binary is available;
# without one the library runs unguarded and the stub would actually sleep 30s.
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
    stub_t6="$TMPDIR_ROOT/gh-t6"
    write_stub "$stub_t6" 'sleep 30' 'echo "2"'
    export GH_CMD="$stub_t6"
    export BRANCH_SHIPPED_TIMEOUT=1
    _t_start=$(date +%s)
    branch_has_merged_pr "feat/some-branch" "$PRIMARY_DIR"; _rc=$?
    _t_end=$(date +%s)
    _elapsed=$(( _t_end - _t_start ))
    unset BRANCH_SHIPPED_TIMEOUT
    assert_rc "T6: timeout stub -> rc 2 (fail-open)" 2 $_rc
    if [ "$_elapsed" -lt 10 ]; then
        echo "PASS: T6 wall-clock bounded (${_elapsed}s < 10s)"
        _pass=$(( _pass + 1 ))
    else
        echo "FAIL: T6 wall-clock NOT bounded (${_elapsed}s >= 10s)"
        _fail=$(( _fail + 1 ))
    fi
else
    echo "SKIP: T6 — no timeout/gtimeout binary; skipping bounded-timeout assertions"
    _pass=$(( _pass + 1 ))
fi

# ── T7: branch "main" → rc 1, NO forge call ──────────────────────────────────
sentinel_t7="$TMPDIR_ROOT/sentinel-t7"
stub_t7="$TMPDIR_ROOT/gh-t7"
write_stub "$stub_t7" "touch \"$sentinel_t7\"" 'echo "2"' 'exit 0'
export GH_CMD="$stub_t7"
branch_has_merged_pr "main" "$PRIMARY_DIR"; _rc=$?
assert_rc "T7: branch=main -> rc 1 (short-circuit)" 1 $_rc
if [ ! -f "$sentinel_t7" ]; then
    echo "PASS: T7 no forge call made for 'main'"
    _pass=$(( _pass + 1 ))
else
    echo "FAIL: T7 forge was called for branch 'main' (sentinel found)"
    _fail=$(( _fail + 1 ))
fi

# ── T8: branch "master" → rc 1, NO forge call ───────────────────────────────
sentinel_t8="$TMPDIR_ROOT/sentinel-t8"
stub_t8="$TMPDIR_ROOT/gh-t8"
write_stub "$stub_t8" "touch \"$sentinel_t8\"" 'echo "2"' 'exit 0'
export GH_CMD="$stub_t8"
branch_has_merged_pr "master" "$PRIMARY_DIR"; _rc=$?
assert_rc "T8: branch=master -> rc 1 (short-circuit)" 1 $_rc
if [ ! -f "$sentinel_t8" ]; then
    echo "PASS: T8 no forge call made for 'master'"
    _pass=$(( _pass + 1 ))
else
    echo "FAIL: T8 forge was called for branch 'master' (sentinel found)"
    _fail=$(( _fail + 1 ))
fi

# ── T9: branch "" (empty) → rc 1, NO forge call ─────────────────────────────
sentinel_t9="$TMPDIR_ROOT/sentinel-t9"
stub_t9="$TMPDIR_ROOT/gh-t9"
write_stub "$stub_t9" "touch \"$sentinel_t9\"" 'echo "2"' 'exit 0'
export GH_CMD="$stub_t9"
branch_has_merged_pr "" "$PRIMARY_DIR"; _rc=$?
assert_rc "T9: branch=empty -> rc 1 (short-circuit)" 1 $_rc
if [ ! -f "$sentinel_t9" ]; then
    echo "PASS: T9 no forge call made for empty branch"
    _pass=$(( _pass + 1 ))
else
    echo "FAIL: T9 forge was called for empty branch (sentinel found)"
    _fail=$(( _fail + 1 ))
fi

# ── T10: branch "HEAD" → rc 1, NO forge call ─────────────────────────────────
sentinel_t10="$TMPDIR_ROOT/sentinel-t10"
stub_t10="$TMPDIR_ROOT/gh-t10"
write_stub "$stub_t10" "touch \"$sentinel_t10\"" 'echo "2"' 'exit 0'
export GH_CMD="$stub_t10"
branch_has_merged_pr "HEAD" "$PRIMARY_DIR"; _rc=$?
assert_rc "T10: branch=HEAD -> rc 1 (short-circuit)" 1 $_rc
if [ ! -f "$sentinel_t10" ]; then
    echo "PASS: T10 no forge call made for 'HEAD'"
    _pass=$(( _pass + 1 ))
else
    echo "FAIL: T10 forge was called for branch 'HEAD' (sentinel found)"
    _fail=$(( _fail + 1 ))
fi

# ── T11: missing primary_worktree_dir arg → rc 2 (defensive) ─────────────────
stub_t11="$TMPDIR_ROOT/gh-t11"
write_stub "$stub_t11" 'echo "2"' 'exit 0'
export GH_CMD="$stub_t11"
branch_has_merged_pr "feat/some-branch"; _rc=$?
assert_rc "T11: missing primary_dir arg -> rc 2" 2 $_rc

# ── T12: missing both args → rc 1 (empty branch short-circuits first) ────────
# The brief's primary claim is "missing primary_worktree_dir → rc 2" (T11).
# When branch is also absent (empty), the empty-branch short-circuit fires
# BEFORE the primary-dir guard, so the result is rc 1 — no forge call.
branch_has_merged_pr; _rc=$?
assert_rc "T12: missing both args -> rc 1 (empty branch short-circuit)" 1 $_rc

# ── summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $_pass passed, $_fail failed"
[ "$_fail" -eq 0 ]
