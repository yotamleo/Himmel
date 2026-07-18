#!/usr/bin/env bash
# handover/pr-merge — squash-merge the PR for the current handover branch.
#
# HIMMEL-141 (HIMMEL-59 v2 child). Merge mode locked to squash per
# operator's 2026-05-25 decision: repo settings block merge-commits.
#
#   gh pr merge <N> --squash --delete-branch        (default)
#
# HIMMEL-224: default to a PLAIN squash merge — NO `--admin`. This repo has
# no branch protection, so `--admin` bypasses nothing yet trips the Opus
# auto-mode classifier's "bypassing the approval gate = destructive op"
# HARD-veto, stalling every overnight run. `--admin` is now only a FALLBACK,
# used when the plain merge fails for a non-cosmetic reason AND admin-merge is
# explicitly authorized via `GH_ADMIN_MERGE_OK=1` (the same env guard-gh.sh
# honors). If the plain merge fails and admin is not authorized, the gh error
# is surfaced with a stuck-playbook pointer and the script exits 4 — it never
# silently escalates privilege. Branch-delete cosmetic failure when the
# worktree is still held is expected and ignored on either attempt.
#
# Exit codes:
#   0  merged (or no PR found — nothing to merge)
#   1  usage error
#   2  required tool missing
#   3  not on a handover/* branch (refuses)
#   4  gh pr merge failed
#   5  blocked by the CR merge gate (unresolved CodeRabbit remarks - HIMMEL-936)
#   6  blocked by the CI-green merge gate (head SHA not green - HIMMEL-1043)
#   7  cannot read the PR head SHA, so the merge cannot be bound to the vetted
#      commit — refuses rather than merge unbound (HIMMEL-1058)
#
# Environment overrides:
#   FORGE / GH_CMD / BITBUCKET_CMD   Forge-seam overrides (HIMMEL-326). The PR
#                            merge routes through scripts/lib/forge.sh, so this
#                            works on GitHub and Bitbucket Cloud. The github
#                            backend still honors GH_CMD (tests set it to a stub).
#   GH_ADMIN_MERGE_OK        When `1`, authorizes the `--admin` fallback on a
#                            non-cosmetic plain-merge failure (GitHub only).
#                            Default off. The github backend reads this directly.
#   PR_MERGE_POLL_ATTEMPTS   Mergeability-poll attempts (HIMMEL-179). Default 5.
#   PR_MERGE_POLL_INTERVAL   Seconds slept between poll attempts. Default 3.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Forge-dispatch seam: forge_pr_find_open / forge_pr_mergeable / forge_pr_merge
# route to the github or bitbucket backend per the repo's origin (HIMMEL-326).
# The admin-fallback + cosmetic-branch-delete handling lives in the github
# backend (gh_forge_pr_merge); this script orchestrates find → poll → merge.
# shellcheck source=../lib/forge.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/forge.sh"

# GH_ADMIN_MERGE_OK is consumed by the github backend (gh_forge_pr_merge) — it
# reads the env var directly, so this script no longer normalizes it.
POLL_ATTEMPTS="${PR_MERGE_POLL_ATTEMPTS:-5}"
POLL_INTERVAL="${PR_MERGE_POLL_INTERVAL:-3}"
DRY_RUN=0

usage() {
    cat <<'EOF'
Usage: pr-merge.sh [--dry-run]

Squash-merges the PR associated with the current handover branch
(--squash --delete-branch). Repo settings forbid merge-commits, so
squash is the only allowed mode. Defaults to a plain merge; escalates to
--admin only on a non-cosmetic failure when GH_ADMIN_MERGE_OK=1.

Refuses (rc=3) if HEAD is not on a `handover/*` branch.

Optional:
  --dry-run    Print intended gh call; don't invoke.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)  DRY_RUN=1; shift ;;
        -h|--help)  usage; exit 0 ;;
        *)          echo "ERR pr-merge: unknown arg: $1" >&2; usage >&2; exit 1 ;;
    esac
done

if ! command -v git >/dev/null 2>&1; then
    echo "ERR pr-merge: required tool 'git' not on PATH" >&2
    exit 2
fi

repo_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$repo_root" ]; then
    echo "ERR pr-merge: not inside a git repo" >&2
    exit 2
fi

current_branch=$(git -C "$repo_root" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
case "$current_branch" in
    handover/*) ;;
    *)
        echo "ERR pr-merge: not on a handover/* branch (current: $current_branch). Refusing." >&2
        exit 3
        ;;
esac

# Determine the forge (github/bitbucket) from origin. Unlike pr-open, a merge is
# NOT best-effort — an undetermined forge is a hard misconfiguration (exit 2).
if ! forge=$(forge_detect); then
    exit 2
fi

# Locate the PR for this branch via the forge seam. Distinguish a genuine API
# failure (auth expired / network / 5xx) from "no PR exists": the former must
# NOT be reported as a clean no-op or an overnight run silently fails to ship
# (HIMMEL-224 CR — silent-failure-hunter).
pr_num=""
if ! pr_num=$(forge_pr_find_open "$current_branch"); then
    echo "ERR pr-merge: open-PR lookup failed for $current_branch (auth/network?). Cannot determine PR state — refusing to report success." >&2
    exit 4
fi
if [ -z "$pr_num" ]; then
    echo "pr-merge: no open PR found for $current_branch — nothing to merge."
    exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY pr-merge: would squash-merge PR #$pr_num on $forge (delete source branch)"
    exit 0
fi

# HIMMEL-936: CR merge gate on the same predicate as the PreToolUse hook, so
# machines without the plugin hook still get the gate on this path. Placed
# before the mergeability poll so a CR-blocked merge fails fast (exit 5)
# instead of burning the 5x3s poll (plan-critic #7). GitHub-only: cr_merge_gate
# resolves via gh; the bitbucket forge skips it.
vetted_head=""
if [ "$forge" = "github" ]; then
    # HIMMEL-1058 (TOCTOU): capture the head we are about to vet, and bind the
    # eventual merge to it. Captured BEFORE the gates on purpose — the gates run
    # inside `$(...)` subshells and cannot hand their own SHA back, so this is
    # the only value we can prove the gates saw-or-newer. If a push lands during
    # the gate run, the gate vets the NEWER sha while we stay bound to this one,
    # and `--match-head-commit` rejects the merge — loudly, which is the point.
    # A non-empty value is required for the binding to mean anything: fail rather
    # than silently fall back to an unbound merge.
    # "${GH_CMD:-gh}", not a bare `gh` — the forge seam's github backend routes
    # every call through GH_CMD and the tests set it to a stub.
    vetted_head=$("${GH_CMD:-gh}" pr view "$pr_num" --json headRefOid --jq '.headRefOid' 2>/dev/null) || vetted_head=""
    if [ -z "$vetted_head" ]; then
        echo "ERR pr-merge: cannot read the head SHA of PR #$pr_num — refusing to merge unbound (HIMMEL-1058)." >&2
        exit 7
    fi

    # shellcheck disable=SC1091
    if . "$SCRIPT_DIR/../lib/cr-merge-gate.sh" 2>/dev/null; then
        _gate_reason=""
        _gate_rc=0
        _gate_reason=$(cr_merge_gate "$pr_num") || _gate_rc=$?
        if [ "$_gate_rc" = "2" ]; then
            echo "pr-merge: CR gate: $_gate_reason" >&2
            exit 5
        fi
    fi
    # HIMMEL-1043: CI-green gate, same predicate as the PreToolUse hook's
    # second gate, so machines without the plugin hook still require green CI
    # on this path. Runs AFTER the CR gate (exit 5) and before the
    # mergeability poll; a CI-blocked merge fails fast (exit 6). pr-merge passes
    # only the PR number (no --repo): a selector that fails to resolve is a
    # plain fail-open rc=3 here — no cwd-branch re-anchor (this path already
    # knows its PR via forge_pr_find_open).
    # shellcheck disable=SC1091
    if . "$SCRIPT_DIR/../lib/ci-green-gate.sh" 2>/dev/null; then
        _ci_reason=""
        _ci_rc=0
        _ci_reason=$(ci_green_gate "$pr_num") || _ci_rc=$?
        if [ "$_ci_rc" = "2" ]; then
            echo "pr-merge: CI gate: $_ci_reason" >&2
            exit 6
        fi
    fi
fi

# Bounded poll for mergeability to settle before merging (HIMMEL-179 sharp#1) —
# GitHub only. This is the SECOND stage of the two-stage UNKNOWN handling: the
# pre-push gate (scripts/hooks/check-pr-mergeable.sh, HIMMEL-136) lets
# `mergeable: UNKNOWN` pass through because GitHub hasn't finished computing
# mergeability right after a push; that pass-through can leave the real merge
# below to fail, so we wait for `mergeable` to settle:
#   MERGEABLE       -> proceed to merge.
#   CONFLICTING     -> fail fast (exit 4); a conflict won't self-resolve.
#   UNKNOWN / empty -> retry after a short sleep; if attempts exhaust while still
#                      unsettled, fall through to the merge attempt (preserve the
#                      pre-check's pass-through behavior — don't hard-fail). A
#                      transient view-query failure surfaces as empty here too.
# Bitbucket Cloud has no mergeable field (forge_pr_mergeable returns UNKNOWN), so
# the poll is pointless there — the 400 at merge time is the only conflict signal
# (spec §5.1), surfaced by forge_pr_merge. Skip the poll entirely for bitbucket.
if [ "$forge" = "github" ]; then
    attempt=1
    while [ "$attempt" -le "$POLL_ATTEMPTS" ]; do
        mergeable=$(forge_pr_mergeable "$pr_num")
        case "$mergeable" in
            MERGEABLE)
                break
                ;;
            CONFLICTING)
                echo "ERR pr-merge: PR #$pr_num is CONFLICTING — resolve conflicts before merging. Refusing." >&2
                exit 4
                ;;
            *)
                # UNKNOWN (or empty/unexpected): still computing or a transient
                # view failure. Retry after a sleep; never sleep after the last.
                if [ "$attempt" -lt "$POLL_ATTEMPTS" ]; then
                    echo "pr-merge: PR #$pr_num mergeable=${mergeable:-<empty>} (attempt $attempt/$POLL_ATTEMPTS) — waiting ${POLL_INTERVAL}s" >&2
                    sleep "$POLL_INTERVAL"
                fi
                ;;
        esac
        attempt=$((attempt + 1))
    done
fi

# Squash-merge via the forge seam. The github backend does a PLAIN squash first
# and escalates to --admin only when GH_ADMIN_MERGE_OK=1 (HIMMEL-224); it also
# absorbs the cosmetic worktree-held branch-delete error. The bitbucket backend
# maps a 400 merge-conflict (spec §5.1, atomic — nothing merged) to a distinct
# failure. Either way: rc 0 = merged, non-zero = real failure.
merge_rc=0
forge_pr_merge "$pr_num" "$vetted_head" || merge_rc=$?
if [ "$merge_rc" -eq 0 ]; then
    exit 0
fi

# forge_pr_merge already printed the backend-specific error. Add the himmel
# recovery guidance (forge-agnostic) and propagate the failure.
cat >&2 <<'EOF'
pr-merge: merge refused. Do NOT retry via another command path — the auto-mode
classifier flags that as evasion. On GitHub this is usually a branch-protection
/ approval gate: set GH_ADMIN_MERGE_OK=1 in the LAUNCHING shell only if real
branch protection is in play, else defer the merge to the operator. On Bitbucket
a conflict (CLI exit 2) means rebase-and-retry. See
docs/internals/stuck-playbook.md § "a PR merge was blocked".
EOF
exit "$merge_rc"
