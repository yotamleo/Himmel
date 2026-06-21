#!/usr/bin/env bash
# test-preflight-sim.sh — golden-file tests for preflight-sim.sh (HIMMEL-475, C1).
#
# Usage: bash scripts/guardrails/test-preflight-sim.sh
#
# Each case pipes a fixture `.in` (one command per line) through the simulator
# and diffs its output against a hand-authored `.expected` golden file — the
# fixtures ARE the definition of correct (the boundary disclaims live-classifier
# parity). Also checks the exit-code contract and the curated-learnings path.
#
# Exit: 0 all passed, 1 any failed. bash 3.2-safe; shellcheck-clean.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIM="$SCRIPT_DIR/preflight-sim.sh"
FIX="$SCRIPT_DIR/fixtures/preflight"

[ -f "$SIM" ] || { printf 'FAIL: preflight-sim.sh not found at %s\n' "$SIM"; exit 1; }

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() {
    printf '  FAIL: %s\n' "$1"
    [ $# -ge 2 ] && printf '%s\n' "$2"
    FAIL=$((FAIL + 1))
}

# golden <label> <expected-file> <actual-output>
golden() {
    local label="$1" expected="$2" actual="$3"
    local diff_out
    if diff_out="$(printf '%s\n' "$actual" | diff -u "$expected" - 2>&1)"; then
        pass "$label"
    else
        fail "$label" "$diff_out"
    fi
}

# ---------------------------------------------------------------------------
# Case 1: built-in rules golden (learnings isolated via /dev/null)
# ---------------------------------------------------------------------------
printf '\nCase 1: built-in rules golden\n'
OUT1="$(bash "$SIM" --learnings /dev/null < "$FIX/builtin.in" 2>&1)"
golden "builtin rules match fixture" "$FIX/builtin.expected" "$OUT1"

# ---------------------------------------------------------------------------
# Case 2: exit code — collisions present → exit 1
# ---------------------------------------------------------------------------
printf '\nCase 2: exit code contract\n'
bash "$SIM" --learnings /dev/null < "$FIX/builtin.in" >/dev/null 2>&1
EC=$?
if [ "$EC" -eq 1 ]; then pass "exit 1 when a collision is predicted"; else fail "expected exit 1, got $EC"; fi

printf 'git status\n' | bash "$SIM" --learnings /dev/null >/dev/null 2>&1
EC0=$?
if [ "$EC0" -eq 0 ]; then pass "exit 0 when all clean"; else fail "expected exit 0, got $EC0"; fi

# usage error (option missing its value) → exit 2
bash "$SIM" --learnings >/dev/null 2>&1
ECU=$?
if [ "$ECU" -eq 2 ]; then pass "usage error exits 2"; else fail "expected exit 2, got $ECU"; fi

# a REFUSE-only learnings hit must drive exit 1 on its own
printf 'rm -rf /\n' | bash "$SIM" --learnings "$FIX/learnings.txt" >/dev/null 2>&1
ECR=$?
if [ "$ECR" -eq 1 ]; then pass "REFUSE-only learnings hit exits 1"; else fail "expected exit 1, got $ECR"; fi

# ---------------------------------------------------------------------------
# Case 3: curated learnings file applied (FLAG + REFUSE)
# ---------------------------------------------------------------------------
printf '\nCase 3: curated learnings applied\n'
OUT3="$(bash "$SIM" --learnings "$FIX/learnings.txt" < "$FIX/learnings.in" 2>&1)"
golden "learnings rules match fixture" "$FIX/learnings.expected" "$OUT3"

# ---------------------------------------------------------------------------
# Case 4: --help exits 0
# ---------------------------------------------------------------------------
printf '\nCase 4: --help\n'
HELP="$(bash "$SIM" --help 2>&1)"; HEC=$?
if [ "$HEC" -eq 0 ]; then pass "--help exits 0"; else fail "--help expected 0, got $HEC"; fi
if printf '%s' "$HELP" | grep -qF -- '--learnings'; then pass "--help documents --learnings"; else fail "--help should mention --learnings"; fi

# ---------------------------------------------------------------------------
printf '\n====================================\n'
printf 'test summary: %d passed, %d failed\n' "$PASS" "$FAIL"
printf '====================================\n'
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
