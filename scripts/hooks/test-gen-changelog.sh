#!/usr/bin/env bash
# Smoke test for scripts/gen-changelog.sh.
#
# Builds throwaway git repos, exercises the generator, asserts correct output.
# Usage: bash scripts/hooks/test-gen-changelog.sh
#
# Exit 0 if all cases pass, 1 otherwise.
#
# shellcheck disable=SC2034  # GEN/R used inside eval'd test body strings, not directly
# shellcheck disable=SC2016  # single-quoted test body strings intentionally contain $
# shellcheck disable=SC2317  # fixture fns called indirectly via eval inside run_test
# shellcheck disable=SC2329  # same as SC2317 (alias in newer shellcheck versions)
set -uo pipefail

HOOKS="$(cd "$(dirname "$0")" && pwd)"
GEN="$(cd "$HOOKS/.." && pwd)/gen-changelog.sh"

# ---------------------------------------------------------------------------
# Fixture: temp git repo with a few conventional commits
# ---------------------------------------------------------------------------

setup_commits() {
  R=$(mktemp -d)
  git -C "$R" init -q
  git -C "$R" config user.email t@t
  git -C "$R" config user.name t
  git -C "$R" commit -q --allow-empty -m "chore: initial scaffold"
  git -C "$R" commit -q --allow-empty -m "feat: baseline feature"
  git -C "$R" commit -q --allow-empty -m "fix: baseline bug fix"
}

# ---------------------------------------------------------------------------
# run_test harness (modeled on test-doc-guard.sh)
# ---------------------------------------------------------------------------

_failures=0

run_test() {
  local name="$1" body="$2"
  local rc=0
  ( eval "$body" ) 2>/dev/null || rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '  PASS  %s\n' "$name"
  else
    printf '  FAIL  %s (subshell rc=%s)\n' "$name" "$rc"
    _failures=$((_failures + 1))
  fi
}

# ---------------------------------------------------------------------------
# Step 1: Test cases (3 total)
# ---------------------------------------------------------------------------

run_test "idempotent on immediate re-run" '
  setup_commits; cd "$R";
  bash "$GEN"; cp CHANGELOG.md a; bash "$GEN"; diff -q a CHANGELOG.md
'

run_test "non-conventional commit lands under Other" '
  setup_commits; cd "$R"; git commit -q --allow-empty -m "random no-type subject";
  bash "$GEN"; grep -q "### Other" CHANGELOG.md && grep -q "random no-type subject" CHANGELOG.md
'

run_test "feat lands under Added" '
  setup_commits; cd "$R"; git commit -q --allow-empty -m "feat: shiny thing";
  bash "$GEN"; awk "/### Added/{f=1} f&&/shiny thing/{print; exit}" CHANGELOG.md | grep -q "shiny thing"
'

run_test "output is end-of-file-fixer clean (single trailing newline)" '
  setup_commits; cd "$R"; bash "$GEN";
  # last two bytes must contain exactly ONE newline — a trailing blank line
  # (two newlines) is what end-of-file-fixer would rewrite on every commit.
  [ "$(tail -c2 CHANGELOG.md | wc -l | tr -d " ")" -eq 1 ]
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
