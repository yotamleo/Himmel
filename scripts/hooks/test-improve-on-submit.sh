#!/usr/bin/env bash
# test-improve-on-submit.sh — smoke test for scripts/hooks/improve-on-submit.sh.
#
# Covers:
#   1. Default (env unset) → exits 0 with empty stdout (no context injection).
#   2. IMPROVE_ON_SUBMIT=1 → exits 0, prints system-reminder context.
#   3. Other truthy values (true/on/yes) also activate.
#   4. Falsy values (0/false/empty) do NOT activate.
#   5. Drains stdin gracefully when the hook payload pipes a JSON body.

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
hook="$repo_root/scripts/hooks/improve-on-submit.sh"

if [ ! -f "$hook" ]; then
    echo "FAIL: $hook not found" >&2
    exit 1
fi

pass=0
fail=0

assert_pass() {
    pass=$((pass + 1))
    echo "  PASS: $1"
}

assert_fail() {
    fail=$((fail + 1))
    echo "  FAIL: $1"
}

# ---------- 1. Default OFF ----------
echo "Test 1: default OFF (env unset)"
out=$(unset IMPROVE_ON_SUBMIT; printf '{"prompt":"hello"}' | bash "$hook")
if [ -z "$out" ]; then
    assert_pass "no context injected when env unset"
else
    assert_fail "expected empty stdout, got: $out"
fi

# ---------- 2. IMPROVE_ON_SUBMIT=1 → active ----------
echo "Test 2: IMPROVE_ON_SUBMIT=1 → active"
out=$(IMPROVE_ON_SUBMIT=1 printf '{"prompt":"hello"}' | IMPROVE_ON_SUBMIT=1 bash "$hook")
if echo "$out" | grep -q "IMPROVE_ON_SUBMIT is active"; then
    assert_pass "context injected when env=1"
else
    assert_fail "expected 'IMPROVE_ON_SUBMIT is active' in output, got: $out"
fi

# ---------- 3. Other truthy values ----------
echo "Test 3: other truthy values activate"
for val in true TRUE on ON yes YES; do
    out=$(IMPROVE_ON_SUBMIT="$val" printf '{}' | IMPROVE_ON_SUBMIT="$val" bash "$hook")
    if echo "$out" | grep -q "IMPROVE_ON_SUBMIT is active"; then
        assert_pass "truthy value '$val' activates"
    else
        assert_fail "truthy value '$val' should activate but did not"
    fi
done

# ---------- 4. Falsy values stay off ----------
echo "Test 4: falsy values stay off"
for val in 0 false "" no off; do
    out=$(IMPROVE_ON_SUBMIT="$val" printf '{}' | IMPROVE_ON_SUBMIT="$val" bash "$hook")
    if [ -z "$out" ]; then
        assert_pass "falsy value '$val' stays off"
    else
        assert_fail "falsy value '$val' should be off but injected: $out"
    fi
done

# ---------- 5. No stdin payload ----------
echo "Test 5: no stdin payload still works"
out=$(IMPROVE_ON_SUBMIT=1 bash "$hook" </dev/null)
if echo "$out" | grep -q "IMPROVE_ON_SUBMIT is active"; then
    assert_pass "no stdin payload tolerated"
else
    assert_fail "expected activation even without stdin, got: $out"
fi

echo
echo "RESULTS: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
exit 0
