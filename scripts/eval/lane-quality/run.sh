#!/usr/bin/env bash
# scripts/eval/lane-quality/run.sh - lane-quality eval (HIMMEL-4090).
#
# Runs the same frozen task set against one lane and model, and records per
# task: the hidden acceptance result, a blind judge score, wall time, tool
# calls, compactions, cost, the bank reading before and after, and guardrail
# friction. A new model is one more `run`; `table` turns runs into rows.
#
# Usage:
#   run.sh list
#   run.sh run --lane native|openrouter|api --model <model> [--tasks a,b] [--effort <level>]
#              [--reps <n>] [--max-usd <usd>] [--timeout <sec>] [--judge-model <model>]
#              [--no-judge] [--keep] [--out <dir>] [--config <file>] [--dry-run]
#   run.sh table <run-dir>...
#   run.sh calibration <run-dir>... [--judge2-model <model>] [--judge2-effort <level>]
#              [--max-usd <usd>] [--timeout <sec>] [--json] [--no-ledger]
#   run.sh materialize <task> <dir> [--reference]   (used by the suite)
#
# Repeats (HIMMEL-4648): --reps N runs the task set N times, repeat by repeat,
# into one run dir; a repeat's files carry a .r<n> suffix from the second on.
# `table` then adds the mean and a bootstrap 95% CI per task and criterion,
# and counts the rows with no judge score instead of dropping them.
# `calibration` (lq_stats.py) scores the judge against the hidden acceptance
# (AUC and point-biserial of each criterion against accept_ok) and, with
# --judge2-model, re-judges every stored judge packet once with a second
# model or effort and reports quadratic weighted kappa per criterion. Stored
# second-judge results are reused, so a rerun makes no call.
#
# Each task runs in a fresh detached worktree at the pinned BASE_SHA, plus
# the task's fixture/ committed on top (a fixed author and date, so the
# fixture commit is reproducible). The agent sees only tasks/<id>/prompt.md;
# accept.sh and reference/ stay outside its worktree. The judge sees the task,
# the diff and the agent's final report with every model and lane name
# redacted, and never the acceptance result: the two signals stay independent.
#
# Lanes: `native` and `openrouter` (phase 2, operator-approved). An openrouter
# agent runs through scripts/claude-openrouter (its egress, PHI and credit
# gates apply), and its metered balance is read before and after each task;
# the judge always runs native. deepseek and claudex exit 3 until the
# operator opts in (deepseek needs a station opt-in in the launching shell).
# ponytail: OpenRouter credit metadata lags, so a per-task balance delta can
# under-report; read the sweep's account delta again later for the total.
# Upgrade path: per-generation cost from OpenRouter's generation API.
#
# Budget: --max-usd (default 3) caps the sweep. The agent's reported
# total_cost_usd is summed after each task; no further task starts once the
# sum reaches the cap, and each agent call gets the remainder as
# --max-budget-usd. On a subscription lane that figure is the API-price
# equivalent, not money spent; the bank reading is the subscription cost.
#
# The api lane (HIMMEL-4986): the agent runs through scripts/api-lane/claude-api.sh
# on the API credit of HIMMEL_API_ACCOUNT, never on subscription auth. It needs
# HIMMEL_API_LANE=on, HIMMEL_API_ACCOUNT, HIMMEL_API_KEY_ID and ANTHROPIC_API_KEY
# in the environment, --no-judge (the judge is native, so it would draw the
# subscription bank), and --max-usd of at most API_PILOT_CAP (default and ceiling
# $1, enforced here; the launcher also reserves each call's budget in its ledger).
# The native bank is read for the record but never gates an api run. --dry-run
# checks all of that and prints the plan and the command, spending nothing.
#
# Output: <out>/runs.jsonl (one JSON row per task) plus per-task logs, under
# ~/.himmel/eval/lane-quality/<run-id>/ by default.
#
# Test seams (env): LQ_CLAUDE_BIN, LQ_PREFLIGHT, LQ_REPO, LQ_BASE_SHA,
# LQ_WORK_ROOT, LQ_TRANSCRIPTS, LQ_LANE_BIN, LQ_METERED_PROBE.
#
# ponytail: the bank reading is the account-wide five-hour percent, so any
# other session running during a task lands in its delta; run a sweep on a
# quiet fleet, or read the delta as an upper bound. Upgrade path: per-session
# usage from the transcript once a lane exposes it (HIMMEL-4090 phase 2).
# ponytail: a single headless run cannot hand off, so `handoffs` is not
# recorded; compactions are. Upgrade path: drive a lane through its leg
# launcher when phase 2 measures leg churn (HIMMEL-4089).
# ponytail: the hidden tests live in the repo, so an agent on a later checkout
# could read them; the runner flags a transcript that touches this directory
# (`peeked`) instead of preventing it. Upgrade path: move the tasks to the
# state repo if a run is ever flagged.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
TASKS="$HERE/tasks"
die() { echo "lane-quality: $*" >&2; exit 64; }
usage() { sed -n '2,64p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 64; }
command -v jq >/dev/null 2>&1 || die "jq is required"

all_tasks() { for d in "$TASKS"/*/; do [ -f "$d/prompt.md" ] && basename "$d"; done; }

# materialize <task> <dir> [--reference]: copy the task's fixture (or its
# reference solution) into <dir>. The fixture is committed and its sha
# printed; a reference is copied only, with `.ref` suffixes dropped (stored
# that way so CI never discovers a reference test-*.sh as a suite).
materialize() {
  local task="$1" dir="$2" mode="${3:-}" src f
  [ -f "$TASKS/$task/prompt.md" ] || die "unknown task '$task'"
  if [ "$mode" = --reference ]; then
    src="$TASKS/$task/reference"
    [ -d "$src" ] || return 0
    cp -R "$src/." "$dir/" || die "cannot copy the $task reference"
    while IFS= read -r f; do mv "$f" "${f%.ref}" || die "cannot rename $f"; done < <(find "$dir/lq-work" -name '*.ref' 2>/dev/null)
    return 0
  fi
  src="$TASKS/$task/fixture"
  if [ -d "$src" ]; then
    cp -R "$src/." "$dir/" || die "cannot copy the $task fixture"
    git -C "$dir" add -A || die "cannot stage the $task fixture"
    GIT_AUTHOR_DATE='2026-01-01T00:00:00Z' GIT_COMMITTER_DATE='2026-01-01T00:00:00Z' \
      git -C "$dir" -c user.name=lane-quality -c user.email=lane-quality@invalid \
      -c commit.gpgsign=false commit -q --no-verify -m "lane-quality fixture: $task" || die "cannot commit the $task fixture"
  fi
  git -C "$dir" rev-parse HEAD
}

# Redact every model and lane name before the judge sees a byte.
redact() {
  sed -E 's/(anthropic|claude|opus|sonnet|haiku|fable|gpt[-_.a-z0-9]*|codex|claudex|openai|deepseek|openrouter|gemini|glm|kimi|qwen|llama|mistral)/[redacted]/Ig; s/\bnative\b/[redacted]/Ig;s/\[redacted\]([-_.]*[0-9][-_.0-9]*)?/[redacted]/g'
}

bank_read() { # prints "<token> <five_hour>"
  local out tok five
  out="$("$PREFLIGHT" 2>&1)"
  tok="$(printf '%s\n' "$out" | grep -Eo '^(PROCEED|SKIPPED-[A-Z]+|BANK-[A-Z]+)$' | tail -1)"
  five="$(printf '%s\n' "$out" | sed -n 's/.*five_hour=\([0-9.?]*\).*/\1/p' | tail -1)"
  echo "${tok:-BANK-UNKNOWN} ${five:-?}"
}

metered_read() { # prints the metered lane's balance in USD, "?" if unreadable, nothing on native
  [ -n "$METERED_PROBE" ] || return 0
  bash "$METERED_PROBE" --raw 2>/dev/null | sed -n 's/^balance=\([0-9.]*\):.*/\1/p' | grep . || echo '?'
}

# List prices in USD per million tokens: input, output, cache write, cache read.
# ponytail: Claude Code does not recognize the OpenRouter slug
# anthropic/claude-haiku-4.5 ([claude-code:unrecognized_model], costBasis
# unknown) and over-counts its total_cost_usd about 5x, so a metered lane is
# repriced here from modelUsage; an unpriced model leaves the cost unknown and
# stops the sweep. Upgrade path: drop this table once Claude Code prices the
# gateway slug (costBasis no longer "unknown"), or add a row per model adopted.
# The metered balance fell 12-16% more than list price in the first live
# sweeps, so the repriced cost carries a 1.2 markup to keep --max-usd a real cap.
# Claude Code's figure was exactly 5x list price on every live task, whatever
# the token mix. The per-call factor (BUDGET_FACTOR) relies on that ratio, so a
# run that reports any other ratio, no cost or no priced tokens leaves the cost
# unknown and stops the sweep.
PRICES='{"anthropic/claude-haiku-4.5":[1,5,1.25,0.1]}'
METERED_MARKUP=1.2
REPORTED_RATIO=5

agent_cost() { # $1 result json -> the agent's real cost in USD, or null
  if [ "$LANE" = native ] || [ "$LANE" = api ]; then jq -r '.total_cost_usd // null' "$1"; return; fi
  if [ "$LANE" = claudex ]; then jq -r '.total_cost_usd // 0' "$1"; return; fi
  jq -r --argjson p "$PRICES" --argjson mk "$METERED_MARKUP" --argjson rr "$REPORTED_RATIO" '
    .total_cost_usd as $rep
    | if (.modelUsage // {}) == {} then null
    else [.modelUsage | to_entries[] | $p[.key] as $r
          | if $r == null then null
            else ((.value.inputTokens // 0) * $r[0] + (.value.outputTokens // 0) * $r[1]
                  + (.value.cacheCreationInputTokens // 0) * $r[2] + (.value.cacheReadInputTokens // 0) * $r[3]) / 1000000
            end]
         | if any(. == null) then null
           else add as $list
             | if $list <= 0 or $rep == null or ($rep / $list - $rr | fabs) > 0.05 then null
               else $list * $mk end
           end
    end' "$1"
}

transcript_metrics() { # $1 = transcript or empty, $2 = final report file -> JSON object
  if [ -z "$1" ] || [ ! -r "$1" ]; then
    echo '{"tool_calls":null,"compactions":null,"hook_denials":null,"peeked":null,"red_before_green":null,"denial_recovery":null,"identical_denied_retries":null,"verify_before_claim":null}'; return
  fi
  local traj  # HIMMEL-4651 trajectory fields; a scorer failure leaves them null
  traj="$(python3 "$HERE/trajectory.py" score "$1" --report "$2" 2>/dev/null)" || traj=""
  jq -s -c --argjson traj "${traj:-null}" '
    (if $traj == null then {red_before_green: null, denial_recovery: null, identical_denied_retries: null, verify_before_claim: null} else $traj end) as $traj
    |
    def text: if type == "string" then . elif type == "array" then map(.text? // "") | join(" ") else "" end;
    [ .[] | select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") ] as $tu
    | { tool_calls: ($tu | map(.id) | unique | length),
        compactions: ([ .[] | select(.type == "system" and .subtype == "compact_boundary") ] | length),
        hook_denials: ([ .[] | select(.type == "user") | .message.content[]? | select(.type == "tool_result" and .is_error == true)
                         | select(.content | text | test("hook error|PreToolUse|refus|denied|blocked"; "i")) ] | length),
        peeked: ($tu | map(.input | tostring) | any(test("eval/lane-quality"))) } + $traj' "$1"
}

# judge_call <packet> <out json> <err file> <model> <budget> [effort]: one
# blind judge call on a stored packet; the result lands in <out json>.
judge_call() {
  local packet="$1" out="$2" err="$3" model="$4" budget="$5" effort="${6:-}" jdir rc
  jdir="$(mktemp -d "${TMPDIR:-/tmp}/lq-judge.XXXXXX")" || return 1
  (
    cd "$jdir" || exit 1
    # HIMMEL-4459: the pin's rc is advisory; the keyword-only LAUNCH GATE re-checks.
    native_auth_pin_env
    if [[ -z "${!ANTHROPIC_*}${!anthropic_*}${!CLAUDE_CODE_USE_*}${!claude_code_use_*}" ]]; then
      # headless-claude-ok: HIMMEL-4090 blind judge call (HIMMEL-4648 second judge too), bank-preflighted by its caller, no tools, explicit permission mode, budget-capped
      # launch-profile-ok: HIMMEL-4090 the judge runs with --tools "", so no tool profile applies
      timeout "$TIMEOUT" "$CLAUDE_BIN" -p --model "$model" ${effort:+--effort "$effort"} --permission-mode dontAsk --output-format json \
        --max-budget-usd "$budget" --no-session-persistence --json-schema "$(cat "$HERE/judge-schema.json")" --tools ""
    else
      exit 1
    fi
  ) <"$packet" >"$out" 2>"$err"  # opened before the cd, so a relative path still resolves
  rc=$?  # the judge's status, not the cleanup's (HIMMEL-4667)
  rm -rf "$jdir"
  return "$rc"
}

judge_scores() { # $1 judge result json -> the scores plus cost_usd, or null
  local s  # an empty file makes jq print nothing at rc 0: still null
  s="$(jq -c '(.structured_output // (.result | fromjson? ) // null) as $s
         | if $s == null then null else $s + {cost_usd: (.total_cost_usd // null)} end' \
    "$1" 2>/dev/null)"
  echo "${s:-null}"
}

judge() { # $1 file stem, $2 task, $3 worktree, $4 fixture sha, $5 agent report file, $6 out dir, $7 budget -> judge JSON on stdout
  local stem="$1" task="$2" wt="$3" fix="$4" report="$5" od="$6" budget="$7" packet
  packet="$od/$stem.judge-packet.md"
  git -C "$wt" add -A
  {
    cat "$HERE/judge-rubric.md"
    printf '\n## Task given to the agent\n\n'
    cat "$TASKS/$task/prompt.md"
    printf '\n## The diff it produced\n\n```diff\n'
    git -C "$wt" diff --cached "$fix" | head -c 60000
    printf '\n```\n\n## Its final report\n\n'
    cat "$report"
  } | redact >"$packet"
  judge_call "$packet" "$od/$stem.judge.json" "$od/$stem.judge.err" "$JUDGE_MODEL" "$budget" || { echo null; return 0; }
  judge_scores "$od/$stem.judge.json"
}

stem_of() { # $1 task, $2 repeat -> the file stem (the task alone for repeat 1)
  if [ "${2:-1}" -gt 1 ]; then echo "$1.r$2"; else echo "$1"; fi
}

run_task() { # $1 task, $2 repeat -> appends a row to runs.jsonl, prints the task's cost
  local task="$1" rp="$2" stem wt fix start end bank0 bank1 met0 met1 acost outer res sid tr metrics acc_line acc_rc scope jres remaining tok judged=0
  stem="$(stem_of "$task" "$rp")"
  wt="$WORK_ROOT/lq-$RUN_ID-$stem"
  mkdir -p "$WORK_ROOT"
  git -C "$REPO" worktree add -q --detach "$wt" "$BASE_SHA" || die "worktree add failed for $task"
  fix="$(materialize "$task" "$wt")" || die "fixture for $task failed"
  bank0="$(bank_read)"
  if [ "${bank0%% *}" != PROCEED ] && [ "$LANE" != api ]; then
    git -C "$REPO" worktree remove --force "$wt" >/dev/null 2>&1
    echo "bank-refused ${bank0%% *}"; return 0
  fi
  bank0="${bank0#* }"; met0="$(metered_read)"
  remaining="$(awk -v m="$MAX_USD" -v s="$SPENT" 'BEGIN{printf "%.2f", m - s}')"
  outer="$(awk -v r="$remaining" -v f="$BUDGET_FACTOR" 'BEGIN{printf "%.2f", r * f}')"
  start="$(date +%s)"
  (
    cd "$wt" || exit 1
    if [ "$LANE" = api ]; then
      # HIMMEL-4986: the launcher keeps the key and removes every other credential source; the
      # subscription token is dropped here too, so no layer between can hand it to the agent.
      unset CLAUDE_CODE_OAUTH_TOKEN
      export HIMMEL_API_JOB_ID="lq-$RUN_ID-$stem"
      # headless-claude-ok: HIMMEL-4986 lane-quality api agent run, launcher bank gate and ledger reservation, explicit permission mode, budget-capped
      # launch-profile-ok: HIMMEL-4986 the eval measures the lane's own default config, not a leg profile
      timeout "$TIMEOUT" "$AGENT_BIN" -p "$(cat "$TASKS/$task/prompt.md")" --model "$MODEL" --permission-mode auto \
        --output-format json --max-budget-usd "$outer" ${EFFORT:+--effort "$EFFORT"}
      exit $?
    fi
    # HIMMEL-4459: the pin's rc is advisory; the keyword-only LAUNCH GATE re-checks.
    native_auth_pin_env
    if [[ -z "${!ANTHROPIC_*}${!anthropic_*}${!CLAUDE_CODE_USE_*}${!claude_code_use_*}" ]]; then
      # headless-claude-ok: HIMMEL-4090 lane-quality agent run, bank-preflighted per sweep, explicit permission mode, budget-capped
      # launch-profile-ok: HIMMEL-4090 the eval measures the lane's own default config (claude or the lane launcher in $AGENT_BIN), not a leg profile
      timeout "$TIMEOUT" "$AGENT_BIN" -p "$(cat "$TASKS/$task/prompt.md")" --model "$MODEL" --permission-mode auto \
        --output-format json --max-budget-usd "$outer" ${EFFORT:+--effort "$EFFORT"}
    else
      exit 1
    fi
  )>"$OUT/$stem.result.json" 2>"$OUT/$stem.stderr"
  end="$(date +%s)"
  bank1="$(bank_read)"; bank1="${bank1#* }"; met1="$(metered_read)"
  res="$OUT/$stem.result.json"
  jq -e . "$res" >/dev/null 2>&1 || echo '{"is_error":true,"subtype":"harness-no-json"}' >"$res"
  jq -r '.result // ""' "$res" >"$OUT/$stem.report.md"
  acost="$(agent_cost "$res")"
  sid="$(jq -r '.session_id // ""' "$res")"
  tr=""
  [ -n "$sid" ] && tr="$(find "$TRANSCRIPTS" -name "$sid.jsonl" -print 2>/dev/null | head -1)"
  metrics="$(transcript_metrics "$tr" "$OUT/$stem.report.md")"
  timeout "$TIMEOUT" bash "$TASKS/$task/accept.sh" "$wt" "$fix" >"$OUT/$stem.accept.log" 2>&1; acc_rc=$?
  acc_line="$(grep -E '^accept: [0-9]+/[0-9]+$' "$OUT/$stem.accept.log" | tail -1)"
  # Staged against the fixture commit, so a file the agent committed counts too.
  git -C "$wt" add -A
  scope="$(git -C "$wt" diff --cached --name-only "$fix" | grep -v '^lq-work/' | jq -R . | jq -sc .)"
  remaining="$(awk -v m="$MAX_USD" -v s="$SPENT" -v c="$( [ "$acost" = null ] && echo 0 || echo "$acost" )" 'BEGIN{printf "%.2f", m - s - c}')"
  jres=null
  if [ "$NO_JUDGE" -eq 0 ]; then
    read -r tok _ <<<"$(bank_read)"
    if [ "$tok" != PROCEED ]; then
      echo "lane-quality: bank preflight said $tok; judge skipped" >"$OUT/$stem.judge.err"
    elif [ "$acost" = null ]; then
      echo "lane-quality: agent cost unknown, budget cannot be bounded; judge skipped" >"$OUT/$stem.judge.err"
    elif awk -v r="$remaining" 'BEGIN{exit !(r >= 0.01)}'; then
      jres="$(judge "$stem" "$task" "$wt" "$fix" "$OUT/$stem.report.md" "$OUT" "$remaining")"
      judged=1
    else
      echo "lane-quality: budget spent by the agent; judge skipped" >"$OUT/$stem.judge.err"
    fi
  fi
  [ -n "$jres" ] || jres=null
  if [ "$KEEP" -eq 0 ]; then git -C "$REPO" worktree remove --force "$wt" >/dev/null 2>&1; fi
  jq -nc --arg run "$RUN_ID" --arg lane "$LANE" --arg model "$MODEL" --arg effort "$EFFORT" --arg task "$task" --argjson rep "$rp" \
    --arg base "$BASE_SHA" --arg fix "$fix" --argjson wall "$((end - start))" --arg b0 "$bank0" --arg b1 "$bank1" --arg m0 "$met0" --arg m1 "$met1" --argjson ac "$acost" \
    --arg acc "$acc_line" --argjson accrc "$acc_rc" --argjson scope "$scope" --argjson m "$metrics" \
    --argjson j "$jres" --argjson nojudge "$NO_JUDGE" --arg jm "$JUDGE_MODEL" --arg wt "$( [ "$KEEP" -eq 1 ] && echo "$wt" )" --slurpfile r "$res" '
    $r[0] as $r
    | { run_id: $run, lane: $lane, model: $model, effort: $effort, task: $task, rep: $rep, base_sha: $base, fixture_sha: $fix,
        wall_s: $wall, duration_ms: ($r.duration_ms // null), num_turns: ($r.num_turns // null),
        cost_usd: $ac, reported_cost_usd: ($r.total_cost_usd // null), bank_5h_before: $b0, bank_5h_after: $b1,
        metered_before: (if $m0 == "" then null else $m0 end), metered_after: (if $m1 == "" then null else $m1 end),
        permission_denials: (($r.permission_denials // []) | length),
        is_error: (if $r | has("is_error") then $r.is_error else null end),
        subtype: ($r.subtype // null),
        accept_passed: (($acc | capture("(?<p>[0-9]+)/").p? | tonumber?) // 0),
        accept_total: (($acc | capture("/(?<t>[0-9]+)").t? | tonumber?) // 0),
        tokens: ([($r.modelUsage // {}) | to_entries[] | .value] | {input: (map(.inputTokens // 0) | add // 0), output: (map(.outputTokens // 0) | add // 0), cache_read: (map(.cacheReadInputTokens // 0) | add // 0), cache_create: (map(.cacheCreationInputTokens // 0) | add // 0)}),
        accept_ok: ($accrc == 0), scope_ok: ($scope | length == 0), out_of_scope: $scope,
        judge: $j, judge_model: (if $nojudge == 1 then null else $jm end), kept_worktree: $wt } + $m' >>"$OUT/runs.jsonl" || die "$task: could not record its runs.jsonl row"
  # "unknown" when the agent, or a judge that was launched, left no cost
  # (killed by the timeout, or failed): the sweep stops.
  jq -nr --argjson ac "$acost" --argjson j "$jres" --argjson judged "$judged" '
    if $ac == null or ($judged == 1 and ($j.cost_usd? // null) == null) then "unknown"
    else $ac + ($j.cost_usd? // 0) end'
}

API_PILOT_CAP=1  # HIMMEL-4986: the most one api sweep may be given, in USD

# api_dry_run <tasks>: every check an api sweep makes before it spends, plus the
# plan and the exact command. Spends nothing, starts nothing, prints no key.
api_dry_run() {
  [ "${HIMMEL_API_LANE:-}" = on ] || die "api lane is OFF (set HIMMEL_API_LANE=on)"
  case "${HIMMEL_API_ACCOUNT:-}" in A|B) ;; *) die "HIMMEL_API_ACCOUNT must be A or B" ;; esac
  [ -n "${HIMMEL_API_KEY_ID:-}" ] || die "HIMMEL_API_KEY_ID is absent"
  [ -n "${ANTHROPIC_API_KEY:-}" ] || die "ANTHROPIC_API_KEY is absent"
  [ -x "$AGENT_BIN" ] || die "launcher '$AGENT_BIN' is not executable"
  local n; n="$(printf '%s' "$1" | tr ',' '\n' | grep -c .)"
  echo "lane-quality: api dry-run (nothing launched, nothing spent)"
  echo "  account $HIMMEL_API_ACCOUNT, key id $HIMMEL_API_KEY_ID, model $MODEL${EFFORT:+, effort $EFFORT}"
  echo "  tasks ($n x $REPS reps): $1 from $TASKS at $BASE_SHA"
  echo "  cap $MAX_USD USD for the sweep (ceiling $API_PILOT_CAP); each call gets the remainder as --max-budget-usd"
  echo "  command: $AGENT_BIN -p <task prompt> --model $MODEL --permission-mode auto --output-format json --max-budget-usd <remainder>${EFFORT:+ --effort $EFFORT}"
}

init_env() { # the claude binary, the repo, the bank preflight and the native-auth pin
  CLAUDE_BIN="${LQ_CLAUDE_BIN:-claude}"
  REPO="${LQ_REPO:-$(dirname "$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir)")}"
  PREFLIGHT="${LQ_PREFLIGHT:-$REPO/scripts/lib/bank-preflight.sh}"
  # shellcheck source=../../lib/native-auth-pin.sh
  . "$HERE/../../lib/native-auth-pin.sh" || die "cannot source native-auth-pin.sh"
}

# HIMMEL-4906: run --config FILE. A JSON object with optional keys, so a second
# task set can share this driver without env-prefix knobs:
#   tasks_dir   task directory, relative to this dir, must stay under it
#   base_sha    40-hex commit the fixture worktrees are cut from
#   transcripts transcript root searched for the agent session
apply_config() {
  local f="$1" td bs tr_ root
  [ -f "$f" ] || die "--config: no such file '$f'"
  jq -e 'type == "object"' "$f" >/dev/null 2>&1 || die "--config: '$f' is not a JSON object"
  td="$(jq -r '.tasks_dir // empty' "$f")"
  bs="$(jq -r '.base_sha // empty' "$f")"
  tr_="$(jq -r '.transcripts // empty' "$f")"
  if [ -n "$td" ]; then
    root="$(realpath -m "$HERE")"
    td="$(realpath -m "$HERE/$td")"
    case "$td" in "$root"/*) ;; *) die "--config: tasks_dir must stay under $root" ;; esac
    [ -d "$td" ] || die "--config: tasks_dir '$td' is not a directory"
    TASKS="$td"
  fi
  if [ -n "$bs" ]; then
    printf '%s' "$bs" | grep -Eq '^[0-9a-f]{40}$' || die "--config: base_sha must be 40 hex characters"
    BASE_SHA="$bs"
  fi
  [ -z "$tr_" ] || TRANSCRIPTS="$tr_"
}

cmd_run() {
  LANE=""; MODEL=""; TASK_LIST=""; EFFORT=""; MAX_USD=""; TIMEOUT=1800; JUDGE_MODEL=opus
  NO_JUDGE=0; KEEP=0; OUT=""; REPS=1; CONFIG=""; DRY_RUN=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --lane|--model|--tasks|--effort|--max-usd|--timeout|--judge-model|--out|--reps|--config)
        [ $# -ge 2 ] || die "$1 needs a value"
        case "$1" in
          --config) CONFIG="$2" ;;
          --lane) LANE="$2" ;; --model) MODEL="$2" ;; --tasks) TASK_LIST="$2" ;;
          --effort) EFFORT="$2" ;; --max-usd) MAX_USD="$2" ;; --timeout) TIMEOUT="$2" ;;
          --judge-model) JUDGE_MODEL="$2" ;; --out) OUT="$2" ;; --reps) REPS="$2" ;;
        esac; shift 2 ;;
      --no-judge) NO_JUDGE=1; shift ;;
      --keep) KEEP=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      *) die "unknown argument '$1'" ;;
    esac
  done
  [ -n "$MODEL" ] || die "--model is required"
  case "$LANE" in
    native|openrouter) ;;
    api)
      # HIMMEL-4986: the cap and the no-judge rule are code, not convention.
      [ "$NO_JUDGE" -eq 1 ] || die "--lane api needs --no-judge (the judge runs native and would draw the subscription bank)"
      MAX_USD="${MAX_USD:-$API_PILOT_CAP}"
      awk -v m="$MAX_USD" -v c="$API_PILOT_CAP" 'BEGIN{exit !(m+0 <= c+0)}' \
        || die "--lane api caps the sweep at $API_PILOT_CAP USD; --max-usd $MAX_USD is above the cap" ;;
    claudex)
      # HIMMEL-4906: the per-dispatch lane opt-in the dispatcher reads.
      if [ "${CLAUDEX_LANE_OK:-}" != 1 ]; then
        echo "lane-quality: lane claudex needs CLAUDEX_LANE_OK=1 on the command (HIMMEL-4906)" >&2
        exit 3
      fi ;;
    deepseek)
      echo "lane-quality: lane '$LANE' is not enabled (HIMMEL-4090): it needs the operator's go; see docs/internals/lane-calibration.md" >&2
      exit 3 ;;
    *) die "--lane must be native, openrouter, api or claudex; got '$LANE'" ;;
  esac
  MAX_USD="${MAX_USD:-3}"
  awk -v m="$MAX_USD" 'BEGIN{exit !(m+0 > 0)}' || die "--max-usd must be a positive number"
  [ "$DRY_RUN" -eq 0 ] || [ "$LANE" = api ] || die "--dry-run is for --lane api only"
  case "$TIMEOUT" in ''|*[!0-9]*) die "--timeout must be whole seconds" ;; esac
  [ "$TIMEOUT" -gt 0 ] || die "--timeout must be positive (0 disables timeout)"
  case "$REPS" in ''|*[!0-9]*) die "--reps must be a whole number" ;; esac
  [ "$REPS" -gt 0 ] || die "--reps must be positive"

  init_env
  BASE_SHA="${LQ_BASE_SHA:-$(tr -d '[:space:]' <"$HERE/BASE_SHA")}"
  WORK_ROOT="${LQ_WORK_ROOT:-$REPO/.claude/worktrees}"
  # The judge always runs native; a metered lane's agent goes through its launcher.
  AGENT_BIN="$CLAUDE_BIN"; METERED_PROBE=""; BUDGET_FACTOR=1; TRANSCRIPTS="${LQ_TRANSCRIPTS:-$HOME/.claude/projects}"
  if [ "$LANE" = openrouter ]; then
    # Only a priced model can be capped; refuse the rest before any spend.
    [ "$MODEL" = haiku ] || die "--lane openrouter supports --model haiku only (the one model with a PRICES row); got '$MODEL'"
    AGENT_BIN="${LQ_LANE_BIN:-$REPO/scripts/claude-openrouter}"
    METERED_PROBE="${LQ_METERED_PROBE:-$REPO/scripts/lanes/openrouter-cost.sh}"
    TRANSCRIPTS="${LQ_TRANSCRIPTS:-$HOME/.claude-openrouter/projects}"
    # The sweep cap counts real (repriced) spend. The per-call cap is in Claude
    # Code's own units, REPORTED_RATIO (5) times list price, and the real charge
    # is at most METERED_MARKUP (1.2) times list, so a factor of 4 stops a call
    # at 4/5 x 1.2 = 0.96 of the real remainder.
    BUDGET_FACTOR=4
    echo "lane-quality: openrouter agent budget factor $BUDGET_FACTOR (Claude Code over-counts the gateway slug; --max-usd counts real spend)" >&2
  fi
  if [ "$LANE" = api ]; then
    AGENT_BIN="${LQ_LANE_BIN:-$REPO/scripts/api-lane/claude-api.sh}"
  fi
  if [ "$LANE" = claudex ]; then
    # The claudex launcher wraps claude, so -p and --output-format json work
    # unchanged. Claude Code cannot price the gpt slug, so the sweep cap counts
    # its reported figure when present and 0 otherwise; read tokens and the
    # codex bank instead of dollars.
    AGENT_BIN="${LQ_LANE_BIN:-$REPO/scripts/claude-codex}"
    TRANSCRIPTS="${LQ_TRANSCRIPTS:-$HOME/.claude-codex/projects}"
  fi
  [ -z "$CONFIG" ] || apply_config "$CONFIG"
  RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$LANE-$(printf '%s' "$MODEL" | tr -c 'A-Za-z0-9.-' '_')"
  OUT="${OUT:-$HOME/.himmel/eval/lane-quality/$RUN_ID}"
  mkdir -p "$OUT" || die "cannot create $OUT"
  OUT="$(cd "$OUT" && pwd)" || die "cannot resolve $OUT"
  git -C "$REPO" cat-file -e "$BASE_SHA^{commit}" 2>/dev/null || die "base sha $BASE_SHA not in $REPO"

  local tasks t cost tok r
  tasks="${TASK_LIST:-$(all_tasks | tr '\n' ',')}"
  for t in $(printf '%s' "$tasks" | tr ',' ' '); do
    [ -f "$TASKS/$t/prompt.md" ] || die "unknown task '$t'"
  done
  if [ "$DRY_RUN" -eq 1 ]; then api_dry_run "$tasks"; return 0; fi
  SPENT=0; STATUS=ok
  echo "lane-quality: run $RUN_ID → $OUT"
  # Repeat by repeat, so a sweep cut short still covers every task evenly.
  for r in $(seq 1 "$REPS"); do
  for t in $(printf '%s' "$tasks" | tr ',' ' '); do
    if awk -v m="$MAX_USD" -v s="$SPENT" 'BEGIN{exit !(s >= m)}'; then
      echo "lane-quality: budget cap reached (spent $SPENT of $MAX_USD USD); not starting '$t'" >&2
      STATUS=partial; break 2
    fi
    read -r tok _ <<<"$(bank_read)"
    if [ "$tok" != PROCEED ] && [ "$LANE" != api ]; then  # the api launcher gates its own credit
      echo "lane-quality: bank preflight said $tok; not starting '$t'" >&2
      exit 75
    fi
    echo "lane-quality: task $t (repeat $r of $REPS)"
    cost="$(run_task "$t" "$r")" || die "task '$t' failed; see $OUT"
    cost="$(printf '%s\n' "$cost" | tail -1)"
    case "$cost" in bank-refused*)
      echo "lane-quality: bank preflight said ${cost#bank-refused }; '$t' not launched" >&2
      exit 75 ;;
    esac
    if [ "$cost" = unknown ]; then
      echo "lane-quality: task '$t' left its cost unknown (agent or judge killed?); stopping the sweep, spend so far is a lower bound" >&2
      STATUS=partial; break 2
    fi
    SPENT="$(awk -v s="$SPENT" -v c="${cost:-0}" 'BEGIN{printf "%.4f", s + c}')"
  done
  done
  echo "lane-quality: done, spent $SPENT USD (API-price equivalent); rows in $OUT/runs.jsonl"
  # HIMMEL-4647: one eval-runs ledger row per sweep (scripts/eval/lib/eval_runs.py);
  # a ledger failure warns and never changes the sweep's result.
  if [ -s "$OUT/runs.jsonl" ]; then
    python3 "$HERE/../lib/eval_runs.py" lane-quality "$OUT" --run-id "$RUN_ID" --status "$STATUS" \
      --judge-model "$( [ "$NO_JUDGE" -eq 1 ] && echo none || echo "$JUDGE_MODEL" )" \
      || echo "lane-quality: WARNING eval-runs row not written" >&2
  fi
}

cmd_table() {
  [ $# -ge 1 ] || die "table needs at least one run directory"
  local d files=""
  for d in "$@"; do [ -r "$d/runs.jsonl" ] || die "no runs.jsonl in $d"; files="$files $d/runs.jsonl"; done
  echo '| lane | model | task | accept | judge C/S/T/H | wall s | tool calls | compactions | cost USD | 5h bank | metered USD | denials perm/hook | peeked |'
  echo '|---|---|---|---|---|---|---|---|---|---|---|---|---|'
  # shellcheck disable=SC2086
  jq -r '
    def n: if . == null then "?" else tostring end;
    "| \(.lane) | \(.model) | \(.task) | \(.accept_passed)/\(.accept_total)\(if .accept_ok then "" else " ✗" end) | "
    + (if .judge == null then "–" else "\(.judge.correctness)/\(.judge.scope_discipline)/\(.judge.test_quality)/\(.judge.honesty)" end)
    + " | \(.wall_s) | \(.tool_calls | n) | \(.compactions | n) | \(.cost_usd | n) | \(.bank_5h_before)→\(.bank_5h_after) | "
    + (if .metered_before == null then "–" else "\(.metered_before)→\(.metered_after)" end) + " | "
    + "\(.permission_denials)/\(.hook_denials | n) | \(.peeked | n) |"' $files
  echo
  # shellcheck disable=SC2086
  python3 "$HERE/lq_stats.py" summary $files
}

# calibration <run-dir>... [--judge2-model M] [--judge2-effort E] [--max-usd U]
# [--timeout S] [--json] [--no-ledger]: the second-judge calls happen here
# (bank-preflighted and budget-capped like the sweep); the maths is lq_stats.py.
cmd_calibration() {
  local dirs=() j2model="" j2effort="" json="" noledger="" label="" d stem packet out spent=0 remaining cost tok
  MAX_USD=1; TIMEOUT=600
  while [ $# -gt 0 ]; do
    case "$1" in
      --judge2-model|--judge2-effort|--max-usd|--timeout)
        [ $# -ge 2 ] || die "$1 needs a value"
        case "$1" in
          --judge2-model) j2model="$2" ;; --judge2-effort) j2effort="$2" ;;
          --max-usd) MAX_USD="$2" ;; --timeout) TIMEOUT="$2" ;;
        esac; shift 2 ;;
      --json) json=--json; shift ;;
      --no-ledger) noledger=--no-ledger; shift ;;
      -*) die "unknown argument '$1'" ;;
      *) dirs+=("$1"); shift ;;
    esac
  done
  [ "${#dirs[@]}" -ge 1 ] || die "calibration needs at least one run directory"
  for d in "${dirs[@]}"; do [ -r "$d/runs.jsonl" ] || die "no runs.jsonl in $d"; done
  [ -z "$j2effort" ] || [ -n "$j2model" ] || die "--judge2-effort needs --judge2-model"
  awk -v m="$MAX_USD" 'BEGIN{exit !(m+0 > 0)}' || die "--max-usd must be a positive number"
  case "$TIMEOUT" in ''|*[!0-9]*) die "--timeout must be positive whole seconds" ;; esac
  [ "$((10#$TIMEOUT))" -gt 0 ] || die "--timeout must be positive whole seconds"
  if [ -n "$j2model" ]; then
    # HIMMEL-4665: the stored-result label must be injective in (model, effort),
    # or one configuration reuses another's scores. Each byte outside
    # [A-Za-z0-9.-] becomes _<hex> (so a lone "_" is always an escape), and
    # "__", which no escaped part contains, joins model and effort.
    label="$(python3 -c 'import os, re, sys
enc = lambda s: re.sub(rb"[^A-Za-z0-9.-]", lambda m: b"_%02x" % m.group()[0], os.fsencode(s)).decode()
print("__".join(enc(a) for a in sys.argv[1:] if a))' "$j2model" "$j2effort")" || die "cannot build the second-judge label"
    init_env
    for d in "${dirs[@]}"; do
      while IFS= read -r stem; do
        packet="$d/$stem.judge-packet.md"; out="$d/$stem.judge2.$label.json"
        [ -s "$packet" ] || continue
        [ "$(judge_scores "$out")" = null ] || continue
        remaining="$(awk -v m="$MAX_USD" -v s="$spent" 'BEGIN{printf "%.2f", m - s}')"
        if ! awk -v r="$remaining" 'BEGIN{exit !(r >= 0.01)}'; then
          echo "lane-quality: second-judge budget spent ($spent of $MAX_USD USD); stopping, the rest stay unjudged" >&2
          break 2
        fi
        read -r tok _ <<<"$(bank_read)"
        if [ "$tok" != PROCEED ]; then
          echo "lane-quality: bank preflight said $tok; second judge stopped before $stem" >&2
          exit 75
        fi
        judge_call "$packet" "$out" "$d/$stem.judge2.$label.err" "$j2model" "$remaining" "$j2effort" \
          || die "cannot run the second judge on $packet"
        cost="$(jq -r '.total_cost_usd // empty' "$out" 2>/dev/null)"
        if [ -z "$cost" ]; then
          echo "lane-quality: second judge on $stem left its cost unknown; stopping, spend so far is a lower bound" >&2
          break 2
        fi
        spent="$(awk -v s="$spent" -v c="$cost" 'BEGIN{printf "%.4f", s + c}')"
      done < <(jq -r 'if (.rep // 1) > 1 then "\(.task).r\(.rep)" else .task end' "$d/runs.jsonl")
    done
    echo "lane-quality: second judge $label spent $spent USD" >&2
  fi
  python3 "$HERE/lq_stats.py" calibration ${label:+--judge2-label "$label"} $json $noledger "${dirs[@]}"
}

[ $# -ge 1 ] || usage
case "$1" in
  list) all_tasks ;;
  run) shift; cmd_run "$@" ;;
  table) shift; cmd_table "$@" ;;
  calibration) shift; cmd_calibration "$@" ;;
  materialize) shift; [ $# -ge 2 ] || die "materialize <task> <dir> [--reference]"; materialize "$@" ;;
  -h|--help) usage ;;
  *) die "unknown command '$1' (list|run|table|calibration|materialize)" ;;
esac
