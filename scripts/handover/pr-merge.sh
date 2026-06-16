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
#
# Environment overrides:
#   GH_CMD                   Default `gh`. Tests can set to `echo`.
#   GH_ADMIN_MERGE_OK        When `1`, authorizes the `--admin` fallback on a
#                            non-cosmetic plain-merge failure. Default off.
#   PR_MERGE_POLL_ATTEMPTS   Mergeability-poll attempts (HIMMEL-179). Default 5.
#   PR_MERGE_POLL_INTERVAL   Seconds slept between poll attempts. Default 3.
set -euo pipefail

GH_CMD="${GH_CMD:-gh}"
GH_ADMIN_MERGE_OK="${GH_ADMIN_MERGE_OK:-0}"
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
if ! command -v "${GH_CMD%% *}" >/dev/null 2>&1; then
    echo "ERR pr-merge: ${GH_CMD%% *} not on PATH" >&2
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

# Locate the PR for this branch. Distinguish a genuine `gh pr list` failure
# (auth expired / network / GitHub 5xx) from "no PR exists": the former must
# NOT be reported as a clean no-op or an overnight run silently fails to ship
# (HIMMEL-224 CR — silent-failure-hunter).
pr_num=""
if ! pr_num=$($GH_CMD pr list --head "$current_branch" --state open --json number --jq '.[0].number // ""'); then
    echo "ERR pr-merge: 'gh pr list' failed for $current_branch (auth/network?). Cannot determine PR state — refusing to report success." >&2
    exit 4
fi
if [ -z "$pr_num" ]; then
    echo "pr-merge: no open PR found for $current_branch — nothing to merge."
    exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY pr-merge: would invoke: $GH_CMD pr merge $pr_num --squash --delete-branch"
    exit 0
fi

# Bounded poll for mergeability to settle before merging (HIMMEL-179 sharp#1).
# This is the SECOND stage of the two-stage UNKNOWN handling. The pre-push
# gate (scripts/hooks/check-pr-mergeable.sh, HIMMEL-136) lets `mergeable:
# UNKNOWN` pass through because GitHub hasn't finished computing mergeability
# in the window right after a push. That pass-through can leave the real
# `gh pr merge` below to fail. Here we wait for `mergeable` to settle:
#   MERGEABLE   -> proceed to merge.
#   CONFLICTING -> fail fast (exit 4); a conflict won't self-resolve.
#   UNKNOWN     -> retry after a short sleep; if attempts exhaust while still
#                  UNKNOWN, fall through to the merge attempt (preserve the
#                  pre-check's pass-through behavior — don't hard-fail).
# `gh pr view` command errors (transient gh/network) skip polling and fall
# through too, rather than crashing. Sleep ONLY between attempts.
attempt=1
while [ "$attempt" -le "$POLL_ATTEMPTS" ]; do
    if ! mergeable=$($GH_CMD pr view "$pr_num" --json mergeable --jq '.mergeable' 2>/dev/null); then
        # gh itself failed (not a status value) — don't crash; let the merge
        # attempt below surface any real problem.
        break
    fi
    case "$mergeable" in
        MERGEABLE)
            break
            ;;
        CONFLICTING)
            echo "ERR pr-merge: PR #$pr_num is CONFLICTING — resolve conflicts before merging. Refusing." >&2
            exit 4
            ;;
        *)
            # UNKNOWN (or empty/unexpected): GitHub may still be computing.
            # Retry after a sleep, but never sleep after the final attempt.
            if [ "$attempt" -lt "$POLL_ATTEMPTS" ]; then
                echo "pr-merge: PR #$pr_num mergeable=${mergeable:-<empty>} (attempt $attempt/$POLL_ATTEMPTS) — waiting ${POLL_INTERVAL}s" >&2
                sleep "$POLL_INTERVAL"
            fi
            ;;
    esac
    attempt=$((attempt + 1))
done

# A held-worktree branch-delete error is cosmetic — the remote PR is merged
# either way. Detect it so both the plain and admin attempts treat it as success.
is_cosmetic_branch_delete() {
    printf '%s' "$1" | grep -qE "failed to run git: fatal: '?main'? is already used by worktree"
}

# Attempt 1: plain squash merge — NO --admin (HIMMEL-224).
if out=$($GH_CMD pr merge "$pr_num" --squash --delete-branch 2>&1); then
    echo "pr-merge: merged PR #$pr_num"
    exit 0
fi
if is_cosmetic_branch_delete "$out"; then
    echo "pr-merge: merged PR #$pr_num (local branch-delete cosmetic-fail, ignored)"
    exit 0
fi

# Plain merge failed for a real reason. Escalate to --admin ONLY if explicitly
# authorized; otherwise surface the error and stop (never silently escalate).
if [ "$GH_ADMIN_MERGE_OK" != "1" ]; then
    echo "ERR pr-merge: plain squash merge of PR #$pr_num failed:" >&2
    printf '%s\n' "$out" >&2
    cat >&2 <<'EOF'
pr-merge: this is likely a branch-protection / approval gate. Do NOT retry via
another path (the auto-mode classifier flags that as evasion). Either set
GH_ADMIN_MERGE_OK=1 in the LAUNCHING shell (only if real branch protection is in
play), or defer the merge to the operator as a one-action handover. See
docs/internals/stuck-playbook.md § "a PR merge was blocked".
EOF
    exit 4
fi

# Attempt 2: authorized --admin fallback.
echo "pr-merge: plain merge failed; GH_ADMIN_MERGE_OK=1 — retrying with --admin" >&2
if out=$($GH_CMD pr merge "$pr_num" --squash --admin --delete-branch 2>&1); then
    echo "pr-merge: merged PR #$pr_num (--admin fallback)"
    exit 0
fi
if is_cosmetic_branch_delete "$out"; then
    echo "pr-merge: merged PR #$pr_num (--admin fallback; local branch-delete cosmetic-fail, ignored)"
    exit 0
fi
echo "ERR pr-merge: gh pr merge --admin failed:" >&2
printf '%s\n' "$out" >&2
exit 4
