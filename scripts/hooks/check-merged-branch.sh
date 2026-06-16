#!/usr/bin/env bash
# Pre-commit hook: warn when committing on a branch already merged into main.
# Catches direct-merge AND squash-merge via patch-id (cherry-pick equivalence).
# Predicate sourced from scripts/guardrails/lib.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../guardrails/lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../guardrails/lib.sh"

# Branch explicitly on rc so rc=2 (e.g., shallow clone with no local `main`)
# fails closed rather than being silently demoted to "not merged".
is_merged_into_main
rc=$?
case "$rc" in
    0)
        # Use lib's _branch (worktree-aware) rather than `git branch
        # --show-current`, which resolves the MAIN-REPO HEAD when run from
        # a linked worktree.
        branch=$(_branch)
        echo "WARNING: Branch '${branch}' appears to be already merged into 'main' (direct or squash)."
        echo "         You may be editing stale code. Check out a fresh branch off main if so."
        exit 1
        ;;
    1)
        exit 0
        ;;
    *)
        echo "ERROR: merged-branch check could not evaluate (is_merged_into_main rc=$rc)." >&2
        echo "       Refusing to allow commit. Fix the repository state and retry." >&2
        exit 1
        ;;
esac
