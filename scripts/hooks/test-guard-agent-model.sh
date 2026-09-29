#!/usr/bin/env bash
# Smoke suite for scripts/hooks/guard-agent-model.sh (HIMMEL-3847): an Agent
# dispatch that overrides model to Fable without an `ESCALATION: <reason>` prompt
# line is denied, and so is a console-judge model override off its frontmatter
# tier (opus) without the marker (HIMMEL-3630: Opus-high judge default).
# Covers: fable / claude-fable-5-1 -> deny; same WITH marker -> allow; empty marker
# -> deny; opus/sonnet/haiku and no model -> allow; console-judge sonnet -> deny,
# opus -> allow, no model -> allow, marked sonnet -> allow; other tool -> allow;
# malformed/empty stdin -> allow (fail-open); allow path prints nothing.
#
# bash 3.2-safe. Platform guard (gitbash-only): jq checks only, no git/path work;
# runs unchanged under Git Bash on Windows. No .ps1 twin needed.
set -uo pipefail

HOOKS="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HOOKS/guard-agent-model.sh"
JUDGE="$HOOKS/../../.claude/agents/console-judge.md"
[ -f "$HOOK" ] || { echo "hook not found: $HOOK" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

# agent <subagent_type> <model> <prompt> — build an Agent payload via jq so the
# prompt's newlines are real JSON escapes; an empty type/model is left out.
agent() {
    jq -cn --arg t "$1" --arg m "$2" --arg p "$3" \
        '{tool_name:"Agent",tool_input:({description:"d",prompt:$p}
          + (if $t != "" then {subagent_type:$t} else {} end)
          + (if $m != "" then {model:$m} else {} end))}'
}

# check <label> <block|allow> <json>
check() {
    local label="$1" expect="$2" json="$3" rc got
    printf '%s' "$json" | bash "$HOOK" >/dev/null 2>&1
    rc=$?
    case "$rc" in 0) got=allow ;; 2) got=block ;; *) got="?(rc=$rc)" ;; esac
    if [ "$got" = "$expect" ]; then ok "$label"; else bad "$label - expected $expect got $got"; fi
}

# silent <label> <json> — the allow path must add zero stdout AND stderr.
silent() {
    local out
    out="$(printf '%s' "$2" | bash "$HOOK" 2>&1)"
    if [ -z "$out" ]; then ok "$1"; else bad "$1 - expected no output, got: $out"; fi
}

MARK=$'do the review\nESCALATION: one hard call, needs taste'
EMPTY=$'do the review\nESCALATION:   \nnext line'

echo "== fable model override =="
check "model fable, no marker -> deny" block "$(agent general-purpose fable 'do the review')"
check "model claude-fable-5-1, no marker -> deny" block "$(agent general-purpose claude-fable-5-1 'do the review')"
check "model Fable (case) -> deny" block "$(agent '' Fable 'do the review')"
check "model fable, marker -> allow" allow "$(agent general-purpose fable "$MARK")"
check "model claude-fable-5-1, marker -> allow" allow "$(agent general-purpose claude-fable-5-1 "$MARK")"
check "model fable, empty marker -> deny" block "$(agent general-purpose fable "$EMPTY")"
check "model fable, marker mid-line (not a line) -> deny" block \
    "$(agent general-purpose fable 'please note ESCALATION: x is fine')"
out="$(agent general-purpose fable 'x' | bash "$HOOK" 2>/dev/null)"
reason="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)"
case "$reason" in
    *HIMMEL-3630*"ESCALATION:"*) ok "deny reason names HIMMEL-3630 and the marker" ;;
    *) bad "deny reason missing HIMMEL-3630 / marker - got: $reason" ;;
esac
if [ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)" = "deny" ]; then
    ok "permissionDecision is deny"
else
    bad "permissionDecision not deny - got: $out"
fi

echo "== other tiers / no model -> allow, zero output =="
check "model opus -> allow" allow "$(agent general-purpose opus 'x')"
check "model sonnet -> allow" allow "$(agent general-purpose sonnet 'x')"
check "model haiku -> allow" allow "$(agent general-purpose haiku 'x')"
check "no model -> allow" allow "$(agent general-purpose '' 'x')"
silent "model sonnet -> no output" "$(agent general-purpose sonnet 'x')"
silent "no model -> no output" "$(agent general-purpose '' 'x')"

echo "== console-judge override off its frontmatter tier (opus) =="
if grep -q '^model: opus$' "$JUDGE"; then
    ok "console-judge frontmatter is still model: opus"
else
    bad "console-judge frontmatter no longer model: opus - update the hook's tier"
fi
check "console-judge + sonnet -> deny" block "$(agent console-judge sonnet 'x')"
check "console-judge + haiku -> deny" block "$(agent console-judge haiku 'x')"
check "console-judge + fable -> deny" block "$(agent console-judge fable 'x')"
check "console-judge + opus -> allow" allow "$(agent console-judge opus 'x')"
check "console-judge + claude-opus-5-5 -> allow" allow "$(agent console-judge claude-opus-5-5 'x')"
check "console-judge + no model -> allow" allow "$(agent console-judge '' 'x')"
check "console-judge + sonnet + marker -> allow" allow "$(agent console-judge sonnet "$MARK")"
check "plugin-namespaced console-judge + sonnet -> deny" block "$(agent himmel-ops:console-judge sonnet 'x')"
check "other agent + sonnet -> allow" allow "$(agent Explore sonnet 'x')"

echo "== other tool / malformed / empty stdin -> allow (fail-open) =="
check "Write tool -> allow" allow '{"tool_name":"Write","tool_input":{"model":"fable"}}'
check "malformed JSON -> allow" allow '{not json'
check "empty stdin -> allow" allow ''
check "no tool_input -> allow" allow '{"tool_name":"Agent"}'
check "non-string model -> allow" allow '{"tool_name":"Agent","tool_input":{"model":7,"prompt":"x"}}'
check "non-string prompt + fable -> deny" block '{"tool_name":"Agent","tool_input":{"model":"fable","prompt":7}}'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
