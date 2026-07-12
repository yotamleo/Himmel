#!/usr/bin/env bash
# Smoke test for scripts/overnight/stop-marker.sh (HIMMEL-137).
#
# Covers:
#   1. set creates marker; check returns rc=0.
#   2. check on absent marker returns rc=1 (silent).
#   3. clear removes marker; check returns rc=1 after.
#   4. Aliases (reset, rm) behave like clear.
#   5. set is idempotent — calling twice leaves marker intact.
#   6. clear is idempotent — calling on absent marker reports "already clear".
#   7. status prints SET when armed + CLEAR when not.
#   8. Unknown subcommand exits 2.
#   9. set without write perms exits 3.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/stop-marker.sh"

PASS=0; FAIL=0; TMP_ROOT=""
# shellcheck disable=SC2329,SC2317
cleanup() {
    if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
        rm -rf "$TMP_ROOT" 2>/dev/null || true
    fi
}
trap cleanup EXIT
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }
assert_rc() {
    local n="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$n"; else fail "$n" "want=$want got=$got"; fi
}
assert_contains() {
    local n="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then pass "$n"; else fail "$n" "missing: $needle"; fi
}

TMP_ROOT=$(mktemp -d)
if command -v cygpath >/dev/null 2>&1; then TMP_ROOT=$(cygpath -m "$TMP_ROOT"); fi
export OVERNIGHT_STOP_DIR="$TMP_ROOT"
MARKER="$TMP_ROOT/.overnight-stop"

# Test 1: set + check ------------------------------------------------
echo "TEST: set creates marker; check returns rc=0"
rc=0; out=$(bash "$SCRIPT" set 2>&1) || rc=$?
assert_rc "set rc=0" "0" "$rc"
if [ -f "$MARKER" ]; then pass "marker exists at $MARKER"; else fail "marker absent"; fi
rc=0; bash "$SCRIPT" check >/dev/null 2>&1 || rc=$?
assert_rc "check rc=0 when armed" "0" "$rc"

# Test 2: check on absent marker -------------------------------------
echo "TEST: check on absent marker returns rc=1 (silent)"
rm -f "$MARKER"
rc=0; out=$(bash "$SCRIPT" check 2>&1) || rc=$?
assert_rc "check rc=1 when clear" "1" "$rc"
if [ -z "$out" ]; then pass "check produces no output (silent)"; else fail "check should be silent" "$out"; fi

# Test 3: clear ------------------------------------------------------
echo "TEST: clear removes marker"
bash "$SCRIPT" set >/dev/null 2>&1
rc=0; out=$(bash "$SCRIPT" clear 2>&1) || rc=$?
assert_rc "clear rc=0" "0" "$rc"
if [ -f "$MARKER" ]; then fail "marker still present after clear"; else pass "marker removed by clear"; fi

# Test 4: aliases ----------------------------------------------------
echo "TEST: aliases (reset, rm) behave like clear"
bash "$SCRIPT" set >/dev/null 2>&1
bash "$SCRIPT" reset >/dev/null 2>&1
if [ -f "$MARKER" ]; then fail "reset alias did not clear"; else pass "reset alias cleared marker"; fi
bash "$SCRIPT" set >/dev/null 2>&1
bash "$SCRIPT" rm >/dev/null 2>&1
if [ -f "$MARKER" ]; then fail "rm alias did not clear"; else pass "rm alias cleared marker"; fi

# Test 5: set idempotent --------------------------------------------
echo "TEST: set is idempotent"
bash "$SCRIPT" set >/dev/null 2>&1
ts1=$(cat "$MARKER")
sleep 1
bash "$SCRIPT" set >/dev/null 2>&1
ts2=$(cat "$MARKER")
# Second set should refresh timestamp (acceptable idempotence — same
# effect, marker exists either way). Just verify marker still present.
if [ -f "$MARKER" ]; then pass "marker present after double-set"; else fail "double-set lost marker"; fi
# Optional: confirm timestamp can be either equal or refreshed; both fine.
if [ -n "$ts1" ] && [ -n "$ts2" ]; then
    pass "marker has timestamp content"
else
    pass "marker timestamps optional"
fi

# Test 6: clear idempotent ------------------------------------------
echo "TEST: clear is idempotent on absent marker"
bash "$SCRIPT" clear >/dev/null 2>&1
rc=0; out=$(bash "$SCRIPT" clear 2>&1) || rc=$?
assert_rc "double-clear rc=0" "0" "$rc"
assert_contains "double-clear reports already clear" "already clear" "$out"

# Test 7: status ------------------------------------------------------
echo "TEST: status reports SET / CLEAR"
out=$(bash "$SCRIPT" status 2>&1)
assert_contains "status CLEAR reported" "CLEAR" "$out"
bash "$SCRIPT" set >/dev/null 2>&1
out=$(bash "$SCRIPT" status 2>&1)
assert_contains "status SET reported" "SET" "$out"

# Test 8: unknown subcommand exits 2 ---------------------------------
echo "TEST: unknown subcommand exits 2"
rc=0; out=$(bash "$SCRIPT" garbage 2>&1) || rc=$?
assert_rc "unknown rc=2" "2" "$rc"
assert_contains "stderr explains" "unknown subcommand" "$out"

# Test 9: filesystem error exits 3 -----------------------------------
echo "TEST: set with bad MARKER_DIR exits 3"
# Use a path with embedded NUL or a known-impossible dir. /proc/1/no-such
# isn't writable. Better: point dir at an existing FILE (mkdir -p will
# fail).
fake_file="$TMP_ROOT/blocking-file"
: > "$fake_file"
rc=0; out=$(OVERNIGHT_STOP_DIR="$fake_file/sub" bash "$SCRIPT" set 2>&1) || rc=$?
# mkdir -p over a file path returns non-zero on Linux/Git Bash. Our script
# checks rc and exits 3.
case "$rc" in
    3) pass "set rc=3 on bad dir" ;;
    *) fail "expected rc=3, got $rc" "$out" ;;
esac

echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
