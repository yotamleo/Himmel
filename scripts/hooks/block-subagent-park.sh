#!/usr/bin/env bash
# block-subagent-park.sh — PreToolUse hook (matcher "Bash|Monitor"): denies a
# subagent (Agent-tool worker) from parking — backgrounding a Bash call or
# reaching for the Monitor tool — inside a subagent session. (HIMMEL-2140)
#
# WHY: worker subagents park — a long run gets backgrounded
# (run_in_background:true) or the worker reaches for the Monitor tool, then
# ENDS ITS TURN "waiting for the notification", stalling until a
# human/controller notices and nudges it awake. One wasted round-trip and a
# wall-clock stall per occurrence; five occurrences in one 2026-08-26
# overnight leg, and prose in briefs reduced but never eliminated it. Per
# CLAUDE.md's "Adding a rule — pick the cheapest layer": first drift is
# signal, on the SECOND escalate to a hook, never to stronger prose — this is
# drift five.
#
# PARENTS ARE DELIBERATELY UNAFFECTED: background-by-default is the PARENT's
# standing rule, and a parent correctly acts on the completion notification —
# a worker does not, it ends its turn and stalls instead. The asymmetry is
# the design, not an oversight.
#
# THE SEAM (settled — do not re-derive): the PreToolUse payload carries
# `agent_id` ONLY when the hook fires inside a subagent (Agent-tool
# dispatched) call (code.claude.com/docs/en/hooks, "Common Input Fields":
# "Present only when the hook fires inside a subagent call."). Present =>
# subagent session; absent => main-thread/parent. This hook uses the SAME
# extraction idiom as orchestrator-inline-guard.sh's WORKER EXEMPTION (see
# that hook's header for the full derivation), at the INVERSE polarity:
# there, `agent_id` present EXEMPTS a worker from a parent-only gate; here,
# `agent_id` present is the PRECONDITION for firing at all.
#
# DO-NOT-RETRY, on the record: an earlier attempt at a similar worker/parent
# split used a CLAUDE_CODE_SESSION_ID-style env var and was REVERTED (see
# orchestrator-inline-guard.sh's "A first attempt ... FALSIFIED" note). In
# this harness an Agent-tool dispatch runs as a nested sub-invocation of the
# SAME top-level session (same session id, same transcript file) — that env
# var means "this CLI process was itself launched as a child of something"
# (e.g. schtasks), not "this is a subagent call", and would silence a guard
# for the exact parent it targets. `agent_id` or nothing.
#
# WHAT IS DENIED (subagent sessions only — agent_id present):
#   1. Bash with tool_input.run_in_background == true.
#   2. The Monitor tool (any call).
# Everything else stays allowed — in particular a foreground Bash call inside
# a subagent (no run_in_background) is never touched by this hook.
#
# sleep is DELIBERATELY NOT denied: the park pathology is ENDING THE TURN
# with work outstanding; a foreground `sleep N` blocks the turn instead of
# ending it (worst case it hits the tool timeout and returns), so it cannot
# cause a park. Denying it would be speculative scope beyond this ticket.
#
# This is a WORKFLOW-shaping hook, not a security fence (scripts/hooks/
# CLAUDE.md's fail-open-vs-closed rule): it fails OPEN on anything it cannot
# evaluate (missing jq, unparseable input, an unrecognised tool). Bash
# 3.2-compatible (no ${var,,}, no mapfile, no associative arrays).
#
# Kill switch (set in the shell that LAUNCHED Claude Code; session-sticky — a
# per-call prefix does NOT reach a hook process): SUBAGENT_PARK_GUARD_DISABLE=1
set -uo pipefail

warn() { echo "block-subagent-park: $*" >&2; }

[ "${SUBAGENT_PARK_GUARD_DISABLE:-0}" = "1" ] && exit 0

command -v jq >/dev/null 2>&1 || { warn "jq not on PATH — allowing (fail-open, no gate)"; exit 0; }

input=$(cat 2>/dev/null || true)
[ -n "$input" ] || exit 0

# Subagent precondition (see header) — a main-thread/parent session carries
# no agent_id and is never gated by this hook.
# Accept agent_id ONLY as a NON-EMPTY STRING (CR round 1, HIMMEL-2140).
# Two traps, one rule. (a) `.agent_id // empty` is wrong: jq's `//` swallows
# `false` as well as null, so `"agent_id": false` would read ABSENT and
# silently skip the gate. (b) But the inverse over-correction is wrong too:
# treating ANY present value as a subagent makes a MALFORMED payload
# (`true` / `123` / `{}`) DENY. This hook is a workflow nudge, not a security
# fence -- it fails OPEN on missing jq and on empty/unparseable stdin, and a
# malformed payload belongs in that same bucket: if we cannot tell, ALLOW.
# The documented contract is an identifier, i.e. a string, so a non-string is
# a contract violation, not a subagent signal. `type` keys on the real
# contract and is immune to both traps.
# A non-object payload makes jq -e exit non-zero => fail-open, as intended.
if ! printf '%s' "$input" | jq -e '(.agent_id | type) == "string" and .agent_id != ""' >/dev/null 2>&1; then
    exit 0
fi

tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)

deny=0
what=""
case "$tool" in
    Bash)
        if printf '%s' "$input" | jq -e '.tool_input.run_in_background == true' >/dev/null 2>&1; then
            deny=1
            what="a Bash call with run_in_background:true"
        fi
        ;;
    Monitor)
        deny=1
        what="the Monitor tool"
        ;;
    *)
        exit 0
        ;;
esac
[ "$deny" = "1" ] || exit 0

deny_msg="You are a subagent (worker) — $what is DENIED here (HIMMEL-2140).

Backgrounding a call, or reaching for Monitor, and then ending your turn to 'wait for the
notification' is how workers PARK: a human or controller has to notice and nudge you awake before
anything continues — one wasted round-trip and a wall-clock stall every time this happens.
Parents are deliberately UNAFFECTED by this gate — background-by-default is the PARENT's
standing rule, and a parent correctly acts on the completion notification when it arrives. A
worker's turn just ENDS instead, so for you backgrounding is a stall, never a convenience.

Do this instead:
  * Run it in the FOREGROUND with an explicit, generous timeout — the Bash tool accepts up to
    600000 ms (10 minutes).
  * Genuinely longer than that? Use scripts/quiet-run.sh, then do BOUNDED foreground polls or
    reads of the log path it prints — never an unbounded wait.
  * If the work is already done, just report it — do not end your turn waiting on anything.

(A short foreground sleep is fine and is not denied by this gate — it blocks your turn rather
than ending it, so it cannot cause a park.)"

reason=$(printf '%s' "$deny_msg" | jq -Rs . 2>/dev/null) \
    || reason='"block-subagent-park: subagent backgrounding/Monitor denied — run in the foreground instead"'
# Belt-and-braces deny: structured permissionDecision:"deny" on stdout PLUS
# exit 2 + stderr (same idiom as orchestrator-inline-guard.sh / guard-console-
# dispatch.sh).
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$reason"
printf '%s\n' "$deny_msg" >&2
exit 2
