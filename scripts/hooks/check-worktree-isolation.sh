#!/usr/bin/env bash
# Pre-commit hook: refuse commits on `main` from the primary worktree.
# Predicate sourced from scripts/guardrails/lib.sh so behavior stays in sync
# with the Claude PreToolUse hook block-edit-on-main.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../guardrails/lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../guardrails/lib.sh"

# Branch explicitly on rc so internal errors (rc=2) fail closed rather than
# being silently demoted to "not on main" by bash `if`.
is_on_main
rc=$?
case "$rc" in
    0)
        echo "ERROR: Committing directly on 'main' is not allowed."
        echo "       Create a worktree branch: EnterWorktree in Claude Code, or 'git worktree add'."
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
