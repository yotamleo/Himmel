#!/usr/bin/env bash
# scripts/lanes/bench/scorecard/agg-burn.sh - P0.1 scorecard recipe (HIMMEL-2977).
#
# Platform guard: no .ps1 twin, by design. POSIX bash 3.2+ plus jq-free grep/
# sed over a Claude Code transcript (same JSONL on every platform); it runs
# under git bash unchanged.
#
# Copied from the HIMMEL-2977 baseline Appendix B (burn-sweep.sh + agg-burn.sh,
# leg N207, 2026-09-12) and folded into one self-contained script: walks
# Claude Code transcripts, tags each session by role (console/leg/relay/other)
# + parent role for subagents + dominant model, runs leg-burn.sh over it, and
# aggregates by role x model. The baseline hardcoded a 7-day mtime window over
# one project's transcripts; this reads --since/--until against each
# session's own timestamp span instead (a session with any activity inside
# [since, until) is included).
#
# Usage: agg-burn.sh --since <ISO8601> [--until <ISO8601>]
#
# SCORECARD_PROJECTS_DIR overrides the transcript root (default: this
# machine's himmel project dir) so tests can point it at a fixture tree.
set -u

usage() { echo "usage: agg-burn.sh --since <ISO8601> [--until <ISO8601>]" >&2; }

SINCE=""; UNTIL=""
while [ $# -gt 0 ]; do
    case "$1" in
        --since) SINCE="${2:?--since needs a value}"; shift 2 ;;
        --until) UNTIL="${2:?--until needs a value}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "agg-burn: unknown argument: $1" >&2; usage; exit 2 ;;
    esac
done
[ -n "$SINCE" ] || { usage; exit 2; }

HERE="$(cd "$(dirname "$0")" && pwd)"
LEG_BURN="$HERE/../../leg-burn.sh"
PROJECTS="${SCORECARD_PROJECTS_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/-home-overlord-Documents-github-himmel}"

# GNU `date -d` first; BSD/macOS `date -j -f` fallback (same convention as
# leg-burn.sh's backdate()/transcript_mtime GNU-first/BSD-fallback comment).
to_epoch() {
    date -d "$1" +%s 2>/dev/null && return 0
    date -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null
}
SINCE_EPOCH=$(to_epoch "$SINCE") || { echo "agg-burn: bad --since: $SINCE" >&2; exit 2; }
UNTIL_EPOCH=""
if [ -n "$UNTIL" ]; then
    UNTIL_EPOCH=$(to_epoch "$UNTIL") || { echo "agg-burn: bad --until: $UNTIL" >&2; exit 2; }
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

ROWS=$(mktemp "${TMPDIR:-/tmp}/agg-burn-rows.XXXXXX")
trap 'rm -f "$ROWS"' EXIT

find "$PROJECTS" -name '*.jsonl' -type f 2>/dev/null | while IFS= read -r f; do
    first_ts=$(ts_of "$f" head)
    [ -n "$first_ts" ] || continue
    last_ts=$(ts_of "$f" tail)
    first_epoch=$(to_epoch "$first_ts") || continue
    last_epoch=$(to_epoch "${last_ts:-$first_ts}") || continue
    [ "$last_epoch" -ge "$SINCE_EPOCH" ] || continue
    if [ -n "$UNTIL_EPOCH" ] && [ "$first_epoch" -ge "$UNTIL_EPOCH" ]; then continue; fi

    line=$(bash "$LEG_BURN" "$f" 2>/dev/null) || continue
    calls=$(printf '%s' "$line" | grep -o 'calls=[0-9]*' | cut -d= -f2)
    avg=$(printf '%s' "$line" | grep -o 'avg-ctx=[^ ]*' | cut -d= -f2)
    first=$(printf '%s' "$line" | grep -o 'first-turn=[^ ]*' | cut -d= -f2)
    comp=$(printf '%s' "$line" | grep -o 'compactions=[0-9]*' | cut -d= -f2)
    txt=$(printf '%s' "$line" | grep -o 'text-only=[0-9]*' | cut -d= -f2)
    model=$(grep -o '"model":"claude-[^"]*"' "$f" | sort | uniq -c | sort -rn | head -1 | sed 's/.*"model":"//; s/"$//')

    case "$f" in
        */subagents/*)
            parent="${f%/subagents/*}.jsonl"
            pname=$(title_of "$parent")
            role=subagent; prole=$(role_of "$pname") ;;
        *)
            name=$(title_of "$f"); role=$(role_of "$name"); prole=- ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$role" "$prole" "${model:-unknown}" "$calls" "$(kn "$avg")" "$(kn "$first")" "$comp" "$txt" >> "$ROWS"
done

printf 'role\tmodel\tsessions\tcalls\tavg_ctx_k(call-wtd)\tmax_session_avg_k\tavg_first_k\tcompactions\ttext_only\ttext_only_ratio\tctx_x_calls_Mtok\n'
awk -F'\t' '
function add(k){ n[k]++; c[k]+=$4; ctx[k]+=$4*$5; fsum[k]+=$6; cp[k]+=$7; tx[k]+=$8; if($5>pk[k])pk[k]=$5 }
{ r=$1; if(r=="subagent") r="subagent(" $2 ")"; add(r "\t" $3); add(r "\tALL"); add("TOTAL\tALL") }
END{
  for(k in n) printf "%s\t%d\t%d\t%.1f\t%.1f\t%.1f\t%d\t%d\t%.3f\t%.1f\n", k, n[k], c[k], (c[k]?ctx[k]/c[k]:0), pk[k], fsum[k]/n[k], cp[k], tx[k], (c[k]?tx[k]/c[k]:0), ctx[k]/1000
}' "$ROWS" | sort
