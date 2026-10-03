#!/usr/bin/env bash
# scripts/eval/lane-quality/test-lane-quality.sh - hermetic suite for the
# lane-quality eval harness (HIMMEL-4090). No real claude call: a fake binary
# stands in for the agent and the judge, and a fake bank preflight for the bank.
#  1. every hidden acceptance test FAILS on its untouched fixture and PASSES on
#     its reference solution (a test that cannot fail is not evidence);
#  2. `run` end to end: metrics, acceptance, blind-judge packet redaction,
#     worktree cleanup;
#  3. the budget cap, the bank refusal and the phase-2 lane refusal;
#  4. `table` renders the recorded rows.
#
# check() evals its condition, so the single quotes and $R are deliberate.
# shellcheck disable=SC2016,SC2034
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
RUN="$HERE/run.sh"
REAL_REPO="$(cd "$HERE/../../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/lane-quality-test.XXXXXX")" || { echo "test-lane-quality: mktemp -d failed" >&2; exit 1; }
trap 'git -C "$TMP/repo" worktree prune >/dev/null 2>&1; rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# A tiny stand-in for the pinned himmel tree: finding-verify cites the real
# cache-probe.sh, so it is copied in byte for byte.
mkdir -p "$TMP/repo/scripts/eval"
cp "$REAL_REPO/scripts/eval/cache-probe.sh" "$TMP/repo/scripts/eval/"
git -C "$TMP/repo" init -q
git -C "$TMP/repo" -c user.name=t -c user.email=t@t add -A
git -C "$TMP/repo" -c user.name=t -c user.email=t@t commit -qm base
BASE="$(git -C "$TMP/repo" rev-parse HEAD)"

echo "1. acceptance tests discriminate (fixture RED, reference GREEN)"
for task in shell-red-green doc-plus-code hook-refusal finding-verify; do
  wt="$TMP/acc-$task"
  git -C "$TMP/repo" worktree add -q --detach "$wt" "$BASE"
  fix="$(bash "$RUN" materialize "$task" "$wt")"
  if bash "$HERE/tasks/$task/accept.sh" "$wt" "$fix" >"$TMP/acc-$task.red" 2>&1; then
    bad "$task: accept passes on the untouched fixture"
  else ok "$task: accept fails on the untouched fixture"; fi
  bash "$RUN" materialize "$task" "$wt" --reference >/dev/null
  if bash "$HERE/tasks/$task/accept.sh" "$wt" "$fix" >"$TMP/acc-$task.green" 2>&1; then
    ok "$task: accept passes on the reference"
  else bad "$task: accept fails on the reference: $(grep FAIL "$TMP/acc-$task.green" | tr '\n' ';')"; fi
done

# Fake claude: the judge call (has --json-schema) records its stdin and scores
# 4s; an agent call copies the task's reference into its cwd and writes a
# transcript with 2 tool calls, 1 compaction and 1 hook denial.
mkdir -p "$TMP/bin" "$TMP/projects/p"
cat >"$TMP/bin/claude" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$LQ_FAKE_LOG"
case " $* " in *" --json-schema "*)
  cat >>"$LQ_FAKE_LOG.judge"
  echo '{"type":"result","is_error":false,"total_cost_usd":0.02,"structured_output":{"correctness":4,"scope_discipline":4,"test_quality":4,"honesty":4,"notes":"n"}}'
  exit 0 ;;
esac
prompt="$2"
case "$prompt" in
  *semver-cmp*) t=shell-red-green ;; *log-tail*) t=doc-plus-code ;;
  *block-curl-pipe*) t=hook-refusal ;; *) t=finding-verify ;;
esac
bash "$LQ_FAKE_RUN" materialize "$t" "$PWD" --reference >/dev/null
sid="sess-$t"
{
  echo '{"type":"assistant","message":{"id":"m1","content":[{"type":"tool_use","id":"tu1","name":"Read","input":{"file_path":"lq-work/x"}}]}}'
  echo '{"type":"assistant","message":{"id":"m2","content":[{"type":"tool_use","id":"tu2","name":"Bash","input":{"command":"cat scripts/eval/lane-quality/tasks/x"}}]}}'
  echo '{"type":"assistant","message":{"id":"m2","content":[{"type":"tool_use","id":"tu2","name":"Bash","input":{"command":"cat scripts/eval/lane-quality/tasks/x"}}]}}'
  echo '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu2","is_error":true,"content":"PreToolUse:Bash hook error: refusing"}]}}'
  echo '{"type":"system","subtype":"compact_boundary"}'
} >"$LQ_TRANSCRIPTS/p/$sid.jsonl"
jq -cn --arg s "$sid" '{type:"result",subtype:"success",is_error:false,session_id:$s,total_cost_usd:0.5,num_turns:3,duration_ms:1000,permission_denials:[{tool_name:"Bash"}],result:"Done by claude-haiku-4-5 via openrouter; tests pass."}'
FAKE
chmod +x "$TMP/bin/claude"
printf '#!/usr/bin/env bash\necho "bank-preflight: five_hour=${LQ_FAKE_5H:-10.0} seven_day=3.0" >&2\necho "${LQ_FAKE_TOKEN:-PROCEED}"\n' >"$TMP/bin/preflight"
chmod +x "$TMP/bin/preflight"

export LQ_CLAUDE_BIN="$TMP/bin/claude" LQ_PREFLIGHT="$TMP/bin/preflight" LQ_REPO="$TMP/repo" \
  LQ_BASE_SHA="$BASE" LQ_WORK_ROOT="$TMP/work" LQ_TRANSCRIPTS="$TMP/projects" \
  LQ_FAKE_LOG="$TMP/fake.log" LQ_FAKE_RUN="$RUN"

echo "2. run end to end (fake agent + fake judge)"
bash "$RUN" run --lane native --model claude-haiku-4-5 --tasks shell-red-green,finding-verify --out "$TMP/out1" >"$TMP/run1.log" 2>&1
rc=$?
R="$TMP/out1/runs.jsonl"
check "run exits 0" '[ "$rc" -eq 0 ]'
[ "$rc" -eq 0 ] || sed 's/^/    run1: /' "$TMP/run1.log"
check "two rows recorded" '[ "$(wc -l <"$R" | tr -d " ")" = 2 ]'
check "acceptance passed on both" '[ "$(jq -s "map(select(.accept_ok)) | length" "$R")" = 2 ]'
check "tool calls deduped by id" '[ "$(jq -s ".[0].tool_calls" "$R")" = 2 ]'
check "compactions counted" '[ "$(jq -s ".[0].compactions" "$R")" = 1 ]'
check "hook denials counted" '[ "$(jq -s ".[0].hook_denials" "$R")" = 1 ]'
check "permission denials counted" '[ "$(jq -s ".[0].permission_denials" "$R")" = 1 ]'
check "cost recorded" '[ "$(jq -s ".[0].cost_usd" "$R")" = 0.5 ]'
check "bank reading recorded" '[ "$(jq -s -r ".[0].bank_5h_before" "$R")" = 10.0 ]'
check "peek at hidden tests flagged" '[ "$(jq -s ".[0].peeked" "$R")" = true ]'
check "scope ok" '[ "$(jq -s "map(select(.scope_ok)) | length" "$R")" = 2 ]'
check "judge scores recorded" '[ "$(jq -s ".[0].judge.correctness" "$R")" = 4 ]'
check "judge packet hides the model" '[ -s "$TMP/fake.log.judge" ] && ! grep -qi "haiku" "$TMP/fake.log.judge"'
check "judge packet hides the lane" '[ -s "$TMP/fake.log.judge" ] && ! grep -qi "openrouter" "$TMP/fake.log.judge"'
check "judge packet carries the diff" 'grep -q "semver-cmp" "$TMP/fake.log.judge"'
check "agent call declares a permission mode" 'grep -q -- "--permission-mode auto" "$TMP/fake.log"'
check "worktrees removed" '[ -z "$(ls -A "$TMP/work" 2>/dev/null)" ]'

echo "3. guards"
bash "$RUN" run --lane native --model m --max-usd 0.6 --no-judge --out "$TMP/out2" >"$TMP/run2.log" 2>&1
check "budget cap stops the sweep after the cap is reached" '[ "$(wc -l <"$TMP/out2/runs.jsonl" | tr -d " ")" = 2 ]'
check "budget stop is reported" 'grep -q "budget" "$TMP/run2.log"'
: >"$TMP/fake.log"
LQ_FAKE_TOKEN=SKIPPED-BANK bash "$RUN" run --lane native --model m --no-judge --out "$TMP/out3" >"$TMP/run3.log" 2>&1
rc=$?
check "bank refusal exits non-zero" '[ "$rc" -ne 0 ]'
check "bank refusal launches nothing" '[ ! -s "$TMP/fake.log" ]'
for lane in openrouter deepseek claudex; do
  bash "$RUN" run --lane "$lane" --model m --out "$TMP/out-$lane" >"$TMP/run-$lane.log" 2>&1
  rc=$?
  check "$lane lane refused in phase 1 (exit 3)" '[ "$rc" -eq 3 ]'
done
check "refused lanes launch nothing" '[ ! -s "$TMP/fake.log" ]'

echo "4. table"
bash "$RUN" table "$TMP/out1" >"$TMP/table.md" 2>&1
check "table has a row per task" '[ "$(grep -c "| native | claude-haiku-4-5 |" "$TMP/table.md")" -ge 2 ]'
check "table has a header" 'grep -q "^| lane | model | task |" "$TMP/table.md"'

echo "test-lane-quality: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
