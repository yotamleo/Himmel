#!/usr/bin/env bash
# scripts/handover/console-kit/shepherd.sh — one deterministic pass over a
# CLOUD-DONE PR (HIMMEL-4942, lever 1). Ten native shepherd legs cost ~$2 each,
# almost all cache reads, for mechanical work with a clean panel every time.
# This runs the mechanical part in one foreground pass and prints ONE block, so
# a model turn is spent only on a finding, a failed suite or a coverage gap.
#
# Read-only toward the PR: no push, no merge, no comment, no CLOUD-ACK steering
# (steering is a headless claude call; the script only says whether it is due).
# Its one write is a detached worktree of the PR head under
# <repo>/.claude/worktrees/shepherd-<pr> (git, not _new-worktree.sh: that helper
# cuts a NEW branch from origin/main, and a shepherd needs the PR head as is).
# The console still reads the diff, GOs and merges.
#
# Usage: shepherd.sh <pr-number>
#
# Steps, in order:
#   1. resolve the PR head + base                       (gh pr view)
#   2. CLOUD-DONE posted?  no -> steering is due, stop  (NEEDS-LEG steering-required)
#   3. detached worktree of the PR head
#   4. ticket-coverage lint                             (ready-check.sh --only 7)
#   5. impacted suites, each run in the worktree        (impacted-suites.sh --shell)
#   6. panel                                            (CR ledger row for the head)
#   7. check-ci                                         (check-ci.sh <pr> --max-wait)
#   8. ready-check                                      (ready-check.sh <pr> <head>)
#
# Step 6 CANNOT run here: /pr-check is a runbook a model session drives (panel,
# adjudication, ledger, marker clear). The script only reads the ledger; with no
# ok row for the head it says "panel: NOT-RUN" and the PR needs a /pr-check
# round. ponytail: a PR is a READY-CANDIDATE only once /pr-check already ran at
# its head, non-shell suites (mjs/ts) are listed but never run here, upgrade
# path HIMMEL-4942 lever 2 (a lean Haiku shepherd for the PRs this flags).
#
# Output (stable):
#   SHEPHERD <pr> <head> READY-CANDIDATE
#   SHEPHERD <pr> <head> NEEDS-LEG <reason>[,<reason>...]
#   then one `  <step>: <verdict> ...` line per step run.
#
# Exit codes:
#   0 — READY-CANDIDATE
#   1 — NEEDS-LEG (at least one reason; the block names them)
#   2 — usage or infra error (gh/jq/git missing, PR unreadable, worktree failed)
#
# Env (tests inject stubs): GH_CMD, SHEPHERD_READY_CHECK, SHEPHERD_CHECK_CI,
# SHEPHERD_IMPACTED, SHEPHERD_LEDGER, SHEPHERD_CI_MAX_WAIT (default 900).
# Bash 3.2-safe. No mapfile.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_SCRIPTS="$(cd "$HERE/../.." && pwd)"
# shellcheck source=scripts/lib/git-clean.sh
. "$HERE/../../lib/git-clean.sh"
git_env_scrub   # a stray GIT_DIR/GIT_WORK_TREE must not redirect the PR worktree

usage() { echo "usage: shepherd.sh <pr-number>" >&2; }

if [ "$#" -ne 1 ]; then usage; exit 2; fi
PR="$1"
case "$PR" in
    ''|0*|*[!0123456789]*)
        usage
        echo "shepherd: pr-number must be digits without a leading zero (got '$PR')" >&2
        exit 2 ;;
esac

GH="${GH_CMD:-gh}"
READY_CHECK="${SHEPHERD_READY_CHECK:-$HERE/ready-check.sh}"
CHECK_CI="${SHEPHERD_CHECK_CI:-$REPO_SCRIPTS/check-ci.sh}"
IMPACTED="${SHEPHERD_IMPACTED:-$REPO_SCRIPTS/cr/impacted-suites.sh}"
CI_MAX_WAIT="${SHEPHERD_CI_MAX_WAIT:-900}"

for tool in "$GH" jq git; do
    command -v "$tool" >/dev/null 2>&1 || { echo "shepherd: $tool not found on PATH" >&2; exit 2; }
done

pr_json=$("$GH" pr view "$PR" --json headRefOid,baseRefName,comments 2>/dev/null) || pr_json=""
HEAD_SHA=$(printf '%s' "$pr_json" | jq -r '.headRefOid // empty' 2>/dev/null)
BASE_REF=$(printf '%s' "$pr_json" | jq -r '.baseRefName // empty' 2>/dev/null)
case "$HEAD_SHA" in
    ''|*[!0123456789abcdef]*) echo "shepherd: cannot read PR #$PR head (gh pr view failed)" >&2; exit 2 ;;
esac
[ "${#HEAD_SHA}" -eq 40 ] || { echo "shepherd: PR #$PR head '$HEAD_SHA' is not a full sha" >&2; exit 2; }
[ -n "$BASE_REF" ] || { echo "shepherd: cannot read PR #$PR base branch" >&2; exit 2; }

REASONS=""
LINES=""
add_line() { LINES="${LINES}  $1
"; }
add_reason() { if [ -z "$REASONS" ]; then REASONS="$1"; else REASONS="$REASONS,$1"; fi; }
emit() { # <READY-CANDIDATE|NEEDS-LEG> [reasons]
    if [ "$1" = "READY-CANDIDATE" ]; then
        printf 'SHEPHERD %s %s READY-CANDIDATE\n' "$PR" "$HEAD_SHA"
    else
        printf 'SHEPHERD %s %s NEEDS-LEG %s\n' "$PR" "$HEAD_SHA" "$2"
    fi
    printf '%s' "$LINES"
}

add_line "head: $HEAD_SHA base: $BASE_REF"

# ── 2. CLOUD-DONE ───────────────────────────────────────────────────────────
if printf '%s' "$pr_json" | jq -e '[.comments[]? | select((.body // "") | startswith("CLOUD-DONE"))] | length > 0' >/dev/null 2>&1; then
    add_line "steering: skipped (CLOUD-DONE posted, the cloud session has ended)"
else
    add_line "steering: DUE (no CLOUD-DONE comment; the cloud session may still push — send CLOUD-ACK steering before anything else)"
    emit NEEDS-LEG steering-required
    exit 1
fi

# ── 3. worktree of the PR head ──────────────────────────────────────────────
common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || { echo "shepherd: not inside a git repo" >&2; exit 2; }
WT="$(cd "$common/.." && pwd)/.claude/worktrees/shepherd-$PR"
if [ -d "$WT" ] && [ "$(git -C "$WT" rev-parse HEAD 2>/dev/null)" = "$HEAD_SHA" ]; then
    if [ -n "$(git -C "$WT" status --porcelain 2>/dev/null)" ]; then
        echo "shepherd: $WT has local changes; remove it (git worktree remove --force) and re-run" >&2
        exit 2
    fi
    add_line "worktree: reused $WT"
else
    if [ -d "$WT" ]; then
        echo "shepherd: $WT exists at another head; remove it (git worktree remove) and re-run" >&2
        exit 2
    fi
    git fetch --quiet origin "pull/$PR/head" >/dev/null 2>&1 || { echo "shepherd: git fetch origin pull/$PR/head failed" >&2; exit 2; }
    [ "$(git rev-parse FETCH_HEAD 2>/dev/null)" = "$HEAD_SHA" ] || { echo "shepherd: fetched PR head differs from $HEAD_SHA (it moved; re-run)" >&2; exit 2; }
    git fetch --quiet origin "$BASE_REF" >/dev/null 2>&1 || true
    git worktree add --quiet --detach "$WT" "$HEAD_SHA" >/dev/null 2>&1 || { echo "shepherd: git worktree add $WT failed" >&2; exit 2; }
    add_line "worktree: created $WT"
fi

# ── 4. ticket coverage ──────────────────────────────────────────────────────
if cov=$(bash "$READY_CHECK" --only 7 "$PR" 2>&1); then
    add_line "coverage: PASS"
else
    add_line "coverage: FAIL $(printf '%s' "$cov" | grep -m1 -i 'fail' | cut -c1-160)"
    add_reason coverage-gap
fi

# ── 5. impacted suites ──────────────────────────────────────────────────────
mb=$(git -C "$WT" merge-base "origin/$BASE_REF" "$HEAD_SHA" 2>/dev/null) || mb=""
if [ -z "$mb" ]; then
    add_line "suites: UNKNOWN (no merge-base with origin/$BASE_REF)"
    add_reason suites-unknown
else
    disc_ok=1
    all=$( cd "$WT" && bash "$IMPACTED" "$mb..$HEAD_SHA" 2>/dev/null ) || disc_ok=0
    shell=$( cd "$WT" && bash "$IMPACTED" "$mb..$HEAD_SHA" --shell 2>/dev/null ) || disc_ok=0
    if [ "$disc_ok" -eq 0 ]; then
        add_line "suites: UNKNOWN (impacted-suites.sh failed; discovery is not an empty list)"
        add_reason suites-discovery-failed
        all=""; shell=""
    fi
    n_run=0; n_fail=0
    for s in $shell; do
        n_run=$((n_run + 1))
        if ( cd "$WT" && bash "$s" >/dev/null 2>&1 ); then
            add_line "suite $s: PASS"
        else
            add_line "suite $s: FAIL"
            n_fail=$((n_fail + 1))
        fi
    done
    n_other=0
    for s in $all; do
        case " $(printf '%s' "$shell" | tr '\n' ' ') " in
            *" $s "*) ;;
            *) n_other=$((n_other + 1)); add_line "suite $s: UNRUN (not a shell suite)" ;;
        esac
    done
    [ "$n_fail" -eq 0 ] || add_reason "suite-failed:$n_fail"
    [ "$n_other" -eq 0 ] || add_reason "suites-unrun:$n_other"
    [ "$n_run" -gt 0 ] || [ "$n_other" -gt 0 ] || add_line "suites: none impacted"
fi

# ── 6. panel (ledger read only) ─────────────────────────────────────────────
LEDGER="${SHEPHERD_LEDGER:-$common/cr-critic-scores.jsonl}"
if [ -f "$LEDGER" ] && jq -e --arg h "$HEAD_SHA" 'select(.kind == "avail" and .head == $h and .status == "ok")' "$LEDGER" >/dev/null 2>&1; then
    add_line "panel: PASS (ledger has an ok row for the head)"
else
    add_line "panel: NOT-RUN (no ok ledger row for this head; /pr-check needs a model session)"
    add_reason panel-not-run
fi

# ── 7. check-ci ─────────────────────────────────────────────────────────────
bash "$CHECK_CI" "$PR" --max-wait "$CI_MAX_WAIT" >/dev/null 2>&1
rc=$?
case "$rc" in
    0) add_line "ci: PASS" ;;
    2|7) add_line "ci: PENDING (check-ci exit $rc: checks not decided)"; add_reason ci-pending ;;
    1) add_line "ci: FAIL (a check is red)"; add_reason ci-failed ;;
    3) add_line "ci: BLOCKED (unresolved review threads or a CR finding)"; add_reason review-threads ;;
    *) add_line "ci: FAIL (check-ci exit $rc)"; add_reason "ci-failed" ;;
esac

# ── 8. ready-check ──────────────────────────────────────────────────────────
if bash "$READY_CHECK" "$PR" "$HEAD_SHA" >/dev/null 2>&1; then
    add_line "ready-check: PASS"
else
    add_line "ready-check: FAIL (run ready-check.sh $PR $HEAD_SHA for the failing rows)"
    add_reason ready-check-failed
fi

if [ -z "$REASONS" ]; then
    emit READY-CANDIDATE
    exit 0
fi
emit NEEDS-LEG "$REASONS"
exit 1
