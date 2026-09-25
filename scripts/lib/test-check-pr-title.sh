#!/usr/bin/env bash
# scripts/lib/test-check-pr-title.sh - HIMMEL-3616. check-pr-title.sh validates
# a PR-title string against the SAME conventional-commit + ticket regex
# check-commit-msg.sh enforces on commits, by invoking that script on a
# synthesized one-line message (the same reuse check-commit-range.sh already
# does for a range) — so the shape lives in one place. No network.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/check-pr-title.sh"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; [ $# -ge 2 ] && printf '    %s\n' "$2"; FAIL=$((FAIL+1)); }
contains() {
    case "$2" in *"$3"*) pass "$1" ;; *) fail "$1" "missing '$3' in: $2" ;; esac
}

# JIRA_PROJECT_KEY drives check-commit-msg.sh's ticket pattern (HIMMEL-N),
# matching this repo's own .env — set it explicitly so the test is hermetic
# and does not depend on the primary checkout's .env being loadable.
export JIRA_PROJECT_KEY=HIMMEL
export TICKET_ID_REQUIRED=1

echo "TEST: a type-less title is refused"
err_a=$(bash "$SUT" "[HIMMEL-1] foo" 2>&1); rc_a=$?
if [ "$rc_a" -ne 0 ]; then pass "type-less title refused (rc!=0)"; else fail "type-less title refused (rc!=0)" "got rc=$rc_a"; fi
contains "refusal names the expected shape" "$err_a" "type(scope)"

echo "TEST: a conventional title with a ticket passes"
out_b=$(bash "$SUT" "fix(x): [HIMMEL-1] foo" 2>&1); rc_b=$?
if [ "$rc_b" -eq 0 ]; then pass "conventional title passes (rc=0)"; else fail "conventional title passes (rc=0)" "got rc=$rc_b out=$out_b"; fi

echo "TEST: a conventional title with no ticket is refused"
err_c=$(bash "$SUT" "fix(x): foo with no ticket" 2>&1); rc_c=$?
if [ "$rc_c" -ne 0 ]; then pass "ticketless title refused (rc!=0)"; else fail "ticketless title refused (rc!=0)" "got rc=$rc_c"; fi

echo "TEST: usage error on no argument"
err_d=$(bash "$SUT" 2>&1); rc_d=$?
if [ "$rc_d" -ne 0 ]; then pass "no-arg refused (rc!=0)"; else fail "no-arg refused (rc!=0)" "got rc=$rc_d"; fi
contains "no-arg refusal shows usage" "$err_d" "Usage"

echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
[ "$FAIL" -gt 0 ] && exit 1
exit 0
