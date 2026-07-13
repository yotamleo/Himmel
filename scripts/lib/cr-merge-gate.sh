#!/usr/bin/env bash
# cr-merge-gate.sh — shared predicate for the HIMMEL-936 CR merge gate.
#
# cr_merge_gate <pr-selector> [<owner/repo>]
#   rc 0 = allow; rc 2 = block, one-line reason on stdout.
#   rc 3 = allow, but the SELECTOR did not resolve to a PR (gh pr view failed)
#          — callers that extracted the selector heuristically (the PreToolUse
#          hook) should retry once with a better-anchored selector (the cwd
#          branch) so quoted/mis-tokenized selectors cannot dodge the gate
#          (codex-1 / codex-adv-1, HIMMEL-936 CR round). Top-level consumers
#          treat any non-2 rc as allow.
#   Deny ONLY on positive evidence:
#     - an unresolved PR review thread whose first comment is by coderabbitai
#     - a CodeRabbit check-run on the head SHA still queued/in_progress
#   EVERYTHING else (gh missing, API error, no PR, parse failure) fails OPEN
#   (rc 0/3) with a "cr-merge-gate: degraded (...) - failing open" stderr note.
#   CR_MERGE_GATE_OK=1 or CR_PROFILE=none skip the gate entirely (rc 0).
#   CR_ZOMBIE_CHECKRUN_MINS sets the old-run override threshold (default 90).
#
# Sourceable from hooks and scripts: uses only `return`, never `exit`;
# does not toggle set -e. bash 3.2-safe. Each `jq` command substitution is
# made set -e-safe with a trailing `|| true` inside the subshell so that a
# caller running `set -e` (pr-merge.sh) does not abort on a jq parse failure
# (a parse failure is a normal fail-open input here, not a hard error).
# HIMMEL-936.

_cmg_degrade() { echo "cr-merge-gate: degraded ($*) - failing open" >&2; }

_cmg_started_epoch() {
    date -u -d "$1" +%s 2>/dev/null && return 0
    date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null
}

cr_merge_gate() {
    [ "${CR_MERGE_GATE_OK:-0}" = "1" ] && return 0
    [ "${CR_PROFILE:-}" = "none" ] && return 0

    local sel="${1:-}" repo="${2:-}"
    if [ -z "$sel" ]; then _cmg_degrade "no PR selector"; return 0; fi
    command -v gh >/dev/null 2>&1 || { _cmg_degrade "gh not on PATH"; return 0; }
    command -v jq >/dev/null 2>&1 || { _cmg_degrade "jq not on PATH"; return 0; }

    local meta url num head owner name
    if [ -n "$repo" ]; then
        meta=$(gh pr view "$sel" --repo "$repo" --json number,headRefOid,url 2>/dev/null) || { _cmg_degrade "gh pr view failed (selector '$sel' unresolvable)"; return 3; }
    else
        meta=$(gh pr view "$sel" --json number,headRefOid,url 2>/dev/null) || { _cmg_degrade "gh pr view failed (selector '$sel' unresolvable)"; return 3; }
    fi
    num=$(printf '%s' "$meta" | jq -r '.number // empty' 2>/dev/null || true)
    head=$(printf '%s' "$meta" | jq -r '.headRefOid // empty' 2>/dev/null || true)
    url=$(printf '%s' "$meta" | jq -r '.url // empty' 2>/dev/null || true)
    if [ -z "$num" ] || [ -z "$head" ] || [ -z "$url" ]; then _cmg_degrade "pr metadata incomplete"; return 0; fi
    # url shape: https://github.com/OWNER/NAME/pull/N
    owner=$(printf '%s' "$url" | sed -n 's|^https://[^/]*/\([^/]*\)/.*|\1|p')
    name=$(printf '%s' "$url"  | sed -n 's|^https://[^/]*/[^/]*/\([^/]*\)/.*|\1|p')
    if [ -z "$owner" ] || [ -z "$name" ]; then _cmg_degrade "cannot parse owner/name from $url"; return 0; fi

    # 1) unresolved coderabbitai review threads
    local threads unresolved threads_page_complete
    # shellcheck disable=SC2016  # GraphQL variables ($owner/$name/$number) are literal here
    threads=$(gh api graphql \
        -f owner="$owner" -f name="$name" -F number="$num" \
        -f query='query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){reviewThreads(first:100){pageInfo{hasNextPage} nodes{isResolved path line comments(first:1){nodes{author{login}}}}}}}}' \
        2>/dev/null) || { _cmg_degrade "reviewThreads query failed"; return 0; }
    # Page-completeness marker (HIMMEL-980 codex-adv-1): this single-page query
    # is the hook's ONLY thread evidence. That is unchanged for the plain gate
    # (>100-thread PRs keep the pre-existing first-page behavior), but the
    # zombie override below must NOT certify "zero unresolved threads" it never
    # saw — so the override is disabled whenever a second page exists.
    # `== false` on purpose (coderabbit 980-r2): only an EXPLICIT
    # hasNextPage:false proves completeness — a missing/null pageInfo yields
    # "false" here (override stays disabled). jq's `//` operator cannot express
    # this: `hasNextPage // true` swallows a legitimate false.
    threads_page_complete=$(printf '%s' "$threads" | jq -r \
        '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage == false' \
        2>/dev/null || echo false)
    unresolved=$(printf '%s' "$threads" | jq -r \
        '[.data.repository.pullRequest.reviewThreads.nodes[]? | select(.isResolved==false) | select((.comments.nodes[0].author.login // "") | test("coderabbit"; "i"))] | length' \
        2>/dev/null || true)
    if [ -z "$unresolved" ]; then _cmg_degrade "reviewThreads parse failed"; return 0; fi
    # >100 threads with zero unresolved ON PAGE ONE is not a pass — it is
    # positive evidence of threads this single-page query never counted
    # (coderabbit 980-r3). Unlike an API/parse failure (degrade, fail open),
    # this blocks: the state is knowable, just not from one page. A real PR
    # with 100+ CodeRabbit threads is pathological — check manually or bypass.
    if [ "$unresolved" -eq 0 ] 2>/dev/null && [ "$threads_page_complete" != "true" ]; then
        echo "BLOCK: PR #$num has more review threads than the gate's single page (100) — cannot certify zero unresolved CodeRabbit threads. Check threads manually, or bypass with CR_MERGE_GATE_OK=1."
        return 2
    fi
    if [ "$unresolved" -gt 0 ] 2>/dev/null; then
        # List the offending threads (path:line) so the block is actionable and
        # the bypass is front-and-center (false-block trust erosion mitigation,
        # plan-critic #5).
        local locs
        locs=$(printf '%s' "$threads" | jq -r \
            '[.data.repository.pullRequest.reviewThreads.nodes[]? | select(.isResolved==false) | select((.comments.nodes[0].author.login // "") | test("coderabbit"; "i")) | "\(.path // "?"):\(.line // "?")"] | join(", ")' \
            2>/dev/null || true)
        echo "BLOCK: $unresolved unresolved CodeRabbit review thread(s) on PR #$num [$locs]. Fix + RESOLVE each thread (operator rule 2026-07-12), or bypass with CR_MERGE_GATE_OK=1 in the launching shell if already adjudicated."
        return 2
    fi

    # 2) CodeRabbit check-run still running on the head SHA
    local runs pending
    runs=$(gh api "repos/$owner/$name/commits/$head/check-runs?per_page=100" 2>/dev/null) || { _cmg_degrade "check-runs query failed"; return 0; }
    pending=$(printf '%s' "$runs" | jq -r \
        '[.check_runs[]? | select(.name=="CodeRabbit") | select(.status!="completed")] | length' \
        2>/dev/null || true)
    if [ -z "$pending" ]; then _cmg_degrade "check-runs parse failed"; return 0; fi
    if [ "$pending" -gt 0 ] 2>/dev/null; then
        local zombie_mins started started_count started_epoch now_epoch age_secs statuses status_state
        zombie_mins="${CR_ZOMBIE_CHECKRUN_MINS:-90}"
        case "$zombie_mins" in ''|*[!0-9]*) zombie_mins=90 ;; esac
        # 10# guard (coderabbit 980-r4): a leading-zero value ("090") passes
        # the digit check but blows up base-8 arithmetic in $((… * 60)).
        zombie_mins=$((10#$zombie_mins))
        started=$(printf '%s' "$runs" | jq -r \
            '[.check_runs[]? | select(.name=="CodeRabbit") | select(.status=="in_progress") | .started_at // empty] | max // empty' \
            2>/dev/null || true)
        started_count=$(printf '%s' "$runs" | jq -r \
            '[.check_runs[]? | select(.name=="CodeRabbit") | select(.status=="in_progress") | select(.started_at != null)] | length' \
            2>/dev/null || true)
        started_epoch=$(_cmg_started_epoch "$started" 2>/dev/null || true)
        now_epoch=$(date -u +%s 2>/dev/null || true)
        # threads_page_complete must be exactly "true": any second page (or a
        # malformed/missing pageInfo) means the zero-unresolved evidence did not
        # cover every thread, and the override may not certify what it never
        # saw (codex-adv-1). The plain in-flight BLOCK below still runs either way.
        if [ "$threads_page_complete" = "true" ] \
            && [ "$started_count" = "$pending" ] && [ -n "$started_epoch" ] && [ -n "$now_epoch" ]; then
            age_secs=$((now_epoch - started_epoch))
            if [ "$age_secs" -gt $((zombie_mins * 60)) ]; then
                statuses=$(gh api "repos/$owner/$name/commits/$head/status" 2>/dev/null) || statuses=""
                status_state=$(printf '%s' "$statuses" | jq -r \
                    '[.statuses[]? | select(.context=="CodeRabbit")][0].state // empty' \
                    2>/dev/null || true)
                if [ "$status_state" = "success" ]; then
                    echo "zombie check-run override: CodeRabbit run in_progress since $started (>${zombie_mins}m) but commit status=success + 0 unresolved threads — treating as completed (HIMMEL-980)" >&2
                    return 0
                fi
            fi
        fi
        echo "BLOCK: CodeRabbit is still reviewing head $head of PR #$num (check-run not completed). Wait for it, then re-check threads. Bypass: CR_MERGE_GATE_OK=1."
        return 2
    fi

    return 0
}
