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
# HIMMEL-4754: decision rows only; the route-intent rows are the pre-send lines.
dlines() { if [ -f "$1" ]; then grep -c '"kind":"route-decision"' "$1"; else echo 0; fi; }
decs() { jq -c 'select(.kind == "route-decision")' "$1"; }
CANARY=CANARY4670zq
# The router fails closed without a project key; the suite names one, and the no-key cases unset it.
export JIRA_PROJECT_KEY=HIMMEL
NOW=2026-10-07T12:00:00Z

# The stub Jira: records every call, answers list from $STUB/list.<label> (and its rc from $STUB/list.rc),
# create with a fresh key, comment with success. Bodies are copied out for the checks.
STUB="$TMP/stub"; mkdir -p "$STUB"
cat >"$STUB/jira" <<'EOF'
#!/usr/bin/env bash
d="$(dirname "$0")"
printf '%s\n' "$*" >>"$d/calls.log"
op="$1"; shift
# HIMMEL-4754: with LOGPROBE set, record how many intent lines the log held when a send arrived.
case "$op" in create|comment) [ -n "${LOGPROBE:-}" ] && { grep -c route-intent "$LOGPROBE" 2>/dev/null; true; } >>"$d/intent-seen.log" ;; esac
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
check "the create carries the two labels, Task, no fixVersion" 'grep -q -- "^create .*--type Task" "$STUB/calls.log" && grep -q -- "^create .*--labels failure-loop,fl-denied-guard-pr-check-literal" "$STUB/calls.log" &&! grep -q -- "--fix-version" "$STUB/calls.log"'
body="$(ls "$STUB"/body.create.* 2>/dev/null | head -n 1)"
check "the ticket body passes the alphabet check" '[ -n "$body" ] && python3 "$FR" check-body "$body" >/dev/null'
check "the body names the class, the leg count and both legs" 'grep -q "denied/guard-pr-check-literal" "$body" && grep -q "distinct legs (14 d): 2" "$body" && grep -q "N100, N200" "$body"'
check "no canary in the body, the call log, the state or the decision log" '! grep -q "$CANARY" "$body" "$STUB/calls.log" "$ST" "$LOG"'
check "one filed line, carrying the ticket" '[ "$(dlines "$LOG")" = 1 ] && decs "$LOG" | jq -e "select(.class == \"denied/guard-pr-check-literal\") | .decision == \"filed\" and .ticket == \"HIMMEL-9001\" and .legs == 2 and (.ts | test(\"^2026-10-07T12:00:00\"))" >/dev/null'
check "e. N500 + N500b count as one leg: no decision" '! grep -q "denied/guard-gh" "$LOG"'
check "signal-only, never-routed and run_error classes log nothing" '! grep -Eq "traj/|blocked/|suite/test-tick|run_error/" "$LOG"'
check "a subagent-role denial does not count" '! grep -q "block-git-stash" "$LOG"'
check "a row older than 14 days does not count" '! grep -q "guard-relay-writes" "$LOG"'
check "a null-leg row does not count" '! grep -q "check-push-target" "$LOG"'
check "the state file maps the class to its ticket" 'jq -e ".classes[\"denied/guard-pr-check-literal\"].ticket == \"HIMMEL-9001\"" "$ST" >/dev/null'

echo "b. a third leg comments once; no new leg writes nothing"
route >"$TMP/b0.out" 2>&1
check "a rerun with no new leg makes no call and no line" '[ "$(calls create)" = 1 ] && [ "$(calls comment)" = 0 ] && [ "$(dlines "$LOG")" = 1 ]'
GL="$STUB/list.fl-denied-guard-pr-check-literal"
printf 'HIMMEL-9001\tTask\tTo Do\tlegs retype past guard-pr-check-literal\n' >"$GL"
row N300 denied/guard-pr-check-literal 1
route >"$TMP/b.out" 2>&1 || bad "route exits 0 on the third leg"
check "one comment on the ticket, no new create" '[ "$(calls comment)" = 1 ] && [ "$(calls create)" = 1 ] && grep -q "^comment HIMMEL-9001 --comment-file " "$STUB/calls.log"'
cbody="$(ls "$STUB"/body.comment.* 2>/dev/null | head -n 1)"
check "the comment body passes the alphabet check and has the new count" '[ -n "$cbody" ] && python3 "$FR" check-body "$cbody" >/dev/null && grep -q "distinct legs (14 d): 3" "$cbody"'
check "one commented line" '[ "$(dlines "$LOG")" = 2 ] && [ "$(decs "$LOG" | jq -r "select(.decision == \"commented\") | .ticket")" = HIMMEL-9001 ]'
row N400 denied/guard-pr-check-literal 1
route >/dev/null 2>&1
check "a fourth leg the same day does not comment twice" '[ "$(calls comment)" = 1 ] && [ "$(decs "$LOG" | jq -r "select(.legs == 4) | .decision")" = skipped:comment-daily ]'

echo "c + d. the daily cap and the memory-inbox candidate"
row N100 suite/test-board.sh 0 false leg 2026-10-06T10:00:00Z true; row N200 suite/test-board.sh 0 false leg 2026-10-06T10:00:00Z true
row N100 denied/permission-prompt; row N200 denied/permission-prompt
route >/dev/null 2>&1
check "two more classes file (3 today)" '[ "$(calls create)" = 3 ] && [ "$(decs "$LOG" | jq -r "select(.decision == \"filed\") | .class" | sort -u | wc -l)" = 3 ]'
row N100 denied/classifier:merge-without-review; row N200 denied/classifier:merge-without-review
route >"$TMP/c.out" 2>&1 || bad "route exits 0 on the capped day"
check "c. the 4th class files nothing and writes one capped line" '[ "$(calls create)" = 3 ] && [ "$(decs "$LOG" | jq -r "select(.class == \"denied/classifier:merge-without-review\") | .decision")" = capped ]'
check "d. the classifier recurrence writes one memory-inbox candidate" '[ "$(grep -c "^- " "$INBOX")" = 1 ] && grep -q "denied/classifier:merge-without-review" "$INBOX" && grep -q "shell-and-gate-traps.md" "$INBOX"'
check "the inbox line carries no canary" '! grep -q "$CANARY" "$INBOX"'
check "only the classifier class writes to the inbox" '! grep -Eq "permission-prompt|test-board|guard-pr-check" "$INBOX"'
route >/dev/null 2>&1
check "a rerun with no new leg adds no inbox line and no log line" '[ "$(grep -c "^- " "$INBOX")" = 1 ] && [ "$(dlines "$LOG")" = 6 ]'
route --now 2026-10-08T12:00:00Z >/dev/null 2>&1
check "the next day the capped class files and the open ticket gets its daily comment" '[ "$(calls create)" = 4 ] && [ "$(calls comment)" = 2 ] && [ "$(decs "$LOG" | jq -r "select(.class == \"denied/classifier:merge-without-review\") | .decision" | tail -n 1)" = filed ]'
check "and it still writes no second inbox candidate" '[ "$(grep -c "^- " "$INBOX")" = 1 ]'

echo "f. every decision has exactly one decision-log line"
check "the log is 8 lines, one per decision, in order" '[ "$(dlines "$LOG")" = 8 ] && [ "$(decs "$LOG" | jq -r .decision | tr "\n" " ")" = "filed commented skipped:comment-daily filed filed capped filed commented " ]'
check "every line is the standard envelope plus {class,legs,decision,ticket}" '[ "$(decs "$LOG" | jq -c "keys" | sort -u)" = "[\"class\",\"decision\",\"host\",\"kind\",\"legs\",\"source\",\"ticket\",\"ts\",\"v\"]" ] && decs "$LOG" | jq -e -s "length > 0 and all(.[]; .v == 1 and .kind == \"route-decision\" and .source == \"scripts/eval/leg-digest/failure_router.py\" and (.host | length) > 0)" >/dev/null'
check "every route-intent line is the standard envelope plus {class,legs,intent}, and each one precedes a decision line" '[ "$(jq -c "select(.kind == \"route-intent\") | keys" "$LOG" | sort -u)" = "[\"class\",\"host\",\"intent\",\"kind\",\"legs\",\"source\",\"ts\",\"v\"]" ] && [ "$(jq -r .kind "$LOG" | grep -c route-intent)" = "$(( $(dlines "$LOG") - $(decs "$LOG" | jq -r .decision | grep -Ec "^(skipped|capped|recurred)") ))" ]'

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
check "recurred-after-done, no comment and no create for it" '[ "$(decs "$LOG" | jq -r "select(.class == \"denied/guard-pr-check-literal\") | .decision" | tail -n 1)" = recurred-after-done ] && [ "$(calls comment)" = 2 ] && [ "$(grep -c "fl-denied-guard-pr-check-literal" "$STUB/calls.log")" -ge 1 ] && [ "$(grep "^create " "$STUB/calls.log" | grep -c "fl-denied-guard-pr-check-literal")" = 1 ]'

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

F3="$TMP/f3"; mkdir -p "$F3"; n0="$(calls create)"
SAVE="$LED"; LED="$F3/l.jsonl"; row N1 denied/guard-x 1; row N2 denied/guard-x 1; LED="$SAVE"
printf 'Error: unexpected response\n' >"$STUB/list.fl-denied-guard-x"
python3 "$FR" route --ledger "$F3/l.jsonl" --state "$F3/s.json" --log "$F3/log" --inbox "$F3/inbox" --now "$NOW" --jira-bin "$STUB/jira" >/dev/null 2>&1
check "search output that is not ticket rows files nothing and logs skipped:search-error" '[ "$(calls create)" = "$n0" ] && [ "$(jq -r .decision "$F3/log")" = skipped:search-error ]'

echo "a recurrence in new legs after the old ones aged out still acts"
F4="$TMP/f4"; mkdir -p "$F4"
SAVE="$LED"; LED="$F4/l.jsonl"
row N1 denied/guard-y 1 false leg 2026-10-01T10:00:00Z; row N2 denied/guard-y 1 false leg 2026-10-01T10:00:00Z
f4() { python3 "$FR" route --ledger "$F4/l.jsonl" --state "$F4/s.json" --log "$F4/log" --inbox "$F4/inbox" --jira-bin "$STUB/jira" "$@" >/dev/null 2>&1; }
f4 --now 2026-10-02T12:00:00Z
k4="$(decs "$F4/log" | jq -r .ticket | head -n 1)"
printf '%s\tTask\tTo Do\tlegs retype past guard-y\n' "$k4" >"$STUB/list.fl-denied-guard-y"
row N3 denied/guard-y 1 false leg 2026-10-20T10:00:00Z; row N4 denied/guard-y 1 false leg 2026-10-20T10:00:00Z
LED="$SAVE"
f4 --now 2026-10-21T12:00:00Z
check "filed on N1+N2, then commented on N3+N4 once N1+N2 left the window" '[ "$(decs "$F4/log" | jq -r .decision | paste -sd " ")" = "filed commented" ]'
c4="$(calls comment)"
SAVE="$LED"; LED="$F4/l.jsonl"
row N5 denied/guard-y 1 false leg 2026-11-05T10:00:00Z; row N6 denied/guard-y 1 false leg 2026-11-05T10:00:00Z
LED="$SAVE"
f4 --now 2026-11-06T12:00:00Z
check "a comment on new legs at the same leg count still writes its decision line" '[ "$(calls comment)" = "$((c4 + 1))" ] && [ "$(decs "$F4/log" | jq -r .decision | paste -sd " ")" = "filed commented commented" ]'

echo "ledger rows dated after the routing time do not count"
F5="$TMP/f5"; mkdir -p "$F5"; n5="$(calls create)"
SAVE="$LED"; LED="$F5/l.jsonl"
row N1 denied/guard-z 1 false leg 2026-10-20T10:00:00Z; row N2 denied/guard-z 1 false leg 2026-10-20T10:00:00Z
LED="$SAVE"
python3 "$FR" route --ledger "$F5/l.jsonl" --state "$F5/s.json" --log "$F5/log" --inbox "$F5/inbox" --now "$NOW" --jira-bin "$STUB/jira" >/dev/null 2>&1
check "two future-dated legs file nothing and log nothing" '[ "$(calls create)" = "$n5" ] && [ ! -s "$F5/log" ]'

echo "a decision-log write that fails leaves the class unacted, so the next run decides again"
F6="$TMP/f6"; mkdir -p "$F6/log"
SAVE="$LED"; LED="$F6/l.jsonl"; row N1 denied/guard-w 1; row N2 denied/guard-w 1; LED="$SAVE"
python3 "$FR" route --ledger "$F6/l.jsonl" --state "$F6/s.json" --log "$F6/log" --inbox "$F6/inbox" --now "$NOW" --jira-bin "$STUB/jira" >/dev/null 2>&1
check "no acted legs are saved for a decision whose log line failed" '[ -z "$(jq -r ".classes[\"denied/guard-w\"].acted // empty" "$F6/s.json" 2>/dev/null)" ]'

echo "HIMMEL-4754: no send without a logged decision"
F7="$TMP/f7"; mkdir -p "$F7"
SAVE="$LED"; LED="$F7/l.jsonl"; row N1 denied/guard-v 1; row N2 denied/guard-v 1; LED="$SAVE"
rm -f "$STUB/intent-seen.log"; n7="$(calls create)"
LOGPROBE="$F7/log" python3 "$FR" route --ledger "$F7/l.jsonl" --state "$F7/s.json" --log "$F7/log" --inbox "$F7/inbox" --now "$NOW" --jira-bin "$STUB/jira" >/dev/null 2>&1
check "an intent line is already in the log when the create arrives" '[ "$(calls create)" = "$((n7 + 1))" ] && [ "$(tail -n 1 "$STUB/intent-seen.log")" = 1 ]'
check "the intent line is a route-intent row with the envelope and no decision, and the decision line follows" '[ "$(jq -r .kind "$F7/log" | paste -sd " ")" = "route-intent route-decision" ] && jq -e -s ".[0] | .v == 1 and (.host | length) > 0 and .class == \"denied/guard-v\" and .intent == \"file\" and (has(\"decision\") | not)" "$F7/log" >/dev/null'
k7="$(decs "$F7/log" | jq -r .ticket | head -n 1)"; printf "%s\tTask\tTo Do\tx\n" "$k7" >"$STUB/list.fl-denied-guard-v"
SAVE="$LED"; LED="$F7/l.jsonl"; row N3 denied/guard-v 1; LED="$SAVE"
rm -f "$STUB/intent-seen.log"
LOGPROBE="$F7/log" python3 "$FR" route --ledger "$F7/l.jsonl" --state "$F7/s.json" --log "$F7/log" --inbox "$F7/inbox" --now "$NOW" --jira-bin "$STUB/jira" >/dev/null 2>&1
check "a comment is preceded by its own intent line too" '[ "$(tail -n 1 "$STUB/intent-seen.log")" = 2 ] && [ "$(jq -r .intent "$F7/log" | grep -c comment)" = 1 ]'
F8="$TMP/f8"; mkdir -p "$F8/log"
SAVE="$LED"; LED="$F8/l.jsonl"; row N1 denied/guard-u 1; row N2 denied/guard-u 1; LED="$SAVE"
n8="$(calls create)"
python3 "$FR" route --ledger "$F8/l.jsonl" --state "$F8/s.json" --log "$F8/log" --inbox "$F8/inbox" --now "$NOW" --jira-bin "$STUB/jira" >/dev/null 2>&1
check "an unwritable log means no create is sent" '[ "$(calls create)" = "$n8" ]'
SAVE="$LED"; LED="$F7/l.jsonl"; row N4 denied/guard-v 1; LED="$SAVE"
c8="$(calls comment)"
python3 "$FR" route --now 2026-10-08T12:00:00Z --ledger "$F7/l.jsonl" --state "$F7/s.json" --log "$F8/log" --inbox "$F7/inbox" --jira-bin "$STUB/jira" >/dev/null 2>&1
check "an unwritable log means no comment is sent" '[ "$(calls comment)" = "$c8" ]'

echo "HIMMEL-4754: no JIRA_PROJECT_KEY fails closed"
F9="$TMP/f9"; mkdir -p "$F9"
SAVE="$LED"; LED="$F9/l.jsonl"; row N1 denied/guard-t 1; row N2 denied/guard-t 1; LED="$SAVE"
n9="$(lines "$STUB/calls.log")"
env -u JIRA_PROJECT_KEY python3 "$FR" route --ledger "$F9/l.jsonl" --state "$F9/s.json" --log "$F9/log" --inbox "$F9/inbox" --now "$NOW" --jira-bin "$STUB/jira" >"$TMP/nokey.out" 2>&1; rc9=$?
check "an unset key exits non-zero, names the key, calls nothing and writes nothing" '[ "$rc9" != 0 ] && grep -q JIRA_PROJECT_KEY "$TMP/nokey.out" && [ "$(lines "$STUB/calls.log")" = "$n9" ] && [ ! -e "$F9/log" ] && [ ! -e "$F9/s.json" ]'
JIRA_PROJECT_KEY='' python3 "$FR" route --ledger "$F9/l.jsonl" --state "$F9/s.json" --log "$F9/log" --inbox "$F9/inbox" --now "$NOW" --jira-bin "$STUB/jira" >/dev/null 2>&1; rc9=$?
check "an empty key fails closed the same way" '[ "$rc9" != 0 ] && [ "$(lines "$STUB/calls.log")" = "$n9" ]'
env -u JIRA_PROJECT_KEY python3 "$FR" route --dry-run --ledger "$F9/l.jsonl" --state "$F9/s.json" --log "$F9/log" --now "$NOW" >"$TMP/nokey-dry.out" 2>&1; rc9=$?
check "--dry-run still works without a key" '[ "$rc9" = 0 ] && grep -q would-file "$TMP/nokey-dry.out"'

echo "HIMMEL-4785: error/Bash sub-classes file one actionable ticket each"
F10="$TMP/f10"; mkdir -p "$F10"
SAVE="$LED"; LED="$F10/l.jsonl"
for c in error/Bash:usage:impacted-suites error/Bash:zsh-nomatch error/Bash:no-such-file error/Bash error/Edit; do
  row N1 "$c"; row N2 "$c"; row N3 "$c"
done
row N1 error/Bash:cr-gate-exit-14; row N2 error/Bash:cr-gate-exit-14; row N3 error/Bash:cr-gate-exit-14
row N1 denied/guard-leg-context-handoff 1; row N2 denied/guard-leg-context-handoff 1
LED="$SAVE"
DRY10="$TMP/dry10.out"
python3 "$FR" route --dry-run --ledger "$F10/l.jsonl" --state "$F10/s.json" --log "$F10/log" --inbox "$F10/inbox" --now "$NOW" >"$DRY10" 2>&1
wf10() { jq -e --arg c "$1" "select(.class == \$c and .decision == \"would-file\")" "$DRY10" >/dev/null; }
check "each sub-class would be filed under its own class" 'for c in error/Bash:usage:impacted-suites error/Bash:zsh-nomatch error/Bash:no-such-file error/Bash:cr-gate-exit-14; do wf10 "$c" || return 1; done'
check "the usage ticket names the script and the fix, not just Bash errors" 'jq -er ".routes[] | select(.match == \"error/Bash:usage:*\") | .summary" "$HERE/failure-routes.table.json" | grep -q "{sub}" && ! jq -er ".routes[] | select(.match == \"error/Bash:usage:*\") | .summary" "$HERE/failure-routes.table.json" | grep -q "errors recur"'
check "every error/Bash:* row carries its own summary, none is the generic one" '[ "$(jq "[.routes[] | select(.match | startswith(\"error/Bash:\")) | .summary] | map(select(contains(\"errors recur\"))) | length" "$HERE/failure-routes.table.json")" = 0 ] && [ "$(jq "[.routes[] | select(.match | startswith(\"error/Bash:\"))] | length" "$HERE/failure-routes.table.json")" -ge 4 ]'
check "the sub-class rows sit before the generic error/* row" '[ "$(jq "[.routes[].match] | (index(\"error/Bash:usage:*\") != null) and index(\"error/Bash:usage:*\") < index(\"error/*\")" "$HERE/failure-routes.table.json")" = true ]'
check "a plain error/Bash and error/Edit still route through the generic row" 'wf10 error/Bash && wf10 error/Edit'
check "the context-guard denial is routed as its own named hook" 'wf10 denied/guard-leg-context-handoff'
check "ok/no-match is never a routable class: the ledger refuses it and the table has no ticket row for it" '! grep -q "\"ok/" "$DRY10" && ! python3 -c "import sys; sys.path.insert(0, sys.argv[1]); import failure_router as f, json; t = json.load(open(sys.argv[2])); sys.exit(0 if any(r[\"route\"] == \"ticket\" and f.fits(r[\"match\"], \"ok/no-match\") for r in t[\"routes\"]) else 1)" "$HERE" "$HERE/failure-routes.table.json"'

echo "the routing table is data"
check "failure-routes.table.json parses and names every spec 4.2 key pattern" 'jq -e "[.routes[].match] | index(\"denied/classifier:*\") and index(\"suite/*\") and index(\"error/*\") and index(\"traj/claim-unverified\")" "$HERE/failure-routes.table.json" >/dev/null'
check "the window is 14 days and the cap is 3" 'jq -e ".window_days == 14 and .daily_cap == 3" "$HERE/failure-routes.table.json" >/dev/null'

echo
echo "test-failure-router: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
