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
#                        [--cohort <name>] [--context <1m|standard|unknown>]
#                        [--exclude-straddle <ISO8601>]
#
# --role <leg|console>       restrict to one role (default: both)
# --cohort <name>            restrict to sessions launched under
#                             --profile <name> (HIMMEL-2977 Task 3: the only
#                             defined cohort today is "leg-impl"). Matched
#                             against SCORECARD_LAUNCH_LOG_DIR (default:
#                             ${HIMMELCTL_CACHE_DIR:-$HOME/.claude/himmel}/launch-logs),
#                             one file per session NAME - the transcript's
#                             customTitle, the one key a launcher knows at
#                             launch time (a session UUID it cannot) -
#                             <name>.log, holding one appended
#                             "headed-arm-leg: profile=<name> ... session=<name>"
#                             line per launch attempt (HIMMEL-3270 writer:
#                             scripts/handover/console-kit/headed-arm-leg.sh).
#                             A session with no launch-log entry is excluded
#                             under --cohort (no profile on record).
#                             MULTI-LINE RULE (HIMMEL-3269): the log is append-only
#                             with no attempt id, so a refused duplicate of a live
#                             session's name can add a line beside the original.
#                             Lines that agree on profile= are one record; lines
#                             that DISAGREE make the session ambiguous and it is
#                             excluded (counted as ambiguous-profile) - neither
#                             first- nor last-write-wins is provable from the log.
#
# The last stdout line is `coverage: roots=R discovered=D parsed=P skipped=K
# (reason=n ...)` - how much of the discovered input the table above covers.
# --context <1m|standard|unknown>
#                             restrict to sessions by the launch context they
#                             RECEIVED (HIMMEL-3279), read from the durable
#                             console launch record headed-arm.sh writes into
#                             the same launch-logs dir. `unknown` selects the
#                             sessions with no usable record (gone, absent,
#                             ambiguous) - they are never proxied from token
#                             counts into a mode. The output carries a
#                             `context:` line naming that source.
# --exclude-straddle <ISO>   drop sessions whose first timestamp precedes
#                             <ISO> but whose last timestamp is >= <ISO>
#                             (spec §2.3: a session straddling a lever-merge
#                             boundary is excluded from both sides' windows).
#
# Adds one column beyond agg-burn.sh's headline columns: counted_shifts (A27
# - a console/relay shift counts iff it has >=100 console-role calls of any
# model; legs are not shifts and always report counted_shifts=sessions).
#
# SCORECARD_PROJECTS_DIR is an explicit scope: exactly that one transcript root
# (tests point it at a fixture tree). The default is the primary himmel project
# dir UNION its `--claude-worktrees-*` siblings - see lib/scorecard-lib.sh.
set -u

usage() {
    echo "usage: agg-postpin.sh --since <ISO8601> [--until <ISO8601>] [--role <leg|console>] [--cohort <name>] [--context <1m|standard|unknown>] [--exclude-straddle <ISO8601>]" >&2
}

SINCE=""; UNTIL=""; ROLE_FILTER=""; COHORT=""; CONTEXT_FILTER=""; STRADDLE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --since) SINCE="${2:?--since needs a value}"; shift 2 ;;
        --until) UNTIL="${2:?--until needs a value}"; shift 2 ;;
        --role) ROLE_FILTER="${2:?--role needs a value}"; shift 2 ;;
        --cohort) COHORT="${2:?--cohort needs a value}"; shift 2 ;;
        --context) CONTEXT_FILTER="${2:?--context needs a value}"; shift 2 ;;
        --exclude-straddle) STRADDLE="${2:?--exclude-straddle needs a value}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "agg-postpin: unknown argument: $1" >&2; usage; exit 2 ;;
    esac
done
[ -n "$SINCE" ] || { usage; exit 2; }
case "$CONTEXT_FILTER" in
    ""|1m|standard|unknown) ;;
    *) echo "agg-postpin: --context must be 1m, standard or unknown, got: $CONTEXT_FILTER" >&2; usage; exit 2 ;;
esac

HERE="$(cd "$(dirname "$0")" && pwd)"
LEG_BURN="$HERE/../../leg-burn.sh"
# shellcheck source=lib/scorecard-lib.sh
. "$HERE/lib/scorecard-lib.sh"
sc_roots_check agg-postpin || exit 2
LAUNCH_LOG_DIR="${SCORECARD_LAUNCH_LOG_DIR:-${HIMMELCTL_CACHE_DIR:-$HOME/.claude/himmel}/launch-logs}"

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
ts_of() { grep -o '"timestamp":"[0-9TZ:.-]*"' "$1" 2>/dev/null | "$2" -1 | cut -d'"' -f4; }

# cohort_ok <session-title>: the join key is the session NAME (customTitle), not
# the transcript's UUID basename. Sets COHORT_WHY to the skip reason on failure.
COHORT_WHY=""
cohort_ok() {
    COHORT_WHY=""
    [ -z "$COHORT" ] && return 0
    # a title is a filename component: never let one walk out of the log dir
    case "$1" in ""|*/*) COHORT_WHY=no-launch-record; return 1 ;; esac
    log="$LAUNCH_LOG_DIR/$1.log"
    [ -f "$log" ] || { COHORT_WHY=no-launch-record; return 1; }
    # whole fields only: `other-profile=leg-impl` must not read as profile=leg-impl
    profiles=$(awk '/^headed-arm-leg:/ {for(i=1;i<=NF;i++) if($i ~ /^profile=/) print $i}' "$log" | sort -u)
    [ -n "$profiles" ] || { COHORT_WHY=no-launch-record; return 1; }
    if [ "$(printf '%s\n' "$profiles" | wc -l | tr -d ' ')" -gt 1 ]; then
        COHORT_WHY=ambiguous-profile; return 1
    fi
    [ "$profiles" = "profile=$COHORT" ] || { COHORT_WHY=other-cohort; return 1; }
}

# context_ok <session-title>: --context selects by the durable launch record.
# Sets CONTEXT_WHY to the skip reason on failure.
CONTEXT_WHY=""
context_ok() {
    CONTEXT_WHY=""
    [ -z "$CONTEXT_FILTER" ] && return 0
    got=$(sc_launch_context "$LAUNCH_LOG_DIR" "$1")
    [ "$got" = "$CONTEXT_FILTER" ] && return 0
    if [ "$got" = unknown ]; then CONTEXT_WHY=context-unknown; else CONTEXT_WHY=other-context; fi
    return 1
}

ROWS=""; FAILS=""; FILES=""; DISC_ERR=""
# trap first: a later mktemp failing must not leak the files already created
trap 'rm -f "$ROWS" "$FAILS" "$FILES" "$DISC_ERR" "$SC_COV"' EXIT
ROWS=$(mktemp "${TMPDIR:-/tmp}/agg-postpin-rows.XXXXXX") || { echo "agg-postpin: mktemp failed" >&2; exit 1; }
FAILS=$(mktemp "${TMPDIR:-/tmp}/agg-postpin-fails.XXXXXX") || { echo "agg-postpin: mktemp failed" >&2; exit 1; }
FILES=$(mktemp "${TMPDIR:-/tmp}/agg-postpin-files.XXXXXX") || { echo "agg-postpin: mktemp failed" >&2; exit 1; }
DISC_ERR=$(mktemp "${TMPDIR:-/tmp}/agg-postpin-discerr.XXXXXX") || { echo "agg-postpin: mktemp failed" >&2; exit 1; }
sc_cov_init || exit 1

# A discovery error must not vanish (the agg-burn.sh HIMMEL-2977 rule): `find
# 2>/dev/null | while` lost both find's errors and its status, so the coverage
# line's `discovered=` would have counted a silently truncated file list.
if ! sc_discover "$FILES" "$DISC_ERR"; then
    echo "agg-postpin: transcript discovery failed under the transcript root(s) - refusing to print a partial table:" >&2
    cat "$DISC_ERR" >&2
    exit 1
fi

while IFS= read -r f; do
    # title_of silences read errors: without this an unreadable file reads as an
    # empty title and is misfiled as an intentional other-role exclusion
    [ -r "$f" ] || { sc_cov unreadable; continue; }
    case "$f" in */subagents/*) sc_cov subagent; continue ;; esac
    name=$(title_of "$f"); role=$(role_of "$name")
    # an untitled session is counted by name, never folded into other-role
    [ "$role" != unattributed ] || { sc_cov unattributed; continue; }
    case "$role" in leg|console) ;; *) sc_cov other-role; continue ;; esac
    if [ -n "$ROLE_FILTER" ] && [ "$role" != "$ROLE_FILTER" ]; then sc_cov role-filter; continue; fi

    first_ts=$(ts_of "$f" head)
    [ -n "$first_ts" ] || { sc_cov no-timestamp; continue; }
    last_ts=$(ts_of "$f" tail)
    first_epoch=$(to_epoch "$first_ts") || { sc_cov bad-timestamp; continue; }
    last_epoch=$(to_epoch "${last_ts:-$first_ts}") || { sc_cov bad-timestamp; continue; }
    [ "$last_epoch" -ge "$SINCE_EPOCH" ] || { sc_cov out-of-window; continue; }
    if [ -n "$UNTIL_EPOCH" ] && [ "$first_epoch" -ge "$UNTIL_EPOCH" ]; then sc_cov out-of-window; continue; fi
    if [ -n "$STRADDLE_EPOCH" ] && [ "$first_epoch" -lt "$STRADDLE_EPOCH" ] && [ "$last_epoch" -ge "$STRADDLE_EPOCH" ]; then sc_cov straddle; continue; fi

    cohort_ok "$name" || { sc_cov "$COHORT_WHY"; continue; }
    context_ok "$name" || { sc_cov "$CONTEXT_WHY"; continue; }

    line=$(bash "$LEG_BURN" "$f" 2>/dev/null) || { echo "$f" >> "$FAILS"; sc_cov leg-burn-failed; continue; }
    sc_cov parsed
    calls=$(printf '%s' "$line" | grep -o 'calls=[0-9]*' | cut -d= -f2)
    avg=$(printf '%s' "$line" | grep -o 'avg-ctx=[^ ]*' | cut -d= -f2)
    first=$(printf '%s' "$line" | grep -o 'first-turn=[^ ]*' | cut -d= -f2)
    comp=$(printf '%s' "$line" | grep -o 'compactions=[0-9]*' | cut -d= -f2)
    model=$(grep -o '"model":"claude-[^"]*"' "$f" | sort | uniq -c | sort -rn | head -1 | sed 's/.*"model":"//; s/"$//')

    counted=1
    if [ "$role" = "console" ] && [ "${calls:-0}" -lt 100 ]; then counted=0; fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$role" "${model:-unknown}" "$calls" "$(kn "$avg")" "$(kn "$first")" "$comp" "$counted" >> "$ROWS"
done < "$FILES"

printf 'role\tmodel\tsessions\tcalls\tavg_ctx_k(call-wtd)\tmax_session_avg_k\tavg_first_k\tcompactions\tctx_x_calls_Mtok\tcounted_shifts\n'
awk -F'\t' '
function add(k){ n[k]++; c[k]+=$3; ctx[k]+=$3*$4; fsum[k]+=$5; cp[k]+=$6; cs[k]+=$7; if($4>pk[k])pk[k]=$4 }
{ add($1 "\t" $2); add($1 "\tALL") }
END{
  for(k in n) printf "%s\t%d\t%d\t%.1f\t%.1f\t%.1f\t%d\t%.1f\t%d\n", k, n[k], c[k], (c[k]?ctx[k]/c[k]:0), pk[k], fsum[k]/n[k], cp[k], ctx[k]/1000, cs[k]
}' "$ROWS" | sort
[ -z "$CONTEXT_FILTER" ] || echo "context: filter=$CONTEXT_FILTER source=launch-record (no proxy; a session with no usable record is unknown)"
sc_cov_line "$(wc -l < "$FILES" | tr -d ' ')" "$SC_ROOT_COUNT"

n_fail=$(wc -l < "$FAILS")
if [ "$n_fail" -gt 0 ]; then
    echo "agg-postpin: WARNING: $n_fail transcript(s) skipped due to leg-burn.sh failure" >&2
fi
