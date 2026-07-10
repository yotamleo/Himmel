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

# T7: _hp_json_field / _hp_json_escape unit cases (HIMMEL-882 CR round-4
# test-2). Direct coverage of the flat-JSON parser/escaper shared by
# queue-lock.sh and arm-resume.sh (previously only exercised indirectly
# through their acquire/rewrite flows).

# T7a: a value ending in a backslash immediately before the field's closing
# quote (the parity boundary) -- the raw value's trailing backslash doubles
# under _hp_json_escape, so the closing quote must read as UNESCAPED (an
# EVEN trailing-backslash count) and correctly terminate the value there.
raw7a=$'abc\\'
_hp_json_escape "$raw7a"; esc7a="$_HP_ESC"
line7a="{\"key\":\"$esc7a\",\"next\":\"ok\"}"
_hp_json_field "$line7a" key
assert_eq "T7a trailing-backslash value extracts in full (escaped form)" "$esc7a" "$_HP_FIELD"
_hp_json_field "$line7a" next
assert_eq "T7a boundary correctly found -- next field still parses" "ok" "$_HP_FIELD"

# T7b: a raw value with a literal backslash immediately adjacent to a
# literal double-quote -- escaping produces an ODD trailing-backslash run
# before an ESCAPED quote (the quote is part of the value, not the
# terminator), so the scan must keep going past it instead of truncating.
raw7b='x\"y'
_hp_json_escape "$raw7b"; esc7b="$_HP_ESC"
line7b="{\"key\":\"$esc7b\"}"
_hp_json_field "$line7b" key
assert_eq "T7b backslash-adjacent-to-quote value round-trips" "$esc7b" "$_HP_FIELD"

# T7c: an empty value ("key":"") extracts as the empty string, not a miss,
# and the scan still finds the next field's boundary correctly.
line7c='{"key":"","next":"ok"}'
_hp_json_field "$line7c" key
assert_eq "T7c empty value extracts as empty string" "" "$_HP_FIELD"
_hp_json_field "$line7c" next
assert_eq "T7c boundary correctly found after an empty value" "ok" "$_HP_FIELD"

# T7d: a key entirely absent from the line -- the return-on-miss branch
# reports the miss via $_HP_FIELD="" rather than leaving a stale value from
# a prior call.
_HP_FIELD="stale-from-a-prior-call"
line7d='{"other":"value"}'
_hp_json_field "$line7d" key
assert_eq "T7d absent key resets _HP_FIELD to empty (miss branch)" "" "$_HP_FIELD"

if [ "$FAILED" -gt 0 ]; then
    echo "---"
    echo "FAIL $FAILED case(s)"
    exit 1
fi
echo "---"
echo "PASS all cases"
exit 0
