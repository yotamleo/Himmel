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
#   F9  a leading-zero SUITE_FLAKE_WINDOW_DAYS reads as decimal
#   F10 a flake is a ::warning and a step-summary section on CI
#   F11 a retry that only prints SKIP and exits 0 stays FAIL
#   F12 an unwritable ledger WARNs, verdict unchanged
#   F13 a prior flake of the same suite name from another repo, or an old row
#       with no repo id, never raises the ticket line (HIMMEL-5121)
#   F14 a suite that fails both attempts keeps BOTH logs under FAIL_LOG_DIR
#   F15 a repo id override with a backslash or quote is reduced to a safe
#       charset and still matches its own rows
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
  out=$(env -u SUITE_TIER_MODE SUITE_FLAKE_REPO_ID=repo-a SUITE_FLAKE_LEDGER="$sb/ledger.jsonl" "$@" bash "$RUNNER" "$sb/scripts" 2>&1); rc=$?
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
# The ledgers.json registry (HIMMEL-4290) requires the v/ts/host/source/kind envelope.
row=$(cat "$sb/ledger.jsonl" 2>/dev/null)
if grepq "$row" -F '"v":1' && grepq "$row" -E '"host":"[^"]+"' \
    && grepq "$row" -F '"source":"run-shell-tests"' && grepq "$row" -F '"kind":"flake"'; then
  pass "F1: the row carries the registry envelope (v, host, source, kind)"
else
  fail "F1: envelope missing from row: $row"
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
printf '{"suite":"test-flaky.sh","repo":"repo-a","case":"","sha":"x","run":"","ts":%s}\n' "$((now - 3600))" > "$sb/ledger.jsonl"
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
printf '{"suite":"test-flaky.sh","repo":"repo-a","case":"","sha":"x","run":"","ts":%s}\n' "$((now - 30 * 86400))" > "$sb/ledger.jsonl"
printf '{"suite":"test-other.sh","repo":"repo-a","case":"","sha":"x","run":"","ts":%s}\n' "$((now - 60))" >> "$sb/ledger.jsonl"
run_flake "$sb"
if [ "$rc" -eq 0 ] && grepq "$out" -F '[FLAKE]' && ! grepq "$out" -F 'file a ticket'; then
  pass "F5: a 30-day-old row and another suite's row do not count"
else
  fail "F5: rc=$rc out: $out"
fi
rm -rf "$sb"
fi

# --- F9 -------------------------------------------------------------------------
echo "== F9: a leading-zero window (08) is decimal, not an octal error =="
sb=$(mktemp -d "${TMPDIR:-/tmp}/rst-flake9.XXXXXX") || { fail "F9: mktemp failed"; sb=""; }
if [ -n "$sb" ]; then
mk_flake_sandbox "$sb" "" 1
now=$(date +%s)
printf '{"suite":"test-flaky.sh","repo":"repo-a","case":"","sha":"x","run":"","ts":%s}\n' "$((now - 3600))" > "$sb/ledger.jsonl"
run_flake "$sb" SUITE_FLAKE_WINDOW_DAYS=08
if [ "$rc" -eq 0 ] && grepq "$out" -F 'file a ticket' && ! grepq "$out" -iE 'value too great|syntax error' \
    && [ "$(ledger_rows "$sb")" = 2 ]; then
  pass "F9: SUITE_FLAKE_WINDOW_DAYS=08 reads as 8 days, ticket line printed, row appended"
else
  fail "F9: rc=$rc rows=$(ledger_rows "$sb") out: $out"
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

# --- F10 ------------------------------------------------------------------------
echo "== F10: a flake is visible on a green CI run (HIMMEL-5116 delta) =="
sb=$(mktemp -d "${TMPDIR:-/tmp}/rst-flake10.XXXXXX") || { fail "F10: mktemp failed"; sb=""; }
if [ -n "$sb" ]; then
mk_flake_sandbox "$sb" "" 1
run_flake "$sb" GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY="$sb/summary.md"
if [ "$rc" -eq 0 ] && grepq "$out" -F '::warning title=FLAKE::test-flaky.sh' \
    && grepq "$(cat "$sb/summary.md" 2>/dev/null)" -F 'FLAKE' \
    && grepq "$(cat "$sb/summary.md" 2>/dev/null)" -F 'test-flaky.sh'; then
  pass "F10: ::warning title=FLAKE:: emitted and a FLAKE section appended to GITHUB_STEP_SUMMARY, rc 0"
else
  fail "F10: rc=$rc summary=$(cat "$sb/summary.md" 2>&1) out: $out"
fi
rm -rf "$sb"
fi
sb=$(mktemp -d "${TMPDIR:-/tmp}/rst-flake10b.XXXXXX") || { fail "F10b: mktemp failed"; sb=""; }
if [ -n "$sb" ]; then
mk_flake_sandbox "$sb" "" 1
run_flake "$sb" GITHUB_ACTIONS=false
if [ "$rc" -eq 0 ] && grepq "$out" -F '[FLAKE]' && ! grepq "$out" -F '::warning'; then
  pass "F10b: no workflow command outside GitHub Actions"
else
  fail "F10b: rc=$rc out: $out"
fi
rm -rf "$sb"
fi

# --- F11 ------------------------------------------------------------------------
echo "== F11: a retry that only prints SKIP and exits 0 stays FAIL =="
sb=$(mktemp -d "${TMPDIR:-/tmp}/rst-flake11.XXXXXX") || { fail "F11: mktemp failed"; sb=""; }
if [ -n "$sb" ]; then
mkdir -p "$sb/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$sb/scripts/test-pass.sh"
{
  printf '#!/usr/bin/env bash\n'
  printf 'cnt="$(dirname "$0")/skippy.count"\n'
  printf 'n=$(cat "$cnt" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$cnt"\n'
  printf 'if [ "$n" -le 1 ]; then echo "not ok 1 - real failure"; exit 1; fi\n'
  printf 'echo "SKIP: tool missing"\nexit 0\n'
} > "$sb/scripts/test-skippy.sh"
chmod +x "$sb/scripts/test-pass.sh" "$sb/scripts/test-skippy.sh"
run_flake "$sb"
if [ "$rc" -eq 1 ] && grepq "$out" -E '^ FAIL: 1' && ! grepq "$out" -E '^ FLAKE:' \
    && ! grepq "$out" -F '[FLAKE]' && [ "$(ledger_rows "$sb")" = 0 ]; then
  pass "F11: a SKIP-and-exit-0 retry renders FAIL, no FLAKE, no ledger row"
else
  fail "F11: rc=$rc rows=$(ledger_rows "$sb") out: $out"
fi
rm -rf "$sb"
fi

# --- F12 ------------------------------------------------------------------------
echo "== F12: an unwritable ledger path WARNs and leaves the verdict alone =="
sb=$(mktemp -d "${TMPDIR:-/tmp}/rst-flake12.XXXXXX") || { fail "F12: mktemp failed"; sb=""; }
if [ -n "$sb" ]; then
mk_flake_sandbox "$sb" "" 1
: > "$sb/blocker"
run_flake "$sb" SUITE_FLAKE_LEDGER="$sb/blocker/ledger.jsonl"
if [ "$rc" -eq 0 ] && grepq "$out" -F '[FLAKE]' && grepq "$out" -E '^ FLAKE: 1' \
    && grepq "$out" -F 'could not append the flake ledger row'; then
  pass "F12: WARN printed, still a FLAKE, rc 0"
else
  fail "F12: rc=$rc out: $out"
fi
rm -rf "$sb"
fi

# --- F13 ------------------------------------------------------------------------
echo "== F13: another repo's (or a repo-less old) row never raises the ticket line =="
sb=$(mktemp -d "${TMPDIR:-/tmp}/rst-flake13.XXXXXX") || { fail "F13: mktemp failed"; sb=""; }
if [ -n "$sb" ]; then
mk_flake_sandbox "$sb" "" 1
now=$(date +%s)
printf '{"suite":"test-flaky.sh","repo":"repo-b","case":"","sha":"x","run":"","ts":%s}\n' "$((now - 3600))" > "$sb/ledger.jsonl"
printf '{"suite":"test-flaky.sh","case":"","sha":"x","run":"","ts":%s}\n' "$((now - 3600))" >> "$sb/ledger.jsonl"
run_flake "$sb"
if [ "$rc" -eq 0 ] && grepq "$out" -F '[FLAKE]' && ! grepq "$out" -F 'file a ticket' \
    && grepq "$(tail -n 1 "$sb/ledger.jsonl")" -F '"repo":"repo-a"'; then
  pass "F13: repo-b and repo-less rows do not count; the new row records its repo id"
else
  fail "F13: rc=$rc out: $out ledger: $(cat "$sb/ledger.jsonl" 2>&1)"
fi
rm -rf "$sb"
fi

# --- F14 ------------------------------------------------------------------------
echo "== F14: a suite that fails twice keeps both attempt logs =="
sb=$(mktemp -d "${TMPDIR:-/tmp}/rst-flake14.XXXXXX") || { fail "F14: mktemp failed"; sb=""; }
if [ -n "$sb" ]; then
mkdir -p "$sb/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$sb/scripts/test-pass.sh"
{
  printf '#!/usr/bin/env bash\n'
  printf 'cnt="$(dirname "$0")/twice.count"\n'
  printf 'n=$(cat "$cnt" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$cnt"\n'
  printf 'echo "not ok 1 - distinct failure of attempt $n"; exit 1\n'
} > "$sb/scripts/test-twice.sh"
chmod +x "$sb/scripts/test-pass.sh" "$sb/scripts/test-twice.sh"
run_flake "$sb" FAIL_LOG_DIR="$sb/logs"
logs=$(cat "$sb"/logs/*test-twice* 2>/dev/null)
if [ "$rc" -eq 1 ] && grepq "$logs" -F 'distinct failure of attempt 1' \
    && grepq "$logs" -F 'distinct failure of attempt 2'; then
  pass "F14: both attempts' logs are preserved under FAIL_LOG_DIR"
else
  fail "F14: rc=$rc logs: $(ls "$sb/logs" 2>&1) :: $logs"
fi
rm -rf "$sb"
fi

# --- F15 ------------------------------------------------------------------------
echo "== F15: a repo id override with a backslash or quote still matches its own rows =="
sb=$(mktemp -d "${TMPDIR:-/tmp}/rst-flake15.XXXXXX") || { fail "F15: mktemp failed"; sb=""; }
if [ -n "$sb" ]; then
mk_flake_sandbox "$sb" "" 1
now=$(date +%s)
printf '{"suite":"test-flaky.sh","repo":"a_b_c","case":"","sha":"x","run":"","ts":%s}\n' "$((now - 3600))" > "$sb/ledger.jsonl"
run_flake "$sb" SUITE_FLAKE_REPO_ID='a\b"c'
if [ "$rc" -eq 0 ] && grepq "$out" -F '[FLAKE]' && grepq "$out" -F 'file a ticket'; then
  pass "F15: the override is reduced to a safe charset, so the repeat check matches"
else
  fail "F15: rc=$rc out: $out ledger: $(cat "$sb/ledger.jsonl" 2>&1)"
fi
rm -rf "$sb"
fi

# --- F16 ------------------------------------------------------------------------
# The default repo id is computed by _flake_repo_id; the runner cannot be pointed
# at a fixture repo (it always means its own checkout), so the two functions are
# lifted out of it and run against throwaway repos.
echo "== F16: one repo is one id across URL spellings and worktrees =="
sb=$(mktemp -d "${TMPDIR:-/tmp}/rst-flake16.XXXXXX") || { fail "F16: mktemp failed"; sb=""; }
if [ -n "$sb" ]; then
fns=$(sed -n '/^_flake_norm_url() {/,/^}/p;/^_flake_repo_id() {/,/^}/p' "$RUNNER")
# shellcheck disable=SC1090
eval "$fns"
# The runner drops these before any git call; a direct run of this suite (a hook
# or wrapper that exported them) must not point the fixtures at another repo.
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES
gq() { git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
mk_url_repo() { # <dir> <origin-url>
  mkdir -p "$1" && git -C "$1" init -q && git -C "$1" remote add origin "$2"
}
mk_url_repo "$sb/u1" "https://GitHub.com/o/r.git"
mk_url_repo "$sb/u2" "https://github.com/o/r"
mk_url_repo "$sb/u3" "git@github.com:o/r.git"
mk_url_repo "$sb/u4" "ssh://git@github.com/o/r.git"
mk_url_repo "$sb/u5" "https://tok@github.com/o/r/"
mk_url_repo "$sb/u6" "https://github.com/o/other.git"
i1=$(_flake_repo_id "$sb/u1" 2>&1); i2=$(_flake_repo_id "$sb/u2" 2>&1)
i3=$(_flake_repo_id "$sb/u3" 2>&1); i4=$(_flake_repo_id "$sb/u4" 2>&1)
i5=$(_flake_repo_id "$sb/u5" 2>&1); i6=$(_flake_repo_id "$sb/u6" 2>&1)
if [ -n "$i1" ] && [ "$i1" = "$i2" ] && [ "$i1" = "$i3" ] && [ "$i1" = "$i4" ] && [ "$i1" = "$i5" ] \
    && [ "$i1" != "$i6" ]; then
  pass "F16: https, https+.git, scp, ssh and credentialed spellings agree; another repo differs"
else
  fail "F16: ids: [$i1] [$i2] [$i3] [$i4] [$i5] vs other [$i6]"
fi
case "$i1" in *github*|*tok*) fail "F16: the id leaks the URL: $i1" ;; esac
mkdir -p "$sb/n1" "$sb/n2" && git -C "$sb/n1" init -q && git -C "$sb/n2" init -q
gq -C "$sb/n1" commit -q --allow-empty -m x
git -C "$sb/n1" worktree add -q "$sb/n1-wt" -b wt 2>/dev/null
d1=$(_flake_repo_id "$sb/n1" 2>&1); d2=$(_flake_repo_id "$sb/n1-wt" 2>&1); d3=$(_flake_repo_id "$sb/n2" 2>&1)
if [ -n "$d1" ] && [ "$d1" = "$d2" ] && [ "$d1" != "$d3" ]; then
  pass "F16: a no-origin repo and its worktree share an id; another no-origin repo differs"
else
  fail "F16: no-origin ids: main [$d1] worktree [$d2] other [$d3]"
fi
rm -rf "$sb"
fi

rst_tally
