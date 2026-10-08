#!/usr/bin/env bash
# scripts/cr/test-cr-round-metrics.sh — fixture ledger with KNOWN numbers for
# cr-round-metrics.sh (HIMMEL-5059). bash 3.2-safe.
# shellcheck disable=SC2015,SC2016  # A && B || C intentional; literal $var in fixture text
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"; CM="$HERE/cr-round-metrics.sh"
tmp="$(mktemp -d)" || exit 1; trap 'rm -rf "$tmp"' EXIT
L="$tmp/ledger.jsonl"; K="$tmp/known.json"
fails=0
check() { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }

f() { # f <ts> <branch> <head> <round> <id> <sev> <text>
  printf '{"kind":"finding","ts":"%s","branch":"%s","head":"%s","model":"codex","finding_id":"%s","severity":"%s","round":%s,"file":"x.sh","line":1,"verdict":"","text":"%s"}\n' "$1" "$2" "$3" "$5" "$6" "$4" "$7"
}
{
  # old: outside the 30-day window, but earlier history for the repeat rate
  f 2026-07-01T00:00:00Z fix/old o1 1 c-1 imp 'NUL-delimited paths are split on newline'
  # a: 3 rounds, no cap hit
  f 2026-10-01T00:00:00Z fix/a a1 1 c-1 imp 'unquoted $var causes word splitting in the guard'
  f 2026-10-01T00:00:01Z fix/a a1 1 c-2 sug 'rm -rf cleanup on an unvalidated path'
  f 2026-10-01T01:00:00Z fix/a a2 2 c-3 imp 'NUL-delimited paths are split on newline again'
  f 2026-10-01T02:00:00Z fix/a a3 3 c-4 sug 'unquoted $var causes word splitting again'
  # b: 4 rounds = cap hit
  f 2026-10-05T00:00:00Z fix/b b1 1 c-1 imp 'unquoted $var in the tokenizer breaks word splitting'
  f 2026-10-05T01:00:00Z fix/b b2 2 c-2 imp 'no timeout bound on the loop; it hangs'
  f 2026-10-05T02:00:00Z fix/b b3 3 c-3 crit 'fail-open on parse error lets the command through'
  f 2026-10-05T03:00:00Z fix/b b4 4 c-4 crit 'this test is vacuous: the assertion cannot fail'
  echo '{"kind":"amend","ts":"2026-10-01T00:05:00Z","branch":"","target_head":"a1","finding_id":"c-2","artifact":"diff","perspective":"off","set":{"verdict":"disproved"}}'
  echo '{"kind":"avail","ts":"2026-10-01T00:00:00Z","branch":"fix/a","head":"a1","model":"codex","status":"ok"}'
} > "$L"
cat > "$K" <<'EOF'
{"classes":[{"id":"timeout-bound","kind":"fix","learning_match":"timeout|hangs"}]}
EOF

out="$(CR_LEDGER="$L" bash "$CM" --now 2026-10-09T00:00:00Z --days 30 --known "$K" 2>&1)"
rc=$?
check "exit 0" "$rc" "0"
json="$(grep -m1 '^{' <<< "$out")"
q() { node -e 'let o=JSON.parse(process.argv[1]),v=o;for(const k of process.argv[2].split("."))v=v==null?v:v[k];console.log(v===undefined?"undef":typeof v==="object"?JSON.stringify(v):v)' "$json" "$1" 2>&1; }

check "branches in window" "$(q branches)" "2"
check "rounds p50" "$(q rounds.p50)" "3"
check "rounds p90" "$(q rounds.p90)" "4"
check "cap hits" "$(q cap_hits.count)" "1"
check "cap hit branch" "$(q cap_hits.branches)" '["fix/b"]'
check "findings total" "$(q findings.total)" "8"
check "severity crit" "$(q findings.by_severity.crit)" "2"
check "severity imp" "$(q findings.by_severity.imp)" "4"
check "severity sug" "$(q findings.by_severity.sug)" "2"
check "class quoting" "$(q findings.by_class.quoting-tokenization)" "3"
check "class nul" "$(q findings.by_class.nul-delimited)" "1"
check "verdict disproved" "$(q findings.by_verdict.disproved)" "1"
# repeats vs an earlier PR: a/c-3 (nul vs old) and b/c-1 (quoting vs a). a/c-4 repeats within a branch only.
check "repeat count" "$(q repeat.vs_earlier_prs.count)" "2"
check "repeat rate" "$(q repeat.vs_earlier_prs.rate)" "0.25"
check "known matched" "$(q repeat.known_findings.matched)" "1"
check "top class" "$(node -e 'console.log(JSON.parse(process.argv[1]).top_classes[0].class)' "$json")" "quoting-tokenization"
check "summary line" "$(grep -c '^cr-round-metrics: ' <<< "$out")" "1"

# --groups: fix/a gated, fix/b ungrouped
printf 'fix/a\tgated\n' > "$tmp/groups.tsv"
json="$(CR_LEDGER="$L" bash "$CM" --now 2026-10-09T00:00:00Z --known "$K" --groups "$tmp/groups.tsv" | grep -m1 '^{')"
check "group gated p90" "$(q groups.gated.p90)" "3"
check "group ungrouped cap hits" "$(q groups.ungrouped.cap_hits)" "1"
check "group gated repeat rate" "$(q groups.gated.repeat_rate)" "0.25"

# empty ledger: no crash, zero branches
: > "$tmp/empty.jsonl"
CR_LEDGER="$tmp/empty.jsonl" bash "$CM" --now 2026-10-09T00:00:00Z --known "$K" > "$tmp/e.out" 2>&1
check "empty ledger exits 0" "$?" "0"

[ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
