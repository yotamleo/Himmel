#!/usr/bin/env bash
# repo-sync-runner.sh — the payload for the daily repo-sync cadence
# (HIMMEL-2115). Enumerates every git repo under the operator's host roots,
# fetches each, and fast-forward-only pulls the DEFAULT branch when it is
# safe to do so. NEVER merges/rebases/resolves — anything not safely
# fast-forwardable is recorded as a failure and left untouched.
#
# WHY A SEPARATE RUNNER (mirrors graphmap-cadence's refresh-graph-map.sh /
# ast-update.sh split, not ggs-cadence's inline-.bat shape): this payload is
# real per-repo branching logic (enumerate, dirty/branch checks, ff-only
# merge) that is not reasonably expressible as generated .bat lines. The
# cadence emitter (repo-sync-cadence.sh) fires this script by absolute path
# and does nothing else — same split as graphmap-cadence's structural/
# semantic legs.
#
# LEDGER PATTERN (mirrors scripts/codex/dispatch-codex-exec.sh, HIMMEL-2023):
# this script sources scripts/lib/flow-run-ledger.sh directly and writes its
# own start/end rows (flow "repo-sync") — unlike ggs-cadence, where the .bat
# owns the ledger calls because the payload there is a non-bash .exe. A bash
# runner can call the lib in-process, so the ledger write lives HERE, once,
# not duplicated into the generated runner text.
#
# RC-PRESERVING (2048 pattern, HIMMEL-2048): exits 0 only when every
# processed repo either pulled cleanly or was benignly skipped (dirty,
# non-default branch, single-writer, undetermined default branch). Exits 1
# when ANY repo hit a real failure (fetch failed, or the default branch is
# not fast-forwardable from HEAD — diverged). Never an unconditional exit 0.
#
# Per-repo classification (see classify_repo()):
#   pulled       ff-only merge succeeded                             ok=true
#   fetch-only   skipped the merge for a BENIGN reason (single-writer
#                marker, non-default/detached branch, dirty worktree,
#                default branch undeterminable)                      ok=true
#   failed       fetch itself failed, OR the default branch is not
#                fast-forwardable from HEAD (diverged/non-ff)         ok=false
# Bare repos and anything under a .claude/worktrees path are EXCLUDED from
# enumeration entirely (never fetched, never rowed) — see enumerate_repos().
#
# STALE-WT CLEANUP PASS (HIMMEL-2116, follow-up to HIMMEL-2115): a repo
# already enumerated below (has a `.git` entry) is routed to
# classify_wt_candidate() INSTEAD OF classify_repo() when it looks like a
# scratch worktree folder made by some other harness/tool outside the
# managed .claude/worktrees tree (already excluded from enumeration
# entirely, see _is_excluded_name) -- either a linked-worktree checkout
# (`.git` is a FILE, not a dir) or a directory literally named `wt-*`. These
# folders get a DIFFERENT, stricter safety gate than the sync pass (dirty --
# including gitignored files, not just tracked changes -- is an ALERT here,
# not a benign skip; see classify_wt_candidate) and are never fetched/
# ff-pulled by the sync pass. AUTO-DELETION requires ALL of: clean (tracked
# AND ignored), fully pushed (a configured upstream with zero commits
# ahead), stale beyond --wt-stale-days (default 14, via the folder's mtime),
# AND being a genuine linked worktree (`.git` is a FILE) -- a wt-*-NAMED but
# otherwise ordinary standalone clone (`.git` is a DIR) that clears every
# other gate is still only ALERTED, never silently rm -rf'd by name
# coincidence alone. Anything short of that is an ALERT row, same
# salvage-first discipline as the sync pass's own failure rows -- and folds
# into the SAME run's outcome/exit code (an alerted wt folder counts as a
# failure for this run, exactly like a
# diverged repo does).
#
# Usage:
#   bash repo-sync-runner.sh [--github-root <path>] [--documents-root <path>]
#       [--results-file <path>] [--task-name <name>] [--wt-stale-days <N>]
#
# Test seams:
#   HIMMEL_FLOW_RUNS_LEDGER  ledger path override (flow-run-ledger.sh's own
#                            var). Every run writes a start/end ledger row
#                            UNCONDITIONALLY; an ad hoc manual/repro
#                            invocation that skips this override writes to
#                            the live ~/.himmel/flow-runs.jsonl and can page
#                            the real HimmelFlowRunError alert on a
#                            deliberately-broken test fixture. Always set it
#                            to a scratch path outside the armed cadence.
#   REPO_SYNC_REMOTE         remote name to operate on (default: origin)
#
# Exit codes:
#   0  every processed repo pulled or was benignly skipped
#   1  at least one repo failed (fetch failure or diverged/non-ff)
#   2  usage / env error (bad flag, no roots exist)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE="${REPO_SYNC_REMOTE:-origin}"

# shellcheck source=../lib/flow-run-ledger.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/flow-run-ledger.sh"

resolve_user_home() {
    if [ -n "${USERPROFILE:-}" ] && command -v cygpath >/dev/null 2>&1; then
        cygpath -u "$USERPROFILE" 2>/dev/null || printf '%s' "$USERPROFILE"
    else
        printf '%s' "${HOME:-${USERPROFILE:-/tmp}}"
    fi
}

GITHUB_ROOT=""
DOCUMENTS_ROOT=""
RESULTS_FILE=""
TASK_NAME=""
WT_STALE_DAYS=""

usage() {
    cat <<'EOF'
Usage: repo-sync-runner.sh [flags]

Flags:
  --github-root <path>     Root scanned FULLY/recursively for git repos
                            (default: <home>/Documents/github)
  --documents-root <path>  Root scanned to depth 2 for git repos, excluding
                            the github-root subtree (default: <home>/Documents)
  --results-file <path>    Per-repo JSONL results file (default:
                            <home>/.claude/repo-sync-cadence/repo-sync-results.jsonl)
  --task-name <name>       Recorded in the ledger start row's task_name field
  --wt-stale-days <N>      Stale-wt-cleanup threshold in days (default: 14)
EOF
}

_require_value() {
    if [ $# -lt 2 ]; then
        echo "ERR repo-sync-runner: $1 requires a value" >&2
        usage >&2
        exit 2
    fi
}

while [ $# -gt 0 ]; do
    case "$1" in
        --github-root)    _require_value "$@"; GITHUB_ROOT="$2"; shift 2 ;;
        --github-root=*)  GITHUB_ROOT="${1#--github-root=}"; shift ;;
        --documents-root)   _require_value "$@"; DOCUMENTS_ROOT="$2"; shift 2 ;;
        --documents-root=*) DOCUMENTS_ROOT="${1#--documents-root=}"; shift ;;
        --results-file)   _require_value "$@"; RESULTS_FILE="$2"; shift 2 ;;
        --results-file=*) RESULTS_FILE="${1#--results-file=}"; shift ;;
        --task-name)      _require_value "$@"; TASK_NAME="$2"; shift 2 ;;
        --task-name=*)    TASK_NAME="${1#--task-name=}"; shift ;;
        --wt-stale-days)   _require_value "$@"; WT_STALE_DAYS="$2"; shift 2 ;;
        --wt-stale-days=*) WT_STALE_DAYS="${1#--wt-stale-days=}"; shift ;;
        -h|--help)        usage; exit 0 ;;
        *)
            echo "ERR repo-sync-runner: unknown arg: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

[ -n "$GITHUB_ROOT" ] || GITHUB_ROOT="$(resolve_user_home)/Documents/github"
[ -n "$DOCUMENTS_ROOT" ] || DOCUMENTS_ROOT="$(resolve_user_home)/Documents"
[ -n "$RESULTS_FILE" ] || RESULTS_FILE="$(resolve_user_home)/.claude/repo-sync-cadence/repo-sync-results.jsonl"
[ -n "$WT_STALE_DAYS" ] || WT_STALE_DAYS=14

if [ ! -d "$DOCUMENTS_ROOT" ]; then
    echo "ERR repo-sync-runner: --documents-root is not a directory: $DOCUMENTS_ROOT" >&2
    exit 2
fi
# 6-digit cap (max 999999 days, ~2739 years) rejected via a STRING-length
# glob, never a numeric comparison: an arbitrarily long all-digit string
# would make `[ "$age_days" -lt "$WT_STALE_DAYS" ]` in
# classify_wt_candidate itself throw an integer-range error, and that test
# sits inside an `if`, so under `set -e` the error is swallowed as "false"
# and falls through to the DELETE branch instead of "not stale" (codex-2,
# HIMMEL-2116 pr-check round-2 panel) -- reject the pathological input here,
# before it ever reaches that comparison.
case "$WT_STALE_DAYS" in
    ''|*[!0-9]*)
        echo "ERR repo-sync-runner: --wt-stale-days must be a non-negative integer, got: $WT_STALE_DAYS" >&2
        exit 2
        ;;
    ???????*)
        echo "ERR repo-sync-runner: --wt-stale-days is unreasonably large (max 6 digits), got: $WT_STALE_DAYS" >&2
        exit 2
        ;;
esac

# --- enumeration -------------------------------------------------------

# _canon <path> — best-effort canonical absolute path for dedup/exclusion
# comparisons. Falls back to the input unchanged (bash 3.2-safe, no reliance
# on GNU realpath being present).
_canon() {
    ( cd "$1" 2>/dev/null && pwd ) || printf '%s' "$1"
}

# _is_excluded <dir-basename> — directories never worth descending into.
# Excludes ANY directory literally named `.claude`, not only `.claude/
# worktrees` — deliberately broader, as defense-in-depth against ever
# recursing into a repo's own tooling directory (worktrees managed by
# clean-garden.sh are never this cadence's business either way; in the
# worktrees case specifically this check is unreachable in practice, since
# _scan_dir already prunes at the repo boundary above it). Also excludes
# `node_modules` (never contains a repo of ours, and can be pathologically
# deep/large under an unbounded github scan).
_is_excluded_name() {
    case "$1" in
        .claude|node_modules) return 0 ;;
        *) return 1 ;;
    esac
}

# _is_bare <repo> — true when git reports the repo as bare (no working tree,
# so "ff-only pull" is meaningless; excluded from enumeration entirely).
_is_bare() {
    [ "$(git -C "$1" rev-parse --is-bare-repository 2>/dev/null)" = "true" ]
}

# _looks_bare_shaped <dir> — cheap filesystem-only pre-filter (no git
# subprocess) for "plausibly a bare repo": a bare repo has no nested .git
# entry (unlike a normal checkout or a linked worktree), so _scan_dir's
# `[ -e "$dir/.git" ]` gate never fires for one and — without this check —
# it falls through to being recursed into like an ordinary directory,
# scanning its entire object database (codex CR round 4). Only directories
# that pass this cheap check pay for the _is_bare git subprocess call below;
# every other directory (the overwhelming majority of a github-root scan)
# never shells out to git just to learn it isn't a repo.
_looks_bare_shaped() {
    [ -f "$1/HEAD" ] && [ -d "$1/objects" ] && [ -d "$1/refs" ]
}

# _scan_dir <dir> <remaining-depth> <exclude-canon...>
# Recursive repo finder with TRUE pruning: the instant a directory carries a
# `.git` entry (dir or file — a file covers a linked worktree checkout) it is
# emitted as a repo root and its subtree is never descended into again (a
# repo's own internals — including any nested .claude/worktrees or a vendored
# submodule's .git — never produce a second, false-positive "repo"). Bare
# repos are excluded at the point of discovery. <remaining-depth> is levels
# left to descend (-1 = unlimited, matching the "github fully" root; 0 means
# "check this dir only, do not descend"). <exclude-canon...> are canonical
# paths to prune outright (e.g. the github root, already covered separately).
_scan_dir() {
    local dir="$1" depth="$2"
    shift 2
    local exclude_canon=("$@")
    local canon ex base sub next_depth
    canon="$(_canon "$dir")"
    for ex in "${exclude_canon[@]+"${exclude_canon[@]}"}"; do
        [ -n "$ex" ] || continue
        case "$canon" in "$ex"|"$ex"/*) return 0 ;; esac
    done
    base="$(basename "$canon")"
    _is_excluded_name "$base" && return 0

    if [ -e "$dir/.git" ]; then
        _is_bare "$dir" && return 0
        printf '%s\n' "$canon"
        return 0
    fi
    # A bare repo has no nested .git (its own root IS the git dir), so it
    # never matches the check above — catch it here instead, before
    # recursing into what would otherwise look like an ordinary directory
    # tree (its objects/refs internals).
    _looks_bare_shaped "$dir" && _is_bare "$dir" && return 0
    [ "$depth" -eq 0 ] && return 0

    next_depth=$depth
    [ "$depth" -gt 0 ] && next_depth=$((depth - 1))
    # Capture find's own rc via plain command substitution (no pipe inside
    # it, so $? is find's, not sort's) -- the old `find ... | sort` piped
    # straight into the while-read process substitution, so a `find`
    # failure (permission denied on a nested dir, the dir vanishing
    # mid-scan) was silently discarded: no error surfaced, and any repos
    # under the unreadable subtree were never enumerated while the run still
    # reported success (codex-2, HIMMEL-2115 pr-check panel). gnu-ok:
    # -mindepth/-maxdepth are also standard BSD find (macOS) flags, not
    # GNU-only.
    # set +e / set -e bracket (matches this file's other rc-capturing calls,
    # e.g. the fetch/ls-remote/status calls in classify_repo below): a bare
    # `find_out=$(find ...)` assignment IS subject to this script's
    # `set -e` (codex-1, HIMMEL-2115 pr-check round-9 panel) -- unlike the
    # process-substitution form this replaced, a failing `find` here would
    # abort the ENTIRE runner mid-scan before `find_rc=$?` on the next line
    # even ran, turning the original silent-repo-loss bug into a full crash
    # on the very first permission-denied subdirectory anywhere in the tree.
    local find_out find_rc=0
    set +e
    find_out=$(find "$dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
    find_rc=$?
    set -e
    if [ "$find_rc" -ne 0 ]; then
        echo "WARN repo-sync-runner: 'find' failed (rc=$find_rc) scanning $dir -- repos under this directory may be silently missing from this run" >&2
        # Marker file, not a variable: this call may be running inside the
        # caller's `<(...)` process substitution subshell, where a plain
        # variable write never reaches the parent (codex-1, HIMMEL-2115
        # pr-check round-10 panel) -- the parent checks for this file's
        # existence after enumeration to fold the failure into the run's
        # outcome/exit code instead of leaving it a stderr-only signal.
        [ -n "${_rs_find_fail_marker:-}" ] && : >> "$_rs_find_fail_marker" 2>/dev/null
    fi
    if [ -n "$find_out" ]; then
        while IFS= read -r sub; do
            _scan_dir "$sub" "$next_depth" "${exclude_canon[@]+"${exclude_canon[@]}"}"
        done < <(printf '%s\n' "$find_out" | sort)
    fi
}

# enumerate_repos <root> <depth> <exclude-canon...> — public entry point;
# see _scan_dir for the depth/exclusion contract.
enumerate_repos() {
    local root="$1" depth="$2"
    shift 2
    _scan_dir "$root" "$depth" "$@"
}

# --- per-repo classification --------------------------------------------

# classify_repo <repo> — sets globals RS_ACTION, RS_OK, RS_BRANCH,
# RS_DEFAULT_BRANCH, RS_REASON. Never mutates the working tree beyond a
# `git fetch` and a `git merge --ff-only` (which itself refuses to touch
# anything it cannot fast-forward).
RS_ACTION=""
RS_OK=""
RS_BRANCH=""
RS_DEFAULT_BRANCH=""
RS_REASON=""

classify_repo() {
    local repo="$1" out rc default_branch branch

    RS_ACTION=""; RS_OK=""; RS_BRANCH=""; RS_DEFAULT_BRANCH=""; RS_REASON=""

    set +e
    out=$(git -C "$repo" fetch --quiet "$REMOTE" 2>&1)
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        RS_ACTION="failed"; RS_OK="false"
        RS_REASON="fetch failed: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
        return 0
    fi

    branch=$(git -C "$repo" symbolic-ref --short -q HEAD 2>/dev/null || true)
    RS_BRANCH="$branch"

    # Single-writer marker (CLAUDE.md convention): a repo carrying this file
    # commits straight to main by design (an auto-committer may write to it
    # at any moment) — never attempt an integrating merge, fetch-only always,
    # regardless of clean/branch state.
    if [ -f "$repo/.single-writer" ]; then
        RS_ACTION="fetch-only"; RS_OK="true"; RS_REASON="single-writer marker present"
        return 0
    fi

    # ls-remote's own command failure (auth/network/etc.) is a real git
    # failure per this cadence's "any git failure -> SKIP + ALERT" contract
    # -- distinct from ls-remote SUCCEEDING but returning no matching HEAD
    # symref line (a benign, differently-configured-remote case). Capture
    # stdout+stderr together and check rc BEFORE parsing, so the two cases
    # classify differently instead of both collapsing into "could not
    # determine the default branch" (codex CR round 6).
    set +e
    ls_remote_raw=$(git -C "$repo" ls-remote --symref "$REMOTE" HEAD 2>&1)
    ls_remote_rc=$?
    set -e
    if [ "$ls_remote_rc" -ne 0 ]; then
        RS_ACTION="failed"; RS_OK="false"
        RS_REASON="ls-remote failed: $(printf '%s' "$ls_remote_raw" | tr '\n' ' ' | cut -c1-200)"
        return 0
    fi
    default_branch=$(printf '%s\n' "$ls_remote_raw" | sed -n 's#^ref: refs/heads/\(.*\)\tHEAD$#\1#p' | head -1)
    RS_DEFAULT_BRANCH="$default_branch"
    if [ -z "$default_branch" ]; then
        RS_ACTION="fetch-only"; RS_OK="true"; RS_REASON="could not determine the remote's default branch"
        return 0
    fi

    if [ -z "$branch" ]; then
        RS_ACTION="fetch-only"; RS_OK="true"; RS_REASON="detached HEAD"
        return 0
    fi
    if [ "$branch" != "$default_branch" ]; then
        RS_ACTION="fetch-only"; RS_OK="true"
        RS_REASON="checked out on '$branch', not the default branch '$default_branch'"
        return 0
    fi

    set +e
    out=$(git -C "$repo" status --porcelain 2>&1)
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        RS_ACTION="failed"; RS_OK="false"
        RS_REASON="could not verify worktree cleanliness: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
        return 0
    fi
    if [ -n "$out" ]; then
        RS_ACTION="fetch-only"; RS_OK="true"; RS_REASON="worktree is dirty"
        return 0
    fi

    # ff-only integration. NEVER merge/rebase/resolve: --ff-only refuses and
    # leaves the tree untouched the instant a real merge would be needed.
    set +e
    out=$(git -C "$repo" merge --ff-only "$REMOTE/$default_branch" 2>&1)
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        RS_ACTION="failed"; RS_OK="false"
        RS_REASON="not fast-forwardable (diverged): $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
        return 0
    fi
    RS_ACTION="pulled"; RS_OK="true"; RS_REASON="fast-forwarded to $REMOTE/$default_branch"
}

# --- stale-wt cleanup (HIMMEL-2116) ---------------------------------------

# _is_wt_candidate <repo> — true when a repo already found by enumeration
# looks like a scratch worktree folder rather than a real sync target: a
# linked-worktree checkout (`.git` is a regular FILE, not a directory) or a
# directory literally named `wt-*`. Routed to classify_wt_candidate instead
# of classify_repo — never both.
_is_wt_candidate() {
    local repo="$1" base
    [ -f "$repo/.git" ] && return 0
    base="$(basename "$repo")"
    case "$base" in wt-*) return 0 ;; esac
    return 1
}

# classify_wt_candidate <repo> — sets globals WT_ACTION (deleted|alert|skip),
# WT_OK, WT_REASON. NEVER touches the filesystem itself (the caller deletes
# on WT_ACTION=deleted) -- purely diagnostic, same split as classify_repo.
#
# Safety gate (salvage-first, stricter than the sync pass's benign-skip
# discipline -- dirty/unpushed/unique-branch are ALERTs here, not skips):
#   dirty worktree                          -> alert
#   detached HEAD / no upstream branch      -> alert (can't confirm pushed)
#   upstream configured but commits ahead   -> alert (unpushed commits)
#   clean + fully pushed but not yet stale  -> skip
#   clean + fully pushed + stale            -> deleted
WT_ACTION=""
WT_OK=""
WT_REASON=""

classify_wt_candidate() {
    local repo="$1" out rc branch upstream_remote remote_match upstream ahead mtime now age_days lock_path

    WT_ACTION=""; WT_OK=""; WT_REASON=""

    # A `git worktree lock`ed folder is an explicit "do not touch" signal --
    # checked FIRST, before any other gate, and never overridden by clean/
    # pushed/stale (codex-3, HIMMEL-2116 pr-check round-4 panel): a raw
    # `rm -rf` later in this function has no awareness of the lock at all
    # (only `git worktree remove` respects it), so this must be caught here.
    # Only linked worktrees (.git is a FILE) can carry a lock file.
    if [ -f "$repo/.git" ]; then
        lock_path=$(git -C "$repo" rev-parse --git-path locked 2>/dev/null || true)
        if [ -n "$lock_path" ] && [ -f "$lock_path" ]; then
            WT_ACTION="alert"; WT_OK="false"
            WT_REASON="worktree is explicitly locked (git worktree lock) -- never auto-deleted regardless of other gates"
            return 0
        fi
    fi

    # --ignored (unlike classify_repo's plain --porcelain): this function's
    # clean folders get `rm -rf`ed, so a gitignored-but-real file (a local
    # .env, a build artifact, a local DB) must count as dirty here, or it is
    # silently destroyed with no git history to recover it from (codex-2,
    # HIMMEL-2116 pr-check panel round 1). --untracked-files=all: an
    # explicit CLI flag, so it overrides a local `status.showUntrackedFiles`
    # config that would otherwise silently hide untracked (non-ignored)
    # content from plain --porcelain (codex-1, round 4 panel) -- without it,
    # a repo configured that way could read as clean while carrying
    # untracked data.
    set +e
    out=$(git -C "$repo" status --porcelain --ignored --untracked-files=all 2>&1)
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        WT_ACTION="alert"; WT_OK="false"
        WT_REASON="could not verify worktree cleanliness: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
        return 0
    fi
    if [ -n "$out" ]; then
        WT_ACTION="alert"; WT_OK="false"; WT_REASON="worktree is dirty (tracked or ignored changes present)"
        return 0
    fi

    branch=$(git -C "$repo" symbolic-ref --short -q HEAD 2>/dev/null || true)
    if [ -z "$branch" ]; then
        WT_ACTION="alert"; WT_OK="false"
        WT_REASON="detached HEAD (cannot verify the checked-out commit is fully pushed)"
        return 0
    fi

    # Resolve @{u}'s OWN remote -- NOT the fixed $REMOTE -- before refreshing
    # anything (HIMMEL-2208, codex-4 round-5 / codex-2+4 rounds 3-4 pr-check
    # panels): a branch tracking a DIFFERENT remote than $REMOTE (default
    # origin) never got that remote's tracking ref refreshed by a fetch
    # scoped to $REMOTE, so a deleted/rewritten branch on the OTHER remote
    # could still read ahead=0 below and wrongly clear this gate.
    upstream_remote=$(git -C "$repo" for-each-ref --format='%(upstream:remotename)' "refs/heads/$branch" 2>/dev/null)
    # Assert the resolved remotename is an ACTUAL configured remote, rather
    # than denylisting the values that aren't (HIMMEL-2208 review): empty (no
    # upstream at all) and "." (a LOCAL-branch upstream -- git's own
    # convention for branch.<name>.remote) are the two known cases, but
    # branch.<name>.remote also accepts a bare URL -- an allowlist covers
    # every such case in one check instead of enumerating them one at a time.
    # Capture the full `git remote` list rather than `| grep -q` (known-
    # findings grep-q-pipe-under-pipefail): under this file's `set -o
    # pipefail`, `grep -q` exits on the first match and can SIGPIPE the
    # producer, flipping the pipeline's exit status on some inputs.
    remote_match=$(git -C "$repo" remote | grep -xF "$upstream_remote" 2>/dev/null) || true
    if [ -z "$upstream_remote" ] || [ -z "$remote_match" ]; then
        WT_ACTION="alert"; WT_OK="false"
        WT_REASON="branch '$branch' has no upstream tracking a real configured remote (unique branch or local-only upstream, not confirmed pushed anywhere)"
        return 0
    fi

    # Refresh the remote-tracking ref BEFORE trusting it for "fully pushed"
    # (codex-1, HIMMEL-2116 pr-check round-3 panel): without a fetch here,
    # a stale local @{u} can show ahead=0 for a branch the remote no longer
    # has (deleted or force-pushed away since the last fetch), wrongly
    # clearing this gate. --prune so a DELETED remote branch's stale
    # tracking ref is actually removed (not just left pointing at its last-
    # known commit) -- without --prune, @{u} would still resolve and still
    # read ahead=0, defeating the point of fetching at all. Fetches
    # $upstream_remote (the branch's OWN configured remote, HIMMEL-2208),
    # not the fixed $REMOTE, for the same reason. A fetch failure is itself
    # an alert -- never silently trust a possibly-stale cache for a
    # deletion decision.
    set +e
    out=$(git -C "$repo" fetch --quiet --prune "$upstream_remote" 2>&1)
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        WT_ACTION="alert"; WT_OK="false"
        WT_REASON="fetch failed, cannot verify fully-pushed status: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
        return 0
    fi

    set +e
    upstream=$(git -C "$repo" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)
    set -e
    if [ -z "$upstream" ]; then
        WT_ACTION="alert"; WT_OK="false"
        WT_REASON="branch '$branch' has no upstream tracking branch (unique branch, not confirmed on any remote)"
        return 0
    fi

    set +e
    ahead=$(git -C "$repo" rev-list --count "${upstream}..HEAD" 2>&1)
    rc=$?
    set -e
    case "$ahead" in
        ''|*[!0-9]*) rc=1 ;;
    esac
    if [ "$rc" -ne 0 ]; then
        WT_ACTION="alert"; WT_OK="false"
        WT_REASON="could not determine whether branch '$branch' is fully pushed vs $upstream"
        return 0
    fi
    if [ "$ahead" -ne 0 ]; then
        WT_ACTION="alert"; WT_OK="false"
        WT_REASON="branch '$branch' has $ahead unpushed commit(s) vs $upstream"
        return 0
    fi

    # mtime is a cheap, imperfect staleness proxy (a commit/push to an
    # existing file need not touch it) -- ponytail: known ceiling, bounded
    # by the other three gates (clean + fully pushed + genuine linked
    # worktree already route an in-use folder to ALERT, not delete).
    # HIMMEL-2203 (follow-up, reviewed and kept as-is): the two literal
    # alternatives don't hold up on inspection -- .git/HEAD only changes on
    # checkout (branch switch), not on a same-branch commit, so it MISSES
    # the exact activity pattern this ticket worries about; the linked
    # worktree's index mtime is self-poisoning here, since the cleanliness
    # check just above (git status --ignored --untracked-files=all)
    # empirically rewrites the index's own mtime on every run even with
    # zero real changes (verified), which would reset the age to ~0 on
    # every fire and make auto-deletion permanently inert. A real fix needs
    # a runner-maintained last-seen timestamp store, independent of
    # git-internal file mtimes -- disproportionate complexity for a
    # not-urgent, already bounded-risk default; upgrade if false-staleness
    # reports become a real problem. GNU `date -r` first (this file's own
    # convention: repo-sync-cadence.sh's status_log uses the identical
    # GNU-then-BSD-stat fallback), then BSD/macOS `stat -f`, then GNU
    # `stat -c` as a last resort -- on BSD/macOS, `date -r` treats its
    # argument as epoch seconds to CONVERT, not a reference file, so
    # without a fallback it silently mis-parses and disables deletion
    # entirely there (codex-4, HIMMEL-2116 pr-check round-4 panel).
    mtime=$(date -r "$repo" +%s 2>/dev/null || stat -f %m "$repo" 2>/dev/null || stat -c %Y "$repo" 2>/dev/null || echo 0)
    now=$(date -u +%s)
    age_days=$(( (now - mtime) / 86400 ))
    if [ "$mtime" -eq 0 ] || [ "$age_days" -lt "$WT_STALE_DAYS" ]; then
        WT_ACTION="skip"; WT_OK="true"
        WT_REASON="clean and fully pushed but not yet stale (${age_days}d < ${WT_STALE_DAYS}d threshold)"
        return 0
    fi

    # Auto-delete only a genuine linked worktree (`.git` is a FILE) -- a
    # wt-*-NAMED but otherwise ordinary standalone clone (`.git` is a DIR)
    # matched on name alone (codex-1, HIMMEL-2116 pr-check panel: an
    # unrelated repo that happens to be named "wt-something" must not be
    # silently rm -rf'd by naming coincidence). It still gets examined and
    # surfaced -- salvage-first via an alert, never silently ignored -- but
    # never auto-deleted; the ticket's own "delete + prune the PARENT repo's
    # worktree registry" wording only makes sense for a linked worktree
    # anyway (a standalone clone has no parent to prune).
    if [ ! -f "$repo/.git" ]; then
        WT_ACTION="alert"; WT_OK="false"
        WT_REASON="clean, fully pushed, and stale, but this is a wt-*-named STANDALONE repo (.git is a directory, not a linked worktree) -- never auto-deleted by name alone; confirm manually"
        return 0
    fi

    WT_ACTION="deleted"; WT_OK="true"
    WT_REASON="clean, fully pushed (branch '$branch' == $upstream), stale ${age_days}d >= ${WT_STALE_DAYS}d threshold"
}

# _wt_reverify_deletable <repo> — cheap TOCTOU guard (HIMMEL-2207): classify_
# wt_candidate's cleanliness AND fully-pushed checks both run well before the
# actual rm -rf in delete_wt_folder; something could commit new work into the
# folder in that window -- a NEW commit makes the worktree CLEAN again, so
# re-checking cleanliness alone is not enough to catch it (codex-1, HIMMEL-
# 2208 pr-check round-2 panel): it would leave unpushed work destroyed while
# reading as a safe delete. Re-checking both immediately before the delete
# narrows -- doesn't eliminate -- that window, without the disproportionate
# complexity of a lock (the ticket's own judgment call: not worth a lock for
# a folder the whole design already expects to be genuinely idle). Re-
# resolves @{u} fresh rather than reusing classify_wt_candidate's (a plain
# local rev-parse/rev-list, no new network fetch -- the window this closes is
# a new LOCAL commit, not remote-side drift, which classify's own fetch
# --prune moments earlier already covers). Same flags as classify_wt_
# candidate's own dirty check (--ignored --untracked-files=all): a
# gitignored file written in the window must still block the delete.
#
# Per-gate enumeration (HIMMEL-2208 pr-check round-3 panel review): the
# delete decision rests on FOUR classify_wt_candidate preconditions -- can
# each flip in the window between classify_wt_candidate returning and the
# actual rm -rf?
#   (1) clean            -- YES, files can appear. Re-checked above.
#   (2) fully pushed      -- YES, a local commit in the window makes the tree
#                            clean again while leaving work unpushed (round-2
#                            finding). Re-checked above (ahead=0 vs a freshly
#                            resolved @{u}).
#   (3) stale (folder mtime) -- NOT independently re-checked. A directory's
#       own mtime only advances when an entry is added/removed directly
#       inside it, never from editing a tracked file's content or from a
#       subdirectory's internal churn (git status rewriting .git/index does
#       NOT touch this repo's own top-level mtime -- same reasoning as the
#       HIMMEL-2203 index-mtime finding on this file). Every way to advance
#       the folder's own mtime in this window is already caught by gate (1)
#       or (2) above: a new/removed top-level entry left uncommitted is
#       dirty (gate 1); committed but not yet pushed is ahead>0 (gate 2);
#       committed AND pushed within the window means the work is already
#       safe on the remote, which is exactly what "clean + fully pushed +
#       stale" exists to safely reclaim. A bare `touch` with no content
#       change bumps neither the folder's mtime nor git status, so it is not
#       real activity to protect against. No path silently escapes gates
#       (1)/(2) here, so re-verifying staleness independently is redundant.
#   (4) genuine linked worktree (.git is a FILE) -- NOT independently
#       re-checked. Flipping it in this window needs deliberate git-
#       internals tampering (git worktree remove + git init, or replacing
#       the .git file by hand) -- outside this ticket's threat model of
#       another process innocently writing into the folder. Even then,
#       delete_wt_folder's own `[ -f "$repo/.git" ]` check just skips the
#       common-dir/parent-prune step and still deletes the folder, identical
#       to how it already handles a standalone repo -- no worse outcome, and
#       no data loss beyond what "clean + fully pushed" already covers.
# Scope: gates (1)/(2) close LOCAL changes made during the window only --
# neither re-fetches, so a REMOTE-side change in the same window (e.g. a
# force-push racing the delete) is out of scope here; that class is
# classify_wt_candidate's own `fetch --prune`, at classification time.
_wt_reverify_deletable() {
    local repo="$1" out rc upstream ahead
    set +e
    out=$(git -C "$repo" status --porcelain --ignored --untracked-files=all 2>/dev/null)
    rc=$?
    set -e
    # A failed status call (repo gone/corrupted/unreadable) must fail CLOSED,
    # not read as clean (codex-1, HIMMEL-2208 pr-check panel): stdout is empty
    # either way, so without the rc check a git-status failure right before
    # the delete would pass this guard.
    if [ "$rc" -ne 0 ] || [ -n "$out" ]; then
        return 1
    fi

    set +e
    upstream=$(git -C "$repo" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)
    set -e
    [ -n "$upstream" ] || return 1

    set +e
    ahead=$(git -C "$repo" rev-list --count "${upstream}..HEAD" 2>&1)
    rc=$?
    set -e
    case "$ahead" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$ahead" -eq 0 ]
}

# delete_wt_folder <repo> — deletes a folder already classified "deleted".
# When it is a linked worktree (`.git` is a file), resolves the parent
# repo's common .git dir BEFORE removing the folder (the gitdir link is
# only readable while the folder exists), then runs `git worktree prune`
# on the parent afterward so its worktree registry doesn't keep pointing at
# a now-missing path.
delete_wt_folder() {
    local repo="$1" common_dir="" parent
    if [ -f "$repo/.git" ]; then
        common_dir=$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null || true)
        case "$common_dir" in
            /*|[A-Za-z]:[/\\]*) : ;;
            *) [ -n "$common_dir" ] && common_dir="$repo/$common_dir" ;;
        esac
    fi
    rm -rf "$repo"
    if [ -n "$common_dir" ]; then
        parent="$(cd "$(dirname "$common_dir")" 2>/dev/null && pwd)"
        if [ -n "$parent" ] && [ -d "$parent/.git" ]; then
            git -C "$parent" worktree prune 2>/dev/null || true
        elif _is_bare "$common_dir"; then
            # The parent repo is itself BARE: git-common-dir already IS the
            # bare repo's own directory (no nested .git one level up), so
            # dirname(common_dir)/.git above never matches and the prune
            # step was silently skipped, leaving a stale worktree registry
            # entry on the bare parent (HIMMEL-2207). Prune directly there.
            git -C "$common_dir" worktree prune 2>/dev/null || true
        fi
    fi
}

# --- JSON row emission (bash 3.2-safe, mirrors flow-run-ledger.sh's escaper) --

_rs_json_str() {
    local s="$1"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    s=${s//$'\t'/\\t}
    printf '"%s"' "$s"
}

_rs_json_null_str() {
    if [ -n "${1:-}" ]; then _rs_json_str "$1"; else printf 'null'; fi
}

# --- main -----------------------------------------------------------------

# EXIT trap (mirrors dispatch-codex-exec.sh's composed EXIT trap, HIMMEL-2023,
# which this file's own header claims to follow): guarantees an end row is
# written even if something between the start row and the normal end-of-
# script write dies unexpectedly (e.g. a results-file append failing on a
# full disk) — without it, `set -e` would abort the whole script mid-flight
# and leave the flow permanently stuck on its start row, never reporting
# outcome=error. Disarmed (via _rs_ended=1) right before the normal end-row
# write below, so a clean run never double-appends.
run_id=""
_rs_ended=0
# shellcheck disable=SC2329,SC2317
_rs_exit_trap() {
    local rc=$?
    if [ "$_rs_ended" -eq 0 ] && [ -n "$run_id" ]; then
        flow_run_append "$(flow_run_row_end repo-sync "$run_id" "" "$rc" "error" 0 "runner exited unexpectedly (rc=$rc) before writing its normal end row")" 2>/dev/null || true
    fi
}
trap _rs_exit_trap EXIT

# Start row FIRST, before any results-file I/O (codex CR round 4): the EXIT
# trap can only report a failure once run_id is set, so if creating/rotating
# RESULTS_FILE itself fails, the run must already have a start row on record
# for the trap's error end row to attach to — otherwise that failure mode
# produces no ledger row at all, breaking the unconditional-reporting
# contract this file's header describes.
host="$(hostname 2>/dev/null || uname -n 2>/dev/null || echo unknown)"
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
run_id="$(flow_run_id repo-sync "$started_at" "$$")"
flow_run_append "$(flow_run_row_start repo-sync "$run_id" "$started_at" "$host" "" "" "$TASK_NAME" "$RESULTS_FILE" "$$")"

results_dir="$(dirname "$RESULTS_FILE")"
mkdir -p "$results_dir" 2>/dev/null || true
_rs_rotate_ok=1
if [ -f "$RESULTS_FILE" ]; then
    mv -f "$RESULTS_FILE" "$RESULTS_FILE.prev" 2>/dev/null || {
        _rs_rotate_ok=0
        echo "repo-sync-runner: WARN rotation of $RESULTS_FILE failed — this run's rows will be appended to the stale prior-run file" >&2
    }
fi
# Only truncate/recreate RESULTS_FILE when rotation actually succeeded (or
# there was nothing to rotate) — a failed mv above must NOT be followed by a
# truncate, or the failure is silently upgraded into data loss: the old
# results this run's caller may still need would be wiped with no .prev
# backup to recover from. When rotation fails, this run's rows still append
# below (results_dir exists, RESULTS_FILE is untouched) rather than being
# dropped — the warning above is the caller's only signal that the file now
# mixes stale and fresh rows.
[ "$_rs_rotate_ok" -eq 1 ] && : > "$RESULTS_FILE"

github_canon=""
[ -d "$GITHUB_ROOT" ] && github_canon="$(_canon "$GITHUB_ROOT")"

# _scan_dir's `find` failures (round-9 fix) only WARN to stderr — that
# WARN never reaches the run's outcome/exit code, so a directory-scan
# failure still reports a clean run despite possibly-missing repos
# (codex-1, HIMMEL-2115 pr-check round-10 panel). Enumeration runs inside
# `<(...)` process substitutions below, so a plain shell variable set by
# `_scan_dir` would be lost when that subshell exits -- use a marker FILE
# instead, which does survive (a real filesystem effect, not shell state).
_rs_find_fail_marker=$(mktemp -t repo-sync-find-fail.XXXXXX 2>/dev/null || true)
[ -n "$_rs_find_fail_marker" ] && rm -f "$_rs_find_fail_marker"

repos=()
if [ -d "$GITHUB_ROOT" ]; then
    while IFS= read -r r; do repos+=("$r"); done < <(enumerate_repos "$GITHUB_ROOT" -1)
fi
while IFS= read -r r; do repos+=("$r"); done < <(enumerate_repos "$DOCUMENTS_ROOT" 2 "$github_canon")

pulled=0
fetch_only=0
failed=0
wt_deleted=0
wt_alerted=0
wt_skipped=0

for repo in "${repos[@]+"${repos[@]}"}"; do
    if _is_wt_candidate "$repo"; then
        classify_wt_candidate "$repo"
        case "$WT_ACTION" in
            deleted)
                if _wt_reverify_deletable "$repo"; then
                    wt_deleted=$((wt_deleted+1)); delete_wt_folder "$repo"
                else
                    WT_ACTION="alert"; WT_OK="false"
                    WT_REASON="became dirty or gained unpushed commits between classification and deletion (TOCTOU re-check, HIMMEL-2207) -- not deleted"
                    wt_alerted=$((wt_alerted+1))
                fi
                ;;
            alert)   wt_alerted=$((wt_alerted+1)) ;;
            skip)    wt_skipped=$((wt_skipped+1)) ;;
        esac
        printf '{"kind":"wt-cleanup","folder":%s,"action":%s,"reason":%s,"ok":%s}\n' \
            "$(_rs_json_str "$repo")" "$(_rs_json_str "$WT_ACTION")" \
            "$(_rs_json_str "$WT_REASON")" "$WT_OK" \
            >> "$RESULTS_FILE"
        continue
    fi
    classify_repo "$repo"
    case "$RS_ACTION" in
        pulled) pulled=$((pulled+1)) ;;
        fetch-only) fetch_only=$((fetch_only+1)) ;;
        failed) failed=$((failed+1)) ;;
    esac
    printf '{"repo":%s,"action":%s,"branch":%s,"default_branch":%s,"reason":%s,"ok":%s}\n' \
        "$(_rs_json_str "$repo")" "$(_rs_json_str "$RS_ACTION")" \
        "$(_rs_json_null_str "$RS_BRANCH")" "$(_rs_json_null_str "$RS_DEFAULT_BRANCH")" \
        "$(_rs_json_str "$RS_REASON")" "$RS_OK" \
        >> "$RESULTS_FILE"
done

total=$((pulled + fetch_only + failed + wt_deleted + wt_alerted + wt_skipped))
note="$total repos: $pulled pulled, $fetch_only fetch-only (skipped), $failed failed; wt-cleanup: $wt_deleted deleted, $wt_alerted alerted, $wt_skipped skipped (not yet stale)"
outcome="complete"
exit_code=0
if [ "$failed" -gt 0 ]; then
    outcome="error"
    exit_code=1
fi
# A stale-wt ALERT is the salvage-first signal (dirty/unpushed/unique
# branch) -- same alert path as a sync failure: fold it into this run's
# outcome/exit code too, not just the per-folder results row.
if [ "$wt_alerted" -gt 0 ]; then
    outcome="error"
    exit_code=1
fi
# Fold the two non-per-repo failure signals into the run's outcome too (CR
# round-10 panel, codex-1/codex-2): neither a rotation failure nor a
# directory-scan failure has a specific repo to attach a "failed" row to,
# but both mean this run's results are suspect (stale-mixed rows, or
# possibly-missing repos) -- a bare stderr WARN never reaches the
# flow-run-ledger/alert path, so without this the run still reports
# "complete" despite either problem.
if [ "$_rs_rotate_ok" -ne 1 ]; then
    note="$note; results-file rotation failed -- this run's rows are appended to the stale prior-run file"
    outcome="error"
    exit_code=1
fi
if [ -n "$_rs_find_fail_marker" ] && [ -e "$_rs_find_fail_marker" ]; then
    note="$note; one or more directory scans failed -- repos under those subtrees may be missing from this run"
    outcome="error"
    exit_code=1
    rm -f "$_rs_find_fail_marker"
fi

flow_run_append "$(flow_run_row_end repo-sync "$run_id" "" "$exit_code" "$outcome" "$total" "$note")"
_rs_ended=1
echo "repo-sync-runner: $note"
echo "repo-sync-runner: results written to $RESULTS_FILE"

exit "$exit_code"
