#!/usr/bin/env bash
# guard-leg-wakeup.sh — PreToolUse hook (matcher "ScheduleWakeup"): denies
# ScheduleWakeup for a console-spawned leg (HIMMEL-3034). A leg launched headed
# by a console (scripts/handover/console-kit/headed-arm-leg.sh exports
# HIMMEL_CONSOLE_LEG=1 in the launching shell) has no reason to self-schedule a
# polling wakeup: every wake re-reads the leg's whole context just to find "not
# yet" (cost program HIMMEL-2763), and a leg waits with ONE foreground blocking
# command anyway (docs/handover/leg-preface.md). Same shape as
# block-leg-askuserquestion.sh (HIMMEL-2923), which is the template for this file.
#
# Zero context cost when not a leg: the marker check is the first statement and
# an allow prints NOTHING (no stdout, no stderr) — an operator or console session
# never sees this hook at all.
#
# Workflow nudge, not a security fence (scripts/hooks/CLAUDE.md "Fail-open vs
# fail-closed"): fails OPEN on anything it cannot parse (missing jq, malformed
# or empty stdin), so a hook bug never locks an operator's own session out of
# ScheduleWakeup.
#
# Bypass: unset HIMMEL_CONSOLE_LEG in the launching shell (session-sticky; a
# per-call prefix does not reach this hook process).
#
# Platform guard (gitbash-only): plain env var + jq, no git/path work; runs
# unchanged under Git Bash on Windows or POSIX bash 3.2+. No .ps1 twin needed.
#
# Hook I/O: JSON on stdin. exit 0 = allow, exit 2 = deny (stderr plus a
# structured hookSpecificOutput.permissionDecision on stdout — same
# belt-and-braces idiom as block-leg-askuserquestion.sh).
set -uo pipefail

[ "${HIMMEL_CONSOLE_LEG:-0}" = "1" ] || exit 0

command -v jq >/dev/null 2>&1 || exit 0

input=$(cat)

tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0
[ "$tool" = "ScheduleWakeup" ] || exit 0

deny_msg="leg wakeup-deny: a console-spawned leg never self-schedules a polling wakeup — each wake re-reads your full context to find 'not yet'. Wait with ONE foreground blocking command (bash scripts/check-ci.sh <pr> --max-wait <s>, or a foreground until-loop), or report to the console by SendMessage and end your turn. (HIMMEL-3034)"

reason=$(printf '%s' "$deny_msg" | jq -Rs . 2>/dev/null) \
    || reason='"leg wakeup-deny: console-spawned leg denied ScheduleWakeup"'
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$reason"
printf '%s\n' "$deny_msg" >&2
exit 2
