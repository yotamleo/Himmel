#!/usr/bin/env bash
# scripts/lanes/bench/scorecard/test-leg-over-by-day.sh - RED/GREEN suite for
# leg-over-by-day.sh (HIMMEL-2977 P0 script shipped in #689 with no paired
# test; HIMMEL-2981). House check/contains style, per
# scripts/test-context-fill.sh.
#
# leg-over-by-day.sh flags/branches covered:
#   --since (required, exit 2 if missing)
#   --until (optional)
#   --threshold-k (default 200; must be a plain non-negative integer with no
#     leading zero, else exit 2)
#   unknown argument -> exit 2
#   SCORECARD_PROJECTS_DIR missing -> exit 2
#   avg_n > THRESHOLD is a STRICT over/under boundary (exactly-at is under)
#   only leg-role, non-subagent transcripts are bucketed - console/relay/
#     other-titled and subagent transcripts are excluded outright
#   since-window inclusive lower edge / until-window exclusive upper edge
#   leg-burn.sh failure -> FAILS + WARNING on stderr, run still exits 0
#
# Platform guard: no .ps1 twin, by design. POSIX bash 3.2+; it runs under
# git bash unchanged.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
OVER_BY_DAY="$HERE/leg-over-by-day.sh"
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
export SCORECARD_PROJECTS_DIR="$HERE/fixtures/leg-over-by-day/boundary"
"$OVER_BY_DAY" >/dev/null 2>&1
check_exit "usage: missing --since exits 2" "$?" "2"

# --- (b) usage: unknown argument -> exit 2
"$OVER_BY_DAY" --since 2026-01-01T00:00:00Z --bogus foo >/dev/null 2>&1
check_exit "usage: unknown argument exits 2" "$?" "2"

# --- (c) usage: missing transcript root dir -> exit 2
export SCORECARD_PROJECTS_DIR="$HERE/fixtures/leg-over-by-day/does-not-exist"
"$OVER_BY_DAY" --since 2026-01-01T00:00:00Z >/dev/null 2>&1
check_exit "usage: missing SCORECARD_PROJECTS_DIR exits 2" "$?" "2"

# --- (d) --threshold-k: non-numeric -> exit 2
export SCORECARD_PROJECTS_DIR="$HERE/fixtures/leg-over-by-day/boundary"
"$OVER_BY_DAY" --since 2026-01-01T00:00:00Z --threshold-k abc >/dev/null 2>&1
check_exit "threshold-k: non-numeric value exits 2" "$?" "2"

# --- (e) --threshold-k: leading zero -> exit 2
"$OVER_BY_DAY" --since 2026-01-01T00:00:00Z --threshold-k 007 >/dev/null 2>&1
check_exit "threshold-k: leading-zero value exits 2" "$?" "2"

# --- (f) boundary: exactly at threshold is under, strictly above is over
# (avg-ctx=200.0k -> avg_n=200000, default threshold-k=200 -> THRESHOLD=200000)
BOUNDARY_OUT=$("$OVER_BY_DAY" --since 2026-01-01T00:00:00Z 2>/dev/null)
check_exit "boundary: exits 0" "$?" "0"
check_contains "boundary: avg exactly at threshold classifies under" \
    "$BOUNDARY_OUT" "2026-08-01 under"
check_contains "boundary: avg strictly above threshold classifies over" \
    "$BOUNDARY_OUT" "2026-08-01 over"

# --- (g) --threshold-k custom: the same 200.0k session flips class when the
# threshold moves across it. Assert BOTH sessions land in "over" and no
# "under" bucket remains — asserting only "2026-08-01 over" is present would
# also pass with --threshold-k silently ignored, since the fixture's other
# session is already over at the default threshold-k=200.
CUSTOM_LOW=$("$OVER_BY_DAY" --since 2026-01-01T00:00:00Z --threshold-k 199 2>/dev/null)
check_exit "threshold-k custom: exits 0" "$?" "0"
check "threshold-k custom: both sessions now over, none under" \
    "$(printf '%s\n' "$CUSTOM_LOW" | grep -v '^coverage:' | awk '{$1=$1; print}' | sort)" "2 2026-08-01 over"
check "threshold-k custom: coverage triple sits beside the table (HIMMEL-3269)" \
    "$(printf '%s\n' "$CUSTOM_LOW" | grep '^coverage:')" "coverage: roots=1 discovered=2 parsed=2 skipped=0"

# --- (h) exclusion: console/relay/other-titled and subagent transcripts are
# never bucketed; the two leg-titled transcripts survive - one in the old
# `...legN<k>...` scheme, one in the current `<TICKET>-N<k>-<slug>` scheme
# (HIMMEL-3269: the legN pattern alone matched 0 of the current legs)
export SCORECARD_PROJECTS_DIR="$HERE/fixtures/leg-over-by-day/exclusion"
EXCLUSION_OUT=$("$OVER_BY_DAY" --since 2026-01-01T00:00:00Z 2>/dev/null)
check_exit "exclusion: exits 0" "$?" "0"
check "exclusion: only the leg-titled (both schemes), non-subagent transcripts are bucketed" \
    "$(printf '%s\n' "$EXCLUSION_OUT" | awk '{s+=$1} END{print s+0}')" "2"
check_contains "exclusion: the surviving row is the leg sessions' day/class" \
    "$EXCLUSION_OUT" "2026-08-10 under"
check "exclusion: coverage names what was skipped and why" \
    "$(printf '%s\n' "$EXCLUSION_OUT" | grep '^coverage:')" \
    "coverage: roots=1 discovered=6 parsed=2 skipped=4 (not-leg=3 subagent=1)"

# --- (i) since-edge: last_epoch >= SINCE_EPOCH is inclusive
export SCORECARD_PROJECTS_DIR="$HERE/fixtures/leg-over-by-day/since-edge"
SINCE_OUT=$("$OVER_BY_DAY" --since 2026-08-05T00:00:00Z 2>/dev/null)
check_exit "since-edge: exits 0" "$?" "0"
check "since-edge: only the session whose last activity is exactly at --since is included" \
    "$(printf '%s\n' "$SINCE_OUT" | awk '{s+=$1} END{print s+0}')" "1"

# --- (j) until-edge: first_epoch >= UNTIL_EPOCH is exclusive
export SCORECARD_PROJECTS_DIR="$HERE/fixtures/leg-over-by-day/until-edge"
UNTIL_OUT=$("$OVER_BY_DAY" --since 2026-01-01T00:00:00Z --until 2026-08-06T00:00:00Z 2>/dev/null)
check_exit "until-edge: exits 0" "$?" "0"
check "until-edge: a session whose first activity is exactly at --until is excluded" \
    "$(printf '%s\n' "$UNTIL_OUT" | awk '{s+=$1} END{print s+0}')" "1"

# --- (k) leg-burn.sh failure -> FAILS + WARNING, run still exits 0
export SCORECARD_PROJECTS_DIR="$HERE/fixtures/leg-over-by-day/malformed"
MALFORMED_ERR=$("$OVER_BY_DAY" --since 2026-01-01T00:00:00Z 2>&1 >/dev/null)
"$OVER_BY_DAY" --since 2026-01-01T00:00:00Z >/dev/null 2>&1
MALFORMED_EXIT=$?
check_contains "malformed: a leg-burn.sh failure prints a skip WARNING" \
    "$MALFORMED_ERR" "WARNING: 1 transcript(s) skipped due to leg-burn.sh failure"
check_exit "malformed: a skipped transcript still exits 0" "$MALFORMED_EXIT" "0"

# --- (l) unreadable: a listed-but-unreadable transcript is named `unreadable` in
# the coverage line, not misfiled as an intentional `not-leg` exclusion
# (HIMMEL-3269 CR round 1: title_of suppresses read errors, so an empty title
# looked like a non-leg session). Skipped when chmod cannot make a file
# unreadable (running as root).
UNR_DIR=$(mktemp -d "${TMPDIR:-/tmp}/lod-unreadable.XXXXXX")
cp "$HERE"/fixtures/leg-over-by-day/boundary/*.jsonl "$UNR_DIR"/
UNR_FILE=$(find "$UNR_DIR" -name '*.jsonl' | sort | head -1)
chmod 000 "$UNR_FILE"
if [ -r "$UNR_FILE" ]; then
    echo "ok - unreadable: SKIPPED (chmod 000 leaves the file readable, e.g. running as root)"
else
    export SCORECARD_PROJECTS_DIR="$UNR_DIR"
    UNR_OUT=$("$OVER_BY_DAY" --since 2026-01-01T00:00:00Z 2>/dev/null)
    check_contains "unreadable: the coverage line names the unreadable transcript" \
        "$(printf '%s\n' "$UNR_OUT" | grep '^coverage:')" "unreadable=1"
fi
chmod 600 "$UNR_FILE"; rm -rf "$UNR_DIR"

echo "---"
if [ "$fails" -eq 0 ]; then
    echo "PASS - test-leg-over-by-day.sh: 0 failures"
    exit 0
else
    echo "FAIL - test-leg-over-by-day.sh: $fails failure(s)"
    exit 1
fi
