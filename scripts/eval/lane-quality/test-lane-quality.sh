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
export HIMMEL_EVAL_RUNS_LEDGER="$TMP/eval-runs.jsonl"   # HIMMEL-4647: never the live ledger
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
  [ -z "${LQ_FAKE_JUDGE_HANG:-}" ] || sleep 10
  echo '{"type":"result","is_error":false,"total_cost_usd":0.02,"structured_output":{"correctness":4,"scope_discipline":4,"test_quality":4,"honesty":4,"notes":"n"}}'
  exit 0 ;;
esac
prompt="$2"
case "$prompt" in
  *semver-cmp*) t=shell-red-green ;; *log-tail*) t=doc-plus-code ;;
  *block-curl-pipe*) t=hook-refusal ;; *) t=finding-verify ;;
esac
bash "$LQ_FAKE_RUN" materialize "$t" "$PWD" --reference >/dev/null
# Misbehaviour knobs: a candidate that hangs, a commit outside lq-work/, and a
# bank that runs dry during the agent call.
[ -z "${LQ_FAKE_HANG:-}" ] || printf '#!/usr/bin/env bash\nsleep 10\n' >lq-work/semver-cmp.sh
if [ -n "${LQ_FAKE_COMMIT:-}" ]; then
  echo x >stray.txt
  git add stray.txt lq-work && git -c user.name=t -c user.email=t@t commit -qm stray --no-verify
fi
[ -z "${LQ_FAKE_DRAIN:-}" ] || echo SKIPPED-BANK >"$LQ_FAKE_DRAIN"
[ -z "${LQ_FAKE_NOJSON:-}" ] || exit 124
sid="sess-$t"
{
  echo '{"type":"assistant","message":{"id":"m1","content":[{"type":"tool_use","id":"tu1","name":"Read","input":{"file_path":"lq-work/x"}}]}}'
  echo '{"type":"assistant","message":{"id":"m2","content":[{"type":"tool_use","id":"tu2","name":"Bash","input":{"command":"cat scripts/eval/lane-quality/tasks/x"}}]}}'
  echo '{"type":"assistant","message":{"id":"m2","content":[{"type":"tool_use","id":"tu2","name":"Bash","input":{"command":"cat scripts/eval/lane-quality/tasks/x"}}]}}'
  echo '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu2","is_error":true,"content":"PreToolUse:Bash hook error: refusing"}]}}'
  echo '{"type":"system","subtype":"compact_boundary"}'
} >"$LQ_TRANSCRIPTS/p/$sid.jsonl"
jq -cn --arg s "$sid" --argjson mu "${LQ_FAKE_MU:-null}" '{type:"result",subtype:"success",is_error:false,session_id:$s,total_cost_usd:0.5,num_turns:3,duration_ms:1000,permission_denials:[{tool_name:"Bash"}],result:"Done by claude-haiku-4-5 via openrouter on the native lane; tests pass."} + (if $mu == null then {} else {modelUsage: $mu} end) + (if $ENV.LQ_FAKE_NOCOST then {total_cost_usd: null} else {} end)'
FAKE
chmod +x "$TMP/bin/claude"
# LQ_FAKE_PROCEED_N=<n>: only the first n calls PROCEED (counted in LQ_FAKE_CALLS).
cat >"$TMP/bin/preflight" <<'FAKE'
#!/usr/bin/env bash
echo "bank-preflight: five_hour=${LQ_FAKE_5H:-10.0} seven_day=3.0" >&2
if [ -n "${LQ_FAKE_PROCEED_N:-}" ]; then
  echo x >>"$LQ_FAKE_CALLS"
  [ "$(wc -l <"$LQ_FAKE_CALLS")" -le "$LQ_FAKE_PROCEED_N" ] || { echo SKIPPED-BANK; exit 0; }
fi
cat "${LQ_FAKE_DRAIN:-/nonexistent}" 2>/dev/null || echo "${LQ_FAKE_TOKEN:-PROCEED}"
FAKE
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
check "judge packet hides the native lane" '[ -s "$TMP/fake.log.judge" ] && ! grep -qiw "native" "$TMP/fake.log.judge"'
check "judge packet carries the diff" 'grep -q "semver-cmp" "$TMP/fake.log.judge"'
check "agent call declares a permission mode" 'grep -q -- "--permission-mode auto" "$TMP/fake.log"'
check "worktrees removed" '[ -z "$(ls -A "$TMP/work" 2>/dev/null)" ]'
check "judge cost counts toward the budget" 'grep -q "spent 1.0400 USD" "$TMP/run1.log"'
check "judge call is budget-capped" 'grep -- "--json-schema" "$TMP/fake.log" | grep -q -- "--max-budget-usd"'
check "judge packet hides the model version" '! grep -q "4-5" "$TMP/fake.log.judge"'
EL="$HIMMEL_EVAL_RUNS_LEDGER"
check "sweep appends one eval-runs row" '[ "$(jq -s "map(select(.artifact | contains(\"/out1/\"))) | length" "$EL")" = 1 ]'
check "eval-runs row is a valid lane-quality row (n=2, ok)" '[ "$(jq -s -r "map(select(.artifact | contains(\"/out1/\")))[0] | \"\(.eval) \(.n) \(.status) \(.metrics.accept_ok_rate == 1)\"" "$EL")" = "lane-quality 2 ok true" ] && python3 "$HERE/../lib/eval_runs.py" validate "$EL" >/dev/null'
check "a clean agent result keeps is_error false" '[ "$(jq -s ".[0].is_error" "$R")" = false ]'

echo "3. guards"
bash "$RUN" run --lane native --model m --max-usd 0.6 --no-judge --out "$TMP/out2" >"$TMP/run2.log" 2>&1
check "budget cap stops the sweep after the cap is reached" '[ "$(wc -l <"$TMP/out2/runs.jsonl" | tr -d " ")" = 2 ]'
check "budget stop is reported" 'grep -q "budget" "$TMP/run2.log"'
: >"$TMP/fake.log"
LQ_FAKE_TOKEN=SKIPPED-BANK bash "$RUN" run --lane native --model m --no-judge --out "$TMP/out3" >"$TMP/run3.log" 2>&1
rc=$?
check "bank refusal exits non-zero" '[ "$rc" -ne 0 ]'
check "bank refusal launches nothing" '[ ! -s "$TMP/fake.log" ]'
for lane in deepseek claudex; do
  bash "$RUN" run --lane "$lane" --model m --out "$TMP/out-$lane" >"$TMP/run-$lane.log" 2>&1
  rc=$?
  check "$lane lane refused (exit 3)" '[ "$rc" -eq 3 ]'
done
check "refused lanes launch nothing" '[ ! -s "$TMP/fake.log" ]'

# HIMMEL-4459: exported exit/return/unset shadows must never reach the agent or
# judge launch. The control (no ambient proxy) proves the shadowed runner still
# launches, so the proxied run staying empty is not vacuous.
shadow_lq() { # <proxy-url|-> <outdir>
  : >"$TMP/fake.log"
  # shellcheck disable=SC2016
  bash -c '
    exit() { :; }; return() { :; }; unset() { :; }; export -f exit return unset
    [ "$1" = - ] && p=() || p=(ANTHROPIC_BASE_URL="$1")
    exec env "${p[@]}" bash "$2" run --lane native --model m --tasks shell-red-green --out "$3"' _ "$1" "$RUN" "$2" >"$TMP/shadow.log" 2>&1
}
shadow_lq - "$TMP/out-shadow-ctl"
check "shadowed exit/return/unset, no proxy: the runner still launches (control)" '[ -s "$TMP/fake.log" ]'
shadow_lq http://evil.invalid "$TMP/out-shadow-px"
check "shadowed exit/return/unset + ambient ANTHROPIC_BASE_URL: nothing is launched" '[ ! -s "$TMP/fake.log" ]'

# openrouter (phase 2): the agent goes through the lane launcher, the judge
# stays native, and the metered balance is read before and after each task.
printf '#!/usr/bin/env bash\necho "$*" >>"$LQ_FAKE_LOG.launcher"\nexec "$LQ_CLAUDE_BIN" "$@"\n' >"$TMP/bin/claude-openrouter"
printf '#!/usr/bin/env bash\necho "balance=8.9070935:credit spend=?"\n' >"$TMP/bin/orcost"
chmod +x "$TMP/bin/claude-openrouter" "$TMP/bin/orcost"
: >"$TMP/fake.log.launcher"
# Claude Code misprices an unrecognized gateway slug, so the harness reprices
# modelUsage at list rates: 50k in, 4k out, 16k cache-write, 100k cache-read
# at Haiku 4.5 rates is 0.10 USD (0.12 with the 1.2 metered markup), against
# a reported 0.50.
MU_HAIKU='{"anthropic/claude-haiku-4.5":{"inputTokens":50000,"outputTokens":4000,"cacheCreationInputTokens":16000,"cacheReadInputTokens":100000}}'
LQ_FAKE_MU="$MU_HAIKU" LQ_LANE_BIN="$TMP/bin/claude-openrouter" LQ_METERED_PROBE="$TMP/bin/orcost" bash "$RUN" run --lane openrouter \
  --model haiku --tasks shell-red-green --max-usd 2 --out "$TMP/out15" >"$TMP/run15.log" 2>&1
rc=$?
check "openrouter lane runs" '[ "$rc" -eq 0 ] && [ "$(wc -l <"$TMP/out15/runs.jsonl" | tr -d " ")" = 1 ]'
check "openrouter agent goes through the lane launcher" 'grep -q -- "--permission-mode auto" "$TMP/fake.log.launcher"'
check "openrouter judge stays native" '! grep -q -- "--json-schema" "$TMP/fake.log.launcher" && [ "$(jq -s ".[0].judge.correctness" "$TMP/out15/runs.jsonl")" = 4 ]'
check "metered balance recorded" '[ "$(jq -s -r ".[0].metered_before" "$TMP/out15/runs.jsonl")" = 8.9070935 ]'
check "native rows carry no metered balance" '[ "$(jq -s ".[0].metered_before" "$R")" = null ]'
check "openrouter cost repriced from modelUsage" 'jq -s ".[0].cost_usd" "$TMP/out15/runs.jsonl" | awk "{exit !(\$1 > 0.1199 && \$1 < 0.1201)}" && [ "$(jq -s ".[0].reported_cost_usd" "$TMP/out15/runs.jsonl")" = 0.5 ]'
check "openrouter outer budget scaled by a logged factor" 'grep -q -- "--max-budget-usd 8.00" "$TMP/fake.log.launcher" && grep -q "budget factor 4" "$TMP/run15.log"'
: >"$TMP/fake.log.launcher"
LQ_LANE_BIN="$TMP/bin/claude-openrouter" LQ_METERED_PROBE="$TMP/bin/orcost" bash "$RUN" run --lane openrouter \
  --model sonnet --tasks shell-red-green --out "$TMP/out17" >"$TMP/run17.log" 2>&1
check "openrouter refuses an unpriced model before launch" 'grep -q "haiku only" "$TMP/run17.log" && [ ! -s "$TMP/fake.log.launcher" ]'
LQ_FAKE_MU='{"x/unpriced":{"inputTokens":1,"outputTokens":1,"cacheCreationInputTokens":0,"cacheReadInputTokens":0}}' \
  LQ_LANE_BIN="$TMP/bin/claude-openrouter" LQ_METERED_PROBE="$TMP/bin/orcost" bash "$RUN" run --lane openrouter \
  --model haiku --tasks shell-red-green,finding-verify --max-usd 2 --out "$TMP/out16" >"$TMP/run16.log" 2>&1
check "an unpriced openrouter model stops the sweep" '[ "$(wc -l <"$TMP/out16/runs.jsonl" | tr -d " ")" = 1 ] && grep -q "cost unknown" "$TMP/run16.log"'
check "a stopped sweep records a partial eval-runs row" '[ "$(jq -s -r "map(select(.artifact | contains(\"/out16/\")))[0].status" "$HIMMEL_EVAL_RUNS_LEDGER")" = partial ]'
# 25k input tokens is 0.025 USD at list, so a reported 0.50 is 20x, not the 5x
# the per-call factor relies on: the cost is unknown and the sweep stops.
LQ_FAKE_MU='{"anthropic/claude-haiku-4.5":{"inputTokens":25000,"outputTokens":0,"cacheCreationInputTokens":0,"cacheReadInputTokens":0}}' \
  LQ_LANE_BIN="$TMP/bin/claude-openrouter" LQ_METERED_PROBE="$TMP/bin/orcost" bash "$RUN" run --lane openrouter \
  --model haiku --tasks shell-red-green,finding-verify --max-usd 2 --out "$TMP/out18" >"$TMP/run18.log" 2>&1
check "an off-ratio reported cost stops the openrouter sweep" '[ "$(wc -l <"$TMP/out18/runs.jsonl" | tr -d " ")" = 1 ] && grep -q "cost unknown" "$TMP/run18.log"'
# Zero priced tokens or no reported cost leaves the 5x ratio unchecked, so the
# cost is unknown and the sweep stops.
LQ_FAKE_MU='{"anthropic/claude-haiku-4.5":{"inputTokens":0,"outputTokens":0,"cacheCreationInputTokens":0,"cacheReadInputTokens":0}}' \
  LQ_LANE_BIN="$TMP/bin/claude-openrouter" LQ_METERED_PROBE="$TMP/bin/orcost" bash "$RUN" run --lane openrouter \
  --model haiku --tasks shell-red-green,finding-verify --max-usd 2 --out "$TMP/out19" >"$TMP/run19.log" 2>&1
check "a zero-token openrouter run stops the sweep" '[ "$(wc -l <"$TMP/out19/runs.jsonl" | tr -d " ")" = 1 ] && grep -q "cost unknown" "$TMP/run19.log"'
LQ_FAKE_NOCOST=1 LQ_FAKE_MU='{"anthropic/claude-haiku-4.5":{"inputTokens":25000,"outputTokens":4000,"cacheCreationInputTokens":0,"cacheReadInputTokens":0}}' \
  LQ_LANE_BIN="$TMP/bin/claude-openrouter" LQ_METERED_PROBE="$TMP/bin/orcost" bash "$RUN" run --lane openrouter \
  --model haiku --tasks shell-red-green,finding-verify --max-usd 2 --out "$TMP/out20" >"$TMP/run20.log" 2>&1
check "a missing reported cost stops the openrouter sweep" '[ "$(wc -l <"$TMP/out20/runs.jsonl" | tr -d " ")" = 1 ] && grep -q "cost unknown" "$TMP/run20.log"'
: >"$TMP/fake.log"
LQ_FAKE_PROCEED_N=1 LQ_FAKE_CALLS="$TMP/calls" bash "$RUN" run --lane native --model m --tasks shell-red-green \
  --no-judge --out "$TMP/out14" >"$TMP/run14.log" 2>&1
rc=$?
check "a bank refusal during task setup launches no agent" '[ "$rc" -eq 75 ] && [ ! -s "$TMP/fake.log" ]'

start=$(date +%s)
LQ_FAKE_HANG=1 LQ_FAKE_COMMIT=1 bash "$RUN" run --lane native --model m --tasks shell-red-green --timeout 3 \
  --no-judge --out "$TMP/out4" >"$TMP/run4.log" 2>&1
took=$(( $(date +%s) - start ))
R4="$TMP/out4/runs.jsonl"
check "a hanging candidate is cut off by the timeout" '[ "$took" -lt 25 ]'
check "a killed acceptance run still records its row" '[ "$(wc -l <"$R4" 2>/dev/null | tr -d " ")" = 1 ]'
check "a killed acceptance run is not ok" '[ "$(jq -s ".[0].accept_ok" "$R4")" = false ]'
check "a committed out-of-scope file is caught" '[ "$(jq -s -r ".[0].out_of_scope[0]" "$R4")" = stray.txt ]'

: >"$TMP/fake.log.judge"
LQ_FAKE_DRAIN="$TMP/drain" bash "$RUN" run --lane native --model m --tasks shell-red-green,finding-verify \
  --out "$TMP/out5" >"$TMP/run5.log" 2>&1
rc=$?
check "a bank drained mid-task skips the judge" '[ ! -s "$TMP/fake.log.judge" ] && [ "$(jq -s ".[0].judge" "$TMP/out5/runs.jsonl")" = null ]'
check "a bank drained mid-task stops the sweep" '[ "$rc" -eq 75 ] && [ "$(wc -l <"$TMP/out5/runs.jsonl" | tr -d " ")" = 1 ]'

: >"$TMP/blocked"
LQ_WORK_ROOT="$TMP/blocked" bash "$RUN" run --lane native --model m --tasks shell-red-green --no-judge \
  --out "$TMP/out6" >"$TMP/run6.log" 2>&1
rc=$?
check "a failed worktree add fails the sweep" '[ "$rc" -ne 0 ] && ! grep -q "lane-quality: done" "$TMP/run6.log"'

RO="$TMP/ro"
git init -q "$RO" && git -C "$RO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
chmod -R a-w "$RO/.git/objects"
bash "$RUN" materialize finding-verify "$RO" >"$TMP/mat.log" 2>&1
rc=$?
chmod -R u+w "$RO/.git/objects"
check "a fixture that cannot be committed fails materialize" '[ "$rc" -ne 0 ]'

: >"$TMP/fake.log.judge"
bash "$RUN" run --lane native --model m --tasks shell-red-green --max-usd 0.5 --out "$TMP/out7" >"$TMP/run7.log" 2>&1
check "no judge call once the agent spent the whole budget" '[ ! -s "$TMP/fake.log.judge" ] && [ "$(jq -s ".[0].judge" "$TMP/out7/runs.jsonl")" = null ]'

start=$(date +%s)
LQ_FAKE_JUDGE_HANG=1 bash "$RUN" run --lane native --model m --tasks shell-red-green,finding-verify --timeout 3 \
  --out "$TMP/out8" >"$TMP/run8.log" 2>&1
took=$(( $(date +%s) - start ))
check "a hanging judge is cut off by the timeout" '[ "$took" -lt 9 ] && [ "$(wc -l <"$TMP/out8/runs.jsonl" | tr -d " ")" = 1 ]'
check "a judge of unknown cost stops the sweep" 'grep -q "cost unknown" "$TMP/run8.log"'

(cd "$TMP" && bash "$RUN" run --lane native --model m --tasks shell-red-green --out out10) >"$TMP/run10.log" 2>&1
check "a relative --out still reaches the judge" '[ "$(jq -s ".[0].judge.correctness" "$TMP/out10/runs.jsonl")" = 4 ]'

LQ_FAKE_NOJSON=1 bash "$RUN" run --lane native --model m --tasks shell-red-green,finding-verify --no-judge \
  --out "$TMP/out9" >"$TMP/run9.log" 2>&1
check "an agent run of unknown cost stops the sweep" '[ "$(wc -l <"$TMP/out9/runs.jsonl" | tr -d " ")" = 1 ] && grep -q "cost unknown" "$TMP/run9.log"'
: >"$TMP/fake.log.judge"
LQ_FAKE_NOJSON=1 bash "$RUN" run --lane native --model m --tasks shell-red-green --out "$TMP/out11" >"$TMP/run11.log" 2>&1
check "no judge call after an agent run of unknown cost" '[ ! -s "$TMP/fake.log.judge" ] && [ "$(jq -s ".[0].judge" "$TMP/out11/runs.jsonl")" = null ]'

if bash "$RUN" run --lane native --model m --tasks shell-red-green --no-judge --timeout 0 --out "$TMP/out12" >"$TMP/run12.log" 2>&1; then
  bad "--timeout 0 is refused"
else check "--timeout 0 is refused" '[ ! -s "$TMP/out12/runs.jsonl" ]'; fi

mkdir -p "$TMP/out13/runs.jsonl"
if bash "$RUN" run --lane native --model m --tasks shell-red-green --no-judge --out "$TMP/out13" >"$TMP/run13.log" 2>&1; then
  bad "an unrecordable row fails the sweep"
else ok "an unrecordable row fails the sweep"; fi

echo "4. table"
bash "$RUN" table "$TMP/out1" >"$TMP/table.md" 2>&1
check "table has a row per task" '[ "$(grep -c "| native | claude-haiku-4-5 |" "$TMP/table.md")" -ge 2 ]'
check "table has a header" 'grep -q "^| lane | model | task |" "$TMP/table.md"'

echo "5. repeats, bootstrap CIs and judge calibration (HIMMEL-4648)"
: >"$TMP/fake.log.judge"
bash "$RUN" run --lane native --model m --tasks shell-red-green,finding-verify --reps 2 --max-usd 9 \
  --out "$TMP/out21" >"$TMP/run21.log" 2>&1
rc=$?
R21="$TMP/out21/runs.jsonl"
check "--reps 2 runs every task twice" '[ "$rc" -eq 0 ] && [ "$(jq -s -r "map(\"\(.task):\(.rep)\") | sort | join(\",\")" "$R21")" = "finding-verify:1,finding-verify:2,shell-red-green:1,shell-red-green:2" ]'
check "a repeat keeps its own judge packet" '[ -s "$TMP/out21/shell-red-green.judge-packet.md" ] && [ -s "$TMP/out21/shell-red-green.r2.judge-packet.md" ]'
check "rows record the judge model" '[ "$(jq -s -r ".[0].judge_model" "$R21")" = opus ]'
L21="$(jq -sc "map(select(.artifact | contains(\"/out21/\")))[0]" "$EL")"
check "the ledger row carries reps 2 and n = distinct tasks" '[ "$(jq -r "\"\(.reps) \(.n) \(.config.tasks | length)\"" <<<"$L21")" = "2 2 2" ]'
check "the ledger row carries a bootstrap 95% CI per task and criterion" 'jq -e ".ci_level == 0.95 and .ci_method == \"bootstrap-percentile\" and .ci[\"shell-red-green.judge_correctness\"].lo == 4 and .ci.judge_correctness.hi == 4" <<<"$L21" >/dev/null'
check "a ledger row with reps validates" 'python3 "$HERE/../lib/eval_runs.py" validate "$EL" >/dev/null'
for v in 0 x; do
  if bash "$RUN" run --lane native --model m --tasks shell-red-green --reps "$v" --out "$TMP/out-reps-$v" >/dev/null 2>&1; then
    bad "--reps $v is refused"
  else ok "--reps $v is refused"; fi
done

# Fixture rows, no model call: task a passes twice (judge 4 then 5), task b
# fails three times (judge 2, 4, and one row with no judge score).
FX="$TMP/fx1"; mkdir -p "$FX"
fxrow() { # task rep accept_ok correctness|null
  jq -nc --arg t "$1" --argjson r "$2" --argjson ok "$3" --argjson c "$4" '{run_id:"fx", lane:"native", model:"m", effort:"", task:$t, rep:$r,
    base_sha:"b", accept_passed:(if $ok then 1 else 0 end), accept_total:1, accept_ok:$ok, scope_ok:true, judge_model:"opus",
    judge:(if $c == null then null else {correctness:$c, scope_discipline:4, test_quality:3, honesty:4, notes:"n"} end)}'
}
{ fxrow a 1 true 4; fxrow a 2 true 5; fxrow b 1 false 2; fxrow b 2 false 4; fxrow b 3 false null; } >"$FX/runs.jsonl"
for s in a a.r2 b b.r2; do echo "packet $s" >"$FX/$s.judge-packet.md"; done

bash "$RUN" table "$FX" >"$TMP/table-fx.md" 2>&1
check "table reports mean and bootstrap 95% CI per task and criterion" 'grep -E "^\| native \| m \| a \| 2 \|" "$TMP/table-fx.md" | grep -q "4.50 \[4.00, 5.00\]"'
check "a constant criterion has a zero-width CI" 'grep -E "^\| native \| m \| a \| 2 \|" "$TMP/table-fx.md" | grep -q "4.00 \[4.00, 4.00\]"'
check "a missing judge score is counted, not dropped" 'grep -E "^\| native \| m \| b \| 3 \|" "$TMP/table-fx.md" | grep -q "3.00 \[2.00, 4.00\]" && grep -E "^\| native \| m \| b \| 3 \|" "$TMP/table-fx.md" | grep -qE "\| 1 \|$"'

python3 "$HERE/../lib/eval_runs.py" lane-quality "$FX" --run-id fx --ledger "$TMP/fx-ledger.jsonl" >/dev/null 2>&1
FXL="$TMP/fx-ledger.jsonl"
check "fixture ledger row: per-task CI and missing count" 'jq -e ".ci[\"a.judge_correctness\"] == {lo: 4, hi: 5} and .metrics[\"b.judge_missing\"] == 1 and .metrics.judge_missing == 1 and .reps == 3 and .n == 2" "$FXL" >/dev/null'
check "fixture ledger cases are per-task means" '[ "$(jq -r ".cases.a.judge_correctness" "$FXL")" = 4.5 ]'

# Calibration math, by hand: correctness on accept-pass {4,5} vs accept-fail
# {2,4} -> AUC 3.5/4 = 0.875; point-biserial r = 1.5 / sqrt(4.75) = 0.6882.
bash "$RUN" calibration "$FX" --json --no-ledger >"$TMP/cal.json" 2>"$TMP/cal.err"
check "calibration: AUC of correctness against accept_ok" 'jq -e ".metrics.auc_correctness == 0.875" "$TMP/cal.json" >/dev/null'
check "calibration: point-biserial of correctness against accept_ok" 'jq ".metrics.pb_correctness" "$TMP/cal.json" | awk "{v = \$1} END {exit !(NR == 1 && v > 0.6882 && v < 0.6883)}"'
check "calibration counts the row with no judge score" 'jq -e ".metrics.judge_missing == 1 and .n == 4" "$TMP/cal.json" >/dev/null'
check "calibration without a second judge reports no kappa" 'jq -e ".metrics | has(\"kappa_correctness\") and .kappa_correctness == null" "$TMP/cal.json" >/dev/null'
check "the calibration report prints its table" 'bash "$RUN" calibration "$FX" --no-ledger 2>/dev/null | grep -qF "| correctness | 0.875 ["'
check "one judge score beside a missing one gets no CI" 'python3 -c "import sys; sys.path.insert(0, sys.argv[1]); import eval_runs as e; s = e.lane_quality_stats([{\"task\": \"x\", \"judge\": {\"correctness\": 3}}, {\"task\": \"x\"}])[\"x\"]; sys.exit(not (s[\"judge_correctness\"][\"ci\"] is None and s[\"judge_missing\"] == 1))" "$HERE/../lib"'
check "a calibration with only one class reports no AUC" 'jq -c "select(.accept_ok)" "$FX/runs.jsonl" >"$TMP/one.jsonl" && mkdir -p "$TMP/fx-one" && mv "$TMP/one.jsonl" "$TMP/fx-one/runs.jsonl" && bash "$RUN" calibration "$TMP/fx-one" --json --no-ledger | jq -e ".metrics.auc_correctness == null" >/dev/null'

# Weighted kappa (quadratic) by hand: identical raters 1, independent 0,
# reversed extremes -1.
kap() { python3 -c 'import sys,json; sys.path.insert(0, sys.argv[1]); import lq_stats; print(lq_stats.weighted_kappa(json.loads(sys.argv[2]), json.loads(sys.argv[3])))' "$HERE" "$1" "$2"; }
check "weighted kappa: identical raters = 1" '[ "$(kap "[1,2,3,4,5]" "[1,2,3,4,5]")" = 1.0 ]'
check "weighted kappa: independent raters = 0" '[ "$(kap "[1,1,2,2]" "[1,2,1,2]")" = 0.0 ]'
check "weighted kappa: reversed extremes = -1" '[ "$(kap "[1,5]" "[5,1]")" = -1.0 ]'

: >"$TMP/fake.log"; : >"$TMP/fake.log.judge"
bash "$RUN" calibration "$FX" --judge2-model sonnet --judge2-effort low --json --max-usd 1 >"$TMP/cal2.json" 2>"$TMP/cal2.err"
rc=$?
check "second-judge pass judges every stored packet once" '[ "$rc" -eq 0 ] && [ "$(grep -c -- "--json-schema" "$TMP/fake.log")" = 4 ]'
check "second judge uses the given model and effort, budget-capped, no tools" 'grep -- "--json-schema" "$TMP/fake.log" | grep -- "--model sonnet" | grep -- "--effort low" | grep -q -- "--max-budget-usd"'
check "second judge rescores the stored packet" 'grep -q "packet a.r2" "$TMP/fake.log.judge"'
check "second judge result stored per row" '[ -s "$FX/a.r2.judge2.sonnet-low.json" ]'
check "weighted kappa against a constant second judge is 0" 'jq -e ".metrics.kappa_correctness == 0 and .metrics.n_kappa == 4" "$TMP/cal2.json" >/dev/null'
check "calibration writes a valid eval-runs row" '[ "$(jq -s -r "map(select(.eval == \"lane-quality-calibration\")) | length" "$EL")" = 1 ] && python3 "$HERE/../lib/eval_runs.py" validate "$EL" >/dev/null'
: >"$TMP/fake.log"
bash "$RUN" calibration "$FX" --judge2-model sonnet --judge2-effort low --json --no-ledger >"$TMP/cal3.json" 2>/dev/null
check "a stored second-judge result is reused, never re-judged" '! grep -q -- "--json-schema" "$TMP/fake.log" && jq -e ".metrics.n_kappa == 4" "$TMP/cal3.json" >/dev/null'
: >"$FX/a.r2.judge2.sonnet-low.json"; : >"$TMP/fake.log"
bash "$RUN" calibration "$FX" --judge2-model sonnet --judge2-effort low --json --no-ledger >/dev/null 2>&1
check "an empty second-judge result is judged again" '[ "$(grep -c -- "--json-schema" "$TMP/fake.log")" = 1 ] && [ -s "$FX/a.r2.judge2.sonnet-low.json" ]'
: >"$TMP/fake.log"
LQ_FAKE_TOKEN=SKIPPED-BANK bash "$RUN" calibration "$FX" --judge2-model haiku --json --no-ledger >/dev/null 2>&1
rc=$?
check "a bank refusal stops the second-judge pass before any call" '[ "$rc" -eq 75 ] && [ ! -s "$TMP/fake.log" ]'
mkdir -p "$TMP/rel/fxr" && cp "$FX/runs.jsonl" "$FX"/*.judge-packet.md "$TMP/rel/fxr/"
: >"$TMP/fake.log.judge"
(cd "$TMP/rel" && bash "$RUN" calibration fxr --judge2-model haiku --json --no-ledger >/dev/null 2>&1)
rc=$?
check "a relative run dir still feeds the second judge its packet" '[ "$rc" -eq 0 ] && grep -q "packet b.r2" "$TMP/fake.log.judge"'
check "weighted kappa ignores a pair off the 1..5 scale" '[ "$(kap "[1,2,6]" "[1,2,3]")" = 1.0 ]'

echo "test-lane-quality: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
