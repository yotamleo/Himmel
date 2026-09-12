#!/usr/bin/env bash
# scripts/lanes/bench/scorecard/ledger-metrics.sh - P0.1 scorecard recipe (HIMMEL-2977).
#
# Platform guard: no .ps1 twin, by design. POSIX bash 3.2+ plus jq and gh,
# both available under git bash unchanged; the ledger it reads is a plain
# JSONL file.
#
# Adapted from the HIMMEL-2977 baseline Appendix B (ledger-metrics.sh, leg
# N207, 2026-09-12): per merged branch in the window, crit/imp/sug findings
# and rounds (distinct heads with any finding/attempt row) off the primary
# ledger. Read-only. The baseline read a pre-fetched "$S/merged.json"; this
# fetches the merged-PR list itself, windowed by --since/--until against
# mergedAt, in place of that precursor step.
#
# Usage: ledger-metrics.sh --since <ISO8601> [--until <ISO8601>] [--repo <owner/repo>]
set -u

usage() { echo "usage: ledger-metrics.sh --since <ISO8601> [--until <ISO8601>] [--repo <owner/repo>]" >&2; }

SINCE=""; UNTIL=""; REPO="yotamleo/Himmel"
while [ $# -gt 0 ]; do
    case "$1" in
        --since) SINCE="${2:?--since needs a value}"; shift 2 ;;
        --until) UNTIL="${2:?--until needs a value}"; shift 2 ;;
        --repo) REPO="${2:?--repo needs a value}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ledger-metrics: unknown argument: $1" >&2; usage; exit 2 ;;
    esac
done
[ -n "$SINCE" ] || { usage; exit 2; }

LEDGER="${SCORECARD_LEDGER:-$HOME/Documents/github/himmel/.git/cr-critic-scores.jsonl}"
[ -f "$LEDGER" ] || { echo "ledger-metrics: no ledger at $LEDGER" >&2; exit 2; }

# GNU `date -d` first; BSD/macOS `date -j -f` fallback (same convention as
# leg-burn.sh's backdate()/transcript_mtime GNU-first/BSD-fallback comment).
to_epoch() {
    date -d "$1" +%s 2>/dev/null && return 0
    date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$(printf '%s' "$1" | sed 's/\.[0-9]*Z$/Z/')" +%s 2>/dev/null
}
SINCE_EPOCH=$(to_epoch "$SINCE") || { echo "ledger-metrics: bad --since: $SINCE" >&2; exit 2; }
UNTIL_EPOCH_ARG=9999999999
if [ -n "$UNTIL" ]; then
    UNTIL_EPOCH_ARG=$(to_epoch "$UNTIL") || { echo "ledger-metrics: bad --until: $UNTIL" >&2; exit 2; }
fi

RUN=$(mktemp -d "${TMPDIR:-/tmp}/ledger-metrics.XXXXXX") || { echo "ledger-metrics: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$RUN"' EXIT

gh pr list -R "$REPO" --state merged --limit 1000 --json number,title,mergedAt,headRefName \
    --jq '.' > "$RUN/merged-all.json" || { echo "ledger-metrics: gh pr list failed" >&2; exit 1; }
merged_count=$(jq 'length' "$RUN/merged-all.json" 2>/dev/null) || { echo "ledger-metrics: could not parse gh pr list output" >&2; exit 1; }
if [ "${merged_count:-0}" -ge 1000 ]; then
    echo "ledger-metrics: WARNING: gh pr list returned $merged_count merged PRs (== --limit 1000); older history may be truncated" >&2
fi
jq --argjson since_epoch "$SINCE_EPOCH" --argjson until_epoch "$UNTIL_EPOCH_ARG" \
    '[.[] | select((.mergedAt | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) >= $since_epoch and (.mergedAt | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) < $until_epoch)]' \
    "$RUN/merged-all.json" > "$RUN/merged.json" || { echo "ledger-metrics: window filter failed" >&2; exit 1; }

jq -r '.[].headRefName' "$RUN/merged.json" > "$RUN/merged-branches-raw.txt" || { echo "ledger-metrics: could not extract headRefName from merged.json" >&2; exit 1; }
sort -u "$RUN/merged-branches-raw.txt" > "$RUN/merged-branches.txt"
jq -r 'select((.artifact // "diff")=="diff") | select(.kind=="finding" or .kind=="attempt") |
  [.kind, .branch, .head, (.severity // "-"), (.model // "-")] | @tsv' "$LEDGER" > "$RUN/ledger-rows.tsv" \
    || { echo "ledger-metrics: could not extract rows from ledger" >&2; exit 1; }

awk -F'\t' -v OFS='\t' '
NR==FNR { m[$1]=1; next }
!($2 in m) { next }
{ b=$2; seen[b]=1; h[b SUBSEP $3]=1
  if ($1=="finding") { f[b SUBSEP $4]++ } }
END {
  for (k in h) { split(k, p, SUBSEP); r[p[1]]++ }
  for (b in seen) print b, f[b SUBSEP "crit"]+0, f[b SUBSEP "imp"]+0, f[b SUBSEP "sug"]+0, r[b]+0
}' "$RUN/merged-branches.txt" "$RUN/ledger-rows.tsv" | sort > "$RUN/ledger-per-branch.tsv"

echo "merged_branches=$(wc -l < "$RUN/merged-branches.txt") with_ledger_rows=$(wc -l < "$RUN/ledger-per-branch.tsv")"
stat() {
  cut -f"$1" "$RUN/ledger-per-branch.tsv" | sort -n | awk '{a[NR]=$1; s+=$1} END{ if(NR==0){print "n=0"; exit}
    med=(NR%2)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2; printf "n=%d sum=%d mean=%.2f median=%.1f max=%d\n", NR, s, s/NR, med, a[NR] }'
}
printf 'crit: '; stat 2
printf 'imp:  '; stat 3
printf 'sug:  '; stat 4
printf 'rounds: '; stat 5
awk -F'\t' '{print $2+$3}' "$RUN/ledger-per-branch.tsv" | sort -n | awk '{a[NR]=$1; s+=$1} END{if(NR==0){print "crit+imp: n=0"; exit} med=(NR%2)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2; printf "crit+imp: n=%d mean=%.2f median=%.1f\n", NR, s/NR, med}'
jq -r 'if length==0 then "merged window: (empty) count=0" else [.[].mergedAt] | "merged window: \(min) .. \(max) count=\(length)" end' "$RUN/merged.json"
