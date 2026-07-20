#!/usr/bin/env bash
# scripts/cr/test-advisory-rows.sh — guard for HIMMEL-1221 G3: the minerva
# advisory panel enumeration prefers FREE rows but falls back to PAID rows when
# the registry has NO free rows (instead of an empty panel → claude-only). Tests
# the real helper minerva calls, so a regression in it (or in the behavior) is
# caught. Hermetic, bash 3.2 safe.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HELPER="$HERE/advisory-rows.sh"
tmp="$(mktemp -d)"
# shellcheck disable=SC2064
trap "rm -rf $tmp" EXIT
fails=0

check() {
    if [ "$2" = "$3" ]; then echo "ok - $1"; else
        echo "FAIL - $1: got [$2] want [$3]"; fails=$((fails + 1)); fi
}

# Paid-only registry → paid rows enumerated (the real himmel case: codex+glm).
printf '%s' '{"panel":[
  {"slug":"codex","model":"gpt-5.5","tier":"paid"},
  {"slug":"glm","model":"glm-5.2","tier":"paid"}]}' > "$tmp/paid.json"
out_paid="$(bash "$HELPER" "$tmp/paid.json")"
check "paid-only: codex enumerated" "$(printf '%s\n' "$out_paid" | grep -c '^codex	gpt-5.5$')" "1"
check "paid-only: glm enumerated"   "$(printf '%s\n' "$out_paid" | grep -c '^glm	glm-5.2$')" "1"
check "paid-only: exactly 2 rows"   "$(printf '%s\n' "$out_paid" | grep -c '	')" "2"

# Registry WITH a free row → only the free row(s), paid suppressed.
printf '%s' '{"panel":[
  {"slug":"codex","model":"gpt-5.5","tier":"paid"},
  {"slug":"glm","model":"glm-5.2","tier":"paid"},
  {"slug":"freebie","model":"m/free","tier":"free"}]}' > "$tmp/mixed.json"
out_mixed="$(bash "$HELPER" "$tmp/mixed.json")"
check "free-present: free row enumerated"  "$(printf '%s\n' "$out_mixed" | grep -c '^freebie	m/free$')" "1"
check "free-present: paid codex suppressed" "$(printf '%s\n' "$out_mixed" | grep -c 'codex')" "0"
check "free-present: paid glm suppressed"   "$(printf '%s\n' "$out_mixed" | grep -c 'glm')" "0"

# Empty / unreadable registry → empty output (no crash).
printf '%s' '{"panel":[]}' > "$tmp/empty.json"
out_empty="$(bash "$HELPER" "$tmp/empty.json")"
check "empty registry: no rows" "$(printf '%s' "$out_empty" | wc -c | tr -d '[:space:]')" "0"

if [ "$fails" -eq 0 ]; then
    echo "ALL PASS"
else
    echo "$fails FAILED"
    exit 1
fi
