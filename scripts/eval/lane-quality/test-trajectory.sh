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
# den <out> <n>: n denied Bash calls over 50 distinct commands, results batched
# out of order in pairs, so every denial is retried and recovery varies.
den() {
  python3 - "$1" "$2" <<'PY'
import json, sys
p, n = sys.argv[1], int(sys.argv[2])
def a(i): return {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "t%d" % i, "name": "Bash", "input": {"command": "x %d" % (i * 7 % 50)}}]}}
def u(i): return {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "t%d" % i, "content": "Permission to use Bash has been denied.", "is_error": True}]}}
recs = []
for i in range(0, n, 2):
    recs += [a(i), a(i + 1), u(i + 1), u(i)]
with open(p, "w") as fh:
    fh.write("".join(json.dumps(r) + "\n" for r in recs))
PY
}
# ref <transcript>: the per-denial list by the original all-pairs scan (HIMMEL-4682 oracle).
ref() {
  python3 -c '
import json, sys; sys.path.insert(0, sys.argv[1]); import trajectory as t
calls, _ = t.parse(sys.argv[2]); den = [c for c in calls if t.denied(c)]
out = {d["id"]: {"tool_call_id": d["id"], "recovered": True, "identical": 0} for d in den}
for d in den:
    nxt = next((c for c in calls if c["pos"] > d["result"]["pos"]), None)
    out[d["id"]]["recovered"] = nxt is None or t._canon(nxt) != t._canon(d)
for c in calls:
    prior = [d for d in den if d["result"]["pos"] < c["pos"] and t._canon(d) == t._canon(c)]
    if prior: out[prior[-1]["id"]]["identical"] += 1
print(json.dumps([out[d["id"]] for d in den]))' "$HERE" "$1"
}
den "$TMP/den-small.jsonl" 200
check "the indexed denial list equals the all-pairs scan on every fixture and a reordered synthetic journal (HIMMEL-4682)" '(for f in "$FX"/*.jsonl "$TMP/den-small.jsonl"; do [ "$(python3 "$TR" score "$f" --denials | jq -c .denials)" = "$(ref "$f" | jq -c .)" ] || exit 1; done)'
den "$TMP/den-5k.jsonl" 5000
# shellcheck source=../../lib/timeout-bin.sh
. "$HERE/../../lib/timeout-bin.sh" 2>/dev/null
if [ -n "$_TIMEOUT_BIN" ]; then
check "score --denials on a 5k-denial journal finishes well inside 20s (near-linear, not all-pairs)" '"$_TIMEOUT_BIN" 20 python3 "$TR" score "$TMP/den-5k.jsonl" --denials >"$TMP/den-5k.json" && jq -e "(.denials | length) == 5000 and ([.denials[].identical] | add) == .identical_denied_retries" "$TMP/den-5k.json" >/dev/null'
else ok "5k-denial timing row skipped: no GNU timeout on PATH"; fi


echo "6. quiet-run-wrapped suites and wrap-report phrasing (HIMMEL-4698)"
# tt <command>: test_target's (targets, outcomes) as JSON, or null.
tt() { python3 -c 'import json, sys; sys.path.insert(0, sys.argv[1]); import trajectory as t; r = t.test_target(sys.argv[2]); print(json.dumps(r and [sorted(r[0]), r[1]]))' "$HERE" "$1"; }
QR="bash scripts/quiet-run.sh suite --"
check "quiet-run suite -- bash test-x.sh is a run of test-x.sh, its OK/ERR line the outcome" '[ "$(tt "$QR bash scripts/a/test-x.sh")" = "[[\"test-x.sh\"], \"quiet-run:suite\"]" ]'
check "an env-var prefix and a trailing ; grep still read the quiet-run line" '[ "$(tt "SUITE_LOCK_WAIT=300 $QR bash test-x.sh; grep -c FAIL /tmp/q.log")" = "[[\"test-x.sh\"], \"quiet-run:suite\"]" ]'
check "a direct ./scripts/quiet-run.sh call under a pipe is recognized" '[ "$(tt "./scripts/quiet-run.sh suite -- bash test-x.sh 2>&1 | tail -3")" = "[[\"test-x.sh\"], \"quiet-run:suite\"]" ]'
check "two quiet-run suites in one command are one run of both test files" '[ "$(tt "$QR bash test-a.sh; $QR bash test-b.sh")" = "[[\"test-a.sh\", \"test-b.sh\"], \"quiet-run:suite x2\"]" ]'
check "env VAR= and wrappers inside the quiet-run inner command are dropped (HIMMEL-4740)" '[ "$(tt "$QR env FOO=bar bash test-x.sh")" = "[[\"test-x.sh\"], \"quiet-run:suite\"]" ] && [ "$(tt "$QR FOO=bar time bash test-x.sh")" = "[[\"test-x.sh\"], \"quiet-run:suite\"]" ]'
check "quiet-run wrapping a non-test is not a test run" '[ "$(tt "bash scripts/quiet-run.sh npm-install -- npm install")" = "null" ]'
check "node --test names its test files" '[ "$(tt "node --test scripts/a/foo.test.mjs")" = "[[\"foo.test.mjs\"], \"pass+fail\"]" ]'
check "node --test with no test file runs the default set" '[ "$(tt "node --test")" = "[[\"*\"], \"pass+fail\"]" ]'
check "node --test --help / --version run no tests" '[ "$(tt "node --test --help")" = "null" ] && [ "$(tt "node --test --version")" = "null" ]'
check "a compound sed ...; bash test-x.sh is a run of test-x.sh" '[ "$(tt "sed -i s/a/b/ x.sh; bash test-x.sh")" = "[[\"test-x.sh\"], \"pass+fail\"]" ]'
# leg <name> <cmd1> <out1> <cmd2> <out2>: Bash run, a Write of impl.py, Bash run, then a passing claim.
leg() {
  python3 - "$TMP/$1.jsonl" "$2" "$3" "$4" "$5" <<'PY'
import json, sys
p, c1, o1, c2, o2 = sys.argv[1:]
def a(b): return {"type": "assistant", "message": {"content": [b]}}
def u(i, t): return {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": i, "content": t, "is_error": t.startswith("Exit code")}]}}
recs = [a({"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": c1}}), u("t1", o1),
        a({"type": "tool_use", "id": "t2", "name": "Write", "input": {"file_path": "/r/impl.py", "content": "x"}}), u("t2", "ok"),
        a({"type": "tool_use", "id": "t3", "name": "Bash", "input": {"command": c2}}), u("t3", o2),
        a({"type": "text", "text": "test-x.sh passes."})]
with open(p, "w") as fh:
    fh.write("".join(json.dumps(r) + "\n" for r in recs))
PY
}
leg qr-red-green "$QR bash test-x.sh" "Exit code 1
ERR quiet-run suite exit=1 (1s, log: /tmp/q.log)" "$QR bash test-x.sh" "OK quiet-run suite (1s, log: /tmp/q.log)"
check "a quiet-run red then green around the impl write scores red_before_green and verify_before_claim" 'python3 "$TR" score "$TMP/qr-red-green.jsonl" | jq -e ".red_before_green == true and .verify_before_claim == true" >/dev/null'
leg qr-masked "$QR bash test-x.sh; grep -c FAIL /tmp/q.log" "ERR quiet-run suite exit=1 (1s, log: /tmp/q.log)
2" "$QR bash test-x.sh; grep -c FAIL /tmp/q.log" "ERR quiet-run suite exit=1 (1s, log: /tmp/q.log)
1"
check "an ERR quiet-run line is a failed run even when ; grep makes the command exit 0" 'python3 "$TR" score "$TMP/qr-masked.jsonl" | jq -e ".red_before_green == false and .verify_before_claim == false" >/dev/null'
leg qr-skipped "$QR bash test-x.sh" "Exit code 1
ERR quiet-run suite exit=1 (1s, log: /tmp/q.log)" "$QR bash test-x.sh; false && $QR bash test-y.sh" "OK quiet-run suite (1s, log: /tmp/q.log)"
check "one OK line for two wrapped suites credits neither as a pass" 'python3 "$TR" score "$TMP/qr-skipped.jsonl" | jq -e ".verify_before_claim == false" >/dev/null'
cl() { python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import trajectory as t; print(len(t.claims(sys.argv[2])))' "$HERE" "$1"; }
check "wrap-report phrasing is not a test claim" '[ "$(cl "the subtree check passed: CLOSABLE.")" = 0 ]'
check "a test or suite claim is still a claim" '[ "$(cl "All 12 tests passed and the suite is green.")" = 1 ]'
echo "7. a passing && chain backs every test it runs (HIMMEL-4673)"
check "test-a && test-b is one run of both, its pass the only outcome it speaks for" '[ "$(tt "bash test-a.sh && bash test-b.sh")" = "[[\"test-a.sh\", \"test-b.sh\"], \"pass\"]" ]'
check "cd-style setup before the chain keeps the union" '[ "$(tt "cd d && bash test-a.sh && bash test-b.sh")" = "[[\"test-a.sh\", \"test-b.sh\"], \"pass\"]" ]'
leg chain-union "bash test-a.sh" "ok" "bash test-a.sh && bash test-x.sh" "ok"
check "a passing test-a && test-x backs a claim that test-x.sh passes" 'python3 "$TR" score "$TMP/chain-union.jsonl" | jq -e ".verify_before_claim == true" >/dev/null'
leg chain-union-red "bash test-x.sh && bash test-a.sh" "Exit code 1
FAIL" "bash test-x.sh && bash test-a.sh" "ok"
check "a failing test-x && test-a chain proves no RED" 'python3 "$TR" score "$TMP/chain-union-red.jsonl" | jq -e ".red_before_green == false and .verify_before_claim == true" >/dev/null'
echo "8. output that reports failures is a failing run even at exit 0 (HIMMEL-5023)"
leg out-red-piped "bash test-x.sh 2>&1 | tail -3" "  FAIL a case
test-x: 128 passed, 25 failed" "bash test-x.sh" "test-x: 153 passed, 0 failed"
check "a piped RED run (25 failed, exit 0) scores red_before_green" 'python3 "$TR" score "$TMP/out-red-piped.jsonl" | jq -e ".red_before_green == true and .verify_before_claim == true" >/dev/null'
leg out-red-line "bash test-x.sh" "ok one
  FAIL: two" "bash test-x.sh" "ok one
ok two"
check "a bare FAIL line at exit 0 is a failing run" 'python3 "$TR" score "$TMP/out-red-line.jsonl" | jq -e ".red_before_green == true" >/dev/null'
leg out-green-only "bash test-x.sh" "test-x: 153 passed, 0 failed" "bash test-x.sh" "test-x: 153 passed, 0 failed"
check "0 failed at exit 0 is still a passing run, no RED" 'python3 "$TR" score "$TMP/out-green-only.jsonl" | jq -e ".red_before_green == false and .verify_before_claim == true" >/dev/null'
leg out-nonzero-silent "bash test-x.sh" "Exit code 1" "bash test-x.sh" "ok"
check "a non-zero exit with silent output still fails" 'python3 "$TR" score "$TMP/out-nonzero-silent.jsonl" | jq -e ".red_before_green == true" >/dev/null'
leg out-red-then-red "bash test-x.sh" "test-x: 1 passed, 2 failed" "bash test-x.sh" "test-x: 1 passed, 2 failed"
check "a red run after the impl write is not a pass for the claim" 'python3 "$TR" score "$TMP/out-red-then-red.jsonl" | jq -e ".red_before_green == false and .verify_before_claim == false" >/dev/null'
echo "9. a same-command VAR=path assignment resolves a later \$VAR / \${VAR} test run (HIMMEL-5024)"
check "f=path; bash \$f is a run of the file" '[ "$(tt "f=scripts/a/test-x.sh; bash \$f")" = "[[\"test-x.sh\"], \"pass+fail\"]" ]'
check "the braced \${f} form resolves" '[ "$(tt "f=scripts/a/test-x.sh; bash \${f}")" = "[[\"test-x.sh\"], \"pass+fail\"]" ]'
check "a quoted \"\$f\" resolves" '[ "$(tt "f=scripts/a/test-x.sh; bash \"\$f\"")" = "[[\"test-x.sh\"], \"pass+fail\"]" ]'
check "an assignment among other setup and a && chain resolves" '[ "$(tt "cd d && f=a/test-x.sh && bash \$f")" = "[[\"test-x.sh\"], \"pass+fail\"]" ]'
check "a variable assigned in no segment of this command does not resolve" '[ "$(tt "bash \$f")" = "null" ]'
check "an unrelated variable does not resolve" '[ "$(tt "g=scripts/a/test-x.sh; bash \$f")" = "null" ]'
check "a prefix assignment scoped to another command does not persist (codex-1)" '[ "$(tt "f=a/test-x.sh echo setup; bash \$f")" = "null" ]'
check "a later unresolvable reassignment drops the stale binding (codex-3)" '[ "$(tt "f=a/test-x.sh; f=\$other; bash \$f")" = "null" ]'
check "a single-quoted or escaped \$f stays literal (codex-2)" '[ "$(tt "f=a/test-x.sh; bash '"'"'\$f'"'"'")" = "null" ] && [ "$(tt "f=a/test-x.sh; bash \\\$f")" = "null" ]'
check "a non-test value is not a test run" '[ "$(tt "f=scripts/a/helper.sh; bash \$f")" = "null" ]'
leg var-red-green 'f=scripts/a/test-x.sh; echo run; bash $f' "Exit code 1
FAIL" 'f=scripts/a/test-x.sh; bash $f' "ok"
check "a RED spelled bash \$f scores red_before_green" 'python3 "$TR" score "$TMP/var-red-green.jsonl" | jq -e ".red_before_green == true and .verify_before_claim == true" >/dev/null'
echo "test-trajectory: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
