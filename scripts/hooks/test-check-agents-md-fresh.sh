#!/usr/bin/env bash
# Smoke test for scripts/hooks/check-agents-md-fresh.sh (HIMMEL-471).
# Builds throwaway git repos, exercises each rc case, asserts exact rc.
# The hook is run IN PLACE from the real tree (it resolves the generator +
# guardrails/lib.sh via its own SCRIPT_DIR); only the GIT REPO is a tempdir.
# The hook validates the STAGED INDEX (git show :path), so setups COMMIT an
# initial fresh pair and then stage edits to exercise index-vs-worktree.
#
# shellcheck disable=SC2034  # R/GEN used inside eval'd test body strings
# shellcheck disable=SC2016  # single-quoted test body strings intentionally contain $
# shellcheck disable=SC2317  # fixture fns called indirectly via eval inside run_test
# shellcheck disable=SC2329  # same as SC2317 (alias in newer shellcheck versions)
set -uo pipefail

HOOKS="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HOOKS/check-agents-md-fresh.sh"
GEN="$HOOKS/../agents-md/generate.mjs"

regen() { AGENTS_MD_SOURCE="$R/CLAUDE.md" AGENTS_MD_TARGET="$R/AGENTS.md" node "$GEN" --write >/dev/null 2>&1; }

# A throwaway git repo with the .himmel-dev marker and a COMMITTED fresh
# CLAUDE.md + AGENTS.md pair (so the index baseline is consistent).
setup_repo() {
  R=$(mktemp -d); git -C "$R" init -q
  git -C "$R" config user.email t@t; git -C "$R" config user.name t
  : > "$R/.himmel-dev"
  printf '# Fixture Rules\n\nDo the thing. Use judgement on trivial tasks.\n' > "$R/CLAUDE.md"
  regen
  git -C "$R" add CLAUDE.md AGENTS.md; git -C "$R" commit -qm init
}
setup_repo_no_marker() { setup_repo; rm -f "$R/.himmel-dev"; }

expect_rc() { local want=$1; shift; local rc=0; "$@" || rc=$?; [ "$rc" -eq "$want" ]; }

_failures=0
run_test() {
  local name="$1" body="$2"; local rc=0
  ( eval "$body" ) 2>/dev/null || rc=$?
  if [ "$rc" -eq 0 ]; then printf '  PASS  %s\n' "$name"
  else printf '  FAIL  %s (subshell rc=%s)\n' "$name" "$rc"; _failures=$((_failures + 1)); fi
}

run_test "no-op without .himmel-dev marker (rc=0)" '
  setup_repo_no_marker; cd "$R";
  printf "\nx\n" >> CLAUDE.md; git add CLAUDE.md;
  expect_rc 0 bash "$SCRIPT"
'

run_test "no-op when no relevant file staged (rc=0)" '
  setup_repo; cd "$R"; echo hi > other.txt; git add other.txt;
  expect_rc 0 bash "$SCRIPT"
'

run_test "fresh: CLAUDE.md edit + regenerated AGENTS.md both staged (rc=0)" '
  setup_repo; cd "$R";
  printf "\nA new rule.\n" >> CLAUDE.md; regen; git add CLAUDE.md AGENTS.md;
  expect_rc 0 bash "$SCRIPT"
'

# The load-bearing index-vs-worktree case: worktree is CONSISTENT (regenerated)
# but only CLAUDE.md is staged, so the INDEX AGENTS.md is stale. The old
# worktree-reading logic would pass (rc=0); the staged-index logic blocks.
run_test "stale: CLAUDE.md staged, AGENTS.md NOT (index stale, worktree consistent) → block (rc=1)" '
  setup_repo; cd "$R";
  printf "\nAn extra rule.\n" >> CLAUDE.md; regen; git add CLAUDE.md;
  expect_rc 1 bash "$SCRIPT"
'

run_test "AGENTS.md absent from index while a generator input is staged → block (rc=1)" '
  R=$(mktemp -d); git -C "$R" init -q;
  git -C "$R" config user.email t@t; git -C "$R" config user.name t;
  : > "$R/.himmel-dev";
  printf "# Fixture\n\nbody\n" > "$R/CLAUDE.md";
  cd "$R"; git add CLAUDE.md;
  expect_rc 1 bash "$SCRIPT"
'

run_test "AGENTS_MD_OK=1 bypasses a stale tree (rc=0)" '
  setup_repo; cd "$R";
  printf "\nAn extra rule.\n" >> CLAUDE.md; git add CLAUDE.md;
  expect_rc 0 env AGENTS_MD_OK=1 bash "$SCRIPT"
'

run_test "CRLF AGENTS.md in index does NOT false-positive (rc=0)" '
  setup_repo; cd "$R";
  printf "\nA new rule.\n" >> CLAUDE.md; regen;
  awk "BEGIN{ORS=\"\r\n\"}{print}" AGENTS.md > AGENTS.md.crlf && mv AGENTS.md.crlf AGENTS.md;
  git add CLAUDE.md AGENTS.md;
  expect_rc 0 bash "$SCRIPT"
'

run_test "cannot-evaluate: staged CLAUDE.md has an @include → fail-closed (rc=2)" '
  setup_repo; cd "$R";
  printf "# Fixture\n@RTK.md\nmore\n" > CLAUDE.md; git add CLAUDE.md;
  expect_rc 2 bash "$SCRIPT"
'

if [ "$_failures" -eq 0 ]; then echo "OK: all cases passed"; exit 0
else echo "FAIL: $_failures case(s) failed"; exit 1; fi
