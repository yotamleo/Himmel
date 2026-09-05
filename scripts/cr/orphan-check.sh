#!/usr/bin/env bash
# scripts/cr/orphan-check.sh -- /pr-check step-4 structural orphan-check
# (HIMMEL-1219 round 5; extracted from the runbook fence by HIMMEL-2226).
#
# WHY THIS IS A SCRIPT AND NOT A FENCE: `.claude/commands/pr-check.md` used to
# carry this logic as an inline ```bash fence the orchestrating session ran
# verbatim. Claude Code's own worktree-isolation guard refuses any bash command
# it cannot statically verify, and this fence tripped it on `while IFS= read -r`
# (an IFS prefix assignment changes word-splitting, which the guard cannot
# model). From a worktree-isolated session -- the normal place himmel feature
# work happens -- the fence was therefore UNRUNNABLE, and the operator had to
# invent a scratch-.sh workaround the runbook never named. Shipping it as a
# real script removes the parse surface entirely rather than teaching the
# parser (HIMMEL-2226 direction 3).
#
# WHAT IT DOES: orphans = (phase-A candidate IDs) - (aggregate VERDICT IDs).
# Step 3.2 phase A persists one `VERDICT [<id>] = <verdict>` line per
# panel/codex candidate to <git-common-dir>/cr-prior-blocking/<branch>; step 4
# persists the session's full aggregate to
# <git-common-dir>/cr-aggregate-verdicts/<branch>. A phase-A candidate with no
# matching aggregate VERDICT line is a candidate the carry-forward DROPPED, and
# is treated fail-closed as `unaddressed` -- the caller adds the printed count to
# its Critical count (N). Uses the SAME VERDICT-line id parse as phase B's awk,
# so the phase-A ID set here is identical to the set phase B counted from.
#
# Fail-open / fail-closed, unchanged from the fence:
#   * missing / empty / unreadable prior-blocking file -> no phase-A candidates
#     to reconcile -> 0 orphans (fail-open, matching phase B).
#   * aggregate file missing/empty WHILE prior-blocking has candidates -> EVERY
#     phase-A candidate is an orphan (fail-closed: a forgotten aggregate write
#     reads as "every candidate unaddressed").
#   * CodeRabbit `[coderabbit-N]` candidates are adjudicated in step 3.5, so
#     they live in the aggregate but never in the prior-blocking file. Orphans
#     are A - B, so they can never be reported as orphans.
#
# Usage:
#   bash scripts/cr/orphan-check.sh [--branch <branch>]
#   --branch defaults to `git branch --show-current`.
#
# Output:
#   stdout -- exactly one line: `orphan-check: <N> unaddressed phase-A candidate(s)`
#   stderr -- one line per orphan id (operator diagnostic, like phase B's).
#
# Exit codes:
#   0  check ran (N may be zero or non-zero -- N is the SIGNAL, not the rc)
#   2  usage error / unresolvable branch
#   3  not inside a git repo (cannot resolve --git-common-dir)
#
# bash 3.2-safe.
set -uo pipefail

branch=""
while [ $# -gt 0 ]; do case "$1" in
  --branch)
    [ $# -ge 2 ] || { echo "orphan-check.sh: --branch requires a value" >&2; exit 2; }
    branch="$2"; shift 2 ;;
  *) echo "orphan-check.sh: unknown arg $1" >&2; exit 2 ;;
esac; done

# Derived EXACTLY like write-verdicts.sh and the runbook fences:
# --git-common-dir is the SHARED git dir across every worktree in the checkout,
# so both scratch files are branch-scoped (HIMMEL-1219 round 1b) -- himmel runs
# concurrent /pr-check by design and unscoped files would race.
gd=$(git rev-parse --git-common-dir 2>/dev/null) || gd=""
[ -n "$gd" ] || { echo "orphan-check.sh: not a git repository (cannot resolve --git-common-dir) -- refusing." >&2; exit 3; }

[ -n "$branch" ] || branch=$(git branch --show-current 2>/dev/null || true)
[ -n "$branch" ] || { echo "orphan-check.sh: cannot resolve the branch (detached HEAD?) -- pass --branch explicitly." >&2; exit 2; }

prior_file="${gd}/cr-prior-blocking/${branch}"
agg_file="${gd}/cr-aggregate-verdicts/${branch}"

orphan_count=0
if [ -s "$prior_file" ]; then
    orphan_out=$(awk -v agg="$agg_file" '
        BEGIN {
            # Build set B (aggregate IDs) from the file the session wrote.
            while ((getline line < agg) > 0)
                if (line ~ /^VERDICT \[/) {
                    id = line
                    sub(/^VERDICT \[/, "", id); sub(/\].*/, "", id)
                    agg_seen[id] = 1
                }
            close(agg)
        }
        # Main input = prior-blocking (phase-A) file. SAME parse as phase B.
        /^VERDICT \[/ {
            id = $(0)
            sub(/^VERDICT \[/, "", id); sub(/\].*/, "", id)
            if (!(id in agg_seen)) { print id; n++ }
        }
        END { print "ORPHAN_COUNT=" n + 0 }
    ' "$prior_file" 2>/dev/null) || orphan_out=""
    orphan_count=$(printf '%s\n' "$orphan_out" | awk -F'=' '/^ORPHAN_COUNT=/{print $(2); exit}')
    case "$orphan_count" in ''|*[!0-9]*) orphan_count=0 ;; esac
    # Surface each orphan ID to the operator (stderr, like phase B's
    # diagnostics) -- a phase-A candidate dropped from the carry-forward.
    printf '%s\n' "$orphan_out" | while read -r oline; do
        case "$oline" in
            ORPHAN_COUNT=*) ;;
            ?*) echo "orphan phase-A candidate: $oline -- no matching aggregate VERDICT line; treating as unaddressed (fail-closed, HIMMEL-1219)" >&2 ;;
        esac
    done
fi
echo "orphan-check: $orphan_count unaddressed phase-A candidate(s)"
