#!/usr/bin/env bash
# scripts/console/sweep-cr-threads.sh — fail-closed GraphQL review-thread
# sweep for a judge/console session (HIMMEL-2320).
#
# Freezes an ad-hoc sweep that shipped a false-clean verdict: it queried
# reviewThreads against the WRONG repo slug (yotamleo/himmel instead of
# yotamleo/himmel). GitHub's GraphQL API answers an unknown
# owner/name/number with an `errors` array and a null `pullRequest` — NOT an
# HTTP failure — so a naive `--jq '... | length'` over that response counts
# zero threads, indistinguishable from a genuinely clean PR. This script
# never folds that shape into a count: it checks `.errors` and a null
# `pullRequest` explicitly, per PR, and exits nonzero the moment either
# fires.
#
# Usage:
#   scripts/console/sweep-cr-threads.sh            # every OPEN PR in this repo
#   scripts/console/sweep-cr-threads.sh 101 104     # only these PR numbers
#
# Repo slug: resolved via `gh repo view --json nameWithOwner` — NEVER
# hardcoded (that hardcode is the exact bug this script exists to prevent).
#
# Output (stdout), one line per PR:
#   PR <number>: <thread_count> threads, <unresolved_count> unresolved
# On a query error (stderr), loud and per-PR:
#   QUERY-ERROR PR <number>: <detail>
# Exit: 0 only if every PR swept cleanly (queried successfully, whatever the
# counts); nonzero if ANY PR hit a QUERY-ERROR or the repo slug/PR list could
# not be resolved.
#
# Env: GH_CMD overrides the `gh` binary (test seam, matches scripts/lib/forge-github.sh).
set -uo pipefail

_gh() { "${GH_CMD:-gh}" "$@"; }

command -v jq >/dev/null 2>&1 || { echo "sweep-cr-threads: jq is required" >&2; exit 1; }

nwo=$(_gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || {
    echo "sweep-cr-threads: 'gh repo view' failed — cannot resolve the repo slug, aborting (fail-closed)" >&2
    exit 1
}
[ -n "$nwo" ] || { echo "sweep-cr-threads: 'gh repo view' returned an empty slug — aborting" >&2; exit 1; }
owner=${nwo%%/*}
name=${nwo#*/}

if [ "$#" -gt 0 ]; then
    for arg in "$@"; do
        case "$arg" in
            ''|*[!0-9]*)
                echo "sweep-cr-threads: '$arg' is not a PR number — usage: sweep-cr-threads.sh [PR_NUMBER ...]" >&2
                exit 1
                ;;
        esac
    done
    pr_numbers="$*"
else
    # --limit 1000: gh's own default is 30, which would silently drop open
    # PRs past the first page on a repo with more than that — exactly the
    # kind of undercount this script exists to prevent.
    pr_numbers=$(_gh pr list --state open --limit 1000 --json number --jq '.[].number' 2>/dev/null) || {
        echo "sweep-cr-threads: 'gh pr list' failed — cannot enumerate open PRs, aborting (fail-closed)" >&2
        exit 1
    }
    if [ -z "$pr_numbers" ]; then
        echo "sweep-cr-threads: 0 open PRs found on $nwo — nothing to sweep" >&2
    elif [ "$(printf '%s\n' "$pr_numbers" | wc -l)" -ge 1000 ]; then
        # gh truncates silently at --limit with no "more remain" signal — at
        # exactly the cap we cannot certify every open PR was enumerated, so
        # this is a QUERY-ERROR, not a (possibly incomplete) sweep.
        echo "sweep-cr-threads: 'gh pr list' returned >=1000 open PRs — cannot certify the sweep covers every open PR at this --limit; pass explicit PR numbers instead" >&2
        exit 1
    fi
fi

# shellcheck disable=SC2016  # GraphQL variables ($owner/$name/$number) are literal here
query='query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){reviewThreads(first:100){totalCount nodes{isResolved}}}}}'

had_error=0
for num in $pr_numbers; do
    resp=$(_gh api graphql -f owner="$owner" -f name="$name" -F number="$num" -f query="$query" 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "QUERY-ERROR PR $num: gh api graphql failed (rc=$rc): $resp" >&2
        had_error=1
        continue
    fi
    if [ "$(printf '%s' "$resp" | jq -r 'has("errors")' 2>/dev/null)" = "true" ]; then
        detail=$(printf '%s' "$resp" | jq -r '[.errors[]?.message // (.errors[]? | tostring)] | join("; ")' 2>/dev/null)
        echo "QUERY-ERROR PR $num: GraphQL returned errors: ${detail:-$resp}" >&2
        had_error=1
        continue
    fi
    pr_node=$(printf '%s' "$resp" | jq -c '.data.repository.pullRequest' 2>/dev/null)
    if [ -z "$pr_node" ] || [ "$pr_node" = "null" ]; then
        echo "QUERY-ERROR PR $num: pullRequest resolved to null (wrong repo slug, or PR does not exist on $nwo)" >&2
        had_error=1
        continue
    fi
    total=$(printf '%s' "$pr_node" | jq -r '.reviewThreads.totalCount')
    returned=$(printf '%s' "$pr_node" | jq -r '.reviewThreads.nodes | length')
    case "$total" in
        ''|*[!0-9]*)
            echo "QUERY-ERROR PR $num: reviewThreads.totalCount is not a number ('$total') — malformed response, cannot certify a count" >&2
            had_error=1
            continue
            ;;
    esac
    if [ "$returned" -lt "$total" ] 2>/dev/null; then
        echo "QUERY-ERROR PR $num: $total review threads exceed this sweep's single page ($returned returned) — unresolved count would be incomplete" >&2
        had_error=1
        continue
    fi
    unresolved=$(printf '%s' "$pr_node" | jq -r '[.reviewThreads.nodes[]? | select(.isResolved==false)] | length')
    case "$unresolved" in
        ''|*[!0-9]*)
            echo "QUERY-ERROR PR $num: unresolved-thread count is not a number ('$unresolved') — malformed response, cannot certify a count" >&2
            had_error=1
            continue
            ;;
    esac
    echo "PR $num: $total threads, $unresolved unresolved"
done

exit "$had_error"
