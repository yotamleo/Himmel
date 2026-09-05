#!/usr/bin/env bash
# forge-github.sh — GitHub backend for the forge seam (HIMMEL-326).
#
# Today's `gh` logic, MOVED not rewritten (the lift-and-shift regression guard,
# spec §7). Every verb shells out to `${GH_CMD:-gh}` so the existing GH_CMD test
# seam keeps working. Sourced by forge.sh; not run directly.

_gh() { "${GH_CMD:-gh}" "$@"; }

# ── CodeRabbit trigger at the seam (HIMMEL-1924) ─────────────────────────────
_FORGE_GH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/cr-trigger-ledger.sh
# shellcheck disable=SC1091  # sourced at runtime; checked standalone by pre-commit
. "$_FORGE_GH_LIB_DIR/cr-trigger-ledger.sh"
# shellcheck source=scripts/lib/cr-available.sh
# shellcheck disable=SC1091
. "$_FORGE_GH_LIB_DIR/cr-available.sh"

# cr_trigger_post_review requires its caller to define warn(). The two hooks
# define their own before sourcing the ledger; no forge consumer does, so
# supply one — but only when the caller hasn't, so a consumer's warn still wins.
if ! declare -f warn >/dev/null 2>&1; then
    warn() { echo "forge(github): $*" >&2; }
fi

# _gh_trigger_cr <pr-ref> — post `@coderabbitai review` at most once per head
# SHA for a PR this process just opened or advanced.
#
# WHY HERE (HIMMEL-1924): CodeRabbit's `auto_review` is OFF (.coderabbit.yaml,
# HIMMEL-1252), so the App reviews only on an explicit trigger comment.
# HIMMEL-1906 posts that comment from two PostToolUse hooks matched against the
# BASH COMMAND STRING the agent ran (`gh pr create`, `git push`). A PR opened or
# advanced from INSIDE a script (graph-publish.sh, pr-open.sh, anything on this
# seam) matches neither pattern, so no trigger was posted and the PR sat on
# "Review skipped: automatic reviews are disabled" until a human commented
# (PR #1725). This is the same trigger keyed on the REAL event — a PR head
# advanced — instead of on what the agent typed.
#
# The hooks are KEPT, not replaced: they still cover the direct `gh pr create` /
# `git push` invocations that never reach this lib. They and this seam share ONE
# ledger keyed by (repo, PR, head SHA), so whichever fires first records the head
# and the other becomes a no-op — a double trigger is impossible by construction,
# not by convention.
#
# Bitbucket has no counterpart on purpose: CodeRabbit is GitHub-only, so
# forge-bitbucket.sh stays untouched and the trigger is a structural no-op there
# rather than a runtime check.
#
# Never blocks: every failure path returns 0. The create/edit already succeeded
# by the time this runs, and check-ci's skipped/absent arms remain the backstop
# that refuses green until a genuine review lands at head.
_gh_trigger_cr() {
    # The repo's ONE armed-CodeRabbit predicate (scripts/lib/cr-available.sh):
    # honours CR_PROFILE=none and stays silent on a clone with no CodeRabbit App.
    # This seam runs inside SHIPPED scripts an adopter executes, so an unarmed
    # repo must not collect stray @coderabbitai comments on every PR it opens.
    cr_app_configured || return 0

    local meta num sha url repo
    meta=$(_gh pr view "$1" --json number,headRefOid,url \
              --jq '"\(.number) \(.headRefOid) \(.url)"' 2>/dev/null) || return 0
    num=${meta%% *}; meta=${meta#* }
    sha=${meta%% *}; url=${meta#* }
    if [ -z "$num" ] || [ -z "$sha" ] || [ -z "$url" ] || [ "$url" = "$sha" ]; then
        warn "WARNING: could not resolve the PR number/head/url for '$1' — post '@coderabbitai review' manually if this PR needs a review"
        return 0
    fi

    repo=${url#*github.com/}
    repo=${repo%%/pull/*}
    if [ -z "$repo" ] || [ "$repo" = "$url" ]; then
        warn "WARNING: could not parse owner/repo from '$url'; trigger the review manually"
        return 0
    fi

    # scan_existing=0: the ledger's per-head key already owns the dedup, and the
    # per-PR comment scan is repo-wide — it cannot tell which head an old comment
    # targeted, so it would suppress a legitimate new-head trigger (the exact
    # HIMMEL-1906 bug; see scripts/lib/cr-trigger-ledger.sh).
    cr_trigger_post_review "$sha" "$num" "$repo" 0
    return 0
}

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
    _gh pr create --title "$title" --body "$body" --base "$base" --head "$head" || return $?
    # HIMMEL-1924: the PR exists now — trigger CodeRabbit here, so a PR opened
    # from inside a script gets a review without the agent having typed
    # `gh pr create` (which is all the HIMMEL-1906 hooks can see).
    _gh_trigger_cr "$head"
}

# update an existing PR body. args: NUMBER TITLE BODY. TITLE is unused here —
# `gh pr edit --body` doesn't require it; the arg exists for seam parity with
# the Bitbucket backend, whose PUT endpoint requires a title.
gh_forge_pr_set_body() {
    local number="$1" body="$3"
    _gh pr edit "$number" --body "$body" || return $?
    # HIMMEL-1924: this is the seam's "advance an EXISTING PR" arm — every
    # script that pushes then refreshes the body (graph-publish.sh,
    # pr-open.sh) lands here with a head the ledger has not seen. A body
    # refresh at an ALREADY-triggered head is a ledger no-op, so keying the
    # trigger on the head SHA (not on this call) keeps it exactly-once.
    _gh_trigger_cr "$number"
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
