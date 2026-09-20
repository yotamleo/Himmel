#!/usr/bin/env bash
# scripts/lanes/bench/scorecard/leg-over-by-day.sh - P0.1 scorecard recipe (HIMMEL-2977).
#
# Platform guard: no .ps1 twin, by design. POSIX bash 3.2+ over a Claude Code
# transcript (same JSONL on every platform); it runs under git bash unchanged.
#
# Adapted from the HIMMEL-2977 baseline Appendix B (leg-over-by-day.sh, leg
# N207, 2026-09-12): legs classified over/under a 200k avg-ctx threshold,
# bucketed by day. The baseline read a hand-curated "$S/leg-over.txt"
# (class + filename pairs) that no Appendix B script produces; this walks
# leg-role transcripts directly and classifies each one itself, over
# --since/--until instead of the baseline's fixed window.
#
# Usage: leg-over-by-day.sh --since <ISO8601> [--until <ISO8601>] [--threshold-k <n>]
set -u

usage() { echo "usage: leg-over-by-day.sh --since <ISO8601> [--until <ISO8601>] [--threshold-k <n>]" >&2; }

SINCE=""; UNTIL=""; THRESHOLD_K=200
while [ $# -gt 0 ]; do
    case "$1" in
        --since) SINCE="${2:?--since needs a value}"; shift 2 ;;
        --until) UNTIL="${2:?--until needs a value}"; shift 2 ;;
        --threshold-k) THRESHOLD_K="${2:?--threshold-k needs a value}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "leg-over-by-day: unknown argument: $1" >&2; usage; exit 2 ;;
    esac
done
[ -n "$SINCE" ] || { usage; exit 2; }

HERE="$(cd "$(dirname "$0")" && pwd)"
LEG_BURN="$HERE/../../leg-burn.sh"
# shellcheck source=lib/scorecard-lib.sh
. "$HERE/lib/scorecard-lib.sh"
sc_roots_check leg-over-by-day || exit 2

# GNU `date -d` first; BSD/macOS `date -j -f` fallback (same convention as
# leg-burn.sh's backdate()/transcript_mtime GNU-first/BSD-fallback comment).
to_epoch() {
    date -d "$1" +%s 2>/dev/null && return 0
    date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$(printf '%s' "$1" | sed 's/\.[0-9]*Z$/Z/')" +%s 2>/dev/null
}
SINCE_EPOCH=$(to_epoch "$SINCE") || { echo "leg-over-by-day: bad --since: $SINCE" >&2; exit 2; }
UNTIL_EPOCH=""
if [ -n "$UNTIL" ]; then
    UNTIL_EPOCH=$(to_epoch "$UNTIL") || { echo "leg-over-by-day: bad --until: $UNTIL" >&2; exit 2; }
fi
case "$THRESHOLD_K" in
    ''|*[!0-9]*) echo "leg-over-by-day: --threshold-k must be a plain non-negative integer: $THRESHOLD_K" >&2; exit 2 ;;
esac
case "$THRESHOLD_K" in
    0) ;;
    0*) echo "leg-over-by-day: --threshold-k must not have a leading zero: $THRESHOLD_K" >&2; exit 2 ;;
esac
THRESHOLD=$((THRESHOLD_K * 1000))

ts_of() { grep -o '"timestamp":"[0-9TZ:.-]*"' "$1" 2>/dev/null | "$2" -1 | cut -d'"' -f4; }
day_of() { printf '%s' "$1" | cut -c1-10; }

FAILS=""; FILES=""; DISC_ERR=""; DAYS=""
# trap first: a later mktemp failing must not leak the files already created
trap 'rm -f "$FAILS" "$FILES" "$DISC_ERR" "$DAYS" "$SC_COV"' EXIT
FAILS=$(mktemp "${TMPDIR:-/tmp}/leg-over-by-day-fails.XXXXXX") || { echo "leg-over-by-day: mktemp failed" >&2; exit 1; }
FILES=$(mktemp "${TMPDIR:-/tmp}/leg-over-by-day-files.XXXXXX") || { echo "leg-over-by-day: mktemp failed" >&2; exit 1; }
DISC_ERR=$(mktemp "${TMPDIR:-/tmp}/leg-over-by-day-discerr.XXXXXX") || { echo "leg-over-by-day: mktemp failed" >&2; exit 1; }
DAYS=$(mktemp "${TMPDIR:-/tmp}/leg-over-by-day-days.XXXXXX") || { echo "leg-over-by-day: mktemp failed" >&2; exit 1; }
sc_cov_init || exit 1

# A discovery error must not vanish (the agg-burn.sh HIMMEL-2977 rule).
if ! sc_discover "$FILES" "$DISC_ERR"; then
    echo "leg-over-by-day: transcript discovery failed under the transcript root(s) - refusing to print a partial table:" >&2
    cat "$DISC_ERR" >&2
    exit 1
fi

while IFS= read -r f; do
    # title_of silences read errors: an unreadable file would read as an empty
    # title and be misfiled as an intentional not-leg exclusion
    [ -r "$f" ] || { sc_cov unreadable; continue; }
    case "$f" in */subagents/*) sc_cov subagent; continue ;; esac
    name=$(title_of "$f")
    [ "$(role_of "$name")" = leg ] || { sc_cov not-leg; continue; }

    first_ts=$(ts_of "$f" head)
    [ -n "$first_ts" ] || { sc_cov no-timestamp; continue; }
    last_ts=$(ts_of "$f" tail)
    first_epoch=$(to_epoch "$first_ts") || { sc_cov bad-timestamp; continue; }
    last_epoch=$(to_epoch "${last_ts:-$first_ts}") || { sc_cov bad-timestamp; continue; }
    [ "$last_epoch" -ge "$SINCE_EPOCH" ] || { sc_cov out-of-window; continue; }
    if [ -n "$UNTIL_EPOCH" ] && [ "$first_epoch" -ge "$UNTIL_EPOCH" ]; then sc_cov out-of-window; continue; fi

    line=$(bash "$LEG_BURN" "$f" 2>/dev/null) || { echo "$f" >> "$FAILS"; sc_cov leg-burn-failed; continue; }
    sc_cov parsed
    avg=$(printf '%s' "$line" | grep -o 'avg-ctx=[^ ]*' | cut -d= -f2)
    case "$avg" in
        *k) avg_n=$(awk -v n="${avg%k}" 'BEGIN{printf "%d", n*1000}') ;;
        *) avg_n="$avg" ;;
    esac
    cls="under"
    [ "${avg_n:-0}" -gt "$THRESHOLD" ] && cls="over"
    printf '%s %s\n' "$(day_of "$first_ts")" "$cls" >> "$DAYS"
done < "$FILES"
sort "$DAYS" | uniq -c
sc_cov_line "$(wc -l < "$FILES" | tr -d ' ')" "$SC_ROOT_COUNT"

n_fail=$(wc -l < "$FAILS")
if [ "$n_fail" -gt 0 ]; then
    echo "leg-over-by-day: WARNING: $n_fail transcript(s) skipped due to leg-burn.sh failure" >&2
fi
