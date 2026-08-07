#!/usr/bin/env bash
# classify-branches.sh - decide, per branch, whether its content is already in
# main. REPORT ONLY: this script never deletes, never pushes, never writes to
# the repo (HIMMEL-1600, wave-1 Track 7.1).
#
# WHY THIS EXISTS
# The estate is unknowable: 321 local branches against 486 open tickets, and the
# two obvious tools both LIE about squash merges. `git log main..B` and
# `git cherry` each report a fully-landed branch as unlanded, because a squash
# merge rewrites every patch-id. Live example: claudex/himmel-1506-app-carry
# reads 3 commits "ahead" of main and was merged as fd8bff27 via PR #1557.
# Until a branch can be classified correctly, nothing can be pruned safely.
#
# ALGORITHM
#   1. PR merge state is PRIMARY. A merged PR whose head is this branch means
#      LANDED, full stop -- no content comparison needed. This resolves most of
#      the estate in one `gh` call.
#   2. The fallback is TIME-FREE, deliberately. An earlier draft proposed
#      "content-compare against main as of the branch's merge time", which is
#      circular: a merge time exists only for merged PRs -- exactly the
#      population step 1 already resolved. The fallback population is (a)
#      branches with no PR at all and (b) closed-unmerged-but-landed-via-another-PR
#      (this repo did that: public #551/#552 closed, content shipped in #553).
#      Neither has a time anchor, so we ask a question that needs none: does
#      every blob the branch introduced appear ANYWHERE in main's history?
#
# EXIT: 0 when the report was produced (whatever it says). Non-zero only on
# usage/environment errors -- a branch being AHEAD is a finding, not a failure.

# pipefail is load-bearing here, not decoration: several checks below read the
# status of a PIPELINE whose failure is the signal. Without it the pipeline
# reports the status of its LAST stage only, and a `|| sentinel` fallback
# becomes dead code that silently never fires.
set -uo pipefail

BASE="main"
PR_MAP=""
LIMIT=1000
PATTERN=""
VERBOSE=0

usage() {
    cat <<'EOF'
usage: classify-branches.sh [--base <ref>] [--pattern <glob>] [--pr-map <file>]
                            [--limit <n>] [--verbose]

Classifies every local branch against <base> (default: main) and prints one
line per branch. REPORT ONLY -- nothing is deleted.

  --base <ref>      compare against this ref (default: main)
  --pattern <glob>  only classify branches matching this glob
  --pr-map <file>   read PR head/state pairs from a TSV file instead of calling
                    gh. Format: <headRefName>\t<state>  (state: MERGED/CLOSED/OPEN)
                    Used by the test suite; also lets you work offline.
  --limit <n>       max PRs to fetch from gh (default: 1000)
  --verbose         also print the evidence behind each verdict

verdicts:
  LANDED   content is in <base> (merged PR, or every introduced blob present)
  AHEAD    content is NOT fully in <base> -- real unlanded work
  UNKNOWN  could not be determined (see the reason on the line)
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --base)    [ $# -ge 2 ] || { echo "classify-branches: --base needs a value" >&2; exit 2; }; BASE="$2"; shift 2 ;;
        --pattern) [ $# -ge 2 ] || { echo "classify-branches: --pattern needs a value" >&2; exit 2; }; PATTERN="$2"; shift 2 ;;
        --pr-map)  [ $# -ge 2 ] || { echo "classify-branches: --pr-map needs a value" >&2; exit 2; }; PR_MAP="$2"; shift 2 ;;
        --limit)   [ $# -ge 2 ] || { echo "classify-branches: --limit needs a value" >&2; exit 2; }; LIMIT="$2"; shift 2 ;;
        --verbose) VERBOSE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "classify-branches: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
    esac
done

git rev-parse --git-dir >/dev/null 2>&1 || {
    echo "classify-branches: not inside a git repository" >&2; exit 2; }
git rev-parse --verify --quiet "$BASE" >/dev/null || {
    echo "classify-branches: base ref '$BASE' does not exist" >&2; exit 2; }

# ---------------------------------------------------------------------------
# Step 1 -- the PR map. ONE gh call for the whole estate, not one per branch:
# per-branch `gh pr list --head B` over 321 branches is hundreds of round trips.
# A branch can carry several PRs (reopened, superseded); MERGED wins over
# everything, so we only ever upgrade a branch's recorded state to MERGED.
# ---------------------------------------------------------------------------
PR_STATE_FILE=$(mktemp) || { echo "classify-branches: mktemp failed" >&2; exit 2; }
trap 'rm -f "$PR_STATE_FILE"' EXIT
PR_SOURCE="none"

if [ -n "$PR_MAP" ]; then
    [ -f "$PR_MAP" ] || { echo "classify-branches: --pr-map file '$PR_MAP' not found" >&2; exit 2; }
    cp "$PR_MAP" "$PR_STATE_FILE"
    PR_SOURCE="file:$PR_MAP"
elif command -v gh >/dev/null 2>&1; then
    if gh pr list --state all --limit "$LIMIT" \
         --json headRefName,state \
         --jq '.[] | [.headRefName, .state] | @tsv' > "$PR_STATE_FILE" 2>/dev/null; then
        PR_SOURCE="gh"
    else
        # Offline / no remote / not authed. Not fatal: step 2 alone still
        # classifies correctly, it just does more work. Say so, because a
        # silent downgrade would make the report look more authoritative
        # than it is.
        : > "$PR_STATE_FILE"
        PR_SOURCE="unavailable (gh failed -- content comparison only)"
    fi
else
    PR_SOURCE="unavailable (no gh on PATH -- content comparison only)"
fi

pr_state_for() { # <branch> -> MERGED|CLOSED|OPEN|"" on stdout
    local _b="$1" _line _head _state _best=""
    while IFS=$'\t' read -r _head _state; do
        [ "$_head" = "$_b" ] || continue
        [ "$_state" = "MERGED" ] && { printf 'MERGED'; return 0; }
        [ -z "$_best" ] && _best="$_state"
    done < "$PR_STATE_FILE"
    printf '%s' "$_best"
}

# ---------------------------------------------------------------------------
# Step 2 -- time-free content comparison.
#
# For every path the branch touched relative to its merge-base with <base>:
#
#   added / modified -> the blob at the branch tip must appear SOMEWHERE in
#                       <base>'s history. `git log --find-object` answers
#                       exactly that, and is indifferent to squashing, since a
#                       squash preserves blobs even though it destroys patch-ids.
#   deleted          -> the path must be ABSENT at <base>'s tip. A deletion
#                       introduces no blob, so a blob-only test would call a
#                       never-landed deletion "landed" vacuously.
#
# Blob ids come from `git ls-tree`, never from hashing a working-tree file.
# That matters: an EMPTY file and an ABSENT file both hash to e69de29…, so a
# hash-object-based probe cannot tell "the branch added an empty file" from
# "the path isn't there", and would misclassify the former. ls-tree prints
# nothing at all for an absent path, which is unambiguous.
#
# The probe is also PATH-ANCHORED, which the first cut of this script was not,
# and the empty file is what exposed it. e69de29… is not merely a collision
# hazard, it is the id of EVERY empty file in the repo, so a bare
# `--find-object=e69de29…` matched some unrelated empty file that had landed
# and reported an unlanded branch as LANDED. The blob must appear in base AT
# THE PATH the branch put it, not merely somewhere. The same reasoning applies
# to any duplicated content (LICENSE copies, empty __init__.py, fixtures).
# ---------------------------------------------------------------------------
blob_at_path_in_base() { # <path> <blob-sha> -> rc 0 if base ever had this blob here
    local _path="$1" _blob="$2" _tip _hit
    # Cheap path first: base's CURRENT tree. Covers everything still present
    # unchanged, which is the overwhelming majority, with no history walk.
    _tip=$(git ls-tree "$BASE" -- "$_path" 2>/dev/null | awk '{print $3}')
    [ -n "$_tip" ] && [ "$_tip" = "$_blob" ] && return 0
    # Otherwise the content may have landed and then been changed again on
    # base. Restrict --find-object with the pathspec so a same-blob hit at a
    # DIFFERENT path cannot satisfy this path's check.
    _hit=$(git log "$BASE" --find-object="$_blob" --format=%H --max-count=1 -- "$_path" 2>/dev/null)
    [ -n "$_hit" ]
}

classify_by_content() { # <branch> -> sets VERDICT + EVIDENCE
    local _b="$1" _mb _status _path _blob _missing=0 _checked=0 _firstmiss="" _diff

    _mb=$(git merge-base "$BASE" "$_b" 2>/dev/null) || _mb=""
    if [ -z "$_mb" ]; then
        VERDICT="UNKNOWN"; EVIDENCE="no merge-base with $BASE (unrelated history)"
        return 0
    fi

    # --no-renames on purpose: a rename detected as a rename would hide the fact
    # that the NEW path's blob must be findable in base. It has to be passed
    # EXPLICITLY — diff.renames defaults to TRUE since Git 2.9, so merely not
    # passing -M/-C does not turn detection off. Without it the walk below sees
    # `R100<TAB>old<TAB>new`, `read -r _status _path` binds _path to the
    # tab-joined "old<TAB>new", every ls-tree on that bogus path comes back
    # empty, and a landed branch is misreported AHEAD.
    # Take the diff up front and FAIL CLOSED on error. Reading it straight into
    # the loop with stderr discarded made a failed diff indistinguishable from
    # an empty one: _checked stayed 0 and the branch was reported LANDED, i.e.
    # safe to delete, on no evidence at all.
    if ! _diff=$(git diff --no-renames --name-status "$_mb" "$_b" 2>/dev/null); then
        VERDICT="UNKNOWN"; EVIDENCE="git diff --name-status failed for $_b"
        return 0
    fi

    while IFS=$'\t' read -r _status _path; do
        [ -n "$_status" ] || continue
        _checked=$((_checked + 1))
        case "$_status" in
            D)
                # Landed iff the path is gone at base tip.
                if git ls-tree -r --name-only "$BASE" -- "$_path" 2>/dev/null | grep -qxF "$_path"; then
                    _missing=$((_missing + 1))
                    [ -z "$_firstmiss" ] && _firstmiss="deletion of '$_path' not in $BASE"
                fi
                ;;
            *)
                _blob=$(git ls-tree "$_b" -- "$_path" 2>/dev/null | awk '{print $3}')
                if [ -z "$_blob" ]; then
                    # Touched but absent at the tip -- treat as indeterminate
                    # rather than guessing.
                    _missing=$((_missing + 1))
                    [ -z "$_firstmiss" ] && _firstmiss="could not read blob for '$_path'"
                elif ! blob_at_path_in_base "$_path" "$_blob"; then
                    _missing=$((_missing + 1))
                    [ -z "$_firstmiss" ] && _firstmiss="blob for '$_path' absent from $BASE history"
                fi
                ;;
        esac
    done <<< "$_diff"

    if [ "$_checked" -eq 0 ]; then
        VERDICT="LANDED"; EVIDENCE="no diff against $BASE"
    elif [ "$_missing" -eq 0 ]; then
        VERDICT="LANDED"; EVIDENCE="all $_checked path(s) present in $BASE history"
    else
        VERDICT="AHEAD"; EVIDENCE="$_missing of $_checked path(s) not in $BASE: $_firstmiss"
    fi
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
BASE_TIP=$(git rev-parse --short "$BASE" 2>/dev/null)
echo "# classify-branches: base=$BASE ($BASE_TIP)  pr-data=$PR_SOURCE"
echo "# REPORT ONLY -- no branch is modified or deleted."
echo

n_landed=0; n_ahead=0; n_unknown=0

while IFS= read -r branch; do
    [ -n "$branch" ] || continue
    [ "$branch" = "$BASE" ] && continue
    if [ -n "$PATTERN" ]; then
        # shellcheck disable=SC2254  # --pattern is DOCUMENTED as a glob; quoting
        # it would turn 'feat/*' into a literal and match nothing.
        case "$branch" in $PATTERN) ;; *) continue ;; esac
    fi

    state=$(pr_state_for "$branch")
    if [ "$state" = "MERGED" ]; then
        VERDICT="LANDED"; EVIDENCE="merged PR"
    else
        classify_by_content "$branch"
        if [ -n "$state" ] && [ "$VERDICT" = "LANDED" ]; then
            EVIDENCE="$EVIDENCE (PR state: $state)"
        fi
    fi

    case "$VERDICT" in
        LANDED)  n_landed=$((n_landed + 1)) ;;
        AHEAD)   n_ahead=$((n_ahead + 1)) ;;
        *)       n_unknown=$((n_unknown + 1)) ;;
    esac

    if [ "$VERBOSE" -eq 1 ]; then
        printf '%-8s %s\n           %s\n' "$VERDICT" "$branch" "$EVIDENCE"
    else
        printf '%-8s %s\n' "$VERDICT" "$branch"
    fi
done < <(git for-each-ref --format='%(refname:short)' refs/heads/)

echo
echo "# LANDED=$n_landed AHEAD=$n_ahead UNKNOWN=$n_unknown"
exit 0
