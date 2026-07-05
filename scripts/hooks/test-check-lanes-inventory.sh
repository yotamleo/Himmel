#!/usr/bin/env bash
# Smoke test for scripts/hooks/check-lanes-inventory.sh (HIMMEL-689).
#
# Builds throwaway git repos, exercises each rc case, asserts exact rc.
# Usage: bash scripts/hooks/test-check-lanes-inventory.sh
#
# Exit 0 if all cases pass, 1 otherwise.
#
# shellcheck disable=SC2034  # R used inside eval'd test body strings
# shellcheck disable=SC2016  # single-quoted test body strings intentionally contain $
# shellcheck disable=SC2317  # fixture fns called indirectly via eval inside run_test
# shellcheck disable=SC2329  # same as SC2317 (alias in newer shellcheck versions)
set -uo pipefail

HOOKS="$(cd "$(dirname "$0")" && pwd)"
# Run the script IN PLACE (it resolves ../lanes/check.mjs + ../guardrails/lib.sh
# via its own SCRIPT_DIR). Only the GIT REPO is a tempdir; the script keys the
# marker off `git rev-parse --show-toplevel` and the staged set off `git
# diff --cached`, both PWD-relative, so `cd "$R"` suffices.
SCRIPT="$HOOKS/check-lanes-inventory.sh"

setup_repo() {
  R=$(mktemp -d); git -C "$R" init -q
  git -C "$R" config user.email t@t; git -C "$R" config user.name t
  : > "$R/.himmel-dev"
}
setup_repo_no_marker() { setup_repo; rm -f "$R/.himmel-dev"; }

expect_rc() { local want=$1; shift; local rc=0; "$@" || rc=$?; [ "$rc" -eq "$want" ]; }

_failures=0
run_test() {
  local name="$1" body="$2" rc=0
  ( eval "$body" ) 2>/dev/null || rc=$?
  if [ "$rc" -eq 0 ]; then printf '  PASS  %s\n' "$name"
  else printf '  FAIL  %s (subshell rc=%s)\n' "$name" "$rc"; _failures=$((_failures + 1)); fi
}

run_test "clean CLAUDE.md (policy + /lanes pointer) staged → pass (rc=0)" '
  setup_repo; cd "$R";
  printf "Delegate down. Query \`/lanes\` (from scripts/lanes/lanes.json).\n" > CLAUDE.md;
  git add CLAUDE.md;
  expect_rc 0 bash "$SCRIPT"
'

run_test "re-introduced inventory needle staged → block (rc=1)" '
  setup_repo; cd "$R";
  printf -- "- GLM lane (scripts/telegram/spawn-glm.ts) — impl chunks\n" > CLAUDE.md;
  git add CLAUDE.md;
  expect_rc 1 bash "$SCRIPT"
'

run_test "no-op without .himmel-dev marker (rc=0)" '
  setup_repo_no_marker; cd "$R";
  printf -- "- codex (CR_PROFILE=paid)\n" > CLAUDE.md; git add CLAUDE.md;
  expect_rc 0 bash "$SCRIPT"
'

run_test "CLAUDE.md not staged → no-op (rc=0)" '
  setup_repo; cd "$R";
  printf "unrelated\n" > other.txt; git add other.txt;
  expect_rc 0 bash "$SCRIPT"
'

run_test "LANES_GUARD_OK=1 bypasses a would-be drift (rc=0)" '
  setup_repo; cd "$R";
  printf -- "- gemini (gemini-subagent)\n" > CLAUDE.md; git add CLAUDE.md;
  expect_rc 0 env LANES_GUARD_OK=1 bash "$SCRIPT"
'

run_test "pointer line naming lanes.json is exempt (rc=0)" '
  setup_repo; cd "$R";
  printf "Query the live set with \`/lanes\` (derived from scripts/lanes/lanes.json + machine state).\n" > CLAUDE.md;
  git add CLAUDE.md;
  expect_rc 0 bash "$SCRIPT"
'

if [ "$_failures" -eq 0 ]; then echo "OK: all cases passed"; exit 0
else echo "FAIL: $_failures case(s) failed"; exit 1; fi
