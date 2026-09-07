#!/usr/bin/env bash
# Shared ledger + post-once helper for CodeRabbit trigger hooks (HIMMEL-1906).
#
# CodeRabbit's `auto_review` is OFF (.coderabbit.yaml, HIMMEL-1252), so the
# App reviews a PR ONLY on an explicit `@coderabbitai review` comment. Two
# PostToolUse hooks post that comment structurally:
#   - trigger-cr-on-pr-create.sh  fires on `gh pr create`
#   - trigger-cr-on-push.sh       fires on `git push`
# Both match the BASH COMMAND STRING, so a PR opened or advanced from INSIDE
# a script matches neither (HIMMEL-1924). scripts/lib/forge-github.sh is the
# third caller: it triggers from the create/edit seam every such script
# already routes through. All three obey the SAME invariant: trigger at most
# ONCE per (repo, PR, head SHA) — so the seam and the hooks can never
# double-post for one head. This file is the shared, load-bearing dedup —
# sourced by all three, never run directly.
#
# `gh` is invoked as `${GH_CMD:-gh}` (the forge seam's existing stub hook,
# scripts/lib/forge-github.sh `_gh`) so the forge tests can exercise the post
# path without touching a real PR. The hooks leave GH_CMD unset and get `gh`.
#
# KEY: keyed by repo+PR-number+SHA, not SHA alone. A bare SHA key let
# triggering a review for one PR silently suppress the trigger for a
# DIFFERENT PR that happens to share that head commit — reachable via
# stacked branches, the same commit pushed to two branches, or a branch
# reopened under a new PR number. Both hooks build the key from the SAME
# three fields passed into cr_trigger_post_review, so they still dedup
# against each other for the same (repo, PR, SHA) — the cross-hook no-op a
# compound `git push && gh pr create` relies on is unchanged.
#
# ponytail: check-then-post is NOT atomic — two concurrent hook processes
# (exactly what a compound `git push && gh pr create` fires) can both read
# "not yet triggered" before either records it, so worst case both post.
# Accepted: a duplicate trigger costs one extra CodeRabbit review; a missed
# trigger is caught loudly by the merge gate refusing green. Upgrade path if
# that ever stops holding (e.g. CodeRabbit review credits become the scarce
# resource): a per-key mkdir claim, same primitive as
# scripts/graphify/refresh-graph-map.sh's _promote_lock_acquire.
#
# Ledger location: `$(git rev-parse --git-common-dir)/cr-triggered-heads`
# (a flat, append-only, greppable audit file) — --git-common-dir (not
# --git-dir) so a worktree checkout shares the ledger with its sibling
# worktrees and the main checkout, matching the existing CR-marker
# precedent (check-cr-before-push.sh's `.git/cr-pending/<branch>`,
# HIMMEL-1540). `.git/` is never tracked, so this needs no gitignore entry;
# it survives across sessions and is pruned for free when a merged worktree
# is removed.
#
# Fail-open: any ledger read/write failure (missing git, unwritable .git,
# etc.) must never strand the caller's push/create — a missing/unreadable
# ledger is treated as "not yet triggered" (post proceeds) and a failed
# write after posting only warns.

cr_trigger_ledger_path() {
    # Test-only escape hatch: point the ledger at a throwaway file instead of
    # the real repo's .git/, so the test suite never writes into (or reads
    # stale state from) whatever real checkout happens to run it. Unset in
    # every normal invocation.
    if [ -n "${CR_TRIGGER_LEDGER_PATH:-}" ]; then
        printf '%s\n' "$CR_TRIGGER_LEDGER_PATH"
        return 0
    fi
    local git_dir
    git_dir=$(git rev-parse --git-common-dir 2>/dev/null) || return 1
    printf '%s/cr-triggered-heads\n' "$git_dir"
}

# cr_trigger_ledger_key <repo> <num> <sha> -- the composite key text: "this
# PR at this head", not the SHA alone.
cr_trigger_ledger_key() {
    printf '%s %s %s' "$1" "$2" "$3"
}

# 0 = this (repo, PR, SHA) is already recorded as triggered. 1 = not
# recorded, OR the ledger is unresolvable/unreadable (fail-open — never
# treated as "already triggered", which could permanently suppress a real
# review).
cr_trigger_ledger_has() {
    local path
    path=$(cr_trigger_ledger_path 2>/dev/null) || return 1
    grep -qxF "$(cr_trigger_ledger_key "$1" "$2" "$3")" "$path" 2>/dev/null
}

# cr_trigger_ledger_record <repo> <num> <sha> -- appends the greppable audit
# line after a confirmed post. Best-effort: a write failure only warns (via
# the caller) and never blocks.
cr_trigger_ledger_record() {
    local path
    path=$(cr_trigger_ledger_path 2>/dev/null) || return 1
    printf '%s\n' "$(cr_trigger_ledger_key "$1" "$2" "$3")" >> "$path" 2>/dev/null
}


# ─── foreign-repo guard (HIMMEL-2034) ───────────────────────────────────────
# On 2026-08-22 trigger-cr-on-pr-create.sh posted `@coderabbitai review` on
# JuliusBrussee/caveman#896 — an UPSTREAM PR opened from this machine. The
# hooks parse owner/repo out of whatever PR URL `gh` printed and comment on
# it; they had no notion of "our" repos. That is outward-facing noise on
# someone else's repo, and it summons a reviewer bot they may not run.
#
# himmel's CR gate is OURS (the CodeRabbit App + the hermes/codex panel) and
# means something only where it is armed, so the trigger is now scoped the
# same way: post only on a repo this harness owns the gate for.
#
# The advisory the sanctioned upstream path (a hermes/codex critic over the
# diff) is named in — one string, so both hooks and the forge seam say the
# same thing.
CR_TRIGGER_FOREIGN_ADVISORY='foreign repo — not triggering CodeRabbit; run the hermes/codex critic on the diff instead'

# _cr_trigger_allowlisted <canon-nwo> — rc 0 iff CR_TRIGGER_REPOS names it.
# Its own function so the `local IFS` split stays scoped to the loop and
# cannot leak into the git-calling helpers below. Split on comma AND space,
# so `a/b,c/d` and `a/b, c/d` both work without a trim.
_cr_trigger_allowlisted() {
    local want="$1" entry IFS=', '
    # shellcheck disable=SC2086  # deliberate word-split on the IFS above
    for entry in ${CR_TRIGGER_REPOS:-}; do
        if _cmg_canon_nwo "$entry" && _cmg_nwo_eq "$_CMG_CANON" "$want"; then
            return 0
        fi
    done
    return 1
}

# cr_trigger_repo_armed <owner/repo> — rc 0 iff we may post a CodeRabbit
# trigger comment on that repo. Two ways to be armed:
#   (a) the cwd's clone has CodeRabbit armed (`git config --local
#       himmel.coderabbit true`, the ONE predicate in cr-available.sh) AND the
#       PR's repo IS that clone's origin. A repo we hold the arming signal for
#       is a repo whose CR gate is ours to trigger.
#   (b) the PR's repo is named in CR_TRIGGER_REPOS (comma-separated nwo) — the
#       explicit escape hatch for a fork/upstream the operator does run the
#       App on, and the test seam.
# Anything else — an upstream PR, a contribution to someone's fork, a repo
# whose arming we cannot see — is rc 1. Fail-CLOSED on its own errors
# (unparseable origin, libs unloadable): the cost of a missed trigger is a
# merge gate that refuses green until someone comments, which is loud; the
# cost of a wrong post is a comment on a stranger's PR, which is not ours to
# make.
cr_trigger_repo_armed() {
    local repo="${1:-}" repo_canon
    [ -n "$repo" ] || return 1

    # Lazily sourced: this runs only on the trigger path (a real PR create or
    # push), so the hooks pay the `$(cd … && pwd)` fork only when a PR is
    # actually in play — never on the PostToolUse fast path.
    if ! declare -f _cmg_canon_nwo >/dev/null 2>&1 || ! declare -f cr_app_configured >/dev/null 2>&1; then
        local _ctl_dir
        _ctl_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || return 1
        # shellcheck source=scripts/lib/nwo.sh
        # shellcheck disable=SC1091
        . "$_ctl_dir/nwo.sh" 2>/dev/null || return 1
        # shellcheck source=scripts/lib/cr-available.sh
        # shellcheck disable=SC1091
        . "$_ctl_dir/cr-available.sh" 2>/dev/null || return 1
    fi

    _cmg_canon_nwo "$repo" || return 1
    repo_canon="$_CMG_CANON"

    # (b) first — it costs no git call.
    _cr_trigger_allowlisted "$repo_canon" && return 0

    # (a) armed clone + the PR is on that clone's origin. Both conditions are
    # required: arming alone would let `gh pr create --repo other/thing` run
    # from inside this checkout post on a foreign repo.
    # shellcheck disable=SC2119  # no-arg call means "this checkout" (the function defaults $1 to $PWD)
    cr_app_configured || return 1
    _cmg_canon_nwo "$(_cmg_local_nwo || true)" || return 1
    _cmg_nwo_eq "$_CMG_CANON" "$repo_canon"
}

# cr_trigger_post_review <sha> <num> <repo_path> <scan_existing 0|1>
#
# The ledger is checked FIRST — it is what prevents a double-post in the
# common case, including across the two different hooks. `scan_existing`
# additionally scans the PR's comments for a pre-existing
# `@coderabbitai (full )?review` (catches a trigger posted by a human or by
# something outside our ledger entirely). That scan is repo-wide, NOT
# per-head — it cannot tell which head an old comment targeted — so it must
# never be the thing that BLOCKS a legitimate new-head trigger. Callers pass
# scan_existing=1 only where a stale match is actually plausible (PR create,
# where a reused/reopened PR number can carry old comments); the push path
# passes 0, because a global scan there would reintroduce exactly the
# per-PR-not-per-SHA bug this ledger exists to fix.
#
# Requires the caller to define `warn()` before calling.
cr_trigger_post_review() {
    local sha="$1" num="$2" repo_path="$3" scan_existing="$4" existing

    # HIMMEL-2034: never comment on a repo whose CR gate is not ours. Checked
    # HERE, in the one function all three callers (both PostToolUse hooks and
    # the forge seam) route their post through, so no caller can forget it.
    if ! cr_trigger_repo_armed "$repo_path"; then
        warn "$repo_path: $CR_TRIGGER_FOREIGN_ADVISORY"
        return 0
    fi

    if cr_trigger_ledger_has "$repo_path" "$num" "$sha"; then
        warn "already triggered CodeRabbit for head ${sha} on PR #$num ($repo_path) — no-op"
        return 0
    fi

    if [ "$scan_existing" = "1" ]; then
        existing=$("${GH_CMD:-gh}" api "repos/$repo_path/issues/$num/comments" --paginate --jq '.[].body' 2>/dev/null || true)
        if printf '%s\n' "$existing" | grep -qiE '@coderabbitai[[:space:]]+(full[[:space:]]+)?review'; then
            # Deliberately do NOT record the head. The scan is repo-wide and
            # cannot tell which head an old comment targeted, so recording here
            # would let a STALE match (a reused/reopened PR number carrying an
            # old trigger) mark this head permanently triggered — the ledger
            # would then no-op every later push event for the same head, and no
            # review would ever land. That contradicts this function's own
            # invariant above: the scan must never BLOCK a legitimate new-head
            # trigger. Skipping the record keeps the failure in the CHEAP
            # direction — a later push may post a duplicate (one extra review)
            # instead of suppressing the review entirely (merge gate refuses
            # green with no way to re-trigger).
            warn "found an existing @coderabbitai trigger comment on PR #$num ($repo_path) — not posting for head ${sha}, and NOT recording it (the scan is repo-wide, so this match may predate this head; a later push may re-trigger)"
            return 0
        fi
    fi

    if "${GH_CMD:-gh}" pr comment "$num" --repo "$repo_path" --body "@coderabbitai review" >/dev/null 2>&1; then
        cr_trigger_ledger_record "$repo_path" "$num" "$sha" \
            || warn "WARNING: posted the trigger but could not record head ${sha} in the ledger — a later event may re-post it"
        echo "posted @coderabbitai review on PR #$num ($repo_path) for head ${sha}" >&2
    else
        warn "WARNING: failed to post @coderabbitai review on PR #$num — post it manually; the merge gate refuses green until a genuine review lands at head"
    fi
    return 0
}
