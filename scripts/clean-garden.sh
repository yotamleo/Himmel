#!/usr/bin/env bash
# clean-garden — combined worktree prune + create.
#
# Usage:
#   ./scripts/clean-garden.sh [branch-name] [flags]
#
# Prune phase: removes any non-primary worktree whose branch tip exactly matches
# the recorded head of a merged PR. After pruning, every kept worktree is
# accounted for and origin's unmerged remote branches are classified.
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
#   --include-puborigin  Also account for puborigin's remote branches.
#   --verbose, -v        Stream subprocess output.
#   -h, --help           Print usage.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Forge-dispatch seam (HIMMEL-326): the merged-PR + open-PR prune signals route
# through forge_* so prune works on GitHub and Bitbucket Cloud alike.
# shellcheck source=lib/forge.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/forge.sh"

# shellcheck disable=SC2016  # literal text, no expansion intended
USAGE_TEXT='Usage: clean-garden.sh [branch-name] [flags]

  branch-name           Optional. type/slug (feat/foo, chore/bar, ...).
                        When supplied, creates the worktree after pruning.

Flags:
  --prune-only          Prune only; skip create even if branch-name given.
  --no-prune            Skip prune; only create.
  --no-install          Forward to _new-worktree.sh (skip jira install).
  --dry-run             Show plan; do nothing.
  --include-puborigin   Also report unmerged branches from puborigin.
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
INCLUDE_PUBORIGIN=0
VERBOSE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --prune-only) PRUNE_ONLY=1; shift ;;
        --no-prune)   NO_PRUNE=1; shift ;;
        --no-install) NO_INSTALL=1; shift ;;
        --dry-run)           DRY_RUN=1; shift ;;
        --include-puborigin) INCLUDE_PUBORIGIN=1; shift ;;
        --verbose|-v)        VERBOSE=1; shift ;;
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

# Detect PR-merge-detection mode once. Forge queries run pinned to the primary
# worktree (forge_in_primary) so they use the primary's origin regardless of the
# script's cwd — the cwd-independent, forge-agnostic replacement for the old
# `gh --repo <nameWithOwner>` scoping (forge_detect always keys off `origin`).
forge_in_primary() { ( cd "$PRIMARY_WORKTREE" && "$@" ); }

HAVE_FORGE=0
FORGE_KIND=""
FORGE_NWO=""
if FORGE_KIND=$(forge_in_primary forge_detect 2>/dev/null) && forge_in_primary forge_auth_status 2>/dev/null; then
    HAVE_FORGE=1
    FORGE_NWO=$(forge_in_primary forge_repo_nwo 2>/dev/null || true)
    if [ -n "$FORGE_NWO" ]; then
        log "clean-garden: $FORGE_KIND CLI available (repo: $FORGE_NWO)"
    else
        log "clean-garden: $FORGE_KIND CLI available but repo lookup failed"
    fi
else
    log "clean-garden: forge CLI unavailable — PR accounting unknown; worktrees are kept"
fi

# GitHub accounting cache. One paginated API walk per repository replaces the
# old per-worktree PR queries and records the PR head SHA needed to distinguish
# a squash-merged branch from post-merge commits on the same branch.
ORIGIN_NWO="$FORGE_NWO"
ORIGIN_PR_CACHE=""
ORIGIN_PR_CACHE_OK=0
PUBORIGIN_NWO=""
PUBORIGIN_PR_CACHE=""
PUBORIGIN_PR_CACHE_OK=0

# KNOWN LIMITATION: rows key on head.repo.full_name == nwo, so a PR opened
# from a fork (head repo != base repo) is filtered out even though its base
# is this repo. Local worktree/remote-tracking branches are pushed straight
# to origin on this private repo, so a fork PR would only coincidentally
# share a branch name with one of them — rare enough here not to warrant the
# extra base.repo.full_name plumbing + matching-rule complexity. Revisit if
# this repo starts taking fork PRs.
fetch_github_pr_cache() {
    local nwo="$1"
    forge_in_primary _gh api --paginate "repos/$nwo/pulls?state=all&per_page=100" \
        --jq '.[] | [(.head.repo.full_name // ""), .head.ref, (if .state == "open" then "open" elif .merged_at != null then "merged" else "closed" end), .head.sha] | @tsv'
}

github_nwo_from_remote() {
    local remote="$1" url path
    url=$(git -C "$PRIMARY_WORKTREE" remote get-url "$remote" 2>/dev/null) || return 1
    case "$url" in
        https://github.com/*|http://github.com/*) path="${url#*github.com/}" ;;
        git@github.com:*) path="${url#git@github.com:}" ;;
        ssh://git@github.com/*) path="${url#ssh://git@github.com/}" ;;
        *) return 1 ;;
    esac
    path="${path%.git}"
    path="${path%/}"
    case "$path" in
        */*) printf '%s\n' "$path" ;;
        *) return 1 ;;
    esac
}

if [ "$HAVE_FORGE" -eq 1 ] && [ "$FORGE_KIND" = "github" ]; then
    if [ -z "$ORIGIN_NWO" ]; then
        # forge_repo_nwo (gh repo view) failed — fall back to parsing origin's
        # remote URL directly rather than silently degrading accounting.
        if ORIGIN_NWO=$(github_nwo_from_remote origin); then
            log "clean-garden: origin repo lookup recovered from remote URL: $ORIGIN_NWO"
        fi
    fi
    if [ -n "$ORIGIN_NWO" ]; then
        if ORIGIN_PR_CACHE=$(fetch_github_pr_cache "$ORIGIN_NWO" 2>/dev/null); then
            ORIGIN_PR_CACHE_OK=1
        else
            echo "WARN clean-garden: GitHub PR cache failed for origin — accounting will keep uncertain work" >&2
        fi
    else
        echo "WARN clean-garden: could not determine origin's GitHub repo (gh repo view + remote URL parse both failed) — PR accounting degraded to unknown for origin" >&2
    fi
fi
if [ "$INCLUDE_PUBORIGIN" -eq 1 ]; then
    if ! git -C "$PRIMARY_WORKTREE" remote get-url puborigin >/dev/null 2>&1; then
        echo "WARN clean-garden: --include-puborigin requested but no puborigin remote exists" >&2
    elif PUBORIGIN_NWO=$(github_nwo_from_remote puborigin); then
        if PUBORIGIN_PR_CACHE=$(fetch_github_pr_cache "$PUBORIGIN_NWO" 2>/dev/null); then
            PUBORIGIN_PR_CACHE_OK=1
        else
            echo "WARN clean-garden: GitHub PR cache failed for puborigin — accounting will keep uncertain work" >&2
        fi
    else
        echo "WARN clean-garden: puborigin is not a GitHub remote — PR accounting unavailable" >&2
    fi
fi

# Sets PR_STATE and PR_HEAD_MATCH for a branch tip. PR_STATE is one of
# open/merged/closed/none when the cache is authoritative, or unknown when the
# forge could not be queried. A merged PR wins over a closed PR, but an open PR
# wins over both. Among merged PRs, an exact recorded head match is remembered.
resolve_pr_state() {
    local remote="$1" branch="$2" tip="$3"
    local cache cache_ok nwo row_repo row_branch row_state row_sha
    local saw_closed=0 saw_merged=0 exact_merged=0
    PR_STATE="unknown"
    PR_HEAD_MATCH=0

    case "$remote" in
        origin)
            cache="$ORIGIN_PR_CACHE"
            cache_ok="$ORIGIN_PR_CACHE_OK"
            nwo="$ORIGIN_NWO"
            ;;
        puborigin)
            cache="$PUBORIGIN_PR_CACHE"
            cache_ok="$PUBORIGIN_PR_CACHE_OK"
            nwo="$PUBORIGIN_NWO"
            ;;
        *) return 0 ;;
    esac
    [ "$cache_ok" -eq 1 ] || return 0

    PR_STATE="none"
    while IFS=$'\t' read -r row_repo row_branch row_state row_sha; do
        [ -n "$row_branch" ] || continue
        [ "$row_repo" = "$nwo" ] || continue
        [ "$row_branch" = "$branch" ] || continue
        case "$row_state" in
            open)
                PR_STATE="open"
                return 0
                ;;
            merged)
                saw_merged=1
                [ "$row_sha" = "$tip" ] && exact_merged=1
                ;;
            closed)
                saw_closed=1
                ;;
        esac
    done <<EOF
$cache
EOF
    if [ "$saw_merged" -eq 1 ]; then
        PR_STATE="merged"
        PR_HEAD_MATCH="$exact_merged"
    elif [ "$saw_closed" -eq 1 ]; then
        PR_STATE="closed"
    fi
}

# Return 0 only when the current branch tip exactly matches the recorded head
# of a merged PR. A mere "this branch once had a merged PR" signal is unsafe:
# commits may have been added after the squash merge (the HIMMEL-1410 loss mode).
#
# The cached-listing accounting above (ORIGIN_PR_CACHE) is GitHub-only. On a
# non-github forge, fall back to the forge-agnostic per-branch signal the
# cache replaced (forge_pr_has_merged) so pruning keeps working — accounting
# rows still show pr-state=unknown there, but that is a display-only gap, not
# a stuck-worktree regression.
NON_GITHUB_PRUNE_DEGRADED_WARNED=0
is_branch_mergeable_for_prune() {
    local branch="$1" tip
    tip=$(git -C "$PRIMARY_WORKTREE" rev-parse --verify "refs/heads/$branch^{commit}" 2>/dev/null) || return 1
    if [ "$HAVE_FORGE" -eq 1 ] && [ "$FORGE_KIND" != "github" ]; then
        if [ "$NON_GITHUB_PRUNE_DEGRADED_WARNED" -eq 0 ]; then
            echo "WARN clean-garden: $FORGE_KIND PR accounting is degraded (pr-state=unknown for kept worktrees) — prune decisions fall back to the legacy per-branch merged-PR check" >&2
            NON_GITHUB_PRUNE_DEGRADED_WARNED=1
        fi
        local count
        if ! count=$(forge_in_primary forge_pr_has_merged "$branch" 2>/dev/null); then
            echo "WARN clean-garden: forge PR query failed for $branch — treating as not-mergeable (worktree kept)" >&2
            return 1
        fi
        [ "${count:-0}" -gt 0 ]
        return
    fi
    resolve_pr_state origin "$branch" "$tip"
    [ "$PR_STATE" = "merged" ] && [ "$PR_HEAD_MATCH" -eq 1 ]
}

# Is an untracked path a known, discardable stray? (HIMMEL-431)
# Allowlist (survey-grounded): bun package-lock.json, codex AGENTS.md / .codex/.
# Scoped to "may be discarded when pruning a MERGED worktree" — NOT a decision
# about repo tracking of codex files (that is HIMMEL-417).
is_ignorable_stray() {
    case "$1" in
        AGENTS.md|*/AGENTS.md)                 return 0 ;;
        .codex/*|*/.codex/*)                   return 0 ;;
        package-lock.json|*/package-lock.json) return 0 ;;
    esac
    return 1
}

# Classify a worktree's working-tree state for the merged-prune decision.
# Echoes exactly one verdict token (rc always 0; git failures -> "scanfail"):
#   scanfail            a git status/ls-files call failed
#   tracked             tracked modifications present (real WIP)
#   clean               no tracked changes, no untracked files
#   forgotten <paths>   tracked-clean, but untracked file(s) NOT on the allowlist
#   strays <paths>      tracked-clean, all untracked file(s) are ignorable strays
classify_worktree() {
    local wt="$1" tracked untracked u nonign="" strays=""
    if ! tracked=$(git -C "$wt" status --porcelain --untracked-files=no 2>/dev/null); then
        echo "scanfail"; return 0
    fi
    if [ -n "$tracked" ]; then echo "tracked"; return 0; fi
    if ! untracked=$(git -C "$wt" ls-files --others --exclude-standard 2>/dev/null); then
        echo "scanfail"; return 0
    fi
    if [ -z "$untracked" ]; then echo "clean"; return 0; fi
    while IFS= read -r u; do
        [ -z "$u" ] && continue
        if is_ignorable_stray "$u"; then
            strays="${strays:+$strays }$u"
        else
            nonign="${nonign:+$nonign }$u"
        fi
    done <<EOF
$untracked
EOF
    if [ -n "$nonign" ]; then echo "forgotten $nonign"; return 0; fi
    echo "strays $strays"; return 0
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

registered_worktree_path() {
    local candidate="$1" candidate_norm wt wt_norm
    candidate_norm=$(cd "$candidate" 2>/dev/null && pwd || echo "$candidate")
    for wt in "${WT_PATHS[@]}"; do
        wt_norm=$(cd "$wt" 2>/dev/null && pwd || echo "$wt")
        if [ "$candidate_norm" = "$wt_norm" ]; then
            return 0
        fi
    done
    return 1
}

human_kib() {
    awk -v kib="${1:-0}" 'BEGIN {
        bytes = kib * 1024
        split("B K M G T", unit)
        value = bytes
        idx = 1
        while (value >= 1024 && idx < 5) {
            value = value / 1024
            idx++
        }
        if (idx == 1 || value >= 10) {
            printf "%.0f%s", value, unit[idx]
        } else {
            printf "%.1f%s", value, unit[idx]
        }
    }'
}

MAIN_REF=""
if git -C "$PRIMARY_WORKTREE" rev-parse --verify --quiet refs/remotes/origin/main >/dev/null; then
    MAIN_REF="refs/remotes/origin/main"
elif git -C "$PRIMARY_WORKTREE" rev-parse --verify --quiet refs/heads/main >/dev/null; then
    MAIN_REF="refs/heads/main"
fi

last_commit_age() {
    local tip="$1" committed now elapsed
    committed=$(git -C "$PRIMARY_WORKTREE" show -s --format=%ct "$tip" 2>/dev/null) || {
        printf '?'; return 0;
    }
    now=$(date +%s)
    elapsed=$((now - committed))
    [ "$elapsed" -lt 0 ] && elapsed=0
    if [ "$elapsed" -ge 86400 ]; then
        printf '%dd' "$((elapsed / 86400))"
    elif [ "$elapsed" -ge 3600 ]; then
        printf '%dh' "$((elapsed / 3600))"
    else
        printf '%dm' "$((elapsed / 60))"
    fi
}

scan_worktree_counts() {
    local wt="$1" status_line status_output
    WT_SCAN_OK=1
    WT_DIRTY_COUNT=0
    WT_UNTRACKED_COUNT=0
    if ! status_output=$(git -C "$wt" status --porcelain --untracked-files=all 2>/dev/null); then
        WT_SCAN_OK=0
        return 0
    fi
    while IFS= read -r status_line; do
        [ -n "$status_line" ] || continue
        case "$status_line" in
            "?? "*) WT_UNTRACKED_COUNT=$((WT_UNTRACKED_COUNT+1)) ;;
            *)       WT_DIRTY_COUNT=$((WT_DIRTY_COUNT+1)) ;;
        esac
    done <<EOF
$status_output
EOF
}

commits_not_on_main() {
    local tip="$1"
    if [ -z "$MAIN_REF" ]; then
        printf '?'
        return 0
    fi
    git -C "$PRIMARY_WORKTREE" rev-list --count "$MAIN_REF..$tip" 2>/dev/null || printf '?'
}

LOCAL_KEPT=0
LOCAL_UNKNOWN=0
report_kept_worktree() {
    local wt="$1" branch="$2" tip="$3" locked="$4"
    local branch_label ahead age verdict why wt_norm
    LOCAL_KEPT=$((LOCAL_KEPT+1))
    branch_label="$branch"
    [ -n "$branch_label" ] || branch_label="(detached:${tip:0:12})"
    ahead=$(commits_not_on_main "$tip")
    age=$(last_commit_age "$tip")
    scan_worktree_counts "$wt"
    wt_norm=$(cd "$wt" 2>/dev/null && pwd || echo "$wt")

    if [ "$WT_SCAN_OK" -eq 0 ]; then
        PR_STATE="unknown"
        verdict="UNKNOWN"
        why="working-tree scan failed"
    elif [ $((WT_DIRTY_COUNT + WT_UNTRACKED_COUNT)) -gt 0 ]; then
        if [ -n "$branch" ]; then
            resolve_pr_state origin "$branch" "$tip"
        else
            PR_STATE="none"
        fi
        verdict="PARKED-WIP"
        why="working tree is not clean"
    elif [ "$wt_norm" = "$PRIMARY_WORKTREE" ]; then
        if [ -n "$branch" ]; then
            resolve_pr_state origin "$branch" "$tip"
        else
            PR_STATE="none"
        fi
        verdict="ACTIVE"
        why="primary worktree"
    elif [ -z "$branch" ]; then
        PR_STATE="none"
        if [ "$ahead" = "0" ]; then
            verdict="SUPERSEDED"
            why="detached tip is already on main"
        else
            verdict="UNKNOWN"
            why="detached tip has commits not on main"
        fi
    else
        resolve_pr_state origin "$branch" "$tip"
        case "$PR_STATE:$PR_HEAD_MATCH:$ahead" in
            open:*)
                verdict="ACTIVE"
                why="open PR"
                ;;
            merged:1:*)
                verdict="SUPERSEDED"
                why="tip matches merged PR head"
                ;;
            merged:0:*)
                verdict="UNKNOWN"
                why="branch tip differs from merged PR head"
                ;;
            *:*:0)
                verdict="SUPERSEDED"
                why="tip is already on main"
                ;;
            closed:*)
                verdict="UNKNOWN"
                why="closed PR left commits off main"
                ;;
            none:*)
                verdict="UNKNOWN"
                why="no PR for commits off main"
                ;;
            *)
                verdict="UNKNOWN"
                why="PR state could not be resolved"
                ;;
        esac
    fi
    [ "$locked" -eq 0 ] || why="$why; worktree locked"
    [ "$verdict" != "UNKNOWN" ] || LOCAL_UNKNOWN=$((LOCAL_UNKNOWN+1))
    printf 'KEEP clean-garden: branch=%s pr=%s commits-not-main=%s dirty=%s untracked=%s age=%s verdict=%s why=%s path=%s\n' \
        "$branch_label" "$PR_STATE" "$ahead" "$WT_DIRTY_COUNT" "$WT_UNTRACKED_COUNT" \
        "$age" "$verdict" "$why" "$wt"
}

report_kept_worktrees() {
    local wt="" branch="" tip="" locked=0 line
    while IFS= read -r line; do
        case "$line" in
            "worktree "*)
                if [ -n "$wt" ]; then
                    report_kept_worktree "$wt" "$branch" "$tip" "$locked"
                fi
                wt="${line#worktree }"
                branch=""
                tip=""
                locked=0
                ;;
            "HEAD "*)
                tip="${line#HEAD }"
                ;;
            "branch refs/heads/"*)
                branch="${line#branch refs/heads/}"
                ;;
            "locked"*)
                locked=1
                ;;
            "")
                if [ -n "$wt" ]; then
                    report_kept_worktree "$wt" "$branch" "$tip" "$locked"
                    wt=""
                fi
                ;;
        esac
    done < <(git -C "$PRIMARY_WORKTREE" worktree list --porcelain)
    if [ -n "$wt" ]; then
        report_kept_worktree "$wt" "$branch" "$tip" "$locked"
    fi
}

REMOTE_MERGED_CLEAN=0
REMOTE_TIP_DIFFERS=0
REMOTE_CLOSED_UNMERGED=0
REMOTE_NO_PR=0
REMOTE_UNKNOWN=0
report_remote_orphans() {
    local remote="$1" branch tip category
    git -C "$PRIMARY_WORKTREE" remote get-url "$remote" >/dev/null 2>&1 || return 0
    while IFS=' ' read -r branch tip; do
        [ -n "$branch" ] || continue
        [ "$branch" != "HEAD" ] || continue
        if [ -n "$MAIN_REF" ] && git -C "$PRIMARY_WORKTREE" merge-base --is-ancestor "$tip" "$MAIN_REF" 2>/dev/null; then
            continue
        fi
        resolve_pr_state "$remote" "$branch" "$tip"
        [ "$PR_STATE" != "open" ] || continue
        case "$PR_STATE:$PR_HEAD_MATCH" in
            merged:1)
                category="MERGED-CLEAN"
                REMOTE_MERGED_CLEAN=$((REMOTE_MERGED_CLEAN+1))
                ;;
            merged:0)
                category="TIP-DIFFERS"
                REMOTE_TIP_DIFFERS=$((REMOTE_TIP_DIFFERS+1))
                ;;
            closed:*)
                category="CLOSED-UNMERGED"
                REMOTE_CLOSED_UNMERGED=$((REMOTE_CLOSED_UNMERGED+1))
                ;;
            none:*)
                category="NO-PR"
                REMOTE_NO_PR=$((REMOTE_NO_PR+1))
                ;;
            *)
                category="UNKNOWN"
                REMOTE_UNKNOWN=$((REMOTE_UNKNOWN+1))
                ;;
        esac
        printf 'REMOTE clean-garden: remote=%s branch=%s pr=%s category=%s tip=%s\n' \
            "$remote" "$branch" "$PR_STATE" "$category" "${tip:0:12}"
    done < <(git -C "$PRIMARY_WORKTREE" for-each-ref \
        --format='%(refname:strip=3) %(objectname)' "refs/remotes/$remote")
}

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

        # Working-tree check (HIMMEL-431). Base the prune decision on TRACKED
        # changes only: a merged worktree's real work is already in main, so its
        # untracked files are strays. Known-regenerable strays (bun lockfile,
        # codex files) are discarded with the prune; tracked WIP or an unknown
        # untracked file (possible forgotten work) keeps the worktree + warns.
        # `|| verdict=scanfail` backstops the rc-always-0 contract: if a future
        # edit ever lets classify_worktree exit non-zero, degrade to the safe
        # skip rather than aborting the whole sweep under `set -e`.
        verdict=$(classify_worktree "$wt") || verdict="scanfail"
        case "$verdict" in
            scanfail)
                echo "WARN clean-garden: $br working-tree scan failed — skipped ($wt)" >&2
                SKIPPED=$((SKIPPED+1)); continue ;;
            tracked)
                echo "WARN clean-garden: $br has uncommitted changes — skipped ($wt)" >&2
                SKIPPED=$((SKIPPED+1)); continue ;;
            "forgotten "*)
                echo "WARN clean-garden: $br has untracked files that are not known strays (possible forgotten work) — skipped ($wt): ${verdict#forgotten }" >&2
                SKIPPED=$((SKIPPED+1)); continue ;;
        esac
        # verdict is "clean" or "strays <paths>".
        strays=""
        case "$verdict" in "strays "*) strays="${verdict#strays }" ;; esac

        if [ "$DRY_RUN" -eq 1 ]; then
            if [ -n "$strays" ]; then
                echo "DRY clean-garden: would prune $br ($wt), discarding untracked strays: $strays"
            else
                echo "DRY clean-garden: would prune $br ($wt)"
            fi
            PRUNED=$((PRUNED+1))
            continue
        fi

        # `git worktree remove` (no --force) refuses on untracked files, so the
        # strays case needs --force. Re-classify immediately before forcing so a
        # tracked change OR a new non-stray untracked file appearing in the window
        # still aborts (restores the defense-in-depth the plain path gets free).
        remove_args=()
        if [ -n "$strays" ]; then
            verdict2=$(classify_worktree "$wt") || verdict2="scanfail"
            case "$verdict2" in
                "strays "*) ;;         # still only strays — safe to force
                "clean") strays="" ;;  # strays vanished; plain remove now works
                *)
                    echo "WARN clean-garden: $br changed during prune ($verdict2) — skipped ($wt)" >&2
                    SKIPPED=$((SKIPPED+1)); continue ;;
            esac
            if [ -n "$strays" ]; then
                remove_args=(--force)
                echo "NOTE clean-garden: $br — pruning merged worktree, discarding untracked strays: $strays ($wt)" >&2
            fi
        fi

        if git -C "$PRIMARY_WORKTREE" worktree remove "${remove_args[@]}" "$wt" >/dev/null 2>&1; then
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

    STRAY_HOME="$PRIMARY_WORKTREE/.claude/worktrees"
    if [ -d "$STRAY_HOME" ]; then
        STRAY_FOUND=0
        STRAY_SWEPT=0
        STRAY_FAILED=0
        STRAY_RECLAIMED_KIB=0
        while IFS= read -r stray_dir; do
            [ -n "$stray_dir" ] || continue
            stray_norm=$(cd "$stray_dir" 2>/dev/null && pwd || echo "$stray_dir")
            if [ "$stray_norm" = "$PRIMARY_WORKTREE" ]; then
                log "  stray-sweep skip primary-looking path: $stray_dir"
                continue
            fi
            if registered_worktree_path "$stray_dir"; then
                log "  stray-sweep keep registered worktree: $stray_dir"
                continue
            fi
            # Fresh = ANY entry inside the husk modified in the last 24h, not
            # just the top-level dir mtime (nested writes by an in-flight
            # session don't touch the top dir's mtime).
            if find "$stray_dir" -mmin -1440 -print 2>/dev/null | grep -q .; then
                log "  stray-sweep skip fresh husk: $stray_dir"
                continue
            fi

            STRAY_FOUND=$((STRAY_FOUND+1))
            stray_kib=$(du -sk "$stray_dir" 2>/dev/null | awk '{ print $1 }') || stray_kib=0
            stray_kib=${stray_kib:-0}

            if [ "$DRY_RUN" -eq 1 ]; then
                echo "DRY clean-garden: would sweep stray husk $stray_dir"
                STRAY_SWEPT=$((STRAY_SWEPT+1))
                STRAY_RECLAIMED_KIB=$((STRAY_RECLAIMED_KIB+stray_kib))
                continue
            fi
            if rm -rf "$stray_dir" 2>/dev/null; then
                log "  swept stray husk: $stray_dir"
                STRAY_SWEPT=$((STRAY_SWEPT+1))
                STRAY_RECLAIMED_KIB=$((STRAY_RECLAIMED_KIB+stray_kib))
            else
                echo "WARN clean-garden: failed to sweep stray husk $stray_dir" >&2
                STRAY_FAILED=$((STRAY_FAILED+1))
            fi
        done < <(find "$STRAY_HOME" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
        if [ "$STRAY_FOUND" -gt 0 ]; then
            STRAY_SIZE=$(human_kib "$STRAY_RECLAIMED_KIB")
            echo "clean-garden: stray-sweep — $STRAY_SWEPT swept, $STRAY_FAILED failed ($STRAY_SIZE reclaimed)"
        fi
    fi

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
            # Branch is gone locally. Check for an open PR via the forge seam if
            # the forge CLI is available. forge_pr_find_open prints the open PR
            # number (→ keep) or empty (→ sweep); a non-zero exit is a real query
            # failure (network/auth) — unknown state must KEEP the marker, else a
            # transient error sweeps a marker whose branch still has an open PR.
            if [ "$HAVE_FORGE" -eq 1 ]; then
                open_pr=""
                if ! open_pr=$(forge_in_primary forge_pr_find_open "$marker_branch" 2>/dev/null); then
                    echo "WARN clean-garden: forge query failed for $marker_branch — keeping marker (PR state unknown)" >&2
                    CR_NOTED=$((CR_NOTED+1))
                    continue
                fi
                if [ -n "$open_pr" ]; then
                    echo "NOTE clean-garden: cr-pending marker kept for $marker_branch (open PR exists — review still needed)" >&2
                    CR_NOTED=$((CR_NOTED+1))
                    continue
                fi
            fi
            # HAVE_FORGE=0: forge unavailable; can't confirm no open PR — sweep
            # anyway since the branch is gone locally (same signal as [gone]
            # fallback used by is_branch_mergeable_for_prune).
            # Branch gone locally, no open PR (or forge unavailable) — sweep.
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

    echo "clean-garden: full accounting — kept worktrees"
    report_kept_worktrees
    echo "clean-garden: full accounting — remote orphans"
    report_remote_orphans origin
    if [ "$INCLUDE_PUBORIGIN" -eq 1 ]; then
        report_remote_orphans puborigin
    fi
    echo "clean-garden: accounting summary — $LOCAL_KEPT kept worktrees; $REMOTE_MERGED_CLEAN MERGED-CLEAN, $REMOTE_TIP_DIFFERS TIP-DIFFERS, $REMOTE_CLOSED_UNMERGED CLOSED-UNMERGED, $REMOTE_NO_PR NO-PR"
    ACCOUNTING_UNKNOWN=$((LOCAL_UNKNOWN + REMOTE_UNKNOWN))
    if [ "$ACCOUNTING_UNKNOWN" -gt 0 ] || [ "$REMOTE_TIP_DIFFERS" -gt 0 ] || [ "$REMOTE_NO_PR" -gt 0 ]; then
        echo "ALERT clean-garden: attention required — $ACCOUNTING_UNKNOWN UNKNOWN, $REMOTE_TIP_DIFFERS TIP-DIFFERS, $REMOTE_NO_PR NO-PR"
    fi
fi

# ---------------------------------------------------------------------------
# HIMMEL-1596 — reap stale worker checkpoints.
#
# The spawner snapshots a worker's uncommitted work to refs/checkpoints/<slug>
# so a worker that dies mid-run does not take its work with it. Those refs live
# OUTSIDE refs/heads/ deliberately — no branch push can carry them — but that
# also means nothing has ever removed them, and an unreferenced-but-reachable
# ref PINS ITS WHOLE OBJECT GRAPH AGAINST gc. A checkpoint is a safety net with
# a short useful life: once the work is harvested (or the run is long dead) it
# is pure ballast, and shared-branch mode reuses the slug, so the pile grows
# with dispatch volume — the direction wave 1 is pushing.
#
# Age is the right predicate, and the only honest one available. "Was it
# harvested?" cannot be answered from here: a harvest is `git restore --source`
# into someone's tree, which leaves no mark on the ref. So this reaps by the
# checkpoint COMMIT's own date, generously, rather than guessing at intent.
# Deliberately NOT tied to whether the worktree or branch still exists — a
# checkpoint outliving its worktree is precisely the case worth keeping.
CHECKPOINT_TTL_DAYS="${CHECKPOINT_TTL_DAYS:-14}"
# Validate BEFORE the arithmetic: a leading-zero value like 08 is read as OCTAL
# by `$(( ))` and dies "value too great for base" (under this script's `set -e`,
# aborting the whole reap); a negative value makes the cutoff a FUTURE time, so
# every checkpoint reads as stale and FRESH work is deleted. Accept only a
# non-negative decimal, else fall back to the 14 default with a warning — the
# same shape critic-panel.sh / pr-check.md use for their timeout knobs.
# (`*[!0-9]*` rejects a leading `-` too, since `-` is not a digit.)
case "$CHECKPOINT_TTL_DAYS" in
    ''|*[!0-9]*)
        echo "WARN clean-garden: CHECKPOINT_TTL_DAYS=\"$CHECKPOINT_TTL_DAYS\" is not a non-negative decimal — using 14" >&2
        CHECKPOINT_TTL_DAYS=14
        ;;
esac
prune_checkpoint_refs() {
    local cutoff now ref ts oid pruned=0 kept=0
    now=$(date +%s)
    # 10# forces base 10 so a (now-valid) leading-zero value like 08 reads as
    # decimal 8, not octal — belt-and-braces alongside the case guard above.
    cutoff=$(( now - 10#$CHECKPOINT_TTL_DAYS * 86400 ))
    # Capture the object ID in the SAME for-each-ref that lists the ref, and pass
    # it as the expected old value to `update-ref -d`: a worker can REPLACE
    # refs/checkpoints/<slug> between this enumerate and the delete (shared-branch
    # mode reuses the slug), so a plain `update-ref -d` would destroy a FRESH
    # checkpoint. With the expected value, git refuses the delete if the ref
    # moved under us — the same compare-and-swap shape update-ref accepts.
    while IFS="$(printf '\t')" read -r ref ts oid; do
        if [ -z "$ref" ] || [ -z "$ts" ] || [ -z "$oid" ]; then continue; fi
        if [ "$ts" -ge "$cutoff" ]; then
            kept=$((kept + 1)); continue
        fi
        if [ "$DRY_RUN" -eq 1 ]; then
            echo "DRY clean-garden: would delete $ref (checkpoint older than ${CHECKPOINT_TTL_DAYS}d)"
            pruned=$((pruned + 1))
        elif git -C "$PRIMARY_WORKTREE" update-ref -d "$ref" "$oid" 2>/dev/null; then
            [ "$VERBOSE" -eq 1 ] && echo "clean-garden: deleted $ref (older than ${CHECKPOINT_TTL_DAYS}d)"
            pruned=$((pruned + 1))
        else
            # A refused delete is the live race worth warning about: the ref
            # moved between enumerate and delete (a fresh checkpoint replaced the
            # stale one we judged eligible), or the delete otherwise failed —
            # either way the ref is left in place rather than destroyed blindly.
            echo "WARN clean-garden: could not delete stale checkpoint $ref (moved or failed — left in place)" >&2
        fi
    done < <(git -C "$PRIMARY_WORKTREE" for-each-ref \
                --format="%(refname)$(printf '\t')%(committerdate:unix)$(printf '\t')%(objectname)" \
                refs/checkpoints/ 2>/dev/null)
    if [ "$pruned" -gt 0 ] || [ "$kept" -gt 0 ]; then
        echo "clean-garden: checkpoints — $pruned pruned (>${CHECKPOINT_TTL_DAYS}d), $kept kept"
    fi
}

if [ "$NO_PRUNE" -eq 0 ]; then
    prune_checkpoint_refs
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
