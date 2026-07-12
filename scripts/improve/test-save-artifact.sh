#!/usr/bin/env bash
# test-save-artifact.sh — smoke test for scripts/improve/save-artifact.sh.
#
# Covers:
#   1. Happy path: writes a file with correct frontmatter + content.
#   2. Mode A (inline) when HANDOVER_DIR unset.
#   3. Mode B (external) when HANDOVER_DIR set + exists.
#   4. Fail-closed when HANDOVER_DIR points to a non-existent dir (rc=2).
#   5. Missing required args → usage + rc=1.
#   6. Dry-run prints body, writes nothing.
#
# Run from the repo root:
#   bash scripts/improve/test-save-artifact.sh

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
script="$repo_root/scripts/improve/save-artifact.sh"

if [ ! -x "$script" ] && [ ! -f "$script" ]; then
    echo "FAIL: $script not found" >&2
    exit 1
fi

pass=0
fail=0
fail_msgs=()

assert_pass() {
    pass=$((pass + 1))
    echo "  PASS: $1"
}

assert_fail() {
    fail=$((fail + 1))
    fail_msgs+=("$1")
    echo "  FAIL: $1"
}

# ---------- 1. Happy path Mode A ----------
echo "Test 1: happy path Mode A (HANDOVER_DIR unset)"

# Use a temp git repo so we don't pollute the real repo's .improve/.
tmp_repo=$(mktemp -d)
set +e
(
    set -e
    cd "$tmp_repo"
    git init -q
    git -c user.name=test -c user.email=test@example.com commit --allow-empty -m init -q
    unset HANDOVER_DIR
    out=$(bash "$script" --original "draft prompt here" --refined "refined prompt body" --notes "Q1: x" --rationale "removed hedging")
    [ -f "$out" ] || { echo "happy path Mode A: artifact not written at $out" >&2; exit 1; }
    grep -q "^name: improve-" "$out" || { echo "happy path Mode A: missing name in frontmatter" >&2; exit 1; }
    grep -q "^mode: A$" "$out" || { echo "happy path Mode A: mode not A" >&2; exit 1; }
    grep -q "refined prompt body" "$out" || { echo "happy path Mode A: refined body missing" >&2; exit 1; }
    grep -q "removed hedging" "$out" || { echo "happy path Mode A: rationale missing" >&2; exit 1; }
)
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
    assert_pass "happy path Mode A"
else
    assert_fail "happy path Mode A (subshell failed rc=$rc)"
fi
rm -rf "$tmp_repo"

# ---------- 2. Mode B ----------
echo "Test 2: Mode B (HANDOVER_DIR set + exists)"
tmp_handover=$(mktemp -d)
out=$(HANDOVER_DIR="$tmp_handover" bash "$script" --original "x" --refined "y")
if [ -f "$out" ] && grep -q "^mode: B$" "$out"; then
    assert_pass "Mode B writes under HANDOVER_DIR/.improve/"
else
    assert_fail "Mode B: artifact missing or mode not 'B' (out=$out)"
fi
rm -rf "$tmp_handover"

# ---------- 3. Fail-closed when HANDOVER_DIR missing ----------
echo "Test 3: fail-closed when HANDOVER_DIR points to a missing dir"
set +e
HANDOVER_DIR="/nonexistent-improve-test-$$" bash "$script" --original "x" --refined "y" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 2 ]; then
    assert_pass "fail-closed rc=2"
else
    assert_fail "fail-closed: expected rc=2, got rc=$rc"
fi

# ---------- 4. Missing required args ----------
echo "Test 4: missing required args → rc=1"
set +e
bash "$script" --original "x" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 1 ]; then
    assert_pass "missing --refined rc=1"
else
    assert_fail "missing --refined: expected rc=1, got rc=$rc"
fi

set +e
bash "$script" --refined "y" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 1 ]; then
    assert_pass "missing --original rc=1"
else
    assert_fail "missing --original: expected rc=1, got rc=$rc"
fi

# ---------- 5. Dry-run prints, writes nothing ----------
echo "Test 5: dry-run prints body, writes nothing"
tmp_handover=$(mktemp -d)
out=$(HANDOVER_DIR="$tmp_handover" bash "$script" --original "x" --refined "y" --dry-run)
if echo "$out" | grep -q "would write to" && [ ! -d "$tmp_handover/.improve" ]; then
    assert_pass "dry-run prints + writes nothing"
else
    assert_fail "dry-run: expected 'would write to' + no .improve/ dir (out=$out)"
fi
rm -rf "$tmp_handover"

# ---------- 6. Slug derivation handles whitespace-only original ----------
echo "Test 6: slug fallback when original is whitespace"
tmp_handover=$(mktemp -d)
out=$(HANDOVER_DIR="$tmp_handover" bash "$script" --original "   " --refined "y")
case "$out" in
    *-draft-*.md)
        assert_pass "slug falls back to 'draft' on whitespace-only original"
        ;;
    *)
        assert_fail "slug fallback: expected *-draft-*.md, got $out"
        ;;
esac
rm -rf "$tmp_handover"

echo
echo "RESULTS: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
    for m in "${fail_msgs[@]}"; do
        echo "  - $m"
    done
    exit 1
fi
exit 0
