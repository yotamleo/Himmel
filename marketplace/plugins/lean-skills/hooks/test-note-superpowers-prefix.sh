#!/usr/bin/env bash
# test-note-superpowers-prefix.sh — suite for the PostToolUse(Skill) prefix-hint
# hook (HIMMEL-3100). The suite is the spec.
#
# Why the hook exists: vendored SKILL.md prose cites `superpowers:<name>`, which
# is "Unknown skill" in a lean-skills-only install. Claude Code fires neither
# PreToolUse nor PostToolUseFailure for that validation-time rejection, so the
# only lean lever is to hint when a citing lean-skills skill LOADS.
set -uo pipefail
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$HOOK_DIR/.." && pwd)"
SCRIPT="$HOOK_DIR/note-superpowers-prefix.sh"
fail=0
emit() { printf '%s' "$1" | CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$SCRIPT" 2>/dev/null; }
bad() { echo "FAIL: $1"; fail=1; }

[ -f "$SCRIPT" ] || { bad "hook script missing: $SCRIPT"; echo "1 failure(s)"; exit 1; }

# a citing skill, qualified and bare -> hint
out=$(emit '{"tool_name":"Skill","tool_input":{"skill":"lean-skills:systematic-debugging"}}')
case "$out" in *lean-skills:*) ;; *) bad "qualified citing skill not hinted (got '$out')";; esac
out=$(emit '{"tool_name":"Skill","tool_input":{"skill":"executing-plans"}}')
case "$out" in *lean-skills:*) ;; *) bad "bare citing skill not hinted (got '$out')";; esac

# the hint is ONE line and a well-formed PostToolUse envelope
out=$(emit '{"tool_name":"Skill","tool_input":{"skill":"lean-skills:writing-skills"}}')
case "$out" in *'"hookEventName":"PostToolUse"'*'"additionalContext"'*) ;; *) bad "malformed envelope (got '$out')";; esac
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = "1" ] || bad "hint is not one line"
if command -v node >/dev/null 2>&1; then
  printf '%s' "$out" | node -e 'const j=JSON.parse(require("fs").readFileSync(0,"utf8"));if(j.hookSpecificOutput.hookEventName!=="PostToolUse"||!j.hookSpecificOutput.additionalContext)process.exit(1)' \
    || bad "envelope is not valid JSON with the expected fields"
fi

# a lean-skills skill that does NOT cite superpowers: -> silent
out=$(emit '{"tool_name":"Skill","tool_input":{"skill":"lean-skills:grilling"}}')
[ -z "$out" ] || bad "non-citing skill hinted (got '$out')"

# another plugin's skill (real superpowers installed alongside) -> silent
out=$(emit '{"tool_name":"Skill","tool_input":{"skill":"superpowers:systematic-debugging"}}')
[ -z "$out" ] || bad "foreign-namespace skill hinted (got '$out')"

# unknown bare name / path traversal -> silent, never reads outside skills/
out=$(emit '{"tool_name":"Skill","tool_input":{"skill":"no-such-skill"}}')
[ -z "$out" ] || bad "unknown skill hinted (got '$out')"
out=$(emit '{"tool_name":"Skill","tool_input":{"skill":"lean-skills:../hooks"}}')
[ -z "$out" ] || bad "traversal name hinted (got '$out')"

# kill switch
out=$(printf '%s' '{"tool_name":"Skill","tool_input":{"skill":"executing-plans"}}' | LEAN_SKILLS_PREFIX_HINT_DISABLE=1 CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$SCRIPT" 2>/dev/null)
[ -z "$out" ] || bad "kill switch ignored (got '$out')"

# empty payload, missing skill key, non-Skill tool -> silent exit 0
out=$(printf '' | CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$SCRIPT" 2>/dev/null); rc=$?
{ [ -z "$out" ] && [ "$rc" = "0" ]; } || bad "empty payload (rc=$rc out='$out')"
out=$(emit '{"tool_name":"Skill","tool_input":{}}')
[ -z "$out" ] || bad "missing skill key hinted (got '$out')"
out=$(emit '{"tool_name":"Bash","tool_input":{"command":"echo executing-plans"}}')
[ -z "$out" ] || bad "non-Skill tool hinted (got '$out')"

# pretty-printed payload; a later "skill" key in tool_response must not win
out=$(emit '{
  "hook_event_name": "PostToolUse",
  "tool_name": "Skill",
  "tool_input": { "skill": "lean-skills:executing-plans" },
  "tool_response": { "skill": "lean-skills:grilling", "success": true }
}')
case "$out" in *lean-skills:*) ;; *) bad "pretty payload / tool_response skill confusion (got '$out')";; esac

# hooks.json wiring: PostToolUse, matcher Skill, points at the script
HJ="$HOOK_DIR/hooks.json"
if [ -f "$HJ" ] && command -v node >/dev/null 2>&1; then
  node -e '
    const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
    const e=(j.hooks.PostToolUse||[]).find(x=>x.matcher==="Skill");
    if(!e) process.exit(1);
    if(!e.hooks.some(h=>h.type==="command"&&h.command.includes("note-superpowers-prefix.sh"))) process.exit(2);
  ' "$HJ" || bad "hooks.json does not wire PostToolUse/Skill -> note-superpowers-prefix.sh (rc=$?)"
else
  bad "hooks.json missing (or node absent)"
fi

# CLOSURE: every superpowers:<name> the vendored tree cites names a skill that
# ships here (the ticket's "namespace mismatch, not a missing capability" claim
# as a check — a re-vendor that cites a new, unvendored skill fails HERE).
cited=$(grep -rhoE 'superpowers:[a-z][a-z0-9-]*' "$PLUGIN_ROOT/skills" 2>/dev/null | sed 's/^superpowers://' | sort -u)
[ -n "$cited" ] || bad "closure scan found zero superpowers: citations (vacuous — the tree changed shape?)"
for n in $cited; do
  [ -f "$PLUGIN_ROOT/skills/$n/SKILL.md" ] || bad "vendored tree cites superpowers:$n but skills/$n/SKILL.md is not vendored"
done

# COVERAGE: the hook hints for EXACTLY the skill dirs that cite superpowers:
# (no hard-coded list to drift after a re-vendor).
for d in "$PLUGIN_ROOT"/skills/*/; do
  n=$(basename "$d")
  out=$(emit "{\"tool_name\":\"Skill\",\"tool_input\":{\"skill\":\"lean-skills:$n\"}}")
  if grep -rqF 'superpowers:' "$d"; then
    case "$out" in *lean-skills:*) ;; *) bad "$n cites superpowers: but was not hinted";; esac
  else
    [ -z "$out" ] || bad "$n does not cite superpowers: but was hinted"
  fi
done

[ "$fail" = "0" ] && echo "ALL PASS"; exit "$fail"
