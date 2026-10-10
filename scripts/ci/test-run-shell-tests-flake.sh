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
#   F16 one repo is one id across URL spellings and worktrees; a relative or
#       local-path origin stays case-exact and keeps its .git, a default port
#       drops (HIMMEL-5144, HIMMEL-5145); an absolute local origin is
#       lexically normalised, a file:// path is percent-decoded and its scheme
#       is case-insensitive, file://host/... is never joined under the
#       checkout (HIMMEL-5157)
#   F17 with no override, the row's repo is the shared lib's id for the
#       runner's own checkout (HIMMEL-5147)
#   F18 a runner that cannot read the id lib writes no ledger row, names the
#       lib and prints no unbound-variable line (HIMMEL-5156, HIMMEL-5157)
#   F19 neither caller defines the id functions itself (HIMMEL-5156)
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
# The default repo id is computed by _flake_repo_id (scripts/lib/flake-repo-id.sh,
# shared with the reader); the runner cannot be pointed at a fixture repo (it
# always means its own checkout), so the lib is sourced here and run against
# throwaway repos.
echo "== F16: one repo is one id across URL spellings and worktrees =="
sb=$(mktemp -d "${TMPDIR:-/tmp}/rst-flake16.XXXXXX") || { fail "F16: mktemp failed"; sb=""; }
if [ -n "$sb" ]; then
RUNNER_ROOT=$(cd "$(dirname "$RUNNER")/../.." && pwd)
# shellcheck source=scripts/lib/flake-repo-id.sh
. "$RUNNER_ROOT/scripts/lib/flake-repo-id.sh"
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
# HIMMEL-5145: a plain relative or absolute path origin keeps its case and its
# .git (two distinct dirs on a case-sensitive fs); a default port drops, others stay.
mk_url_repo "$sb/p1" "Repo/project";  mk_url_repo "$sb/p2" "repo/project"
mk_url_repo "$sb/p3" "/srv/r";        mk_url_repo "$sb/p4" "/srv/r.git"
mk_url_repo "$sb/p5" "/srv/r/"
mk_url_repo "$sb/q1" "ssh://git@github.com:22/o/r.git"
mk_url_repo "$sb/q2" "https://GitHub.com:443/o/r"
mk_url_repo "$sb/q3" "http://github.com:80/o/r.git"
mk_url_repo "$sb/q4" "http://github.com/o/r"
mk_url_repo "$sb/q5" "ssh://git@github.com:2222/o/r.git"
mk_url_repo "$sb/q6" "https://github.com:22/o/r"
# A relative origin is resolved against the checkout (HIMMEL-5156), so the case
# row compares the normaliser's output for one shared base, not two directories.
p1=$(_flake_norm_url "Repo/project" "$sb" 2>&1); p2=$(_flake_norm_url "repo/project" "$sb" 2>&1)
p3=$(_flake_repo_id "$sb/p3" 2>&1); p4=$(_flake_repo_id "$sb/p4" 2>&1); p5=$(_flake_repo_id "$sb/p5" 2>&1)
if [ -n "$p1" ] && [ "$p1" != "$p2" ]; then
  pass "F16: Repo/project and repo/project are distinct ids"
else
  fail "F16: relative origins case-folded: [$p1] [$p2]"
fi
if [ -n "$p3" ] && [ "$p3" != "$p4" ] && [ "$p3" = "$p5" ]; then
  pass "F16: /srv/r and /srv/r.git are distinct ids; a trailing slash does not matter"
else
  fail "F16: local path ids: /srv/r [$p3] /srv/r.git [$p4] /srv/r/ [$p5]"
fi
# HIMMEL-5156: file:// is a local path, not a network URL, so file:///srv/r.git
# is the /srv/r.git directory (not /srv/r), and a relative origin is resolved
# against the main checkout, so one repo's worktrees share an id and the same
# relative text from two parents does not.
mk_url_repo "$sb/f1" "file:///srv/r.git"
mk_url_repo "$sb/f2" "file:///srv/r"
f1=$(_flake_repo_id "$sb/f1" 2>&1); f2=$(_flake_repo_id "$sb/f2" 2>&1)
if [ -n "$f1" ] && [ "$f1" != "$p3" ] && [ "$f1" = "$p4" ] && [ "$f2" = "$p3" ]; then
  pass "F16: file:///srv/r.git is the /srv/r.git directory, distinct from /srv/r"
else
  fail "F16: file:// ids: file:///srv/r.git [$f1] /srv/r [$p3] /srv/r.git [$p4] file:///srv/r [$f2]"
fi
# HIMMEL-5157: an absolute local origin is lexically normalised like a relative
# one, a file:// path is percent-decoded and its scheme is case-insensitive, and
# file://host/path is a host form that is never joined under the checkout.
mk_url_repo "$sb/a1" "/srv/x/../r.git"
mk_url_repo "$sb/a2" "/srv/./r.git"
mk_url_repo "$sb/a3" "/srv//r.git"
a1=$(_flake_repo_id "$sb/a1" 2>&1); a2=$(_flake_repo_id "$sb/a2" 2>&1); a3=$(_flake_repo_id "$sb/a3" 2>&1)
if [ -n "$a1" ] && [ "$a1" = "$p4" ] && [ "$a2" = "$p4" ] && [ "$a3" = "$p4" ]; then
  pass "F16: /srv/x/../r.git, /srv/./r.git and /srv//r.git are /srv/r.git"
else
  fail "F16: absolute origin ids: a1 [$a1] a2 [$a2] a3 [$a3] vs /srv/r.git [$p4]"
fi
mk_url_repo "$sb/d1" "file:///srv/my%20repo.git"
mk_url_repo "$sb/d2" "/srv/my repo.git"
mk_url_repo "$sb/d3" "FILE:///srv/r.git"
mk_url_repo "$sb/d4" "FILE:///srv/r"
mk_url_repo "$sb/d5" "file:///srv/my%2520repo.git"
mk_url_repo "$sb/d6" "/srv/my%20repo.git"
dd1=$(_flake_repo_id "$sb/d1" 2>&1); dd2=$(_flake_repo_id "$sb/d2" 2>&1); dd3=$(_flake_repo_id "$sb/d3" 2>&1)
dd4=$(_flake_repo_id "$sb/d4" 2>&1); dd5=$(_flake_repo_id "$sb/d5" 2>&1); dd6=$(_flake_repo_id "$sb/d6" 2>&1)
if [ -n "$dd1" ] && [ "$dd1" = "$dd2" ]; then
  pass "F16: file:///srv/my%20repo.git is /srv/my repo.git"
else
  fail "F16: percent-decoding: file:// [$dd1] vs plain path [$dd2]"
fi
if [ "$dd5" != "$dd1" ] && [ "$dd6" != "$dd2" ] && [ "$dd5" = "$dd6" ]; then
  pass "F16: a decoded path is not decoded twice, and a plain path is never decoded"
else
  fail "F16: decode scope: %2520 [$dd5] vs %20 plain [$dd6] vs decoded [$dd1]"
fi
if [ -n "$dd3" ] && [ "$dd3" = "$p4" ] && [ "$dd4" = "$p3" ] && [ "$dd3" != "$dd4" ]; then
  pass "F16: FILE:// is file:// and still distinct from the no-.git path"
else
  fail "F16: scheme case: FILE:///srv/r.git [$dd3] want [$p4]; FILE:///srv/r [$dd4] want [$p3]"
fi
mk_url_repo "$sb/h1" "file://host/r.git"
mk_url_repo "$sb/h2" "file://HOST/r.git"
mk_url_repo "$sb/h3" "host/r.git"
mk_url_repo "$sb/h4" "file://localhost/srv/r.git"
mk_url_repo "$sb/h5" "file://localhostx/srv/r.git"
h1=$(_flake_repo_id "$sb/h1" 2>&1); h2=$(_flake_repo_id "$sb/h2" 2>&1); h3=$(_flake_repo_id "$sb/h3" 2>&1)
h4=$(_flake_repo_id "$sb/h4" 2>&1); h5=$(_flake_repo_id "$sb/h5" 2>&1)
if [ -n "$h1" ] && [ "$h1" = "$h2" ] && [ "$h1" != "$h3" ] && [ "$h1" != "$p4" ]; then
  pass "F16: file://host/r.git is a host form, not the checkout-relative host/r.git"
else
  fail "F16: file://host ids: host [$h1] HOST [$h2] relative host/r.git [$h3] /srv/r.git [$p4]"
fi
if [ "$h4" = "$p4" ] && [ "$h5" != "$p4" ]; then
  pass "F16: file://localhost/... is the local path; localhostx is another host"
else
  fail "F16: localhost: [$h4] want [$p4]; localhostx [$h5] must differ"
fi
# HIMMEL-5161: a decoded trailing newline is part of the path, so
# file:///srv/r%0A is a different directory from file:///srv/r (command
# substitution would strip it); %00 stays escaped, so it is not /srv/r either;
# the localhost host is case-insensitive; file://host/r.git is not /host/r.git.
mk_url_repo "$sb/n1" "file:///srv/r%0A"
mk_url_repo "$sb/n2" "file:///srv/r%0A%0A"
mk_url_repo "$sb/n3" "file:///srv/r%00"
mk_url_repo "$sb/n4" "file://LOCALHOST/srv/r.git"
mk_url_repo "$sb/n5" "/host/r.git"
n1=$(_flake_repo_id "$sb/n1" 2>&1); n2=$(_flake_repo_id "$sb/n2" 2>&1); n3=$(_flake_repo_id "$sb/n3" 2>&1)
n4=$(_flake_repo_id "$sb/n4" 2>&1); n5=$(_flake_repo_id "$sb/n5" 2>&1)
if [ -n "$n1" ] && [ "$n1" != "$f2" ] && [ "$n1" != "$n2" ] && [ "$n2" != "$f2" ]; then
  pass "F16: file:///srv/r%0A and %0A%0A are distinct from file:///srv/r and each other"
else
  fail "F16: trailing newline: %0A [$n1] %0A%0A [$n2] vs file:///srv/r [$f2]"
fi
if [ -n "$n3" ] && [ "$n3" != "$f2" ]; then
  pass "F16: file:///srv/r%00 stays escaped and is distinct from /srv/r"
else
  fail "F16: %00: [$n3] vs file:///srv/r [$f2]"
fi
if [ "$n4" = "$p4" ] && [ "$h1" != "$n5" ]; then
  pass "F16: file://LOCALHOST/... is the local path; file://host/r.git is not /host/r.git"
else
  fail "F16: LOCALHOST [$n4] want [$p4]; host form [$h1] vs /host/r.git [$n5] must differ"
fi
mk_url_repo "$sb/ra/co" "../r.git"; mk_url_repo "$sb/rb/co" "../r.git"
gq -C "$sb/ra/co" commit -q --allow-empty -m x
# The worktree sits under a parent other than the checkout's, so a lib that
# resolved the relative origin against the worktree would give another id (HIMMEL-5157).
mkdir -p "$sb/rw"
git -C "$sb/ra/co" worktree add -q "$sb/rw/co-wt" -b rwt 2>/dev/null
r1=$(_flake_repo_id "$sb/ra/co" 2>&1); r2=$(_flake_repo_id "$sb/rb/co" 2>&1); r3=$(_flake_repo_id "$sb/rw/co-wt" 2>&1)
if [ -n "$r1" ] && [ "$r1" != "$r2" ] && [ "$r1" = "$r3" ]; then
  pass "F16: ../r.git from two parents is two ids; a worktree shares its checkout's id"
else
  fail "F16: relative origin ids: parent a [$r1] parent b [$r2] a's worktree [$r3]"
fi
# --separate-git-dir: the common dir is not the checkout, so a relative origin
# resolves against the checkout (the first worktree), never the git dir.
mkdir -p "$sb/rs" "$sb/rt" "$sb/gd"
git init -q --separate-git-dir "$sb/gd/s.git" "$sb/rs/co" 2>/dev/null
git init -q --separate-git-dir "$sb/gd/t.git" "$sb/rt/co" 2>/dev/null
git -C "$sb/rs/co" remote add origin ../r.git; git -C "$sb/rt/co" remote add origin ../r.git
s1=$(_flake_repo_id "$sb/rs/co" 2>&1); s2=$(_flake_repo_id "$sb/rt/co" 2>&1)
case "$s1:$s2" in
  origin-*:origin-*) s_ok=1 ;;
  *) s_ok=0 ;;
esac
if [ "$s_ok" = 1 ] && [ "$s1" != "$s2" ]; then
  pass "F16: --separate-git-dir checkouts with ../r.git from two parents are two ids"
else
  fail "F16: separate-git-dir relative origin ids collide: [$s1] [$s2]"
fi
q1=$(_flake_repo_id "$sb/q1" 2>&1); q2=$(_flake_repo_id "$sb/q2" 2>&1); q3=$(_flake_repo_id "$sb/q3" 2>&1)
q4=$(_flake_repo_id "$sb/q4" 2>&1); q5=$(_flake_repo_id "$sb/q5" 2>&1); q6=$(_flake_repo_id "$sb/q6" 2>&1)
if [ "$q1" = "$i3" ] && [ "$q2" = "$i2" ] && [ "$q3" = "$q4" ]; then
  pass "F16: ssh :22, https :443 and http :80 equal the portless spelling"
else
  fail "F16: default ports kept: q1 [$q1] vs scp [$i3]; q2 [$q2] vs https [$i2]; q3 [$q3] vs q4 [$q4]"
fi
if [ "$q5" != "$i3" ] && [ "$q6" != "$i2" ]; then
  pass "F16: a non-default port, or another scheme's default, stays in the id"
else
  fail "F16: non-default port dropped: q5 [$q5] q6 [$q6]"
fi
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

# --- F17 ------------------------------------------------------------------------
# Runner level, no SUITE_FLAKE_REPO_ID override: the row's repo is the lib's id
# for the runner's own checkout, so a runner that hard-codes an id (or stops
# sourcing the lib) fails here.
echo "== F17: the runner's default repo id is the lib's id for its own checkout =="
sb=$(mktemp -d "${TMPDIR:-/tmp}/rst-flake17.XXXXXX") || { fail "F17: mktemp failed"; sb=""; }
if [ -n "$sb" ]; then
mk_flake_sandbox "$sb" "" 1
want=$(_flake_repo_id "$RUNNER_ROOT")
out=$(env -u SUITE_TIER_MODE -u SUITE_FLAKE_REPO_ID SUITE_FLAKE_LEDGER="$sb/ledger.jsonl" bash "$RUNNER" "$sb/scripts" 2>&1); rc=$?
got=$(grep -o '"repo":"[^"]*"' "$sb/ledger.jsonl" 2>/dev/null | head -n 1)
if [ "$rc" -eq 0 ] && [ -n "$want" ] && [ "$got" = "\"repo\":\"$want\"" ]; then
  pass "F17: the ledger row carries the lib's id for the runner's checkout"
else
  fail "F17: rc=$rc want [$want] got [$got] out: $out"
fi
rm -rf "$sb"
fi

# --- F18 ------------------------------------------------------------------------
# HIMMEL-5156: a runner that cannot read the id lib fails closed — it writes no
# ledger row (never "repo":""), names the lib, and the run's verdict is unchanged.
echo "== F18: a missing id lib writes no ledger row =="
sb=$(mktemp -d "${TMPDIR:-/tmp}/rst-flake18.XXXXXX") || { fail "F18: mktemp failed"; sb=""; }
if [ -n "$sb" ]; then
mkdir -p "$sb/co/scripts/ci" "$sb/suites"
cp "$RUNNER" "$sb/co/scripts/ci/run-shell-tests.sh"
cp -R "$RUNNER_ROOT/scripts/lib" "$sb/co/scripts/lib"; rm -f "$sb/co/scripts/lib/flake-repo-id.sh"
mk_flake_sandbox "$sb" "" 1
mv "$sb/scripts/test-pass.sh" "$sb/scripts/test-flaky.sh" "$sb/suites/"
out=$(cd "$sb" && env -u SUITE_TIER_MODE -u SUITE_FLAKE_REPO_ID SUITE_FLAKE_LEDGER="$sb/ledger.jsonl" bash "$sb/co/scripts/ci/run-shell-tests.sh" "$sb/suites" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && grepq "$out" -E '^ FLAKE: 1' && [ "$(ledger_rows "$sb")" = 0 ] \
    && grepq "$out" -F 'flake-repo-id' && ! grepq "$out" -F 'unbound variable'; then
  pass "F18: no lib, no row, the lib is named, no unbound variable, the verdict is the same"
else
  fail "F18: rc=$rc rows=$(ledger_rows "$sb") ledger: $(cat "$sb/ledger.jsonl" 2>&1) out: $out"
fi
rm -rf "$sb"
fi

# --- F19 ------------------------------------------------------------------------
# HIMMEL-5156 (j2305a follow-up 2): the lib is the one definition. F17 and R5 run
# with the checkout's own plain-https origin, which a stale copy hashes the same
# way, so only a structural check catches a re-added copy in either caller.
echo "== F19: neither caller defines the id functions itself =="
f19_re='^[[:space:]]*(function[[:space:]]+)?(_flake_norm_url|_flake_repo_id)[[:space:]]*(\(\))?[[:space:]]*(\{|$)'
f19_ctl=$(mktemp) || exit 1
printf '_flake_repo_id() {\n  :\n}\n' > "$f19_ctl"
grep -Eq "$f19_re" "$f19_ctl"; f19_rc=$?
rm -f "$f19_ctl"
if [ "$f19_rc" -eq 0 ]; then
  pass "F19: the matcher finds a definition (positive control)"
else
  fail "F19: the matcher missed a known definition, rc=$f19_rc"
fi
for f in scripts/ci/run-shell-tests.sh scripts/observability/suite-flake-summary.sh; do
  grep -Eq "$f19_re" "$RUNNER_ROOT/$f"; f19_rc=$?
  case "$f19_rc" in
    0) fail "F19: $f defines _flake_norm_url or _flake_repo_id itself" ;;
    1) pass "F19: $f defines neither id function" ;;
    *) fail "F19: $f could not be read, grep rc=$f19_rc" ;;
  esac
done

rst_tally
