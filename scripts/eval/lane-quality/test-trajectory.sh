#!/usr/bin/env bash
# scripts/eval/lane-quality/test-trajectory.sh - hermetic suite for the
# trajectory scorer (HIMMEL-4651). Every field has a positive and a negative
# synthetic fixture under fixtures/trajectory/; no model call, no bank.
#  1. `score` gives the expected four fields on each fixture;
#  2. an unreadable or empty transcript scores null, never a crash;
#  3. `rescore` reads a stored run dir and finds each transcript by session id;
#  4. the lane adapter turns the per-task fields into ledger metrics.
#
# check() evals its condition, so the single quotes are deliberate.
# shellcheck disable=SC2016
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
TR="$HERE/trajectory.py"
FX="$HERE/fixtures/trajectory"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/trajectory-test.XXXXXX")" || { echo "test-trajectory: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export HIMMEL_EVAL_RUNS_LEDGER="$TMP/eval-runs.jsonl"
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# expect <fixture> <red_before_green> <denial_recovery> <identical_denied_retries> <verify_before_claim>
expect() {
  local got want
  got="$(python3 "$TR" score "$FX/$1.jsonl" 2>"$TMP/$1.err" | jq -c '[.red_before_green, (if .denial_recovery == null then null else (.denial_recovery * 1000 | round) end), .identical_denied_retries, .verify_before_claim]')"
  want="[$2,$3,$4,$5]"
  if [ "$got" = "$want" ]; then ok "$1: $want"; else bad "$1: want $want, got '${got:-}' $(head -c 300 "$TMP/$1.err")"; fi
}

echo "1. score: one positive and one negative fixture per field"
#       fixture           rbg   recov idr vbc
expect red-green          true  null  0   true
expect green-only         false null  0   true
# red-denied re-sends its denied command after a Write: not the next call
# (recovered), but still an identical retry.
expect red-denied         false 1000  1   true
expect denial-recovered   null  1000  0   null
expect denial-repeated    false 333   2   true
expect claim-unverified   false null  0   false
expect claim-stale        false null  0   false
expect no-claim           null  null  0   null
expect masked             false null  0   false
expect chain-and          false null  0   true
expect chain-trailing     true  null  0   true
expect runner-named       false null  0   false
expect runner-named-ok    false null  0   true
expect not-a-run          false null  0   false
expect runner-config      false null  0   true

echo "2. unreadable or empty input"
: >"$TMP/empty.jsonl"
check "an empty transcript scores no claim and no test run" 'python3 "$TR" score "$TMP/empty.jsonl" | jq -e ".red_before_green == null and .verify_before_claim == null and .identical_denied_retries == 0" >/dev/null'
check "a missing transcript scores all null" 'python3 "$TR" score "$TMP/nope.jsonl" | jq -e "[.[]] | all(. == null)" >/dev/null'
printf 'not json\n{"type":"assistant"}\n[]\n' >"$TMP/junk.jsonl"
check "malformed lines are skipped, not fatal" 'python3 "$TR" score "$TMP/junk.jsonl" | jq -e ".identical_denied_retries == 0" >/dev/null'

echo "3. rescore a stored run dir (no model call)"
mkdir -p "$TMP/run" "$TMP/projects/p"
cp "$FX/red-green.jsonl" "$TMP/projects/p/sid-a.jsonl"
cp "$FX/claim-unverified.jsonl" "$TMP/projects/p/sid-b.jsonl"
printf '%s\n' '{"task":"a","rep":1}' '{"task":"b","rep":1}' '{"task":"c","rep":1}' >"$TMP/run/runs.jsonl"
echo '{"session_id":"sid-a"}' >"$TMP/run/a.result.json"
echo '{"session_id":"sid-b"}' >"$TMP/run/b.result.json"
echo '{"session_id":"sid-gone"}' >"$TMP/run/c.result.json"
check "rescore exits 0" 'python3 "$TR" rescore "$TMP/run" --transcripts "$TMP/projects" --json >"$TMP/rescore.json" 2>"$TMP/rescore.err"'
check "rescore scores each row by its session transcript" 'jq -e ".rows | map(.red_before_green) == [true, false, null]" "$TMP/rescore.json" >/dev/null'
check "rescore marks a row whose transcript is gone" 'jq -e ".rows[2].transcript == null" "$TMP/rescore.json" >/dev/null'
check "rescore summary counts scored rows per field" 'jq -e ".summary.verify_before_claim == {\"n\": 2, \"true\": 1, \"rate\": 0.5}" "$TMP/rescore.json" >/dev/null'
check "rescore never rewrites the run dir" '[ "$(cat "$TMP/run/runs.jsonl" | wc -l | tr -d " ")" = 3 ] && ! jq -e "has(\"red_before_green\")" "$TMP/run/runs.jsonl" >/dev/null'
check "rescore prints a markdown summary by default" 'python3 "$TR" rescore "$TMP/run" --transcripts "$TMP/projects" | grep -q "^| verify_before_claim | 2 |"'

echo "4. the lane adapter carries the fields into the ledger row"
cat >"$TMP/run/runs.jsonl" <<'ROWS'
{"task":"a","rep":1,"lane":"native","model":"m","accept_passed":1,"accept_total":1,"accept_ok":true,"scope_ok":true,"red_before_green":true,"denial_recovery":1.0,"identical_denied_retries":0,"verify_before_claim":true}
{"task":"b","rep":1,"lane":"native","model":"m","accept_passed":0,"accept_total":1,"accept_ok":false,"scope_ok":true,"red_before_green":false,"denial_recovery":0.5,"identical_denied_retries":2,"verify_before_claim":false}
{"task":"c","rep":1,"lane":"native","model":"m","accept_passed":0,"accept_total":1,"accept_ok":false,"scope_ok":true,"red_before_green":null,"denial_recovery":null,"identical_denied_retries":1,"verify_before_claim":null}
ROWS
python3 "$HERE/../lib/eval_runs.py" lane-quality "$TMP/run" --run-id t1 >/dev/null 2>"$TMP/adapter.err"
check "the adapter writes a valid row" 'python3 "$HERE/../lib/eval_runs.py" validate "$HIMMEL_EVAL_RUNS_LEDGER" >/dev/null'
check "rates count only the rows where a field applies" 'jq -e ".metrics.red_before_green_rate == 0.5 and .metrics.denial_recovery_rate == 0.75 and .metrics.verify_before_claim_rate == 0.5" "$HIMMEL_EVAL_RUNS_LEDGER" >/dev/null'
check "identical denied retries are summed" 'jq -e ".metrics.identical_denied_retries == 3" "$HIMMEL_EVAL_RUNS_LEDGER" >/dev/null'
printf '%s\n' '{"task":"a","rep":1,"accept_passed":1,"accept_total":1,"accept_ok":true,"scope_ok":true}' >"$TMP/run/runs.jsonl"
python3 "$HERE/../lib/eval_runs.py" lane-quality "$TMP/run" --run-id t2 >/dev/null 2>&1
check "a pre-4651 run dir still writes a row, its fields null" 'jq -s -e ".[-1].metrics | .red_before_green_rate == null and .identical_denied_retries == null" "$HIMMEL_EVAL_RUNS_LEDGER" >/dev/null'

echo "5. score --denials: the per-denial list the leg digest joins by tool_call_id (HIMMEL-4670)"
check "denial-repeated lists each denial: recovered when the next call differs, identical = the retries it drew" 'python3 "$TR" score "$FX/denial-repeated.jsonl" --denials | jq -e -c ".denials == [{\"tool_call_id\":\"toolu_01\",\"recovered\":false,\"identical\":1},{\"tool_call_id\":\"toolu_02\",\"recovered\":false,\"identical\":1},{\"tool_call_id\":\"toolu_03\",\"recovered\":true,\"identical\":0}]" >/dev/null'
check "a retry after an intervening call still counts against the denial it repeats" 'python3 "$TR" score "$FX/red-denied.jsonl" --denials | jq -e -c ".denials == [{\"tool_call_id\":\"toolu_02\",\"recovered\":true,\"identical\":1}]" >/dev/null'
check "the per-denial identical counts sum to identical_denied_retries on every fixture" '(for f in "$FX"/*.jsonl; do python3 "$TR" score "$f" --denials | jq -e "([.denials[].identical] | add // 0) == .identical_denied_retries" >/dev/null || exit 1; done)'
check "without --denials the output keeps exactly the four fields (run.sh merges it into runs.jsonl)" 'python3 "$TR" score "$FX/denial-repeated.jsonl" | jq -e "keys == [\"denial_recovery\",\"identical_denied_retries\",\"red_before_green\",\"verify_before_claim\"]" >/dev/null'
check "a missing transcript lists no denials" 'python3 "$TR" score "$TMP/nope.jsonl" --denials | jq -e ".denials == []" >/dev/null'
check "--denials names the schema version the fields were scored under" 'python3 "$TR" score "$FX/red-green.jsonl" --denials | jq -e ".trajectory_v == 1" >/dev/null'

echo "test-trajectory: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
