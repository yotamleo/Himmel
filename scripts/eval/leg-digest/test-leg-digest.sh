#!/usr/bin/env bash
# scripts/eval/leg-digest/test-leg-digest.sh - hermetic suite for the leg digest (HIMMEL-4670 P1).
# Synthetic fixtures only; no model call, no bank, no ledger write.
#  1. every class key of spec section 2.2 comes out of fixtures/classes.jsonl;
#  2. the classifier sub-class: ledger first, else the journal's bracket against the fixed list;
#  3. suite rows carry final_red; trajectory joins by tool_call_id; trajectory rows;
#  4. the #1976 agents.jsonl fixture digests as expected;
#  5. canary: no free text from the journal reaches the digest (spec 6.1);
#  6. denial cross-check: mapper and trajectory.py agree except the enumerated exceptions (spec 2.3);
#  7. status ok / partial / inconclusive, and the digest spawns nothing but git and python3.
#
# check() evals its condition, so the single quotes are deliberate.
# shellcheck disable=SC2016
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
DIG="$HERE/leg-digest.ts"
FX="$HERE/fixtures"
REPO="$(cd "$HERE/../../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/leg-digest-test.XXXXXX")" || { echo "test-leg-digest: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

SID=4670c1a5-0000-4000-8000-000000000001
cp "$FX/classes.jsonl" "$TMP/$SID.jsonl"
digest() { bun "$DIG" --transcript "$1" --denials-ledger "$FX/classifier-denials.jsonl" "${@:2}"; }
digest "$TMP/$SID.jsonl" >"$TMP/classes.json" 2>"$TMP/classes.err" || bad "digest of classes.jsonl exits 0: $(head -c 300 "$TMP/classes.err")"
row() { jq -c --arg k "$1" --arg a "${2:-main}" '[.failures[] | select(.class == $k and .agent.id == $a)] | .[0] // empty' "$TMP/classes.json"; }

echo "1. class keys (spec 2.2)"
check "a chained-runner refusal is keyed by the hook after the closing ]:, not by the chain" '[ "$(row denied/guard-pr-check-literal | jq .count)" = 2 ]'
check "an emoji-led hook refusal is keyed by its hook" '[ "$(row denied/read-clamp | jq .count)" = 1 ]'
check "a name that is not a scripts/hooks basename is denied/other" '[ "$(row denied/other | jq .count)" = 1 ]'
check "the permission prompt is denied/permission-prompt" '[ "$(row denied/permission-prompt | jq .count)" = 1 ]'
check "an allow-listed tool error is keyed by its tool" '[ "$(row error/Edit | jq .count)" = 1 ]'
check "an mcp tool error is error/mcp" '[ "$(row error/mcp | jq .count)" = 1 ]'
check "an unknown tool error is error/other" '[ "$(row error/other | jq .count)" = 1 ]'
check "a BLOCKED report is blocked/-" '[ "$(row blocked/- | jq .count)" = 1 ]'
check "an API error with a listed code is run_error/<code>" '[ "$(row run_error/server_error | jq .count)" = 1 ]'
check "a subagent refusal is its own row under its agent id, role subagent" '[ "$(row denied/check-push-target sub01 | jq -c "[.count, .agent.role, .agent.model]")" = "[1,\"subagent\",\"claude-sonnet-5-5\"]" ]'
check "the main agent row names role and model" '[ "$(row denied/read-clamp | jq -c "[.agent.role, .agent.model]")" = "[\"agent\",\"claude-opus-5-5\"]" ]'
check "tool_call_ids point back into the journal" '[ "$(row denied/guard-pr-check-literal | jq -c .tool_call_ids)" = "[\"toolu_d1\",\"toolu_d2\"]" ]'
check "first_ts and last_ts bound the class" 'row denied/guard-pr-check-literal | jq -e ".first_ts < .last_ts" >/dev/null'

echo "2. classifier sub-class: ledger, then the journal bracket against the fixed list"
check "a ledger row with a listed category keys it" '[ "$(row denied/classifier:merge-without-review | jq -c .tool_call_ids)" = "[\"toolu_c1\"]" ]'
check "a ledger tag of unknown falls back to the journal bracket on the list" '[ "$(row denied/classifier:out-of-place-publication | jq -c .tool_call_ids)" = "[\"toolu_c2\"]" ]'
check "an off-list bracket and a malformed bracket are classifier:other" '[ "$(row denied/classifier:other | jq -c .tool_call_ids)" = "[\"toolu_c3\",\"toolu_c4\"]" ]'
check "another session's ledger row is never joined" '! grep -q session-transcript-tampering "$TMP/classes.json"'

echo "3. suite rows, the trajectory join, trajectory rows"
check "a tracked suite that later passes is not final_red" '[ "$(row suite/test-trajectory.sh | jq -c "[.count, .final_red]")" = "[1,false]" ]'
check "a tracked suite whose last run failed is final_red" '[ "$(row suite/test-eval-runs.sh | jq -c "[.count, .final_red]")" = "[1,true]" ]'
check "an untracked suite is suite/other" '[ "$(row suite/other | jq .count)" = 1 ]'
check "only suite rows carry final_red" '[ "$(jq "[.failures[] | select(has(\"final_red\") and (.failure != \"suite\"))] | length" "$TMP/classes.json")" = 0 ]'
check "identical_retry and recovered come from trajectory.py, joined by tool_call_id" '[ "$(row denied/guard-pr-check-literal | jq -c "[.identical_retry, .recovered]")" = "[1,false]" ]'
check "a subagent row has no trajectory join (main agent only)" '[ "$(row denied/check-push-target sub01 | jq -c "[.identical_retry, .recovered]")" = "[null,null]" ]'
check "identical_denied_retries >= 1 writes a traj/identical-retry row" '[ "$(row traj/identical-retry | jq -c "[.failure, .count]")" = "[\"traj\",1]" ]'
check "metrics count the session" 'jq -e ".metrics | .turns == 3 and .subagents == 1 and .fail_denied == 10 and .fail_suite == 3 and .fail_blocked == 1 and .fail_error == 3 and .run_errors == 1 and .interrupts == 1 and .identical_denied_retries == 1" "$TMP/classes.json" >/dev/null'
check "the digest names its versions and the main model" 'jq -e ".digest_v == 1 and .mapper_v == 1 and .trajectory_v == 1 and .model == \"claude-opus-5-5\" and .session == \"$SID\" and .status == \"ok\"" "$TMP/classes.json" >/dev/null'

echo "4. the #1976 agents.jsonl fixture"
cp "$REPO/scripts/config-ui/tests/fixtures/agui/agents.jsonl" "$TMP/agents.jsonl"
digest "$TMP/agents.jsonl" >"$TMP/agents.json" 2>/dev/null
check "agents.jsonl digests to its four failures" '[ "$(jq -c "[.failures[] | select(.failure != \"traj\") | .class] | sort" "$TMP/agents.json")" = "[\"blocked/-\",\"denied/check-push-target\",\"error/Bash\",\"suite/other\"]" ]'
check "a subagent_type outside the allow-list is kind other" 'jq -e ".agents | map(select(.id == \"a1b2c3\")) | .[0].kind == \"other\"" "$TMP/agents.json" >/dev/null'

echo "5. canary: no journal text reaches the digest (spec 6.1)"
cp "$FX/canary.jsonl" "$TMP/$SID.c.jsonl"
check "the canary fixture carries the canary" '[ "$(grep -c CANARY4670zq "$FX/canary.jsonl")" -ge 20 ]'
digest "$TMP/$SID.c.jsonl" >"$TMP/canary.json" 2>"$TMP/canary.err"
check "the canary digest is non-empty" 'jq -e ".failures | length > 10" "$TMP/canary.json" >/dev/null'
check "the canary appears nowhere in the digest or its stderr" '! grep -q CANARY4670zq "$TMP/canary.json" "$TMP/canary.err"'

echo "6. denial cross-check: mapper vs trajectory.py (spec 2.3)"
: >"$TMP/divergence.txt"
for f in "$REPO"/scripts/eval/lane-quality/fixtures/trajectory/*.jsonl "$REPO/scripts/config-ui/tests/fixtures/agui/agents.jsonl" "$FX/classes.jsonl"; do
  n="$(basename "$f")"
  digest "$f" | jq -r --arg n "$n" '.stats.denial_divergence[] | "\($n) \(.tool_call_id) \(.only)"' >>"$TMP/divergence.txt"
done
grep -v '^#' "$HERE/denial-exceptions.txt" | grep -v '^$' | awk '{print $1, $2, $3}' | sort >"$TMP/allowed.txt"
sort "$TMP/divergence.txt" >"$TMP/seen.txt"
check "every divergence is an enumerated exception" '[ -z "$(comm -23 "$TMP/seen.txt" "$TMP/allowed.txt")" ] || { comm -23 "$TMP/seen.txt" "$TMP/allowed.txt"; false; }'
check "every enumerated exception still occurs (no stale lines)" '[ -z "$(comm -13 "$TMP/seen.txt" "$TMP/allowed.txt")" ] || { comm -13 "$TMP/seen.txt" "$TMP/allowed.txt"; false; }'
check "every exception names its reason" '! grep -v "^#" "$HERE/denial-exceptions.txt" | grep -v "^$" | awk "NF < 4" | grep -q .'

echo "7. status and spawns"
check "a missing journal is inconclusive, exit 0" 'digest "$TMP/nope.jsonl" | jq -e ".status == \"inconclusive\" and .failures == []" >/dev/null'
check "a journal over the size cap is inconclusive" 'digest "$TMP/$SID.jsonl" --max-bytes 100 | jq -e ".status == \"inconclusive\"" >/dev/null'
{ cat "$FX/classes.jsonl"; echo 'not json'; } >"$TMP/$SID.p.jsonl"
check "a malformed line makes it partial" 'digest "$TMP/$SID.p.jsonl" | jq -e ".status == \"partial\" and .stats.malformed == 1" >/dev/null'
check "a usage error exits 2" 'bun "$DIG" >/dev/null 2>&1; [ $? = 2 ]'
check "the digest spawns only git and python3, never a model CLI" '[ "$(grep -oE "spawnSync\(\[\"[a-z0-9]+\"" "$DIG" | sort -u | tr -d "\n")" = "spawnSync([\"git\"spawnSync([\"python3\"" ] && ! grep -qE "\b(claude|codex|gemini)\b.*spawn|spawn.*\b(claude|codex|gemini)\b" "$DIG"'

echo "test-leg-digest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
