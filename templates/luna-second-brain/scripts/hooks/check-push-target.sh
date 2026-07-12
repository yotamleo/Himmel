#!/usr/bin/env bash
# Pre-push hook: block direct push to main.
# Input from git: "local_ref local_sha remote_ref remote_sha" per line on stdin.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../guardrails/lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../guardrails/lib.sh"

# Single-writer opt-in: a repo with a local `.single-writer` marker pushes
# main directly by design (personal vaults / state repos). Mirrors the
# worktree-isolation pre-commit gate / block-edit-on-main.sh.
if is_single_writer_repo; then
    exit 0
fi

while read -r _local_ref _local_sha remote_ref _remote_sha; do
    if is_main_ref "$remote_ref"; then
        echo "ERROR: Direct push to 'main' is not allowed."
        echo "       Open a PR from a worktree branch instead."
        exit 1
    fi
done
exit 0
