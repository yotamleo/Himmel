#!/usr/bin/env bash
# scripts/lanes/bench/scorecard/test-leg-relaunch.sh - RED/GREEN suite for
# leg-relaunch.sh (HIMMEL-2977 P0 script shipped in #689 with no paired test;
# HIMMEL-2981). House check/contains style, per scripts/test-context-fill.sh.
#
# leg-relaunch.sh flags/branches covered:
#   --since (required, exit 2 if missing)
#   --until (optional)
#   unknown argument -> exit 2
#   SCORECARD_HANDOVER_DIR missing/unset with no configured handover -> exit 2
#   runs = highest N in "> **RUN N NOTE" blocks, default 1 when absent;
#     relaunches = runs-1
#   blocked_bullets = "- [HH:MM] BLOCKED" lines
#   wrapped_blocked = "- [HH:MM] WRAPPED ... BLOCKED" lines (distinct from,
#     and not double-counted into, blocked_bullets)
#   doc_date = the LAST YYYY-MM-DD substring in the filename (not the first)
#   since/until are day-truncated; since is inclusive, until is exclusive
#   TOTAL row aggregates n/relaunches(+mean)/blocked(+mean)/wrapped
#   the handover-doc glob ignores filenames with no legN token or no date
#
# Platform guard: no .ps1 twin, by design. POSIX bash 3.2+; it runs under
# git bash unchanged.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
RELAUNCH="$HERE/leg-relaunch.sh"
fails=0

check_exit() {
    name="$1"; actual="$2"; expected="$3"
    if [ "$actual" = "$expected" ]; then
        echo "ok - $name"
    else
        echo "FAIL - $name: expected exit [$expected] got [$actual]"
        fails=$((fails + 1))
    fi
}

check_contains() {
    name="$1"; haystack="$2"; needle="$3"
    case "$haystack" in
        *"$needle"*) echo "ok - $name" ;;
        *) echo "FAIL - $name: expected to contain [$needle] in [$haystack]"; fails=$((fails + 1)) ;;
    esac
}

check() {
    name="$1"; actual="$2"; expected="$3"
    if [ "$actual" = "$expected" ]; then
        echo "ok - $name"
    else
        echo "FAIL - $name: expected [$expected] got [$actual]"
        fails=$((fails + 1))
    fi
}

# --- (a) usage: missing --since -> exit 2
export SCORECARD_HANDOVER_DIR="$HERE/fixtures/leg-relaunch/main"
"$RELAUNCH" >/dev/null 2>&1
check_exit "usage: missing --since exits 2" "$?" "2"

# --- (b) usage: unknown argument -> exit 2
"$RELAUNCH" --since 2026-01-01T00:00:00Z --bogus foo >/dev/null 2>&1
check_exit "usage: unknown argument exits 2" "$?" "2"

# --- (c) SCORECARD_HANDOVER_DIR pointed at a nonexistent path -> exit 2
export SCORECARD_HANDOVER_DIR="$HERE/fixtures/leg-relaunch/does-not-exist"
"$RELAUNCH" --since 2026-01-01T00:00:00Z >/dev/null 2>&1
check_exit "handover dir: nonexistent SCORECARD_HANDOVER_DIR exits 2" "$?" "2"

# --- (d)-(h) main: an original doc (no RUN block, one BLOCKED bullet) and its
# "b"-successor (RUN 2 NOTE, one WRAPPED...BLOCKED bullet)
export SCORECARD_HANDOVER_DIR="$HERE/fixtures/leg-relaunch/main"
MAIN_OUT=$("$RELAUNCH" --since 2026-01-01T00:00:00Z 2>/dev/null)
check_exit "main: exits 0" "$?" "0"
check_contains "main: no RUN block defaults to runs=1, relaunches=0" \
    "$MAIN_OUT" "$(printf 'legN9200\t1\t0\t1\t0\t')"
check_contains "main: a RUN 2 NOTE block yields runs=2, relaunches=1" \
    "$MAIN_OUT" "$(printf 'legN9200\t2\t1\t0\t1\t')"
check_contains "main: TOTAL row aggregates n/relaunches/blocked/wrapped across both docs" \
    "$MAIN_OUT" "$(printf 'TOTAL(n=2)\t-\t1 (mean 0.50)\t1 (mean 0.50)\t1\t-')"
check_contains "main: coverage triple beside the TOTAL row" \
    "$MAIN_OUT" "coverage: discovered=2 parsed=2 skipped=0"

# --- (i) doc_date is the LAST YYYY-MM-DD substring in the filename, not the
# first: a --since after the (wrong) first date but before the (right) last
# date only includes the doc if the last date is what's actually used
export SCORECARD_HANDOVER_DIR="$HERE/fixtures/leg-relaunch/two-dates"
TWO_DATES_OUT=$("$RELAUNCH" --since 2026-08-01T00:00:00Z 2>/dev/null)
check_exit "two-dates: exits 0" "$?" "0"
check_contains "two-dates: doc_date uses the LAST date in the filename" \
    "$TWO_DATES_OUT" "legN9210"

# --- (j) since-edge: doc_epoch >= SINCE_EPOCH is the inclusive lower edge
# (day-truncated)
export SCORECARD_HANDOVER_DIR="$HERE/fixtures/leg-relaunch/since-edge"
SINCE_OUT=$("$RELAUNCH" --since 2026-08-03T00:00:00Z 2>/dev/null)
check_exit "since-edge: exits 0" "$?" "0"
check "since-edge: only the doc dated exactly at --since's day is included" \
    "$(printf '%s\n' "$SINCE_OUT" | grep -c '^legN')" "1"
check_contains "since-edge: the surviving doc is the one at the boundary" "$SINCE_OUT" "legN9221"

# --- (k) until-edge: doc_epoch >= UNTIL_EPOCH is the exclusive upper edge
export SCORECARD_HANDOVER_DIR="$HERE/fixtures/leg-relaunch/until-edge"
UNTIL_OUT=$("$RELAUNCH" --since 2026-01-01T00:00:00Z --until 2026-08-06T00:00:00Z 2>/dev/null)
check_exit "until-edge: exits 0" "$?" "0"
check "until-edge: a doc dated exactly at --until's day is excluded" \
    "$(printf '%s\n' "$UNTIL_OUT" | grep -c '^legN')" "1"
check_contains "until-edge: the surviving doc is the one before the boundary" "$UNTIL_OUT" "legN9230"

# --- (l) the handover-doc glob ignores filenames with no legN token/no date
export SCORECARD_HANDOVER_DIR="$HERE/fixtures/leg-relaunch/ignore-nonmatching"
IGNORE_OUT=$("$RELAUNCH" --since 2026-01-01T00:00:00Z 2>/dev/null)
check_exit "ignore-nonmatching: exits 0" "$?" "0"
check "ignore-nonmatching: a filename with no legN token/date is not picked up" \
    "$(printf '%s\n' "$IGNORE_OUT" | grep -c '^legN')" "1"
# HIMMEL-3269: a dated doc the metric does not read (current `<TICKET>-N<k>-`
# naming) is counted as skipped with its reason, not silently absent
check "ignore-nonmatching: the unread doc shows up in the coverage triple with its reason" \
    "$(printf '%s\n' "$IGNORE_OUT" | grep '^coverage:')" "coverage: discovered=2 parsed=1 skipped=1 (no-leg-token=1)"

# --- (m) leg numbers of differing digit counts sort numerically, not
# lexicographically (legN9 < legN10 < legN207 < legN1000)
export SCORECARD_HANDOVER_DIR="$HERE/fixtures/leg-relaunch/sort-order"
SORT_OUT=$("$RELAUNCH" --since 2026-01-01T00:00:00Z 2>/dev/null)
check_exit "sort-order: exits 0" "$?" "0"
LEG_ORDER=$(printf '%s\n' "$SORT_OUT" | grep -oE '^legN[0-9]+' | tr '\n' ',')
check "sort-order: legs are ordered numerically by leg number, not lexicographically" \
    "$LEG_ORDER" "legN9,legN10,legN207,legN1000,"

# --- (n) portability guard: GNU-only `sort -V` must not appear in a script
# whose header declares POSIX bash 3.2+
SORT_V_COUNT=$(grep -c 'sort -V' "$RELAUNCH")
check "portability: leg-relaunch.sh does not use GNU-only sort -V" "$SORT_V_COUNT" "0"

# --- (o) unreadable: a listed-but-unreadable doc is named `unreadable` in the
# coverage line, not counted as parsed with a default run count (HIMMEL-3269 CR
# round 1). Skipped when chmod cannot make a file unreadable (running as root).
UNR_DIR=$(mktemp -d "${TMPDIR:-/tmp}/relaunch-unreadable.XXXXXX") || { echo "FAIL - unreadable: mktemp -d"; exit 1; }
cp "$HERE"/fixtures/leg-relaunch/main/* "$UNR_DIR"/ || { echo "FAIL - unreadable: cp fixture"; exit 1; }
UNR_FILE=$(find "$UNR_DIR" -type f | sort | head -1)
[ -n "$UNR_FILE" ] || { echo "FAIL - unreadable: no fixture file copied"; exit 1; }
chmod 000 "$UNR_FILE" || { echo "FAIL - unreadable: chmod 000"; exit 1; }
if [ -r "$UNR_FILE" ]; then
    echo "ok - unreadable: SKIPPED (chmod 000 leaves the file readable, e.g. running as root)"
else
    export SCORECARD_HANDOVER_DIR="$UNR_DIR"
    UNR_OUT=$("$RELAUNCH" --since 2026-01-01T00:00:00Z 2>/dev/null)
    check "unreadable: the coverage line names the unreadable doc and does not count it parsed" \
        "$(printf '%s\n' "$UNR_OUT" | grep '^coverage:')" "coverage: discovered=2 parsed=1 skipped=1 (unreadable=1)"
fi
chmod 600 "$UNR_FILE"; rm -rf "$UNR_DIR"

echo "---"
if [ "$fails" -eq 0 ]; then
    echo "PASS - test-leg-relaunch.sh: 0 failures"
    exit 0
else
    echo "FAIL - test-leg-relaunch.sh: $fails failure(s)"
    exit 1
fi
