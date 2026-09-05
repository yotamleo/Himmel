#!/usr/bin/env bash
# Paired smoke test for scripts/glm/append-outbox.sh (HIMMEL-1649).
# Usage: bash scripts/glm/test-append-outbox.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/append-outbox.sh"
FIXTURE=$(mktemp -d -t glm-append-outbox.XXXXXX)
OWN_SESSION="$FIXTURE/glm-sessions/glm-own-1"
WRONG_PARENT="$FIXTURE/not-glm-sessions/glm-own-1"
mkdir -p "$OWN_SESSION" "$WRONG_PARENT"
trap 'rm -rf "$FIXTURE"' EXIT

native_dir() {
    (cd "$1" && pwd -W 2>/dev/null) || (cd "$1" && pwd -P)
}

OWN_SESSION_NATIVE=$(native_dir "$OWN_SESSION")
FAILED=0
CASES=0
EXPECTED_CASES=23

run_helper() {
    local session="$1"
    shift
    if [ "$session" = "<unset>" ]; then
        env -u GLM_SESSION_DIR bash "$HELPER" "$@" >/dev/null 2>&1
    else
        env -u GLM_SESSION_DIR "GLM_SESSION_DIR=$session" bash "$HELPER" "$@" >/dev/null 2>&1
    fi
    echo "$?"
}

assert_rc() {
    local label="$1" expected="$2" actual="$3"
    CASES=$((CASES + 1))
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label (rc=$actual)"
    else
        echo "FAIL $label - expected rc=$expected, got rc=$actual"
        FAILED=$((FAILED + 1))
    fi
}

assert_last_text() {
    local label="$1" expected="$2" file="$3"
    CASES=$((CASES + 1))
    if [ -f "$file" ] && tail -1 "$file" | jq -e --arg expected "$expected" '.text == $expected' >/dev/null 2>&1; then
        echo "PASS $label"
    else
        echo "FAIL $label - appended JSONL text did not match"
        FAILED=$((FAILED + 1))
    fi
}

TEXT=$(printf 'progress "quoted"\nnext line')
PAYLOAD=$(node -e 'process.stdout.write(Buffer.from(process.argv[1], "utf8").toString("base64url"))' "$TEXT")
assert_rc "valid session and payload append" 0 "$(run_helper "$OWN_SESSION_NATIVE" "$PAYLOAD")"
assert_last_text "appended line is correct JSON text" "$TEXT" "$OWN_SESSION/outbox.jsonl"
assert_rc "missing GLM_SESSION_DIR denied" 2 "$(run_helper '<unset>' "$PAYLOAD")"
assert_rc "relative GLM_SESSION_DIR denied" 2 "$(run_helper 'relative/glm-sessions/glm-own-1' "$PAYLOAD")"
assert_rc "wrong parent directory denied" 2 "$(run_helper "$WRONG_PARENT" "$PAYLOAD")"
assert_rc "non-base64url token denied" 2 "$(run_helper "$OWN_SESSION_NATIVE" 'abc=')"
assert_rc "base64url length decode failure denied" 2 "$(run_helper "$OWN_SESSION_NATIVE" 'A')"
assert_rc "non-UTF-8 decoded payload denied" 2 "$(run_helper "$OWN_SESSION_NATIVE" '_w')"
OVERSIZE=$(node -e 'process.stdout.write("a".repeat(16385))')
assert_rc "oversize token denied" 2 "$(run_helper "$OWN_SESSION_NATIVE" "$OVERSIZE")"
assert_rc "missing payload argument denied" 2 "$(env -u GLM_SESSION_DIR GLM_SESSION_DIR="$OWN_SESSION_NATIVE" bash "$HELPER" >/dev/null 2>&1; echo $?)"
assert_rc "extra payload argument denied" 2 "$(env -u GLM_SESSION_DIR GLM_SESSION_DIR="$OWN_SESSION_NATIVE" bash "$HELPER" "$PAYLOAD" extra >/dev/null 2>&1; echo $?)"

# --- HIMMEL-1649 round 3: schema LOCKSTEP with block-glm-external-writes.sh ---
# This helper is the OFF-LANE implementation of the hook's payload contract. A
# divergence means an off-lane worker writes records the adjudicator cannot
# read — which is exactly what the previous revision did by hardcoding {text}
# and silently dropping every structured escalation.
b64url() { node -e 'process.stdout.write(Buffer.from(process.argv[1],"utf8").toString("base64url"))' "$1"; }
assert_last_json() {
    local label="$1" filter="$2" file="$3"
    CASES=$((CASES + 1))
    if [ -f "$file" ] && tail -1 "$file" | jq -e "$filter" >/dev/null 2>&1; then
        echo "PASS $label"
    else
        echo "FAIL $label - last record does not satisfy: $filter"
        FAILED=$((FAILED + 1))
    fi
}
ESC_OK=$(b64url '{"type":"escalation","capability":"git push","arm":"git-push","reason":"no arm","step":"7"}')
assert_rc "structured escalation accepted" 0 "$(run_helper "$OWN_SESSION_NATIVE" "$ESC_OK")"
assert_last_json "escalation keeps type/arm and gains a stamped ts" '.type == "escalation" and .arm == "git-push" and (.ts | type) == "string"' "$OWN_SESSION/outbox.jsonl"
SCALAR=$(b64url '123')
assert_rc "bare scalar note-wrapped, not refused" 0 "$(run_helper "$OWN_SESSION_NATIVE" "$SCALAR")"
assert_last_json "bare scalar becomes a note verbatim" '.type == "note" and .text == "123"' "$OWN_SESSION/outbox.jsonl"
assert_rc "unknown structured type denied" 2 "$(run_helper "$OWN_SESSION_NATIVE" "$(b64url '{"type":"grant","text":"x"}')")"
assert_rc "unknown key denied" 2 "$(run_helper "$OWN_SESSION_NATIVE" "$(b64url '{"type":"note","text":"x","evil":1}')")"
assert_rc "non-string escalation field denied" 2 "$(run_helper "$OWN_SESSION_NATIVE" "$(b64url '{"type":"escalation","capability":1,"arm":"gh","reason":"r","step":"s"}')")"
# Consecutive-duplicate suppression, same rule as the hook.
DUP=$(b64url 'dup me')
assert_rc "first duplicate-probe send accepted" 0 "$(run_helper "$OWN_SESSION_NATIVE" "$DUP")"
dup_n1=$(wc -l < "$OWN_SESSION/outbox.jsonl")
assert_rc "immediate resend accepted (suppressed)" 0 "$(run_helper "$OWN_SESSION_NATIVE" "$DUP")"
dup_n2=$(wc -l < "$OWN_SESSION/outbox.jsonl")
CASES=$((CASES + 1))
if [ "$dup_n2" -eq "$dup_n1" ]; then
    echo "PASS consecutive duplicate appended no second row"
else
    echo "FAIL consecutive duplicate appended a row ($dup_n1 -> $dup_n2)"
    FAILED=$((FAILED + 1))
fi

# HIMMEL-1649 round 4 [codex-adv-r4-1] — torn JSONL tail, lockstep with the hook.
# An interrupted earlier append leaves the file ending mid-line. Appending
# straight onto it would CONCATENATE this record into that partial line, and a
# consumer that skips invalid lines then loses BOTH — while the caller is told
# the report was saved. The new record must land independently parseable.
TORN_SESSION="$FIXTURE/glm-sessions/glm-torn-9"
mkdir -p "$TORN_SESSION"
TORN_SESSION_NATIVE=$(native_dir "$TORN_SESSION")
printf '{"type":"note","text":"interrupted mid-write"' > "$TORN_SESSION/outbox.jsonl"
assert_rc "append after a torn tail accepted" 0 \
    "$(run_helper "$TORN_SESSION_NATIVE" "$(b64url 'after the torn tail')")"
CASES=$((CASES + 1))
if tail -1 "$TORN_SESSION/outbox.jsonl" | jq -e '.type == "note" and .text == "after the torn tail"' >/dev/null 2>&1; then
    echo "PASS torn tail did not swallow the next record"
else
    echo "FAIL torn tail swallowed the next record - last line is not independently parseable"
    FAILED=$((FAILED + 1))
fi

if [ "$FAILED" -ne 0 ]; then
    echo "$FAILED case(s) FAILED"
    exit 1
fi
if [ "$CASES" -ne "$EXPECTED_CASES" ]; then
    echo "CASE-COUNT MISMATCH - ran $CASES, expected $EXPECTED_CASES"
    exit 1
fi
echo "all cases passed ($CASES/$EXPECTED_CASES)"
exit 0
