#!/usr/bin/env bash
# test-leg-handoff-threshold-docs.sh — HIMMEL-4089 ask 2. Pins the leg context
# hand-off threshold where a leg and a console read it.
#
# Every leg launch carries an autocompact ceiling (headed-arm-leg.sh refuses
# one without it), so compaction is a backstop, not data loss. Measured over
# 399 leg sessions (2026-09-27..10-03): 349 compacted, 309 of those still
# reached WRAPPED after their last compaction, and every observed compaction
# fired between 157k and 176k of the 200k window. 75 % (150k) sits below all
# of them. The old 60 % hand-off was the churn, not the safety. HIMMEL-4569
# moved the leg preface to the hook's rule: 65 % of the --autocompact ceiling
# (130k), checkpoint (compact mode) or RESUME (handoff mode).
#
# The judge preface keeps 60 %: a judge holds design-grade reasoning in
# context and loses it at compaction (judge-brief-template.md).
#
# Docs-only reads, no network, no live state. PLATFORM GUARD: no .ps1 twin —
# Bash 3.2, grep only.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DOCS="${DOCS:-$HERE/../../docs}"
PREFACE="$DOCS/handover/leg-preface.md"
BRIEF="$DOCS/handover/leg-brief-template.md"
CALIB="$DOCS/internals/lane-calibration.md"
fails=0

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
has() {  # has <label> <file> <fixed needle>
    if grep -qF -- "$3" "$2"; then pass "$1"; else fail "$1 (missing '$3')"; fi
}
lacks() {  # lacks <label> <file> <extended regex>
    local hit rc
    hit="$(grep -nE -m 1 -- "$3" "$2")"; rc=$?
    case "$rc" in
        1) pass "$1" ;;
        0) fail "$1 (found: $hit)" ;;
        *) fail "$1 (grep rc=$rc)" ;;  # a grep error is never a clean absence
    esac
}

for f in "$PREFACE" "$BRIEF" "$CALIB"; do
    [ -s "$f" ] || { echo "FAIL - missing $f"; exit 1; }
done

# The backticks in these needles are literal Markdown.
# shellcheck disable=SC2016
has   "preface states the ceiling-derived threshold (HIMMEL-4569)" "$PREFACE" '**Context past 65 % of your `--autocompact` ceiling:**'
has   "preface describes the compact mode"   "$PREFACE" 'CHECKPOINT <full sha of HEAD> pushed'
# shellcheck disable=SC2016
has   "preface describes the handoff mode"   "$PREFACE" '**`handoff`:**'
has   "preface names the autocompact backstop" "$PREFACE" 'autocompact'
lacks "preface carries no 60 % hand-off"     "$PREFACE" '60 ?%'
has   "brief template hands off at 75 %"     "$BRIEF"   '≥75 % fill'
lacks "brief template carries no 60 % fill"  "$BRIEF"   '60 ?% fill'
has   "calibration states the 75 % leg rule" "$CALIB"   'Leg handover is at 75% context fill'
has   "preface names close-wrapped-leg.sh as the session end (HIMMEL-2414)" "$PREFACE" "the console's \`close-wrapped-leg.sh\` ends the session"
lacks "preface does not tell a leg to exit its own session (HIMMEL-2414)" "$PREFACE" 'closable-window banner, and \*\*exit\*\*'
lacks "calibration drops the 45 % leg rule"  "$CALIB"   'Leg handover is whichever limit arrives first: 45%'

if [ "$fails" -gt 0 ]; then
    echo "test-leg-handoff-threshold-docs: $fails failure(s)"
    exit 1
fi
echo "test-leg-handoff-threshold-docs: all passed"
