#!/usr/bin/env bash
# Pre-commit hook: refuse commits on `main` from the primary worktree.
# Predicate sourced from scripts/guardrails/lib.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../guardrails/lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../guardrails/lib.sh"

# Bootstrap exemption: a repo's first-ever commit legitimately lands on the
# initial branch (main) — there is no existing main to protect yet, so
# worktree-isolation does not apply. An unborn HEAD (zero commits) means the
# scaffold is being committed for the first time; allow it. Without this, a
# fresh vault (git init + run setup.sh, then commit the scaffold) is blocked
# on its very first commit and has to be committed on a throwaway branch and
# have main recreated by hand.
if ! git rev-parse --verify -q HEAD >/dev/null 2>&1; then
    exit 0
fi

# Single-writer opt-in: a repo with a local `.single-writer` marker at its
# root commits straight to main by design (personal vaults / state repos);
# the worktree-forcing block does not apply. Mirrors block-edit-on-main.sh.
# On internal error the predicate returns false (fail-closed) and we fall
# through to the normal is_on_main check below.
if is_single_writer_repo; then
    exit 0
fi

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
