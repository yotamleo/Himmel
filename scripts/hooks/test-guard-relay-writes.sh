#!/usr/bin/env bash
# Tests for guard-relay-writes.sh (HIMMEL-2975 Task 26, Guard D): the relay's
# write-deny fence on console inbox writes, leg handover docs, the console
# rundir, and the env-override / inbox-send --token Bash shapes that would
# defeat Guards B/C. Every row runs twice — HIMMEL_CONSOLE_RELAY=1 (expect
# the documented rc) and unset (expect a silent allow, rc=0/empty) — to pin
# the marker-gated no-op contract.
#
# Usage: bash scripts/hooks/test-guard-relay-writes.sh
#
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
# Pure bash + jq over a temp sandbox; NOT ported to native PowerShell — see
# guard-relay-writes.sh's own header for why (the relay lane is Linux-only).
set -uo pipefail

grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/guard-relay-writes.sh"
[ -x "$HOOK" ] || chmod +x "$HOOK" 2>/dev/null || true

# Resolve bash ONCE from the suite's own unmodified PATH — see
# test-guard-subagent-model.sh's identical BASH_ABS rationale (HIMMEL-1567).
BASH_ABS=$(command -v bash)
[ -n "$BASH_ABS" ] || { echo "FATAL: cannot resolve bash on PATH" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/himmel-relay-writes-guard.XXXXXX")"
[ -n "$TMP" ] || { echo "FATAL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

ROOT="$TMP/root"
mkdir -p "$ROOT/inbox" "$ROOT/yotamleo/himmel"

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

assert_empty() {
    local label="$1" actual="$2"
    if [ -z "$actual" ]; then
        echo "ok   $label"
        pass=$((pass + 1))
    else
        echo "FAIL $label — expected empty, got: $actual"
        fail=$((fail + 1))
    fi
}

write_payload() {
    # write_payload <tool_name> <file_path>
    jq -nc --arg tn "$1" --arg p "$2" '{tool_name:$tn, tool_input:{file_path:$p}}'
}

bash_payload() {
    jq -nc --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}}'
}

read_payload() {
    jq -nc --arg p "$1" '{tool_name:"Read", tool_input:{file_path:$p}}'
}

run_relay() {
    local name="$1" json="$2"
    printf '%s' "$json" | env HANDOVER_DIR="$ROOT" HIMMEL_CONSOLE_RELAY=1 "$BASH_ABS" "$HOOK" >"$TMP/out-$name" 2>"$TMP/err-$name"
    echo "$?"
}

run_norelay() {
    local name="$1" json="$2"
    printf '%s' "$json" | env -u HIMMEL_CONSOLE_RELAY HANDOVER_DIR="$ROOT" "$BASH_ABS" "$HOOK" >"$TMP/out-$name" 2>"$TMP/err-$name"
    echo "$?"
}

combined_output() {
    cat "$TMP/out-$1" "$TMP/err-$1" 2>/dev/null
}

INBOX_X="$ROOT/inbox/X.md"
LEG_DOC="$ROOT/yotamleo/himmel/HIMMEL-1-a-legN9-2026-09-12-RESUME.md"
RUNDIR_LOG="/run/user/1000/himmel-console/s/inbox-sent.log"
OWN_DOC="$ROOT/yotamleo/himmel/HIMMEL-1-relay-2026-09-12-RESUME.md"
EXTERNAL_LEG_DOC="/home/u/luna/handovers/a-legN3-2026-09-12-RESUME.md"

# name|json|expect_rc_relay|expect_rc_norelay
ROWS_NAME=(row1 row2 row3 row4 row5 row6 row7 row8 row9 row10a row10b row10c row10d row11)
ROWS_JSON=(
    "$(write_payload Write "$INBOX_X")"
    "$(write_payload Edit "$LEG_DOC")"
    "$(write_payload Write "$RUNDIR_LOG")"
    "$(write_payload Edit "$OWN_DOC")"
    "$(bash_payload "echo x >> $ROOT/inbox/X.md")"
    "$(bash_payload "printf x | tee -a $EXTERNAL_LEG_DOC")"
    "$(bash_payload "bash scripts/handover/console-kit/inbox-send.sh S halt")"
    "$(bash_payload "bash scripts/handover/console-kit/inbox-send.sh S go --token t")"
    "$(bash_payload "HIMMEL_CONSOLE_RELAY= bash inbox-send.sh S x")"
    "$(bash_payload "CLAUDE_PID=1 bash x.sh")"
    "$(bash_payload "CONSOLE_SESSION_NAME=j bash x.sh")"
    "$(bash_payload "SESSION_NAME_CMDLINE_FILE=f bash x.sh")"
    "$(bash_payload "env -u HIMMEL_CONSOLE_LEG bash x.sh")"
    "$(bash_payload "cat $ROOT/inbox/X.md")"
)
ROWS_EXPECT=(2 2 2 0 2 2 0 2 2 2 2 2 2 0)

echo "=== marker set (HIMMEL_CONSOLE_RELAY=1) ==="
i=0
while [ "$i" -lt "${#ROWS_NAME[@]}" ]; do
    name="${ROWS_NAME[$i]}"
    json="${ROWS_JSON[$i]}"
    expect="${ROWS_EXPECT[$i]}"
    rc=$(run_relay "relay-$name" "$json")
    assert_rc "relay $name" "$expect" "$rc"
    if [ "$expect" = "2" ]; then
        assert_contains "relay $name deny reason" "relay write-deny:" "$(cat "$TMP/out-relay-$name")"
        assert_contains "relay $name deny decision" '"permissionDecision":"deny"' "$(cat "$TMP/out-relay-$name")"
    else
        assert_empty "relay $name allow: no output" "$(combined_output "relay-$name")"
    fi
    i=$((i + 1))
done

echo ""
echo "=== marker unset — every row is a silent no-op (rc=0, empty) ==="
i=0
while [ "$i" -lt "${#ROWS_NAME[@]}" ]; do
    name="${ROWS_NAME[$i]}"
    json="${ROWS_JSON[$i]}"
    rc=$(run_norelay "norelay-$name" "$json")
    assert_rc "norelay $name" 0 "$rc"
    assert_empty "norelay $name: no output" "$(combined_output "norelay-$name")"
    i=$((i + 1))
done

echo ""
echo "=== fail-closed / non-write edge cases (marker set) ==="

RC_MALFORMED=$(run_relay malformed "not-json{{{")
assert_rc "malformed stdin denies under the marker (rc=2)" 2 "$RC_MALFORMED"
assert_contains "malformed stdin deny reason" "relay write-deny:" "$(cat "$TMP/out-malformed")"

RC_READ=$(run_relay read-tool "$(read_payload "$INBOX_X")")
assert_rc "Read tool on inbox path allows (rc=0)" 0 "$RC_READ"
assert_empty "Read tool: no output" "$(combined_output read-tool)"

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
