#!/usr/bin/env bash
# Tests for scripts/hooks/block-subagent-park.sh (HIMMEL-2140).
#
# Usage: bash scripts/hooks/test-block-subagent-park.sh
#
# Every case below feeds a real payload to the REAL hook script and asserts
# on ITS exit status / output — none of this replicates the hook's own logic
# (a control that just re-implements the gate proves nothing: delete the gate
# and it still passes).
set -uo pipefail

grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/block-subagent-park.sh"
[ -x "$HOOK" ] || chmod +x "$HOOK" 2>/dev/null || true

BASH_ABS=$(command -v bash)
if [ -z "$BASH_ABS" ]; then
    echo "FATAL: cannot resolve bash on PATH" >&2
    exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/himmel-subagent-park.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

assert_rc() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "ok   $label (rc=$actual)"
        pass=$((pass + 1))
    else
        echo "FAIL $label — expected rc=$expected, got rc=$actual"
        fail=$((fail + 1))
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if grepq "$haystack" -F "$needle"; then
        echo "ok   $label"
        pass=$((pass + 1))
    else
        echo "FAIL $label — missing '$needle'"
        echo "  actual: $haystack"
        fail=$((fail + 1))
    fi
}

run_hook() {  # run_hook <name> <json> [env...] — writes out-<name>/err-<name>, echoes rc
    local name="$1" json="$2"; shift 2
    printf '%s' "$json" | env "$@" "$BASH_ABS" "$HOOK" \
        >"$TMP/out-$name" 2>"$TMP/err-$name"
    echo "$?"
}

combined_output() { cat "$TMP/out-$1" "$TMP/err-$1" 2>/dev/null; }

SUBAGENT_BG='{"agent_id":"sub-1","tool_name":"Bash","tool_input":{"command":"sleep 300","run_in_background":true}}'
SUBAGENT_MONITOR='{"agent_id":"sub-1","tool_name":"Monitor","tool_input":{}}'
MAIN_BG='{"tool_name":"Bash","tool_input":{"command":"sleep 300","run_in_background":true}}'
SUBAGENT_FG='{"agent_id":"sub-1","tool_name":"Bash","tool_input":{"command":"echo hi"}}'

echo "=== DENY: subagent parking ==="

RC1=$(run_hook subagent-bg-denied "$SUBAGENT_BG")
assert_rc "1. subagent + Bash run_in_background:true -> DENIED" 2 "$RC1"

RC2=$(run_hook subagent-monitor-denied "$SUBAGENT_MONITOR")
assert_rc "2. subagent + Monitor -> DENIED" 2 "$RC2"

echo "=== ALLOW: the required non-vacuous controls ==="

RC3=$(run_hook main-bg-allowed "$MAIN_BG")
assert_rc "3. main-thread (no agent_id) + Bash run_in_background:true -> ALLOWED (parent asymmetry)" 0 "$RC3"

RC4=$(run_hook subagent-fg-allowed "$SUBAGENT_FG")
assert_rc "4. subagent + Bash WITHOUT run_in_background -> ALLOWED (deny is not vacuously broad)" 0 "$RC4"

echo "=== Deny message names the alternative (not a bare 'no') ==="

DENY_TEXT="$(combined_output subagent-bg-denied)"
assert_contains "5a. message says FOREGROUND" "FOREGROUND" "$DENY_TEXT"
assert_contains "5b. message names the 600000 ms timeout ceiling" "600000 ms" "$DENY_TEXT"
assert_contains "5c. message names scripts/quiet-run.sh for genuinely long work" "scripts/quiet-run.sh" "$DENY_TEXT"
assert_contains "5d. message says BOUNDED polls, never unbounded" "BOUNDED" "$DENY_TEXT"

# CR round 1 (HIMMEL-2140): a MALFORMED agent_id must ALLOW, not deny.
# The documented contract is an identifier string; `true`/`123`/`{}`/"" are
# contract violations, and this hook fails OPEN on anything it cannot read
# (missing jq, empty stdin) -- a malformed payload belongs in that bucket.
# These also pin the opposite trap: the original `.agent_id // empty`
# extraction swallowed `false` as absent, and a naive "any present value"
# fix would have made all of these DENY. Only a non-empty STRING denies.
for bad in 'true' '123' '{}' '""'; do
    RC_BAD=$(run_hook "subagent-malformed-id"         "{\"agent_id\":$bad,\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"x\",\"run_in_background\":true}}")
    assert_rc "6. malformed agent_id ($bad) -> ALLOWED (fail-open, not a subagent signal)" 0 "$RC_BAD"
done

echo "=== Red-before-green: SUBAGENT_PARK_GUARD_DISABLE=1 must un-deny the same payloads ==="

RC1_DISABLED=$(run_hook subagent-bg-disabled "$SUBAGENT_BG" SUBAGENT_PARK_GUARD_DISABLE=1)
assert_rc "red: kill switch allows the Bash run_in_background case (proves the test exercises the real gate)" 0 "$RC1_DISABLED"

RC2_DISABLED=$(run_hook subagent-monitor-disabled "$SUBAGENT_MONITOR" SUBAGENT_PARK_GUARD_DISABLE=1)
assert_rc "red: kill switch allows the Monitor case (proves the test exercises the real gate)" 0 "$RC2_DISABLED"

echo "=== Fail-open sanity (workflow nudge, not a security fence) ==="

RC_MALFORMED=$(printf 'not json' | env "$BASH_ABS" "$HOOK" >"$TMP/out-malformed" 2>"$TMP/err-malformed"; echo $?)
assert_rc "malformed JSON on stdin allows" 0 "$RC_MALFORMED"

RC_EMPTY=$(printf '' | env "$BASH_ABS" "$HOOK" >"$TMP/out-empty" 2>"$TMP/err-empty"; echo $?)
assert_rc "empty stdin allows" 0 "$RC_EMPTY"

STUB_NOJQ_DIR="$TMP/stub-no-jq"
mkdir -p "$STUB_NOJQ_DIR"
STUB_PATH_NO_JQ=$(printf '%s' "$PATH" | tr ':' '\n' | while IFS= read -r _d; do
    [ -n "$_d" ] || continue
    [ -x "$_d/jq" ] || [ -x "$_d/jq.exe" ] || printf '%s\n' "$_d"
done | tr '\n' ':')
RC_NOJQ=$(printf '%s' "$SUBAGENT_BG" | env PATH="$STUB_PATH_NO_JQ" "$BASH_ABS" "$HOOK" >"$TMP/out-nojq" 2>"$TMP/err-nojq"; echo $?)
assert_rc "jq absent allows (fail-open)" 0 "$RC_NOJQ"

echo ""
echo "$((pass + fail)) checks, $pass passed, $fail failed"
if [ "$fail" -eq 0 ]; then
    echo "SUMMARY: All block-subagent-park.sh cases passed."
    exit 0
else
    echo "SUMMARY: $fail case(s) failed."
    exit 1
fi
