#!/usr/bin/env bash
# Pre-commit hook: refuse commits on `main` from the primary worktree.
# Predicate sourced from scripts/guardrails/lib.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../guardrails/lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../guardrails/lib.sh"

is_on_main
rc=$?
case "$rc" in
    0)
        echo "ERROR: Committing directly on 'main' is not allowed."
        echo "       Create a worktree branch: 'git worktree add' or 'git switch -c <type>/<slug>'."
        exit 1
        ;;
    1)
        exit 0
        ;;
    *)
        echo "ERROR: worktree-isolation could not determine current branch (is_on_main rc=$rc)." >&2
        echo "       Refusing to allow commit. Fix the repository state and retry." >&2
        exit 1
        ;;
esac
