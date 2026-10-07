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
# moved the leg preface to the hook's rule, a share of the --autocompact
# ceiling; HIMMEL-4710 set it to 75 % (150k) and made the guard OFF by default
# (on only by `headed-arm-leg.sh --context-guard compact|handoff`), with
# docs/internals/leg-context-guard.md the one reference.
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
GUARD="$DOCS/internals/leg-context-guard.md"
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

for f in "$PREFACE" "$BRIEF" "$CALIB" "$GUARD"; do
    [ -s "$f" ] || { echo "FAIL - missing $f"; exit 1; }
done

# The backticks in these needles are literal Markdown.
# shellcheck disable=SC2016
has   "preface states the ceiling-derived threshold (HIMMEL-4710)" "$PREFACE" '**Context past 75 % of your `--autocompact` ceiling'
has   "preface says the guard is off by default (HIMMEL-4710)" "$PREFACE" 'off by default'
has   "preface links the guard reference (HIMMEL-4710)" "$PREFACE" 'docs/internals/leg-context-guard.md'
lacks "preface drops the 65 % rule"         "$PREFACE" '65 ?%'
lacks "preface no longer calls compact the default" "$PREFACE" 'compact` \(the default\)'
has   "preface describes the compact mode"   "$PREFACE" 'CHECKPOINT <full sha of HEAD> pushed'
# shellcheck disable=SC2016
has   "preface describes the handoff mode"   "$PREFACE" '**`handoff`:**'
has   "preface names the autocompact backstop" "$PREFACE" 'autocompact'
lacks "preface carries no 60 % hand-off"     "$PREFACE" '60 ?%'
has   "brief template states the ceiling-derived threshold (HIMMEL-4710)" "$BRIEF" '75 % of the leg'"'"'s'
# shellcheck disable=SC2016
has   "brief template names how to turn it on" "$BRIEF"  '`--context-guard compact|handoff`'
has   "brief template says the guard is off by default" "$BRIEF" 'off by default'
lacks "brief template drops the 65 % rule"  "$BRIEF"   '65 ?%'
lacks "brief template drops the 75 % fill rule" "$BRIEF" '75 ?% fill'
lacks "brief template carries no 60 % fill"  "$BRIEF"   '60 ?% fill'
# shellcheck disable=SC2016
has  "calibration states the 75 % ceiling rule (HIMMEL-4710)" "$CALIB" 'Leg checkpoint or handover is at 75% of the leg'"'"'s `--autocompact` ceiling'
lacks "calibration drops the 75 % leg rule"  "$CALIB"   'Leg handover is at 75% context fill'
has   "preface names close-wrapped-leg.sh as the session end (HIMMEL-2414)" "$PREFACE" "the console's \`close-wrapped-leg.sh\` ends the session"
lacks "preface does not tell a leg to exit its own session (HIMMEL-2414)" "$PREFACE" 'closable-window banner, and \*\*exit\*\*'
lacks "calibration drops the 45 % leg rule"  "$CALIB"   'Leg handover is whichever limit arrives first: 45%'
# The one reference (HIMMEL-4710 REDIRECT item 3): every fact a leg or a console
# needs, in one place.
has   "guard doc: off by default"            "$GUARD"   'off by default'
has   "guard doc: how to turn it on"         "$GUARD"   '--context-guard compact'
has   "guard doc: the share override"        "$GUARD"   'HIMMEL_LEG_CONTEXT_SHARE'
has   "guard doc: the threshold arithmetic"  "$GUARD"   '157k'
has   "guard doc: the pushed CHECKPOINT"     "$GUARD"   'CHECKPOINT <full sha of HEAD> pushed'
has   "guard doc: the clean CHECKPOINT"      "$GUARD"   'CHECKPOINT <full sha of HEAD> clean'
has   "guard doc: the RESUME unlock"         "$GUARD"   'RESUME.md'
has   "guard doc: BLOCKED frees hand-off only" "$GUARD" 'hand-off calls and reads'
has   "guard doc: the one-line commit form"  "$GUARD"   '--trailer'
has   "guard doc: the bypass"                "$GUARD"   'LEG_CONTEXT_HANDOFF_OK=1'

if [ "$fails" -gt 0 ]; then
    echo "test-leg-handoff-threshold-docs: $fails failure(s)"
    exit 1
fi
echo "test-leg-handoff-threshold-docs: all passed"
