#!/usr/bin/env bash
# Smoke test for scripts/hooks/check-doc-guard.sh.
#
# Builds throwaway git repos, exercises each rc case, asserts exact rc.
# Usage: bash scripts/hooks/test-doc-guard.sh
#
# Exit 0 if all cases pass, 1 otherwise.
#
# shellcheck disable=SC2034  # SCRIPT/ORIGIN/R used inside eval'd test body strings
# shellcheck disable=SC2016  # single-quoted test body strings intentionally contain $
# shellcheck disable=SC2317  # fixture fns called indirectly via eval inside run_test
# shellcheck disable=SC2329  # same as SC2317 (alias in newer shellcheck versions)
set -uo pipefail

# ---------------------------------------------------------------------------
# Step 0: Shared fixture helpers (load-bearing across Tasks 3, 4, 7, 8)
# ---------------------------------------------------------------------------

HOOKS="$(cd "$(dirname "$0")" && pwd)"
# Run the script IN PLACE from the real tree (plan-critic r2, F4): the script
# resolves its map + ../guardrails/lib.sh via its own SCRIPT_DIR, so it must stay
# where those siblings live. Only the GIT REPO is a tempdir -- the script keys the
# marker off `git rev-parse --show-toplevel` and the staged set off `git diff
# --cached`, both PWD-relative, so `cd "$R"` is all that's needed (mirrors how
# check-platforms-tested.sh is tested).
SCRIPT="$HOOKS/check-doc-guard.sh"

# setup_repo: temp git repo WITH the .himmel-dev marker.
setup_repo() {
  R=$(mktemp -d); git -C "$R" init -q
  git -C "$R" config user.email t@t; git -C "$R" config user.name t
  : > "$R/.himmel-dev"
}

setup_repo_no_marker() { setup_repo; rm -f "$R/.himmel-dev"; }

# setup_repo_with_origin: adds a bare origin with main for pre-push base resolution.
setup_repo_with_origin() {
  setup_repo
  ORIGIN=$(mktemp -d); git -C "$ORIGIN" init -q --bare
  git -C "$R" remote add origin "$ORIGIN"
  git -C "$R" commit -q --allow-empty -m init; git -C "$R" branch -M main
  git -C "$R" push -q origin main
}

expect_rc() { local want=$1; shift; local rc=0; "$@" || rc=$?; [ "$rc" -eq "$want" ]; }

# ---------------------------------------------------------------------------
# run_test harness (modeled on test-lib.sh pass/fail accounting)
# ---------------------------------------------------------------------------

_failures=0

run_test() {
  local name="$1" body="$2"
  local rc=0
  # Run each test body in a subshell so cd/R don't leak between cases
  ( eval "$body" ) 2>/dev/null || rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '  PASS  %s\n' "$name"
  else
    printf '  FAIL  %s (subshell rc=%s)\n' "$name" "$rc"
    _failures=$((_failures + 1))
  fi
}

# ---------------------------------------------------------------------------
# Step 1: Test cases (9 total -- 7 pre-commit + 2 pre-push, assert EXACT rc with expect_rc)
# ---------------------------------------------------------------------------

run_test "blocks added command without catalog (rc=1)" '
  setup_repo; cd "$R";
  mkdir -p .claude/commands docs; : > .claude/commands/foo.md; : > docs/commands-catalog.md;
  git add .claude/commands/foo.md;
  expect_rc 1 bash "$SCRIPT"
'

run_test "passes added command WITH catalog staged (rc=0)" '
  setup_repo; cd "$R";
  mkdir -p .claude/commands docs; : > .claude/commands/foo.md; : > docs/commands-catalog.md;
  git add .claude/commands/foo.md docs/commands-catalog.md;
  expect_rc 0 bash "$SCRIPT"
'

run_test "passes when modifying (not adding) a command (rc=0)" '
  setup_repo; cd "$R";
  mkdir -p .claude/commands; : > .claude/commands/foo.md; git add . ; git commit -qm seed;
  echo x >> .claude/commands/foo.md; git add .claude/commands/foo.md;
  expect_rc 0 bash "$SCRIPT"
'

run_test "no-op without .himmel-dev marker (rc=0)" '
  setup_repo_no_marker; cd "$R";
  mkdir -p .claude/commands; : > .claude/commands/foo.md; git add .claude/commands/foo.md;
  expect_rc 0 bash "$SCRIPT"
'

run_test "path-keying: target doc absent from tree, pair inert (rc=0)" '
  setup_repo; cd "$R"; rm -f docs/commands-catalog.md 2>/dev/null;
  mkdir -p .claude/commands; : > .claude/commands/foo.md; git add .claude/commands/foo.md;
  expect_rc 0 bash "$SCRIPT"
'

run_test "DOC_GUARD_OK=1 bypasses (rc=0)" '
  setup_repo; cd "$R";
  mkdir -p .claude/commands; : > .claude/commands/foo.md; git add .claude/commands/foo.md;
  expect_rc 0 env DOC_GUARD_OK=1 bash "$SCRIPT"
'

run_test "DOC_GUARD_FORCE_ERR=1 exits 2" '
  setup_repo; cd "$R"; expect_rc 2 env DOC_GUARD_FORCE_ERR=1 bash "$SCRIPT"
'

run_test "pre-push passes when catalog updated in a LATER commit of range (rc=0)" '
  setup_repo_with_origin; cd "$R"; git checkout -qb feat/x;
  mkdir -p .claude/commands docs;
  : > .claude/commands/foo.md; git add .; git commit -qm "add cmd";
  echo "- foo" >> docs/commands-catalog.md; git add .; git commit -qm "catalog";
  expect_rc 0 env DOC_GUARD_NO_FETCH=1 bash "$SCRIPT" --pre-push
'

run_test "pre-push blocks when range never touches catalog (rc=1)" '
  setup_repo_with_origin; cd "$R";
  mkdir -p .claude/commands docs; : > docs/commands-catalog.md;
  git add .; git commit -qm "init catalog";
  git push -q origin main;
  git checkout -qb feat/y;
  : > .claude/commands/bar.md; git add .; git commit -qm "add cmd";
  expect_rc 1 env DOC_GUARD_NO_FETCH=1 bash "$SCRIPT" --pre-push
'

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

if [ "$_failures" -eq 0 ]; then
  echo "OK: all cases passed"
  exit 0
else
  echo "FAIL: $_failures case(s) failed"
  exit 1
fi
