#!/usr/bin/env bash
# PreToolUse hook for Bash/PowerShell/mcp__* — GLM-lane external-write deny.
#
# WHY (HIMMEL-654 session-9 tail, operator decision #1 — "harden BEFORE
# scaling the offload"): GLM workers (scripts/telegram/spawn-glm.ts) and
# claude-glm sessions run claude against api.z.ai, usually with
# --permission-mode bypassPermissions. Third-party lanes have NO auto-mode
# classifier and bypassPermissions removes the prompt layer, so the only
# control between a mis-prompted worker and an external write is the
# poisoned worktree pushurl — a tripwire, not a wall. This hook is the
# deterministic classifier SUBSTITUTE: on the GLM lane, hard-block
# push / PR / external-write shapes.
#
# Lane detection: ANTHROPIC_BASE_URL contains api.z.ai (set by
# scripts/telegram/glm-env.ts buildGlmEnv and the scripts/claude-glm{,.ps1}
# launcher family; inherited by hook processes). Non-GLM sessions exit 0 on
# the first case below — near-zero overhead, before the jq availability check.
#
# Blocked on-lane:
#   - ALL mcp__* tools EXCEPT the qmd KB carve-out (v1 chores are repo-local;
#     blanket beats a verb list; qmd KB reads are operator-allowed, see below)
#   - git push; git remote set-url; git config …url (tripwire un-poisoning)
#   - the gh CLI EXCEPT the carve-out below — pr create/merge/edit/review/
#     comment/ready, api, repo, release, gist, … stay blocked (parent-session
#     actions)
#   - network CLIs: curl/wget/Invoke-WebRequest/Invoke-RestMethod/iwr/irm
#     (write-flag parsing is fragile post-lowercasing; chores are repo-local;
#     bun/npm installs remain allowed — dependency fetch, not external write)
#
# Allowed on-lane (operator policy 2026-07-03 — audited-action carve-out):
#   - the Jira CLI (scripts/jira/ path, or bare `jira`): writes are audited in
#     Jira history + recoverable, so GLM workers may update status/comments and
#     file followup tickets. Atlassian MCP stays blocked (mcp__* below) — Jira
#     routing is CLI-first (block-backend-tier enforces that in every session).
#   - the qmd KB (mcp__plugin_qmd_qmd__* tools): read-only knowledge-base access.
#   - gh issue <anything> (full issue surface — reads AND writes; cr-deferred
#     followups are gh issues, audited in GitHub + recoverable), plus read-only
#     PR/CI context: `gh pr view|diff|checks|status|list`, `gh run
#     view|list|watch`. Every other gh use stays blocked (counting arm below).
#
# Known limitations (accidental-shape guard, like block-read-secrets):
#   - any wrapper displacing the command from command position is missed:
#     env-prefixed `FOO=1 git push`, sudo/xargs/timeout wrappers, `git-push`,
#     and the `=`-joined global-flag form `git --git-dir=/x push` (missed too)
#   - in-process network is invisible to a command-text hook — bun/node
#     fetch, including bun-invoking the telegram bridge send path
#   - malformed/empty tool JSON -> allow (parity with sibling hooks; Claude
#     Code emits valid JSON)
#   - the gh carve-out counts command-position gh occurrences (total vs
#     allowed) and shares the wrapper gap above — a wrapper-displaced gh is
#     invisible to BOTH counts, so it is neither blocked nor credited as allowed
#   Accepted OVER-blocks (fail-closed direction, all test-pinned):
#   - newlines flatten to ';', so quoted prose whose LINE starts with a
#     blocked verb ("…\ngit push later") blocks; mid-line prose stays allowed
#   - an allowed `gh issue …` whose quoted body contains `;`/`|` followed by
#     another gh token ("--body 'step 1; gh pr merge later'") blocks (the
#     body token inflates the total count)
#   - global flags BEFORE a gh subcommand displace it from the allow anchor:
#     `gh -R o/r issue list` blocks; write flags AFTER the subcommand
#     (`gh issue list -R o/r`) — allowed
#   All backstopped by the poisoned pushurl tripwire + the parent CR gate —
#   those two remain the load-bearing controls; this hook is the in-session
#   deterministic layer.
#
# Exit codes: 0 allow; 2 block (stderr shown to the worker).
# Bypass: GLM_EXTERNAL_WRITES_OK=1 in the env of the shell that spawns the
# worker (spawn-glm caller / claude-glm launcher). Session-sticky.
set -euo pipefail

case "${ANTHROPIC_BASE_URL:-}" in
    *api.z.ai*) ;;
    *) exit 0 ;;
esac

[ "${GLM_EXTERNAL_WRITES_OK:-0}" = "1" ] && exit 0

# On-lane, a TOP-LEVEL errexit abort must BLOCK (exit 2), never slip through
# as a non-blocking exit 1 (only exit 2 denies in Claude Code). Scope honesty:
# the trap cannot see failures inside `if at_cmd ...` condition contexts
# (errexit-exempt; a grep crashing on a fixed pattern is the only such shape —
# ~impossible in practice), and the malformed-JSON path deliberately stays
# fail-OPEN above per sibling-hook parity — this clamp covers everything else.
# shellcheck disable=SC2154  # rc is assigned by rc=$? inside the same trap string
trap 'rc=$?; if [ "$rc" != 0 ] && [ "$rc" != 2 ]; then exit 2; fi' EXIT

if ! command -v jq >/dev/null 2>&1; then
    echo "block-glm-external-writes: jq not on PATH — refusing to evaluate on the GLM lane; install jq" >&2
    exit 2
fi

input=$(cat)
tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)

deny() {
    {
        echo "⛔ block-glm-external-writes: $1"
        echo "    This session runs on the GLM lane (ANTHROPIC_BASE_URL=api.z.ai), which has"
        echo "    no auto-mode classifier — external writes are hard-blocked (HIMMEL-654)."
        echo "    Deliver results as a committed branch diff + your session outbox summary;"
        echo "    the parent Claude session / operator pushes and opens PRs."
        echo "    Operator bypass: GLM_EXTERNAL_WRITES_OK=1 in the spawning shell."
    } >&2
    exit 2
}

case "$tool" in
    mcp__plugin_qmd_qmd__*) exit 0 ;; # KB search/read — operator-allowed (audited-lane policy 2026-07-03)
    mcp__*) deny "MCP tool '$tool' is blocked on the GLM lane." ;;
    Bash|PowerShell) ;;
    *) exit 0 ;;
esac

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -z "$cmd" ] && exit 0

# Lower-case + flatten newlines TO ';' — a newline separates commands exactly
# like ';' does, so flattening to spaces (the sibling hooks' shape) UNDER-blocks:
# a two-line "gh pr view 1\ngh pr merge 1" would read as one command and the
# merge would slip through as an "argument". Flattening to ';' keeps command
# boundaries visible to the (^|[;&|(]) anchor. Cost (accepted, fail-closed): a
# quoted commit-message LINE that STARTS with a blocked verb ("…\ngit push
# later") now over-blocks — pinned by test; mid-line prose stays allowed.
cmd_lc=$(printf '%s' "$cmd" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C tr '\n\r' ';;')

# Command-position matcher: start-of-command or right after ; & | ( —
# deliberately NOT space/quote, so prose inside a commit message ("… git push
# …") does not false-block. Env-prefixed `FOO=1 git push` is therefore missed:
# accepted limitation, tripwire-backstopped (see header).
at_cmd() { printf '%s' "$cmd_lc" | grep -qE "(^|[;&|(])[[:space:]]*($1)"; }

# Occurrence counter (same command-position wrapper as at_cmd). grep -c counts
# LINES, and cmd_lc is flattened to one line, so -c undercounts a compound with
# two command-position matches — count PER-MATCH via grep -oE | wc -l instead.
# grep exits 1 on zero matches; `|| true` keeps that from tripping errexit
# inside the assignment's command substitution. $(( )) strips wc's whitespace.
count_cmd() {
    local n
    n=$(printf '%s' "$cmd_lc" | grep -oE "(^|[;&|(])[[:space:]]*($1)" | wc -l) || true
    printf '%s' "$((n))"
}

# git push — subcommand position; tolerate intervening short/long flags with
# one optional argument each (git -C <path> push, git -c k=v push).
if at_cmd 'git([[:space:]]+-[a-z-]+([[:space:]]+[^[:space:];&|]+)?)*[[:space:]]+push([[:space:]]|$)'; then
    deny "git push is blocked on the GLM lane (commit locally; the parent session pushes)."
fi
# tripwire un-poisoning: remote set-url, or git config touching any *url key.
# Flag-tolerant subcommand-position shape (same as the push arm) — NOT the
# greedy `git[^;&|]*` form, which gobbles quoted prose and false-blocks
# commit messages mentioning "remote set-url" / "config url" (critic F2).
# `git config --get remote.origin.url` (a read) still blocks: accepted
# overmatch, pinned by test — allowing --get would miss `--local` writes.
if at_cmd 'git([[:space:]]+-[a-z-]+([[:space:]]+[^[:space:];&|]+)?)*[[:space:]]+remote[[:space:]]+set-url' || at_cmd 'git([[:space:]]+-[a-z-]+([[:space:]]+[^[:space:];&|]+)?)*[[:space:]]+config([[:space:]]+-[a-z-]+)*[[:space:]]+[^[:space:];&|]*url'; then
    deny "rewriting git remote/push URLs is blocked on the GLM lane (the pushurl tripwire stays poisoned)."
fi
# gh carve-out (operator policy 2026-07-03, HIMMEL-675): allow `gh issue`
# (full surface — cr-deferred followups are gh issues, audited + recoverable)
# and read-only PR/CI context (`gh pr view|diff|checks|status|list`, `gh run
# view|list|watch`); deny every other gh. Count command-position gh occurrences
# vs allowed ones — a compound smuggling a denied gh past an allowed one
# (`gh pr view 1 && gh pr merge 1`) has total > allowed → deny.
gh_total=$(count_cmd 'gh([[:space:]]|$)')
gh_allowed=$(count_cmd 'gh[[:space:]]+(issue([[:space:]]|$)|pr[[:space:]]+(view|diff|checks|status|list)([[:space:]]|$)|run[[:space:]]+(view|list|watch)([[:space:]]|$))')
if [ "$gh_total" -gt "$gh_allowed" ]; then
    deny "gh is limited on the GLM lane: issue ops + pr/run reads; PR mutations belong to the parent session."
fi
if at_cmd '(curl|wget|invoke-webrequest|invoke-restmethod|iwr|irm)([[:space:]]|$)'; then
    deny "network CLIs are blocked on the GLM lane (chores are repo-local)."
fi

exit 0
