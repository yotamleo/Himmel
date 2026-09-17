#!/usr/bin/env bash
# scripts/lanes/bench/scorecard/agg-postpin.sh - P0.1 scorecard recipe (HIMMEL-2977).
#
# Platform guard: no .ps1 twin, by design. POSIX bash 3.2+ plus jq-free grep/
# sed over a Claude Code transcript (same JSONL on every platform); it runs
# under git bash unchanged.
#
# Copied from the HIMMEL-2977 baseline Appendix B (agg-postpin.sh, leg N207,
# 2026-09-12): the headline leg/console rollup (spec §0/§2.1's legs +
# Fable-console rows). Folded into one self-contained script on the same
# walk as agg-burn.sh, restricted to role in {leg, console}. The baseline
# hardcoded its window; this takes --since/--until.
#
# Usage: agg-postpin.sh --since <ISO8601> [--until <ISO8601>] [--role <role>]
#                        [--cohort <name>] [--exclude-straddle <ISO8601>]
#
# --role <leg|console>       restrict to one role (default: both)
# --cohort <name>            restrict to sessions launched under
#                             --profile <name> (HIMMEL-2977 Task 3: the only
#                             defined cohort today is "leg-impl"). Matched
#                             against SCORECARD_LAUNCH_LOG_DIR (default:
#                             $HOME/.claude/launch-logs), one file per
#                             session basename, containing the
#                             "headed-arm-leg: profile=<name> ..." line
#                             (see scripts/handover/console-kit/headed-arm-leg.sh).
#                             A session with no matching launch-log entry is
#                             excluded under --cohort (no profile on record).
# --exclude-straddle <ISO>   drop sessions whose first timestamp precedes
#                             <ISO> but whose last timestamp is >= <ISO>
#                             (spec §2.3: a session straddling a lever-merge
#                             boundary is excluded from both sides' windows).
#
# Adds one column beyond agg-burn.sh's headline columns: counted_shifts (A27
# - a console/relay shift counts iff it has >=100 console-role calls of any
# model; legs are not shifts and always report counted_shifts=sessions).
#
# SCORECARD_PROJECTS_DIR overrides the transcript root (default: this
# machine's himmel project dir) so tests can point it at a fixture tree.
set -u

usage() {
    echo "usage: agg-postpin.sh --since <ISO8601> [--until <ISO8601>] [--role <leg|console>] [--cohort <name>] [--exclude-straddle <ISO8601>]" >&2
}

SINCE=""; UNTIL=""; ROLE_FILTER=""; COHORT=""; STRADDLE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --since) SINCE="${2:?--since needs a value}"; shift 2 ;;
        --until) UNTIL="${2:?--until needs a value}"; shift 2 ;;
        --role) ROLE_FILTER="${2:?--role needs a value}"; shift 2 ;;
        --cohort) COHORT="${2:?--cohort needs a value}"; shift 2 ;;
        --exclude-straddle) STRADDLE="${2:?--exclude-straddle needs a value}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "agg-postpin: unknown argument: $1" >&2; usage; exit 2 ;;
    esac
done
[ -n "$SINCE" ] || { usage; exit 2; }

HERE="$(cd "$(dirname "$0")" && pwd)"
LEG_BURN="$HERE/../../leg-burn.sh"
PROJECTS="${SCORECARD_PROJECTS_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/-home-overlord-Documents-github-himmel}"
[ -d "$PROJECTS" ] || { echo "agg-postpin: transcript root not found: $PROJECTS" >&2; exit 2; }
LAUNCH_LOG_DIR="${SCORECARD_LAUNCH_LOG_DIR:-$HOME/.claude/launch-logs}"

# GNU `date -d` first; BSD/macOS `date -j -f` fallback (same convention as
# leg-burn.sh's backdate()/transcript_mtime GNU-first/BSD-fallback comment).
to_epoch() {
    date -d "$1" +%s 2>/dev/null && return 0
    date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$(printf '%s' "$1" | sed 's/\.[0-9]*Z$/Z/')" +%s 2>/dev/null
}
SINCE_EPOCH=$(to_epoch "$SINCE") || { echo "agg-postpin: bad --since: $SINCE" >&2; exit 2; }
UNTIL_EPOCH=""
if [ -n "$UNTIL" ]; then
    UNTIL_EPOCH=$(to_epoch "$UNTIL") || { echo "agg-postpin: bad --until: $UNTIL" >&2; exit 2; }
fi
STRADDLE_EPOCH=""
if [ -n "$STRADDLE" ]; then
    STRADDLE_EPOCH=$(to_epoch "$STRADDLE") || { echo "agg-postpin: bad --exclude-straddle: $STRADDLE" >&2; exit 2; }
fi

kn() { case "$1" in *k) awk -v n="${1%k}" 'BEGIN{printf "%.3f", n}';; *) awk -v n="$1" 'BEGIN{printf "%.3f", n/1000}';; esac; }
title_of() { grep -o '"customTitle":"[^"]*"' "$1" 2>/dev/null | tail -1 | sed 's/.*:"//; s/"$//'; }
role_of() {
    case "$1" in
        *-console*) echo console ;;
        *-relay*) echo relay ;;
        *legN*) echo leg ;;
        *) echo other ;;
    esac
}
ts_of() { grep -o '"timestamp":"[0-9TZ:.-]*"' "$1" 2>/dev/null | "$2" -1 | cut -d'"' -f4; }

cohort_ok() {
    [ -z "$COHORT" ] && return 0
    base=$(basename "$1" .jsonl)
    log="$LAUNCH_LOG_DIR/$base.log"
    [ -f "$log" ] || return 1
    awk -v c="profile=$COHORT" '{for(i=1;i<=NF;i++) if($i==c){f=1;exit}} END{exit !f}' "$log"
}

ROWS=$(mktemp "${TMPDIR:-/tmp}/agg-postpin-rows.XXXXXX") || { echo "agg-postpin: mktemp failed" >&2; exit 1; }
FAILS=$(mktemp "${TMPDIR:-/tmp}/agg-postpin-fails.XXXXXX") || { echo "agg-postpin: mktemp failed" >&2; exit 1; }
trap 'rm -f "$ROWS" "$FAILS"' EXIT

find "$PROJECTS" -name '*.jsonl' -type f 2>/dev/null | while IFS= read -r f; do
    case "$f" in */subagents/*) continue ;; esac
    name=$(title_of "$f"); role=$(role_of "$name")
    case "$role" in leg|console) ;; *) continue ;; esac
    [ -n "$ROLE_FILTER" ] && [ "$role" != "$ROLE_FILTER" ] && continue

    first_ts=$(ts_of "$f" head)
    [ -n "$first_ts" ] || continue
    last_ts=$(ts_of "$f" tail)
    first_epoch=$(to_epoch "$first_ts") || continue
    last_epoch=$(to_epoch "${last_ts:-$first_ts}") || continue
    [ "$last_epoch" -ge "$SINCE_EPOCH" ] || continue
    if [ -n "$UNTIL_EPOCH" ] && [ "$first_epoch" -ge "$UNTIL_EPOCH" ]; then continue; fi
    if [ -n "$STRADDLE_EPOCH" ] && [ "$first_epoch" -lt "$STRADDLE_EPOCH" ] && [ "$last_epoch" -ge "$STRADDLE_EPOCH" ]; then continue; fi

    cohort_ok "$f" || continue

    line=$(bash "$LEG_BURN" "$f" 2>/dev/null) || { echo "$f" >> "$FAILS"; continue; }
    calls=$(printf '%s' "$line" | grep -o 'calls=[0-9]*' | cut -d= -f2)
    avg=$(printf '%s' "$line" | grep -o 'avg-ctx=[^ ]*' | cut -d= -f2)
    first=$(printf '%s' "$line" | grep -o 'first-turn=[^ ]*' | cut -d= -f2)
    comp=$(printf '%s' "$line" | grep -o 'compactions=[0-9]*' | cut -d= -f2)
    model=$(grep -o '"model":"claude-[^"]*"' "$f" | sort | uniq -c | sort -rn | head -1 | sed 's/.*"model":"//; s/"$//')

    counted=1
    if [ "$role" = "console" ] && [ "${calls:-0}" -lt 100 ]; then counted=0; fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$role" "${model:-unknown}" "$calls" "$(kn "$avg")" "$(kn "$first")" "$comp" "$counted" >> "$ROWS"
done

printf 'role\tmodel\tsessions\tcalls\tavg_ctx_k(call-wtd)\tmax_session_avg_k\tavg_first_k\tcompactions\tctx_x_calls_Mtok\tcounted_shifts\n'
awk -F'\t' '
function add(k){ n[k]++; c[k]+=$3; ctx[k]+=$3*$4; fsum[k]+=$5; cp[k]+=$6; cs[k]+=$7; if($4>pk[k])pk[k]=$4 }
{ add($1 "\t" $2); add($1 "\tALL") }
END{
  for(k in n) printf "%s\t%d\t%d\t%.1f\t%.1f\t%.1f\t%d\t%.1f\t%d\n", k, n[k], c[k], (c[k]?ctx[k]/c[k]:0), pk[k], fsum[k]/n[k], cp[k], ctx[k]/1000, cs[k]
}' "$ROWS" | sort

n_fail=$(wc -l < "$FAILS")
if [ "$n_fail" -gt 0 ]; then
    echo "agg-postpin: WARNING: $n_fail transcript(s) skipped due to leg-burn.sh failure" >&2
fi
