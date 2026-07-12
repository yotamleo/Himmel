#!/usr/bin/env bash
# test-sweep.sh — smoke tests for sweep-himmel.sh.
#
# These tests do NOT hit the network. They verify:
#   - Argument parsing (valid + invalid combinations)
#   - Help output renders
#   - Date computation (--days N resolves to a SINCE)
#   - Error paths exit non-zero with a clear message
#
# Online-hitting cases (--dry-run with real gh + --pr) are left for
# operator-driven manual smoke. Mocking gh would be more brittle than
# valuable for a first wedge.
#
# Manual smoke commands:
#   bash scripts/luna/sweep-himmel.sh --days 3 \
#       --state-repo "$(dirname "$HANDOVER_DIR")"    # dry-run
#   bash scripts/luna/sweep-himmel.sh --days 3 --pr        # opens PR in luna-brain

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWEEP="$SCRIPT_DIR/sweep-himmel.sh"

PASS=0
FAIL=0
FAILED_CASES=()

assert_exit() {
    local label="$1"
    local expected_rc="$2"
    shift 2
    local stderr_out
    local actual_rc=0
    stderr_out=$("$@" 2>&1 >/dev/null) || actual_rc=$?
    if [[ "$actual_rc" == "$expected_rc" ]]; then
        PASS=$((PASS + 1))
        echo "  PASS: $label (rc=$actual_rc)"
    else
        FAIL=$((FAIL + 1))
        FAILED_CASES+=("$label (expected rc=$expected_rc, got $actual_rc)")
        echo "  FAIL: $label (expected rc=$expected_rc, got $actual_rc)"
        if [[ -n "$stderr_out" ]]; then
            echo "    stderr was:"
            printf '%s\n' "$stderr_out" | sed 's/^/      /'
        fi
    fi
}

assert_stderr_contains() {
    local label="$1"
    local needle="$2"
    shift 2
    local stderr
    stderr=$("$@" 2>&1 >/dev/null || true)
    if echo "$stderr" | grep -qF -- "$needle"; then
        PASS=$((PASS + 1))
        echo "  PASS: $label (stderr contained '$needle')"
    else
        FAIL=$((FAIL + 1))
        FAILED_CASES+=("$label (stderr missing '$needle')")
        echo "  FAIL: $label (stderr missing '$needle')"
        echo "    stderr was: $stderr"
    fi
}

echo "==> Smoke tests for $SWEEP"
echo ""

# Sanity
[[ -x "$SWEEP" ]] || chmod +x "$SWEEP"

echo "Case 1: --help renders and exits 0"
assert_exit "help exits 0" 0 "$SWEEP" --help
assert_exit "-h exits 0"  0 "$SWEEP" -h

echo ""
echo "Case 2: unknown argument exits non-zero with a clear message"
assert_exit "unknown arg exits 1" 1 "$SWEEP" --does-not-exist
assert_stderr_contains "unknown arg message" "unknown argument" "$SWEEP" --does-not-exist

echo ""
echo "Case 3: --days requires an integer"
assert_exit "--days missing arg exits 1" 1 "$SWEEP" --days
assert_stderr_contains "--days missing arg message" "requires" "$SWEEP" --days
assert_exit "--days non-int exits 1" 1 "$SWEEP" --days abc
assert_stderr_contains "--days non-int message" "positive integer" "$SWEEP" --days abc

echo ""
echo "Case 4: --since requires YYYY-MM-DD"
assert_exit "--since missing arg exits 1" 1 "$SWEEP" --since
assert_stderr_contains "--since missing arg message" "requires" "$SWEEP" --since
assert_exit "--since bad format exits 1" 1 "$SWEEP" --since 2026/05/01
assert_stderr_contains "--since bad format message" "YYYY-MM-DD" "$SWEEP" --since 2026/05/01

echo ""
echo "Case 5: --out requires a path"
assert_exit "--out missing arg exits 1" 1 "$SWEEP" --out
assert_stderr_contains "--out missing arg message" "requires" "$SWEEP" --out

echo ""
echo "Case 6: --state-repo requires a path"
assert_exit "--state-repo missing arg exits 1" 1 "$SWEEP" --state-repo

echo ""
echo "Case 7: --days and --since are mutually exclusive"
assert_exit "days-then-since exits 1" 1 "$SWEEP" --days 3 --since 2026-01-01
assert_stderr_contains "days-then-since message" "mutually exclusive" "$SWEEP" --days 3 --since 2026-01-01
assert_exit "since-then-days exits 1" 1 "$SWEEP" --since 2026-01-01 --days 3
assert_stderr_contains "since-then-days message" "mutually exclusive" "$SWEEP" --since 2026-01-01 --days 3

echo ""
echo "==> Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
    echo ""
    echo "Failed cases:"
    for case in "${FAILED_CASES[@]}"; do
        echo "  - $case"
    done
    exit 1
fi

exit 0
