#!/usr/bin/env bash
# scripts/lanes/leg-cost-report.sh - leg cost per group, from the ledger only
# (HIMMEL-4217).
#
# Usage: leg-cost-report.sh [--since YYYY-MM-DD] [--by class|model|ticket]
#
# Reads <handover root>/.ledger/leg-cost.jsonl (override: LEG_COST_LEDGER), the
# one row per wrapped leg close-wrapped-leg.sh appends. Prints one tab-separated
# line per group: group, n, median, p80, max, total - all cost-eq (token
# equivalents, lib/burn-weights.sh), rounded to integers. Median of an even n is
# the mean of the middle two; p80 is nearest-rank (the ceil(0.8*n)-th value).
# Unparseable ledger lines are skipped. Exit: 0 report, 1 no ledger, 2 usage.
#
# Platform guard: no .ps1 twin, by design - the ledger writer is the Linux-only
# console kit. POSIX bash 3.2+ and jq.
set -u -o pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SINCE=""
BY=class
while [ "$#" -gt 0 ]; do
    case "$1" in
        --since) [ "$#" -ge 2 ] || { echo "usage: leg-cost-report.sh [--since DATE] [--by class|model|ticket]" >&2; exit 2; }
                 SINCE="$2"; shift 2 ;;
        --by)    [ "$#" -ge 2 ] || { echo "usage: leg-cost-report.sh [--since DATE] [--by class|model|ticket]" >&2; exit 2; }
                 BY="$2"; shift 2 ;;
        *) echo "usage: leg-cost-report.sh [--since DATE] [--by class|model|ticket]" >&2; exit 2 ;;
    esac
done
case "$BY" in class|model|ticket) ;; *) echo "leg-cost-report: --by must be class, model or ticket" >&2; exit 2 ;; esac
case "$SINCE" in ''|[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) echo "leg-cost-report: --since must be YYYY-MM-DD" >&2; exit 2 ;; esac
command -v jq >/dev/null 2>&1 || { echo "leg-cost-report: jq is required" >&2; exit 1; }

# shellcheck source=scripts/lanes/lib/leg-cost-row.sh
. "$HERE/lib/leg-cost-row.sh" || exit 1
LEDGER=$(leg_cost_ledger_path) || exit 1
[ -r "$LEDGER" ] || { echo "leg-cost-report: no ledger at $LEDGER" >&2; exit 1; }

jq -R 'fromjson? | select(type == "object" and (.cost_eq | type) == "number")' "$LEDGER" \
    | jq -rs --arg by "$BY" --arg since "$SINCE" '
        def pct(p): (length) as $n | .[((p * $n) | ceil) - 1];
        def med: (length) as $n | if $n % 2 == 1 then .[($n - 1) / 2] else (.[$n / 2 - 1] + .[$n / 2]) / 2 end;
        [ .[] | select($since == "" or ((.date // "") >= $since)) ]
        | group_by(.[$by])[]
        | (map(.cost_eq) | sort) as $c
        | [(.[0][$by] // "unknown"), ($c | length), ($c | med | round), ($c | pct(0.8) | round), ($c | max | round), ($c | add | round)]
        | @tsv'
