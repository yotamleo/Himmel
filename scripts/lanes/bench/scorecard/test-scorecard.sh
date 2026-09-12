#!/usr/bin/env bash
# scripts/lanes/bench/scorecard/test-scorecard.sh - RED/GREEN suite for
# agg-postpin.sh's --exclude-straddle, --cohort and counted_shifts column
# (HIMMEL-2977 Task 3 Step 2). House check/contains style, per
# scripts/test-context-fill.sh.
#
# Platform guard: no .ps1 twin, by design. POSIX bash 3.2+; it runs under
# git bash unchanged.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
POSTPIN="$HERE/agg-postpin.sh"
fails=0

check() {
    name="$1"; actual="$2"; expected="$3"
    if [ "$actual" = "$expected" ]; then
        echo "ok - $name"
    else
        echo "FAIL - $name: expected [$expected] got [$actual]"
        fails=$((fails + 1))
    fi
}

session_count() {
    # the role's "ALL"-model row already carries the total session count
    # in the sessions column (field 3) - read it directly.
    printf '%s\n' "$1" | awk -F'\t' -v role="$2" '$1==role && $2=="ALL" {print $3; found=1} END{if(!found) print 0}'
}

# --- (a) straddle: before/after/straddling fixtures, T = 2026-09-03T00:00:00Z
export SCORECARD_PROJECTS_DIR="$HERE/fixtures/straddle"
unset SCORECARD_LAUNCH_LOG_DIR

WITHOUT_STRADDLE=$("$POSTPIN" --since 2026-09-03T00:00:00Z --role leg 2>/dev/null)
check "straddle: without --exclude-straddle counts 2 sessions" \
    "$(session_count "$WITHOUT_STRADDLE" leg)" "2"

WITH_STRADDLE=$("$POSTPIN" --since 2026-09-03T00:00:00Z --exclude-straddle 2026-09-03T00:00:00Z --role leg 2>/dev/null)
check "straddle: with --exclude-straddle counts 1 session" \
    "$(session_count "$WITH_STRADDLE" leg)" "1"

# --- (b) cohort: leg-impl pair, --cohort counts 1 of 2
export SCORECARD_PROJECTS_DIR="$HERE/fixtures/cohort"
export SCORECARD_LAUNCH_LOG_DIR="$HERE/fixtures/cohort/launch-logs"

WITHOUT_COHORT=$("$POSTPIN" --since 2026-01-01T00:00:00Z --role leg 2>/dev/null)
check "cohort: without --cohort counts 3 sessions" \
    "$(session_count "$WITHOUT_COHORT" leg)" "3"

WITH_COHORT=$("$POSTPIN" --since 2026-01-01T00:00:00Z --role leg --cohort leg-impl 2>/dev/null)
check "cohort: --cohort leg-impl counts 1 of 3 (excludes no-log and leg-impl-other)" \
    "$(session_count "$WITH_COHORT" leg)" "1"

# --- (c) shift: 60 Fable + 50 Sonnet console-role calls -> counted_shifts=1
export SCORECARD_PROJECTS_DIR="$HERE/fixtures/shift"
unset SCORECARD_LAUNCH_LOG_DIR

SHIFT_OUT=$("$POSTPIN" --since 2026-01-01T00:00:00Z --role console 2>/dev/null)
COUNTED=$(printf '%s\n' "$SHIFT_OUT" | awk -F'\t' '$1=="console" && $2=="ALL" {print $NF}')
check "shift: >=100 console-role calls -> counted_shifts=1" "$COUNTED" "1"

# --- (d) shift: 10 console-role calls (< 100) -> counted_shifts=0, disproving
# a hardcoded counted_shifts=1
export SCORECARD_PROJECTS_DIR="$HERE/fixtures/shift-under"
unset SCORECARD_LAUNCH_LOG_DIR

SHIFT_UNDER_OUT=$("$POSTPIN" --since 2026-01-01T00:00:00Z --role console 2>/dev/null)
COUNTED_UNDER=$(printf '%s\n' "$SHIFT_UNDER_OUT" | awk -F'\t' '$1=="console" && $2=="ALL" {print $NF}')
check "shift: <100 console-role calls -> counted_shifts=0" "$COUNTED_UNDER" "0"

echo "---"
if [ "$fails" -eq 0 ]; then
    echo "PASS - test-scorecard.sh: 0 failures"
    exit 0
else
    echo "FAIL - test-scorecard.sh: $fails failure(s)"
    exit 1
fi
