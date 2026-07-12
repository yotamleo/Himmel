#!/usr/bin/env bash
# Hermetic test for scripts/lib/register-auto-arm-hook.sh (HIMMEL-594).
set -uo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel)"
REG="$REPO_ROOT/scripts/lib/register-auto-arm-hook.sh"
[ -f "$REG" ] || { echo "FAIL: $REG not found"; exit 1; }
failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

HOOK='bash "/abs/himmel/scripts/hooks/auto-arm-on-cap.sh"'

# --- registers into an empty settings.json ---
t="$(mktemp -d)"; s="$t/settings.json"; echo '{}' > "$s"
bash "$REG" "$s" "$HOOK" --assume-yes >/dev/null 2>&1
n="$(jq '[.hooks.PreToolUse[]?.hooks[]?.command | select(test("auto-arm-on-cap"))] | length' "$s")"
if [ "$n" -eq 1 ]; then pass "registers hook into {}"; else fail "expected 1 entry, got $n"; fi

# --- idempotent: 2nd run keeps exactly one ---
bash "$REG" "$s" "$HOOK" --assume-yes >/dev/null 2>&1
n="$(jq '[.hooks.PreToolUse[]?.hooks[]?.command | select(test("auto-arm-on-cap"))] | length' "$s")"
if [ "$n" -eq 1 ]; then pass "idempotent (still one entry)"; else fail "2nd run -> $n entries"; fi

# --- preserves a pre-existing unrelated PreToolUse entry ---
t2="$(mktemp -d)"; s2="$t2/settings.json"
echo '{"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"bash other.sh"}]}]}}' > "$s2"
bash "$REG" "$s2" "$HOOK" --assume-yes >/dev/null 2>&1
if jq -e '.hooks.PreToolUse | map(.hooks[].command) | any(test("other.sh"))' "$s2" >/dev/null; then pass "preserves existing hook"; else fail "clobbered existing hook"; fi
n="$(jq '[.hooks.PreToolUse[]?.hooks[]?.command | select(test("auto-arm-on-cap"))] | length' "$s2")"
if [ "$n" -eq 1 ]; then pass "adds exactly one auto-arm entry"; else fail "expected 1 auto-arm entry, got $n"; fi

# --- missing settings.json -> error rc=1 ---
bash "$REG" "$t/nope.json" "$HOOK" --assume-yes >/dev/null 2>&1
if [ "$?" -eq 1 ]; then pass "missing settings -> rc1"; else fail "missing settings did not rc1"; fi

rm -rf "$t" "$t2"
echo
if [ "$failures" -eq 0 ]; then echo "ALL PASS"; else echo "$failures FAILED"; exit 1; fi
