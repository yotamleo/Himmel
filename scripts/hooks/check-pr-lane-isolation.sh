#!/usr/bin/env bash
# Pre-commit gate: refuse commits on `main` that touch PR-lane paths.
#
# Portable export of himmel's worktree-isolation posture for two-lane repos
# like luna (HIMMEL-214: isolation was structurally enforced only in himmel;
# other repos relied on prose). Consumed via pre-commit's remote-repo
# mechanism: the consuming repo references himmel in .pre-commit-config.yaml
# and scopes this hook with a `files:` regex listing its PR-lane paths.
# pre-commit then invokes this script ONLY when a staged file matches,
# passing the matched filenames as args:
#   - on a feature branch         -> allow (lane rule satisfied via PR flow)
#   - on main, PR-lane file(s)    -> block (structural change needs a PR)
#   - on main, no matching files  -> hook not invoked at all (vault-content /
#     plugin-lane commits to main pass untouched)
# With no `files:` filter in the consuming config, every staged file matches
# and the gate degrades to full isolation (block all commits on main, with
# the offending paths listed).
#
# Predicate sourced from scripts/guardrails/lib.sh, same as the sibling
# check-worktree-isolation.sh. This works when consumed remotely because
# pre-commit clones the ENTIRE hook repo into its cache, so SCRIPT_DIR-
# relative paths resolve inside that clone while CWD stays the consuming
# repo's root (which is the git state `is_on_main` reads).
#
# Consumer snippet + luna's concrete PR-lane regex: docs/luna/pr-lane-guard.md.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Sourced GUARDED (CR finding, mirrors block-edit-on-main.sh's py-armor
# pattern): without -e a failed source would fall through to an undefined
# `is_on_main` (rc=127) and only fail closed by accident of the `*)` arm.
# Make the fail-closed explicit instead.
# shellcheck source=../guardrails/lib.sh
# shellcheck disable=SC1091
if ! . "$SCRIPT_DIR/../guardrails/lib.sh" 2>/dev/null; then
    echo "ERROR: pr-lane-isolation cannot source guardrails/lib.sh — refusing to allow commit." >&2
    exit 1
fi

# No filenames: only reachable when a consumer adds `always_run: true`
# (pre-commit then fires the hook even though no staged file matched its
# `files:` filter — without always_run, a no-match commit skips the hook
# entirely and never enters this script). Exit 0 = allow: safe ONLY because
# there are no matched PR-lane files to gate, not because anything was
# checked. Do NOT combine this hook with `always_run: true` or
# `pass_filenames: false` in a consuming config — both degrade it to a
# no-op (see .pre-commit-hooks.yaml).
if [ "$#" -eq 0 ]; then
    exit 0
fi

# Branch explicitly on rc so internal errors (rc=2) fail closed rather than
# being silently demoted to "not on main" by bash `if`.
is_on_main
rc=$?
case "$rc" in
    1)
        exit 0
        ;;
    0)
        echo "ERROR: commit on 'main' touches PR-lane path(s):"
        for f in "$@"; do
            echo "         $f"
        done
        echo "       Two-lane rule: structural changes go through worktree + branch + PR."
        echo "       Create a branch (e.g. 'git switch -c chore/<slug>') and open a PR."
        echo "       Deliberate exception: SKIP=pr-lane-isolation git commit ..."
        exit 1
        ;;
    *)
        echo "ERROR: pr-lane-isolation could not determine current branch (is_on_main rc=$rc)." >&2
        echo "       Refusing to allow commit. Fix the repository state and retry." >&2
        exit 1
        ;;
esac
