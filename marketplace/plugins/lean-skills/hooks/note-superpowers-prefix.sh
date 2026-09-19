#!/usr/bin/env bash
# note-superpowers-prefix.sh — PostToolUse(Skill) hook (HIMMEL-3100).
#
# The vendored SKILL.md prose (verbatim from obra/superpowers) hands off to
# siblings as `superpowers:<name>`. In a lean-skills-only install that plugin is
# not installed, so following the handoff via the Skill tool is
# "Unknown skill: superpowers:<name>" although the skill ships here as
# `lean-skills:<name>` (the bare `<name>` resolves too).
#
# Why THIS event: Claude Code fires neither PreToolUse nor PostToolUseFailure
# for a validation-time rejection ("an unknown tool name, input that fails
# schema or tool-specific validation" — code.claude.com/docs/en/hooks), so the
# failing call cannot be intercepted or rewritten. What CAN be done is hint at
# the moment the stale prose is read: when a lean-skills skill whose files cite
# `superpowers:` loads successfully, add one line of context saying how to
# resolve the prefix. Vendored prose stays untouched (VENDORED.md rule).
#
# Which skills cite is read from the tree (grep), never a hard-coded list, so a
# re-vendor cannot drift it. Advisory, FAIL-OPEN: only ever exit 0, with either
# an additionalContext envelope or empty stdout.
#
# Kill switch: LEAN_SKILLS_PREFIX_HINT_DISABLE=1 (launching shell).
# Wiring: marketplace/plugins/lean-skills/hooks/hooks.json (PostToolUse, matcher
# "Skill"). Paired suite: hooks/test-note-superpowers-prefix.sh. bash 3.2-safe.

set -uo pipefail
trap 'exit 0' ERR

[ "${LEAN_SKILLS_PREFIX_HINT_DISABLE:-0}" = "1" ] && exit 0
[ -t 0 ] && exit 0
payload=$(cat 2>/dev/null || true)
[ -z "$payload" ] && exit 0

# First "skill" key = tool_input.skill (tool_input precedes tool_response in the
# PostToolUse payload); grep -o so a later "skill" key cannot win the way a
# greedy sed would.
skill=$(printf '%s' "$payload" | grep -o '"skill"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n 1 | sed 's/.*:[[:space:]]*"\([^"]*\)"$/\1/')

# lean-skills:<name> or a bare <name>. Anything else (another plugin's
# `x:<name>`, `..`, `/`) fails the charset and stays silent — that also keeps
# the directory lookup below inside skills/.
name=${skill#lean-skills:}
case "$name" in
  "" | *[!A-Za-z0-9_-]*) exit 0 ;;
esac

root=${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
dir="$root/skills/$name"
[ -d "$dir" ] || exit 0
grep -rqF 'superpowers:' "$dir" 2>/dev/null || exit 0

printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"lean-skills (HIMMEL-3100): in this skill, superpowers:<x> means lean-skills:<x> (bare <x> also resolves); the superpowers plugin is not installed, so a superpowers:-prefixed Skill call fails."}}'
exit 0
