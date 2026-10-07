#!/usr/bin/env bash
# scripts/eval/leg-digest/test-failure-router.sh - hermetic suite for the failure router (HIMMEL-4670 P5).
# Scratch state, log, inbox and a stub Jira only; never ~/.himmel, never a real Jira write. No model call.
# The spec 7 row P5 proof, end to end over a fixture ledger:
#  a. denied/guard-pr-check-literal with identical retry in 2 distinct legs files exactly ONE ticket,
#     whose body passes the alphabet check and carries no canary;
#  b. a third leg adds one comment and no ticket; a run with no new leg writes nothing;
#  c. a 4th class on a capped day files nothing and writes a capped line;
#  d. a denied/classifier:* recurrence writes one memory-inbox candidate;
#  e. two chained sessions of one leg (N500 + N500b) do not trip recurrence;
#  f. every decision has exactly one decision-log line.
# Plus: route --dry-run writes nothing and calls no Jira; never-routed classes log nothing; a Done ticket is
# never re-filed; an unreadable state file, a search error or a bad body file nothing; the role and window filters.
#
# check() evals its condition, so the single quotes are deliberate.
# shellcheck disable=SC2016,SC2034,SC2012  # check() evals single-quoted asserts that read these vars
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
FR="$HERE/failure_router.py"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/failure-router-test.XXXXXX")" || { echo "test-failure-router: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
# Never the live files, whatever a case forgets to pass.
export HIMMEL_LEG_FAILURES_LEDGER="$TMP/never-ledger.jsonl"
export HIMMEL_FAILURE_ROUTES_LOG="$TMP/never-log.jsonl"
export HIMMEL_FAILURE_ROUTES_STATE="$TMP/never-state.json"
export HIMMEL_FAILURE_INBOX="$TMP/never-inbox.md"
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
lines() { if [ -f "$1" ]; then grep -c . "$1"; else echo 0; fi; }
CANARY=CANARY4670zq
NOW=2026-10-07T12:00:00Z

# The stub Jira: records every call, answers list from $STUB/list.<label> (and its rc from $STUB/list.rc),
# create with a fresh key, comment with success. Bodies are copied out for the checks.
STUB="$TMP/stub"; mkdir -p "$STUB"
cat >"$STUB/jira" <<'EOF'
#!/usr/bin/env bash
d="$(dirname "$0")"
printf '%s\n' "$*" >>"$d/calls.log"
op="$1"; shift
grab() { while [ $# -gt 0 ]; do case "$1" in --desc-file|--comment-file) cp "$2" "$d/body.$op.$(wc -l <"$d/calls.log")"; shift 2 ;; *) shift ;; esac; done; }
case "$op" in
  list) lbl="$(printf '%s' "$*" | sed -n 's/.*labels = "\([^"]*\)".*/\1/p')"; [ -f "$d/list.$lbl" ] && cat "$d/list.$lbl"; exit "$(cat "$d/list.rc" 2>/dev/null || echo 0)" ;;
  create) grab "$@"; n=$(( $(cat "$d/n" 2>/dev/null || echo 9000) + 1 )); echo "$n" >"$d/n"; echo "Created HIMMEL-$n" ;;
  comment) grab "$@"; echo "Comment added to $1" ;;
  *) exit 9 ;;
esac
EOF
chmod +x "$STUB/jira"

LED="$TMP/ledger.jsonl"; ST="$TMP/state.json"; LOG="$TMP/routes.log.jsonl"; INBOX="$TMP/inbox.md"
calls() { if [ -f "$STUB/calls.log" ]; then grep -c "^$1 " "$STUB/calls.log"; else echo 0; fi; }
route() { python3 "$FR" route --ledger "$LED" --state "$ST" --log "$LOG" --inbox "$INBOX" --now "$NOW" --jira-bin "$STUB/jira" "$@"; }
# row <leg|null> <class> [identical_retry] [recovered] [role] [ts] [final_red]
SEQ=0
row() {
  SEQ=$((SEQ + 1))
  local leg="$1" cls="$2" ir="${3:-0}" rec="${4:-false}" role="${5:-leg}" ts="${6:-2026-10-06T10:00:00Z}" fr="${7:-}"
  local id=main; [ "$role" = leg ] || id="agent-$SEQ"
  jq -nc --arg leg "$leg" --arg cls "$cls" --argjson ir "$ir" --argjson rec "$rec" --arg role "$role" --arg id "$id" \
    --arg ts "$ts" --arg fr "$fr" --arg sid "$(printf '4670c1a5-0000-4000-8000-%012d' "$SEQ")" --arg c "$CANARY" '
    {v:1, ts:$ts, host:"h", source:"scripts/eval/leg-digest/leg_ledger.py", kind:"leg-failure", session:$sid,
     leg:(if $leg == "null" then null else $leg end), console:$c, ticket:"HIMMEL-4670", pr:1990,
     agent:{id:$id, role:$role, kind:$c, model:"claude-opus-5-5"}, class:$cls, failure:($cls | split("/")[0]),
     count:2, identical_retry:$ir, recovered:$rec, first_ts:1, last_ts:2, tool_call_ids:[$c]}
    + (if $fr == "" then {} else {final_red:($fr == "true")} end)' >>"$LED"
}

echo "0. RED guard: the router exists"
check "failure_router.py is present" '[ -f "$FR" ]'

echo "a. two distinct legs with identical retry file exactly one ticket"
row N100 denied/guard-pr-check-literal 1
row N200 denied/guard-pr-check-literal 2
# Chained sessions of one leg (e), never-routed classes, a filtered role and an aged row ride along.
row N500 denied/guard-gh 1
row N500b denied/guard-gh 1
row N100 traj/claim-unverified; row N200 traj/claim-unverified
row N100 traj/red-before-green; row N200 traj/red-before-green
row N100 blocked/-; row N200 blocked/-
row N100 suite/test-tick.sh 0 false leg 2026-10-06T10:00:00Z false; row N200 suite/test-tick.sh 0 false leg 2026-10-06T10:00:00Z false
row N100 run_error/overloaded; row N200 run_error/overloaded
row N100 denied/block-git-stash 1 false subagent; row N200 denied/block-git-stash 1 false subagent
row N100 denied/guard-relay-writes 1; row N200 denied/guard-relay-writes 1 false leg 2026-09-01T10:00:00Z
row null denied/check-push-target 1; row N100 denied/check-push-target 1
route >"$TMP/a.out" 2>&1 || bad "route exits 0: $(head -c 400 "$TMP/a.out")"
check "exactly one create through the stub" '[ "$(calls create)" = 1 ]'
check "a label search ran before the create, over every status" 'grep -q "^list --jql project = HIMMEL AND labels = \"fl-denied-guard-pr-check-literal\" --limit 5" "$STUB/calls.log"'
check "the create carries the two labels, Task, no fixVersion" 'grep "^create " "$STUB/calls.log" | grep -q -- "--type Task" && grep "^create " "$STUB/calls.log" | grep -q -- "--labels failure-loop,fl-denied-guard-pr-check-literal" && ! grep -q -- "--fix-version" "$STUB/calls.log"'
body="$(ls "$STUB"/body.create.* 2>/dev/null | head -n 1)"
check "the ticket body passes the alphabet check" '[ -n "$body" ] && python3 "$FR" check-body "$body" >/dev/null'
check "the body names the class, the leg count and both legs" 'grep -q "denied/guard-pr-check-literal" "$body" && grep -q "distinct legs (14 d): 2" "$body" && grep -q "N100, N200" "$body"'
check "no canary in the body, the call log, the state or the decision log" '! grep -q "$CANARY" "$body" "$STUB/calls.log" "$ST" "$LOG"'
check "one filed line, carrying the ticket" '[ "$(lines "$LOG")" = 1 ] && jq -e "select(.class == \"denied/guard-pr-check-literal\") | .decision == \"filed\" and .ticket == \"HIMMEL-9001\" and .legs == 2 and (.ts | test(\"^2026-10-07T12:00:00\"))" "$LOG" >/dev/null'
check "e. N500 + N500b count as one leg: no decision" '! grep -q "denied/guard-gh" "$LOG"'
check "signal-only, never-routed and run_error classes log nothing" '! grep -Eq "traj/|blocked/|suite/test-tick|run_error/" "$LOG"'
check "a subagent-role denial does not count" '! grep -q "block-git-stash" "$LOG"'
check "a row older than 14 days does not count" '! grep -q "guard-relay-writes" "$LOG"'
check "a null-leg row does not count" '! grep -q "check-push-target" "$LOG"'
check "the state file maps the class to its ticket" 'jq -e ".classes[\"denied/guard-pr-check-literal\"].ticket == \"HIMMEL-9001\"" "$ST" >/dev/null'

echo "b. a third leg comments once; no new leg writes nothing"
route >"$TMP/b0.out" 2>&1
check "a rerun with no new leg makes no call and no line" '[ "$(calls create)" = 1 ] && [ "$(calls comment)" = 0 ] && [ "$(lines "$LOG")" = 1 ]'
GL="$STUB/list.fl-denied-guard-pr-check-literal"
printf 'HIMMEL-9001\tTask\tTo Do\tlegs retype past guard-pr-check-literal\n' >"$GL"
row N300 denied/guard-pr-check-literal 1
route >"$TMP/b.out" 2>&1 || bad "route exits 0 on the third leg"
check "one comment on the ticket, no new create" '[ "$(calls comment)" = 1 ] && [ "$(calls create)" = 1 ] && grep -q "^comment HIMMEL-9001 --comment-file " "$STUB/calls.log"'
cbody="$(ls "$STUB"/body.comment.* 2>/dev/null | head -n 1)"
check "the comment body passes the alphabet check and has the new count" '[ -n "$cbody" ] && python3 "$FR" check-body "$cbody" >/dev/null && grep -q "distinct legs (14 d): 3" "$cbody"'
check "one commented line" '[ "$(lines "$LOG")" = 2 ] && [ "$(jq -r "select(.decision == \"commented\") | .ticket" "$LOG")" = HIMMEL-9001 ]'
row N400 denied/guard-pr-check-literal 1
route >/dev/null 2>&1
check "a fourth leg the same day does not comment twice" '[ "$(calls comment)" = 1 ] && [ "$(jq -r "select(.legs == 4) | .decision" "$LOG")" = skipped:comment-daily ]'

echo "c + d. the daily cap and the memory-inbox candidate"
row N100 suite/test-board.sh 0 false leg 2026-10-06T10:00:00Z true; row N200 suite/test-board.sh 0 false leg 2026-10-06T10:00:00Z true
row N100 denied/permission-prompt; row N200 denied/permission-prompt
route >/dev/null 2>&1
check "two more classes file (3 today)" '[ "$(calls create)" = 3 ] && [ "$(jq -r "select(.decision == \"filed\") | .class" "$LOG" | sort -u | wc -l)" = 3 ]'
row N100 denied/classifier:merge-without-review; row N200 denied/classifier:merge-without-review
route >"$TMP/c.out" 2>&1 || bad "route exits 0 on the capped day"
check "c. the 4th class files nothing and writes one capped line" '[ "$(calls create)" = 3 ] && [ "$(jq -r "select(.class == \"denied/classifier:merge-without-review\") | .decision" "$LOG")" = capped ]'
check "d. the classifier recurrence writes one memory-inbox candidate" '[ "$(grep -c "^- " "$INBOX")" = 1 ] && grep -q "denied/classifier:merge-without-review" "$INBOX" && grep -q "shell-and-gate-traps.md" "$INBOX"'
check "the inbox line carries no canary" '! grep -q "$CANARY" "$INBOX"'
check "only the classifier class writes to the inbox" '! grep -Eq "permission-prompt|test-board|guard-pr-check" "$INBOX"'
route >/dev/null 2>&1
check "a rerun with no new leg adds no inbox line and no log line" '[ "$(grep -c "^- " "$INBOX")" = 1 ] && [ "$(lines "$LOG")" = 6 ]'
route --now 2026-10-08T12:00:00Z >/dev/null 2>&1
check "the next day the capped class files and the open ticket gets its daily comment" '[ "$(calls create)" = 4 ] && [ "$(calls comment)" = 2 ] && [ "$(jq -r "select(.class == \"denied/classifier:merge-without-review\") | .decision" "$LOG" | tail -n 1)" = filed ]'
check "and it still writes no second inbox candidate" '[ "$(grep -c "^- " "$INBOX")" = 1 ]'

echo "f. every decision has exactly one decision-log line"
check "the log is 8 lines, one per decision, in order" '[ "$(lines "$LOG")" = 8 ] && [ "$(jq -r .decision "$LOG" | tr "\n" " ")" = "filed commented skipped:comment-daily filed filed capped filed commented " ]'
check "every line is {ts,class,legs,decision,ticket}" '[ "$(jq -c "keys" "$LOG" | sort -u)" = "[\"class\",\"decision\",\"legs\",\"ticket\",\"ts\"]" ]'

echo "dry-run writes nothing and calls no Jira"
row N600 denied/guard-pr-check-literal 1
row N100 error/Edit; row N200 error/Edit; row N300 error/Edit
before="$(cat "$ST" "$LOG" "$INBOX" | sha256sum)"; ncalls="$(lines "$STUB/calls.log")"
route --now 2026-10-09T12:00:00Z --dry-run >"$TMP/dry.out" 2>&1 || bad "route --dry-run exits 0"
check "no call, no state, log or inbox change" '[ "$(lines "$STUB/calls.log")" = "$ncalls" ] && [ "$(cat "$ST" "$LOG" "$INBOX" | sha256sum)" = "$before" ]'
check "it prints what it would do" 'grep -q "would-comment" "$TMP/dry.out" && grep -q "would-file" "$TMP/dry.out" && grep -q "error/Edit" "$TMP/dry.out"'

echo "a Done ticket is never re-filed or reopened"
printf 'HIMMEL-9001\tTask\tDone\tlegs retype past guard-pr-check-literal\n' >"$GL"
route --now 2026-10-09T12:00:00Z >/dev/null 2>&1
check "recurred-after-done, no comment and no create for it" '[ "$(jq -r "select(.class == \"denied/guard-pr-check-literal\") | .decision" "$LOG" | tail -n 1)" = recurred-after-done ] && [ "$(calls comment)" = 2 ] && [ "$(grep -c "fl-denied-guard-pr-check-literal" "$STUB/calls.log")" -ge 1 ] && [ "$(grep "^create " "$STUB/calls.log" | grep -c "fl-denied-guard-pr-check-literal")" = 1 ]'

echo "fail closed for Jira"
F2="$TMP/f2"; mkdir -p "$F2"; cp "$LED" "$F2/l.jsonl"
printf 'not json' >"$F2/state.json"; n0="$(calls create)"
python3 "$FR" route --ledger "$F2/l.jsonl" --state "$F2/state.json" --log "$F2/log" --inbox "$F2/inbox" --now "$NOW" --jira-bin "$STUB/jira" >/dev/null 2>&1
check "an unreadable state file calls nothing and logs skipped:state-unreadable" '[ "$(calls create)" = "$n0" ] && [ "$(jq -r .decision "$F2/log" | sort -u)" = skipped:state-unreadable ] && [ ! -f "$F2/inbox" ]'
echo 1 >"$STUB/list.rc"
python3 "$FR" route --ledger "$F2/l.jsonl" --state "$F2/fresh.json" --log "$F2/log2" --inbox "$F2/inbox" --now "$NOW" --jira-bin "$STUB/jira" >/dev/null 2>&1
check "a search error files nothing and logs skipped:search-error" '[ "$(calls create)" = "$n0" ] && [ "$(jq -r .decision "$F2/log2" | sort -u)" = skipped:search-error ]'
rm -f "$STUB/list.rc"
printf -- '- class: denied/x\n- note: %s\n' "$CANARY" >"$TMP/badbody"
check "check-body refuses a line outside the alphabet" '! python3 "$FR" check-body "$TMP/badbody" >/dev/null 2>&1'
printf -- '- class: denied/x\n- legs: N1, rm -rf /\n' >"$TMP/badbody2"
check "check-body refuses a value outside its label's alphabet" '! python3 "$FR" check-body "$TMP/badbody2" >/dev/null 2>&1'

echo "the routing table is data"
check "failure-routes.table.json parses and names every spec 4.2 key pattern" 'jq -e "[.routes[].match] | index(\"denied/classifier:*\") and index(\"suite/*\") and index(\"error/*\") and index(\"traj/claim-unverified\")" "$HERE/failure-routes.table.json" >/dev/null'
check "the window is 14 days and the cap is 3" 'jq -e ".window_days == 14 and .daily_cap == 3" "$HERE/failure-routes.table.json" >/dev/null'

echo
echo "test-failure-router: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
