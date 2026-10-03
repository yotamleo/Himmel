#!/usr/bin/env bash
# scripts/lanes/test-leg-cost-report.sh - suite for leg-cost-report.sh (HIMMEL-4217).
# Hermetic: a fixture ledger in a scratch dir (LEG_COST_LEDGER), never the live
# handover root.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/leg-cost-report.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/lcr-test.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); fi; }

L="$W/ledger.jsonl"
row() { # row <date> <class> <model> <ticket> <cost>
    printf '{"date":"%s","leg":"N1","ticket":"%s","pr":null,"model":"%s","profile":"p","class":"%s","calls":1,"out":1,"cache_read":1,"cache_create":1,"input":1,"cost_eq":%s,"compactions":0,"session":"s"}\n' "$1" "$4" "$3" "$2" "$5"
}
{
    row 2026-10-03 shepherd sonnet HIMMEL-1 100
    row 2026-10-03 shepherd sonnet HIMMEL-2 200
    row 2026-10-03 shepherd sonnet HIMMEL-3 300
    row 2026-10-03 shepherd sonnet HIMMEL-4 400
    row 2026-10-03 shepherd sonnet HIMMEL-5 500
    row 2026-10-03 impl opus HIMMEL-6 1000
    row 2026-10-03 impl opus HIMMEL-6 3000
    row 2026-09-01 shepherd sonnet HIMMEL-7 9999
    printf 'not json at all\n'
} > "$L"

run() { LEG_COST_LEDGER="$L" bash "$SUT" "$@" 2>&1; }
# cells <group> - the tab-separated cells of that group's line, after its name
cell_line() { printf '%s\n' "$1" | grep -F -e "$2	" | cut -f2- | tr '\t' ' '; }

out=$(run --by class)
check "by class: shepherd (n median p80 max total) incl. the old row" "$(cell_line "$out" shepherd)" "6 350 500 9999 11499"
check "by class: impl even-n median is the mean of the middle two" "$(cell_line "$out" impl)" "2 2000 3000 3000 4000"
out=$(run --since 2026-10-01 --by class)
check "since: the old row is excluded" "$(cell_line "$out" shepherd)" "5 300 400 500 1500"
out=$(run --since 2026-10-01 --by model)
check "by model: opus group" "$(cell_line "$out" opus)" "2 2000 3000 3000 4000"
out=$(run --since 2026-10-01 --by ticket)
check "by ticket: HIMMEL-6 groups its two legs" "$(cell_line "$out" HIMMEL-6)" "2 2000 3000 3000 4000"
out=$(run --since 2026-10-01)
check "default grouping is class" "$(cell_line "$out" impl)" "2 2000 3000 3000 4000"
rc=0; run --by bogus >/dev/null || rc=$?
check "bad --by is a usage error (rc 2)" "$rc" "2"
rc=0; LEG_COST_LEDGER="$W/none.jsonl" bash "$SUT" >/dev/null 2>&1 || rc=$?
check "absent ledger is an error (rc 1)" "$rc" "1"

if [ "$fails" -eq 0 ]; then echo "PASS - test-leg-cost-report.sh"; exit 0; fi
echo "FAIL - test-leg-cost-report.sh ($fails failure(s))"
exit 1
