#!/usr/bin/env bash
# check-cr-best-effort.sh — CodeRabbit is best effort; nothing tracked may
# schedule, queue, or hold work on it (HIMMEL-3360).
#
# Operator ruling 2026-09-21: CodeRabbit is one CI-only reviewer beside the
# local critic panel. The merge gate is CI green + zero unresolved review
# threads + the /pr-check panel. A CodeRabbit finding that exists still
# blocks; CodeRabbit being absent, late, skipped or rate-limited never does,
# and nothing waits on it. Seven finished PRs were once held ~7 h because
# docs and memory taught "one review per hour account-wide, sequence the
# opens". That was the second drift, so the rule is a gate, not prose.
#
# Rule: a line that names CodeRabbit AND carries a scheduling/holding term is
# a violation. Terms: slot, queue, hourly, per hour, /hour, an hour apart,
# "wait for" (it / the review / its review / CodeRabbit / the App), re-trigger,
# full review, "budget the", "rounds are scarce". Negations are NOT parsed —
# a "never wait for it" next to the reviewer's name trips too — so state the
# rule without those words ("CodeRabbit is best effort, not gating"). The one
# escape is an
# explicit same-line marker for quoted history, like the ponytail convention:
#     cr-best-effort-ok: <why this line quotes the old behaviour>
#
# Scope (gate mode = tracked files, so a fresh clone with an empty memory
# directory gets the same verdict): docs/**, .claude/commands/**,
# .agents/skills/**, scripts/** (.sh and .md), CLAUDE.md, README.md.
# `*/fixtures/*` is excluded: frozen red-control copies of old scripts must
# stay byte-identical; so is this guard's own suite, whose RED controls are
# the old text by design. ponytail: single-line co-occurrence only — a sentence
# that wraps "CodeRabbit" and "slot" onto two lines is missed. Every instance
# this ticket removed sat on one line; revisit if a wrapped one appears.
#
# Usage:
#   check-cr-best-effort.sh            # gate mode: every tracked in-scope file
#   check-cr-best-effort.sh <file>...  # direct mode: the named files (tests)
# Exit: 0 clean · 1 violation(s) · 2 cannot evaluate (fail-closed).
set -uo pipefail

CR_RE='[Cc]ode[ -]?[Rr]abbit|CODE[ -]?RABBIT'
SCHED_RE='\b(review|hourly|free|cr) slots?\b|\bslots? (is |was )?(free|confirmed|across)\b|\bqueue (the|them|it)\b|\bqueued\b|\bsequence (the|them)\b|\bhourly\b|\bper hour\b|/hour\b|an hour apart|\bone (included )?review (per hour|at a time)\b|\bwait for (it|the review|its review|the app|a review|[Cc]ode[ -]?[Rr]abbit)\b|\bwait approximately\b|\bbudget the\b|rounds are scarce'
MARKER='cr-best-effort-ok:'

fail=0
report() {
    echo "→ check-cr-best-effort: $1:$2 schedules or holds work on CodeRabbit (it is best effort, never gating):" >&2
    echo "    $3" >&2
    echo "    Remove the wait/queue, or quote history with a same-line '$MARKER <reason>' marker." >&2
    fail=1
}

scan_file() {
    # One grep pipeline per file (a per-line fork is minutes over scripts/**).
    local f="$1" hits n line
    [ -r "$f" ] || { echo "check-cr-best-effort: cannot read $f" >&2; return 2; }
    # "merge queue" is GitHub's feature, not a CodeRabbit hold — blanked before the term match.
    hits=$(grep -nE "$CR_RE" -- "$f" 2>/dev/null | sed 's/merge queue/merge-Q/g' | grep -iE "$SCHED_RE" | grep -vF "$MARKER") || return 0
    while IFS= read -r line; do
        n="${line%%:*}"
        report "$f" "$n" "${line#*:}"
    done <<EOF
$hits
EOF
    return 0
}

if [ $# -gt 0 ]; then
    for f in "$@"; do scan_file "$f" || exit 2; done
else
    root=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "check-cr-best-effort: not a git repo — cannot evaluate" >&2; exit 2; }
    cd "$root" || exit 2
    files=$(git ls-files -- 'docs/*.md' 'docs/**/*.md' '.claude/commands/*.md' '.agents/skills/**/*.md' \
        'scripts/*.sh' 'scripts/**/*.sh' 'scripts/*.md' 'scripts/**/*.md' CLAUDE.md README.md 2>/dev/null) \
        || { echo "check-cr-best-effort: git ls-files failed — cannot evaluate" >&2; exit 2; }
    [ -n "$files" ] || { echo "check-cr-best-effort: no in-scope tracked files — cannot evaluate" >&2; exit 2; }
    while IFS= read -r f; do
        case "$f" in */fixtures/*|scripts/hooks/test-check-cr-best-effort.sh) continue ;; esac
        scan_file "$f" || exit 2
    done <<EOF
$files
EOF
fi

exit "$fail"
