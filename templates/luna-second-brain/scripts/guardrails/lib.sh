#!/usr/bin/env bash
# scripts/guardrails/lib.sh — shared git-state predicates.
#
# Sourced by:
#   - scripts/hooks/check-worktree-isolation.sh
#   - scripts/hooks/check-push-target.sh
#   - scripts/hooks/check-no-force-push.sh
#
# Contract: each predicate returns one of:
#   0 - true  (predicate holds)
#   1 - false (predicate does not hold)
#   2 - internal error: predicate cannot be evaluated (git missing, repo
#       broken, required ref absent). Callers MUST treat rc=2 as fail-closed.
#
# rc=2 is silent (predicates do NOT print to stderr); the caller is the right
# place to emit a context-specific diagnostic on fail-closed paths.
#
# Each predicate accepts an optional first arg DIR (defaults to PWD).
# Exception: `is_main_ref` takes a ref string (not a directory).

set -uo pipefail

# guard_call PREDICATE [ARGS...]
# Wraps a predicate call so rc=2 (internal error) becomes an immediate
# fail-closed exit instead of being silently demoted to "false" by bash `if`.
# Use as:   if guard_call is_on_main "$dir"; then ...
guard_call() {
    local name="$1"; shift
    "$name" "$@"
    local rc=$?
    if [ "$rc" -eq 2 ]; then
        echo "guardrails: $name returned rc=2 (internal error) - fail-closed" >&2
        exit 2
    fi
    return "$rc"
}

# Internal: current branch name from the worktree-specific HEAD file.
# `git branch --show-current` resolves main-repo HEAD from linked worktrees,
# which is the wrong answer when we want THIS worktree's branch. Read HEAD
# directly.
#
# Detached-HEAD handling: prints empty string and returns rc=1 (no current
# branch). Callers MUST distinguish empty branch from a valid branch name.
_branch() {
    local dir="${1:-.}"
    local git_dir
    git_dir=$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null) || return 2
    local head_file="${git_dir}/HEAD"
    if [ ! -f "$head_file" ]; then
        return 2
    fi
    local ref
    ref=$(cat "$head_file") || return 2
    case "$ref" in
        "ref: refs/heads/"*)
            printf '%s' "${ref#ref: refs/heads/}"
            ;;
        *)
            printf ''
            return 1
            ;;
    esac
}

# is_on_main [DIR]
# True iff current branch is exactly "main".
# Returns 1 on detached HEAD (no current branch is "main").
is_on_main() {
    local b rc
    b=$(_branch "${1:-.}"); rc=$?
    if [ "$rc" -eq 2 ]; then return 2; fi
    [ "$b" = "main" ]
}

# is_main_ref REF
# True iff REF is refs/heads/main. Used by check-push-target.sh which reads
# remote refs from git's pre-push stdin contract.
is_main_ref() {
    [ "${1:-}" = "refs/heads/main" ]
}

# is_dirty [DIR]
# True iff `git status --porcelain` has any output (staged, unstaged, or
# untracked).
is_dirty() {
    local dir="${1:-.}"
    local out
    out=$(git -C "$dir" status --porcelain 2>/dev/null) || return 2
    [ -n "$out" ]
}
