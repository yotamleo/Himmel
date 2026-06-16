#!/usr/bin/env bash
# clean-garden — combined worktree prune + create.
#
# Usage:
#   ./scripts/clean-garden.sh [branch-name] [flags]
#
# Prune phase: removes any non-primary worktree whose branch has a merged PR
# (preferred signal: `gh pr list --state merged`) or is marked [gone] in
# `git branch -v` (fallback when gh unavailable).
#
# Create phase: when branch-name supplied, delegates to scripts/_new-worktree.sh
# after the prune.
#
# Safety:
#   - Never prunes the primary worktree.
#   - Never prunes a worktree with uncommitted changes; warns and skips.
#   - --dry-run shows the plan without touching anything.
#
# Flags:
#   --prune-only         Skip the create phase even if branch-name given.
#   --no-prune           Skip the prune phase; just create.
#   --no-install         Forwarded to _new-worktree.sh.
#   --dry-run            Show what would happen, do nothing.
#   --verbose, -v        Stream subprocess output.
#   -h, --help           Print usage.
set -euo pipefail

# shellcheck disable=SC2016  # literal text, no expansion intended
USAGE_TEXT='Usage: clean-garden.sh [branch-name] [flags]

  branch-name           Optional. type/slug (feat/foo, chore/bar, ...).
                        When supplied, creates the worktree after pruning.

Flags:
  --prune-only          Prune only; skip create even if branch-name given.
  --no-prune            Skip prune; only create.
  --no-install          Forward to _new-worktree.sh (skip jira install).
  --dry-run             Show plan; do nothing.
  --verbose, -v         Stream subprocess output.
  -h, --help            This message.

Note: this command never uses `git worktree remove --force`. For force
removal (e.g., orphaned admin record, stuck lock), run
`git worktree remove --force <path>` manually.'

usage_err() {
    printf '%s\n' "$USAGE_TEXT" >&2
    exit 2
}
print_help() {
    printf '%s\n' "$USAGE_TEXT"
    exit 0
}

BRANCH=""
PRUNE_ONLY=0
NO_PRUNE=0
NO_INSTALL=0
DRY_RUN=0
VERBOSE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --prune-only) PRUNE_ONLY=1; shift ;;
        --no-prune)   NO_PRUNE=1; shift ;;
        --no-install) NO_INSTALL=1; shift ;;
        --dry-run)    DRY_RUN=1; shift ;;
        --verbose|-v) VERBOSE=1; shift ;;
        -h|--help)    print_help ;;
        -*)           echo "Unknown flag: $1" >&2; usage_err ;;
        *)
            if [ -n "$BRANCH" ]; then
                echo "ERR clean-garden: multiple positional args ('$BRANCH', '$1')" >&2
                usage_err
            fi
            BRANCH="$1"
            shift
            ;;
    esac
done

if [ "$NO_PRUNE" -eq 1 ] && [ "$PRUNE_ONLY" -eq 1 ]; then
    echo "ERR clean-garden: --no-prune and --prune-only are mutually exclusive" >&2
    exit 1
fi
if [ "$NO_PRUNE" -eq 1 ] && [ -z "$BRANCH" ]; then
    echo "ERR clean-garden: --no-prune requires a branch-name to create" >&2
    exit 1
fi

COMMON_DIR=$(git rev-parse --git-common-dir 2>/dev/null) || {
    echo "ERR clean-garden: not in a git repo" >&2; exit 1
}
PRIMARY_WORKTREE=$(cd "$(dirname "$COMMON_DIR")" && pwd)

log() {
    if [ "$VERBOSE" -eq 1 ]; then
        echo "$@"
    fi
}

# Detect PR-merge-detection mode once. Also pin the gh repo scope to the
# primary worktree's nameWithOwner so a checkout with multiple remotes (or a
# fork) cannot mis-match a merged PR on an unrelated upstream.
HAVE_GH=0
GH_REPO=""
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    HAVE_GH=1
    GH_REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
    if [ -n "$GH_REPO" ]; then
        log "clean-garden: gh CLI available — using merged-PR signal (repo: $GH_REPO)"
    else
        log "clean-garden: gh CLI available but repo view failed — gh queries will run unscoped"
    fi
else
    log "clean-garden: gh CLI unavailable — falling back to [gone] tracking"
fi

# Return 0 if the branch has a merged PR (or is [gone] in fallback mode).
# Returns 1 (do-not-prune) on any error so transient failures are safe.
is_branch_mergeable_for_prune() {
    local branch="$1"
    if [ "$HAVE_GH" -eq 1 ]; then
        local count
        local -a gh_args=(pr list --head "$branch" --state merged --json number --jq 'length')
        [ -n "$GH_REPO" ] && gh_args=(--repo "$GH_REPO" "${gh_args[@]}")
        if ! count=$(gh "${gh_args[@]}" 2>/dev/null); then
            echo "WARN clean-garden: gh PR query failed for $branch — treating as not-mergeable (worktree kept)" >&2
            return 1
        fi
        # The test exit code is intentionally the function's return value.
        [ "${count:-0}" -gt 0 ]
        return
    fi
    # Fallback: parse `git branch -v` for [gone]. Assumes the worktree branch
    # also exists in the primary repo's branch list — true for branches
    # created via scripts/_new-worktree.sh (always created from primary).
    git -C "$PRIMARY_WORKTREE" branch -v 2>/dev/null \
        | sed 's/^[+* ]//' \
        | awk -v b="$branch" '$1 == b && /\[gone\]/ { found=1 } END { exit !found }'
}

# Read worktree list into parallel arrays.
WT_PATHS=()
WT_BRANCHES=()
WT_LOCKED=()
current_path=""
current_branch=""
current_locked=0
flush_record() {
    if [ -n "$current_path" ]; then
        WT_PATHS+=("$current_path")
        WT_BRANCHES+=("$current_branch")
        WT_LOCKED+=("$current_locked")
        current_path=""
        current_branch=""
        current_locked=0
    fi
}
while IFS= read -r line; do
    case "$line" in
        "worktree "*)
            flush_record
            current_path="${line#worktree }"
            ;;
        "branch refs/heads/"*)
            current_branch="${line#branch refs/heads/}"
            ;;
        "locked"*)
            current_locked=1
            ;;
        "")
            flush_record
            ;;
    esac
done < <(git -C "$PRIMARY_WORKTREE" worktree list --porcelain)
flush_record

PRUNED=0
PARTIAL=0
SKIPPED=0
FAILED=0
if [ "$NO_PRUNE" -eq 0 ]; then
    log "clean-garden: prune phase — scanning ${#WT_PATHS[@]} worktrees"
    for i in "${!WT_PATHS[@]}"; do
        wt="${WT_PATHS[$i]}"
        br="${WT_BRANCHES[$i]}"
        locked="${WT_LOCKED[$i]}"

        # Normalize path comparison (Windows can return /c/ vs C:/ variants).
        wt_norm=$(cd "$wt" 2>/dev/null && pwd || echo "$wt")
        if [ "$wt_norm" = "$PRIMARY_WORKTREE" ]; then
            log "  skip primary: $wt"
            continue
        fi
        if [ -z "$br" ]; then
            log "  skip detached: $wt"
            continue
        fi
        if [ "$locked" -eq 1 ]; then
            echo "WARN clean-garden: $br is locked — skipped ($wt); unlock with: git worktree unlock $wt" >&2
            SKIPPED=$((SKIPPED+1))
            continue
        fi

        if ! is_branch_mergeable_for_prune "$br"; then
            log "  keep (PR not merged): $br @ $wt"
            continue
        fi

        # Dirty check. Pruning uses `git worktree remove` (no --force) so git
        # itself will also refuse if the worktree gets re-dirtied between this
        # check and the remove call — defense in depth against TOCTOU.
        # Capture stderr separately so a status self-failure (e.g. stale
        # .git/index.lock from a crashed process) is surfaced instead of
        # being misread as a clean tree.
        status_out=""
        status_err=""
        status_rc=0
        { status_out=$(git -C "$wt" status --porcelain 2>/dev/null); status_rc=$?; } || true
        if [ "$status_rc" -ne 0 ]; then
            status_err=$(git -C "$wt" status --porcelain 2>&1 >/dev/null || true)
            echo "WARN clean-garden: $br git status failed (rc=$status_rc) — skipped ($wt): ${status_err}" >&2
            SKIPPED=$((SKIPPED+1))
            continue
        fi
        if [ -n "$status_out" ]; then
            echo "WARN clean-garden: $br has uncommitted changes — skipped ($wt)" >&2
            SKIPPED=$((SKIPPED+1))
            continue
        fi

        if [ "$DRY_RUN" -eq 1 ]; then
            echo "DRY clean-garden: would prune $br ($wt)"
            PRUNED=$((PRUNED+1))
            continue
        fi

        if git -C "$PRIMARY_WORKTREE" worktree remove "$wt" >/dev/null 2>&1; then
            if git -C "$PRIMARY_WORKTREE" branch -D "$br" >/dev/null 2>&1; then
                echo "OK clean-garden: pruned $br ($wt)"
                PRUNED=$((PRUNED+1))
            else
                echo "WARN clean-garden: worktree removed but branch delete failed for $br — counted as partial" >&2
                PARTIAL=$((PARTIAL+1))
            fi
            # Delete the CR-pending marker for this branch now that the PR is merged.
            cr_marker="${COMMON_DIR}/cr-pending/${br}"
            if [ -f "$cr_marker" ]; then
                rm -f "$cr_marker"
                log "  deleted cr-pending marker for $br"
            fi
        else
            echo "ERR clean-garden: failed to remove worktree $wt (re-dirtied? locked? run with --verbose to investigate)" >&2
            FAILED=$((FAILED+1))
        fi
    done
    echo "clean-garden: prune summary — $PRUNED pruned, $PARTIAL partial, $SKIPPED skipped, $FAILED failed"

    # CR-pending marker sweep: remove stale markers for branches that no
    # longer exist locally AND have no open PR. Markers for branches that are
    # gone locally but still have an open PR are always kept (fail-safe).
    # If gh is unavailable we fall back to a local-branch-only check (markers
    # for non-existent branches are swept even without gh confirmation).
    CR_DIR="${COMMON_DIR}/cr-pending"
    if [ -d "$CR_DIR" ]; then
        CR_SWEPT=0
        CR_KEPT=0
        CR_NOTED=0
        # Walk every regular file under cr-pending/ — branch name is the
        # path relative to cr-pending/ (may contain '/' for scoped branches).
        while IFS= read -r marker_file; do
            # Reconstruct branch name: strip leading cr-pending/ prefix.
            marker_branch="${marker_file#"${CR_DIR}"/}"
            # Skip if the branch still exists locally — marker is live.
            if git -C "$PRIMARY_WORKTREE" rev-parse --verify --quiet \
                    "refs/heads/${marker_branch}" >/dev/null 2>&1; then
                log "  cr-pending keep (branch exists): $marker_branch"
                CR_KEPT=$((CR_KEPT+1))
                continue
            fi
            # Branch is gone locally. Check for an open PR if gh is available.
            # Mirror the same scoping pattern as is_branch_mergeable_for_prune:
            # use --repo when GH_REPO is known, otherwise call unscoped.
            if [ "$HAVE_GH" -eq 1 ]; then
                open_count=0
                if [ -n "$GH_REPO" ]; then
                    open_count=$(gh --repo "$GH_REPO" pr list --head "$marker_branch" \
                        --state open --json number --jq 'length' 2>/dev/null) || open_count="ERR"
                else
                    open_count=$(gh pr list --head "$marker_branch" \
                        --state open --json number --jq 'length' 2>/dev/null) || open_count="ERR"
                fi
                # gh failure (network/auth) is NOT "no open PR" — unknown state
                # must keep the marker, else a transient error sweeps a marker
                # whose branch still has an active PR.
                if [ "$open_count" = "ERR" ] || [ -z "$open_count" ]; then
                    echo "WARN clean-garden: gh query failed for $marker_branch — keeping marker (PR state unknown)" >&2
                    CR_NOTED=$((CR_NOTED+1))
                    continue
                fi
                if [ "${open_count:-0}" -gt 0 ]; then
                    echo "NOTE clean-garden: cr-pending marker kept for $marker_branch (open PR exists — review still needed)" >&2
                    CR_NOTED=$((CR_NOTED+1))
                    continue
                fi
            fi
            # HAVE_GH=0: gh unavailable; can't confirm no open PR — sweep
            # anyway since the branch is gone locally (same signal as [gone]
            # fallback used by is_branch_mergeable_for_prune).
            # Branch gone locally, no open PR (or gh unavailable) — sweep.
            if [ "$DRY_RUN" -eq 1 ]; then
                echo "DRY clean-garden: would sweep stale cr-pending marker for $marker_branch"
                CR_SWEPT=$((CR_SWEPT+1))
            else
                rm -f "$marker_file"
                log "  swept stale cr-pending marker: $marker_branch"
                CR_SWEPT=$((CR_SWEPT+1))
            fi
        done < <(find "$CR_DIR" -type f 2>/dev/null | sort)
        echo "clean-garden: cr-pending sweep — $CR_SWEPT swept, $CR_KEPT kept (branch exists), $CR_NOTED kept (open PR)"
    fi
fi

if [ "$PRUNE_ONLY" -eq 1 ] || [ -z "$BRANCH" ]; then
    exit 0
fi

# Create phase — delegate to _new-worktree.sh.
NW_ARGS=("$BRANCH")
[ "$NO_INSTALL" -eq 1 ] && NW_ARGS+=("--no-install")
[ "$VERBOSE" -eq 1 ] && NW_ARGS+=("--verbose")

# Dry-run is intentionally NOT forwarded — _new-worktree.sh has no --dry-run
# flag, and forwarding would error out. Print the plan here and exit instead.
if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY clean-garden: would run scripts/_new-worktree.sh ${NW_ARGS[*]}"
    exit 0
fi

exec bash "$PRIMARY_WORKTREE/scripts/_new-worktree.sh" "${NW_ARGS[@]}"
