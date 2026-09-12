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

RUN=$(mktemp -d "${TMPDIR:-/tmp}/ledger-metrics.XXXXXX")
trap 'rm -rf "$RUN"' EXIT

gh pr list -R "$REPO" --state merged --limit 1000 --json number,title,mergedAt,headRefName \
    --jq "[.[] | select(.mergedAt >= \"$SINCE\")]" > "$RUN/merged.json"
if [ -n "$UNTIL" ]; then
    jq "[.[] | select(.mergedAt < \"$UNTIL\")]" "$RUN/merged.json" > "$RUN/merged.filtered.json"
    mv "$RUN/merged.filtered.json" "$RUN/merged.json"
fi

jq -r '.[].headRefName' "$RUN/merged.json" | sort -u > "$RUN/merged-branches.txt"
jq -r 'select((.artifact // "diff")=="diff") | select(.kind=="finding" or .kind=="attempt") |
  [.kind, .branch, .head, (.severity // "-"), (.model // "-")] | @tsv' "$LEDGER" > "$RUN/ledger-rows.tsv"

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
