#!/usr/bin/env bash
# scripts/ci/run-shell-tests-fixture.sh — shared fixtures for the
# test-run-shell-tests* family (HIMMEL-2895).
#
# The runner's self-test was one 3086-line file until HIMMEL-2895 split it
# along its case boundaries, so the sharded shell-unit job (HIMMEL-2872) could
# place the pieces independently — the sharder parallelises across FILES, so
# one 382s file was a hard floor on every shard count. Everything below was
# file-scoped in that single file; it lives here so the six split suites share
# ONE copy instead of six that drift apart.
#
# Sourced, never executed. Each suite in the family starts with:
#
#     set -uo pipefail
#     # shellcheck source=run-shell-tests-fixture.sh
#     # shellcheck disable=SC1091
#     . "$(cd "$(dirname "$0")" && pwd)/run-shell-tests-fixture.sh"
#
# and ends with `rst_tally`. It provides: $RUNNER, grepq, pass/fail/$failures,
# rst_tally, mk_rotate_sandbox, a sandboxed SUITE_LOCK_DIR / SUITE_ROTATE_STATE
# (plus the EXIT trap that cleans them), the neutralized ambient suite-control
# environment, and the red-control contract helper.
#
# It lives beside its consumers in scripts/ci/ rather than under scripts/lib/,
# this repo's shared-library directory, because it is consumed only by the ci
# self-tests for one runner — scripts/lib/ holds libraries the whole corpus
# reaches for. The name is not test-*.sh, so the runner never discovers it as
# a suite.
#
# Platform guard: no .ps1 twin, and none is wanted. This is not an entry point
# — it is sourced by the suites in its own directory, which are themselves
# bash-only and already run under Git Bash on Windows as well as Linux (see
# the Git-Bash measurements cited in run-shell-tests.sh's timeout table).
# Everything here is portable bash: mktemp, printf, grep, chmod, trap.

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this family's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone. (HIMMEL-1430.)
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

RST_FIXTURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$RST_FIXTURE_DIR/run-shell-tests.sh"

if [ ! -f "$RUNNER" ]; then
  echo "FAIL: runner not found at $RUNNER"
  exit 1
fi

# Point every invocation in the family at a throwaway lock (HIMMEL-1338).
# Without this, the cases would contend for the real machine-wide lock with any
# full-suite run happening elsewhere on the box and refuse with rc 2 — a red
# suite that says nothing about the behaviour under test. Lock ACQUISITION is
# covered on purpose in test-suite-concurrency.sh, against its own sandbox.
SUITE_LOCK_SANDBOX=$(mktemp -d)
export SUITE_LOCK_DIR="$SUITE_LOCK_SANDBOX/suite.lock"
# Same reasoning for the rotation cursor (HIMMEL-2243): no case in the family
# may write the real $HOME/.himmel cursor. Case 17 -- the three
# test-run-shell-tests-rotation*.sh suites -- overrides this per sub-case with
# its own cursor path to exercise rotation itself.
#
# Sharing ONE path across every case other than Case 17 is safe only because
# none of them ever truncates: SUITE_RUN_BUDGET is set nowhere outside Case
# 17, so the runner never reaches the write branch that would use this path.
# Any FUTURE case that sets a truncating budget must pass its own
# SUITE_ROTATE_STATE, exactly as every Case 17 sub-case does — otherwise it
# inherits this shared sandbox path and its cursor write collides with
# whatever else happens to share it.
export SUITE_ROTATE_STATE="$SUITE_LOCK_SANDBOX/rotate.cursor"
trap 'rm -rf "$SUITE_LOCK_SANDBOX"' EXIT

# HIMMEL-2599: neutralize the ambient suite-control environment for every
# nested $RUNNER invocation. CI's shell-unit job (.github/workflows/ci.yml)
# exports SUITE_TIER_MODE and SUITE_CHANGED_SINCE on every pull_request/push
# leg (HIMMEL-2166) so the OUTER run-shell-tests.sh call narrows its own plan --
# but the family's nested calls inherited them too, silently narrowing THEIR
# plans (SUITE_TIER_MODE=fast tier-skips, --changed-since-shaped filtering) and
# short-circuiting the very rotation/conditional-suite code paths under test.
# Some cases already neutralize SUITE_TIER_MODE per-call (`env -u
# SUITE_TIER_MODE`, HIMMEL-2120/2243) where they need it explicit and local;
# unsetting both here once, for every suite that sources this, closes the gap
# for every OTHER call site instead of requiring each new case to remember its
# own `env -u`. A case that wants to exercise these vars still sets them
# explicitly on its own invocation, which overrides an unset ambient value the
# same way it would override an inherited one.
unset SUITE_TIER_MODE SUITE_CHANGED_SINCE

# HIMMEL-2518/HIMMEL-2544: Case 18m-R's mutation control goes through the
# RED-control contract helper rather than a hand-rolled inequality — the helper
# asserts the mutant RAN, PRODUCED a value, and produced the SPECIFIC wrong
# value predicted, the three properties a `!=` check cannot establish.
# RED_CONTROL_TMPDIR keeps its stderr captures inside $SUITE_LOCK_SANDBOX, so
# the EXIT trap above already cleans them.
# shellcheck disable=SC2034  # read by red-control.sh, which the repo's lint
# runs shellcheck WITHOUT -x and therefore cannot see.
RED_CONTROL_TMPDIR="$SUITE_LOCK_SANDBOX"
# shellcheck source=../lib/red-control.sh
# shellcheck disable=SC1091
. "$RST_FIXTURE_DIR/../lib/red-control.sh"

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }

# rst_tally — the family's shared final tally. Every suite ends with it, so the
# six files report identically and a reader can diff their summaries.
rst_tally() {
  echo
  if [ "$failures" -eq 0 ]; then
    echo "OK: all cases passed"
    exit 0
  else
    echo "FAIL: $failures case(s) failed"
    exit 1
  fi
}

# mk_rotate_sandbox <dir> <order-log> — Case 17's shared fixture: six suites
# test-a.sh .. test-f.sh, each appending its own name to <order-log> as it
# runs, so a later assertion can read the ORDER the runner chose. test-a.sh
# sleeps 25s and the rest 1s; that gap is the whole point, because a
# SUITE_RUN_BUDGET below 25 truncates the run after the first suite and sends
# the runner down its cursor-writing branch.
#
# Every 17x sub-case drives this same sandbox, which is why each one costs
# 25-51s: test-a.sh's sleep is paid on every full run, so the eleven sub-cases
# were 327s of the original file's 382s (HIMMEL-2895 measurement). That is why
# they now live in three files -- test-run-shell-tests-rotation.sh (17a-17f),
# -rotation-guards.sh (17g-17j) and -rotation-cursor.sh (17k-17m) -- and why
# this builder is here rather than copied into each of them.
mk_rotate_sandbox() {
  local _d="$1" _order="$2" _c _dur
  : > "$_order"
  for _c in a b c d e f; do
    _dur=1
    [ "$_c" = "a" ] && _dur=25
    cat > "$_d/test-$_c.sh" <<SHEOF
#!/usr/bin/env bash
sleep $_dur
echo test-$_c.sh >> "$_order"
exit 0
SHEOF
    chmod +x "$_d/test-$_c.sh"
  done
}
