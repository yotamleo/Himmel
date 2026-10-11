#!/usr/bin/env bash
# judge-cache-row.sh — one prompt-cache ledger row per judge subagent
# transcript (HIMMEL-5180). Read-only: reads the subagent JSONL and its
# sibling .meta.json, prints one TSV row, appends it to --ledger if given.
#
# Usage:
#   bash scripts/eval/judge-cache-row.sh [--ledger <file>] [--header] <agent-*.jsonl>...
#
# Columns: judge  agent  model  ttl  wall_s  turns  cc_5m  cc_1h  cache_read
#          longest_gap_s  gaps_over_300s
#   judge          the meta.json description (e.g. "Judge j2334b PR 2334")
#   agent          agentType from meta.json (Explore | console-judge-ro | ...)
#   ttl            "1h" if any 1h write was billed, "5m" if only 5m writes,
#                  "unknown" when the run billed no cache write at all
#   turns          distinct API messages (usage rows are deduped by message id:
#                  one message is written once per content block)
#   longest_gap_s  largest gap between consecutive distinct messages; a gap
#                  over 300 s on a 5m run is a cold re-prime
set -euo pipefail

ledger=""
header=0
files=()
while [ $# -gt 0 ]; do
    case "$1" in
        --ledger) ledger="${2:?--ledger needs a file}"; shift 2 ;;
        --header) header=1; shift ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) files+=("$1"); shift ;;
    esac
done
command -v jq >/dev/null 2>&1 || { echo "judge-cache-row: jq not on PATH" >&2; exit 1; }
[ "${#files[@]}" -gt 0 ] || { echo "judge-cache-row: no transcript given" >&2; exit 2; }

HDR=$'judge\tagent\tmodel\tttl\twall_s\tturns\tcc_5m\tcc_1h\tcache_read\tlongest_gap_s\tgaps_over_300s'
out() {
    printf '%s\n' "$1"
    if [ -n "$ledger" ]; then printf '%s\n' "$1" >> "$ledger"; fi
}
if [ "$header" = 1 ]; then out "$HDR"; fi

for f in "${files[@]}"; do
    [ -f "$f" ] || { echo "judge-cache-row: not a file: $f" >&2; exit 2; }
    meta="${f%.jsonl}.meta.json"
    desc="" agent="" mdl=""
    if [ -f "$meta" ]; then
        desc=$(jq -r '.description // ""' "$meta")
        agent=$(jq -r '.agentType // ""' "$meta")
        mdl=$(jq -r '.model // ""' "$meta")
    fi
    row=$(jq -rs --arg d "$desc" --arg a "$agent" '
        def ts: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
        [ .[] | select(.type == "assistant" and .message.usage != null) ]
        | group_by(.message.id)
        | map({t: (map(.timestamp | ts) | min), u: .[0].message.usage})
        | sort_by(.t) as $m
        | ($m | map(.u.cache_creation.ephemeral_5m_input_tokens // 0) | add // 0) as $c5
        | ($m | map(.u.cache_creation.ephemeral_1h_input_tokens // 0) | add // 0) as $c1
        | ($m | map(.u.cache_read_input_tokens // 0) | add // 0) as $cr
        | [ range(1; $m | length) | $m[.].t - $m[. - 1].t ] as $g
        | [ $d, $a, $m_name,
            (if $c1 > 0 then "1h" elif $c5 > 0 then "5m" else "unknown" end),
            (if ($m | length) > 1 then ($m[-1].t - $m[0].t) else 0 end),
            ($m | length), $c5, $c1, $cr,
            ($g | max // 0), ($g | map(select(. > 300)) | length) ]
        | map(tostring) | @tsv
    ' --arg m_name "$mdl" "$f")
    out "$row"
done
