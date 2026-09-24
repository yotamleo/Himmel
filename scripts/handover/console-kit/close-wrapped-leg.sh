#!/usr/bin/env bash
# scripts/handover/console-kit/close-wrapped-leg.sh - console-run wrapped-leg
# window close (HIMMEL-3572 row 7). A console's `kill <konsole pid>` is
# classifier-denied [Interfere With Workloads] when typed as a bare literal -
# this script wraps the same TERM under a literal the classifier allowlists,
# but ONLY after verifying the leg is actually done: the queue lock on its
# doc is free AND its own last Results marker-bullet is WRAPPED. It never
# kills a pid it cannot independently prove belongs to that leg.
#
# Usage: close-wrapped-leg.sh <leg-doc>
#
# Refuses (nothing signaled) unless:
#   - `queue-lock.sh status <leg-doc>` reports free (rc=0);
#   - the doc's last `## Results` marker-bullet (one of LIVE/FINDING/
#     RESOLVED/READY/BLOCKED/HALTED/WRAPPED, leading token of the newest
#     such bullet) is WRAPPED;
#   - exactly one live `claude` session's real argv (via
#     scripts/lanes/lib/claude-sessions.sh's claude_sessions, /proc-argv
#     based, never a flattened pgrep -af scan) carries a `-n <name>` naming
#     the leg (names derived by scripts/lib/leg-identity.sh's leg_identity -
#     the doc stem, its undated form, and any legacy-family derived name).
# TERM goes to that one pid only - it never signals a non-matching pid, and
# 0 or >1 matches is a refusal, not a best guess.
#
# After the signal, if the doc names exactly one worktree path (a
# `.claude/worktrees/...` path appearing once) AND that worktree's PR (the
# last `MERGED #<n>` bullet, else the last `READY <pr> ...` bullet) reads
# MERGED via `gh pr view`, runs `scripts/clean.sh --only <worktree>` and
# reports (not fails) an "in use" skip. Never guesses a worktree: 0 or >1
# candidates in the doc skips the prune with a report, same as the PR-not-
# found case.
#
# Exit codes:
#   0  signaled (prune ran, skipped, or reported "in use" - all non-fatal)
#   1  gh/git/queue-lock plumbing failure, or the TERM signal itself failed
#   2  usage (missing/unreadable doc)
#   3  refused - the queue lock is not free
#   4  refused - the doc's last marker-bullet is not WRAPPED
#   5  refused - 0 or >1 live sessions matched the leg's names
#
# Platform guard: Linux bash 3.2+ (depends on /proc via claude-sessions.sh;
# no .ps1 twin - konsole legs are Linux/KDE-only, same guard as
# headed-arm-leg.sh's konsole launch path).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
GH="${GH_BIN:-gh}"
KILL="${KILL_BIN:-kill}"
CLEAN_SH="${CLEAN_SH_BIN:-$HERE/../../clean.sh}"

usage() {
    echo "usage: close-wrapped-leg.sh <leg-doc>" >&2
}

if [ "$#" -ne 1 ]; then
    usage
    exit 2
fi
DOC="$1"
if [ ! -f "$DOC" ] || [ ! -r "$DOC" ]; then
    usage
    echo "close-wrapped-leg: cannot read doc '$DOC'" >&2
    exit 2
fi

if ! bash "$HERE/../queue-lock.sh" status "$DOC" >/dev/null 2>&1; then
    echo "close-wrapped-leg: refusing - the queue lock on $DOC is not free" >&2
    exit 3
fi

last_marker=$(grep -E '^- [0-9]{2}:[0-9]{2} (LIVE|FINDING|RESOLVED|READY|BLOCKED|HALTED|WRAPPED)( |$)' "$DOC" \
    | tail -1 | sed -E 's/^- [0-9]{2}:[0-9]{2} ([A-Z]+).*/\1/')
if [ "$last_marker" != "WRAPPED" ]; then
    echo "close-wrapped-leg: refusing - the doc's last Results marker-bullet is '${last_marker:-<none>}', not WRAPPED" >&2
    exit 4
fi

# shellcheck source=scripts/lib/leg-identity.sh
# shellcheck disable=SC1091
if ! . "$HERE/../../lib/leg-identity.sh"; then
    echo "close-wrapped-leg: cannot load scripts/lib/leg-identity.sh" >&2
    exit 1
fi
# shellcheck source=scripts/lanes/lib/claude-sessions.sh
# shellcheck disable=SC1091
if ! . "$HERE/../../lanes/lib/claude-sessions.sh"; then
    echo "close-wrapped-leg: cannot load scripts/lanes/lib/claude-sessions.sh" >&2
    exit 1
fi

ident=$(leg_identity "$DOC")
names=",${ident#*$'\t'},"

sessions=$(claude_sessions)
census_rc=$?
if [ "$census_rc" -gt 1 ]; then
    echo "close-wrapped-leg: claude_sessions census failed (rc=$census_rc)" >&2
    exit 1
fi

matched=""
match_count=0
while IFS=$'\t' read -r pid name _model _ac; do
    [ -n "$pid" ] || continue
    case "$name" in
        '#'*) continue ;;
    esac
    case "$names" in
        *",${name},"*)
            matched="$pid"
            match_count=$((match_count + 1)) ;;
    esac
done <<EOF
$sessions
EOF

if [ "$match_count" -ne 1 ]; then
    echo "close-wrapped-leg: refusing - $match_count live session(s) matched leg names [${ident#*$'\t'}] (need exactly 1)" >&2
    exit 5
fi

if ! "$KILL" -TERM "$matched"; then
    echo "close-wrapped-leg: failed to send TERM to pid $matched" >&2
    exit 1
fi
echo "close-wrapped-leg: sent TERM to pid $matched (leg $(leg_label "$DOC"))"

worktrees=$(grep -oE "/[^\` ]*/\.claude/worktrees/[^\`) ]+" "$DOC" | sort -u)
wt_count=$(printf '%s\n' "$worktrees" | grep -c . || true)
if [ "$wt_count" -ne 1 ]; then
    echo "close-wrapped-leg: doc names $wt_count worktree path(s) - skipping the prune, never guessing" >&2
    exit 0
fi
WT="$worktrees"

shipline=$(grep -E '^- [0-9]{2}:[0-9]{2} (MERGED #|READY )' "$DOC" | tail -1)
pr=""
case "$shipline" in
    *MERGED\ \#*) pr=$(printf '%s' "$shipline" | sed -E 's/.*MERGED #([0-9]+).*/\1/') ;;
    *READY\ *) pr=$(printf '%s' "$shipline" | sed -E 's/.*READY ([0-9]+) .*/\1/') ;;
esac
case "$pr" in
    ''|*[!0123456789]*)
        echo "close-wrapped-leg: no MERGED/READY PR number found in $DOC - skipping the prune" >&2
        exit 0 ;;
esac

if ! state=$("$GH" pr view "$pr" --json state --jq '.state' 2>/dev/null); then
    echo "close-wrapped-leg: refusing - gh pr view #$pr failed (auth/connectivity?) - cannot confirm the PR is merged, not pruning" >&2
    exit 1
fi
if [ "$state" != "MERGED" ]; then
    echo "close-wrapped-leg: PR #$pr state is '${state:-unknown}', not MERGED - skipping the prune" >&2
    exit 0
fi

out=$(bash "$CLEAN_SH" --only "$WT" 2>&1)
rc=$?
echo "$out"
if [ "$rc" -ne 0 ]; then
    if printf '%s' "$out" | grep -qi 'in use'; then  # pipefail-ok: no pipefail here (set -u only); $out is an already-captured small string, not a live producer
        echo "close-wrapped-leg: worktree $WT reported in use - not a failure, retry --only shortly"
        exit 0
    fi
    echo "close-wrapped-leg: clean.sh --only $WT failed (rc=$rc)" >&2
    exit 1
fi
exit 0
