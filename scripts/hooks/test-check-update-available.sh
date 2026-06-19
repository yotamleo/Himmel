#!/usr/bin/env bash
# test-check-update-available.sh — smoke test for check-update-available.sh
# (HIMMEL-413).
#
# 8 numbered tests, ~14 assertions.
#
# Covers:
#   1. UPDATE_CHECK_DISABLE=1 → silent exit 0, no stamp written.
#   2. No git repo → silent exit 0.
#   3. behind=0 → silent (up to date).
#   4. behind=N → nudge emitted with correct count.
#   5. No remote at all → silent exit 0 (fetch-exit path).
#   6. Remote present but no tracking branch set → silent exit 0 (@{u} path).
#   7. Throttle within interval → silent (no second run).
#   8. Throttle after interval → runs again.
#
# Uses UPDATE_CHECK_STATE_DIR to keep all state in a throwaway tmpdir.
# Creates a local bare "upstream" repo and a clone with commits ahead
# to simulate "behind N" without any real network dependency.

set -euo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/check-update-available.sh"

if [ ! -f "$HOOK" ]; then
    echo "FAIL: $HOOK not found" >&2
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

assert_pass() { pass=$((pass + 1)); echo "  PASS: $1"; }
assert_fail() { fail=$((fail + 1)); echo "  FAIL: $1"; }

assert_contains() {
    local desc="$1" pattern="$2" actual="$3"
    if printf '%s' "$actual" | grep -q "$pattern"; then
        assert_pass "$desc"
    else
        assert_fail "$desc — expected pattern '$pattern', got: $actual"
    fi
}

assert_empty() {
    local desc="$1" actual="$2"
    if [ -z "$actual" ]; then
        assert_pass "$desc"
    else
        assert_fail "$desc — expected empty stdout, got: $actual"
    fi
}

# Counter to ensure unique repo directories even for the same N + PID combo.
_repo_counter=0

# Build a local "upstream" bare repo + a clone that is N commits behind it.
# Sets globals: CHECKOUT_DIR (working clone).
# Uses the repo's actual default branch name to stay portable.
make_repo_behind() {
    local n="${1:-1}"
    _repo_counter=$((_repo_counter + 1))
    local base="$TMP/repo_${n}_${_repo_counter}"
    local bare="$base/upstream.git"
    local clone="$base/checkout"

    mkdir -p "$bare" "$clone"

    # Init bare upstream.
    git init --bare --quiet "$bare"

    # Init clone, make first commit, push, set upstream tracking.
    git init --quiet "$clone"
    git -C "$clone" config user.email "test@test.test"
    git -C "$clone" config user.name "Test"
    git -C "$clone" remote add origin "$bare"
    printf 'init\n' > "$clone/file.txt"
    git -C "$clone" add file.txt
    git -C "$clone" commit --quiet -m "init"

    # Determine the actual default branch (master or main depending on git config).
    local defbranch
    defbranch=$(git -C "$clone" rev-parse --abbrev-ref HEAD)

    git -C "$clone" push --quiet origin "HEAD:$defbranch" 2>/dev/null
    git -C "$clone" branch --quiet --set-upstream-to="origin/$defbranch" "$defbranch" 2>/dev/null || \
        git -C "$clone" branch --quiet -u "origin/$defbranch" "$defbranch" 2>/dev/null || true

    if [ "$n" -gt 0 ]; then
        # Add N commits to upstream via a secondary clone.
        local work="$base/work"
        git clone --quiet "$bare" "$work" 2>/dev/null
        git -C "$work" config user.email "test@test.test"
        git -C "$work" config user.name "Test"
        local i
        for i in $(seq 1 "$n"); do
            printf '%s\n' "upstream-commit-$i" > "$work/file.txt"
            git -C "$work" add file.txt
            git -C "$work" commit --quiet -m "upstream $i"
        done
        git -C "$work" push --quiet origin "$defbranch" 2>/dev/null
    fi

    CHECKOUT_DIR="$clone"
}

# ─── Test 1: kill switch ────────────────────────────────────────────────────
echo "Test 1: UPDATE_CHECK_DISABLE=1 → silent"
SD="$TMP/s1"; mkdir -p "$SD"
out=$(UPDATE_CHECK_DISABLE=1 UPDATE_CHECK_STATE_DIR="$SD" bash "$HOOK" 2>/dev/null) || true
assert_empty "disabled: no output" "$out"
if [ ! -f "$SD/himmel-update-check-last" ]; then
    assert_pass "disabled: no stamp written"
else
    assert_fail "disabled: stamp should NOT be written"
fi

# ─── Test 2: no git repo ────────────────────────────────────────────────────
echo "Test 2: no git repo → silent"
SD="$TMP/s2"; mkdir -p "$SD"
NODIR="$TMP/nogit"
mkdir -p "$NODIR"
out=$(UPDATE_CHECK_STATE_DIR="$SD" CLAUDE_PROJECT_DIR="$NODIR" bash "$HOOK" 2>/dev/null) || true
assert_empty "no-git: no output" "$out"

# ─── Test 3: behind=0 (up to date) → silent ─────────────────────────────────
echo "Test 3: behind=0 → silent"
make_repo_behind 0
SD="$TMP/s3"; mkdir -p "$SD"
out=$(UPDATE_CHECK_STATE_DIR="$SD" CLAUDE_PROJECT_DIR="$CHECKOUT_DIR" bash "$HOOK" 2>/dev/null) || true
assert_empty "behind=0: no output" "$out"

# ─── Test 4: behind=N → nudge with correct count ────────────────────────────
echo "Test 4: behind=2 → nudge emitted"
make_repo_behind 2
SD="$TMP/s4"; mkdir -p "$SD"
out=$(UPDATE_CHECK_STATE_DIR="$SD" CLAUDE_PROJECT_DIR="$CHECKOUT_DIR" bash "$HOOK" 2>/dev/null) || true
assert_contains "behind=2: system-reminder tag" "system-reminder" "$out"
assert_contains "behind=2: count in output" "2 commit" "$out"
assert_contains "behind=2: /himmel-update mention" "/himmel-update" "$out"

# ─── Test 5: no remote at all → silent (fetch-exit path) ───────────────────────────────────
echo "Test 5: no remote → silent (fetch-exit path)"
NOUPS="$TMP/noups"; mkdir -p "$NOUPS"
git init --quiet "$NOUPS"
git -C "$NOUPS" config user.email "t@t.t"
git -C "$NOUPS" config user.name "T"
printf 'x\n' > "$NOUPS/f"
git -C "$NOUPS" add f
git -C "$NOUPS" commit --quiet -m "x"
# No remote at all: git fetch origin fails → hook exits 0 at fetch step.
SD="$TMP/s5"; mkdir -p "$SD"
out=$(UPDATE_CHECK_STATE_DIR="$SD" CLAUDE_PROJECT_DIR="$NOUPS" bash "$HOOK" 2>/dev/null) || true
assert_empty "no-remote: no output" "$out"

# ─── Test 6: remote present, no tracking branch set → silent (@{u} path) ──────
echo "Test 6: remote present, no tracking branch → silent (@{u} path)"
# Build a bare local repo to serve as origin (fetchable, no network needed).
BARE6="$TMP/bare6.git"
WORK6="$TMP/work6"
mkdir -p "$BARE6"
git init --bare --quiet "$BARE6"
git init --quiet "$WORK6"
git -C "$WORK6" config user.email "t@t.t"
git -C "$WORK6" config user.name "T"
printf 'y\n' > "$WORK6/f"
git -C "$WORK6" add f
git -C "$WORK6" commit --quiet -m "init"
# Wire up origin so git fetch origin succeeds.
git -C "$WORK6" remote add origin "$BARE6"
# Push to bare so the fetch has something to talk to.
DEFBR6=$(git -C "$WORK6" rev-parse --abbrev-ref HEAD)
git -C "$WORK6" push --quiet origin "HEAD:$DEFBR6" 2>/dev/null
# Deliberately do NOT set upstream tracking for the current branch
# (no --set-upstream-to), so @{u} fails → hook exits 0 after fetch succeeds.
SD="$TMP/s6"; mkdir -p "$SD"
out=$(UPDATE_CHECK_STATE_DIR="$SD" CLAUDE_PROJECT_DIR="$WORK6" bash "$HOOK" 2>/dev/null) || true
assert_empty "no-tracking-branch: no output" "$out"

# ─── Test 7: throttle within interval → silent (no second run) ──────────
echo "Test 7: throttle within interval → silent"
make_repo_behind 1
SD="$TMP/s7"; mkdir -p "$SD"
# First run: should emit nudge and write stamp.
out1=$(UPDATE_CHECK_STATE_DIR="$SD" CLAUDE_PROJECT_DIR="$CHECKOUT_DIR" bash "$HOOK" 2>/dev/null) || true
assert_contains "throttle: first run emits nudge" "system-reminder" "$out1"
if [ -f "$SD/himmel-update-check-last" ]; then
    assert_pass "throttle: stamp written after first run"
else
    assert_fail "throttle: stamp missing after first run"
fi
# Second run immediately (interval=14400 so fresh stamp blocks it): should be throttled → silent.
out2=$(UPDATE_CHECK_STATE_DIR="$SD" UPDATE_CHECK_INTERVAL=14400 CLAUDE_PROJECT_DIR="$CHECKOUT_DIR" bash "$HOOK" 2>/dev/null) || true
assert_empty "throttle: second run (within interval) silent" "$out2"

# ─── Test 8: throttle after interval expires → runs again ────────────
echo "Test 8: throttle expired → runs again"
make_repo_behind 1
SD="$TMP/s8"; mkdir -p "$SD"
# Write an old stamp by using interval=0 (forces the hook to always think the
# interval has elapsed), so we simulate "interval expired".
out=$(UPDATE_CHECK_STATE_DIR="$SD" UPDATE_CHECK_INTERVAL=0 CLAUDE_PROJECT_DIR="$CHECKOUT_DIR" bash "$HOOK" 2>/dev/null) || true
assert_contains "expired throttle (interval=0): nudge emitted" "system-reminder" "$out"

# ─── Summary ─────────────────────────────────────────────────────────────────
echo
echo "RESULTS: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
exit 0
