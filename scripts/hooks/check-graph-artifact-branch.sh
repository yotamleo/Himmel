#!/usr/bin/env bash
# Pre-commit hook: refuse staged changes under graphify-out/ unless the
# commit is happening on the sanctioned /graph-publish flow (HIMMEL-2167).
#
# Why: two worker PRs (#1958, #1959) ran `graphify update .` per the
# CLAUDE.md graphify installer section and committed graphify-out/ artifacts
# onto ordinary feature branches. Both went CONFLICTING the moment the
# dedicated graph-publish PR (#1956) merged a newer graph to main — second
# drift of the same class, hence a structural gate instead of more prose.
#
# graphify-out/ is only meant to change via the /graph-publish flow, which
# runs on a chore/graph-publish-* branch. Anything else staging under
# graphify-out/ is blocked unless the operator explicitly opts out with
# GRAPH_COMMIT_OK=1 (e.g. a deliberate one-off fix to the tracked graph).
#
# Only NEWLY-STAGED graphify-out/ paths matter here; scope is enforced both
# by this branch check and by the `files: ^graphify-out/` pre-commit filter,
# so the hook only even runs when graph files are staged. bash 3.2-safe (no
# mapfile/associative arrays).
set -euo pipefail

if [ "${GRAPH_COMMIT_OK:-}" = "1" ]; then
    exit 0
fi

branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
case "$branch" in
    chore/graph-publish-*)
        exit 0 ;;
esac

staged=$(git diff --cached --name-only -- graphify-out/ 2>/dev/null || true)
if [ -z "$staged" ]; then
    exit 0
fi

echo "ERROR: graph-artifact-branch — staged graphify-out/ changes on branch '$branch':" >&2
while IFS= read -r line; do echo "  $line" >&2; done <<< "$staged"
echo "" >&2
echo "graph changes ship via /graph-publish (chore/graph-publish-* branch) or GRAPH_COMMIT_OK=1" >&2
echo "" >&2
echo "Commit blocked." >&2
exit 1
