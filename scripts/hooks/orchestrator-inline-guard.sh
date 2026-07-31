#!/usr/bin/env bash
# orchestrator-inline-guard.sh — PreToolUse hook (matcher "Edit|Write|NotebookEdit"):
# advisory structural nudge when a top-tier parent session (Fable/Opus) edits an
# implementation-surface file directly instead of dispatching to a worker lane
# (HIMMEL-1384, phase 1 — CLAUDE.md "Subagent policy": inline implementation on
# a top-tier parent is the anti-pattern, sole exception is one trivial CR-fix
# per PR). Escalates HIMMEL-166/688 per the repo's own "second drift -> structural"
# doctrine (operator, 2026-07-29: "i always find myself re-enforcing this").
#
# THIS IS ADVISORY ONLY — it NEVER blocks. Every path through this script exits
# 0. A bug here must never brick a legitimate Edit/Write/NotebookEdit call; the
# fail-open sibling precedent is guard-implementor-dispatch.sh (a cost guard,
# not a security guard), not block-edit-on-main.sh's fail-closed posture.
#
# ============================================================================
# MODEL DETECTION — DOCUMENTED BLOCKER, HONEST BEST-EFFORT ANSWER
# ============================================================================
# Claude Code's PreToolUse hook payload does NOT carry the session's model.
# Verified against the official hooks contract (code.claude.com/docs/en/hooks):
# PreToolUse ships session_id/prompt_id/transcript_path/cwd/permission_mode/
# effort/tool_name/tool_input/tool_use_id — no `model` field. Only SessionStart
# MAY carry a `model` field, and the docs say explicitly it "is not guaranteed
# to be present." No $CLAUDE_MODEL (or any) env var exposes it to hook
# subprocesses either. Nothing in this repo's existing hooks caches a
# per-session model value that a PreToolUse hook could read (the statusline
# usage cache read by guard-implementor-dispatch.sh carries 5h/7d bank
# utilization, not model identity).
#
# Given that, this hook uses the only remaining signal: it tails the
# transcript file named in the PreToolUse payload (`transcript_path`) and
# reads the `.message.model` field of the most recent assistant turn. This is
# EXPLICITLY UNSUPPORTED per Claude Code's own docs ("The entry format is
# internal to Claude Code and changes between versions, so scripts that parse
# these files directly can break on any release" — and the transcript may lag
# the in-memory conversation by a turn). Two things make this an acceptable
# tradeoff for a PHASE-1 ADVISORY hook specifically: (1) a wrong read only
# ever costs a missed or spurious *nudge*, never a block; (2) failure defaults
# toward NOT firing (empty/unreadable/unparseable transcript => not top-tier
# => silent allow), matching the "err on the side of NOT firing" doctrine this
# ticket also applies to path scoping (HIMMEL-1341). If Claude Code changes
# the transcript shape, this hook degrades to permanently silent — not to a
# false nudge. A durable fix (e.g. a SessionStart hook caching `.model` to a
# per-session file) is out of scope for phase 1, which only authorizes ADDING
# the single PreToolUse entry below.
# ============================================================================
#
# Path scope (tunable, per ticket): implementation surfaces IN —
# scripts/**, marketplace/plugins/*/src/**, .claude/commands/**. Docs/prose/
# ledger/handover/scratchpad OUT, checked first and always win. Markdown is
# treated as prose everywhere EXCEPT under .claude/commands/, where .md *is*
# the implementation format (slash-command specs) — without that carve-out a
# blanket .md exclusion would silently defeat the .claude/commands/ inclusion
# entirely, since every slash command is a .md file.
#
# On trigger: injects a short additionalContext nudge (hookSpecificOutput
# permissionDecision:"allow" idiom — auto-approve-safe-bash.sh /
# guard-memory-capture.sh precedent) and appends one jsonl line
# ({ts, session, model, tool, path}) to ~/.claude/orchestrator-inline-guard/
# fires.jsonl — the phase-2 counter-metric this ticket exists to seed. Log
# failures never fail the hook (append-only, best-effort, `|| true`).
#
# Env knobs (all optional):
#   ORCH_GUARD_DISABLE=1        session bypass (launching-shell convention,
#                                same as EDIT_ON_MAIN_OK / IMPL_GUARD_DISABLE)
#   ORCH_GUARD_LOG               fire-log path override (test seam; default
#                                ~/.claude/orchestrator-inline-guard/fires.jsonl)
#   ORCH_GUARD_TRANSCRIPT_TAIL   lines tailed from transcript_path when
#                                sniffing the model (test seam; default 60)
#
# ============================================================================
# WORKER EXEMPTION (HIMMEL-1417)
# ============================================================================
# This advisory targets a TOP-TIER PARENT implementing inline — never a
# dispatched Agent-tool worker executing its own assigned brief (the exact
# case CLAUDE.md's subagent policy wants: Sonnet as default implementor for
# a well-specified brief). The model-tail-sniffing above cannot tell the two
# apart: a worker's hook subprocess can end up tailing a transcript whose
# most recent assistant turn is the DISPATCHING PARENT's (Opus/Fable), not
# the worker's own model — a false fire on every worker edit (observed live,
# leg 14, CR rounds 3-6).
#
# A first attempt at this fix keyed the exemption on the CLAUDE_CODE_CHILD_
# SESSION=1 env var, on the basis that a dispatched worker's session carried
# it. That was FALSIFIED by direct parent-side ground truth: the genuine
# top-level orchestrator session (the one this guard exists to fire on) also
# has CLAUDE_CODE_CHILD_SESSION=1 when launched via the standard armed/
# scheduled overnight path — because in this harness a Task/Agent-tool
# dispatch runs as a nested sub-invocation of the SAME top-level session
# (same CLAUDE_CODE_SESSION_ID, same transcript file), not a separate CLI
# process with its own session identity. That env var reads as "this CLI
# process was itself launched as a child of something" (e.g. schtasks),
# unrelated to Agent-tool dispatch — so it would have silenced the guard for
# the exact parent it targets. Reverted.
#
# The correct, DOCUMENTED discriminator (code.claude.com/docs/en/hooks,
# "Common Input Fields"): when a PreToolUse hook fires inside a subagent
# call, the JSON payload carries an `agent_id` field ("Present only when the
# hook fires inside a subagent call. Use this to distinguish subagent hook
# calls from main-thread calls."). Unlike the env var or transcript-tail
# model sniffing, this is a first-class, explicitly-for-this-purpose field,
# not an inferred heuristic — so it is trusted directly rather than treated
# as best-effort. Absence of `agent_id` (top-level session) falls through
# unchanged to the existing model-tier heuristic below, preserving current
# fire-on-ambiguity behavior for the genuine parent-implements-inline case.
# ============================================================================
#
# bash 3.2-compatible (no ${var,,}, no mapfile, no associative arrays).
set -uo pipefail

warn() { echo "orchestrator-inline-guard: $*" >&2; }

[ "${ORCH_GUARD_DISABLE:-0}" = "1" ] && exit 0

command -v jq >/dev/null 2>&1 || { warn "jq not on PATH — allowing (fail-open, no nudge)"; exit 0; }

input=$(cat 2>/dev/null || true)
[ -n "$input" ] || exit 0

# Worker exemption (HIMMEL-1417) — see header. `agent_id` is present ONLY
# when this hook fires inside a subagent (Agent-tool dispatched) call; a
# dispatched worker's own edits are the desired pattern, not the anti-pattern
# this advisory exists to catch.
agent_id=$(printf '%s' "$input" | jq -r '.agent_id // empty' 2>/dev/null || true)
[ -n "$agent_id" ] && exit 0

tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)
case "$tool" in
    Edit|Write|NotebookEdit) ;;
    *) exit 0 ;;  # matcher already scopes this; defensive for direct invocation
esac

session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)
transcript_path=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null || true)
path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null || true)
[ -n "$path" ] || exit 0

# Normalize path separators — Windows payloads carry backslashes (octal \134
# avoids shellcheck SC1003's false single-quote-escape warning on a literal
# '\\', same armored approach as guard-memory-capture.sh).
path=$(printf '%s' "$path" | tr '\134' '/')

# ---- Exclusions (docs/prose/ledger/handover/scratchpad) — checked first, always win ----
case "$path" in
    */handovers/*|handovers/*) exit 0 ;;
    */docs/*|docs/*) exit 0 ;;
    */scratchpad/*|scratchpad/*) exit 0 ;;
    */.git/*) exit 0 ;;
    *ledger*|*.jsonl) exit 0 ;;
esac
# Markdown is prose/docs everywhere EXCEPT .claude/commands/ (see header).
case "$path" in
    */.claude/commands/*|.claude/commands/*) ;;
    *.md|*.MD) exit 0 ;;
esac

# ---- Inclusion (implementation surface) — must match at least one ----
included=0
case "$path" in
    scripts/*|*/scripts/*) included=1 ;;
esac
case "$path" in
    marketplace/plugins/*/src/*|*/marketplace/plugins/*/src/*) included=1 ;;
esac
case "$path" in
    .claude/commands/*|*/.claude/commands/*) included=1 ;;
esac
[ "$included" = "1" ] || exit 0

# ---- Model detection (best-effort; see header) ----
TAIL_LINES="${ORCH_GUARD_TRANSCRIPT_TAIL:-60}"
model=""
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
    while IFS= read -r line; do
        m=$(printf '%s' "$line" | jq -r '.message.model // empty' 2>/dev/null || true)
        [ -n "$m" ] && model="$m"
    done < <(tail -n "$TAIL_LINES" "$transcript_path" 2>/dev/null || true)
fi
[ -n "$model" ] || exit 0

model_lc=$(printf '%s' "$model" | tr '[:upper:]' '[:lower:]')
case "$model_lc" in
    *opus*|*fable*) ;;
    *) exit 0 ;;
esac

# ---- Fire: log + advisory ----
LOG="${ORCH_GUARD_LOG:-${HOME:-}/.claude/orchestrator-inline-guard/fires.jsonl}"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
jq -nc --arg ts "$now" --arg s "$session_id" --arg m "$model" --arg t "$tool" --arg p "$path" \
    '{ts:$ts,session:$s,model:$m,tool:$t,path:$p}' >> "$LOG" 2>/dev/null || true

jq -nc '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",additionalContext:"You are the orchestrating parent; this looks like implementation. Dispatch it to a worker lane (CLAUDE.md subagent policy) — one trivial CR-fix exemption per PR already spent?"}}'
exit 0
