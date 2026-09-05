#!/usr/bin/env bash
# Smoke test for scripts/hooks/check-hook-lib-suites.sh (HIMMEL-1578).
#
# Builds throwaway git repos carrying fixture node:test suites, exercises each
# rc case, asserts exact rc. Usage: bash scripts/hooks/test-check-hook-lib-suites.sh
#
# Exit 0 if all cases pass, 1 otherwise.
#
# WHY THIS EXISTS, and why it is NOT circular. HIMMEL-1578 is a ticket about
# guards that nobody runs. check-hook-lib-suites.sh is itself a guard, and it
# would have shipped with zero automated coverage. This suite is discovered
# automatically by scripts/ci/run-shell-tests.sh (`**/test-*.sh`), which the
# public CI shell-unit job runs — a surface that genuinely executes, unlike the
# ci.yml node --test steps the ticket originally proposed (see the script's own
# header for why those cannot work).
#
# It plants FIXTURE suites in a temp repo rather than running the real ones, so
# it stays fast and carries no dependency on .claude/settings.json — which is in
# PRIVATE_PATHS and is a hard 404 on the public mirror where this runs.
#
# shellcheck disable=SC2034  # R used inside eval'd test body strings
# shellcheck disable=SC2016  # single-quoted test body strings intentionally contain $
# shellcheck disable=SC2317  # fixture fns called indirectly via eval inside run_test
# shellcheck disable=SC2329  # same as SC2317 (alias in newer shellcheck versions)
set -uo pipefail

HOOKS="$(cd "$(dirname "$0")" && pwd)"
# Run the script IN PLACE. It resolves its root via `git rev-parse
# --show-toplevel` and globs relative to that, so pointing PWD at a temp repo
# is enough to swap in fixture suites.
SCRIPT="$HOOKS/check-hook-lib-suites.sh"

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not found — check-hook-lib-suites.sh cannot be exercised"
  exit 0
fi

# One parent tempdir for every fixture repo, removed on exit (glm-1). The EXIT
# trap is safe here despite each case running inside a `( eval … )` subshell:
# bash does NOT fire an inherited EXIT trap when a ( ) subshell exits, only when
# the parent does — verified, not assumed.
TMPROOT=$(mktemp -d -t hooklibsuites.XXXXXX) || {
  echo "test-check-hook-lib-suites: cannot create the temporary root" >&2
  exit 1
}
trap 'rm -rf "$TMPROOT"' EXIT

PASSING_SUITE="import test from 'node:test';
import assert from 'node:assert/strict';
test('fixture passes', () => { assert.equal(1, 1); });
"
FAILING_SUITE="import test from 'node:test';
import assert from 'node:assert/strict';
test('fixture fails', () => { assert.equal(1, 2); });
"

# A repo with both globs populated by PASSING fixture suites.
setup_repo() {
  # Explicit template PATH (portable on GNU and BSD/macOS alike) so each repo
  # lands under $TMPROOT and is swept by the one trap above.
  # `exit`, not `return`: this runs inside each case's `( eval … )` subshell, so
  # exiting aborts THAT case (run_test records a FAIL) without killing the run.
  # A broken fixture must fail its case, never proceed — with `set -uo pipefail`
  # and no `-e`, an empty $R would turn the mkdir below into `/scripts/hooks`,
  # i.e. a write at filesystem root (CodeRabbit, round 2).
  R=$(mktemp -d "$TMPROOT/repo.XXXXXX") || { echo "setup_repo: mktemp failed" >&2; exit 1; }
  git -C "$R" init -q || { echo "setup_repo: git init failed in $R" >&2; exit 1; }
  git -C "$R" config user.email t@t; git -C "$R" config user.name t
  mkdir -p "$R/scripts/hooks" "$R/scripts/lib"
  printf '%s' "$PASSING_SUITE" > "$R/scripts/hooks/fixture.test.mjs"
  printf '%s' "$PASSING_SUITE" > "$R/scripts/lib/fixture.test.mjs"
}

expect_rc() { local want=$1; shift; local rc=0; "$@" || rc=$?; [ "$rc" -eq "$want" ]; }

_failures=0
run_test() {
  local name="$1" body="$2" rc=0
  ( eval "$body" ) >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then printf '  PASS  %s\n' "$name"
  else printf '  FAIL  %s (subshell rc=%s)\n' "$name" "$rc"; _failures=$((_failures + 1)); fi
}

run_test "both globs green → rc=0" '
  setup_repo; cd "$R";
  expect_rc 0 bash "$SCRIPT"
'

run_test "a failing scripts/hooks suite → rc=1" '
  setup_repo; cd "$R";
  printf "%s" "$FAILING_SUITE" > scripts/hooks/fixture.test.mjs;
  expect_rc 1 bash "$SCRIPT"
'

run_test "a failing scripts/lib suite → rc=1" '
  setup_repo; cd "$R";
  printf "%s" "$FAILING_SUITE" > scripts/lib/fixture.test.mjs;
  expect_rc 1 bash "$SCRIPT"
'

# The ls-guard is the whole reason the script does not just call `node --test`:
# node reports 0 tests and EXITS 0 on a glob that matches nothing, so a renamed
# or deleted suite would otherwise read as a pass.
run_test "empty scripts/hooks glob fires the ls-guard → rc=1" '
  setup_repo; cd "$R";
  rm -f scripts/hooks/fixture.test.mjs;
  expect_rc 1 bash "$SCRIPT"
'

run_test "empty scripts/lib glob fires the ls-guard → rc=1" '
  setup_repo; cd "$R";
  rm -f scripts/lib/fixture.test.mjs;
  expect_rc 1 bash "$SCRIPT"
'

# Guards the ls-guard against a false-green regression: prove bare `node --test`
# really does exit 0 on the empty glob the case above catches. If node ever
# changed that behaviour, the ls-guard would be dead weight and this fails loudly.
run_test "bare node --test on an empty glob still exits 0 (the ls-guard premise)" '
  setup_repo; cd "$R";
  rm -f scripts/hooks/fixture.test.mjs;
  expect_rc 0 node --test "scripts/hooks/*.test.mjs"
'

if [ "$_failures" -eq 0 ]; then
  printf 'check-hook-lib-suites: all cases passed\n'
  exit 0
fi
printf 'check-hook-lib-suites: %s case(s) FAILED\n' "$_failures"
exit 1
