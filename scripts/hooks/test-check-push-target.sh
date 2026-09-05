#!/usr/bin/env bash
# Smoke test for scripts/hooks/check-push-target.sh (HIMMEL-2371).
#
# HIMMEL-2371 root cause: this hook is wired as a pre-commit-configured
# `stages: [pre-push]` entry. pre-commit's own hook-impl drains ALL of git's
# pre-push stdin before invoking any configured hook and exposes the pushed
# ref only via PRE_COMMIT_* env vars — so the hook's stdin is ALWAYS empty
# under that shape, and the old `while read` loop silently exited 0 on every
# push, including a direct push to main (the incident this ticket was filed
# from — confirmed against the real pre-commit dispatch chain: see the
# repro commands in the PR body). Empty stdin is normal there; it is not
# evidence nothing is being pushed.
#
# Covers:
#   1. Raw ref-stream stdin naming main -> BLOCKED (positive control).
#   2. Raw ref-stream stdin naming a feature branch -> PASS (negative control).
#   3. Raw ref-stream stdin naming master -> BLOCKED (is_main_ref covers both).
#   4. Multi-ref raw stdin with main as the SECOND line -> BLOCKED.
#   5. THE BUG: pre-commit-configured shape (PRE_COMMIT=1, empty stdin,
#      PRE_COMMIT_REMOTE_BRANCH=refs/heads/main) -> BLOCKED. Red on the
#      pre-fix script (exit 0 / silent pass), green after the fix.
#   6. Same shape, feature branch -> PASS.
#   7. Empty stdin with NO env at all (a genuine no-op push, e.g. the branch
#      is already up to date, outside pre-commit) -> PASS, not fail-closed.
#   8. PRE_COMMIT=1 but PRE_COMMIT_REMOTE_BRANCH unset (pre-commit's env
#      contract did not hold) -> fail CLOSED.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/check-push-target.sh"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }

expect_blocked() {
    local label="$1" out rc
    shift
    out=$("$@" 2>&1) && rc=0 || rc=$?
    if [ "$rc" -eq 0 ]; then
        fail "$label: push must be BLOCKED" "hook exited 0; output: $out"
    else
        case "$out" in
            *"not allowed"*|*"refusing"*) pass "$label" ;;
            *) fail "$label: blocked but without an explanatory message" "output: $out" ;;
        esac
    fi
}

expect_pass() {
    local label="$1" out rc
    shift
    out=$("$@" 2>&1) && rc=0 || rc=$?
    if [ "$rc" -eq 0 ]; then
        pass "$label"
    else
        fail "$label: push must PASS" "hook exited $rc; output: $out"
    fi
}

# run_raw REF_LINES — feed a raw git pre-push ref stream to the hook on stdin.
# shellcheck disable=SC2329,SC2317  # invoked indirectly via expect_blocked/expect_pass "$@"
run_raw() {
    printf '%s' "$1" | bash "$HOOK"
}

# Test 1/2/3: raw ref-stream stdin (a real .git/hooks/pre-push, the
# pre-push.legacy migration hook, or a direct invocation) -----------------

echo "TEST: raw stdin naming refs/heads/main -> BLOCKED"
expect_blocked "raw stdin, push to main" \
    run_raw "refs/heads/main abc refs/heads/main def
"

echo "TEST: raw stdin naming a feature branch -> PASS"
expect_pass "raw stdin, push to feature branch" \
    run_raw "refs/heads/feat/x abc refs/heads/feat/x def
"

echo "TEST: raw stdin naming refs/heads/master -> BLOCKED"
expect_blocked "raw stdin, push to master" \
    run_raw "refs/heads/master abc refs/heads/master def
"

echo "TEST: multi-ref raw stdin, main is the SECOND line -> BLOCKED"
expect_blocked "raw stdin, multi-ref push with main second" \
    run_raw "refs/heads/feat/x abc refs/heads/feat/x def
refs/heads/main abc refs/heads/main def
"

# Test 5/6: the actual bug shape — pre-commit-configured dispatch ----------

echo "TEST: pre-commit-configured shape (PRE_COMMIT=1, empty stdin, PRE_COMMIT_REMOTE_BRANCH=main) -> BLOCKED"
expect_blocked "configured shape, push to main (HIMMEL-2371 regression)" \
    env PRE_COMMIT=1 PRE_COMMIT_REMOTE_BRANCH=refs/heads/main bash "$HOOK" </dev/null

echo "TEST: pre-commit-configured shape, feature branch -> PASS"
expect_pass "configured shape, push to feature branch" \
    env PRE_COMMIT=1 PRE_COMMIT_REMOTE_BRANCH=refs/heads/feat/x bash "$HOOK" </dev/null

# Test 7: genuinely empty stdin outside pre-commit (no-op push) -----------

echo "TEST: empty stdin, no env at all (no-op push, not through pre-commit) -> PASS"
expect_pass "empty stdin, no pre-commit env" \
    bash "$HOOK" </dev/null

# Test 8: PRE_COMMIT=1 but pre-commit's env contract did not hold ---------

echo "TEST: PRE_COMMIT=1 with no PRE_COMMIT_REMOTE_BRANCH -> fail CLOSED"
expect_blocked "PRE_COMMIT=1, PRE_COMMIT_REMOTE_BRANCH unset" \
    env PRE_COMMIT=1 bash "$HOOK" </dev/null

# Summary ------------------------------------------------------------

echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
