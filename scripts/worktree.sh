#!/usr/bin/env bash
# Create a worktree without pruning. Companion to scripts/clean.sh.
#
# Thin wrapper over clean-garden.sh in --no-prune mode. Branch name is
# required (clean-garden.sh already enforces this combination); we
# pre-flight here so the operator sees a worktree-specific message
# rather than a clean-garden generic one.
set -euo pipefail

USAGE='Usage: worktree.sh <branch-name> [--no-install] [--verbose|-v] [--dry-run]

Creates a new git worktree under .claude/worktrees/<type>+<slug>/ for
the given branch. Branch name must be type/slug where type is one of
feat|fix|chore|docs|refactor|test (validated by _new-worktree.sh).

For combined prune-then-create, use /clean_garden or
scripts/clean-garden.sh. For prune-only, use /clean or scripts/clean.sh.'

# Help short-circuit (any position).
for arg in "$@"; do
    case "$arg" in
        -h|--help) printf '%s\n' "$USAGE"; exit 0 ;;
    esac
done

# Require at least one non-flag, non-empty positional arg (the branch).
# Catches: no args; flag-only invocations (`--verbose`); empty-string
# branch (`worktree.sh ""`). Without this, the orchestrator emits a
# generic `--no-prune requires a branch-name` message at rc=1.
have_branch=0
for arg in "$@"; do
    case "$arg" in
        -*) ;;                              # flag, skip
        '') ;;                              # empty positional, skip
        *) have_branch=1; break ;;
    esac
done
if [ "$have_branch" -eq 0 ]; then
    printf '%s\n' "$USAGE" >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/clean-garden.sh" --no-prune "$@"
