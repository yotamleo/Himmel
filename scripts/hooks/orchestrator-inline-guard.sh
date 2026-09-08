#!/usr/bin/env bash
# orchestrator-inline-guard.sh — PreToolUse hook (matcher "Edit|Write|NotebookEdit"):
# per-PR budget gate when a top-tier parent session (Fable/Opus) edits an
# implementation-surface file directly instead of dispatching to a worker lane
# (HIMMEL-1384 phase 1 advisory; HIMMEL-1791 phase 2 DENY — CLAUDE.md "Subagent
# policy": inline implementation on a top-tier parent is the anti-pattern, sole
# exception is one trivial CR-fix per PR). Escalates HIMMEL-166/688 per the
# repo's own "second drift -> structural" doctrine (operator, 2026-07-29: "i
# always find myself re-enforcing this"): the phase-1 advisory fired EIGHT
# times in one leg (2026-08-15) and was overridden every time — "hook
# additionalContext ≠ compliance".
#
# DENY SEMANTICS (HIMMEL-1791):
#   - The one-per-PR exemption is tracked STRUCTURALLY, per BRANCH (a branch
#     is a PR here) — the branch of the worktree that HOLDS THE EDITED FILE,
#     not the session's cwd (HIMMEL-1976; the cwd keying charged a primary-
#     checkout parent's every worktree edit to "main"), and never the repo's
#     default branch — under <git-common-dir>/inline-impl-spent/ — same shared
#     git-common-dir convention as cr-pending/<branch> and cr-prior-blocking/
#     <branch>, except the branch is percent-encoded into ONE filename
#     segment (CR r1: a raw <branch> path let feat/x's mkdir -p create the
#     directory where branch feat's state FILE lives — false deny in one
#     order, permanently unenforceable budget in the other; see the state
#     section below). The
#     git-COMMON-dir (not the per-worktree git dir) is load-bearing: it is
#     shared across every worktree in the checkout and himmel runs concurrent
#     work in many worktrees by design. PER PR, NOT PER ROUND — counting per
#     round is exactly the drift that happened.
#   - FIRST qualifying inline edit on a branch: ALLOW and record it (state
#     file + fires.jsonl row) with an advisory that the exemption is now
#     spent — or, if the record write fails, an advisory that says plainly
#     the budget was NOT recorded (CR r1 codex-1; allow stands, fail-open).
#     SECOND and later: DENY, except an identical SAME-SESSION retry of the
#     recorded edit (same path), which is allowed without a new spend (CR r1
#     glm-4 — the budget is spent at PreToolUse intent, so a tool-level
#     failure of the first Edit must not cost the legitimate retry).
#     DENY (structured permissionDecision:"deny" on
#     stdout, which overrides the exit code, PLUS exit 2 + stderr — the
#     belt-and-braces idiom; see test-block-glm-external-writes.sh round 4).
#   - The deny message carries the sanctioned recovery: dispatch via the Agent
#     tool with an explicit model tier (CLAUDE.md subagent policy; HIMMEL-1967
#     — impl routes to native Claude subagents only, NOT
#     scripts/telegram/dispatch-lane.sh, whose unqualified impl dispatch
#     exits 2 for exactly this class of work, HIMMEL-2210) so the sanctioned
#     path is easier than the blocked one, AND names the ESCALATION path
#     (a higher-tier model, or the Fable tier): a parent reading a blocked or
#     struggling worker as licence to implement inline is the specific hole
#     that produced two of the eight phase-1 overrides. Inline is never the
#     only option.
#
# CARVE-OUTS — never denied, never consume the budget:
#   - in-progress merge/rebase (MERGE_HEAD / REBASE_HEAD / rebase-merge /
#     rebase-apply present in the worktree's git dir) — conflict resolution is
#     genuinely parent work;
#   - handover-state repo paths, docs-only paths, and the CR ledger / marker
#     machinery (excluded by the path scoping below: handovers/, docs/,
#     scratchpad/, .git/, *ledger*, *.jsonl, prose .md);
#   - test-only edits are NOT carved out — they are implementation.
#
# Escape hatches (set in the shell that LAUNCHED Claude Code; session-sticky —
# a per-call prefix does NOT reach a hook process):
#   INLINE_IMPL_OK=1       HIMMEL-1791 deliberate override — LOUD: warns on
#                          stderr and appends a decision:"override" row to the
#                          fire log, so an override is auditable, never silent
#   ORCH_GUARD_DISABLE=1   silent emergency kill switch (phase-1 behaviour)
#
# FAIL-OPEN POSTURE: every unresolvable input (missing jq, unreadable
# transcript, non-repo cwd, unreadable branch) ALLOWS. The budget DENIES only
# on positive evidence (the branch's state file exists). The state WRITE may
# fail silently (`|| true` + warn) — a lost record fail-opens later edits, it
# never bricks the current one.
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
# the in-memory conversation by a turn). Phase 1 justified it with "a wrong
# read only ever costs a missed or spurious nudge, never a block"; phase 2's
# deny changes that arithmetic, so the blast radius of a wrong read is now
# bounded by four structural hatches: (1) the HIMMEL-1417 worker exemption
# (`agent_id`) is a first-class field checked BEFORE any gating; (2) an
# unreadable/unparseable transcript defaults toward NOT firing (not top-tier
# => silent allow); (3) the FIRST qualifying edit on a branch is always
# allowed — a deny needs a prior recorded spend, so a single misread never
# blocks the edit in front of it; (4) INLINE_IMPL_OK=1 (audited) releases the
# session. If Claude Code changes the transcript shape, this hook degrades to
# permanently silent — not to a false deny. A durable fix (e.g. a SessionStart
# hook caching `.model` to a per-session file) remains a separate ticket.
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
# On trigger: appends one jsonl row ({ts, session, model, tool, path,
# decision}) to ~/.claude/orchestrator-inline-guard/fires.jsonl (decision =
# exempt-allow | exempt-allow-unrecorded | retry-allow | deny | override |
# allow-no-branch | allow-default-branch — the counter-metric
# HIMMEL-1384 seeded) and then allows-with-advisory (first spend), denies
# (budget spent), or allows (override / unresolvable branch). Log failures
# never fail the hook (append-only, best-effort, `|| true`).
#
# Env knobs (all optional):
#   ORCH_GUARD_DISABLE=1        silent kill switch (launching-shell convention)
#   INLINE_IMPL_OK=1            loud audited override (HIMMEL-1791)
#   ORCH_GUARD_LOG               fire-log path override (test seam; default
#                                ~/.claude/orchestrator-inline-guard/fires.jsonl)
#   ORCH_GUARD_STATE_DIR         budget-state base dir override (test seam;
#                                default <git-common-dir>/inline-impl-spent)
#   ORCH_GUARD_TRANSCRIPT_TAIL   lines tailed from transcript_path when
#                                sniffing the model (test seam; default 60)
#
# ============================================================================
# WORKER EXEMPTION (HIMMEL-1417)
# ============================================================================
# This guard targets a TOP-TIER PARENT implementing inline — never a
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

command -v jq >/dev/null 2>&1 || { warn "jq not on PATH — allowing (fail-open, no gate)"; exit 0; }

input=$(cat 2>/dev/null || true)
[ -n "$input" ] || exit 0

# Worker exemption (HIMMEL-1417) — see header. `agent_id` is present ONLY
# when this hook fires inside a subagent (Agent-tool dispatched) call; a
# dispatched worker's own edits are the desired pattern, not the anti-pattern
# this guard exists to catch.
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
# Test files are deliberately NOT carved out (HIMMEL-1791): scripts/** test
# suites are implementation.
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

# ---- Fire log (counter-metric) + shared timestamp ----
LOG="${ORCH_GUARD_LOG:-${HOME:-}/.claude/orchestrator-inline-guard/fires.jsonl}"
LOG_DIR=$(dirname "$LOG" 2>/dev/null || true)
if [ -n "$LOG_DIR" ]; then
    mkdir -p "$LOG_DIR" 2>/dev/null || true
fi
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

fire_log() {  # fire_log <decision> — one jsonl row, best-effort
    jq -nc --arg ts "$now" --arg s "$session_id" --arg m "$model" --arg t "$tool" --arg p "$path" --arg d "$1" \
        '{ts:$ts,session:$s,model:$m,tool:$t,path:$p,decision:$d}' >> "$LOG" 2>/dev/null || true
}

# ---- Escape hatch (HIMMEL-1791): loud, audited override. Checked only once
# the edit is a qualifying gate candidate, so the audit row records exactly
# the edits the gate would have acted on. An override does NOT spend the
# budget: the exemption stays for a genuine trivial CR-fix; overrides are a
# separate, explicitly audited authority.
if [ "${INLINE_IMPL_OK:-0}" = "1" ]; then
    warn "INLINE_IMPL_OK=1 — allowing inline implementation by explicit session override (audited in $LOG)"
    fire_log override
    exit 0
fi

# ---- Repo context for the per-branch budget (HIMMEL-1791/1976) ----
# The budget is per PR, and the PR is the branch of the worktree that HOLDS
# the edited file — NOT the session's cwd (HIMMEL-1976). A parent works from
# the primary checkout (on main, by design for the lane workflow) and edits
# files inside worktrees; keying on cwd charged every such edit to "main",
# whose one spend on 2026-08-16 was never un-spent, making the one-trivial-
# CR-fix-per-PR exemption structurally ZERO. So: resolve the branch from
# dirname(file_path) when that path is ABSOLUTE and inside a work tree, and
# fall back to the cwd only when it is not. Relative paths (test fixtures,
# defensive direct invocation) always take the cwd — resolving them against
# the hook's own PWD would silently name whatever repo the hook runs in.
# Everything downstream (merge/rebase carve-out, git-common-dir state base)
# anchors on the SAME dir the branch came from, so a file in another checkout
# keeps its budget there. Every git failure allows (fail-open): the budget
# denies only on positive evidence.
command -v git >/dev/null 2>&1 || exit 0
cwd_dir=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)
[ -n "$cwd_dir" ] || cwd_dir="${CLAUDE_PROJECT_DIR:-}"
[ -n "$cwd_dir" ] || cwd_dir="$PWD"

repo_dir=""
branch=""
branch_src=""
# `$path` reached here ALREADY separator-normalized (tr '\134' '/' above), so
# a Windows payload is `C:/repo/file` by now and dirname sees only '/' — the
# arm below is safe on both platforms (CR r1+r2 codex-1 flagged the raw
# `C:\repo\file` form twice, reading this hunk without that earlier line).
case "$path" in
    /*|[A-Za-z]:*)
        file_dir=$(dirname "$path")
        # A Write can create a file under a directory that does not exist yet;
        # `git -C` on it fails, and the cwd fallback would then re-create the
        # very mis-keying this fixes (CR r3 codex-1). Walk up to the nearest
        # EXISTING ancestor first — inside a worktree that is still the same
        # worktree. Terminates: dirname of a root is itself.
        while [ -n "$file_dir" ] && [ ! -d "$file_dir" ]; do
            file_parent=$(dirname "$file_dir")
            [ "$file_parent" = "$file_dir" ] && break
            file_dir="$file_parent"
        done
        # `--is-inside-work-tree` (not just symbolic-ref): a DETACHED worktree
        # holding the file must take the unresolvable arm below, never fall
        # back to the cwd's branch — that is the mis-keying this fixes.
        if [ "$(git -C "$file_dir" rev-parse --is-inside-work-tree 2>/dev/null || true)" = "true" ]; then
            repo_dir="$file_dir"
            branch_src="the edited file's worktree"
            branch=$(git -C "$repo_dir" symbolic-ref -q --short HEAD 2>/dev/null || true)
        fi
        ;;
esac
if [ -z "$repo_dir" ]; then
    repo_dir="$cwd_dir"
    branch_src="the session cwd"
    branch=$(git -C "$repo_dir" symbolic-ref -q --short HEAD 2>/dev/null || true)
fi

# The repo's default branch is never a PR — and an on-main edit is already
# owned by block-edit-on-main.sh. Charging it would re-create the permanently
# spent "main" record. origin/HEAD is AUTHORITATIVE where it resolves; the
# main/master conventional names are only the fallback for a repo (or a
# throwaway fixture) that has no origin/HEAD (CR r1 codex-2: applying the
# literals unconditionally would leave a legitimate PR branch NAMED main or
# master untracked in a repo whose real default is something else).
default_branch=$(git -C "$repo_dir" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)
default_branch="${default_branch#origin/}"
is_default=0
if [ -n "$default_branch" ]; then
    [ "$branch" = "$default_branch" ] && is_default=1
else
    [ "$branch" = "main" ] && is_default=1
    [ "$branch" = "master" ] && is_default=1
fi

if [ "$is_default" = "1" ]; then
    # Resolved, but not a PR branch — same allow + advisory arm as an
    # unresolvable branch, and no spend recorded against the default branch.
    fire_log allow-default-branch
    jq -nc --arg ctx "You are the orchestrating parent; this looks like implementation. Dispatch it to a worker lane (CLAUDE.md subagent policy) — one trivial CR-fix exemption per PR already spent? (branch '$branch' resolved from $branch_src is the repo's default branch, not a PR — inline budget not tracked for this edit)" \
        '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",additionalContext:$ctx}}'
    exit 0
fi
case "$branch" in
    ""|HEAD)
        # Unresolvable/detached branch — allow, but keep the phase-1 advisory
        # visible so a qualifying edit never passes in total silence.
        fire_log allow-no-branch
        jq -nc --arg ctx "You are the orchestrating parent; this looks like implementation. Dispatch it to a worker lane (CLAUDE.md subagent policy) — one trivial CR-fix exemption per PR already spent? (branch unresolvable from $branch_src — inline budget not tracked for this edit)" \
            '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",additionalContext:$ctx}}'
        exit 0
        ;;
esac

# ---- Merge/rebase carve-out (HIMMEL-1791): conflict resolution is genuinely
# parent work — allow and do NOT consume the budget. MERGE_HEAD / REBASE_HEAD
# (and the rebase-merge / rebase-apply dirs) live in the CURRENT worktree's
# git dir; `rev-parse --git-path` resolves each against it and is made
# absolute below (git may emit an MSYS-relative path; Windows drive-letter
# forms are left alone).
gitpath() {  # gitpath <name> — absolute path of a worktree git-dir entry, or empty
    local p
    p=$(git -C "$repo_dir" rev-parse --git-path "$1" 2>/dev/null) || return 1
    case "$p" in
        /*|[A-Za-z]:*) printf '%s\n' "$p" ;;
        *) printf '%s/%s\n' "$repo_dir" "$p" ;;
    esac
}
merge_head=$(gitpath MERGE_HEAD)
rebase_head=$(gitpath REBASE_HEAD)
rebase_merge=$(gitpath rebase-merge)
rebase_apply=$(gitpath rebase-apply)
# Evaluate each probe independently (CR r1 glm-3): the previous form gated
# the whole carve-out on `[ -n "$merge_head" ]`, so a failure of JUST the
# MERGE_HEAD probe silently disabled the REBASE_HEAD / rebase-merge /
# rebase-apply carve-outs too — a rebase in progress would then consume the
# budget (or be denied) because one rev-parse call failed. A probe that
# fails to resolve contributes nothing; the others still speak for
# themselves, and with no positive evidence from any probe the budget logic
# below fail-opens as usual.
in_merge_or_rebase=0
[ -n "$merge_head" ] && [ -e "$merge_head" ] && in_merge_or_rebase=1
[ -n "$rebase_head" ] && [ -e "$rebase_head" ] && in_merge_or_rebase=1
[ -n "$rebase_merge" ] && [ -d "$rebase_merge" ] && in_merge_or_rebase=1
[ -n "$rebase_apply" ] && [ -d "$rebase_apply" ] && in_merge_or_rebase=1
[ "$in_merge_or_rebase" = "1" ] && exit 0

# ---- Per-branch budget state (HIMMEL-1791) ----
# Convention: cr-pending/<branch> + cr-prior-blocking/<branch> — branch-scoped
# state under the SHARED git-common-dir, so the budget is visible from every
# worktree in the checkout and keyed per PR (branch), never per round. The
# KEY is the branch percent-encoded into ONE filename segment (CR r1):
# branch names contain '/', and the raw-branch-as-path form this ticket
# shipped first let one branch's state occupy another's path — spending
# `feat/x` did `mkdir -p <base>/feat`, exactly where a branch literally
# named `feat` keeps its state FILE (false DENY on feat's first edit), and
# in the inverse order feat's state file blocked feat/x's mkdir entirely,
# leaving that branch's budget permanently unenforceable. Injective
# encoding: '%' -> '%25' first, then '/' -> '%2F' — no encoded key contains
# '/', so no branch's state can ever be a path prefix of another's, and the
# state base holds only flat files (no per-spend mkdir). State written by
# the pre-encoding scheme (nested raw-branch paths) is orphaned — inert, and
# an orphan fails OPEN (that branch simply gets a fresh exemption), the safe
# direction for a guard whose deny demands positive evidence. The file has
# no lifecycle management by design: presence = spent; a stale entry for a
# deleted branch is inert (and /worktree refuses to reuse a merged-PR
# branch name).
# ORCH_GUARD_STATE_DIR overrides the base dir (test seam only).
if [ -n "${ORCH_GUARD_STATE_DIR:-}" ]; then
    state_base="$ORCH_GUARD_STATE_DIR"
else
    state_base=$(git -C "$repo_dir" rev-parse --git-common-dir 2>/dev/null || true)
    [ -n "$state_base" ] || exit 0
    case "$state_base" in
        /*|[A-Za-z]:*) ;;
        *) state_base="$repo_dir/$state_base" ;;
    esac
    state_base="$state_base/inline-impl-spent"
fi
state_key=$(printf '%s' "$branch" | sed -e 's/%/%25/g' -e 's|/|%2F|g')
state_path="$state_base/$state_key"

if [ ! -f "$state_path" ]; then
    # FIRST qualifying inline edit on this branch: spend the ONE per-PR
    # exemption — record it, then allow with an advisory that it is spent.
    # `-f` (not `-e`): only the state FILE is positive evidence of a spend —
    # anything else at the path (e.g. a directory left by external
    # tampering; the flat-key scheme itself never creates one) reads as
    # unspent, which fail-opens. If the write FAILS, say so plainly (CR r1
    # codex-1): the advisory must not claim a spend that did not happen —
    # later edits will not be denied, because nothing was recorded. The
    # allow stands either way (fail-open is the correct posture here).
    mkdir -p "$state_base" 2>/dev/null || true
    write_ok=0
    jq -nc --arg ts "$now" --arg s "$session_id" --arg m "$model" --arg t "$tool" --arg p "$path" \
        '{ts:$ts,session:$s,model:$m,tool:$t,path:$p}' > "$state_path" 2>/dev/null \
        && [ -f "$state_path" ] && write_ok=1
    if [ "$write_ok" = "1" ]; then
        fire_log exempt-allow
        first_ctx="You are the orchestrating parent; this looks like implementation — recorded as the ONE per-PR inline exemption for branch '$branch' (resolved from $branch_src; HIMMEL-1791). The next inline implementation edit on this branch will be DENIED: dispatch it instead via the Agent tool with an explicit model tier (CLAUDE.md subagent policy — haiku/sonnet/opus/fable, see /lanes; HIMMEL-1967: impl routes to native Claude subagents only, not scripts/telegram/dispatch-lane.sh)"
    else
        warn "cannot record inline-exemption state ($state_path) — allowing anyway (budget not spent)"
        fire_log exempt-allow-unrecorded
        first_ctx="You are the orchestrating parent; this looks like implementation — allowed, but the per-PR inline exemption could NOT be recorded (state write failed, HIMMEL-1791): the budget was NOT spent, so later inline edits will not be denied by this gate. Dispatching remains the sanctioned path: the Agent tool with an explicit model tier (CLAUDE.md subagent policy; HIMMEL-1967: impl routes to native Claude subagents only, not scripts/telegram/dispatch-lane.sh)"
    fi
    # permissionDecision:"allow" is the phase-1 idiom this hook shipped with
    # (052711a0: auto-approve-safe-bash.sh / guard-memory-capture.sh
    # precedent) — verified against the pre-branch advisory version before
    # keeping it (CR r1 glm-5): NOT a permission widened by HIMMEL-1791.
    jq -nc --arg ctx "$first_ctx" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",additionalContext:$ctx}}'
    exit 0
fi

# ---- Retry allowance (CR r1 glm-4) ----
# The exemption is recorded at PreToolUse — on INTENT, not outcome — so a
# tool-level failure of the first edit (e.g. an Edit old_string mismatch)
# used to spend the budget and deny the legitimate retry. Recording on
# success instead would need a PostToolUse hook, i.e. new .claude/settings
# .json wiring (out of scope for this ticket), so the in-scope fix: an
# IDENTICAL retry — same session, same path as the recorded spend — does
# not hit the deny. Session-scoped by design: a LATER session editing the
# same file is new work, not a retry, and still denies (the per-PR budget
# must not reset on every continuation session); path-scoped likewise (a
# different file in the same session denies). The residual looseness —
# unlimited same-session edits to the ONE exempted file — bounds a "trivial
# CR-fix" fairly: it is one file in one sitting, everything else dispatches
# (or takes the audited INLINE_IMPL_OK override).
spent_session=$(jq -r '.session // empty' "$state_path" 2>/dev/null || true)
spent_path=$(jq -r '.path // empty' "$state_path" 2>/dev/null || true)
if [ "$spent_session" = "$session_id" ] && [ "$spent_path" = "$path" ]; then
    fire_log retry-allow
    retry_ctx="Same file, same session as the recorded per-PR inline exemption (HIMMEL-1791) — allowed as a retry of that edit (e.g. after a tool-level failure), no new spend. A different file, or a later session, must dispatch instead via the Agent tool with an explicit model tier (CLAUDE.md subagent policy; HIMMEL-1967: impl routes to native Claude subagents only, not scripts/telegram/dispatch-lane.sh)"
    jq -nc --arg ctx "$retry_ctx" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",additionalContext:$ctx}}'
    exit 0
fi

# ---- Budget spent: DENY (HIMMEL-1791). The message must leave the parent
# with a sanctioned path that is EASIER than inline: the ready-to-run lane
# dispatcher, plus the ESCALATION answer for the round-guard hole (a
# HIMMEL-1553 refusal of the selected lane is NOT licence to implement inline
# — choose a higher-tier lane via --lane or the Fable tier instead), plus the
# audited override.
spent_ts=$(jq -r '.ts // "earlier"' "$state_path" 2>/dev/null || true)
# The state file is UNTRUSTED on-disk input (CR r1 glm-6): whitelist the
# exact ISO-UTC shape this hook itself writes before the value reaches the
# model-facing deny reason — crafted content under .git must not become
# model-visible text. Anything else (including empty, on an unreadable
# file) displays as "earlier".
case "$spent_ts" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
    *) spent_ts="earlier" ;;
esac
deny_msg="You are the orchestrating parent and this is implementation — DENIED. The ONE per-PR inline
exemption for branch '$branch' (resolved from $branch_src) is already spent (recorded $spent_ts; CLAUDE.md subagent policy:
from the second CR round on, batch the remaining findings to a worker lane in shared-branch
mode). Per PR, not per round — round counting is the drift this gate exists to stop.

Dispatch the work instead — use the Agent tool with an explicit model tier (HIMMEL-1967: impl
routes to native Claude subagents only, NOT scripts/telegram/dispatch-lane.sh, whose unqualified
impl dispatch exits 2 for exactly this class of work). Pick haiku for bulk mechanical work,
sonnet for a well-specified implementation brief (the default implementor), or escalate to
opus/fable for a judgment call — see /lanes for the live inventory, and brief the child fully,
it inherits nothing.

A worker stuck on repeated blocking reviews is NOT licence to implement inline —
ESCALATE instead: a higher-tier model, or the Fable tier.

Deliberate override (audited): relaunch with INLINE_IMPL_OK=1 in the launching shell —
a per-call prefix does not reach this hook."
fire_log deny
reason=$(printf '%s' "$deny_msg" | jq -Rs . 2>/dev/null) \
    || reason='"orchestrator-inline-guard: per-PR inline exemption already spent — dispatch to a worker lane"'
# Structured deny on stdout (overrides the exit code where parsed) AND exit 2
# + stderr (the documented blocking channel) — deny on both channels.
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$reason"
printf '%s\n' "$deny_msg" >&2
exit 2
