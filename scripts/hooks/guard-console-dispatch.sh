#!/usr/bin/env bash
# guard-console-dispatch.sh — PreToolUse hook (matcher "Agent"): [HIMMEL-2323]
# structural fence for operator ruling 20 — PR/ticket-shaped work dispatched
# FROM A CONSOLE session must go to an armed DETACHED session with a mission
# doc (bash scripts/handover/arm-resume.sh), never an in-process Agent-tool
# subagent. In-process subagents die with the parent, are not relaunchable,
# and their reports land in the parent's own context — none of that survives
# a console session ending, and a console dying mid-flight loses the work
# outright. Agent-tool dispatch from a console stays sanctioned for bounded
# read-only research; this hook targets only the ship-flow shape.
#
# This is the CLAUDE.md "second drift" escalation: the ruling stood verbatim
# in its own handover chain and still drifted TWICE — most recently a console
# dispatching four PR-shaped writer legs as in-process subagents on
# 2026-08-31. Per root CLAUDE.md's "Adding a rule": first drift is signal, on
# the SECOND escalate to a hook/gate/classifier, never to stronger prose.
#
# DENY SEMANTICS: refuse only when BOTH hold —
#   1. the session is CONSOLE-shaped (see "Console detection" below), AND
#   2. the Agent dispatch's description+prompt match markers from AT LEAST
#      TWO DISTINCT ship-flow marker families (worktree / pr-open / cr-gate;
#      see below). A single-family match (a review brief that merely mentions
#      CodeRabbit, say) is deliberately NOT enough — the two-family
#      conjunction is the false-positive budget that keeps bounded read-only
#      research dispatches frictionless.
# Always-allow carve-out, checked BEFORE the family count: subagent_type
# "Explore" (the read-only search agent) — a real, STRUCTURAL read-only
# lane, not a claim made in prompt text.
#
# THERE IS DELIBERATELY NO PROMPT-TEXT READ-ONLY CARVE-OUT. Three CR rounds
# each shipped one and each round it leaked, in three different ways:
#   round 1: a partial-scope MODE alternative (`do not edit <X>`) matched a
#            genuine writer brief with a "do not edit the docs" aside.
#   round 2: closing that to a MODE-vs-OUTPUT principle (`analysis only` /
#            `plan only` kept, `return … recommendation` / `produce … plan`
#            dropped) still left OUTPUT-shaped forms that a writer brief can
#            end with ("create a worktree, open the PR, then return
#            recommendations").
#   round 3: even the surviving MODE-only forms leaked, because the phrase
#            can govern a subordinate CLAUSE rather than the whole dispatch
#            ("perform read-only analysis first, THEN <full ship flow>").
# Distinguishing "discusses the ship flow" from "orders the ship flow, with
# a read-only-sounding clause up front" is intent detection — three rounds
# of evidence say a regex over prompt text cannot do it here. So: not
# patched a fourth time, removed. The two carve-outs below are the only
# ones left, and both are load-bearing (structural / audited), never
# spoofable by the dispatch's own prompt text:
#   * subagent_type: Explore
#   * CONSOLE_DISPATCH_OK=1 (see "Escape hatches" below)
# A genuinely read-only dispatch uses one of those two; the deny message
# names both.
#
# Console detection (ordered, cheap, fail-open — unknown means NOT console):
#   1. HIMMEL_SESSION_ROLE (set in the LAUNCHING shell; session-sticky — a
#      per-call prefix does not reach a hook process). "console"
#      (case-insensitive) => console-shaped. Any other non-empty value =>
#      NOT console, decided, stop — an explicit non-console marker always
#      wins immediately, before the transcript is even read.
#   2. Otherwise, a BOUNDED head read of transcript_path (the launch prompt
#      lives in the first turns, unlike orchestrator-inline-guard.sh's
#      model-tail-sniff, which reads the END for the MOST RECENT turn) —
#      default CONSOLE_DISPATCH_TRANSCRIPT_HEAD_LINES leading JSONL lines,
#      scoped to the FIRST entry whose "type" is "user", further scoped to
#      the FIRST handover-doc path NAMED in that turn's own text (in order —
#      the launch prompt loads exactly one doc, and it is the first path
#      named; a LATER mention, e.g. a mission doc naming the console leg's
#      own doc further down the same turn, is not evidence of loading and
#      does not count, CR round 4 [codex-1]) — console-shaped only if THAT
#      first path's basename matches *-console.md. Scoping to the first
#      user turn (not the raw file head) matters: a system prompt, a tool
#      result, or an assistant turn merely MENTIONING such a path must not
#      count, only the session's own actual launch turn. This
#      is the same class of best-effort, explicitly-unsupported transcript
#      read orchestrator-inline-guard.sh documents for model detection: a
#      wrong read only ever costs a missed fire (fail-open), never a false
#      deny, because it is one signal among an AND-of-two-conditions gate.
#   3. Otherwise: NOT console. A missing/unreadable/unparseable transcript,
#      or no user turn found in the bound, allows.
# Test seam: the payload's own transcript_path field IS the seam (point it at
# a fixture in a test); CONSOLE_DISPATCH_TRANSCRIPT_HEAD_LINES tunes the
# bound.
#
# Escape hatches (set in the shell that LAUNCHED Claude Code; session-sticky):
#   CONSOLE_DISPATCH_OK=1       deliberate one-session carve-out
#   CONSOLE_DISPATCH_DISABLE=1  emergency kill switch
# Both are LOUD — warned on stderr and appended to CONSOLE_DISPATCH_LOG
# (default ~/.claude/console-dispatch-guard/overrides.jsonl), best-effort,
# mirroring guard-implementor-dispatch.sh's log_override().
#
# This is a WORKFLOW fence (scripts/hooks/CLAUDE.md's fail-open-vs-closed
# rule), not a security fence: it must never be the reason an unrelated
# dispatch can't run. Bash 3.2-compatible. Exit codes: 0 allow; 2 refuse.
set -uo pipefail

warn() { echo "guard-console-dispatch: $*" >&2; }

# grepq <text> [grep-args...] — never `printf | grep -q` under pipefail; see
# guard-implementor-dispatch.sh's identical helper for the SIGPIPE rationale
# (HIMMEL-1430).
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

input=$(cat 2>/dev/null || true)

log_override() {
    local override="$1" log now session subagent log_dir
    log="${CONSOLE_DISPATCH_LOG:-${HOME:-}/.claude/console-dispatch-guard/overrides.jsonl}"
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'unknown')
    session=""
    subagent=""
    log_dir=$(dirname "$log" 2>/dev/null || true)
    if [ -n "$log_dir" ]; then
        mkdir -p "$log_dir" 2>/dev/null || true
    fi
    if command -v jq >/dev/null 2>&1; then
        session=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)
        subagent=$(printf '%s' "$input" | jq -r '.tool_input.subagent_type // empty' 2>/dev/null || true)
        jq -nc --arg ts "$now" --arg o "$override" --arg s "$session" --arg a "$subagent" \
            '{ts:$ts,override:$o,session:$s,subagent_type:$a}' >> "$log" 2>/dev/null || true
    else
        printf '{"ts":"%s","override":"%s","session":"","subagent_type":""}\n' \
            "$now" "$override" >> "$log" 2>/dev/null || true
    fi
    warn "$override=1 — allowing by explicit session override; audit log: $log"
}

if [ "${CONSOLE_DISPATCH_OK:-0}" = "1" ]; then
    log_override CONSOLE_DISPATCH_OK
    exit 0
fi
if [ "${CONSOLE_DISPATCH_DISABLE:-0}" = "1" ]; then
    log_override CONSOLE_DISPATCH_DISABLE
    exit 0
fi

command -v jq >/dev/null 2>&1 || { warn "jq not on PATH — allowing (fail-open)"; exit 0; }
[ -n "$input" ] || exit 0

if ! tool=$(printf '%s' "$input" | jq -r '.tool_name | select(type == "string") // empty' 2>/dev/null); then
    warn "cannot parse hook input — allowing (fail-open)"
    exit 0
fi
[ "$tool" = "Agent" ] || exit 0

subagent_type=$(printf '%s' "$input" | jq -r '.tool_input.subagent_type | select(type == "string") // empty' 2>/dev/null || true)
case "$subagent_type" in
    Explore) exit 0 ;;
esac

text=$(printf '%s' "$input" | jq -r '[.tool_input.description, .tool_input.prompt] | map(select(type == "string")) | join("\n")' 2>/dev/null || true)
[ -n "$text" ] || exit 0

# ---- ship-flow marker families (case-insensitive; each an independent signal) ----
worktree_match=0
grepq "$text" -Eqi '\.claude/worktrees|clean-garden\.sh|git worktree|/worktree|create a worktree' && worktree_match=1
pr_open_match=0
grepq "$text" -Eqi 'gh pr create|open (the |a )pr([^[:alnum:]_]|$)|gh pr edit' && pr_open_match=1
cr_gate_match=0
grepq "$text" -Eqi '/pr-check|pr-check|cr-clean|clear-cr-marker|coderabbit' && cr_gate_match=1
family_count=$((worktree_match + pr_open_match + cr_gate_match))

# ---- console detection (see header) ----
is_console=0
role_lc=$(printf '%s' "${HIMMEL_SESSION_ROLE:-}" | tr '[:upper:]' '[:lower:]')
if [ -n "$role_lc" ]; then
    [ "$role_lc" = "console" ] && is_console=1
else
    transcript_path=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null || true)
    if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
        # Scope the scan to the FIRST USER TURN only, not the raw file head —
        # a raw byte-head scan classified ANY session as console the instant
        # early content merely MENTIONED a handover-console path (a doc, a
        # quoted brief, a tool result, an assistant turn, another leg's
        # mission text), which is the launch prompt for nobody. Read a
        # bounded number of leading JSONL LINES (not bytes — a byte cutoff
        # can truncate the last line into invalid JSON; a line cutoff never
        # does, since head -n only ever emits whole lines), find the FIRST
        # entry whose top-level "type" is "user", and match only that
        # entry's own message text. A system prompt, a tool result, or an
        # assistant turn mentioning the path no longer counts. No user turn
        # in the bound, or an unparseable line, is NOT console (fail-open).
        head_lines="${CONSOLE_DISPATCH_TRANSCRIPT_HEAD_LINES:-40}"
        first_user_text=""
        while IFS= read -r line; do
            entry_type=$(printf '%s' "$line" | jq -r '.type // empty' 2>/dev/null || true)
            if [ "$entry_type" = "user" ]; then
                # Stop HERE unconditionally — this is the turn to judge,
                # whether or not it produced any text. Continuing past an
                # empty/non-text first user turn to a LATER one would judge
                # the wrong turn (CR round 2 [codex-3]); empty text simply
                # fails the match below, which is NOT console (fail-open).
                first_user_text=$(printf '%s' "$line" | jq -r '
                    (.message.content) as $c
                    | if ($c | type) == "string" then $c
                      elif ($c | type) == "array" then ($c | map(.text? // empty) | join("\n"))
                      else empty end' 2>/dev/null || true)
                break
            fi
        done < <(head -n "$head_lines" "$transcript_path" 2>/dev/null || true)
        # Require a LOADED HANDOVER-DOC PATH, not a bare filename mention: an
        # unbroken run of path-like characters spanning "handover" (any
        # segment containing it, e.g. "handovers"), a path separator, and a
        # filename ending ".md" — the shape of a real
        # handovers/<user>/<repo>/…-console.md load line. A bare grep for
        # `*-console.md` alone false-positived on ANY session that read this
        # hook's own header, docs/internals/enforcement.md's guard section, or
        # this hook's test fixtures (all of which mention the glob in prose,
        # not as a path) — the exact false-positive the two-family
        # conjunction was supposed to make impossible. Natural-language prose
        # cannot satisfy this: the character class excludes spaces and JSON
        # escape backslashes, so "handover-doc path whose basename matches
        # *-console.md" never bridges the gap. The separator class accepts
        # BOTH "/" and "\" (CR round 2 [codex-2]) — this repo runs on
        # Windows/Git-Bash, jq has already decoded any JSON-escaped
        # backslash by the time this matches, and a native Windows handover
        # path (…\handovers\…\X-console.md) must still be recognised.
        # CR round 3 [codex-1] confirmed this already works (POSIX bracket
        # expressions treat "\" as a literal, not an escape); `\\` below is
        # cosmetic hardening only, spelling the class unambiguously so it
        # does not depend on that POSIX-vs-other-regex-flavor nuance.
        #
        # CR round 4 [codex-1]: a MATCH anywhere in the turn is not proof of
        # LOADING. A mission doc routinely names the console leg and ITS
        # doc further down the same turn ("load W1-mission.md ... report to
        # the console leg, doc 31P-console.md") — that is a false deny of an
        # ordinary armed leg's own dispatches, not a real console session.
        # The launch prompt loads exactly one doc, and it is the FIRST path
        # named — so extract every handover-doc path in the turn, in order
        # (grep -o preserves match order; `| head -n 1` takes the first),
        # and the session is console-shaped only if THAT path's basename
        # ends "-console.md". A later console-doc mention, after a
        # different doc has already been named, no longer counts.
        # HIMMEL_SESSION_ROLE remains the PRIMARY, exact signal (checked
        # above, before any transcript is read) — this whole block is only
        # the fallback for a session launched without it, and this rule
        # makes that fallback's failure mode a miss, not a false deny.
        first_doc_path=""
        if [ -n "$first_user_text" ]; then
            first_doc_path=$(printf '%s' "$first_user_text" | grep -Eoi 'handover[A-Za-z0-9_./\\-]*[/\\][A-Za-z0-9_.-]*\.md' 2>/dev/null | head -n 1 || true)
        fi
        if [ -n "$first_doc_path" ] && grepq "$first_doc_path" -Eqi -- '-console\.md$'; then
            is_console=1
        fi
    fi
fi
[ "$is_console" = "1" ] || exit 0

[ "$family_count" -ge 2 ] || exit 0

families=""
[ "$worktree_match" = "1" ] && families="${families}worktree,"
[ "$pr_open_match" = "1" ] && families="${families}pr-open,"
[ "$cr_gate_match" = "1" ] && families="${families}cr-gate,"
families="${families%,}"

deny_msg="You are a CONSOLE session dispatching PR/ship-flow-shaped work ($families) as an
in-process Agent-tool subagent — DENIED (standing operator ruling 20).

In-process subagents die with the parent, are not relaunchable, and their reports land in the
parent's own context — none of that survives a console session ending, and a console dying
mid-flight loses the work outright.

Do this instead:
  1. Write a mission doc into the handover state repo.
  2. Arm a detached session against it:
       bash scripts/handover/arm-resume.sh --time smart --handover <path-to-mission-doc>
     (--time smart is the usage-aware slot: relaunch ASAP once the bank has headroom, else at
     the binding window's reset; the handover file's resume_cwd: frontmatter sets the working
     directory.)

Genuinely read-only work has two structural options, neither spoofable by prompt text (a
prompt-text read-only claim is NOT a carve-out here — three CR rounds proved it leaks):
  * dispatch with subagent_type: Explore, or
  * relaunch with CONSOLE_DISPATCH_OK=1 in the launching shell (audited; a per-call prefix
    does not reach this hook)."

reason=$(printf '%s' "$deny_msg" | jq -Rs . 2>/dev/null) \
    || reason='"guard-console-dispatch: console session denied a ship-flow-shaped Agent dispatch"'
# Belt-and-braces deny: structured permissionDecision:"deny" on stdout PLUS
# exit 2 + stderr (see orchestrator-inline-guard.sh for the same idiom).
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$reason"
printf '%s\n' "$deny_msg" >&2
exit 2
