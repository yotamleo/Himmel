#!/usr/bin/env bash
# Smoke test for scripts/lib/telemetry.sh (HIMMEL-236).
set -uo pipefail

LIB="$(cd "$(dirname "$0")" && pwd)/telemetry.sh"
# shellcheck source=telemetry.sh
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

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*) echo "PASS $label" ;;
        *) echo "FAIL $label — missing: $needle"; FAILED=$((FAILED + 1)) ;;
    esac
}

FAILED=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export SKILL_TELEMETRY_DIR="$TMP/telemetry"
unset SKILL_TELEMETRY_DISABLE 2>/dev/null || true
LOG="$SKILL_TELEMETRY_DIR/skill-usage.jsonl"

# T1: basic emit — rc 0, exactly one line, no stdout output
out=$(telemetry_emit test-skill test-event)
rc=$?
assert_eq "T1 emit rc=0" 0 "$rc"
assert_eq "T1 emit is silent on stdout" "" "$out"
assert_eq "T1 one line appended" 1 "$(wc -l < "$LOG" | tr -d ' ')"

# T2: record carries the required fields
line=$(tail -1 "$LOG")
assert_contains "T2 has version" '"v":1' "$line"
assert_contains "T2 has ts" '"ts":"' "$line"
assert_contains "T2 has session_id" '"session_id":"' "$line"
assert_contains "T2 has repo" '"repo":"' "$line"
assert_contains "T2 has skill" '"skill":"test-skill"' "$line"
assert_contains "T2 has event" '"event":"test-event"' "$line"

# T3: extra key=value pairs land as fields; appends accumulate
telemetry_emit test-skill armed time=09:30 force=0
line=$(tail -1 "$LOG")
assert_contains "T3 extra kv time" '"time":"09:30"' "$line"
assert_contains "T3 extra kv force" '"force":"0"' "$line"
assert_eq "T3 two lines total" 2 "$(wc -l < "$LOG" | tr -d ' ')"

# T4: values with quotes/backslashes are escaped — record stays valid JSON
telemetry_emit test-skill weird 'note=he said "hi" c:\path'
line=$(tail -1 "$LOG")
assert_contains "T4 quote escaped" 'he said \"hi\"' "$line"
assert_contains "T4 backslash escaped" 'c:\\path' "$line"
if command -v node >/dev/null 2>&1; then
    if printf '%s' "$line" | node -e 'JSON.parse(require("fs").readFileSync(0,"utf8"))' 2>/dev/null; then
        echo "PASS T4 record parses as JSON"
    else
        echo "FAIL T4 record is not valid JSON: $line"
        FAILED=$((FAILED + 1))
    fi
else
    echo "SKIP T4 JSON parse check (node not found)"
fi

# T5: CLAUDE_SESSION_ID is recorded when set; "-" otherwise
CLAUDE_SESSION_ID=abc-123 telemetry_emit test-skill withsession
assert_contains "T5 session recorded" '"session_id":"abc-123"' "$(tail -1 "$LOG")"
telemetry_emit test-skill nosession
assert_contains "T5 fallback dash" '"session_id":"-"' "$(tail -1 "$LOG")"

# T6: kill switch suppresses the append, rc still 0
before=$(wc -l < "$LOG" | tr -d ' ')
SKILL_TELEMETRY_DISABLE=1 telemetry_emit test-skill suppressed
rc=$?
assert_eq "T6 disabled rc=0" 0 "$rc"
assert_eq "T6 disabled appends nothing" "$before" "$(wc -l < "$LOG" | tr -d ' ')"

# T7: missing skill/event → quiet no-op, rc 0 (fail-open)
telemetry_emit "" missing-skill
rc=$?
assert_eq "T7 empty skill rc=0" 0 "$rc"
telemetry_emit only-skill
rc=$?
assert_eq "T7 missing event rc=0" 0 "$rc"
assert_eq "T7 nothing appended" "$before" "$(wc -l < "$LOG" | tr -d ' ')"

# T8: unwritable sink → rc 0, no crash (fail-open under set -e callers)
SKILL_TELEMETRY_DIR="$TMP/blocked/nested" : # path whose parent we make a file
: > "$TMP/blocked"
SKILL_TELEMETRY_DIR="$TMP/blocked/nested" telemetry_emit test-skill blocked
rc=$?
assert_eq "T8 unwritable sink rc=0" 0 "$rc"

# T9: malformed extra arg (no '=') is skipped, record still written
telemetry_emit test-skill partial notakv good=1
line=$(tail -1 "$LOG")
assert_contains "T9 good kv kept" '"good":"1"' "$line"
case "$line" in
    *notakv*) echo "FAIL T9 malformed kv leaked into record"; FAILED=$((FAILED + 1)) ;;
    *) echo "PASS T9 malformed kv skipped" ;;
esac

# Helper for T10/T11: assert a single record parses as JSON (node-gated).
assert_json() {
    local label="$1" record="$2"
    if command -v node >/dev/null 2>&1; then
        if printf '%s' "$record" | node -e 'JSON.parse(require("fs").readFileSync(0,"utf8"))' 2>/dev/null; then
            echo "PASS $label"
        else
            echo "FAIL $label — not valid JSON: $record"
            FAILED=$((FAILED + 1))
        fi
    else
        echo "SKIP $label (node not found)"
    fi
}

# T10: embedded newline/CR/tab cannot break JSONL framing — exactly ONE
# line appended, record stays valid JSON (the escape class that would
# otherwise corrupt the whole sink file)
before=$(wc -l < "$LOG" | tr -d ' ')
telemetry_emit test-skill multiline "note=$(printf 'a\nb\tc\rd')"
assert_eq "T10 one line appended despite newline/CR/tab" $((before + 1)) "$(wc -l < "$LOG" | tr -d ' ')"
line=$(tail -1 "$LOG")
assert_contains "T10 newline/CR/tab flattened to spaces" '"note":"a b c d"' "$line"
assert_json "T10 record parses as JSON" "$line"

# T11: other C0 control chars (ESC, vertical tab, backspace, form feed,
# unit separator) are stripped — verbatim they'd be invalid JSON and
# silently poison the shared sink
telemetry_emit test-skill ctrlchars "note=$(printf 'a\033b\013c\010d\014e\037f')"
line=$(tail -1 "$LOG")
assert_contains "T11 C0 controls stripped" '"note":"abcdef"' "$line"
case "$line" in
    *$'\x1b'*|*$'\x0b'*|*$'\x08'*|*$'\x0c'*|*$'\x1f'*)
        echo "FAIL T11 raw control char leaked into record"; FAILED=$((FAILED + 1)) ;;
    *) echo "PASS T11 no raw control char in record" ;;
esac
assert_json "T11 record parses as JSON" "$line"

# T12: kill switch treats any non-empty value as disable (HIMMEL-375) —
# "true" and "yes" are common env values that the old "= 1" check silently
# ignored. rc must still be 0 (fail-open) and no line appended.
before=$(wc -l < "$LOG" | tr -d ' ')
SKILL_TELEMETRY_DISABLE=true telemetry_emit test-skill suppressed-true
rc=$?
assert_eq "T12 disable=true rc=0" 0 "$rc"
assert_eq "T12 disable=true appends nothing" "$before" "$(wc -l < "$LOG" | tr -d ' ')"
SKILL_TELEMETRY_DISABLE=yes telemetry_emit test-skill suppressed-yes
rc=$?
assert_eq "T12 disable=yes rc=0" 0 "$rc"
assert_eq "T12 disable=yes appends nothing" "$before" "$(wc -l < "$LOG" | tr -d ' ')"

# T13: caller-supplied key=value pairs whose key collides with a reserved
# field (v, ts, session_id, repo, skill, event) are silently skipped —
# they must not produce duplicate JSON keys that break the JSONL sink
# (HIMMEL-374). The non-colliding pair must still land.
telemetry_emit test-skill no-collision v=99 ts=bad session_id=injected repo=fake skill=override event=override extra=kept
line=$(tail -1 "$LOG")
assert_contains "T13 non-colliding pair kept" '"extra":"kept"' "$line"
# The caller-supplied overrides of reserved fields must NOT appear as values.
# (The system writes v=1; the caller tried v=99 — "99" must not appear.)
case "$line" in
    *'"v":99'*|*'"v":"99"'*) echo "FAIL T13 caller v=99 leaked into record"; FAILED=$((FAILED + 1)) ;;
    *)                        echo "PASS T13 reserved key v not duplicated" ;;
esac
# skill= and event= are the likeliest real collision vectors.
case "$line" in
    *'"skill":"override"'*) echo "FAIL T13 caller skill=override leaked"; FAILED=$((FAILED + 1)) ;;
    *)                      echo "PASS T13 reserved key skill not duplicated" ;;
esac
case "$line" in
    *'"event":"override"'*) echo "FAIL T13 caller event=override leaked"; FAILED=$((FAILED + 1)) ;;
    *)                      echo "PASS T13 reserved key event not duplicated" ;;
esac

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "test-telemetry: ALL PASS"
    exit 0
else
    echo "test-telemetry: $FAILED FAILURE(S)"
    exit 1
fi
