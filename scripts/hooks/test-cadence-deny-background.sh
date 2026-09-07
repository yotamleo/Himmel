#!/usr/bin/env bash
# Smoke test for scripts/hooks/cadence-deny-background.sh (HIMMEL-1682 S2b).
#
# Usage: bash scripts/hooks/test-cadence-deny-background.sh
#
# Contract under test:
#   * DENY → a Bash call with tool_input.run_in_background == true exits 2 and
#            names the foreground alternative on stderr.
#   * PASS → everything else exits 0 with no deny (foreground commands, non-Bash
#            tools, the string "true" instead of boolean true, missing jq, or
#            unparseable input — all fail OPEN so a parse hiccup never blocks the
#            cadence).
#
# The load-bearing cases for the S2b fix:
#   - a run_in_background attempt IS denied under the cadence profile (the
#     silent-park failure converted to a same-turn foreground retry);
#   - a normal foreground command is still allowed through (so the deny does not
#     break the cadence's real work).
#
# Exit codes:
#   0 — all cases passed
#   1 — at least one case failed
set -uo pipefail

grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

HOOK="$(cd "$(dirname "$0")" && pwd)/cadence-deny-background.sh"
[ -x "$HOOK" ] || chmod +x "$HOOK"

FAILED=0
ERR_TMP="$(mktemp "${TMPDIR:-/tmp}/cadence-deny-background.XXXXXX")"
trap 'rm -f "$ERR_TMP"' EXIT

# decide <json> → DENY if the hook exited 2 AND stderr carries the redirect
# message; else PASS. Captures stderr to ERR_TMP (no pipe → no pipefail trap).
decide() {
    local rc
    printf '%s' "$1" | bash "$HOOK" 2>"$ERR_TMP" >/dev/null
    rc=$?
    if [ "$rc" -eq 2 ] && grepq "$(cat "$ERR_TMP")" 'foreground'; then
        echo "DENY"
    else
        echo "PASS"
    fi
}

assert() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label ($actual)"
    else
        echo "FAIL $label — expected $expected, got $actual"
        FAILED=$((FAILED + 1))
    fi
}

# --- DENY: a backgrounded Bash call under the cadence profile ---
assert "background find"          DENY "$(decide '{"tool_name":"Bash","tool_input":{"command":"find . -name x","run_in_background":true}}')"
assert "background media fetch"   DENY "$(decide '{"tool_name":"Bash","tool_input":{"command":"curl -s http://x/y","run_in_background":true}}')"
assert "background + extra field" DENY "$(decide '{"tool_name":"Bash","tool_input":{"command":"echo hi","run_in_background":true,"timeout":30000}}')"

# --- PASS: foreground and non-applicable (the deny must not over-reach) ---
assert "foreground find"          PASS "$(decide '{"tool_name":"Bash","tool_input":{"command":"find . -name x"}}')"
assert "explicit false"           PASS "$(decide '{"tool_name":"Bash","tool_input":{"command":"echo hi","run_in_background":false}}')"
assert "string true not boolean"  PASS "$(decide '{"tool_name":"Bash","tool_input":{"command":"echo hi","run_in_background":"true"}}')"
assert "non-Bash background"      PASS "$(decide '{"tool_name":"Read","tool_input":{"command":"x","run_in_background":true}}')"
assert "empty input"              PASS "$(decide '')"

if [ "$FAILED" -eq 0 ]; then
    echo "OK cadence-deny-background: all cases passed"
    exit 0
fi
echo "ERR cadence-deny-background: $FAILED case(s) failed" >&2
exit 1
