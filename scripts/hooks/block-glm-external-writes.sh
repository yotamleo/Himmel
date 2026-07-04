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
# the trap cannot see failures inside `if ... grep -q ...` condition contexts
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
#
# Occurrence counter (same command-position wrapper). grep -c counts
# LINES, and cmd_lc is flattened to one line, so -c undercounts a compound with
# two command-position matches — count PER-MATCH via grep -oE | wc -l instead.
# grep exits 1 on zero matches; `|| true` keeps that from tripping errexit
# inside the assignment's command substitution. $(( )) strips wc's whitespace.
count_cmd() {
    local n
    n=$(printf '%s' "$cmd_lc" | grep -oE "(^|[;&|(])[[:space:]]*($1)" | wc -l) || true
    printf '%s' "$((n))"
}

# --- Deny-arm count form + session grant-consult (escalation channel, HIMMEL-654) ---
# Each command-text deny arm is a total-vs-allowed COUNT (never an inline deny):
#   git-push / git-url / network — builtin allowed 0 (no carve-out);
#   gh — builtin allowed = the issue-ops + pr/run-reads carve-out (HIMMEL-675).
# The subcommand-position shapes below are unchanged from the pre-grant arms
# (push flag-tolerant; git-url = remote set-url OR config…url OR-ed into ONE
# count; gh carve-out; network CLIs). A per-session grant in
# ${GLM_SESSION_DIR}/grants.jsonl can widen ONE arm's allowed count by folding
# its pattern into a SINGLE alternation (never a sum — F1), TTL- and use-bounded,
# fail-closed: an unset/absent grants file or any invalid grant line leaves the
# arm at its builtin allowance and it still denies.
gp_shape='git([[:space:]]+-[a-z-]+([[:space:]]+[^[:space:];&|]+)?)*[[:space:]]+push([[:space:]]|$)'
gu_shape='(git([[:space:]]+-[a-z-]+([[:space:]]+[^[:space:];&|]+)?)*[[:space:]]+remote[[:space:]]+set-url|git([[:space:]]+-[a-z-]+([[:space:]]+[^[:space:];&|]+)?)*[[:space:]]+config([[:space:]]+-[a-z-]+)*[[:space:]]+[^[:space:];&|]*url)'
gh_shape='gh([[:space:]]|$)'
gh_allow='gh[[:space:]]+(issue([[:space:]]|$)|pr[[:space:]]+(view|diff|checks|status|list)([[:space:]]|$)|run[[:space:]]+(view|list|watch)([[:space:]]|$))'
net_shape='(curl|wget|invoke-webrequest|invoke-restmethod|iwr|irm)([[:space:]]|$)'

gp_total=$(count_cmd "$gp_shape"); gp_allowed=0
gu_total=$(count_cmd "$gu_shape"); gu_allowed=0
gh_total=$(count_cmd "$gh_shape"); gh_allowed=$(count_cmd "$gh_allow")
net_total=$(count_cmd "$net_shape"); net_allowed=0

# F9 fast path: every arm satisfied by builtins alone -> allow WITHOUT reading
# grants.jsonl, so a builtin-allowed command never consults or consumes a grant.
if [ "$gp_total" -le "$gp_allowed" ] && [ "$gu_total" -le "$gu_allowed" ] \
   && [ "$gh_total" -le "$gh_allowed" ] && [ "$net_total" -le "$net_allowed" ]; then
    exit 0
fi

# Some arm exceeds its builtin allowance -> consult per-session grants (fail-closed).
# gp_alt/gu_alt/gh_alt/net_alt accumulate valid grant patterns per arm ('|'-joined,
# no associative arrays); valid_grants accumulates "grant_id <pattern>" lines for
# the consumption-append pass. A grant is skipped (as if absent) if it is not a
# well-formed grant line, has an unknown arm, fails the deny-shape anchor / has an
# unbounded prefix, is expired, or is used up.
gp_alt=""; gu_alt=""; gh_alt=""; net_alt=""; valid_grants=""
grants_file="${GLM_SESSION_DIR:-}/grants.jsonl"
if [ -n "${GLM_SESSION_DIR:-}" ] && [ -f "$grants_file" ]; then
    # Read the ledger ONCE and parse from the in-memory copy so the per-line loop
    # never re-opens the file; the consumption append below is a separate, later
    # pipeline, so there is no read/write overlap on grants.jsonl.
    grants_data=$(cat "$grants_file")
    now_iso=$(date -u +%Y-%m-%dT%H:%M:%S)
    while IFS= read -r gline; do
        [ -z "$gline" ] && continue
        gobj=$(printf '%s' "$gline" | jq -c 'select(.type=="grant")' 2>/dev/null) || continue
        [ -z "$gobj" ] && continue
        garm=$(printf '%s' "$gobj" | jq -r '.arm // empty' 2>/dev/null) || continue
        gpat=$(printf '%s' "$gobj" | jq -r '.pattern // empty' 2>/dev/null) || continue
        gmax=$(printf '%s' "$gobj" | jq -r '.max_uses // empty' 2>/dev/null) || continue
        gid=$(printf '%s' "$gobj" | jq -r '.grant_id // empty' 2>/dev/null) || continue
        gexp=$(printf '%s' "$gobj" | jq -r '.expires_at // empty' 2>/dev/null) || continue
        if [ -z "$garm" ] || [ -z "$gpat" ] || [ -z "$gmax" ] || [ -z "$gid" ] || [ -z "$gexp" ]; then continue; fi
        case "$garm" in git-push|git-url|gh|network) ;; *) continue ;; esac
        case "$gmax" in ''|*[!0-9]*) continue ;; esac
        [ "$gmax" -gt 0 ] || continue
        [ "${#gexp}" -ge 19 ] || continue
        if ! [[ "$now_iso" < "${gexp:0:19}" ]]; then continue; fi          # expired
        if printf '%s' "$gpat" | grep -qE '^\.[*+]'; then continue; fi      # unbounded prefix (F2)
        # per-arm deny-shape anchor (F8): reject a grant whose pattern is not
        # anchored on THIS arm's deny shape (a git-push grant must carry a push
        # token; a git-url grant a url token; gh/network the family verb).
        case "$garm" in
            gh)
                printf '%s' "$gpat" | grep -qE '^gh(\[\[:space:\]\]|[[:space:]])' || continue ;;
            network)
                printf '%s' "$gpat" | grep -qE '^\(?(curl|wget|invoke-webrequest|invoke-restmethod|iwr|irm)' || continue ;;
            git-push)
                printf '%s' "$gpat" | grep -qE '^git' || continue
                printf '%s' "$gpat" | grep -qE '(\[\[:space:\]\]|[[:space:]]|\|\)|\+)push' || continue ;;
            git-url)
                printf '%s' "$gpat" | grep -qE '^git' || continue
                printf '%s' "$gpat" | grep -qE 'url' || continue ;;
        esac
        gused=$(printf '%s\n' "$grants_data" | grep -c "\"type\":\"consumption\",\"grant_id\":\"$gid\"" || true)
        gused=${gused:-0}
        [ "$gused" -lt "$gmax" ] || continue                                # exhausted
        case "$garm" in
            git-push) gp_alt="${gp_alt:+$gp_alt|}$gpat" ;;
            git-url)  gu_alt="${gu_alt:+$gu_alt|}$gpat" ;;
            gh)       gh_alt="${gh_alt:+$gh_alt|}$gpat" ;;
            network)  net_alt="${net_alt:+$net_alt|}$gpat" ;;
        esac
        valid_grants="${valid_grants}${gid} ${gpat}
"
    done <<< "$grants_data"
fi

# Recompute each still-failing arm's allowed as ONE alternation (builtin|grant)
# — never a sum (F1). Arms with no builtin carve-out omit the builtin term.
if [ -n "$gp_alt" ]; then gp_allowed=$(count_cmd "$gp_alt"); fi
if [ -n "$gu_alt" ]; then gu_allowed=$(count_cmd "$gu_alt"); fi
if [ -n "$gh_alt" ]; then gh_allowed=$(count_cmd "($gh_allow)|($gh_alt)"); fi
if [ -n "$net_alt" ]; then net_allowed=$(count_cmd "$net_alt"); fi

if [ "$gp_total" -le "$gp_allowed" ] && [ "$gu_total" -le "$gu_allowed" ] \
   && [ "$gh_total" -le "$gh_allowed" ] && [ "$net_total" -le "$net_allowed" ]; then
    # Honored: append one consumption line per valid grant whose pattern matched
    # this command (append-only — existing lines are never rewritten).
    con_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    printf '%s' "$valid_grants" | while read -r vgid vpat; do
        [ -z "$vgid" ] && continue
        if [ "$(count_cmd "$vpat")" -gt 0 ]; then
            printf '{"type":"consumption","grant_id":"%s","ts":"%s"}\n' "$vgid" "$con_ts" >> "$grants_file"
        fi
    done
    exit 0
fi

# Still over allowance after grants -> deny the offending arm (message per arm).
if [ "$gp_total" -gt "$gp_allowed" ]; then
    deny "git push is blocked on the GLM lane (commit locally; the parent session pushes)."
fi
if [ "$gu_total" -gt "$gu_allowed" ]; then
    deny "rewriting git remote/push URLs is blocked on the GLM lane (the pushurl tripwire stays poisoned)."
fi
if [ "$gh_total" -gt "$gh_allowed" ]; then
    deny "gh is limited on the GLM lane: issue ops + pr/run reads; PR mutations belong to the parent session."
fi
if [ "$net_total" -gt "$net_allowed" ]; then
    deny "network CLIs are blocked on the GLM lane (chores are repo-local)."
fi

exit 0
