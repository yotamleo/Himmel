#!/usr/bin/env bash
# shellcheck disable=SC2016  # fixture suite bodies are single-quoted on purpose: their $vars must stay literal
# scripts/ci/test-run-shell-tests-flake.sh — the run-shell-tests.sh cases for
# the one-shot flake retry and the FLAKE ledger (HIMMEL-5116).
#
# A suite that fails is re-run ONCE, alone. Passing on the retry makes it a
# FLAKE: not PASS, not FAIL, a visible summary line, one jsonl row in the ledger
# (SUITE_FLAKE_LEDGER), and a loud "file a ticket" line when the same suite has
# already flaked inside SUITE_FLAKE_WINDOW_DAYS. A `# no-retry` suite header
# opts a suite out. Failing twice is FAIL; a retry never turns a real failure
# green.
#
#   F1  fail-then-pass                  -> FLAKE, ledger row, rc 0
#   F2  fail-then-fail                  -> FAIL, ran exactly twice, no ledger row
#   F3  `# no-retry` suite              -> never retried (ran once), FAIL
#   F4  second flake inside the window  -> the ticket line
#   F5  an old prior flake              -> no ticket line
#   F6  a flake beside a real failure   -> rc 1 (the flake does not mask FAIL)
#   F7  a suite killed at its cap       -> not retried
#   F8  a retry of a no-retry suite that would have passed stays FAIL
#
# Usage: bash scripts/ci/test-run-shell-tests-flake.sh
set -uo pipefail

# shellcheck source=run-shell-tests-fixture.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/run-shell-tests-fixture.sh"

# mk_flake_sandbox <dir> <flaky-header-extra> <fail-runs>
#   test-pass.sh   always passes
#   test-flaky.sh  fails its first <fail-runs> runs, then passes; counts runs in
#                  <dir>/scripts/flaky.count
mk_flake_sandbox() {
  local sb="$1" header="$2" fail_runs="$3"
  mkdir -p "$sb/scripts"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$sb/scripts/test-pass.sh"
  {
    printf '#!/usr/bin/env bash\n'
    [ -z "$header" ] || printf '%s\n' "$header"
    printf 'cnt="$(dirname "$0")/flaky.count"\n'
    printf 'n=$(cat "$cnt" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$cnt"\n'
    printf 'if [ "$n" -le %s ]; then echo "not ok 1 - flaky assertion"; exit 1; fi\n' "$fail_runs"
    printf 'exit 0\n'
  } > "$sb/scripts/test-flaky.sh"
  chmod +x "$sb/scripts/test-pass.sh" "$sb/scripts/test-flaky.sh"
}

# run_flake <dir> [env...]  -> sets out/rc; ledger is <dir>/ledger.jsonl
run_flake() {
  local sb="$1"; shift
  out=$(env -u SUITE_TIER_MODE SUITE_FLAKE_LEDGER="$sb/ledger.jsonl" "$@" bash "$RUNNER" "$sb/scripts" 2>&1); rc=$?
}
runs_of() { cat "$1/scripts/flaky.count" 2>/dev/null || echo 0; }
ledger_rows() { [ -f "$1/ledger.jsonl" ] && grep -c . "$1/ledger.jsonl" || echo 0; }

# --- F1 -------------------------------------------------------------------------
echo "== F1: fail then pass is a FLAKE =="
sb=$(mktemp -d "${TMPDIR:-/tmp}/rst-flake1.XXXXXX") || { fail "F1: mktemp failed"; sb=""; }
if [ -n "$sb" ]; then
mk_flake_sandbox "$sb" "" 1
run_flake "$sb" GITHUB_RUN_ID=424242
if [ "$rc" -eq 0 ] && [ "$(runs_of "$sb")" = 2 ] && grepq "$out" -F '[FLAKE]' \
    && grepq "$out" -E '^ FLAKE: 1' && grepq "$out" -E '^ PASS: 1' && grepq "$out" -E '^ FAIL: 0' \
    && ! grepq "$out" -F 'file a ticket'; then
  pass "F1: retried once, reported FLAKE (not PASS, not FAIL), exit 0, no ticket line on a first flake"
else
  fail "F1: rc=$rc runs=$(runs_of "$sb") out: $out"
fi
if [ "$(ledger_rows "$sb")" = 1 ] && grepq "$(cat "$sb/ledger.jsonl")" -F '"suite":"test-flaky.sh"' \
    && grepq "$(cat "$sb/ledger.jsonl")" -F '"run":"424242"' \
    && grepq "$(cat "$sb/ledger.jsonl")" -E '"ts":[0-9]+' \
    && grepq "$(cat "$sb/ledger.jsonl")" -F 'flaky assertion'; then
  pass "F1: one ledger row: suite, run id, ts, failing case line"
else
  fail "F1: ledger: $(cat "$sb/ledger.jsonl" 2>&1)"
fi
rm -rf "$sb"
fi

# --- F2 -------------------------------------------------------------------------
echo "== F2: fail then fail is FAIL =="
sb=$(mktemp -d "${TMPDIR:-/tmp}/rst-flake2.XXXXXX") || { fail "F2: mktemp failed"; sb=""; }
if [ -n "$sb" ]; then
mk_flake_sandbox "$sb" "" 99
run_flake "$sb"
if [ "$rc" -eq 1 ] && [ "$(runs_of "$sb")" = 2 ] && grepq "$out" -E '^ FAIL: 1' \
    && ! grepq "$out" -E '^ FLAKE:' && [ "$(ledger_rows "$sb")" = 0 ]; then
  pass "F2: a deterministic failure ran exactly twice and still FAILs, no ledger row"
else
  fail "F2: rc=$rc runs=$(runs_of "$sb") rows=$(ledger_rows "$sb") out: $out"
fi
rm -rf "$sb"
fi

# --- F3 / F8 ----------------------------------------------------------------------
echo "== F3: a # no-retry suite is never retried =="
sb=$(mktemp -d "${TMPDIR:-/tmp}/rst-flake3.XXXXXX") || { fail "F3: mktemp failed"; sb=""; }
if [ -n "$sb" ]; then
mk_flake_sandbox "$sb" "# no-retry: guards a real race" 1
run_flake "$sb"
if [ "$rc" -eq 1 ] && [ "$(runs_of "$sb")" = 1 ] && grepq "$out" -E '^ FAIL: 1' \
    && ! grepq "$out" -F '[FLAKE]' && [ "$(ledger_rows "$sb")" = 0 ]; then
  pass "F3/F8: no-retry suite ran once, stayed FAIL even though a retry would have passed"
else
  fail "F3: rc=$rc runs=$(runs_of "$sb") out: $out"
fi
rm -rf "$sb"
fi

# --- F4 / F5 ----------------------------------------------------------------------
echo "== F4: a second flake inside the window prints the ticket line =="
sb=$(mktemp -d "${TMPDIR:-/tmp}/rst-flake4.XXXXXX") || { fail "F4: mktemp failed"; sb=""; }
if [ -n "$sb" ]; then
mk_flake_sandbox "$sb" "" 1
now=$(date +%s)
printf '{"suite":"test-flaky.sh","case":"","sha":"x","run":"","ts":%s}\n' "$((now - 3600))" > "$sb/ledger.jsonl"
run_flake "$sb"
if [ "$rc" -eq 0 ] && grepq "$out" -F 'file a ticket' && grepq "$out" -F 'test-flaky.sh' \
    && [ "$(ledger_rows "$sb")" = 2 ]; then
  pass "F4: prior flake an hour ago -> loud 'file a ticket' line, row appended, exit 0"
else
  fail "F4: rc=$rc rows=$(ledger_rows "$sb") out: $out"
fi
rm -rf "$sb"
fi
echo "== F5: an old prior flake is outside the window =="
sb=$(mktemp -d "${TMPDIR:-/tmp}/rst-flake5.XXXXXX") || { fail "F5: mktemp failed"; sb=""; }
if [ -n "$sb" ]; then
mk_flake_sandbox "$sb" "" 1
now=$(date +%s)
printf '{"suite":"test-flaky.sh","case":"","sha":"x","run":"","ts":%s}\n' "$((now - 30 * 86400))" > "$sb/ledger.jsonl"
printf '{"suite":"test-other.sh","case":"","sha":"x","run":"","ts":%s}\n' "$((now - 60))" >> "$sb/ledger.jsonl"
run_flake "$sb"
if [ "$rc" -eq 0 ] && grepq "$out" -F '[FLAKE]' && ! grepq "$out" -F 'file a ticket'; then
  pass "F5: a 30-day-old row and another suite's row do not count"
else
  fail "F5: rc=$rc out: $out"
fi
rm -rf "$sb"
fi

# --- F6 -------------------------------------------------------------------------
echo "== F6: a flake beside a real failure keeps the run red =="
sb=$(mktemp -d "${TMPDIR:-/tmp}/rst-flake6.XXXXXX") || { fail "F6: mktemp failed"; sb=""; }
if [ -n "$sb" ]; then
mk_flake_sandbox "$sb" "" 1
printf '#!/usr/bin/env bash\nexit 1\n' > "$sb/scripts/test-red.sh"
chmod +x "$sb/scripts/test-red.sh"
run_flake "$sb"
if [ "$rc" -eq 1 ] && grepq "$out" -E '^ FAIL: 1' && grepq "$out" -E '^ FLAKE: 1' \
    && grepq "$out" -F 'test-red.sh (rc=1)'; then
  pass "F6: exit 1, FAIL: 1 and FLAKE: 1 reported separately"
else
  fail "F6: rc=$rc out: $out"
fi
rm -rf "$sb"
fi

# --- F7 -------------------------------------------------------------------------
echo "== F7: a suite killed at its cap is not retried =="
sb=$(mktemp -d "${TMPDIR:-/tmp}/rst-flake7.XXXXXX") || { fail "F7: mktemp failed"; sb=""; }
if [ -n "$sb" ]; then
mkdir -p "$sb/scripts"
printf '#!/usr/bin/env bash\ncnt="$(dirname "$0")/slow.count"\nn=$(cat "$cnt" 2>/dev/null || echo 0); echo $((n + 1)) > "$cnt"\nsleep 30\n' > "$sb/scripts/test-slow.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$sb/scripts/test-pass.sh"
chmod +x "$sb/scripts/test-slow.sh" "$sb/scripts/test-pass.sh"
run_flake "$sb" SUITE_TIMEOUT=2
if [ "$rc" -eq 1 ] && [ "$(cat "$sb/scripts/slow.count" 2>/dev/null || echo 0)" = 1 ] && grepq "$out" -F 'CAP EXCEEDED'; then
  pass "F7: a capped suite ran once and renders CAP EXCEEDED"
else
  fail "F7: rc=$rc runs=$(cat "$sb/scripts/slow.count" 2>&1) out: $out"
fi
rm -rf "$sb"
fi

rst_tally
