#!/usr/bin/env bash
# guard-subagent-model.sh — PreToolUse hook (matcher "Agent"): [HIMMEL-2653]
# structural nudge for root CLAUDE.md's "Every dispatch names an explicit
# model" rule. An Agent dispatch with no `model` inherits the PARENT
# session's model — silently billing the scarcer parent tier (Sonnet/Opus/
# Fable) for work that could have run on a cheaper one. Nothing enforced this
# before; it was prose only.
#
# WHY NOW: a 24h/4.40e9-token measurement (HIMMEL-2653) found subagents at
# 50.06% of raw spend, with subagent_type "general-purpose" alone at 49.85% —
# the dominant shape is exactly the unnamed-model, generic-worker dispatch
# this hook targets.
#
# TRIP CONDITION (both must hold):
#   1. tool_input.model is absent, empty, or whitespace-only.
#   2. tool_input.subagent_type is absent/empty OR exactly "general-purpose".
# A NAMED specialist subagent_type (Explore, statusline-setup, a plugin
# agent, ...) is NOT tripped even with no model — those carry their own model
# in their own agent definition, so an absent `model` field here says nothing
# about what actually runs.
#
# DEFAULT ACTION: WARN — allow (exit 0) plus a visible
# permissionDecisionReason, the same shape guard-implementor-dispatch.sh
# already emits for its own WARN path. Set HIMMEL_REQUIRE_SUBAGENT_MODEL=1 to
# escalate to a hard DENY (exit 2). This mirrors the WARN/HARD split of the
# sibling bank guards in this file: default advisory, opt-in enforcement.
#
# Escape hatch (set in the shell that LAUNCHED Claude Code; session-sticky):
#   SUBAGENT_MODEL_OK=1   silences both the WARN and the DENY.
#
# FAIL-OPEN ON EVERYTHING ELSE: unreadable/unparseable stdin, a non-Agent
# tool, missing tool_input, any jq failure — all exit 0 silently. This is a
# workflow nudge (scripts/hooks/CLAUDE.md's fail-open-vs-closed rule), not a
# security fence: a guard that blocks dispatch because it could not parse a
# payload is worse than the drift it prevents. Purely structural on two
# payload fields — no transcript read, no prompt-text intent detection.
#
# Bash 3.2-compatible. Exit codes: 0 allow (optionally with a WARN reason);
# 2 deny (only under HIMMEL_REQUIRE_SUBAGENT_MODEL=1).
#
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
# Reads the hook payload from stdin and shells out to jq; NOT ported to native
# PowerShell, and deliberately shipped without a .ps1 twin — hooks.json invokes
# this script through hooks/run-hook-with-bash.js, so it runs under bash on
# every platform himmel supports and a twin would be dead code. A real Windows
# port (only needed if that wiring ever changes) would have to read the same
# stdin JSON, reproduce the fail-open contract above exactly — absent
# tool_input, wrong-typed fields and any parse failure all allow — and emit the
# same permissionDecision object and 0/2 exit codes.
set -uo pipefail

warn() { echo "guard-subagent-model: $*" >&2; }

input=$(cat 2>/dev/null || true)

if [ "${SUBAGENT_MODEL_OK:-0}" = "1" ]; then
    warn "SUBAGENT_MODEL_OK=1 — allowing by explicit session override"
    exit 0
fi

command -v jq >/dev/null 2>&1 || exit 0
[ -n "$input" ] || exit 0

if ! tool=$(printf '%s' "$input" | jq -r '.tool_name | select(type == "string") // empty' 2>/dev/null); then
    exit 0
fi
[ "$tool" = "Agent" ] || exit 0

# HIMMEL-2653: a missing/non-object tool_input, or a model/subagent_type
# field present with the WRONG JSON type, must fail open like any other
# unparseable payload — it must NOT be treated as the field being genuinely
# omitted (which trips the guard). `select(type == "string") // empty` alone
# cannot tell those two apart: both a truly-absent field and a present-but-
# wrong-type field collapse to the empty string. That collapse is exactly
# what let a payload with no `tool_input` at all read as empty model + empty
# subagent_type and get DENIED instead of failing open. So check .tool_input's
# type first, then each field's type, before ever reading a value.
tool_input_type=$(printf '%s' "$input" | jq -r '.tool_input | type' 2>/dev/null) || exit 0
[ "$tool_input_type" = "object" ] || exit 0

model_type=$(printf '%s' "$input" | jq -r '.tool_input.model | type' 2>/dev/null) || exit 0
case "$model_type" in
    null|string) ;;
    *) exit 0 ;;
esac
model=$(printf '%s' "$input" | jq -r '.tool_input.model // empty' 2>/dev/null) || exit 0

subagent_type_type=$(printf '%s' "$input" | jq -r '.tool_input.subagent_type | type' 2>/dev/null) || exit 0
case "$subagent_type_type" in
    null|string) ;;
    *) exit 0 ;;
esac
subagent_type=$(printf '%s' "$input" | jq -r '.tool_input.subagent_type // empty' 2>/dev/null) || exit 0

# Whitespace-only counts as absent — a model field carrying only spaces names
# nothing runnable.
model_trimmed=$(printf '%s' "$model" | tr -d '[:space:]')
[ -z "$model_trimmed" ] || exit 0

case "$subagent_type" in
    ''|general-purpose) ;;
    *) exit 0 ;;
esac

shape="${subagent_type:-<no-subagent_type>}/<no-model>"

if [ "${HIMMEL_REQUIRE_SUBAGENT_MODEL:-0}" = "1" ]; then
    cat >&2 <<EOF
guard-subagent-model: unnamed-model Agent dispatch DENIED ($shape) —
HIMMEL_REQUIRE_SUBAGENT_MODEL=1 is set. An Agent dispatch with no model
silently inherits the PARENT session's model, billing the scarcer parent
tier for work that may not need it (root CLAUDE.md: "Every dispatch names
an explicit model").

Pass an explicit model on this dispatch. /lanes lists the live tiers/lanes
available on this machine.

Deliberate override: relaunch with SUBAGENT_MODEL_OK=1 in the launching shell.
EOF
    exit 2
fi

reason=$(printf '%s' "guard-subagent-model: unnamed-model Agent dispatch ($shape) inherits the parent session's model — pass an explicit model (see /lanes for the live inventory). (SUBAGENT_MODEL_OK=1 to silence; HIMMEL_REQUIRE_SUBAGENT_MODEL=1 to enforce)" | jq -Rs . 2>/dev/null) \
    || reason='"guard-subagent-model: unnamed-model Agent dispatch — pass an explicit model"'
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":%s}}\n' "$reason"
exit 0
