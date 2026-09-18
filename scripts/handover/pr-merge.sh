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
#
# Jira auto-transition is opt-in per merge (HIMMEL-3143; --jira-transition
# above), not the old unconditional default. It used to fire on every merge
# and closed HIMMEL-2975 while sibling work was still outstanding — one of
# those closes had no open PR, branch or commit referencing the ticket at
# all, because the owed work lived only in a design doc's task list. An
# "only transition when no other PR references this ticket" heuristic
# cannot catch that case, so it cannot be the primary fix, only an optional
# secondary guard on top of opt-in. See jira_auto_transition_on_merge below.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Forge-dispatch seam: forge_pr_find_open / forge_pr_mergeable / forge_pr_merge
# route to the github or bitbucket backend per the repo's origin (HIMMEL-326).
# The admin-fallback + cosmetic-branch-delete handling lives in the github
# backend (gh_forge_pr_merge); this script orchestrates find → check → merge.
# shellcheck source=../lib/forge.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/forge.sh"

# GH_ADMIN_MERGE_OK is consumed by the github backend (gh_forge_pr_merge) — it
# reads the env var directly, so this script no longer normalizes it.
DRY_RUN=0
JIRA_TRANSITION_OPT_IN=0

usage() {
    cat <<'EOF'
Usage: pr-merge.sh [--dry-run] [--jira-transition]

Squash-merges the PR associated with the current handover branch
(--squash --delete-branch). Repo settings forbid merge-commits, so
squash is the only allowed mode. Defaults to a plain merge; escalates to
--admin only on a non-cosmetic failure when GH_ADMIN_MERGE_OK=1.

Refuses (rc=3) if HEAD is not on a `handover/*` branch.

Optional:
  --dry-run          Print intended gh call; don't invoke.
  --jira-transition  Opt IN to auto-transitioning the ticket on this merge
                     (HIMMEL-3143). Default: report what would have happened,
                     do not touch Jira. See jira_auto_transition_on_merge
                     below for why this is opt-in rather than an open-PR
                     heuristic.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)  DRY_RUN=1; shift ;;
        --jira-transition) JIRA_TRANSITION_OPT_IN=1; shift ;;
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

# HIMMEL-1346 — clear this branch's pending CR marker through the sanctioned
# chokepoint (scripts/cr/clear-cr-marker.sh, never a raw `rm`) so the merge does
# not leave one behind: the marker lives in the SHARED git-common-dir and
# check-cr-marker-on-pr-create.sh resolves the branch from the session cwd, so a
# marker outliving its merged branch HARD-BLOCKS `gh pr create` on unrelated
# branches.
#
# Ordering. AFTER the merge is impossible: deleteBranchOnMerge removes the
# remote head branch, and the marker's endpoint binding then refuses (exit 16)
# for every merged branch. So it runs before — and before the CR/CI gates
# below, not between them and the merge (codex-1): the chokepoint runs its own
# check-ci watch, which can take minutes, and inserting that between this
# script's gates and its merge would widen exactly the window HIMMEL-1058's
# head binding narrows. Nothing here depends on those gates: clear-cr-marker
# re-derives its whole verdict (ledger + PR head + check-ci) itself.
#
# Best-effort: a marker that will not clear is reported, never a merge failure.
# No marker => the chokepoint is not invoked at all (it would otherwise pay for
# a check-ci watch to no-op).
_cr_marker_common=$(git rev-parse --git-common-dir 2>/dev/null || true)
_cr_clearer="$SCRIPT_DIR/../cr/clear-cr-marker.sh"
if [ -n "$_cr_marker_common" ] && [ -f "$_cr_marker_common/cr-pending/$current_branch" ]; then
    if [ ! -f "$_cr_clearer" ]; then
        # Say so (codex-2): a pending marker left behind silently is the exact
        # failure HIMMEL-1346 is about.
        echo "pr-merge: clear-cr-marker.sh not found at $_cr_clearer — the CR marker for '$current_branch' stays pending (HIMMEL-1346). Merging anyway." >&2
    else
        _cr_clear_rc=0
        bash "$_cr_clearer" "$current_branch" || _cr_clear_rc=$?
        if [ "$_cr_clear_rc" -ne 0 ]; then
            echo "pr-merge: could not clear the CR marker for '$current_branch' (clear-cr-marker exit $_cr_clear_rc) — it stays pending and will block \`gh pr create\` for branches resolved from a session cwd in this checkout (HIMMEL-1346). Merging anyway." >&2
        fi
    fi
fi

# HIMMEL-936: CR merge gate on the same predicate as the PreToolUse hook, so
# machines without the plugin hook still get the gate on this path. Placed
# before the mergeability check so a CR-blocked merge fails fast (exit 5).
# GitHub-only: cr_merge_gate resolves via gh; the bitbucket forge skips it.
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
    # mergeability check; a CI-blocked merge fails fast (exit 6). pr-merge passes
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

# Deterministic mergeability check before merging (HIMMEL-1232) — GitHub only.
# forge_pr_mergeable now computes the conflict LOCALLY via `git merge-tree`
# (github backend), so there is no async GitHub `mergeable` field to wait on: the
# old bounded poll (HIMMEL-179, 5x3s) is gone — a single read decides.
#   CONFLICTING     -> fail fast (exit 4); a conflict won't self-resolve.
#   MERGEABLE       -> proceed to merge.
#   UNKNOWN / empty -> a tooling gap (git < 2.38, refs unavailable, no PR view).
#                      Fail OPEN and proceed — the merge still fails loudly if it
#                      truly conflicts, and hard-blocking on a tool gap is worse.
# Bitbucket Cloud has no pre-merge mergeable signal (forge_pr_mergeable returns
# UNKNOWN), so this is skipped there — the 400 at merge time is the only conflict
# signal (spec §5.1), surfaced by forge_pr_merge.
if [ "$forge" = "github" ]; then
    mergeable=$(forge_pr_mergeable "$pr_num")
    if [ "$mergeable" = "CONFLICTING" ]; then
        echo "ERR pr-merge: PR #$pr_num is CONFLICTING — resolve conflicts before merging. Refusing." >&2
        exit 4
    fi
fi

# HIMMEL-374: best-effort Jira auto-transition on merge — same structural fix
# as merge-on-green.sh's jira_auto_transition_on_merge (duplicated rather than
# shared: the two scripts already have no common helper file, and this is a
# handful of lines). Never fails the merge: every step degrades to a skip/
# failed message on stderr, never a non-zero return. GitHub-only, matching
# this script's other title/gh-dependent steps above — reads the ticket key
# from the PR title's `[PROJ-N]` tag and the target status from
# reconcile-config.json, so this and reconcile-backlog.mjs share one source
# of truth for "what status does a closed ticket move to" per project.
jira_auto_transition_on_merge() {
    [ "$forge" = "github" ] || return 0
    local pr="$1" title key project config_path target_status comment_tmp transition_out transition_rc=0
    local jira_common jira_repo_root issue_type_json issue_type comment_rc=0

    title=$("${GH_CMD:-gh}" pr view "$pr" --json title -q .title 2>/dev/null) || return 0
    key=$(printf '%s' "$title" | grep -oE '\[[A-Za-z]+-[0-9]+\]' | head -1 | tr -d '[]') || true
    [ -n "$key" ] || return 0

    # Resolve the PRIMARY checkout, not this process's own (possibly-worktree)
    # toplevel: scripts/jira/dist/ is an untracked build artifact that only
    # exists there (project convention — see scripts/jira/CLAUDE.md).
    jira_common=$(git rev-parse --git-common-dir 2>/dev/null) || return 0
    jira_repo_root=$(cd "$(dirname "$jira_common")" 2>/dev/null && pwd) || return 0

    [ -f "$jira_repo_root/scripts/jira/dist/index.js" ] || {
        echo "pr-merge: PR #$pr merged but Jira CLI is not built — not auto-transitioning $key." >&2
        return 0
    }

    project="${key%-*}"
    config_path="$jira_repo_root/scripts/jira/reconcile-config.json"
    [ -f "$config_path" ] || return 0
    target_status=$(node -e '
        try {
            const c = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
            const t = c[process.argv[2]] && c[process.argv[2]].targetStatus;
            if (t) process.stdout.write(t);
        } catch {}
    ' "$config_path" "$project" 2>/dev/null)
    [ -n "$target_status" ] || return 0

    # Never touch Epic/Story (standing project invariant — reconcile-lib.mjs's
    # own classifyTicket enforces this for the batch reconciler; this
    # merge-time hook has no classifyTicket call in its path, so it must
    # check independently). Fails safe: an unreadable/undetermined type
    # skips the transition rather than risking one on an Epic or Story.
    issue_type_json=$(cd "$jira_repo_root" && node scripts/jira/dist/index.js get "$key" --json 2>/dev/null)
    issue_type=$(printf '%s' "$issue_type_json" | node -e '
        try {
            const d = JSON.parse(require("fs").readFileSync(0, "utf8"));
            const t = d.fields && d.fields.issuetype && d.fields.issuetype.name;
            if (t) process.stdout.write(t);
        } catch {}
    ' 2>/dev/null)
    case "$issue_type" in
        Epic|Story)
            echo "pr-merge: PR #$pr merged but $key is a $issue_type — never auto-transitioning." >&2
            return 0
            ;;
        "")
            echo "pr-merge: PR #$pr merged but $key's issue type could not be verified — not auto-transitioning." >&2
            return 0
            ;;
    esac

    # HIMMEL-3143: opt-in per merge, not a heuristic (see the file header).
    # Report what WOULD have happened and stop — no comment, no transition.
    if [ "$JIRA_TRANSITION_OPT_IN" != "1" ]; then
        echo "pr-merge: PR #$pr merged; would auto-transition $key to '$target_status' (pass --jira-transition to do it — opt-in per HIMMEL-3143)." >&2
        return 0
    fi

    comment_tmp=$(mktemp "${TMPDIR:-/tmp}/pr-merge-jira-comment.XXXXXX") || return 0
    printf 'PR #%s merged. scripts/handover/pr-merge.sh is attempting to auto-transition this ticket to '"'"'%s'"'"'.\n' \
        "$pr" "$target_status" >"$comment_tmp"
    ( cd "$jira_repo_root" && node scripts/jira/dist/index.js comment "$key" --comment-file "$comment_tmp" ) \
        >/dev/null 2>&1 || comment_rc=$?
    rm -f "$comment_tmp"
    # A failed comment means no evidence breadcrumb would exist on the
    # ticket — skip the transition rather than close it silently.
    if [ "$comment_rc" -ne 0 ]; then
        echo "pr-merge: PR #$pr merged but the Jira evidence comment on $key failed (rc=$comment_rc) — not auto-transitioning." >&2
        return 0
    fi

    transition_out=$(cd "$jira_repo_root" && node scripts/jira/dist/index.js transition "$key" "$target_status" 2>&1) \
        || transition_rc=$?
    if [ "$transition_rc" -ne 0 ]; then
        echo "pr-merge: PR #$pr merged but Jira transition of $key to '$target_status' failed (rc=$transition_rc): ${transition_out//$'\n'/ }" >&2
    fi
    return 0
}

# Squash-merge via the forge seam. The github backend does a PLAIN squash first
# and escalates to --admin only when GH_ADMIN_MERGE_OK=1 (HIMMEL-224); it also
# absorbs the cosmetic worktree-held branch-delete error. The bitbucket backend
# maps a 400 merge-conflict (spec §5.1, atomic — nothing merged) to a distinct
# failure. Either way: rc 0 = merged, non-zero = real failure.
merge_rc=0
forge_pr_merge "$pr_num" "$vetted_head" || merge_rc=$?
if [ "$merge_rc" -eq 0 ]; then
    jira_auto_transition_on_merge "$pr_num"
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
