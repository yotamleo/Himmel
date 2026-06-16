#!/usr/bin/env bash
# Smoke test for scripts/lib/handover-path.sh.
set -uo pipefail

LIB="$(cd "$(dirname "$0")" && pwd)/handover-path.sh"
# shellcheck source=handover-path.sh
# shellcheck disable=SC1091
. "$LIB"

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "PASS $label"
    else
        echo "FAIL $label — expected '$expected', got '$actual'"
        FAILED=$((FAILED + 1))
    fi
}

assert_rc() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label (rc=$actual)"
    else
        echo "FAIL $label — expected rc=$expected, got rc=$actual"
        FAILED=$((FAILED + 1))
    fi
}

FAILED=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# T1: HANDOVER_DIR unset → inline default under repo root (pure)
# PURE handover_root only resolves when the dir already exists. The
# himmel repo has handovers/ tracked (README stub), so this passes on
# main without bootstrap.
unset HANDOVER_DIR
REPO=$(git rev-parse --show-toplevel)
got=$(handover_root)
expected=$(cd "$REPO/handovers" && pwd)
assert_eq "T1 mode A resolves to repo/handovers" "$expected" "$got"
assert_eq "T1 mode A reports A" "A" "$(handover_mode)"

# T1b: pure handover_root in Mode A with MISSING dir → rc=2 (HIMMEL-150).
# Use an isolated temp git repo with no handovers/ to exercise the pure
# fail-closed path without polluting himmel state.
TMP_REPO_PURE=$(mktemp -d)
git -C "$TMP_REPO_PURE" init --quiet
(
    cd "$TMP_REPO_PURE" || exit 1
    unset HANDOVER_DIR
    handover_root >/dev/null 2>&1
)
assert_rc "T1b pure handover_root rc=2 when inline missing" 2 "$?"
if [ -d "$TMP_REPO_PURE/handovers" ]; then
    echo "FAIL T1b pure resolver should NOT have mkdir'd"
    FAILED=$((FAILED + 1))
else
    echo "PASS T1b pure resolver did not mkdir"
fi
rm -rf "$TMP_REPO_PURE"

# T1c: handover_root_ensure in Mode A with missing dir → creates + rc=0.
TMP_REPO_ENSURE=$(mktemp -d)
git -C "$TMP_REPO_ENSURE" init --quiet
got_ensure=$(
    cd "$TMP_REPO_ENSURE" || exit 1
    unset HANDOVER_DIR
    handover_root_ensure 2>/dev/null
)
expected_ensure=$(cd "$TMP_REPO_ENSURE/handovers" 2>/dev/null && pwd)
assert_eq "T1c ensure resolves to repo/handovers" "$expected_ensure" "$got_ensure"
if [ -d "$TMP_REPO_ENSURE/handovers" ]; then
    echo "PASS T1c ensure did mkdir"
else
    echo "FAIL T1c ensure should have mkdir'd"
    FAILED=$((FAILED + 1))
fi
rm -rf "$TMP_REPO_ENSURE"

# T2: HANDOVER_DIR set to existing dir → mode B
mkdir -p "$TMP/external"
HANDOVER_DIR="$TMP/external"
got=$(handover_root)
expected=$(cd "$TMP/external" && pwd)
assert_eq "T2 mode B resolves to HANDOVER_DIR" "$expected" "$got"
assert_eq "T2 mode B reports B" "B" "$(handover_mode)"

# T3: HANDOVER_DIR set to non-existent dir → fail-closed rc=2
HANDOVER_DIR="$TMP/does-not-exist"
( handover_root >/dev/null 2>&1 )
assert_rc "T3 missing HANDOVER_DIR fails closed" 2 "$?"

# T4: HANDOVER_DIR set to a file (not dir) → fail-closed rc=2
touch "$TMP/not-a-dir"
HANDOVER_DIR="$TMP/not-a-dir"
( handover_root >/dev/null 2>&1 )
assert_rc "T4 HANDOVER_DIR is a file" 2 "$?"

# T5: HANDOVER_DIR empty string → treat as unset → inline default
unset HANDOVER_DIR
export HANDOVER_DIR=""
got=$(handover_root)
expected=$(cd "$REPO/handovers" && pwd)
assert_eq "T5 empty HANDOVER_DIR falls back to inline" "$expected" "$got"

# T6: trailing slash on HANDOVER_DIR is normalised
HANDOVER_DIR="$TMP/external/"
got=$(handover_root)
expected=$(cd "$TMP/external" && pwd)
assert_eq "T6 trailing slash normalised" "$expected" "$got"

if [ "$FAILED" -gt 0 ]; then
    echo "---"
    echo "FAIL $FAILED case(s)"
    exit 1
fi
echo "---"
echo "PASS all cases"
exit 0
