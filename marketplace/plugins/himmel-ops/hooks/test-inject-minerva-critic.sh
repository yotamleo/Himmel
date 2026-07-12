#!/usr/bin/env bash
# test-inject-minerva-critic.sh — smoke test for the PreToolUse(Skill) minerva
# critic-injection hook (HIMMEL-429). The suite is the spec.
#
# Field path (.skill) confirmed by the HIMMEL-429 spike: Claude Code records the
# Skill tool's input as {"tool_name":"Skill","tool_input":{"skill":"<name>"}}.
set -uo pipefail
SCRIPT="$(cd "$(dirname "$0")" && pwd)/inject-minerva-critic.sh"
fail=0
emit() { printf '%s' "$1" | bash "$SCRIPT"; }

# brainstorming → inject spec-critic directive
out=$(emit '{"tool_name":"Skill","tool_input":{"skill":"superpowers:brainstorming"}}')
case "$out" in *spec-critic*|*minerva*) ;; *) echo "FAIL: brainstorming not injected (got '$out')"; fail=1;; esac

# writing-plans → inject plan-critic directive
out=$(emit '{"tool_name":"Skill","tool_input":{"skill":"superpowers:writing-plans"}}')
case "$out" in *plan-critic*|*minerva*) ;; *) echo "FAIL: writing-plans not injected (got '$out')"; fail=1;; esac

# the injected JSON must be a well-formed PreToolUse hookSpecificOutput
out=$(emit '{"tool_name":"Skill","tool_input":{"skill":"superpowers:brainstorming"}}')
case "$out" in *'"hookEventName":"PreToolUse"'*'"additionalContext"'*) ;; *) echo "FAIL: malformed injection envelope (got '$out')"; fail=1;; esac

# unrelated skill → no injection (empty stdout)
out=$(emit '{"tool_name":"Skill","tool_input":{"skill":"superpowers:using-superpowers"}}')
[ -z "$out" ] || { echo "FAIL: unrelated skill injected (got '$out')"; fail=1; }

# minerva's own skill → no injection (the operator already ran the pipeline)
out=$(emit '{"tool_name":"Skill","tool_input":{"skill":"himmel-ops:minerva"}}')
[ -z "$out" ] || { echo "FAIL: minerva self-skill injected (got '$out')"; fail=1; }

# kill switch
out=$(MINERVA_HOOK_DISABLE=1 emit '{"tool_name":"Skill","tool_input":{"skill":"superpowers:brainstorming"}}')
[ -z "$out" ] || { echo "FAIL: kill switch ignored (got '$out')"; fail=1; }

# no payload → quiet exit 0
out=$(printf '' | bash "$SCRIPT"); [ -z "$out" ] || { echo "FAIL: empty payload injected (got '$out')"; fail=1; }

# non-Skill tool → no injection (defensive; matcher should prevent this anyway)
out=$(emit '{"tool_name":"Bash","tool_input":{"command":"echo brainstorming"}}')
[ -z "$out" ] || { echo "FAIL: non-Skill tool injected (got '$out')"; fail=1; }

# multi-line / pretty-printed payload still injects (must not assume single-line stdin)
out=$(printf '{\n  "tool_name": "Skill",\n  "tool_input": { "skill": "superpowers:brainstorming" }\n}' | bash "$SCRIPT")
case "$out" in *minerva*) ;; *) echo "FAIL: multi-line payload not injected (got '$out')"; fail=1;; esac

# trigger word only in an arg value (not the skill field) → no injection
out=$(emit '{"tool_name":"Skill","tool_input":{"skill":"obsidian-save","args":"brainstorming notes"}}')
[ -z "$out" ] || { echo "FAIL: arg-value substring injected (got '$out')"; fail=1; }

# Skill tool, well-formed JSON, but no skill key → no-op
out=$(emit '{"tool_name":"Skill","tool_input":{}}')
[ -z "$out" ] || { echo "FAIL: missing skill key injected (got '$out')"; fail=1; }

[ "$fail" = "0" ] && echo "ALL PASS"; exit "$fail"
