#!/usr/bin/env bash
# Pre-push hook: refuse to push when the open PR for the current branch
# has mergeable: CONFLICTING (HIMMEL-136).
#
# Pre-commit framework wires this into the pre-push stage. Stdin
# contract: "local_ref local_sha remote_ref remote_sha" per line — same
# as check-push-target.sh.
#
# Behavior:
# - Drains stdin so the pre-commit framework doesn't deadlock when the
#   push contains many refs.
# - Resolves the current branch via `git symbolic-ref HEAD`.
# - Skips on main / detached HEAD (no PR ever opens for main; detached
#   pushes have no head ref to query).
# - Queries `gh pr view --head <branch> --json mergeable`. When no PR
#   exists, exits 0 (nothing to gate on).
# - Refuses (exit 1) when `mergeable` is `CONFLICTING`. Surfaces the
#   PR URL + the gh command to inspect.
# - Falls back to exit 0 (best-effort) when gh CLI is missing or
#   unauthenticated — a hard refuse would block pushes whenever the
#   operator works offline.
#
# Bypass: SKIP_PR_MERGEABLE=1 git push ... (logs WARNING).
set -uo pipefail

# Drain stdin first so pre-commit doesn't deadlock when push touches
# many refs. We don't actually need stdin content for the mergeable
# check — it's branch-scoped.
while read -r _line; do :; done

if [ "${SKIP_PR_MERGEABLE:-0}" = "1" ]; then
    echo "→ pr-mergeable: SKIP_PR_MERGEABLE=1 — skipping (WARNING: confirm gh pr view --json mergeable is not CONFLICTING before merging)" >&2
    exit 0
fi

branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
if [ -z "$branch" ] || [ "$branch" = "main" ]; then
    exit 0
fi

GH_CMD="${GH_CMD:-gh}"

if ! command -v "${GH_CMD%% *}" >/dev/null 2>&1; then
    echo "→ pr-mergeable: gh CLI missing — skipping (best-effort)" >&2
    exit 0
fi

if ! $GH_CMD auth status >/dev/null 2>&1; then
    echo "→ pr-mergeable: gh CLI not authenticated — skipping (best-effort)" >&2
    exit 0
fi

mergeable=""
if pr_json=$($GH_CMD pr view --json mergeable,url,number --jq '{m: .mergeable, u: .url, n: .number}' "$branch" 2>/dev/null); then
    # gh prints "null" or empty when no PR exists.
    if [ -n "$pr_json" ] && [ "$pr_json" != "null" ]; then
        # Parse the three fields without a jq dep — gh already pre-formatted.
        mergeable=$(printf '%s' "$pr_json" | grep -oE '"m":"[^"]*"' | head -1 | sed 's/.*:"\(.*\)"/\1/')
        pr_url=$(printf '%s' "$pr_json" | grep -oE '"u":"[^"]*"' | head -1 | sed 's/.*:"\(.*\)"/\1/')
        pr_num=$(printf '%s' "$pr_json" | grep -oE '"n":[0-9]+' | head -1 | sed 's/.*://')
    fi
fi

if [ -z "$mergeable" ]; then
    # No PR for this branch — nothing to gate on. The pr-open step
    # will create one on the next push.
    exit 0
fi

case "$mergeable" in
    CONFLICTING)
        cat >&2 <<EOF
ERROR: PR #${pr_num} for branch '$branch' is in CONFLICTING state.
       Resolve merge conflicts before pushing.

       Inspect: gh pr view ${pr_num} --json mergeable,mergeStateStatus
       PR URL:  ${pr_url}

Bypass: SKIP_PR_MERGEABLE=1 git push ...
EOF
        exit 1
        ;;
    MERGEABLE|UNKNOWN|*)
        # MERGEABLE: clearly OK. UNKNOWN: gh hasn't computed yet — let it
        # through; the gh pr merge gate will block again at merge time
        # if it's actually conflicting. Anything else: be lenient.
        #
        # Two-stage UNKNOWN handling (HIMMEL-179): this pre-push pass-through
        # is stage 1. Stage 2 is the bounded mergeability poll in
        # scripts/handover/pr-merge.sh, which waits for UNKNOWN to settle to
        # MERGEABLE/CONFLICTING before the real `gh pr merge`.
        exit 0
        ;;
esac
