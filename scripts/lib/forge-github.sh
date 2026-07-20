#!/usr/bin/env bash
# forge-github.sh — GitHub backend for the forge seam (HIMMEL-326).
#
# Today's `gh` logic, MOVED not rewritten (the lift-and-shift regression guard,
# spec §7). Every verb shells out to `${GH_CMD:-gh}` so the existing GH_CMD test
# seam keeps working. Sourced by forge.sh; not run directly.

_gh() { "${GH_CMD:-gh}" "$@"; }

gh_forge_auth_status() {
    _gh auth status >/dev/null 2>&1
}

gh_forge_repo_nwo() {
    _gh repo view --json nameWithOwner -q .nameWithOwner
}

gh_forge_default_branch() {
    _gh repo view --json defaultBranchRef -q .defaultBranchRef.name
}

gh_forge_user_slug() {
    _gh api user -q .login
}

# echo the open PR number for a branch, or "" if none.
gh_forge_pr_find_open() {
    local branch="$1"
    _gh pr list --head "$branch" --state open --json number --jq '.[0].number // ""'
}

# create a PR; echo its URL. args: TITLE BODY BASE HEAD
gh_forge_pr_create() {
    local title="$1" body="$2" base="$3" head="$4"
    _gh pr create --title "$title" --body "$body" --base "$base" --head "$head"
}

# update an existing PR body. args: NUMBER TITLE BODY. TITLE is unused here —
# `gh pr edit --body` doesn't require it; the arg exists for seam parity with
# the Bitbucket backend, whose PUT endpoint requires a title.
gh_forge_pr_set_body() {
    local number="$1" body="$3"
    _gh pr edit "$number" --body "$body"
}

# echo MERGEABLE | CONFLICTING | UNKNOWN, or empty when no PR exists. args: REF
# (a branch name or PR number — whatever `gh pr view` accepts).
#
# HIMMEL-1232: computes the merge conflict LOCALLY with `git merge-tree
# --write-tree` (Git 2.38+) instead of reading GitHub's async `mergeable` field,
# which is flaky/slow and returns UNKNOWN right after a push (HIMMEL-136/179).
# Only the PR's base+head refs are read from GitHub, via a SYNCHRONOUS `gh pr
# view` (baseRefName/headRefOid are stored fields, not async-computed); the merge
# itself is then computed offline:
#     merge-tree exit 0  -> clean     -> MERGEABLE
#     merge-tree exit 1  -> conflicts -> CONFLICTING
#     anything else      -> git error -> UNKNOWN
# Every missing precondition (no PR, gh error, unresolvable base/head, git < 2.38)
# degrades to empty/UNKNOWN so callers FAIL OPEN — a tooling gap must never
# hard-block a push or a merge.
#
# A missing ref makes `git merge-tree` ALSO exit 1 (indistinguishable from a real
# conflict), so base and head are `git rev-parse --verify`'d first; merge-tree
# runs only when both are confirmed present, making exit 1 mean "genuine
# conflict" unambiguously.
gh_forge_pr_mergeable() {
    local ref="$1"
    local meta base_name head_oid
    # Synchronous metadata read — NOT the async `mergeable` field. `|| return 0`
    # turns a "no PR" / gh error into empty output (callers treat it as "no PR").
    meta=$(_gh pr view "$ref" --json baseRefName,headRefOid \
              --jq '.baseRefName + " " + .headRefOid' 2>/dev/null) || return 0
    [ -z "$meta" ] && return 0
    base_name=${meta%% *}
    head_oid=${meta##* }
    if [ -z "$base_name" ] || [ -z "$head_oid" ] || [ "$base_name" = "$head_oid" ]; then
        echo "UNKNOWN"; return 0
    fi

    # Resolve the base commit locally WITHOUT fetching (the point is an offline,
    # non-hanging check): prefer the remote-tracking ref, fall back to a local
    # branch of the same name. Unresolvable -> fail open.
    local base_commit
    base_commit=$(git rev-parse --verify --quiet "refs/remotes/origin/$base_name^{commit}") \
        || base_commit=$(git rev-parse --verify --quiet "$base_name^{commit}") \
        || { echo "UNKNOWN"; return 0; }

    # The head commit must be present locally (it is this branch's tip after a
    # push). Absent -> fail open rather than guess.
    git rev-parse --verify --quiet "$head_oid^{commit}" >/dev/null \
        || { echo "UNKNOWN"; return 0; }

    # git merge-tree --write-tree (Git 2.38+): 0 clean, 1 conflicts, else error.
    # With both refs verified above, exit 1 unambiguously means a real conflict.
    local rc=0
    git merge-tree --write-tree "$base_commit" "$head_oid" >/dev/null 2>&1 || rc=$?
    case "$rc" in
        0) echo "MERGEABLE" ;;
        1) echo "CONFLICTING" ;;
        *) echo "UNKNOWN" ;;   # git < 2.38 usage error, or merge could not complete
    esac
}

# count merged PRs whose source branch is BRANCH (clean-garden prune signal).
gh_forge_pr_has_merged() {
    local branch="$1"
    _gh pr list --head "$branch" --state merged --json number --jq 'length'
}

# file a CR deferred-issue; echo the issue URL. args: REPO TITLE BODY LABEL.
# This reproduces today's exact `gh issue create` shape (HIMMEL-30) so the
# GitHub deferred-filer path is unchanged behind the seam.
gh_forge_issue_create() {
    local repo="$1" title="$2" body="$3" label="$4"
    _gh issue create --repo "$repo" --title "$title" --body "$body" --label "$label"
}

# Cosmetic held-worktree branch-delete error — the remote PR is merged anyway.
_gh_is_cosmetic_branch_delete() {
    printf '%s' "$1" | grep -qE "failed to run git: fatal: '?main'? is already used by worktree"
}

# squash-merge + delete source branch; plain first, --admin only when
# GH_ADMIN_MERGE_OK=1 (HIMMEL-224). args: NUMBER VETTED_HEAD_SHA.
# rc 0 = merged (incl. cosmetic branch-delete fail); rc 4 = real failure
# (incl. a missing vetted head — refused below, never merged unbound).
#
# VETTED_HEAD_SHA closes the HIMMEL-1058 TOCTOU window: the gates certify
# headRefOid at check time, but a push landing between that capture and this
# merge would slip an UNVETTED commit into main. `--match-head-commit` makes
# GitHub reject the merge unless the head still is the SHA we vetted, so the
# race fails loudly instead of merging unreviewed code. The binding is now
# MANDATORY (CodeRabbit #470): an empty head is REFUSED here rather than merged
# unbound. The sole orchestrator caller (pr-merge.sh) already exits 7 on an
# unreadable head, so this only ever fires as a backstop against a future
# caller that forgets to pass the vetted SHA.
gh_forge_pr_merge() {
    local number="$1" head="${2:-}"
    local out
    if [ -z "$head" ]; then
        echo "ERR forge(github): refusing to merge PR #$number without a vetted head SHA — the HIMMEL-1058 head binding is mandatory (CodeRabbit #470)." >&2
        return 4
    fi
    local -a match=(--match-head-commit "$head")
    if out=$(_gh pr merge "$number" --squash --delete-branch "${match[@]+"${match[@]}"}" 2>&1); then
        echo "forge(github): merged PR #$number${head:+ (bound to vetted head $head)}"
        return 0
    fi
    if _gh_is_cosmetic_branch_delete "$out"; then
        echo "forge(github): merged PR #$number (local branch-delete cosmetic-fail, ignored)"
        return 0
    fi
    if [ "${GH_ADMIN_MERGE_OK:-0}" != "1" ]; then
        echo "ERR forge(github): plain squash merge of PR #$number failed:" >&2
        printf '%s\n' "$out" >&2
        return 4
    fi
    echo "forge(github): plain merge failed; GH_ADMIN_MERGE_OK=1 — retrying with --admin" >&2
    # --admin bypasses branch protection, NOT the head binding: the retry stays
    # pinned to the vetted SHA (an admin merge of an unvetted head is exactly the
    # HIMMEL-1058 risk).
    if out=$(_gh pr merge "$number" --squash --admin --delete-branch "${match[@]+"${match[@]}"}" 2>&1); then
        echo "forge(github): merged PR #$number (--admin fallback${head:+, bound to vetted head $head})"
        return 0
    fi
    if _gh_is_cosmetic_branch_delete "$out"; then
        echo "forge(github): merged PR #$number (--admin fallback; cosmetic-fail, ignored)"
        return 0
    fi
    echo "ERR forge(github): gh pr merge --admin failed:" >&2
    printf '%s\n' "$out" >&2
    return 4
}
