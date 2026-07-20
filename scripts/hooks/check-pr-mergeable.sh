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
# - Skips on a protected default (main OR master — HIMMEL-297) / detached
#   HEAD (no PR ever opens for the default branch; detached pushes have no
#   head ref to query).
# - Asks forge_pr_mergeable for the branch's open PR. On GitHub that now
#   computes the conflict LOCALLY via `git merge-tree` (HIMMEL-1232) rather
#   than reading GitHub's flaky async `mergeable` field. When no PR exists,
#   exits 0 (nothing to gate on).
# - Refuses (exit 1) when the verdict is `CONFLICTING`. Surfaces the
#   PR URL + the gh command to inspect.
# - Falls back to exit 0 (best-effort) when gh CLI is missing or
#   unauthenticated — a hard refuse would block pushes whenever the
#   operator works offline.
#
# Bypass: SKIP_PR_MERGEABLE=1 git push ... (logs WARNING).
#
# HIMMEL-326: routes through the forge seam (scripts/lib/forge.sh), so it gates
# GitHub and Bitbucket Cloud. On Bitbucket forge_pr_mergeable always returns
# UNKNOWN (no pre-merge mergeable signal — spec §5.1), so this hook never blocks
# a Bitbucket push; the conflict surfaces at merge time instead.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/forge.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/forge.sh"

# Drain stdin first so pre-commit doesn't deadlock when push touches
# many refs. We don't actually need stdin content for the mergeable
# check — it's branch-scoped.
while read -r _line; do :; done

if [ "${SKIP_PR_MERGEABLE:-0}" = "1" ]; then
    echo "→ pr-mergeable: SKIP_PR_MERGEABLE=1 — skipping (WARNING: confirm gh pr view --json mergeable is not CONFLICTING before merging)" >&2
    exit 0
fi

branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
if [ -z "$branch" ] || [ "$branch" = "main" ] || [ "$branch" = "master" ]; then
    exit 0
fi

# Determine the forge; without an origin we can't gate — skip best-effort.
if ! forge_detect >/dev/null 2>&1; then
    echo "→ pr-mergeable: cannot determine forge (no github/bitbucket origin) — skipping (best-effort)" >&2
    exit 0
fi

# Best-effort: a hard refuse would block pushes whenever the operator works
# offline or the forge CLI is missing / unauthenticated.
if ! forge_auth_status 2>/dev/null; then
    echo "→ pr-mergeable: forge CLI missing or unauthenticated — skipping (best-effort)" >&2
    exit 0
fi

# Query mergeability for this branch's open PR. forge_pr_mergeable accepts a
# branch ref (the github backend's `gh pr view <branch>` resolves it) and prints
# MERGEABLE / CONFLICTING / UNKNOWN, or empty when no PR exists.
mergeable=$(forge_pr_mergeable "$branch" 2>/dev/null || true)

if [ -z "$mergeable" ] || [ "$mergeable" = "null" ]; then
    # No PR for this branch — nothing to gate on. The pr-open step
    # will create one on the next push.
    exit 0
fi

case "$mergeable" in
    CONFLICTING)
        # Only GitHub yields CONFLICTING here — Bitbucket's forge_pr_mergeable
        # is hardcoded UNKNOWN — so the inspect hint stays gh-flavored.
        cat >&2 <<EOF
ERROR: the open PR for branch '$branch' is in CONFLICTING state.
       Resolve merge conflicts before pushing.

       Inspect: gh pr view $branch --json mergeable,mergeStateStatus

Bypass: SKIP_PR_MERGEABLE=1 git push ...
EOF
        exit 1
        ;;
    MERGEABLE|UNKNOWN|*)
        # MERGEABLE: clearly OK. UNKNOWN: a tooling gap (git < 2.38, base/head
        # refs unavailable — GitHub) or no pre-merge signal (Bitbucket). Let it
        # through best-effort — the merge gate (scripts/handover/pr-merge.sh)
        # runs the same local check again and blocks at merge time if it is
        # actually conflicting. Anything else: be lenient.
        exit 0
        ;;
esac
