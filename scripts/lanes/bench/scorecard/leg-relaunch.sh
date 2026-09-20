#!/usr/bin/env bash
# scripts/lanes/bench/scorecard/leg-relaunch.sh - P0.1 scorecard recipe (HIMMEL-2977).
#
# Platform guard: no .ps1 twin, by design. POSIX bash 3.2+ over plain handover
# markdown files; it runs under git bash unchanged.
#
# Adapted from the HIMMEL-2977 baseline Appendix B (leg-relaunch.sh, leg
# N207, 2026-09-12): per leg handover doc,
#   runs      = highest N among "> **RUN N NOTE" preface blocks (1 if none); relaunches = runs-1
#   blocked   = Results bullets whose status word is BLOCKED
#   wrapped_blocked = Results bullets "WRAPPED ... BLOCKED"
# The baseline hardcoded its leg range (legN(19[5-9]|20[0-6])); this filters
# by the YYYY-MM-DD date embedded in each handover doc's filename against
# --since/--until instead.
#
# Usage: leg-relaunch.sh --since <ISO8601> [--until <ISO8601>]
set -u

usage() { echo "usage: leg-relaunch.sh --since <ISO8601> [--until <ISO8601>]" >&2; }

SINCE=""; UNTIL=""
while [ $# -gt 0 ]; do
    case "$1" in
        --since) SINCE="${2:?--since needs a value}"; shift 2 ;;
        --until) UNTIL="${2:?--until needs a value}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "leg-relaunch: unknown argument: $1" >&2; usage; exit 2 ;;
    esac
done
[ -n "$SINCE" ] || { usage; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../../lib/load-dotenv.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../../../lib/load-dotenv.sh"
# shellcheck source=../../../lib/user-slug.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../../../lib/user-slug.sh"
# shellcheck source=../../../lib/handover-path.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../../../lib/handover-path.sh"
load_dotenv HANDOVER_DIR USER_SLUG

if [ -n "${SCORECARD_HANDOVER_DIR:-}" ]; then
    H="$SCORECARD_HANDOVER_DIR"
elif handover_base=$(handover_root 2>/dev/null) && handover_slug=$(user_slug 2>/dev/null); then
    H="$handover_base/$handover_slug/himmel"
else
    H=""
fi
if ! { [ -n "$H" ] && [ -d "$H" ]; }; then
    echo "leg-relaunch: no handover dir (set SCORECARD_HANDOVER_DIR, or configure HANDOVER_DIR/USER_SLUG via /handover-setup)" >&2
    exit 2
fi

# GNU `date -d` first; BSD/macOS `date -j -f` fallback (same convention as
# leg-burn.sh's backdate()/transcript_mtime GNU-first/BSD-fallback comment).
to_epoch() {
    date -d "$1" +%s 2>/dev/null && return 0
    date -j -u -f '%Y-%m-%d' "$1" +%s 2>/dev/null
}
SINCE_DAY=$(printf '%s' "$SINCE" | cut -c1-10)
SINCE_EPOCH=$(to_epoch "$SINCE_DAY") || { echo "leg-relaunch: bad --since: $SINCE" >&2; exit 2; }
UNTIL_EPOCH=""
if [ -n "$UNTIL" ]; then
    UNTIL_EPOCH=$(to_epoch "$(printf '%s' "$UNTIL" | cut -c1-10)") || { echo "leg-relaunch: bad --until: $UNTIL" >&2; exit 2; }
fi

# HIMMEL-3269 coverage: "discovered" is every dated doc in the handover dir, not
# just the ones the metric reads - so a doc whose name carries no `legN<k>` token
# (the current `<TICKET>-N<k>-<slug>` scheme among them) is counted as skipped
# with its reason instead of being silently absent from the discovered set.
# ponytail: the leg token is still `legN<k>`; docs named `<TICKET>-N<k>-...` are
# reported as no-leg-token, not measured.
# shellcheck source=lib/scorecard-lib.sh
. "$SCRIPT_DIR/lib/scorecard-lib.sh"
LIST=""
trap 'rm -f "$LIST" "$SC_COV"' EXIT
LIST=$(mktemp "${TMPDIR:-/tmp}/leg-relaunch-list.XXXXXX") || { echo "leg-relaunch: mktemp failed" >&2; exit 1; }
sc_cov_init || exit 1
for path in "$H"/*[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*; do
    [ -f "$path" ] && printf '%s\n' "$path" >> "$LIST"
done

printf 'leg\truns\trelaunches\tblocked_bullets\twrapped_blocked\tfile\n'
while IFS= read -r path; do
    f=$(basename "$path")
    case "$f" in *legN[0-9]*) ;; *) sc_cov no-leg-token; continue ;; esac
    doc_date=$(printf '%s' "$f" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | tail -1)
    [ -n "$doc_date" ] || { sc_cov no-date; continue; }
    doc_epoch=$(to_epoch "$doc_date") || { sc_cov bad-date; continue; }
    [ "$doc_epoch" -ge "$SINCE_EPOCH" ] || { sc_cov out-of-window; continue; }
    if [ -n "$UNTIL_EPOCH" ] && [ "$doc_epoch" -ge "$UNTIL_EPOCH" ]; then sc_cov out-of-window; continue; fi
    sc_cov parsed

    leg=$(printf '%s' "$f" | grep -oE 'legN[0-9]+')
    runs=$(grep -oE '^> \*\*RUN [0-9]+ NOTE' "$H/$f" | grep -oE '[0-9]+' | sort -n | tail -1)
    runs=${runs:-1}
    b=$(grep -cE '^- ([0-9]{2}:[0-9]{2} )?BLOCKED' "$H/$f")
    w=$(grep -cE '^- ([0-9]{2}:[0-9]{2} )?WRAPPED .*BLOCKED' "$H/$f")
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$leg" "$runs" "$((runs-1))" "$b" "$w" "$f"
done < "$LIST" | sort -t "$(printf '\t')" -k1.5,1n | awk -F'\t' -v OFS='\t' '{print} NR>0{r+=$3; b+=$4; w+=$5; n++} END{if(n>0) printf "TOTAL(n=%d)\t-\t%d (mean %.2f)\t%d (mean %.2f)\t%d\t-\n", n, r, r/n, b, b/n, w}'
sc_cov_line "$(wc -l < "$LIST" | tr -d ' ')"
