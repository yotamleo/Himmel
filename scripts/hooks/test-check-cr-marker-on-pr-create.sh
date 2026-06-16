#!/usr/bin/env bash
# Smoke test for scripts/hooks/check-cr-marker-on-pr-create.sh (HIMMEL-213).
#
# HIMMEL-213: the hook used to resolve the branch from CLAUDE_PROJECT_DIR
# (the main checkout, on `main`), but `gh pr create` actually runs in a
# worktree on a feature branch. It looked up cr-pending/main (empty) and
# never fired. The fix parses `--head <branch>` from the extracted
# `gh pr create` command and checks cr-pending/<that-branch> instead — and,
# because project_dir HEAD is main's HEAD (wrong for the head branch),
# BLOCKS on mere marker presence when resolved from --head.
#
# Covers (acceptance):
#   1. gh pr create --head feat/X (marker present for feat/X) -> BLOCK (exit 2),
#      with CLAUDE_PROJECT_DIR on main.
#   2. --head=feat/X form, marker present -> BLOCK (exit 2).
#   2b. -H feat/X short form, marker present -> BLOCK (exit 2).
#   2c. --head owner:feat/X fork form (owner stripped), marker present -> BLOCK.
#   3. --head feat/X, NO marker -> allow (exit 0).
#   4. No --head, marker present on current (project_dir) branch + SHA match
#      -> BLOCK (exit 2) — fall-back path not regressed.
#   5. Non-`gh pr create` command -> allow (exit 0).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/check-cr-marker-on-pr-create.sh"

PASS=0
FAIL=0
TMP_ROOT=""

# shellcheck disable=SC2329,SC2317  # invoked via trap; body reachable through it
cleanup() {
    if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
        rm -rf "$TMP_ROOT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }

# Setup: tmp git repo on main, plus a linked worktree on feat/X.
TMP_ROOT=$(mktemp -d)
if command -v cygpath >/dev/null 2>&1; then
    TMP_ROOT=$(cygpath -m "$TMP_ROOT")
fi
REPO="$TMP_ROOT/repo"
git init -q --initial-branch=main "$REPO" 2>/dev/null || {
    git init -q "$REPO"
    git -C "$REPO" symbolic-ref HEAD refs/heads/main || true
}
git -C "$REPO" -c user.email=t@test.com -c user.name=test commit -q --allow-empty -m "init"
git -C "$REPO" branch -m main 2>/dev/null || true

# Feature branch + worktree (the place gh pr create really runs).
git -C "$REPO" branch feat/X
WORKTREE="$TMP_ROOT/wt-featX"
git -C "$REPO" worktree add -q "$WORKTREE" feat/X

# project_dir = main checkout (stays on main). This is what the hook sees as
# CLAUDE_PROJECT_DIR in the real session-in-main / work-in-worktree pattern.
PROJECT_DIR="$REPO"

# Marker lives under the SHARED .git (git-common-dir), regardless of worktree.
git_common=$(git -C "$REPO" rev-parse --git-common-dir)
case "$git_common" in
    /*|?:/*|?:\\*) ;;
    *)             git_common="$REPO/$git_common" ;;
esac
marker_for() { echo "${git_common}/cr-pending/$1"; }

write_marker() {
    local branch="$1"
    local m
    m=$(marker_for "$branch")
    mkdir -p "$(dirname "$m")"
    # Format mirrors check-cr-before-push.sh: "<iso-date> | <sha>"
    printf '%s | %s\n' "2026-05-31T00:00:00+00:00" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" > "$m"
}

# Run the hook with a given command string as the PreToolUse payload, with
# CLAUDE_PROJECT_DIR pointed at the main checkout. Returns exit code via rc.
run_hook() {
    local command_json="$1"
    local payload
    payload=$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$command_json")
    rc=0
    out=$(printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$HOOK" 2>&1) || rc=$?
}

# Test 1: --head feat/X, marker present -> BLOCK (exit 2) -------------
echo "TEST: gh pr create --head feat/X, marker present, project_dir on main -> BLOCK"
write_marker "feat/X"
run_hook "gh pr create --head feat/X --base main --title t --body b"
if [ "$rc" -eq 2 ]; then
    pass "blocked (exit 2) on --head feat/X with marker"
else
    fail "expected exit 2, got rc=$rc" "out: $out"
fi
case "$out" in
    *"CR review pending for feat/X"*) pass "stderr names the head branch feat/X" ;;
    *) fail "expected 'CR review pending for feat/X' in stderr" "out: $out" ;;
esac

# Test 2: --head=feat/X form, marker present -> BLOCK ----------------
echo "TEST: --head=feat/X (equals form), marker present -> BLOCK"
run_hook "gh pr create --head=feat/X --base main"
if [ "$rc" -eq 2 ]; then
    pass "blocked (exit 2) on --head=feat/X with marker"
else
    fail "expected exit 2, got rc=$rc" "out: $out"
fi

# Test 2b: -H feat/X (short form), marker present -> BLOCK ----------
echo "TEST: -H feat/X (short form), marker present -> BLOCK"
run_hook "gh pr create -H feat/X --base main"
if [ "$rc" -eq 2 ]; then
    pass "blocked (exit 2) on -H feat/X with marker"
else
    fail "expected exit 2, got rc=$rc" "out: $out"
fi

# Test 2c: --head owner:feat/X (fork form), marker present -> BLOCK --
# The owner: segment must be stripped so the marker for the bare branch
# name is found.
echo "TEST: --head owner:feat/X (fork form), marker present -> BLOCK"
run_hook "gh pr create --head somefork:feat/X --base main"
if [ "$rc" -eq 2 ]; then
    pass "blocked (exit 2) on --head owner:feat/X (owner stripped)"
else
    fail "expected exit 2, got rc=$rc" "out: $out"
fi
case "$out" in
    *"CR review pending for feat/X"*) pass "stderr names bare branch feat/X (owner stripped)" ;;
    *) fail "expected 'CR review pending for feat/X' in stderr" "out: $out" ;;
esac

# Test 3: --head feat/X, NO marker -> allow (exit 0) ----------------
echo "TEST: --head feat/X, no marker -> allow"
rm -f "$(marker_for feat/X)"
run_hook "gh pr create --head feat/X --base main"
if [ "$rc" -eq 0 ]; then
    pass "allowed (exit 0) when no marker for head branch"
else
    fail "expected exit 0, got rc=$rc" "out: $out"
fi

# Test 4: no --head, marker present on project_dir branch + SHA match -> BLOCK
# (fall-back path: branch resolved from project_dir, SHA-match refinement kept)
echo "TEST: no --head, marker on current branch (SHA match) -> BLOCK (fall-back not regressed)"
# Make project_dir live ON feat/X so branch --show-current = feat/X and HEAD
# matches the marker SHA we write.
git -C "$REPO" worktree remove --force "$WORKTREE" 2>/dev/null || true
git -C "$REPO" checkout -q feat/X
head_sha=$(git -C "$REPO" rev-parse HEAD)
m=$(marker_for "feat/X")
mkdir -p "$(dirname "$m")"
printf '%s | %s\n' "2026-05-31T00:00:00+00:00" "$head_sha" > "$m"
run_hook "gh pr create --base main"
if [ "$rc" -eq 2 ]; then
    pass "blocked (exit 2) via project_dir fall-back with SHA match"
else
    fail "expected exit 2, got rc=$rc" "out: $out"
fi
rm -f "$m"

# Test 5: non-`gh pr create` command -> allow ------------------------
echo "TEST: unrelated command -> allow (exit 0)"
write_marker "feat/X"
run_hook "git status"
if [ "$rc" -eq 0 ]; then
    pass "allowed (exit 0) for non gh-pr-create command"
else
    fail "expected exit 0, got rc=$rc" "out: $out"
fi

# Summary ------------------------------------------------------------
echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
