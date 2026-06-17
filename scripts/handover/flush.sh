#!/usr/bin/env bash
# handover/flush — session-end consolidation sweep across handover/* branches.
#
# HIMMEL-143 (HIMMEL-59 v2 child). Walks the resolved handover repo
# and reconciles state for every local `handover/*` branch:
#
#   - Unpushed (HEAD ahead of origin/<branch>, or origin/<branch>
#     missing): `git push -u origin <branch>`.
#   - No open PR: invoke `scripts/handover/pr-open.sh` to open one.
#   - Merged into the default branch (origin/main or origin/master): report
#     (default) or delete the local branch via `git branch -D` when
#     --cleanup is passed.
#
# Wired into `/context-hop` so cap-resume hand-off cannot leave un-pushed
# state; explicit `/handover-flush` covers the manual case.
#
# Failure modes:
#   - gh CLI auth missing → warn + dump the exact commands the operator
#     must run to land each branch.
#   - push failure → printed per-branch, sweep continues to the next branch.
#   - pr-open failure → already best-effort inside pr-open.sh (exit 0).
#
# Exit codes:
#   0  sweep ran (with or without per-branch errors); summary printed
#   1  usage / input error
#   2  required tool missing or env unusable
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/handover-path.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/handover-path.sh"
# default_branch() resolves the handover repo's default (main OR master,
# HIMMEL-297) for the PR base / merged-check below.
# shellcheck source=../guardrails/lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../guardrails/lib.sh"
# Forge-dispatch seam (HIMMEL-326): the PR-state queries route through forge_*,
# so flush works against a GitHub or Bitbucket Cloud handover repo.
# shellcheck source=../lib/forge.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/forge.sh"

GH_CMD="${GH_CMD:-gh}"
GIT_CMD="${GIT_CMD:-git}"
DRY_RUN=0
CLEANUP=0
NO_PR_OPEN=0
# Empty unless explicitly pinned; resolved to the handover repo's default
# branch (main OR master) once the repo root is known (HIMMEL-297).
DEFAULT_BASE="${HANDOVER_PR_BASE:-}"

usage() {
    cat <<'EOF'
Usage: flush.sh [--dry-run] [--cleanup] [--no-pr-open]

Walk every local `handover/*` branch in the resolved handover repo
(per HANDOVER_DIR) and reconcile it against origin:
  - unpushed   → git push -u origin <branch>
  - no PR open → invoke pr-open.sh
  - merged     → report (or delete local branch with --cleanup)

Always prints a per-branch status table and a footer summary.

Optional:
  --dry-run      Print intended actions; touch nothing.
  --cleanup      Delete local handover/* branches merged into the default
                 branch (origin/main or origin/master).
  --no-pr-open   Skip the pr-open step. Useful when gh is unreachable;
                 flush still pushes + reports.

Environment:
  HANDOVER_DIR            Required (Mode B only).
  HANDOVER_PR_BASE        Default base for new PRs. Defaults to the handover
                          repo's default branch (main or master).
  GH_CMD / GIT_CMD        Test overrides.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)    DRY_RUN=1; shift ;;
        --cleanup)    CLEANUP=1; shift ;;
        --no-pr-open) NO_PR_OPEN=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        *)            echo "ERR flush: unknown arg: $1" >&2; usage >&2; exit 1 ;;
    esac
done

if ! command -v "${GIT_CMD%% *}" >/dev/null 2>&1; then
    echo "ERR flush: required tool 'git' not on PATH" >&2
    exit 2
fi

mode=$(handover_mode)
if [ "$mode" != "B" ]; then
    echo "ERR flush: Mode A (inline) not supported — set HANDOVER_DIR to an external repo first" >&2
    exit 2
fi
if ! root=$(handover_root); then
    exit 2
fi
if ! handover_repo=$($GIT_CMD -C "$root" rev-parse --show-toplevel 2>&1); then
    echo "ERR flush: handover root not in a git repo: $handover_repo" >&2
    exit 2
fi

# Resolve the PR base = the handover repo's default branch (main OR master,
# HIMMEL-297), unless HANDOVER_PR_BASE pinned it explicitly above.
if [ -z "$DEFAULT_BASE" ]; then
    DEFAULT_BASE=$(default_branch "$handover_repo")
fi

# Forge queries run pinned to the handover repo — its origin determines the
# forge (GitHub or Bitbucket, HIMMEL-326) — regardless of flush's own cwd.
forge_in_handover() { ( cd "$handover_repo" && "$@" ); }

# Detect whether the forge CLI is usable (forge resolvable + authenticated).
# When unusable, fall back to "report + dump commands" mode for the PR step.
forge_usable=1
if ! forge_in_handover forge_detect >/dev/null 2>&1; then
    forge_usable=0
elif ! forge_in_handover forge_auth_status >/dev/null 2>&1; then
    forge_usable=0
fi
if [ "$forge_usable" -eq 0 ] && [ "$NO_PR_OPEN" -eq 0 ]; then
    echo "flush: WARNING — forge CLI not usable (missing or unauthenticated). PR-open step will be replaced with command dumps." >&2
fi

# Collect local handover/* branches. Sorted for deterministic output.
mapfile -t branches < <($GIT_CMD -C "$handover_repo" for-each-ref --format='%(refname:short)' 'refs/heads/handover/' 2>/dev/null | sort)

if [ ${#branches[@]} -eq 0 ]; then
    echo "flush: no local handover/* branches — nothing to do."
    exit 0
fi

# Ensure origin/<default> is up-to-date for the merged check. Best-effort.
$GIT_CMD -C "$handover_repo" fetch -q origin "$DEFAULT_BASE" 2>/dev/null || true

# Per-branch reconciliation -------------------------------------------

unpushed=0
pushed=0
already_pushed=0
pr_opened=0
pr_dumped=0
merged_reported=0
merged_cleaned=0
errors=0

printf '%-50s %-15s %-15s %-10s\n' "BRANCH" "PUSH" "PR" "MERGED"
printf '%-50s %-15s %-15s %-10s\n' "------" "----" "--" "------"

for branch in "${branches[@]}"; do
    push_state="-"
    pr_state="-"
    merged_state="-"

    # 1. Push state -----------------------------------------------------
    if $GIT_CMD -C "$handover_repo" rev-parse --verify --quiet "refs/remotes/origin/$branch" >/dev/null 2>&1; then
        ahead=$($GIT_CMD -C "$handover_repo" rev-list --count "origin/$branch..$branch" 2>/dev/null || echo "0")
    else
        ahead="new"
    fi
    if [ "$ahead" = "0" ]; then
        push_state="in-sync"
        already_pushed=$((already_pushed+1))
    else
        unpushed=$((unpushed+1))
        if [ "$DRY_RUN" -eq 1 ]; then
            push_state="WOULD-push"
        else
            if $GIT_CMD -C "$handover_repo" push -u origin "$branch" >/dev/null 2>&1; then
                push_state="pushed"
                pushed=$((pushed+1))
            else
                push_state="PUSH-FAIL"
                errors=$((errors+1))
            fi
        fi
    fi

    # 2. PR state -------------------------------------------------------
    if [ "$NO_PR_OPEN" -eq 1 ]; then
        pr_state="skipped"
    elif [ "$forge_usable" -eq 0 ]; then
        pr_state="FORGE-UNAVAIL"
        pr_dumped=$((pr_dumped+1))
        # Dump the command operator should run.
        echo "flush: forge CLI unavailable — to open the PR for $branch, run:" >&2
        echo "    cd $handover_repo && git checkout $branch && bash $SCRIPT_DIR/pr-open.sh --base $DEFAULT_BASE" >&2
    else
        pr_num=""
        if pr_num=$(forge_in_handover forge_pr_find_open "$branch" 2>/dev/null); then :; fi
        if [ -n "$pr_num" ]; then
            pr_state="#$pr_num"
        else
            if [ "$DRY_RUN" -eq 1 ]; then
                pr_state="WOULD-open"
            else
                # pr-open.sh requires HEAD on the target branch. Switch + invoke,
                # then restore the prior branch on exit.
                prior=$($GIT_CMD -C "$handover_repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
                if $GIT_CMD -C "$handover_repo" checkout -q "$branch" 2>/dev/null; then
                    if ( cd "$handover_repo" && GH_CMD="$GH_CMD" bash "$SCRIPT_DIR/pr-open.sh" --base "$DEFAULT_BASE" >/dev/null 2>&1 ); then
                        pr_state="opened"
                        pr_opened=$((pr_opened+1))
                    else
                        pr_state="PR-FAIL"
                        errors=$((errors+1))
                    fi
                    if [ -n "$prior" ]; then
                        $GIT_CMD -C "$handover_repo" checkout -q "$prior" 2>/dev/null || true
                    fi
                else
                    pr_state="CHECKOUT-FAIL"
                    errors=$((errors+1))
                fi
            fi
        fi
    fi

    # 3. Merged state ---------------------------------------------------
    # `merge-base --is-ancestor <branch> origin/<default>` covers
    # fast-forward + merge-commit (tip is an ancestor of the default branch).
    # For squash-merged branches (the HIMMEL-141 mode), the tip is NOT an
    # ancestor; instead detect via `git cherry origin/<default> <branch>`
    # — all commits with a `-` prefix means everything was applied upstream.
    is_merged=0
    if $GIT_CMD -C "$handover_repo" merge-base --is-ancestor "$branch" "origin/$DEFAULT_BASE" 2>/dev/null; then
        is_merged=1
    else
        # Squash detection: are all commits on <branch> patch-equivalent to
        # commits on origin/<default>? `git cherry` prints `+` for missing,
        # `-` for applied. Empty `+` output → all applied → merged.
        if $GIT_CMD -C "$handover_repo" rev-parse --verify --quiet "origin/$DEFAULT_BASE" >/dev/null 2>&1; then
            cherry_missing=$($GIT_CMD -C "$handover_repo" cherry "origin/$DEFAULT_BASE" "$branch" 2>/dev/null | grep -c '^+' || true)
            # `wc -l`-style — but cherry_missing is the count; treat 0 as merged.
            if [ "$cherry_missing" = "0" ]; then
                is_merged=1
            fi
        fi
    fi
    if [ "$is_merged" -eq 1 ]; then
        merged_reported=$((merged_reported+1))
        if [ "$CLEANUP" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
            # Don't delete the currently-checked-out branch.
            current=$($GIT_CMD -C "$handover_repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
            if [ "$branch" = "$current" ]; then
                merged_state="merged-held"
            elif $GIT_CMD -C "$handover_repo" branch -D "$branch" >/dev/null 2>&1; then
                merged_state="cleaned"
                merged_cleaned=$((merged_cleaned+1))
            else
                merged_state="MERGED-DEL-FAIL"
                errors=$((errors+1))
            fi
        else
            merged_state="merged"
        fi
    fi

    printf '%-50s %-15s %-15s %-10s\n' "$branch" "$push_state" "$pr_state" "$merged_state"
done

# Summary -------------------------------------------------------------

echo
echo "===================================="
echo "flush summary:"
echo "  branches scanned : ${#branches[@]}"
echo "  in-sync          : $already_pushed"
if [ "$DRY_RUN" -eq 1 ]; then
    echo "  would-push       : $unpushed"
else
    echo "  pushed           : $pushed (of $unpushed unpushed)"
fi
echo "  PR opened        : $pr_opened"
[ "$pr_dumped" -gt 0 ] && echo "  PR command dumps : $pr_dumped (gh unavailable)"
echo "  merged           : $merged_reported"
[ "$CLEANUP" -eq 1 ] && echo "  merged cleaned   : $merged_cleaned"
echo "  errors           : $errors"
echo "===================================="

# Always exit 0 — per-branch errors are surfaced in the table, but a
# sweep is best-effort by design (a single broken branch shouldn't
# block the rest).
exit 0
