#!/usr/bin/env bash
# Smoke test for scripts/hooks/check-debrand-coverage.sh (HIMMEL-480).
#
# WHY THIS FILE EXISTS: the generator suite (scripts/agents-md/test-generate.sh)
# only exercises generate.mjs. The hook WRAPPER around it was untested, and a
# status-capture inversion (`if ! cmd; then rc=$?`, which leaves rc=0 because
# `!` negates before the branch) shipped briefly and made the gate report
# success for every failure. Unit tests could not have caught that. These cases
# drive the hook itself and assert its exit code.
#
# The hook runs IN PLACE from the real tree (it resolves the generator and
# guardrails/lib.sh via its own SCRIPT_DIR); only the GIT REPO is a tempdir.
#
# shellcheck disable=SC2034  # R/SCRIPT used inside eval'd test body strings
# shellcheck disable=SC2016  # single-quoted test bodies intentionally contain $
# shellcheck disable=SC2317  # fixture fns called indirectly via eval
# shellcheck disable=SC2329  # same as SC2317 in newer shellcheck
set -uo pipefail

HOOKS="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HOOKS/check-debrand-coverage.sh"
REAL_CLAUDE="$HOOKS/../../CLAUDE.md"
REAL_DEBRAND="$HOOKS/../agents-md/debrand.json"

# shellcheck source=../lib/fixture-tempdir.sh
# shellcheck disable=SC1091
. "$HOOKS/../lib/fixture-tempdir.sh"

# A throwaway repo whose CLAUDE.md is a COPY of the real one, so the real
# debrand table's live rules genuinely match — the baseline must be green.
setup_repo() {
  R=$(fixture_mktemp_dir) || return 1; git -C "$R" init -q
  git -C "$R" config user.email t@t; git -C "$R" config user.name t
  : > "$R/.himmel-dev"
  mkdir -p "$R/scripts/agents-md"
  cp "$REAL_CLAUDE" "$R/CLAUDE.md"
  cp "$REAL_DEBRAND" "$R/scripts/agents-md/debrand.json"
  git -C "$R" add CLAUDE.md scripts/agents-md/debrand.json
  git -C "$R" commit -qm init
}

expect_rc() { local want=$1; shift; local rc=0; "$@" || rc=$?; [ "$rc" -eq "$want" ]; }

_failures=0
run_test() {
  local name="$1" body="$2"; local rc=0
  # The EXIT trap runs INSIDE the per-test subshell, where setup_repo's $R is
  # set — each case makes exactly one throwaway repo, so one trap cleans it.
  # Without this a 13-case run leaves 13 mktemp -d git repos behind, and they
  # accumulate across runs. `${R:-}` keeps it a harmless no-op if a case exits
  # before setup_repo runs.
  ( trap 'rm -rf "${R:-}"' EXIT; eval "$body" ) 2>/dev/null || rc=$?
  if [ "$rc" -eq 0 ]; then printf '  PASS  %s\n' "$name"
  else printf '  FAIL  %s (subshell rc=%s)\n' "$name" "$rc"; _failures=$((_failures + 1)); fi
}

run_test "no-op without .himmel-dev marker (rc=0)" '
  setup_repo && cd "$R" || exit 1; rm -f .himmel-dev;
  printf "\nx\n" >> CLAUDE.md; git add CLAUDE.md;
  expect_rc 0 bash "$SCRIPT"
'

run_test "no-op when neither input is staged (rc=0)" '
  setup_repo && cd "$R" || exit 1; echo hi > other.txt; git add other.txt;
  expect_rc 0 bash "$SCRIPT"
'

run_test "no-op for unrelated path containing CLAUDE.md (rc=0)" '
  setup_repo && cd "$R" || exit 1; mkdir -p templates/luna-second-brain;
  echo hi > templates/luna-second-brain/_CLAUDE.md;
  git add templates/luna-second-brain/_CLAUDE.md;
  expect_rc 0 bash "$SCRIPT"
'

run_test "green: staged CLAUDE.md keeps every live rule matching (rc=0)" '
  setup_repo && cd "$R" || exit 1;
  printf "\nAn unrelated new rule.\n" >> CLAUDE.md; git add CLAUDE.md;
  expect_rc 0 bash "$SCRIPT"
'

# THE regression case for the fail-open inversion: break a LIVE rule and require
# a nonzero exit. With `if ! cmd; then rc=$?` this returned 0.
run_test "blocks when a live debrand rule is orphaned (rc=1)" '
  setup_repo && cd "$R" || exit 1;
  # No sed -i: that is GNU-only and this suite must run on macOS bash 3.2 too.
  sed "s/spawns a Fable child/spawns a Fable offspring/" CLAUDE.md > CLAUDE.tmp;
  mv CLAUDE.tmp CLAUDE.md;
  git add CLAUDE.md;
  expect_rc 1 bash "$SCRIPT"
'

# A dormant rule whose phrase reappears must fail closed under enforcement:
# leaving the flag on exempts that rule from orphan detection forever after.
run_test "blocks a revived dormant rule (rc=2)" '
  setup_repo && cd "$R" || exit 1;
  printf "%s\n" "[{\"from\":\"spawns a Fable child\",\"to\":\"spawns a top-model child\",\"dormant\":true,\"note\":\"deliberately stale flag\"}]" \
    > scripts/agents-md/debrand.json;
  git add scripts/agents-md/debrand.json;
  expect_rc 2 bash "$SCRIPT"
'

# The hook must judge COMMITTED state — an unstaged debrand.json edit must not
# change the verdict.
run_test "ignores an unstaged debrand.json edit (rc=0)" '
  setup_repo && cd "$R" || exit 1;
  printf "\nAn unrelated new rule.\n" >> CLAUDE.md; git add CLAUDE.md;
  printf "%s\n" "[{\"from\":\"zzz-never-present\",\"to\":\"x\"}]" > scripts/agents-md/debrand.json;
  expect_rc 0 bash "$SCRIPT"
'

run_test "blocks a staged DELETION of CLAUDE.md (rc=2)" '
  setup_repo && cd "$R" || exit 1; git rm --cached -q CLAUDE.md;
  expect_rc 2 bash "$SCRIPT"
'

run_test "blocks a staged RENAME of CLAUDE.md (rc=2)" '
  setup_repo && cd "$R" || exit 1; git mv CLAUDE.md CLAUDE.renamed.md;
  expect_rc 2 bash "$SCRIPT"
'

run_test "malformed staged debrand.json is fatal (rc=2)" '
  setup_repo && cd "$R" || exit 1;
  printf "[{\"to\":\"x\"}]\n" > scripts/agents-md/debrand.json;
  git add scripts/agents-md/debrand.json;
  expect_rc 2 bash "$SCRIPT"
'

run_test "staged no-op debrand mapping is fatal (rc=2)" '
  setup_repo && cd "$R" || exit 1;
  printf "%s\n" "[{\"from\":\"spawns a Fable child\",\"to\":\"spawns a Fable child\"}]" \
    > scripts/agents-md/debrand.json;
  git add scripts/agents-md/debrand.json;
  expect_rc 2 bash "$SCRIPT"
'

run_test "staged duplicate-from debrand mapping is fatal (rc=2)" '
  setup_repo && cd "$R" || exit 1;
  printf "%s\n" "[{\"from\":\"duplicate-phrase\",\"to\":\"x\"},{\"from\":\"duplicate-phrase\",\"to\":\"y\"}]" \
    > scripts/agents-md/debrand.json;
  git add scripts/agents-md/debrand.json;
  expect_rc 2 bash "$SCRIPT"
'

run_test "non-array staged debrand.json is fatal (rc=2)" '
  setup_repo && cd "$R" || exit 1;
  printf "{\"from\":\"a\",\"to\":\"b\"}\n" > scripts/agents-md/debrand.json;
  git add scripts/agents-md/debrand.json;
  expect_rc 2 bash "$SCRIPT"
'

if [ "$_failures" -eq 0 ]; then echo "OK: all cases passed"; exit 0
else echo "FAIL: $_failures case(s) failed"; exit 1; fi
