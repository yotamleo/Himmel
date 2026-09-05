#!/usr/bin/env bash
# Tests for scripts/hooks/guard-console-dispatch.sh (HIMMEL-2323).
#
# Usage: bash scripts/hooks/test-guard-console-dispatch.sh
set -uo pipefail

# grepq <text> [grep-args...] — never `printf | grep -q` under pipefail
# (HIMMEL-1430; see guard-implementor-dispatch.sh's identical helper).
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/guard-console-dispatch.sh"
[ -x "$HOOK" ] || chmod +x "$HOOK" 2>/dev/null || true

TMP="$(mktemp -d "${TMPDIR:-/tmp}/himmel-console-guard.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

BASH_ABS=$(command -v bash)
if [ -z "$BASH_ABS" ]; then
    echo "FATAL: cannot resolve bash on PATH" >&2
    exit 1
fi

pass=0
fail=0

assert_rc() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "ok   $label (rc=$actual)"
        pass=$((pass + 1))
    else
        echo "FAIL $label — expected rc=$expected, got rc=$actual"
        fail=$((fail + 1))
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if grepq "$haystack" -F "$needle"; then
        echo "ok   $label"
        pass=$((pass + 1))
    else
        echo "FAIL $label — missing '$needle'"
        echo "  actual: $haystack"
        fail=$((fail + 1))
    fi
}

assert_empty() {
    local label="$1" actual="$2"
    if [ -z "$actual" ]; then
        echo "ok   $label"
        pass=$((pass + 1))
    else
        echo "FAIL $label — expected empty, got: $actual"
        fail=$((fail + 1))
    fi
}

# payload <subagent_type> <description> <prompt> [transcript_path]
payload() {
    jq -nc --arg st "$1" --arg d "$2" --arg p "$3" --arg tp "${4:-}" \
        '{tool_name:"Agent",session_id:"sess-test",transcript_path:$tp,tool_input:{subagent_type:$st,description:$d,prompt:$p}}'
}

run_hook() {
    local name="$1" json="$2"; shift 2
    printf '%s' "$json" | env "$@" "$BASH_ABS" "$HOOK" \
        >"$TMP/out-$name" 2>"$TMP/err-$name"
    echo "$?"
}

combined_output() {
    cat "$TMP/out-$1" "$TMP/err-$1" 2>/dev/null
}

# --- transcript fixtures ---
CONSOLE_TRANSCRIPT="$TMP/leg-console.md-loaded.jsonl"
printf '%s\n' '{"type":"user","message":{"content":"Loaded handover: handovers/yotam/himmel/leg-console.md — resume from there."}}' > "$CONSOLE_TRANSCRIPT"

LEG_TRANSCRIPT="$TMP/leg-w1-normal.jsonl"
printf '%s\n' '{"type":"user","message":{"content":"Loaded handover: handovers/yotam/himmel/HIMMEL-2323-w1.md — implement the guard."}}' > "$LEG_TRANSCRIPT"

MISSING_TRANSCRIPT="$TMP/does-not-exist.jsonl"

# HIMMEL-2323 CR round 1 [w1-2323-b7d2]: the transcript scan must require a
# LOADED HANDOVER-DOC PATH, not a bare "*-console.md" mention — a session
# that merely READ this hook's own header (which discusses "*-console.md" in
# prose) must not be classified console-shaped.
SELF_REFERENCE_TRANSCRIPT="$TMP/self-reference.jsonl"
printf '%s\n' '{"type":"user","message":{"content":"tool_result: a loaded handover-doc path whose basename matches *-console.md"}}' > "$SELF_REFERENCE_TRANSCRIPT"

BARE_FILENAME_TRANSCRIPT="$TMP/bare-filename.jsonl"
printf '%s\n' '{"type":"user","message":{"content":"See notes-console.md for context."}}' > "$BARE_FILENAME_TRANSCRIPT"

REAL_HANDOVER_TRANSCRIPT="$TMP/real-handover.jsonl"
printf '%s\n' '{"type":"user","message":{"content":"Loaded handover: /home/yotamleo/state/handovers/yotamleo/himmel/HIMMEL-2323-console.md — resume from there."}}' > "$REAL_HANDOVER_TRANSCRIPT"

# HIMMEL-2323 CR round 2 [w1-2323-b7d2] [codex-2]: the scan must be scoped to
# the FIRST USER TURN, not any early line — a system prompt, tool result, or
# assistant turn merely mentioning a handover-console path must not count.
ASSISTANT_TURN_TRANSCRIPT="$TMP/assistant-turn-only.jsonl"
printf '%s\n' \
    '{"type":"assistant","message":{"content":"noting path /home/x/state/handovers/yotamleo/himmel/other-console.md for later"}}' \
    '{"type":"user","message":{"content":"Just get started on the usual thing."}}' \
    > "$ASSISTANT_TURN_TRANSCRIPT"

NO_USER_TURN_TRANSCRIPT="$TMP/no-user-turn.jsonl"
printf '%s\n' \
    '{"type":"system","message":{"content":"session init"}}' \
    '{"type":"assistant","message":{"content":"handovers/yotamleo/himmel/other-console.md noted"}}' \
    > "$NO_USER_TURN_TRANSCRIPT"

# [codex-2]: a native Windows path (backslash separators).
WINDOWS_PATH_TRANSCRIPT="$TMP/windows-path.jsonl"
printf '%s\n' '{"type":"user","message":{"content":"Loaded handover: C:\\state\\handovers\\yotamleo\\himmel\\HIMMEL-2323-console.md"}}' > "$WINDOWS_PATH_TRANSCRIPT"

# [codex-3]: the FIRST user entry has empty content; a LATER user turn
# carries the console path. Must judge the first (empty) turn only, so this
# must NOT be console.
EMPTY_FIRST_USER_TRANSCRIPT="$TMP/empty-first-user.jsonl"
printf '%s\n' \
    '{"type":"user","message":{"content":[]}}' \
    '{"type":"user","message":{"content":"Loaded handover: handovers/yotamleo/himmel/HIMMEL-2323-console.md — resume from there."}}' \
    > "$EMPTY_FIRST_USER_TRANSCRIPT"

# CR round 4 [codex-1]: a mission doc routinely NAMES the console leg and its
# doc further down the same turn — that mention is not evidence of LOADING.
# The doc actually being loaded is the FIRST path named (the mission doc).
MISSION_THEN_CONSOLE_MENTION_TRANSCRIPT="$TMP/mission-then-console-mention.jsonl"
printf '%s\n' '{"type":"user","message":{"content":"load handovers/yotamleo/himmel/W1-mission.md overnight mode. Report to the console leg whose doc is handovers/yotamleo/himmel/31P-console.md when done."}}' > "$MISSION_THEN_CONSOLE_MENTION_TRANSCRIPT"

# Two non-console handover docs named; no console anywhere in the turn.
TWO_MISSION_DOCS_TRANSCRIPT="$TMP/two-mission-docs.jsonl"
printf '%s\n' '{"type":"user","message":{"content":"load handovers/yotamleo/himmel/W1-mission.md, cross-reference handovers/yotamleo/himmel/W2-notes.md, and proceed."}}' > "$TWO_MISSION_DOCS_TRANSCRIPT"

SHIP_FLOW_PROMPT='Create a worktree at .claude/worktrees/fix-x, land the change, then run gh pr create --title x, then run /pr-check to get it CR-clean.'
ONE_FAMILY_PROMPT='Review this and check for any CodeRabbit-flagged issues in the diff.'
RESEARCH_PROMPT='Investigate how the worktree lifecycle works; report findings only, no changes.'
# [codex-3]: exercise the POSIX-boundary "open a PR" phrasing directly
# (previously relied on a GNU-only \b).
OPEN_A_PR_PROMPT='Create a worktree at .claude/worktrees/fix-x and open a PR for it.'
# HIMMEL-2323 CR round 3: there is no prompt-text read-only carve-out any
# more (three rounds each shipped one and each leaked it a different way —
# see the hook's own header). This prompt genuinely DISCUSSES the ship flow
# rather than ordering it, which is exactly the shape the deleted carve-out
# used to rescue — it must now refuse like any other >=2-family match.
READONLY_DISCUSS_NOW_DENIES='Read-only. Review how the .claude/worktrees flow and the gh pr create step work, then report.'
# CR round 3 [codex-2]: even a MODE declaration ("read-only analysis" / "do
# analysis only") governing a subordinate CLAUSE, with a full ship-flow
# instruction following it, must refuse — the deleted carve-out could not
# tell "this whole brief is read-only" from "this whole brief is a writer
# brief with a read-only-sounding clause up front", and it leaked exactly
# that way in this hook's own CR history.
READONLY_ANALYSIS_CLAUSE_BYPASS="Perform read-only analysis first, then ${SHIP_FLOW_PROMPT}"
ANALYSIS_ONLY_CLAUSE_BYPASS="Do analysis only on the config, then ${SHIP_FLOW_PROMPT}"

echo "=== DENY: console-shaped + >=2 ship-flow families ==="

RC1=$(run_hook env-console-worktree-propen "$(payload general-purpose 'ship it' "$SHIP_FLOW_PROMPT")" HIMMEL_SESSION_ROLE=console)
assert_rc "env console + worktree + gh pr create refuses" 2 "$RC1"
assert_contains "deny names the exact arm-resume.sh replacement" "bash scripts/handover/arm-resume.sh --time smart --handover <path-to-mission-doc>" "$(combined_output env-console-worktree-propen)"
assert_contains "deny states in-process subagents die with the parent" "die with the parent" "$(combined_output env-console-worktree-propen)"
assert_contains "deny names CONSOLE_DISPATCH_OK override" "CONSOLE_DISPATCH_OK=1" "$(combined_output env-console-worktree-propen)"

RC2=$(run_hook transcript-console-propen-crgate "$(payload general-purpose 'ship it' 'gh pr create --title x; then run /pr-check' "$CONSOLE_TRANSCRIPT")")
assert_rc "transcript-detected console + pr-open + cr-gate refuses" 2 "$RC2"

RC3=$(run_hook env-console-worktree-crgate "$(payload general-purpose 'ship it' 'Create a worktree at .claude/worktrees/fix-x and get it CR-clean via /pr-check.')" HIMMEL_SESSION_ROLE=console)
assert_rc "env console + worktree + cr-gate (third pairing) refuses" 2 "$RC3"

RC3A=$(run_hook real-handover-path-survives "$(payload general-purpose 'ship it' "$SHIP_FLOW_PROMPT" "$REAL_HANDOVER_TRANSCRIPT")")
assert_rc "real handovers/.../HIMMEL-2323-console.md load line + full ship-flow prompt still refuses (tightened regex positive survives)" 2 "$RC3A"

RC_OPENPR=$(run_hook open-a-pr-boundary "$(payload general-purpose 'ship it' "$OPEN_A_PR_PROMPT")" HIMMEL_SESSION_ROLE=console)
assert_rc "codex-3: 'open a PR' (POSIX boundary, no GNU \\b) + worktree refuses" 2 "$RC_OPENPR"

RC_WINPATH=$(run_hook windows-path-survives "$(payload general-purpose 'ship it' "$SHIP_FLOW_PROMPT" "$WINDOWS_PATH_TRANSCRIPT")")
assert_rc "codex-2: native Windows backslash handover path in the first user turn still refuses" 2 "$RC_WINPATH"

RC_READONLY_DISCUSS=$(run_hook readonly-discuss-now-denies "$(payload general-purpose 'ship it' "$READONLY_DISCUSS_NOW_DENIES")" HIMMEL_SESSION_ROLE=console)
assert_rc "CR round 3: deliberate posture change — the prompt-text read-only carve-out is DELETED, so a brief DISCUSSING the ship flow now refuses like any other; use subagent_type Explore or CONSOLE_DISPATCH_OK=1 instead" 2 "$RC_READONLY_DISCUSS"

RC_READONLY_CLAUSE=$(run_hook readonly-analysis-clause-bypass "$(payload general-purpose 'ship it' "$READONLY_ANALYSIS_CLAUSE_BYPASS")" HIMMEL_SESSION_ROLE=console)
assert_rc "CR round 3 codex-2: 'perform read-only analysis first, then <ship flow>' — a MODE clause governing part of a writer brief — still refuses" 2 "$RC_READONLY_CLAUSE"

RC_ANALYSIS_ONLY_CLAUSE=$(run_hook analysis-only-clause-bypass "$(payload general-purpose 'ship it' "$ANALYSIS_ONLY_CLAUSE_BYPASS")" HIMMEL_SESSION_ROLE=console)
assert_rc "CR round 3 codex-2: 'do analysis only on the config, then <ship flow>' still refuses" 2 "$RC_ANALYSIS_ONLY_CLAUSE"

echo "=== ALLOW: false-positive budget ==="

RC_EMPTY_FIRST_USER=$(run_hook empty-first-user-not-console "$(payload general-purpose 'ship it' "$SHIP_FLOW_PROMPT" "$EMPTY_FIRST_USER_TRANSCRIPT")")
assert_rc "codex-3: empty first user turn is judged (not skipped past to a later user turn) — NOT console" 0 "$RC_EMPTY_FIRST_USER"

RC_ASSISTANT_TURN=$(run_hook assistant-turn-not-console "$(payload general-purpose 'ship it' "$SHIP_FLOW_PROMPT" "$ASSISTANT_TURN_TRANSCRIPT")")
assert_rc "codex-2: console path mentioned only in an assistant turn (not the first user turn) is NOT console-shaped" 0 "$RC_ASSISTANT_TURN"

RC_NO_USER_TURN=$(run_hook no-user-turn-fails-open "$(payload general-purpose 'ship it' "$SHIP_FLOW_PROMPT" "$NO_USER_TURN_TRANSCRIPT")")
assert_rc "codex-2: transcript with no user turn at all fails open (NOT console)" 0 "$RC_NO_USER_TURN"

RC_MISSION_THEN_MENTION=$(run_hook mission-then-console-mention-not-console "$(payload general-purpose 'ship it' "$SHIP_FLOW_PROMPT" "$MISSION_THEN_CONSOLE_MENTION_TRANSCRIPT")")
assert_rc "CR round 4 codex-1: mission doc loaded first, console leg's doc only MENTIONED later in the same turn — NOT console (the false deny this round closes)" 0 "$RC_MISSION_THEN_MENTION"

RC_TWO_MISSION_DOCS=$(run_hook two-mission-docs-not-console "$(payload general-purpose 'ship it' "$SHIP_FLOW_PROMPT" "$TWO_MISSION_DOCS_TRANSCRIPT")")
assert_rc "two non-console handover docs named, no console anywhere — NOT console" 0 "$RC_TWO_MISSION_DOCS"

RC_ENV_WINS_OVER_MISSION=$(run_hook env-console-wins-over-mission-doc "$(payload general-purpose 'ship it' "$SHIP_FLOW_PROMPT" "$LEG_TRANSCRIPT")" HIMMEL_SESSION_ROLE=console)
assert_rc "HIMMEL_SESSION_ROLE=console still wins over a transcript whose first user turn loads a MISSION (non-console) doc" 2 "$RC_ENV_WINS_OVER_MISSION"

RC_SELFREF=$(run_hook self-reference-not-console "$(payload general-purpose 'ship it' "$SHIP_FLOW_PROMPT" "$SELF_REFERENCE_TRANSCRIPT")")
assert_rc "transcript quoting this hook's own *-console.md prose is NOT console-shaped (self-reference regression)" 0 "$RC_SELFREF"

RC_BAREFILE=$(run_hook bare_filename-not-console "$(payload general-purpose 'ship it' "$SHIP_FLOW_PROMPT" "$BARE_FILENAME_TRANSCRIPT")")
assert_rc "bare notes-console.md filename mention (no handover path) is NOT console-shaped" 0 "$RC_BAREFILE"

RC4=$(run_hook not-console-full-shipflow "$(payload general-purpose 'ship it' "$SHIP_FLOW_PROMPT" "$LEG_TRANSCRIPT")")
assert_rc "NOT console (non-console transcript) + full ship-flow prompt stays frictionless" 0 "$RC4"
assert_empty "armed leg dispatch is silent" "$(combined_output not-console-full-shipflow)"

RC5=$(run_hook console-research "$(payload general-purpose 'investigate' "$RESEARCH_PROMPT")" HIMMEL_SESSION_ROLE=console)
assert_rc "console + bounded read-only research prompt (no markers) allowed" 0 "$RC5"
assert_empty "console research is silent" "$(combined_output console-research)"

RC6=$(run_hook console-one-family "$(payload general-purpose 'review' "$ONE_FAMILY_PROMPT")" HIMMEL_SESSION_ROLE=console)
assert_rc "console + only ONE family (CodeRabbit mention) allowed" 0 "$RC6"
assert_empty "console one-family mention is silent" "$(combined_output console-one-family)"

RC7=$(run_hook console-explore "$(payload Explore 'ship it' "$SHIP_FLOW_PROMPT")" HIMMEL_SESSION_ROLE=console)
assert_rc "console + subagent_type Explore + ship-flow markers allowed" 0 "$RC7"

RC9=$(run_hook role-leg-wins "$(payload general-purpose 'ship it' "$SHIP_FLOW_PROMPT")" HIMMEL_SESSION_ROLE=leg)
assert_rc "HIMMEL_SESSION_ROLE=leg + full ship-flow prompt: explicit non-console wins" 0 "$RC9"

BASH_PAYLOAD='{"tool_name":"Bash","session_id":"sess-test","tool_input":{"command":"echo hi"}}'
RC10=$(run_hook non-agent-tool "$BASH_PAYLOAD" HIMMEL_SESSION_ROLE=console)
assert_rc "non-Agent tool_name allowed" 0 "$RC10"

RC11=$(run_hook missing-transcript "$(payload general-purpose 'ship it' "$SHIP_FLOW_PROMPT" "$MISSING_TRANSCRIPT")")
assert_rc "missing/unreadable transcript + no env marker + full ship-flow prompt fails open" 0 "$RC11"

RC12=$(printf '%s' 'not json at all' | env HIMMEL_SESSION_ROLE=console "$BASH_ABS" "$HOOK" >"$TMP/out-malformed" 2>"$TMP/err-malformed"; echo $?)
assert_rc "malformed JSON on stdin allows" 0 "$RC12"

RC13=$(printf '' | env HIMMEL_SESSION_ROLE=console "$BASH_ABS" "$HOOK" >"$TMP/out-empty" 2>"$TMP/err-empty"; echo $?)
assert_rc "empty stdin allows" 0 "$RC13"

STUB_NOJQ_DIR="$TMP/stub-no-jq"
mkdir -p "$STUB_NOJQ_DIR"
STUB_PATH_NO_JQ=$(printf '%s' "$PATH" | tr ':' '\n' | while IFS= read -r _d; do
    [ -n "$_d" ] || continue
    [ -x "$_d/jq" ] || [ -x "$_d/jq.exe" ] || printf '%s\n' "$_d"
done | tr '\n' ':')
RC14=$(printf '%s' "$(payload general-purpose 'ship it' "$SHIP_FLOW_PROMPT")" | env HIMMEL_SESSION_ROLE=console PATH="$STUB_PATH_NO_JQ" "$BASH_ABS" "$HOOK" >"$TMP/out-nojq" 2>"$TMP/err-nojq"; echo $?)
assert_rc "jq absent allows (fail-open)" 0 "$RC14"

echo "=== Overrides ==="

DENIED_JSON="$(payload general-purpose 'ship it' "$SHIP_FLOW_PROMPT")"
OK_LOG="$TMP/ok-overrides.jsonl"
RC15=$(run_hook override-ok "$DENIED_JSON" HIMMEL_SESSION_ROLE=console CONSOLE_DISPATCH_OK=1 CONSOLE_DISPATCH_LOG="$OK_LOG")
assert_rc "CONSOLE_DISPATCH_OK=1 overrides an otherwise-denied payload" 0 "$RC15"
assert_contains "override audit log records CONSOLE_DISPATCH_OK" '"override":"CONSOLE_DISPATCH_OK"' "$(cat "$OK_LOG" 2>/dev/null || true)"

DISABLE_LOG="$TMP/disable-overrides.jsonl"
RC16=$(run_hook override-disable "$DENIED_JSON" HIMMEL_SESSION_ROLE=console CONSOLE_DISPATCH_DISABLE=1 CONSOLE_DISPATCH_LOG="$DISABLE_LOG")
assert_rc "CONSOLE_DISPATCH_DISABLE=1 overrides an otherwise-denied payload" 0 "$RC16"

echo ""
echo "$((pass + fail)) checks, $pass passed, $fail failed"
if [ "$fail" -eq 0 ]; then
    echo "SUMMARY: All guard-console-dispatch.sh cases passed."
    exit 0
else
    echo "SUMMARY: $fail case(s) failed."
    exit 1
fi
