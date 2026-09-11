#!/usr/bin/env bash
# Smoke suite for scripts/hooks/block-leg-askuserquestion.sh (HIMMEL-2923):
# a console-spawned leg (HIMMEL_CONSOLE_LEG=1, set by HIMMEL-2919's launcher)
# calling AskUserQuestion is denied — nobody answers in that window. Covers:
# marker+tool -> deny, marker unset -> allow, marker+other tool -> allow,
# malformed/empty stdin -> allow (fail-open; a hook crash must never lock an
# operator out).
#
# bash 3.2-safe. Platform guard (gitbash-only): plain env var + jq checks, no
# git/path work; runs unchanged under Git Bash on Windows. No .ps1 twin needed.
set -uo pipefail

HOOKS="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HOOKS/block-leg-askuserquestion.sh"
[ -f "$HOOK" ] || { echo "hook not found: $HOOK" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

# check <label> <block|allow> <json> [ENV=val ...]
check() {
    local label="$1" expect="$2" json="$3"; shift 3
    local rc got
    printf '%s' "$json" | env "$@" bash "$HOOK" >/dev/null 2>&1
    rc=$?
    case "$rc" in
        0) got=allow ;;
        2) got=block ;;
        *) got="?(rc=$rc)" ;;
    esac
    if [ "$got" = "$expect" ]; then ok "$label"; else
        bad "$label - expected $expect got $got"; fi
}

echo "== marker set + AskUserQuestion -> deny =="
check "marker + AskUserQuestion -> deny" block \
    '{"tool_name":"AskUserQuestion","tool_input":{"questions":[]}}' \
    HIMMEL_CONSOLE_LEG=1
out="$(printf '%s' '{"tool_name":"AskUserQuestion","tool_input":{"questions":[]}}' | env HIMMEL_CONSOLE_LEG=1 bash "$HOOK" 2>&1 >/dev/null)"
case "$out" in
    *SendMessage*HIMMEL-2923*) ok "deny text names SendMessage and the ticket" ;;
    *) bad "deny text missing SendMessage/HIMMEL-2923 - got: $out" ;;
esac

echo "== marker unset -> allow (operator sessions keep the tool) =="
check "no marker + AskUserQuestion -> allow" allow \
    '{"tool_name":"AskUserQuestion","tool_input":{"questions":[]}}'

echo "== marker set + a different tool_name -> allow =="
check "marker + Write -> allow" allow \
    '{"tool_name":"Write","tool_input":{"file_path":"x.txt"}}' \
    HIMMEL_CONSOLE_LEG=1

echo "== malformed/empty stdin -> allow (fail-open) =="
check "marker + malformed JSON -> allow" allow \
    '{not json' \
    HIMMEL_CONSOLE_LEG=1
check "marker + empty stdin -> allow" allow \
    '' \
    HIMMEL_CONSOLE_LEG=1

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
