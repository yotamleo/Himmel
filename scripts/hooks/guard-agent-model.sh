#!/usr/bin/env bash
# guard-agent-model.sh — PreToolUse hook (matcher "Agent"): denies an Agent
# dispatch that overrides `model` to Fable, and a `console-judge` dispatch that
# overrides `model` off its frontmatter tier (opus), unless the dispatch prompt
# carries a line `ESCALATION: <non-empty reason>` (HIMMEL-3847). HIMMEL-3630
# retired Fable as the judge default: Opus 5.5 high measured ~2.7x cheaper per
# verdict ($8.23 vs $21.94, HIMMEL-3595) at comparable wall time and no missed
# finding, yet an in-process Agent call passing `model: fable` silently overrides
# .claude/agents/console-judge.md's `model: opus` (console O did it three times on
# 2026-09-29). Fable stays available as the CLAUDE.md escalation target for ONE
# hard call — the marker is that lane, and leaves an audit trail in the prompt.
#
# Allow prints NOTHING (no stdout, no stderr): zero context cost. A missing
# `model` is always allowed (the agent's own frontmatter/default applies).
# The console-judge tier is hardcoded to opus; test-guard-agent-model.sh asserts
# the frontmatter still says so, so a tier change there fails the suite here.
#
# Workflow nudge, not a security fence (scripts/hooks/CLAUDE.md "Fail-open vs
# fail-closed"): fails OPEN on anything it cannot parse (missing jq, malformed or
# empty stdin, non-string fields), matching the sibling per-tool guards
# guard-leg-wakeup.sh / block-leg-askuserquestion.sh and the Agent watchdog
# auto-arm-on-subagent-cap.sh (exit 0 on an unparseable or non-Agent payload).
#
# Bypass: the `ESCALATION: <reason>` prompt line is the per-dispatch bypass; it
# is a line of its own (a mid-sentence mention or an empty reason does not count).
#
# Platform guard (gitbash-only): jq only, no git/path work; runs unchanged under
# Git Bash on Windows or POSIX bash 3.2+. No .ps1 twin needed.
#
# Hook I/O: JSON on stdin. exit 0 = allow, exit 2 = deny (stderr plus a
# structured hookSpecificOutput.permissionDecision on stdout — same
# belt-and-braces idiom as guard-leg-wakeup.sh).
#
# ponytail: covers the Agent tool only — a Workflow script's agent() dispatches
# run inside the one Workflow tool call and no per-dispatch hook seam is known,
# so they are not covered; upgrade path is the follow-up ticket cited in
# HIMMEL-3847's PR body.
set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0

input=$(cat)

verdict=$(printf '%s' "$input" | jq -r '
    def s: if type == "string" then . else "" end;
    (.tool_name | s) as $tool
    | (.tool_input | if type == "object" then . else {} end) as $ti
    | ($ti.model | s | ascii_downcase) as $m
    | ($ti.subagent_type | s | ascii_downcase) as $t
    | ($ti.prompt | s | test("(^|\n)[ \t]*ESCALATION:[ \t]*[^ \t\r\n]")) as $marked
    | if $tool != "Agent" or $m == "" or $marked then "allow"
      elif ($m | test("^(claude-)?fable([^a-z0-9]|$)")) then "fable"
      elif ($t | test("(^|:)console-judge$")) and ($m | test("^(claude-)?opus") | not) then "judge"
      else "allow" end' 2>/dev/null) || exit 0

case "$verdict" in
    fable) what="model fable" ;;
    judge) what="a console-judge model override off its frontmatter tier (opus)" ;;
    *) exit 0 ;;
esac

deny_msg="agent-model-deny: ${what} without an escalation marker — HIMMEL-3630 retired Fable as the judge default (Opus 5.5 high measured ~2.7x cheaper per verdict, \$8.23 vs \$21.94, with no missed finding; HIMMEL-3595). Drop the model override, or for ONE genuinely hard call add a prompt line 'ESCALATION: <reason>' and re-dispatch. (HIMMEL-3847)"

reason=$(printf '%s' "$deny_msg" | jq -Rs . 2>/dev/null) \
    || reason='"agent-model-deny: model override denied without an ESCALATION: marker (HIMMEL-3630)"'
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$reason"
printf '%s\n' "$deny_msg" >&2
exit 2
