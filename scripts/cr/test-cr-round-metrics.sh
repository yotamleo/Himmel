#!/usr/bin/env bash
# scripts/cr/test-cr-round-metrics.sh — fixture ledger with KNOWN numbers for
# cr-round-metrics.sh (HIMMEL-5059). bash 3.2-safe.
# shellcheck disable=SC2015,SC2016  # A && B || C intentional; literal $var in fixture text
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"; CM="$HERE/cr-round-metrics.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cr-round-metrics.XXXXXX")" || exit 1; trap 'rm -rf "$tmp"' EXIT
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

# --now bounds every row: at 10-05T01:30 fix/b has 2 rows and no cap hit
json="$(CR_LEDGER="$L" bash "$CM" --now 2026-10-05T01:30:00Z --known "$K" | grep -m1 '^{')"
check "--now findings total" "$(q findings.total)" "6"
check "--now cap hits" "$(q cap_hits.count)" "0"

# group names that collide with Object.prototype keys must not crash
printf 'fix/a\tconstructor\n' > "$tmp/groups2.tsv"
json="$(CR_LEDGER="$L" bash "$CM" --now 2026-10-09T00:00:00Z --known "$K" --groups "$tmp/groups2.tsv" | grep -m1 '^{')"
check "proto-named group" "$(q groups.constructor.branches)" "1"

# overlapping branches: x starts first but raises nul only AFTER y does, so y is no repeat
{
  f 2026-10-02T00:00:00Z fix/x x1 1 c-1 imp 'no timeout bound on the loop; it hangs'
  f 2026-10-02T09:00:00Z fix/x x2 2 c-2 imp 'NUL-delimited paths are split on newline'
  f 2026-10-02T05:00:00Z fix/y y1 1 c-1 imp 'NUL-delimited paths are split on newline'
} > "$tmp/overlap.jsonl"
json="$(CR_LEDGER="$tmp/overlap.jsonl" bash "$CM" --now 2026-10-09T00:00:00Z --known "$K" | grep -m1 '^{')"
check "overlap repeat count" "$(q repeat.vs_earlier_prs.count)" "1"

# empty ledger: no crash, zero branches
: > "$tmp/empty.jsonl"
CR_LEDGER="$tmp/empty.jsonl" bash "$CM" --now 2026-10-09T00:00:00Z --known "$K" > "$tmp/e.out" 2>&1
check "empty ledger exits 0" "$?" "0"
json="$(grep -m1 '^{' "$tmp/e.out")"
check "empty ledger is JSON with zero branches" "$(q branches)" "0"
CR_LEDGER="$tmp/missing.jsonl" bash "$CM" --now 2026-10-09T00:00:00Z --known "$K" > "$tmp/m.out" 2>&1
check "missing ledger exits 2" "$?" "2"
check "missing ledger names the path" "$(grep -c "$tmp/missing.jsonl" "$tmp/m.out")" "1"
check "missing ledger prints no JSON" "$(grep -c '^{' "$tmp/m.out")" "0"

# no CR_LEDGER and not inside a git repo: no ledger to read, not a zero report
( cd "$tmp" && env -u CR_LEDGER GIT_CEILING_DIRECTORIES="$tmp/.." bash "$CM" --known "$K" ) > "$tmp/nr.out" 2>&1
check "outside a repo exits 2" "$?" "2"

# a non-empty ledger with no usable record is an error, not a zero report
printf 'garbage\n{not json\nnull\n' > "$tmp/allbad.jsonl"
CR_LEDGER="$tmp/allbad.jsonl" bash "$CM" --now 2026-10-09T00:00:00Z --known "$K" > "$tmp/ab.out" 2>&1
check "all-malformed ledger exits 2" "$?" "2"
check "all-malformed prints no JSON" "$(grep -c '^{' "$tmp/ab.out")" "0"

# some malformed lines: reported in the JSON and on stderr, still exit 0
printf 'garbage\n' > "$tmp/mixed.jsonl"; cat "$L" >> "$tmp/mixed.jsonl"
CR_LEDGER="$tmp/mixed.jsonl" bash "$CM" --now 2026-10-09T00:00:00Z --known "$K" > "$tmp/mx.out" 2> "$tmp/mx.err"
check "mixed ledger exits 0" "$?" "0"
json="$(grep -m1 '^{' "$tmp/mx.out")"
check "skipped lines counted in JSON" "$(q ledger_lines_skipped)" "1"
check "skipped lines noted on stderr" "$(grep -c 'skipped 1 of' "$tmp/mx.err")" "1"

# an explicit --known that is missing or unparsable fails; the default stays tolerant
CR_LEDGER="$L" bash "$CM" --now 2026-10-09T00:00:00Z --known "$tmp/nope.json" > "$tmp/k1.out" 2>&1
check "missing --known exits 2" "$?" "2"
printf '{oops' > "$tmp/badknown.json"
CR_LEDGER="$L" bash "$CM" --now 2026-10-09T00:00:00Z --known "$tmp/badknown.json" > "$tmp/k2.out" 2>&1
check "unparsable --known exits 2" "$?" "2"

# a missing --groups file is a clean message, not a stack trace
CR_LEDGER="$L" bash "$CM" --now 2026-10-09T00:00:00Z --known "$K" --groups "$tmp/nogroups.tsv" > "$tmp/g.out" 2>&1
check "missing --groups exits 2" "$?" "2"
check "missing --groups has no stack trace" "$(grep -c ' at ' "$tmp/g.out")" "0"
check "missing --groups names the file" "$(grep -c 'nogroups.tsv' "$tmp/g.out")" "1"

# an amend after --now is not applied: the disproved verdict lands at 10-01T00:05
json="$(CR_LEDGER="$L" bash "$CM" --now 2026-10-01T00:03:00Z --known "$K" | grep -m1 '^{')"
check "amend after --now ignored" "$(q findings.by_verdict.disproved)" "undef"

CR_LEDGER="$L" bash "$CM" --now not-a-date --known "$K" > "$tmp/bad.out" 2>&1
check "invalid --now exits 2" "$?" "2"

# unreadable ledger (a directory) is an error, not an empty report
CR_LEDGER="$tmp" bash "$CM" --now 2026-10-09T00:00:00Z --known "$K" > "$tmp/d.out" 2>&1
check "unreadable ledger exits 2" "$?" "2"

# a JSON null line is skipped like a malformed line
{ echo null; echo 42; cat "$L"; } > "$tmp/nulls.jsonl"
json="$(CR_LEDGER="$tmp/nulls.jsonl" bash "$CM" --now 2026-10-09T00:00:00Z --known "$K" | grep -m1 '^{')"
check "null record skipped" "$(q findings.total)" "8"

# huge --days is a usage error, not a crash
CR_LEDGER="$L" bash "$CM" --now 2026-10-09T00:00:00Z --days 99999999999 --known "$K" > "$tmp/h.out" 2>&1
check "huge --days exits 2" "$?" "2"

[ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
