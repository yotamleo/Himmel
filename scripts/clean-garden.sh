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
# HIMMEL-2227 — worktree_in_use / worktree_intact: a plain `git worktree
# remove` is NOT atomic on Windows (see the lib's own header for the measured
# repro), so the prune loop below probes before removing and classifies a
# failed remove instead of trusting a bare non-zero rc.
# shellcheck source=lib/worktree-inuse.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/worktree-inuse.sh"

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
# Allowlist (survey-grounded): bun package-lock.json, codex AGENTS.md / .codex/,
# tokensave .tokensave/. Scoped to "may be discarded when pruning a MERGED
# worktree" — NOT a decision about repo tracking of codex files (that is
# HIMMEL-417).
#
# On tool-generated churn (HIMMEL-1692): every entry here is ALSO gitignored in
# this repo, so `ls-files --others --exclude-standard` normally filters it long
# before classify_worktree sees it. The allowlist is the belt to that braces —
# it keeps the verdict correct in a clone/adopter checkout whose .gitignore
# lacks the entry, where the churn would otherwise read as "forgotten" (=
# possible user work) and refuse the prune forever. .tokensave/ is the sharp
# case: this machine chains a tokensave watcher off the GLOBAL git hookspath,
# so post-checkout mints a live SQLite DB inside a NEW worktree within seconds
# of `git worktree add` — churn that is emphatically not user work. Adding a
# path here says only "safe to DISCARD with an already-merged worktree"; it can
# never suppress a refusal driven by tracked modifications, which are checked
# first and independently in classify_worktree.
is_ignorable_stray() {
    case "$1" in
        AGENTS.md|*/AGENTS.md)                 return 0 ;;
        .codex/*|*/.codex/*)                   return 0 ;;
        .tokensave/*|*/.tokensave/*)           return 0 ;;
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

# HIMMEL-1692 — snapshot a refused-prune worktree's uncommitted work to
# refs/checkpoints/<slug>, so classify_worktree's refusal above (tracked or
# forgotten verdict) doesn't just leave that work sitting unprotected in the
# worktree against any OTHER deletion path. A temporary GIT_INDEX_FILE is used
# instead of `git stash`: `git stash create` alone cannot capture untracked
# files, and neither the real index nor the working tree may be touched here —
# this runs against someone else's live worktree, possibly mid-edit. The
# written ref is reaped by the existing checkpoint TTL sweep further down this
# file (CHECKPOINT_TTL_DAYS) — no separate lifecycle needed.
#
# Failure-tolerant by design: this is a safety net bolted onto a refusal that
# already happened, so a failure here must never abort the sweep or flip the
# prune verdict. Every git call is guarded and a failure returns non-zero
# quietly with a WARN; callers invoke this as `checkpoint_worktree ... || true`.
checkpoint_worktree() {
    local wt="$1" br="$2"
    local raw slug tmp_dir tmp_index head_oid head_tree old_oid tree oid nfiles rc
    local index_tree index_oid index_parent snap_tree

    raw="$(basename "$wt")"
    slug="$(printf '%s' "$raw" | sed -E 's/[^A-Za-z0-9._-]/-/g')-autosave"

    if ! git check-ref-format "refs/checkpoints/$slug" >/dev/null 2>&1; then
        echo "WARN clean-garden: checkpoint ref 'refs/checkpoints/$slug' rejected by check-ref-format — skipping snapshot for $br ($wt)" >&2
        return 1
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "DRY clean-garden: would checkpoint $wt -> refs/checkpoints/$slug"
        return 0
    fi

    head_oid=$(git -C "$wt" rev-parse --verify HEAD 2>/dev/null)
    if [ -z "$head_oid" ]; then
        echo "WARN clean-garden: could not resolve HEAD for $br ($wt) — skipping checkpoint" >&2
        return 1
    fi

    tmp_dir=$(mktemp -d 2>/dev/null)
    if [ -z "$tmp_dir" ] || [ ! -d "$tmp_dir" ]; then
        echo "WARN clean-garden: could not create temp dir for checkpoint of $br — skipping" >&2
        return 1
    fi
    tmp_index="$tmp_dir/index"

    # Seed from HEAD first: a fresh index is EMPTY, so `add -A` over it alone
    # would write a tree containing ONLY the currently-dirty paths — a diff vs
    # HEAD that DELETES the rest of the repo. read-tree HEAD then `add -A`
    # yields HEAD-plus-changes, which is what "checkpoint" means.
    if ! GIT_INDEX_FILE="$tmp_index" git -C "$wt" read-tree "$head_oid" >/dev/null 2>&1; then
        echo "WARN clean-garden: checkpoint read-tree failed for $br ($wt) — skipping" >&2
        rm -rf "$tmp_dir"
        return 1
    fi
    if ! GIT_INDEX_FILE="$tmp_index" git -C "$wt" add -A >/dev/null 2>&1; then
        echo "WARN clean-garden: checkpoint add -A failed for $br ($wt) — skipping" >&2
        rm -rf "$tmp_dir"
        return 1
    fi
    tree=$(GIT_INDEX_FILE="$tmp_index" git -C "$wt" write-tree 2>/dev/null)
    if [ -z "$tree" ]; then
        echo "WARN clean-garden: checkpoint write-tree failed for $br ($wt) — skipping" >&2
        rm -rf "$tmp_dir"
        return 1
    fi
    rm -rf "$tmp_dir"

    head_tree=$(git -C "$wt" rev-parse --verify "${head_oid}^{tree}" 2>/dev/null)

    # Capture the INDEX snapshot too, and do it BEFORE the nothing-to-save
    # early-return (codex CR rounds 1 + 3). `add -A` above records the
    # WORKING-TREE content of every path, so the index is a SECOND state this
    # function must not drop:
    #   - staged X, then edited again on disk -> worktree wins, X would be lost;
    #   - staged X, then reverted on disk to HEAD -> the worktree tree collapses
    #     back to HEAD's, so an early-return placed above this would exit 0 and
    #     silently discard X, even though `status --porcelain` reported the
    #     worktree dirty and sent us here. That was round 3's Critical.
    # READ-ONLY: `write-tree` with no GIT_INDEX_FILE override reads the
    # worktree's REAL index and writes only tree objects — it never rewrites the
    # index file, so the mid-edit-worktree invariant this function is built
    # around still holds. Best-effort like everything else here: an unmerged or
    # unreadable index just yields no index snapshot.
    index_tree=$(git -C "$wt" write-tree 2>/dev/null)

    # Which tree does the checkpoint RESTORE to? Normally the worktree — that is
    # the state an operator expects `git restore --source=<ref>` to give back.
    # But when the worktree collapses back to HEAD and only the index differs,
    # the staged snapshot is the ONLY work that exists, so it becomes the
    # checkpoint's own tree rather than being demoted to a parent nobody looks at.
    snap_tree="$tree"
    if [ "$tree" = "$head_tree" ] && [ -n "$index_tree" ] && [ "$index_tree" != "$head_tree" ]; then
        snap_tree="$index_tree"
    fi
    if [ "$snap_tree" = "$head_tree" ]; then
        return 0   # nothing to save — worktree AND index both collapse to HEAD
    fi

    # One tree cannot represent both states, so when the index differs from the
    # tree we are restoring to, keep it as an extra PARENT: reachable from the
    # ref (fetchable, not gc-able) without changing what a restore yields.
    index_parent=""
    if [ -n "$index_tree" ] && [ "$index_tree" != "$snap_tree" ] && [ "$index_tree" != "$head_tree" ]; then
        index_oid=$(git -C "$wt" commit-tree "$index_tree" -p "$head_oid" -m "clean-garden autosave INDEX (HIMMEL-1692): $br" 2>/dev/null)
        [ -n "$index_oid" ] && index_parent="$index_oid"
    fi

    # Lossless overwrite: an existing checkpoint becomes a SECOND parent, so a
    # re-run of /clean never discards an earlier snapshot, and the update-ref
    # below passes the old oid as the expected value (compare-and-swap) —
    # the same shape prune_checkpoint_refs uses for its delete.
    old_oid=$(git -C "$PRIMARY_WORKTREE" rev-parse --verify --quiet "refs/checkpoints/$slug" 2>/dev/null)
    set -- -p "$head_oid"
    [ -n "$old_oid" ] && set -- "$@" -p "$old_oid"
    [ -n "$index_parent" ] && set -- "$@" -p "$index_parent"
    oid=$(git -C "$wt" commit-tree "$snap_tree" "$@" -m "clean-garden autosave (HIMMEL-1692): $br" 2>/dev/null)
    if [ -z "$oid" ]; then
        echo "WARN clean-garden: checkpoint commit-tree failed for $br ($wt) — skipping" >&2
        return 1
    fi

    # Compare-and-swap on BOTH paths (codex adversarial round 4). The update
    # path passes the observed old oid; the CREATE path passes the EMPTY STRING,
    # which is git's "this ref must not exist" expectation — without it, two
    # concurrent /clean runs that both saw no ref would both plain-write it and
    # the loser's snapshot would become unreachable, silently, from the function
    # that promises losslessness. On contention we WARN and return 1 rather than
    # retry: the winner's checkpoint is a snapshot of the SAME worktree taken
    # seconds apart, so refusing to clobber it loses nothing real, and a
    # rebuild-and-retry loop would add a race of its own to best-effort armor.
    rc=0
    if [ -n "$old_oid" ]; then
        git -C "$PRIMARY_WORKTREE" update-ref "refs/checkpoints/$slug" "$oid" "$old_oid" 2>/dev/null || rc=1
    else
        git -C "$PRIMARY_WORKTREE" update-ref "refs/checkpoints/$slug" "$oid" "" 2>/dev/null || rc=1
    fi
    if [ "$rc" -ne 0 ]; then
        echo "WARN clean-garden: checkpoint update-ref failed for $br (refs/checkpoints/$slug created or moved concurrently — the other run's checkpoint stands) — skipping" >&2
        return 1
    fi

    nfiles=$(git -C "$wt" diff-tree --no-commit-id --name-only -r "$head_tree" "$snap_tree" 2>/dev/null | wc -l | tr -d ' ')
    # Recover into a SEPARATE detached worktree, never `git restore --worktree
    # -- .` (codex adversarial round 1). `restore` writes every captured path
    # into whatever worktree the operator happens to be standing in — silently
    # overwriting THEIR uncommitted work, and not necessarily even the worktree
    # this snapshot came from. A data-loss guard must not advertise a
    # data-losing recovery. `worktree add --detach` is inspectable and additive.
    echo "SAVED clean-garden: checkpointed $br -> refs/checkpoints/$slug ($nfiles file(s)); recover with: git worktree add --detach <recovery-path> refs/checkpoints/$slug   (inspect there, then copy what you need — do NOT 'git restore' over a live worktree)"
    return 0
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

# HIMMEL-1970 — `refs/remotes/<remote>/*` is a LOCAL CACHE, and nothing here
# ever refreshed it. This repo has deleteBranchOnMerge=true, and merge-on-green
# no longer passes `gh pr merge --delete-branch` (HIMMEL-1679) — that flag's
# `git push origin --delete` was what used to drop the local ref as a side
# effect. So a squash-merged branch now vanishes server-side while its
# remote-tracking ref lives on forever, and the classifier below re-reports it
# as MERGED-CLEAN on every run (19 of them on 2026-08-20 — read by a human as
# "19 worktrees were kept and none pruned", which the prune loop never claimed:
# these counters are about REMOTE BRANCHES, never worktrees). Drop the dead
# refs before classifying. Fail-OPEN: a stale ref only inflates a report, so an
# unreachable remote just leaves the cache alone and everything is classified
# as before.
REMOTE_LIVE_HEADS=""
REMOTE_LIVE_OK=0
refresh_remote_tracking() {
    local remote="$1" heads
    REMOTE_LIVE_HEADS=""
    REMOTE_LIVE_OK=0
    # Non-interactive: an https remote without cached credentials would
    # otherwise sit on a username prompt and hang /clean (which runs unattended
    # from cadences), and an ssh remote would hang on a host-key/passphrase
    # prompt. Both are turned into a fast failure, which is the fail-open path.
    if ! heads=$(GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}" \
            git -C "$PRIMARY_WORKTREE" ls-remote --heads "$remote" 2>/dev/null); then
        # Unconditional, not log(): a DEFAULT run must carry the marker that
        # the remote-branch counters below may be stale.
        echo "clean-garden: remote-tracking refresh skipped ($remote unreachable) — the remote-branch counters below may include branches the remote no longer has"
        return 0
    fi
    REMOTE_LIVE_HEADS=$(printf '%s\n' "$heads" | sed -n 's#^[0-9a-f]*[[:space:]]*refs/heads/##p')
    REMOTE_LIVE_OK=1
    # --dry-run must not touch refs; the skip below still keeps the REPORT
    # honest in that mode, so both modes classify identically.
    [ "$DRY_RUN" -eq 1 ] && return 0
    git -C "$PRIMARY_WORKTREE" remote prune "$remote" >/dev/null 2>&1 || true
    return 0
}

# Is this remote-tracking branch still on the remote? Unknown (refresh failed)
# counts as live — never drop a row on missing evidence.
remote_branch_is_live() {
    [ "$REMOTE_LIVE_OK" -eq 1 ] || return 0
    grep -qxF "$1" <<EOF
$REMOTE_LIVE_HEADS
EOF
}

report_remote_orphans() {
    local remote="$1" branch tip category
    git -C "$PRIMARY_WORKTREE" remote get-url "$remote" >/dev/null 2>&1 || return 0
    refresh_remote_tracking "$remote"
    while IFS=' ' read -r branch tip; do
        [ -n "$branch" ] || continue
        [ "$branch" != "HEAD" ] || continue
        if ! remote_branch_is_live "$branch"; then
            log "  remote-orphan skip (no longer on $remote): $branch"
            continue
        fi
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
                checkpoint_worktree "$wt" "$br" || true
                echo "WARN clean-garden: $br has uncommitted changes — skipped ($wt)" >&2
                SKIPPED=$((SKIPPED+1)); continue ;;
            "forgotten "*)
                checkpoint_worktree "$wt" "$br" || true
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

        # HIMMEL-2227 — in-use probe BEFORE the remove, plain or --force alike:
        # the remove is NOT atomic on Windows, and --force strips git's own
        # up-front refusal, so without this probe a forced remove on an
        # in-use tree is guaranteed to gut it (see worktree-inuse.sh's header
        # for the measured repro).
        if worktree_in_use "$wt"; then
            echo "WARN clean-garden: $br could not be safely removed (likely in use by a live process) — skipped ($wt); $WORKTREE_INUSE_DETAIL" >&2
            SKIPPED=$((SKIPPED+1))
            continue
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
            # HIMMEL-2227 — never report a removal outcome without LOOKING. A
            # refusal git makes up front leaves the tree whole; a failure
            # part-way through (only reachable via --force here, since a
            # plain remove already refuses up front on real dirt) leaves a
            # gutted tree that still answers `git ls-files` with confident
            # zeroes.
            if worktree_intact "$PRIMARY_WORKTREE" "$wt"; then
                echo "ERR clean-garden: failed to remove worktree $wt (re-dirtied? locked?) — git refused the removal; the worktree is still registered with its .git link present. Run with --verbose to investigate." >&2
            else
                echo "ERR clean-garden: removal of worktree $wt FAILED PARTWAY — the tree may be GUTTED (its .git link and/or its 'git worktree list' entry is gone). Do NOT trust anything measured inside it: git commands there report an empty repo. Recover from the primary checkout, in order: 1) git -C '$PRIMARY_WORKTREE' worktree prune  2) make sure '$wt' is empty or removed -- 'git worktree add' refuses a non-empty destination, and remnants can survive exactly this partial-remove case  3) git -C '$PRIMARY_WORKTREE' worktree add '$wt' '$br'" >&2
            fi
            FAILED=$((FAILED+1))
        fi
    done
    echo "clean-garden: prune summary — $PRUNED pruned, $PARTIAL partial, $SKIPPED skipped, $FAILED failed"

    STRAY_HOME="$PRIMARY_WORKTREE/.claude/worktrees"
    if [ -d "$STRAY_HOME" ]; then
        STRAY_FOUND=0
        STRAY_SWEPT=0
        STRAY_FAILED=0
        STRAY_REFUSED=0
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

            # HIMMEL-1692 — this is the one unconditional `rm -rf` in the
            # script, so classify before destroying. A husk here can be a
            # REAL worktree whose admin record died mid-`git worktree remove`
            # (see the ERR path above — "failed to remove worktree" — that
            # leaves exactly this shape: directory present, `git worktree
            # list` blind to it; unguarded, this loop would have destroyed it
            # 24h later). Reuse classify_worktree/checkpoint_worktree rather
            # than re-deriving worktree state here.
            #
            # HIMMEL-2267 — but classify_worktree only describes THIS directory
            # when it IS one. On a plain leftover directory (no .git of its own)
            # `git -C` does not fail: it walks UP to the enclosing checkout and
            # answers about the PARENT's working tree, so the husk inherited the
            # parent's verdict. Wherever `.claude/worktrees` is not gitignored —
            # any adopter clone whose .gitignore lacks the entry — a husk's own
            # contents then read back as "forgotten <path>" and the sweep
            # refused them forever. Settle "is this a worktree at all" FIRST;
            # only a real one is worth classifying. MSYS TRAP: `-e
            # "$stray_dir/.git"` can resolve `.git.exe` and other surprises
            # under Git-Bash; `find -maxdepth 1 -name .git` is the reliable
            # presence check.
            #
            # HIMMEL-2267 — this presence check must distinguish find FAILING
            # (permissions, a transient I/O error, an exotic path) from find
            # RUNNING and finding no .git: `2>/dev/null` on an emptiness test
            # alone makes both look like "no .git", which fails OPEN into the
            # unconditional `rm -rf` below. Capture find's own exit status; on
            # failure we cannot prove this ISN'T a worktree, so route to the
            # existing "scanfail" verdict (below), which already refuses to
            # sweep rather than guess.
            if stray_git_marker=$(find "$stray_dir" -maxdepth 1 -name .git 2>/dev/null); then  # gnu-ok: Git-Bash can resolve a Bash `-e "$stray_dir/.git"` test to .git.exe (see comment above); -maxdepth is also POSIX-supported by BSD find
                if [ -z "$stray_git_marker" ]; then
                    verdict="nonworktree"
                else
                    verdict=$(classify_worktree "$stray_dir") || verdict="scanfail"
                fi
            else
                # find itself failed — we cannot prove this is NOT a worktree,
                # so fail closed rather than delete something uninspectable.
                # HIMMEL-2267 — distinct from "scanfail" below: this is the
                # presence PROBE failing, before we even know whether a .git
                # exists, so it gets its own verdict and message rather than
                # being blamed on classify_worktree/git.
                verdict="probefail"
            fi
            case "$verdict" in
                nonworktree)
                    # No .git at all — a plain leftover directory, never a
                    # worktree, so there is no uncommitted work to preserve.
                    log "  stray-sweep plain leftover directory (no .git): $stray_dir"
                    ;;
                tracked|"forgotten "*)
                    checkpoint_worktree "$stray_dir" "(husk) $(basename "$stray_dir")" || true
                    echo "WARN clean-garden: stray husk has uncommitted work ($verdict) — refusing to sweep $stray_dir" >&2
                    STRAY_REFUSED=$((STRAY_REFUSED+1))
                    continue
                    ;;
                probefail)
                    # The .git presence check itself failed (permissions, a
                    # transient I/O error, an exotic path) — we never even
                    # learned whether $stray_dir has a .git, so it is unknown
                    # whether this is a worktree at all. Fail closed rather
                    # than assume it's safe.
                    echo "WARN clean-garden: stray husk's .git presence check could not be completed (unknown whether it is a worktree) — refusing to sweep $stray_dir (inspect by hand, then rm -rf it yourself once satisfied)" >&2
                    STRAY_REFUSED=$((STRAY_REFUSED+1))
                    continue
                    ;;
                scanfail)
                    # The presence check above already peeled off the no-.git
                    # case as "nonworktree", so reaching here means $stray_dir
                    # DOES have a .git — but classify_worktree's own git
                    # status/ls-files call still failed to read it. Fail
                    # closed on the evidence that it WAS a worktree rather
                    # than assume it's safe.
                    echo "WARN clean-garden: stray husk looks like a broken/orphaned worktree whose contents git could not inspect — refusing to sweep $stray_dir (inspect by hand, then rm -rf it yourself once satisfied)" >&2
                    STRAY_REFUSED=$((STRAY_REFUSED+1))
                    continue
                    ;;
                clean|"strays "*)
                    : ;;   # the two known-disposable verdicts — sweep below
                *)
                    # Unknown verdict. classify_worktree's vocabulary is closed
                    # today, so this is unreachable — which is exactly why it
                    # must be explicit: the arm below this case is an
                    # unconditional `rm -rf`, so a verdict added later without
                    # updating this switch would silently DEFAULT TO DELETING.
                    # Fail closed, matching the prune loop's own `*)` skip.
                    echo "WARN clean-garden: stray husk got an unrecognized classify verdict ('$verdict') — refusing to sweep $stray_dir (fail-closed; teach this case statement the new verdict)" >&2
                    STRAY_REFUSED=$((STRAY_REFUSED+1))
                    continue
                    ;;
            esac
            # verdict is "nonworktree", "clean", or "strays ..." — safe to
            # sweep.

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
            echo "clean-garden: stray-sweep — $STRAY_SWEPT swept, $STRAY_FAILED failed, $STRAY_REFUSED refused ($STRAY_SIZE reclaimed)"
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
    # HIMMEL-1970: name the second population. These four counters come from
    # report_remote_orphans (refs/remotes/*), NOT from the kept worktrees — a
    # bare "N MERGED-CLEAN" next to "N kept worktrees" was read as "N merged
    # worktrees were kept but not pruned", which the prune loop never said.
    echo "clean-garden: accounting summary — $LOCAL_KEPT kept worktrees; remote branches: $REMOTE_MERGED_CLEAN MERGED-CLEAN, $REMOTE_TIP_DIFFERS TIP-DIFFERS, $REMOTE_CLOSED_UNMERGED CLOSED-UNMERGED, $REMOTE_NO_PR NO-PR"
    ACCOUNTING_UNKNOWN=$((LOCAL_UNKNOWN + REMOTE_UNKNOWN))
    if [ "$ACCOUNTING_UNKNOWN" -gt 0 ] || [ "$REMOTE_TIP_DIFFERS" -gt 0 ] || [ "$REMOTE_NO_PR" -gt 0 ]; then
        echo "ALERT clean-garden: attention required — $ACCOUNTING_UNKNOWN UNKNOWN, $REMOTE_TIP_DIFFERS TIP-DIFFERS, $REMOTE_NO_PR NO-PR (the last two count remote branches, not worktrees)"
    fi

    # HIMMEL-2070 — report-only: which LOCAL BRANCHES (not just kept
    # worktrees) are ahead of main with no PR at all. This is the gap the
    # prune loop above never covers: it only drops a branch whose PR already
    # MERGED, so a squash-merged branch under a DIFFERENT head (a squash
    # rewrites the patch-id — the accounting above is blind to it), or one
    # that never got a PR opened, is invisible to it by design. Delegates
    # entirely to scripts/unlanded-work.sh's classification; never re-derives
    # it here. Read-only: prints DROP commands for the one class that is safe
    # to force through — it never runs them, and never touches a worktree
    # with uncommitted changes itself (unlanded-work.sh never touches a
    # worktree at all).
    report_unlanded_work() {
        local script="$PRIMARY_WORKTREE/scripts/unlanded-work.sh"
        [ -f "$script" ] || return 0
        echo "clean-garden: full accounting — unlanded local work (never a PR)"
        # Capture stderr separately and cd into PRIMARY_WORKTREE first
        # (codex-3/codex-4, HIMMEL-2070 CR round 2): unlanded-work.sh always
        # exits 0 by contract even on a scan failure (an unresolvable
        # --base), writing the diagnostic to stderr instead — a discarded
        # stderr made a failed scan print the same all-zero accounting as a
        # genuinely clean repo. The explicit cd (rather than trusting
        # whatever cwd this function happened to be called from) guarantees
        # the detector resolves ITS repo as this checkout, not wherever the
        # caller's shell cwd is.
        local stderr_tmp; stderr_tmp="$(mktemp)"
        local tsv; tsv="$(cd "$PRIMARY_WORKTREE" && bash "$script" --tsv 2>"$stderr_tmp")"
        local scan_stderr; scan_stderr="$(cat "$stderr_tmp" 2>/dev/null)"; rm -f "$stderr_tmp"
        if [ -z "$tsv" ] && [ -n "$scan_stderr" ]; then
            echo "  scan unavailable: $(printf '%s' "$scan_stderr" | head -1)"
            return 0
        fi
        local n_landed n_stale n_unlanded
        n_landed="$(printf '%s\n' "$tsv" | awk -F'\t' '$1=="LANDED-ELSEWHERE"' | grep -c . || true)"
        n_stale="$(printf '%s\n' "$tsv" | awk -F'\t' '$1=="STALE"' | grep -c . || true)"
        n_unlanded="$(printf '%s\n' "$tsv" | awk -F'\t' '$1=="UNLANDED-LIVE"' | grep -c . || true)"
        echo "  LANDED-ELSEWHERE=${n_landed:-0} (safe to drop)  STALE=${n_stale:-0} (review before dropping)  UNLANDED-LIVE=${n_unlanded:-0} (never opened as a PR)"
        if [ "${n_landed:-0}" -gt 0 ]; then
            echo "  LANDED-ELSEWHERE drop commands:"
            printf '%s\n' "$tsv" | awk -F'\t' '$1=="LANDED-ELSEWHERE"' | while IFS="$(printf '\t')" read -r _ branch _ _ _ _ wt; do
                [ -n "$branch" ] || continue
                # %q, not a double-quoted %s (codex-5, HIMMEL-2070 CR round 2):
                # a git ref name may legally contain "$(...)"/backticks/quotes,
                # which a double-quoted printed command does not neutralize.
                # No --force (codex-2, HIMMEL-2070 CR round 3) -- matches
                # this script's own documented policy above ("this command
                # never uses `git worktree remove --force`"). Plain `git
                # worktree remove` already refuses on any uncommitted or
                # untracked change, which is the safety check --force exists
                # to bypass; advertising --force by default in a "safe to
                # drop" command could discard real uncommitted work.
                [ -n "$wt" ] && printf '    git worktree remove %q\n' "$wt"
                printf '    git branch -D %q\n' "$branch"
            done
        fi
        if [ "${n_stale:-0}" -gt 0 ]; then
            echo "  STALE: no ready-to-run destructive command here on purpose — a STALE branch may carry never-landed work that merely no longer applies against main; review by hand (bash scripts/unlanded-work.sh --class STALE)."
        fi
    }
    report_unlanded_work
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
#
# checkpoint_worktree (HIMMEL-1692) writes into this SAME refs/checkpoints/
# namespace when the prune loop refuses a dirty worktree, so those autosave
# refs age out under this same TTL sweep — no separate lifecycle needed.
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
