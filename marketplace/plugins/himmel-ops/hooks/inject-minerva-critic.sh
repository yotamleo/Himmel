#!/usr/bin/env bash
# inject-minerva-critic.sh — PreToolUse(Skill) hook (HIMMEL-429).
#
# Closes the no-/minerva bypass: when superpowers:brainstorming or
# superpowers:writing-plans is invoked by ANY path (auto-trigger, direct
# /skill, or a sub-skill handoff) WITHOUT going through /minerva, inject a
# scoped directive so the model still runs the matching minerva adversarial
# critic loop (himmel-ops:minerva). This is ADVISORY context, not a permission
# change — it cannot widen what any hook allows.
#
# Spike findings (HIMMEL-429 Task 1, all confirmed):
#   Q1 matcher:"Skill" is valid for PreToolUse.                        (docs)
#   Q2 the invoked skill name is at tool_input.skill.   (session-transcript)
#   Q3 PreToolUse additionalContext reaches the model — "wrapped in a
#      system reminder, inserted next to the tool result, read on the next
#      model request".                                                  (docs)
#   Q4 a plugin hooks/hooks.json fires the same as repo settings.json.  (docs)
# => shipped via the himmel-ops plugin hooks.json for system-wide reach.
#
# Context injector → FAIL-OPEN: never block a Skill call on our own error.
# (PreToolUse exit code 2 would BLOCK the tool; we only ever exit 0 with
# either an injection envelope or empty stdout.)
#
# Kill switch: MINERVA_HOOK_DISABLE=1 (set in the launching shell) disables it.
#
# Hook contract (PreToolUse): reads the tool-call JSON on stdin; exit 0 with a
# {"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":...}}
# envelope on stdout to inject context, or exit 0 with empty stdout for no-op.
#
# Wiring: marketplace/plugins/himmel-ops/hooks/hooks.json (PreToolUse,
# matcher "Skill"). bash 3.2-safe.

set -uo pipefail
trap 'exit 0' ERR

[ "${MINERVA_HOOK_DISABLE:-0}" = "1" ] && exit 0

# Slurp the FULL payload. Sibling PreToolUse hooks use `cat` (block-edit-on-
# main.sh, auto-approve-safe-bash.sh); `read -r` reads only the first line and
# would silently no-op on a multi-line / pretty-printed JSON body. Guard the
# interactive no-stdin case so a hand-run never hangs on cat.
[ -t 0 ] && exit 0
payload=$(cat 2>/dev/null || true)
[ -z "$payload" ] && exit 0

# Extract the invoked skill name: grep the "skill" value (the only such key in a
# Skill tool_input; canonical path tool_input.skill, confirmed by the spike). On
# a multi-line payload sed still matches the line that bears the key.
skill=$(printf '%s' "$payload" | sed -n 's/.*"skill"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

inject() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"%s"}}\n' "$1"
}

case "$skill" in
  *brainstorming*)
    inject "minerva (HIMMEL-428): after this brainstorming writes the spec, do NOT auto-handoff to writing-plans — run the minerva SPEC-CRITIC loop first (himmel-ops:minerva, Stage 2 charter), then proceed."
    ;;
  *writing-plans*)
    inject "minerva (HIMMEL-428): after this plan is written, run the minerva PLAN-CRITIC loop (himmel-ops:minerva, Stage 4 charter) before implementation."
    ;;
  *)
    exit 0
    ;;
esac

exit 0
