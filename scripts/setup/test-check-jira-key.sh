#!/usr/bin/env bash
# Smoke test for scripts/setup/check-jira-key.sh (HIMMEL-285).
#
# Usage: bash scripts/setup/test-check-jira-key.sh
#
# Covers:
#   1. optional + unset key -> rc=0, skip notice
#   2. required + unset key -> rc=1, ERROR text pointing at .env + --with-jira
#   3. optional + set key   -> rc=0, echoes key
#   4. required + set key   -> rc=0, echoes key
#   5. bad mode arg         -> rc=2, usage line
#   6. no mode arg (default) -> rc=0, skip notice (optional is the default)
#
# Exit codes: 0 all passed, 1 at least one failed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/check-jira-key.sh"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }
assert_rc() {
    local name="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then pass "$name (rc=$actual)"; else fail "$name" "expected rc=$expected, got rc=$actual"; fi
}
assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then pass "$name"; else fail "$name" "missing: $needle"; fi
}

# run_case <mode> <key|__unset__> — captures combined output in OUT, rc in RC.
OUT=""
RC=0
run_case() {
    local mode="$1" key="$2"
    RC=0
    if [ "$key" = "__unset__" ]; then
        OUT=$(env -u JIRA_PROJECT_KEY bash "$SCRIPT" "$mode" 2>&1) || RC=$?
    else
        OUT=$(JIRA_PROJECT_KEY="$key" bash "$SCRIPT" "$mode" 2>&1) || RC=$?
    fi
}

echo "TEST 1: optional + unset -> rc=0 with skip notice"
run_case optional "__unset__"
assert_rc "optional unset exit code" 0 "$RC"
assert_contains "skip notice" "Skipped: JIRA_PROJECT_KEY not set" "$OUT"
assert_contains "points at --with-jira" "--with-jira" "$OUT"

echo "TEST 2: required + unset -> rc=1 with loud error"
run_case required "__unset__"
assert_rc "required unset exit code" 1 "$RC"
assert_contains "error text" "ERROR: JIRA_PROJECT_KEY is not set" "$OUT"
assert_contains "fix points at .env" ".env" "$OUT"

echo "TEST 3: optional + set -> rc=0, echoes key"
run_case optional "ACME"
assert_rc "optional set exit code" 0 "$RC"
assert_contains "echoes key" "JIRA_PROJECT_KEY=ACME" "$OUT"

echo "TEST 4: required + set -> rc=0, echoes key"
run_case required "ACME"
assert_rc "required set exit code" 0 "$RC"
assert_contains "echoes key" "JIRA_PROJECT_KEY=ACME" "$OUT"

echo "TEST 5: bad mode arg -> rc=2 usage"
run_case bogus "ACME"
assert_rc "bad mode exit code" 2 "$RC"
assert_contains "usage line" "usage: check-jira-key.sh" "$OUT"

echo "TEST 6: no mode arg (default=optional) + unset -> rc=0 with skip notice"
RC=0
OUT=$(env -u JIRA_PROJECT_KEY bash "$SCRIPT" 2>&1) || RC=$?
assert_rc "no-arg default exit code" 0 "$RC"
assert_contains "no-arg skip notice" "Skipped: JIRA_PROJECT_KEY not set" "$OUT"

echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
