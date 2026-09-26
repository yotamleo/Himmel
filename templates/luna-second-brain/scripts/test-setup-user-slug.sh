#!/usr/bin/env bash
# Hermetic tests for scripts/lib/check-user-slug.sh and setup.sh's step
# [2/6] wiring (HIMMEL-2539).
#
# The thing under test is a DISPOSITION, not a resolver: the resolver
# (scripts/lib/user-slug.sh) is unchanged in its two sources (env var, git
# config). What matters here is that an unresolved slug leaves setup.sh
# running (rc=0, never the old exit 1), says what that costs, and is still
# visible after "Setup complete." scrolls past.
#
# PLATFORM GUARD — no .ps1 twin, deliberately: this is the suite for the
# bash setup path; scripts/setup.ps1 has its own USER_SLUG step calling the
# same check-user-slug.sh via Git Bash (see setup.ps1's [2/6] comment), and
# is exercised manually per tests/smoke-test.md rather than by a hermetic PS
# harness — there is none in this template today for setup.ps1 itself.
set -uo pipefail

here="$(cd -- "$(dirname -- "$0")" && pwd)"
script="$here/lib/check-user-slug.sh"
setup_sh="$here/setup.sh"
setup_ps1="$here/setup.ps1"
PASS=0; FAIL=0; TMP_ROOT=""
# shellcheck disable=SC2329,SC2317
cleanup() { [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ] && rm -rf "$TMP_ROOT" 2>/dev/null; return 0; }
trap cleanup EXIT
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want='$2' got='$3'"; fi; }
# grep -q with NO pipeline: under `set -o pipefail` a piped `grep -q` reports
# a SUCCESSFUL early match as a failed pipeline (SIGPIPE on the producer) —
# HIMMEL-1430.
assert_has() { if grep -q -F -- "$2" <<< "$3"; then pass "$1"; else fail "$1" "missing: $2"; fi; }
assert_lacks() { if grep -q -F -- "$2" <<< "$3"; then fail "$1" "unexpectedly present: $2"; else pass "$1"; fi; }

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/setup-user-slug.XXXXXX") || {
  echo "FAIL: mktemp -d failed" >&2; exit 1;
}
if command -v cygpath >/dev/null 2>&1; then TMP_ROOT=$(cygpath -m "$TMP_ROOT"); fi

# Isolation: a HOME the operator's ~/.gitconfig cannot reach, no
# GIT_CONFIG_* overrides, no system config — otherwise a tester with a real
# git identity resolves a slug and the unresolved arms below never run.
export HOME="$TMP_ROOT/home"; mkdir -p "$HOME"
unset GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM 2>/dev/null || true
export GIT_CONFIG_NOSYSTEM=1

REPO="$TMP_ROOT/repo"
git init -q "$REPO"
git -C "$REPO" config user.email "test@test.invalid"

run() { ( cd "$REPO" && bash "$script" ); }

# ── 1. Resolved: stdout is the bare slug and NOTHING else, because setup.sh
# captures it straight into `export USER_SLUG=`.
echo "TEST: resolved -> rc=0, stdout is the bare slug"
out=$(USER_SLUG=alice run 2>/dev/null); rc=$?
assert_eq "resolved rc=0" "0" "$rc"
assert_eq "stdout is exactly the slug" "alice" "$out"
err=$(USER_SLUG=alice run 2>&1 >/dev/null)
assert_has "stderr names the source" "USER_SLUG env" "$err"

# ── 2. Unresolved: rc=3, and specifically NOT the old rc=1 that aborted
# setup.sh's install.
echo "TEST: unresolved -> rc=3 (the advisory code), never rc=1"
git -C "$REPO" config --unset user.name 2>/dev/null || true
out=$(USER_SLUG='' run 2>/dev/null); rc=$?
assert_eq "unresolved rc=3" "3" "$rc"
assert_eq "unresolved stdout is empty" "" "$out"

err=$(USER_SLUG='' run 2>&1 >/dev/null)
assert_has "diagnostic is a WARN, since the run continues" "WARN user-slug" "$err"
assert_lacks "and is NOT framed as a fatal ERR" "ERR user-slug" "$err"
assert_has "says the setup continues" "Setup CONTINUES" "$err"
assert_has "names the consequence" "handover buckets" "$err"
assert_has "remedy 1: the env var" "USER_SLUG" "$err"
assert_has "remedy 2: the git identity" "git config" "$err"
assert_has "says no re-run of setup is needed" "no re-run of setup" "$err"

# ── 3. Usage error: an unexpected arg is not the no-flag form.
echo "TEST: usage error -> rc=2"
out=$( ( cd "$REPO" && bash "$script" --bogus ) 2>/dev/null); rc=$?
assert_eq "unknown arg -> usage rc=2" "2" "$rc"

# ── 4. setup.sh wiring: routes through check-user-slug.sh, records the
# advised state for the footer, and no longer aborts.
echo "TEST: setup.sh step [2/6] wiring"
setup_src=$(cat "$setup_sh")
assert_has "step [2/6] calls check-user-slug.sh" "lib/check-user-slug.sh" "$setup_src"
assert_has "an unresolved slug is recorded for the footer" "_user_slug_manual=1" "$setup_src"
assert_has "the footer names the skipped step" "STILL MANUAL: USER_SLUG" "$setup_src"

# No `exit 1` between the [2/6] banner and the [3/6] banner — the abort this
# ticket removed. A line-range assertion rather than a whole-file grep,
# because setup.sh legitimately exits 1 elsewhere ([1/6]'s preflight).
s_line=$(grep -n '\[2/6\] Resolving USER_SLUG' "$setup_sh" | head -1 | cut -d: -f1)
e_line=$(grep -n '\[3/6\] Installing pre-commit' "$setup_sh" | head -1 | cut -d: -f1)
if [ -n "$s_line" ] && [ -n "$e_line" ] && [ "$e_line" -gt "$s_line" ]; then
  block=$(sed -n "${s_line},${e_line}p" "$setup_sh")
  assert_lacks "step [2/6] no longer aborts the install" "exit 1" "$block"
else
  fail "could not locate the [2/6]..[3/6] block" "start=$s_line end=$e_line"
  block=""
fi

# ── 5. Executed, not just grepped: eval the extracted [2/6] block itself
# against the same isolated env used above, so the RED here is the actual
# defect ("setup.sh hard-fails on an unresolved USER_SLUG") rather than a
# proxy for it. Works unmodified at base (the old inline exit-1 block) and
# after the fix (the check-user-slug.sh wiring), since it evals whatever
# text sits between the two banners.
echo "TEST: setup.sh [2/6] step completes (rc=0) with no USER_SLUG, no git identity"
if [ -n "$block" ]; then
  _step_out=$(
    ( set -uo pipefail
      REPO_ROOT="$(dirname "$here")"
      cd "$REPO" || exit 9
      unset USER_SLUG
      eval "$block"
    ) 2>"$TMP_ROOT/step-stderr"
  )
  _step_rc=$?
  _step_err=$(cat "$TMP_ROOT/step-stderr")
  assert_eq "setup continues past an unresolved slug (rc=0)" "0" "$_step_rc"
  assert_has "the step's own stderr is WARN-shaped" "WARN user-slug" "$_step_err"
else
  fail "skipped: could not extract the [2/6] block"
fi

# ── 6. setup.ps1: same disposition, source-text only (no PS harness here).
echo "TEST: setup.ps1 [2/6] wiring"
ps1_src=$(cat "$setup_ps1")
assert_has "calls check-user-slug.sh (not the retired _print-user-slug.sh)" "lib\\check-user-slug.sh" "$ps1_src"
assert_lacks "_print-user-slug.sh is retired" "_print-user-slug.sh" "$ps1_src"
assert_has "an unresolved slug is recorded for the footer" "UserSlugManual = \$true" "$ps1_src"
assert_has "the footer names the skipped step" "STILL MANUAL: USER_SLUG" "$ps1_src"

s2_line=$(grep -n '\[2/6\] Resolving USER_SLUG' "$setup_ps1" | head -1 | cut -d: -f1)
e2_line=$(grep -n '\[3/6\] Installing pre-commit' "$setup_ps1" | head -1 | cut -d: -f1)
if [ -n "$s2_line" ] && [ -n "$e2_line" ] && [ "$e2_line" -gt "$s2_line" ]; then
  ps1_block=$(sed -n "${s2_line},${e2_line}p" "$setup_ps1")
  # A remaining `exit 1` in this block is fine (bash-missing is a genuine
  # precondition failure, unrelated to slug resolution) — the removed shape
  # was the fatal message paired with it.
  assert_lacks "step [2/6] no longer treats an unresolved slug as fatal" \
    "ERROR: USER_SLUG resolution failed" "$ps1_block"
else
  fail "could not locate the [2/6]..[3/6] block in setup.ps1" "start=$s2_line end=$e2_line"
fi

echo ""
echo "RESULTS: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
