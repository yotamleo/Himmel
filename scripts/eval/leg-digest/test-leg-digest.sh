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
# absent: grep found no match (status 1); a grep error (status 2) is not proof of absence.
absent() { grep -q "$@"; [ $? = 1 ]; }

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

echo "tool denominators (HIMMEL-4816)"
check "calls retain Bash, Read and the exact MCP tool separately" 'jq -e ".metrics.tool_calls_by_tool | .Bash > 0 and .Read > 0 and .mcp__qmd__query == 1" "$TMP/classes.json" >/dev/null'
check "per-tool calls sum to the session total and unknown lane never comes from a model" 'jq -e "([.metrics.tool_calls_by_tool[]] | add) == .metrics.tool_calls and .lane == \"unknown\" and ([.tool_health[].lane] | unique) == [\"unknown\"]" "$TMP/classes.json" >/dev/null'
check "per-tool failures exclude text reports and grep no-match" 'jq -e ".metrics.tool_failures_by_tool.Edit == 1 and .metrics.tool_failures_by_tool.mcp__qmd__query == 1" "$TMP/classes.json" >/dev/null'

echo "2. classifier sub-class: ledger, then the journal bracket against the fixed list"
# HIMMEL-4683: the fixture's ledger row and journal bracket for toolu_c1 share one category, so a broken ledger join
# would still pass via the bracket fallback. Rewrite the bracket to another listed category; the ledger's must win.
mkdir -p "$TMP/lw"  # the digest keys the ledger by the journal basename, so the copy keeps "$SID.jsonl"
sed 's/Reason: \[Merge Without Review\]\./Reason: [Security Weaken]./' "$TMP/$SID.jsonl" >"$TMP/lw/$SID.jsonl"
digest "$TMP/lw/$SID.jsonl" >"$TMP/ledger-wins.json" 2>/dev/null || bad "the ledger-priority digest exits 0"
check "a ledger row with a listed category keys it" '[ "$(grep -c "Reason: \[Security Weaken\]" "$TMP/lw/$SID.jsonl")" = 1 ] && [ "$(jq -c "[.failures[] | select(.class | startswith(\"denied/classifier:\")) | [.class, .tool_call_ids]] | map(select(.[1] | index(\"toolu_c1\")))" "$TMP/ledger-wins.json")" = "[[\"denied/classifier:merge-without-review\",[\"toolu_c1\"]]]" ]'
check "a ledger tag of unknown falls back to the journal bracket on the list" '[ "$(row denied/classifier:out-of-place-publication | jq -c .tool_call_ids)" = "[\"toolu_c2\"]" ]'
check "an off-list bracket and a malformed bracket are classifier:other" '[ "$(row denied/classifier:other | jq -c .tool_call_ids)" = "[\"toolu_c3\",\"toolu_c4\"]" ]'
check "another session's ledger row is never joined" 'absent session-transcript-tampering "$TMP/classes.json"'

echo "3. suite rows, the trajectory join, trajectory rows"
check "a tracked suite that later passes is not final_red" '[ "$(row suite/test-trajectory.sh | jq -c "[.count, .final_red]")" = "[1,false]" ]'
check "a tracked suite whose last run failed is final_red" '[ "$(row suite/test-eval-runs.sh | jq -c "[.count, .final_red]")" = "[1,true]" ]'
check "an untracked suite is suite/other" '[ "$(row suite/other | jq .count)" = 1 ]'
check "only suite rows carry final_red" '[ "$(jq "[.failures[] | select(has(\"final_red\") and (.failure != \"suite\"))] | length" "$TMP/classes.json")" = 0 ]'
check "identical_retry and recovered come from trajectory.py, joined by tool_call_id" '[ "$(row denied/guard-pr-check-literal | jq -c "[.identical_retry, .recovered]")" = "[1,false]" ]'
check "a subagent row has no trajectory join (main agent only)" '[ "$(row denied/check-push-target sub01 | jq -c "[.identical_retry, .recovered]")" = "[null,null]" ]'
check "identical_denied_retries >= 1 writes a traj/identical-retry row" '[ "$(row traj/identical-retry | jq -c "[.failure, .count]")" = "[\"traj\",1]" ]'
check "metrics count the session" 'jq -e ".metrics | .turns == 3 and .subagents == 1 and .fail_denied == 10 and .fail_suite == 3 and .fail_blocked == 1 and .fail_error == 3 and .run_errors == 1 and .interrupts == 1 and .identical_denied_retries == 1" "$TMP/classes.json" >/dev/null'
check "the digest names its versions and the main model" 'jq -e ".digest_v == 2 and .mapper_v == 1 and .trajectory_v == 1 and .model == \"claude-opus-5-5\" and .session == \"$SID\" and .status == \"ok\"" "$TMP/classes.json" >/dev/null'

echo "4. the #1976 agents.jsonl fixture"
cp "$REPO/scripts/config-ui/tests/fixtures/agui/agents.jsonl" "$TMP/agents.jsonl"
digest "$TMP/agents.jsonl" >"$TMP/agents.json" 2>/dev/null
check "agents.jsonl digests to its four failures" '[ "$(jq -c "[.failures[] | select(.failure != \"traj\") | .class] | sort" "$TMP/agents.json")" = "[\"blocked/-\",\"denied/check-push-target\",\"error/Bash:no-such-file\",\"suite/other\"]" ]'
check "a subagent_type outside the allow-list is kind other" 'jq -e ".agents | map(select(.id == \"a1b2c3\")) | .[0].kind == \"other\"" "$TMP/agents.json" >/dev/null'

echo "5. canary: no journal text reaches the digest (spec 6.1)"
cp "$FX/canary.jsonl" "$TMP/$SID.c.jsonl"
check "the canary fixture carries the canary" '[ "$(grep -c CANARY4670zq "$FX/canary.jsonl")" -ge 20 ]'
digest "$TMP/$SID.c.jsonl" >"$TMP/canary.json" 2>"$TMP/canary.err" || bad "the canary digest exits 0"
check "the canary digest is non-empty" 'jq -e ".failures | length > 10" "$TMP/canary.json" >/dev/null'
check "the canary appears nowhere in the digest or its stderr" 'absent CANARY4670zq "$TMP/canary.json" "$TMP/canary.err"'
# HIMMEL-3724: input_head and the raw reason_tag never leave the host. The digest maps reason_tag onto the closed
# category list (slugged); every row here also carries input_head, and the off-list tag is a canary.
jq -c '. + {input_head: "IHEAD4670zq"} | if .reason_tag == "unknown" then .reason_tag = "RTAG4670zq" else . end' "$FX/classifier-denials.jsonl" >"$TMP/egress-ledger.jsonl"
bun "$DIG" --transcript "$TMP/$SID.jsonl" --denials-ledger "$TMP/egress-ledger.jsonl" >"$TMP/egress.json" 2>"$TMP/egress.err" || bad "the egress digest exits 0"
check "the egress ledger carries input_head and the canary tag" '[ "$(grep -c IHEAD4670zq "$TMP/egress-ledger.jsonl")" = 4 ] && [ "$(grep -c RTAG4670zq "$TMP/egress-ledger.jsonl")" = 1 ]'
check "the egress digest still keys the ledger category" '[ "$(jq -c "[.failures[] | select(.class == \"denied/classifier:merge-without-review\")] | length" "$TMP/egress.json")" = 1 ]'
check "no input_head key or value reaches the digest or its stderr" 'absent -e input_head -e IHEAD4670zq "$TMP/egress.json" "$TMP/egress.err"'
check "no raw reason_tag reaches the digest or its stderr, only the slugged category" 'absent -e RTAG4670zq -e "Merge Without Review" -e "Session Transcript Tampering" -e reason_tag "$TMP/egress.json" "$TMP/egress.err"'
# HIMMEL-4694: an off-list tag falls back to the journal bracket, so the class alone cannot show the canary row joined.
# The same row (ts, tool, session) with an on-list tag must key toolu_c2, else the absence check above is vacuous.
jq -c 'if .reason_tag == "RTAG4670zq" then .reason_tag = "Merge Without Review" else . end' "$TMP/egress-ledger.jsonl" >"$TMP/probe-ledger.jsonl"
bun "$DIG" --transcript "$TMP/$SID.jsonl" --denials-ledger "$TMP/probe-ledger.jsonl" >"$TMP/probe.json" 2>/dev/null || bad "the join-probe digest exits 0"
check "the canary ledger row is matched to toolu_c2" '[ "$(jq -c "[.failures[] | select(.class == \"denied/classifier:merge-without-review\") | .tool_call_ids[]]" "$TMP/probe.json")" = "[\"toolu_c1\",\"toolu_c2\"]" ]'

echo "6. denial cross-check: mapper vs trajectory.py (spec 2.3)"
: >"$TMP/divergence.txt"
for f in "$REPO"/scripts/eval/lane-quality/fixtures/trajectory/*.jsonl "$REPO/scripts/config-ui/tests/fixtures/agui/agents.jsonl" "$FX/classes.jsonl"; do
  n="$(basename "$f")"
  digest "$f" >"$TMP/cross.json" || bad "the cross-check digest of $n exits 0"
  jq -r --arg n "$n" '.stats.denial_divergence[] | "\($n) \(.tool_call_id) \(.only)"' "$TMP/cross.json" >>"$TMP/divergence.txt" || bad "the cross-check digest of $n lists its divergences"
done
grep -v '^#' "$HERE/denial-exceptions.txt" | grep -v '^$' | awk '{print $1, $2, $3}' | sort >"$TMP/allowed.txt"
sort "$TMP/divergence.txt" >"$TMP/seen.txt"
check "every divergence is an enumerated exception" '[ -z "$(comm -23 "$TMP/seen.txt" "$TMP/allowed.txt")" ] || { comm -23 "$TMP/seen.txt" "$TMP/allowed.txt"; false; }'
check "every enumerated exception still occurs (no stale lines)" '[ -z "$(comm -13 "$TMP/seen.txt" "$TMP/allowed.txt")" ] || { comm -13 "$TMP/seen.txt" "$TMP/allowed.txt"; false; }'
check "every exception names its reason" 'awk "!/^#/ && NF > 0 && NF < 4 { bad = 1 } END { exit bad }" "$HERE/denial-exceptions.txt"'

echo "7. status and spawns"
check "a missing journal is inconclusive, exit 0" 'digest "$TMP/nope.jsonl" | jq -e ".status == \"inconclusive\" and .failures == []" >/dev/null'
check "a journal over the size cap is inconclusive" 'digest "$TMP/$SID.jsonl" --max-bytes 100 | jq -e ".status == \"inconclusive\"" >/dev/null'
{ cat "$FX/classes.jsonl"; echo 'not json'; } >"$TMP/$SID.p.jsonl"
check "a malformed line makes it partial" 'digest "$TMP/$SID.p.jsonl" | jq -e ".status == \"partial\" and .stats.malformed == 1" >/dev/null'
check "a usage error exits 2" 'bun "$DIG" >/dev/null 2>&1; [ $? = 2 ]'
check "the digest spawns only git and python3, never a model CLI" '[ "$(grep -oE "spawnSync\(\[\"[a-z0-9]+\"" "$DIG" | sort -u | tr -d "\n")" = "spawnSync([\"git\"spawnSync([\"python3\"" ] && absent -E "\b(claude|codex|gemini)\b.*spawn|spawn.*\b(claude|codex|gemini)\b" "$DIG"'

echo "8. a subagent in its own file, a relative path, more denials than ids, a failed trajectory"
S2=4670c1a5-0000-4000-8000-000000000002
cp -R "$FX/split" "$TMP/split"
(cd "$TMP/split" && bun "$DIG" --transcript "$S2.jsonl" --denials-ledger "$FX/classifier-denials.jsonl") >"$TMP/split.json" 2>"$TMP/split.err"
srow() { jq -c --arg k "$1" --arg a "${2:-main}" '[.failures[] | select(.class == $k and .agent.id == $a)] | .[0] // empty' "$TMP/split.json"; }
check "a relative --transcript still follows its subagent file" '[ "$(jq .stats.files "$TMP/split.json")" = 2 ] && [ -n "$(srow denied/permission-prompt sub02)$(srow suite/test-trajectory.sh sub02)" ]'
check "final_red is per agent: main went green, the subagent stayed red" '[ "$(srow suite/test-trajectory.sh | jq -c "[.count, .final_red]")" = "[1,false]" ] && [ "$(srow suite/test-trajectory.sh sub02 | jq -c "[.count, .final_red]")" = "[1,true]" ]'
check "two untracked suites on suite/other: one still red keeps the row final_red" '[ "$(srow suite/other | jq -c "[.count, .final_red]")" = "[2,true]" ]'
check "the trajectory join covers denials past the five tool_call_ids kept" '[ "$(srow denied/read-clamp | jq -c "[.count, (.tool_call_ids | length), .recovered, .identical_retry]")" = "[6,5,false,1]" ]'
mkdir -p "$TMP/fakebin"
printf '#!/bin/sh\nexit 1\n' >"$TMP/fakebin/python3"
chmod +x "$TMP/fakebin/python3"
check "a failed trajectory.py makes it partial" 'PATH="$TMP/fakebin:$PATH" digest "$TMP/$SID.jsonl" | jq -e ".status == \"partial\" and .stats.trajectory_failed == true" >/dev/null'
check "a trajectory.py that ran is not a failure" 'jq -e ".stats.trajectory_failed == false" "$TMP/classes.json" >/dev/null'
mkdir -p "$TMP/nogit"
printf '#!/bin/sh\nexit 1\n' >"$TMP/nogit/git"
chmod +x "$TMP/nogit/git"
check "a failed git ls-files makes it partial and names the lookup" 'PATH="$TMP/nogit:$PATH" digest "$TMP/$SID.jsonl" | jq -e ".status == \"partial\" and .stats.lookups_failed == [\"tracked-tests\"]" >/dev/null'
mkdir -p "$TMP/onlybun"
ln -s "$(command -v bun)" "$TMP/onlybun/bun"
check "git and python3 missing from PATH make it partial, exit 0" 'PATH="$TMP/onlybun" digest "$TMP/$SID.jsonl" | jq -e ".status == \"partial\" and .stats.trajectory_failed == true and .stats.lookups_failed == [\"tracked-tests\"]" >/dev/null'
check "lookups that worked leave lookups_failed empty" 'jq -e ".stats.lookups_failed == []" "$TMP/classes.json" >/dev/null'

echo "9. error/Bash sub-classes and the context-guard denials (HIMMEL-4785)"
S9=4785c1a5-0000-4000-8000-000000000001
cp "$FX/bash-errors.jsonl" "$TMP/$S9.jsonl"
digest "$TMP/$S9.jsonl" >"$TMP/be.json" 2>"$TMP/be.err" || bad "digest of bash-errors.jsonl exits 0: $(head -c 300 "$TMP/be.err")"
berow() { jq -c --arg k "$1" '[.failures[] | select(.class == $k and .agent.id == "main")] | .[0] // empty' "$TMP/be.json"; }
check "a grep that matched nothing (exit 1, empty output) is not a failure row" '[ "$(jq "[.failures[] | select(.class | test(\"no-match\"))] | length" "$TMP/be.json")" = 0 ] && [ -z "$(berow error/Bash:no-match)" ]'
check "it is counted as ok_no_match, not as an error" 'jq -e ".metrics.ok_no_match == 4 and .metrics.fail_error == 21" "$TMP/be.json" >/dev/null'
check "no failure row carries an ok/ class" '[ "$(jq "[.failures[] | select(.class | startswith(\"ok/\"))] | length" "$TMP/be.json")" = 0 ]'
check "a grep with output, a non-grep empty exit 1, a grep followed by a failing command or piped into one or into a parenthesized one, a grep with an apostrophe in a trailing comment followed by a failing command, a grep whose escaped space makes the # an argument, a grep whose backslash-newline continuation leaves a comment line with an apostrophe, a usage error that names two tracked scripts and neither in its output, a grep exit 2, an unmatched exit 3 and an untracked script stay error/Bash" '[ "$(berow error/Bash | jq .count)" = 13 ]'
check "a usage error is keyed by the tracked script, one row per script" '[ "$(berow error/Bash:usage:impacted-suites | jq .count)" = 3 ] && [ "$(berow error/Bash:usage:write-verdicts | jq .count)" = 1 ]'
check "clear-cr-marker exit 14 is error/Bash:cr-gate-exit-14, another script at 14 is not" '[ "$(berow error/Bash:cr-gate-exit-14 | jq -c "[.count, .tool_call_ids]")" = "[1,[\"toolu_cr1\"]]" ]'
check "a zsh nomatch is error/Bash:zsh-nomatch, not no-match" '[ "$(berow error/Bash:zsh-nomatch | jq -c .tool_call_ids)" = "[\"toolu_z1\"]" ]'
check "a missing path is error/Bash:no-such-file in both spellings" '[ "$(berow error/Bash:no-such-file | jq -c .tool_call_ids)" = "[\"toolu_f1\",\"toolu_f2\"]" ]'
check "a context-guard refusal is its own denied/ class, three spellings" '[ "$(berow denied/guard-leg-context-handoff | jq -c .tool_call_ids)" = "[\"toolu_c1\",\"toolu_c2\",\"toolu_c3\"]" ]'
check "an unknown hook is still denied/other" '[ "$(berow denied/other | jq -c .tool_call_ids)" = "[\"toolu_c4\"]" ]'
check "every sub-class key passes the router alphabet" 'jq -r ".failures[].class" "$TMP/be.json" | grep -Ev "^(denied|suite|blocked|error|run_error|traj)/[A-Za-z0-9._:+-]{1,80}$" | wc -l | grep -qx 0'

echo "10. by-design exit codes come from the registry, not the failure count (HIMMEL-4853)"
# fixtures/exit-codes.jsonl: 14 non-zero Bash results. Before the registry all 14 were failures (12 error + 2 suite).
S10=4853c1a5-0000-4000-8000-000000000001
cp "$FX/exit-codes.jsonl" "$TMP/$S10.jsonl"
digest "$TMP/$S10.jsonl" >"$TMP/ec.json" 2>"$TMP/ec.err" || bad "digest of exit-codes.jsonl exits 0: $(head -c 300 "$TMP/ec.err")"
check "result and retry rcs are counted apart: 7 result, 2 retry" 'jq -e ".metrics.ok_result == 7 and .metrics.ok_retry == 2" "$TMP/ec.json" >/dev/null'
check "only the 5 real failures stay: a check-ci 1, an unlisted rc, a refusal, an unregistered script and a suite red" 'jq -e ".metrics.fail_error == 4 and .metrics.fail_suite == 1 and ([.failures[].count] | add) == 5" "$TMP/ec.json" >/dev/null'
check "quiet-run 75 (a suite run) is a retry, the same suite's exit 1 is still suite/other" 'jq -e "([.by_design[] | select(.script == \"quiet-run.sh\")] | .[0] | [.rc, .class, .count]) == [\"75\",\"retry\",1] and ([.failures[] | select(.class == \"suite/other\")] | .[0].count) == 1" "$TMP/ec.json" >/dev/null'
check "by_design rows carry script, rc, class and count only" 'jq -e "[.by_design[] | keys | join(\",\")] | unique == [\"class,count,rc,script\"]" "$TMP/ec.json" >/dev/null'
check "an rc listed by only one of two named scripts takes the class of the script that lists it" 'jq -e "([.by_design[] | select(.script == \"check-ci.sh\" and .rc == \"3\")] | .[0].count) == 2 and ([.by_design[] | select(.script == \"queue-lock.sh\" and .rc == \"11\")] | .[0].count) == 2" "$TMP/ec.json" >/dev/null'
check "a refusal rc (merge-on-green 17) and an unlisted rc (check-ci 9) stay error/Bash" '[ "$(jq "[.failures[] | select(.class == \"error/Bash\")] | .[0].count" "$TMP/ec.json")" = 4 ]'
check "no failure row exists for a result or retry rc, so the router never sees one" 'jq -e "[.failures[] | select(.failure == \"error\" or .failure == \"suite\")] | map(.count) | add == 5" "$TMP/ec.json" >/dev/null'

echo "test-leg-digest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
