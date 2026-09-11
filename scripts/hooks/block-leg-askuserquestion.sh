#!/usr/bin/env bash
# block-leg-askuserquestion.sh — PreToolUse hook (matcher "AskUserQuestion"):
# denies AskUserQuestion for a console-spawned leg (HIMMEL-2923). A leg
# launched headed by a console (scripts/handover/console-kit/headed-arm-leg.sh,
# HIMMEL-2919, exports HIMMEL_CONSOLE_LEG=1 in the launching shell) runs in a
# window nobody answers: two legs parked on an AskUserQuestion call on
# 2026-09-10 — one 77 minutes with its diff already complete, the other
# despite an explicit NEVER in its brief. Second drift on prose -> structural
# (root CLAUDE.md "Adding a rule").
#
# Scope: inert until HIMMEL-2919's launcher export lands. Until then
# HIMMEL_CONSOLE_LEG is never set and this hook always falls through to
# allow — that is expected, not a bug.
#
# Workflow nudge, not a security fence (scripts/hooks/CLAUDE.md "Fail-open vs
# fail-closed"): fails OPEN on anything it cannot parse (missing jq, malformed
# or empty stdin), so a hook bug never locks an operator's own session out of
# AskUserQuestion.
#
# Bypass: unset HIMMEL_CONSOLE_LEG in the launching shell (session-sticky; a
# per-call prefix does not reach this hook process).
#
# Platform guard (gitbash-only): plain env var + jq, no git/path work; runs
# unchanged under Git Bash on Windows or POSIX bash 3.2+. No .ps1 twin needed.
#
# Hook I/O: JSON on stdin. exit 0 = allow, exit 2 = deny (stderr plus a
# structured hookSpecificOutput.permissionDecision on stdout — same
# belt-and-braces idiom as guard-console-dispatch.sh).
set -uo pipefail

[ "${HIMMEL_CONSOLE_LEG:-0}" = "1" ] || exit 0

command -v jq >/dev/null 2>&1 || exit 0

input=$(cat)

tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0
[ "$tool" = "AskUserQuestion" ] || exit 0

deny_msg="You are a console-spawned leg; nobody answers in this window. Ask the console by SendMessage (your brief names it), or wait with ONE foreground blocking command / a foreground until-loop. (HIMMEL-2923)"

reason=$(printf '%s' "$deny_msg" | jq -Rs . 2>/dev/null) \
    || reason='"block-leg-askuserquestion: console-spawned leg denied AskUserQuestion"'
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$reason"
printf '%s\n' "$deny_msg" >&2
exit 2
