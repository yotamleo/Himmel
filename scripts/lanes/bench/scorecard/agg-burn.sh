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
# SCORECARD_PROJECTS_DIR is an explicit scope: exactly that one transcript root
# (tests point it at a fixture tree). The default is the primary himmel project
# dir UNION its `--claude-worktrees-*` siblings - see lib/scorecard-lib.sh
# (HIMMEL-3269 F1: a primary-only default dropped the worktree legs).
#
# The last stdout line is `coverage: roots=R discovered=D parsed=P skipped=K
# (reason=n ...)` - how much of the discovered input the numbers above cover.
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
# shellcheck source=../../lib/burn-weights.sh
. "$HERE/../../lib/burn-weights.sh"
# shellcheck source=lib/scorecard-lib.sh
. "$HERE/lib/scorecard-lib.sh"
sc_roots_check agg-burn || exit 2

# GNU `date -d` first; BSD/macOS `date -j -f` fallback (same convention as
# leg-burn.sh's backdate()/transcript_mtime GNU-first/BSD-fallback comment).
to_epoch() {
    date -d "$1" +%s 2>/dev/null && return 0
    date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$(printf '%s' "$1" | sed 's/\.[0-9]*Z$/Z/')" +%s 2>/dev/null
}
SINCE_EPOCH=$(to_epoch "$SINCE") || { echo "agg-burn: bad --since: $SINCE" >&2; exit 2; }
UNTIL_EPOCH=""
if [ -n "$UNTIL" ]; then
    UNTIL_EPOCH=$(to_epoch "$UNTIL") || { echo "agg-burn: bad --until: $UNTIL" >&2; exit 2; }
fi

kn() { case "$1" in *k) awk -v n="${1%k}" 'BEGIN{printf "%.3f", n}';; *) awk -v n="$1" 'BEGIN{printf "%.3f", n/1000}';; esac; }
ts_of() { grep -o '"timestamp":"[0-9TZ:.-]*"' "$1" 2>/dev/null | "$2" -1 | cut -d'"' -f4; }

ROWS=""; FAILS=""; FILES=""; DISC_ERR=""; UNREADABLE=""
# trap first: a later mktemp failing must not leak the files already created
trap 'rm -f "$ROWS" "$FAILS" "$FILES" "$DISC_ERR" "$UNREADABLE" "$SC_COV"' EXIT
ROWS=$(mktemp "${TMPDIR:-/tmp}/agg-burn-rows.XXXXXX") || { echo "agg-burn: mktemp failed" >&2; exit 1; }
FAILS=$(mktemp "${TMPDIR:-/tmp}/agg-burn-fails.XXXXXX") || { echo "agg-burn: mktemp failed" >&2; exit 1; }
FILES=$(mktemp "${TMPDIR:-/tmp}/agg-burn-files.XXXXXX") || { echo "agg-burn: mktemp failed" >&2; exit 1; }
DISC_ERR=$(mktemp "${TMPDIR:-/tmp}/agg-burn-discerr.XXXXXX") || { echo "agg-burn: mktemp failed" >&2; exit 1; }
UNREADABLE=$(mktemp "${TMPDIR:-/tmp}/agg-burn-unreadable.XXXXXX") || { echo "agg-burn: mktemp failed" >&2; exit 1; }
sc_cov_init || exit 1

# HIMMEL-2977: discovery errors must not vanish. `find ... 2>/dev/null | while`
# lost both find's permission errors and its exit status, so an unreadable
# subtree gave exit 0 and a TOTAL that silently omitted it - a number that
# looks complete and is not. Capture find's stderr + status and fail loudly
# (exit 1, no table) rather than emit a partial total.
if ! sc_discover "$FILES" "$DISC_ERR"; then
    echo "agg-burn: transcript discovery failed under the transcript root(s) - refusing to print a partial total:" >&2
    cat "$DISC_ERR" >&2
    exit 1
fi

while IFS= read -r f; do
    # a listed-but-unreadable file would otherwise fall out at the empty-timestamp
    # `continue` below (grep's error is silenced) and vanish from the total
    if [ ! -r "$f" ]; then echo "$f" >> "$UNREADABLE"; sc_cov unreadable; continue; fi
    first_ts=$(ts_of "$f" head)
    [ -n "$first_ts" ] || { sc_cov no-timestamp; continue; }
    last_ts=$(ts_of "$f" tail)
    first_epoch=$(to_epoch "$first_ts") || { sc_cov bad-timestamp; continue; }
    last_epoch=$(to_epoch "${last_ts:-$first_ts}") || { sc_cov bad-timestamp; continue; }
    [ "$last_epoch" -ge "$SINCE_EPOCH" ] || { sc_cov out-of-window; continue; }
    if [ -n "$UNTIL_EPOCH" ] && [ "$first_epoch" -ge "$UNTIL_EPOCH" ]; then sc_cov out-of-window; continue; fi

    line=$(bash "$LEG_BURN" --raw "$f" 2>/dev/null) || { echo "$f" >> "$FAILS"; sc_cov leg-burn-failed; continue; }
    sc_cov parsed
    calls=$(printf '%s' "$line" | grep -o 'calls=[0-9]*' | cut -d= -f2)
    avg=$(printf '%s' "$line" | grep -o 'avg-ctx=[^ ]*' | cut -d= -f2)
    first=$(printf '%s' "$line" | grep -o 'first-turn=[^ ]*' | cut -d= -f2)
    comp=$(printf '%s' "$line" | grep -o 'compactions=[0-9]*' | cut -d= -f2)
    txt=$(printf '%s' "$line" | grep -o 'text-only=[0-9]*' | cut -d= -f2)
    out=$(printf '%s' "$line" | grep -o 'out=[^ ]*' | cut -d= -f2)
    cr=$(printf '%s' "$line" | grep -o 'cache-read=[^ ]*' | cut -d= -f2)
    cc=$(printf '%s' "$line" | grep -o 'cache-create=[^ ]*' | cut -d= -f2)
    inp=$(printf '%s' "$line" | grep -o 'input=[^ ]*' | cut -d= -f2)
    model=$(grep -o '"model":"claude-[^"]*"' "$f" | sort | uniq -c | sort -rn | head -1 | sed 's/.*"model":"//; s/"$//')

    case "$f" in
        */subagents/*)
            parent="${f%/subagents/*}.jsonl"
            pname=$(title_of "$parent")
            role=subagent; prole=$(role_of "$pname") ;;
        *)
            name=$(title_of "$f"); role=$(role_of "$name"); prole=- ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$role" "$prole" "${model:-unknown}" "$calls" "$(kn "$avg")" "$(kn "$first")" "$comp" "$txt" \
        "${out:-0}" "${cr:-0}" "${cc:-0}" "${inp:-0}" >> "$ROWS"
done < "$FILES"

if [ -s "$UNREADABLE" ]; then
    echo "agg-burn: $(wc -l < "$UNREADABLE" | tr -d ' ') unreadable transcript(s) - refusing to print a partial total:" >&2
    cat "$UNREADABLE" >&2
    exit 1
fi

printf 'role\tmodel\tsessions\tcalls\tavg_ctx_k(call-wtd)\tmax_session_avg_k\tavg_first_k\tcompactions\ttext_only\ttext_only_ratio\tctx_x_calls_Mtok\n'
awk -F'\t' '
function add(k){ n[k]++; c[k]+=$4; ctx[k]+=$4*$5; fsum[k]+=$6; cp[k]+=$7; tx[k]+=$8; if($5>pk[k])pk[k]=$5 }
{ r=$1; if(r=="subagent") r="subagent(" $2 ")"; add(r "\t" $3); add(r "\tALL"); add("TOTAL\tALL") }
END{
  for(k in n) printf "%s\t%d\t%d\t%.1f\t%.1f\t%.1f\t%d\t%d\t%.3f\t%.1f\n", k, n[k], c[k], (c[k]?ctx[k]/c[k]:0), pk[k], fsum[k]/n[k], cp[k], tx[k], (c[k]?tx[k]/c[k]:0), ctx[k]/1000
}' "$ROWS" | sort

# HIMMEL-2987: price-weighted TOTAL, over every row regardless of role/model.
# HIMMEL-2996: columns 9-12 are now the exact integer counters leg-burn.sh
# --raw prints (no per-session 0.1k rounding to compound); this awk sums the
# raw counts and divides by 1000 ONCE for display, replacing the HIMMEL-2991
# per-session-kn()-then-sum path.
awk -F'\t' -v wi="$LEG_BURN_W_INPUT" -v wcr="$LEG_BURN_W_CACHE_READ" -v wcc="$LEG_BURN_W_CACHE_CREATE" -v wo="$LEG_BURN_W_OUTPUT" '
{ out+=$9; cr+=$10; cc+=$11; inp+=$12 }
END{
  costeq = inp*wi + cr*wcr + cc*wcc + out*wo
  printf "TOTAL cache-read=%.1fk cache-create=%.1fk input=%.1fk output=%.1fk cost-eq=%.1fk\n", cr/1000, cc/1000, inp/1000, out/1000, costeq/1000
}' "$ROWS"

sc_cov_line "$(wc -l < "$FILES" | tr -d ' ')" "$SC_ROOT_COUNT"

n_fail=$(wc -l < "$FAILS")
if [ "$n_fail" -gt 0 ]; then
    echo "agg-burn: WARNING: $n_fail transcript(s) skipped due to leg-burn.sh failure" >&2
fi
