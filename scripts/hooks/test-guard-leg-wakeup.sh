#!/usr/bin/env bash
# Smoke suite for scripts/hooks/guard-leg-wakeup.sh (HIMMEL-3034): a
# console-spawned leg (HIMMEL_CONSOLE_LEG=1, set by headed-arm-leg.sh) calling
# ScheduleWakeup is denied — each self-scheduled wake re-reads the leg's whole
# context to find "not yet". Covers: marker+tool -> deny with a `leg wakeup-deny:`
# reason, marker unset / not "1" -> allow with ZERO output (context cost 0 for a
# non-leg), marker+other tool -> allow with zero output, malformed/empty stdin ->
# allow (fail-open; a hook crash must never lock an operator out).
#
# HIMMEL_CONSOLE_LEG is set/unset explicitly per case (this suite itself is
# usually run from inside a leg, which already exports it): every case runs under
# `env -u HIMMEL_CONSOLE_LEG` first, so an inherited marker never leaks in.
#
# bash 3.2-safe. Platform guard (gitbash-only): plain env var + jq checks, no
# git/path work; runs unchanged under Git Bash on Windows. No .ps1 twin needed.
set -uo pipefail

HOOKS="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HOOKS/guard-leg-wakeup.sh"
[ -f "$HOOK" ] || { echo "hook not found: $HOOK" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

WAKE='{"tool_name":"ScheduleWakeup","tool_input":{"delaySeconds":270,"prompt":"x","reason":"poll"}}'

# check <label> <block|allow> <json> [ENV=val ...]
check() {
    local label="$1" expect="$2" json="$3"; shift 3
    local rc got
    printf '%s' "$json" | env -u HIMMEL_CONSOLE_LEG "$@" bash "$HOOK" >/dev/null 2>&1
    rc=$?
    case "$rc" in
        0) got=allow ;;
        2) got=block ;;
        *) got="?(rc=$rc)" ;;
    esac
    if [ "$got" = "$expect" ]; then ok "$label"; else
        bad "$label - expected $expect got $got"; fi
}

# silent <label> <json> [ENV=val ...] — allow path must add zero stdout AND stderr.
silent() {
    local label="$1" json="$2"; shift 2
    local out
    out="$(printf '%s' "$json" | env -u HIMMEL_CONSOLE_LEG "$@" bash "$HOOK" 2>&1)"
    if [ -z "$out" ]; then ok "$label"; else
        bad "$label - expected no output, got: $out"; fi
}

echo "== marker set + ScheduleWakeup -> deny =="
check "marker + ScheduleWakeup -> deny" block "$WAKE" HIMMEL_CONSOLE_LEG=1
out="$(printf '%s' "$WAKE" | env -u HIMMEL_CONSOLE_LEG HIMMEL_CONSOLE_LEG=1 bash "$HOOK" 2>/dev/null)"
reason="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)"
case "$reason" in
    "leg wakeup-deny: "*) ok "stdout JSON reason starts with 'leg wakeup-deny: '" ;;
    *) bad "stdout JSON reason not 'leg wakeup-deny: ...' - got: $out" ;;
esac
case "$reason" in
    *"check-ci.sh <pr> --max-wait"*HIMMEL-3034*) ok "reason names the foreground replacement and the ticket" ;;
    *) bad "reason missing 'check-ci.sh <pr> --max-wait' / HIMMEL-3034 - got: $reason" ;;
esac
decision="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)"
if [ "$decision" = "deny" ]; then ok "permissionDecision is deny"; else
    bad "permissionDecision not deny - got: $decision"; fi
err="$(printf '%s' "$WAKE" | env -u HIMMEL_CONSOLE_LEG HIMMEL_CONSOLE_LEG=1 bash "$HOOK" 2>&1 >/dev/null)"
case "$err" in
    "leg wakeup-deny: "*) ok "stderr carries the same deny text" ;;
    *) bad "stderr not 'leg wakeup-deny: ...' - got: $err" ;;
esac

echo "== marker unset / not 1 -> allow, zero output (context cost 0) =="
check "no marker + ScheduleWakeup -> allow" allow "$WAKE"
silent "no marker + ScheduleWakeup -> no output" "$WAKE"
check "marker=0 + ScheduleWakeup -> allow" allow "$WAKE" HIMMEL_CONSOLE_LEG=0
silent "marker=0 + ScheduleWakeup -> no output" "$WAKE" HIMMEL_CONSOLE_LEG=0
check "marker empty + ScheduleWakeup -> allow" allow "$WAKE" HIMMEL_CONSOLE_LEG=

echo "== marker set + a different tool_name -> allow, zero output =="
check "marker + Write -> allow" allow \
    '{"tool_name":"Write","tool_input":{"file_path":"x.txt"}}' HIMMEL_CONSOLE_LEG=1
silent "marker + Write -> no output" \
    '{"tool_name":"Write","tool_input":{"file_path":"x.txt"}}' HIMMEL_CONSOLE_LEG=1
check "marker + Bash -> allow" allow \
    '{"tool_name":"Bash","tool_input":{"command":"sleep 1"}}' HIMMEL_CONSOLE_LEG=1

echo "== malformed/empty stdin -> allow (fail-open) =="
check "marker + malformed JSON -> allow" allow '{not json' HIMMEL_CONSOLE_LEG=1
check "marker + empty stdin -> allow" allow '' HIMMEL_CONSOLE_LEG=1
silent "marker + malformed JSON -> no output" '{not json' HIMMEL_CONSOLE_LEG=1

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
