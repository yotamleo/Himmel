#!/usr/bin/env bash
# Pre-push hook: block direct push to main.
# Input from git: "local_ref local_sha remote_ref remote_sha" per line on stdin.
#
# HIMMEL-2371 root cause: this hook is wired as a pre-commit-configured
# `stages: [pre-push]` entry (.pre-commit-config.yaml, id: no-push-to-main).
# pre-commit's own hook-impl reads ALL of git's pre-push stdin itself, before
# invoking any configured hook (hook_impl.py: `sys.stdin.buffer.read()` —
# see check-cr-before-push.sh's HIMMEL-1540 section for the fuller writeup),
# and exposes the pushed ref to configured hooks only via PRE_COMMIT_* env
# vars. The old `while read` loop here always saw an already-drained (EOF)
# stdin in that shape, ran zero iterations, and fell through to `exit 0` —
# passing EVERY push, including a direct push to main, under the exact
# invocation shape pre-commit actually uses (confirmed against the installed
# pre-commit 4.6.0 source; not Windows-specific). No bypass env var or
# .single-writer marker is involved — this script never read either.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../guardrails/lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../guardrails/lib.sh"

block_main() {
    echo "ERROR: Direct push to 'main' is not allowed." >&2
    echo "       Open a PR from a worktree branch instead." >&2
    exit 1
}

# Read the ref stream ONCE (mirrors check-cr-before-push.sh) — stdin cannot
# be rewound. `[ ! -t 0 ]` avoids blocking on a bare interactive terminal.
push_ref_lines=""
if [ ! -t 0 ]; then
    push_ref_lines=$(cat)
fi

if [ -n "$push_ref_lines" ]; then
    while IFS=' ' read -r _local_ref _local_sha remote_ref _remote_sha; do
        [ -z "$remote_ref" ] && continue
        is_main_ref "$remote_ref" && block_main
    done <<REF_LINES
$push_ref_lines
REF_LINES
    exit 0
fi

# Empty stdin. git's pre-push protocol reports a line only for a ref that is
# actually moving, so an empty-but-connected stdin from a REAL invocation
# (a genuine .git/hooks/pre-push, the pre-push.legacy migration hook, or a
# direct/manual/test invocation) trustworthily means nothing is being pushed
# — safe to allow. The one shape where empty stdin is NOT trustworthy is
# pre-commit's own configured-hook dispatch (commands/run.py), which drains
# stdin unconditionally before running ANY configured hook, whether or not a
# ref actually moved. `PRE_COMMIT=1` is the env var pre-commit sets ONLY
# around that dispatch (never around its legacy-hook subprocess call, and
# never present outside pre-commit) — it is the one reliable signal that
# distinguishes the two, so check it before trusting an empty stdin.
if [ "${PRE_COMMIT:-}" = "1" ]; then
    # PRE_COMMIT_REMOTE_BRANCH names the first pushed ref (set together with
    # PRE_COMMIT_REMOTE_NAME/URL whenever a ref actually moved — see
    # check-cr-before-push.sh). This branch alone only sees the FIRST ref of
    # a multi-ref push, so a main push ordered after a non-main ref in the
    # same `git push` would slip past it in isolation. That gap is closed by
    # install-cr-pre-push-legacy.sh, which now runs this same script against
    # git's complete, undrained ref stream ahead of the CR gate — the branch
    # below is defense-in-depth for a clone that has not (yet) run it.
    if [ -n "${PRE_COMMIT_REMOTE_BRANCH:-}" ]; then
        is_main_ref "$PRE_COMMIT_REMOTE_BRANCH" && block_main
        exit 0
    fi
    # PRE_COMMIT=1 but no PRE_COMMIT_REMOTE_BRANCH: pre-commit's documented
    # pre-push env contract (HIMMEL-1540) did not hold as expected. Fail
    # CLOSED rather than assume a benign push — a silent exit 0 here is
    # exactly the bug this ticket exists to close.
    echo "ERROR: check-push-target: pre-commit reports a pre-push hook run (PRE_COMMIT=1) but never set PRE_COMMIT_REMOTE_BRANCH — refusing the push (cannot determine the pushed ref)." >&2
    exit 1
fi

exit 0
