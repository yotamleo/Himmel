#!/usr/bin/env bash
# scripts/eval/leg-digest/test-leg-ledger.sh - hermetic suite for the leg ledgers (HIMMEL-4670 P2).
# Scratch ledgers only; never ~/.himmel. No model call, no bank.
#  1. record writes one leg-failures row per digest class and one leg-trajectory eval-runs row; both validate;
#  2. idempotence by session: a second run, and a run after a crash between writes, append only what is missing;
#  3. the leg-failures validator refuses unknown keys, free-text keys, a bad class and more than five ids;
#  4. canary: no journal text reaches either ledger or the digest file (spec 6.1);
#  5. an inconclusive digest still writes a valid eval-runs row; a later ok run supersedes it;
#  6. backfill --since takes only leg-titled main journals from that date, skips a salus root, and is idempotent.
#
# check() evals its condition, so the single quotes are deliberate.
# shellcheck disable=SC2016,SC2034
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
DIG="$HERE/leg-digest.ts"
LL="$HERE/leg_ledger.py"
EVR="$HERE/../lib/eval_runs.py"
FX="$HERE/fixtures"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/leg-ledger-test.XXXXXX")" || { echo "test-leg-ledger: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
# Never the live ledgers, whatever a case forgets to pass.
export HIMMEL_EVAL_RUNS_LEDGER="$TMP/never-eval.jsonl"
export HIMMEL_LEG_FAILURES_LEDGER="$TMP/never-fail.jsonl"
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
absent() { grep -q "$@"; [ $? = 1 ]; }
lines() { if [ -f "$1" ]; then grep -c . "$1"; else echo 0; fi; }

SID=4670c1a5-0000-4000-8000-000000000001
FL="$TMP/fail.jsonl"; EL="$TMP/eval.jsonl"; ST="$TMP/state"
cp "$FX/classes.jsonl" "$TMP/$SID.jsonl"
bun "$DIG" --transcript "$TMP/$SID.jsonl" --denials-ledger "$FX/classifier-denials.jsonl" >"$TMP/digest.json" 2>/dev/null || bad "the P1 digest exits 0"
rec() { python3 "$LL" record --failures-ledger "$FL" --eval-ledger "$EL" --state-dir "$ST" "$@"; }

echo "1. record: leg-failures rows and the leg-trajectory eval-runs row"
rec --digest "$TMP/digest.json" --leg N1373 --ticket HIMMEL-4670 --console demo-console --pr 1990 --doc himmel/x.md >"$TMP/rec1.out" 2>&1 || bad "record exits 0: $(head -c 300 "$TMP/rec1.out")"
check "one leg-failures row per digest class" '[ "$(lines "$FL")" = "$(jq ".failures | length" "$TMP/digest.json")" ] && [ "$(lines "$FL")" -gt 10 ]'
check "one eval-runs row" '[ "$(lines "$EL")" = 1 ]'
check "validate passes on the leg-failures ledger" 'python3 "$LL" validate "$FL" >/dev/null'
check "validate passes on the eval-runs ledger" 'python3 "$EVR" validate "$EL" >/dev/null'
check "a leg-failures row carries the envelope and the leg fields" 'jq -e "select(.class == \"denied/guard-pr-check-literal\") | .v == 1 and .kind == \"leg-failure\" and .source == \"scripts/eval/leg-digest/leg_ledger.py\" and (.host | length > 0) and (.ts | length > 0) and .session == \"$SID\" and .leg == \"N1373\" and .ticket == \"HIMMEL-4670\" and .console == \"demo-console\" and .pr == 1990 and .count == 2 and .identical_retry == 1 and .recovered == false" "$FL" >/dev/null'
check "a suite row keeps final_red" 'jq -e "select(.class == \"suite/test-eval-runs.sh\") | .final_red == true" "$FL" >/dev/null'
check "the eval-runs row is the observational leg-trajectory row keyed by session" 'jq -e ".eval == \"leg-trajectory\" and .run_id == \"$SID\" and .status == \"ok\" and .meta.observational == true and .meta.leg == \"N1373\" and .meta.pr == 1990 and .n == 3 and .reps == 1 and .cases == null and .config.digest_v == 1 and .model == \"claude-opus-5-5\"" "$EL" >/dev/null'
check "its metrics are the digest metrics, booleans as 1/0" 'jq -e ".metrics | .fail_denied == 10 and .turns == 3 and .identical_denied_retries == 1 and has(\"red_before_green\") and has(\"verify_before_claim\")" "$EL" >/dev/null'
check "the digest file is written last and the row points at it" '[ -f "$ST/$SID.json" ] && [ "$(jq -r .artifact "$EL")" = "$ST/$SID.json" ]'

echo "2. idempotence by session id"
rec --digest "$TMP/digest.json" --leg N1373 >"$TMP/rec2.out" 2>&1 || bad "the second record exits 0"
check "a second run appends 0 rows to either ledger" '[ "$(lines "$FL")" = "$(jq ".failures | length" "$TMP/digest.json")" ] && [ "$(lines "$EL")" = 1 ]'
rm -f "$ST/$SID.json"
head -n 5 "$FL" >"$TMP/f5" && mv "$TMP/f5" "$FL"
: >"$EL"
rec --digest "$TMP/digest.json" --leg N1373 >"$TMP/rec3.out" 2>&1 || bad "the healing record exits 0"
check "a crash after five rows heals: the missing rows and the eval row, nothing doubled" '[ "$(lines "$FL")" = "$(jq ".failures | length" "$TMP/digest.json")" ] && [ "$(lines "$EL")" = 1 ] && [ -z "$(jq -r "[.agent.id, .class] | join(\" \")" "$FL" | sort | uniq -d)" ]'
rm -f "$ST/$SID.json"
rec --digest "$TMP/digest.json" --leg N1373 >/dev/null 2>&1
check "a crash before the digest file only rewrites the marker" '[ "$(lines "$FL")" = "$(jq ".failures | length" "$TMP/digest.json")" ] && [ "$(lines "$EL")" = 1 ] && [ -f "$ST/$SID.json" ]'

echo "3. the leg-failures validator"
row1="$(head -n 1 "$FL")"
vrow() { printf '%s\n' "$1" >"$TMP/v.jsonl"; python3 "$LL" validate "$TMP/v.jsonl" >/dev/null; }
check "a valid row passes" 'vrow "$row1"'
check "an unknown key fails" '! vrow "$(jq -c ". + {extra: 1}" <<<"$row1")"'
for k in content command message prompt path; do
  check "a $k field fails" '! vrow "$(jq -c --arg k "$k" ". + {(\$k): \"x\"}" <<<"$row1")"'
done
check "a free-text class fails" '! vrow "$(jq -c ".class = \"denied/run rm -rf\"" <<<"$row1")"'
check "a class whose prefix is not its failure fails" '! vrow "$(jq -c ".class = \"suite/other\" | .failure = \"denied\"" <<<"$row1")"'
check "more than five tool_call_ids fail" '! vrow "$(jq -c ".tool_call_ids = [\"t1\",\"t2\",\"t3\",\"t4\",\"t5\",\"t6\"]" <<<"$row1")"'
check "a non-UUID session fails" '! vrow "$(jq -c ".session = \"../x\"" <<<"$row1")"'
check "a missing envelope field fails" '! vrow "$(jq -c "del(.source)" <<<"$row1")"'
check "a not-JSON line fails" '! vrow "not json"'

echo "4. canary (spec 6.1)"
CS=4670c1a5-0000-4000-8000-0000000000cc
cp "$FX/canary.jsonl" "$TMP/$CS.jsonl"
bun "$DIG" --transcript "$TMP/$CS.jsonl" --denials-ledger "$FX/classifier-denials.jsonl" >"$TMP/canary.json" 2>/dev/null
rec --digest "$TMP/canary.json" >"$TMP/canary.out" 2>&1 || bad "the canary record exits 0"
check "the canary run wrote rows" '[ "$(grep -c "$CS" "$FL")" -gt 5 ]'
check "the canary appears in no ledger, digest file or output" 'absent CANARY4670zq "$FL" "$EL" "$ST/$CS.json" "$TMP/canary.out"'

echo "5. inconclusive, then superseded"
IS=4670c1a5-0000-4000-8000-0000000000dd
bun "$DIG" --transcript "$TMP/$IS.jsonl" >"$TMP/inc.json" 2>/dev/null
rec --digest "$TMP/inc.json" >/dev/null 2>&1 || bad "the inconclusive record exits 0"
check "an inconclusive digest writes a valid eval-runs row with null metrics" 'python3 "$EVR" validate "$EL" >/dev/null && jq -e "select(.run_id == \"$IS\") | .status == \"inconclusive\" and .metrics.turns == null" "$EL" >/dev/null'
rec --digest "$TMP/inc.json" >/dev/null 2>&1
check "a second inconclusive run appends nothing" '[ "$(grep -c "\"run_id\":\"$IS\"" "$EL")" = 1 ]'
cp "$FX/classes.jsonl" "$TMP/$IS.jsonl"
bun "$DIG" --transcript "$TMP/$IS.jsonl" --denials-ledger "$FX/classifier-denials.jsonl" >"$TMP/inc2.json" 2>/dev/null
rec --digest "$TMP/inc2.json" >/dev/null 2>&1
check "a later ok run supersedes it with one more row" '[ "$(grep -c "\"run_id\":\"$IS\"" "$EL")" = 2 ] && [ "$(jq -r "select(.run_id == \"$IS\") | .status" "$EL" | tail -n 1)" = ok ]'
rec --digest "$TMP/inc2.json" >/dev/null 2>&1
check "and an ok run is final" '[ "$(grep -c "\"run_id\":\"$IS\"" "$EL")" = 2 ]'

echo "6. backfill --since"
P="$TMP/projects"; mkdir -p "$P/-home-x-himmel" "$P/-home-x-other"
B1=4670b000-0000-4000-8000-000000000001; B2=4670b000-0000-4000-8000-000000000002
B3=4670b000-0000-4000-8000-000000000003; B4=4670b000-0000-4000-8000-000000000004
title() { printf '{"type":"custom-title","customTitle":"%s","sessionId":"%s"}\n' "$1" "$2"; }
{ title HIMMEL-4670-N1365-agui-spec "$B1"; sed "s#\"sessionId\"#\"cwd\": \"$TMP/w\", \"sessionId\"#" "$FX/classes.jsonl"; } >"$P/-home-x-himmel/$B1.jsonl"
B5=4670b000-0000-4000-8000-000000000005
{ title HIMMEL-5-N6-nocwd "$B5"; cat "$FX/classes.jsonl"; } >"$P/-home-x-himmel/$B5.jsonl"
cat "$FX/classes.jsonl" >"$P/-home-x-himmel/$B2.jsonl"
{ title HIMMEL-1-N9-old "$B3"; sed 's/2026-10-06T/2026-09-01T/g' "$FX/classes.jsonl"; } >"$P/-home-x-himmel/$B3.jsonl"
mkdir -p "$TMP/salus-root" && : >"$TMP/salus-root/.salus"
{ title HIMMEL-2-N8-phi "$B4"; sed "s#\"sessionId\"#\"cwd\": \"$TMP/salus-root/w\", \"sessionId\"#" "$FX/classes.jsonl"; } >"$P/-home-x-other/$B4.jsonl"
mkdir -p "$P/-home-x-himmel/$B1/subagents"
{ title HIMMEL-3-N7-sub "$B1"; cat "$FX/classes.jsonl"; } >"$P/-home-x-himmel/$B1/subagents/agent-x.jsonl"
BF="$TMP/bf-fail.jsonl"; BE="$TMP/bf-eval.jsonl"; BS="$TMP/bf-state"
bf() { python3 "$LL" backfill --since 2026-10-01 --projects "$P" --denials-ledger "$FX/classifier-denials.jsonl" --failures-ledger "$BF" --eval-ledger "$BE" --state-dir "$BS"; }
bf >"$TMP/bf1.out" 2>&1 || bad "backfill exits 0: $(head -c 300 "$TMP/bf1.out")"
check "backfill digests only the leg-titled main journal from the window" '[ "$(jq -r .run_id "$BE" | tr "\n" " ")" = "$B1 " ]'
check "the leg and ticket come from the title, marked backfill" 'jq -e ".meta.leg == \"N1365\" and .meta.ticket == \"HIMMEL-4670\" and .meta.backfill == true and .meta.observational == true" "$BE" >/dev/null'
check "the salus-rooted and the cwd-less journals are refused and counted" 'grep -q "salus=2" "$TMP/bf1.out" && absent "$B4" "$BF" "$BE" && absent "$B5" "$BF" "$BE"'
check "backfill reports its row counts" 'grep -qE "^backfill: .*legs=1 .*failures\+=[1-9][0-9]* eval\+=1" "$TMP/bf1.out"'
check "both backfill ledgers validate" 'python3 "$LL" validate "$BF" >/dev/null && python3 "$EVR" validate "$BE" >/dev/null'
n1="$(lines "$BF")"
bf >"$TMP/bf2.out" 2>&1
check "a second backfill appends 0 rows" '[ "$(lines "$BE")" = 1 ] && [ "$(lines "$BF")" = "$n1" ] && grep -qE "failures\+=0 eval\+=0" "$TMP/bf2.out"'
mkdir -p "$TMP/h/.config/claude-glm/phi-roots"
HOME="$TMP/h" python3 "$LL" backfill --since 2026-10-01 --projects "$P" --denials-ledger "$FX/classifier-denials.jsonl" --failures-ledger "$TMP/bf3-f.jsonl" --eval-ledger "$TMP/bf3-e.jsonl" --state-dir "$TMP/bf3-s" >"$TMP/bf3.out" 2>&1; rc3=$?
check "an unreadable PHI-roots file fails closed: nonzero, nothing written" '[ "$rc3" != 0 ] && [ ! -s "$TMP/bf3-e.jsonl" ]'
check "a usage error exits 2" 'python3 "$LL" backfill >/dev/null 2>&1; [ $? = 2 ]'
check "the writer spawns only bun, never a model CLI" 'absent -E "\"(claude|codex|gemini)\"" "$LL"'

echo "7. --digest-error: a closed-vocabulary reason in meta (HIMMEL-4670 P3)"
DE=4670c1a5-0000-4000-8000-0000000000de; DX=4670c1a5-0000-4000-8000-0000000000df
printf '{"digest_v":1,"mapper_v":1,"trajectory_v":null,"session":"%s","status":"inconclusive","model":null,"metrics":{},"failures":[]}\n' "$DE" >"$TMP/de.json"
rec --digest "$TMP/de.json" --digest-error timeout >/dev/null 2>&1
check "an accepted reason lands in meta.digest_error" 'jq -e "select(.run_id == \"$DE\") | .status == \"inconclusive\" and .meta.digest_error == \"timeout\"" "$EL" >/dev/null'
sed "s/$DE/$DX/" "$TMP/de.json" >"$TMP/dx.json"
python3 "$LL" record --failures-ledger "$FL" --eval-ledger "$EL" --state-dir "$ST" --digest "$TMP/dx.json" --digest-error "boom at line 3" >/dev/null 2>&1; rcx=$?
check "an unknown reason is refused and writes no row" '[ "$rcx" != 0 ] && absent "$DX" "$EL" && [ ! -f "$ST/$DX.json" ]'

echo "8. a partial-to-ok upgrade replaces the session's rows (HIMMEL-4701)"
US=4670c1a5-0000-4000-8000-0000000000e1; OS=4670c1a5-0000-4000-8000-0000000000e2
UF="$TMP/up-fail.jsonl"; UE="$TMP/up-eval.jsonl"; US_ST="$TMP/up-state"
urec() { python3 "$LL" record --failures-ledger "$UF" --eval-ledger "$UE" --state-dir "$US_ST" "$@"; }
jq -c --arg s "$US" '.session = $s | .status = "partial" | .failures = [(.failures | map(select(.failure == "denied")) | .[0] | .count = 99), (.failures | map(select(.failure == "denied")) | .[0] | .class = "denied/stale-class")]' "$TMP/digest.json" >"$TMP/up-partial.json"
jq -c --arg s "$US" '.session = $s' "$TMP/digest.json" >"$TMP/up-ok.json"
jq -c --arg s "$OS" '.session = $s | .status = "partial" | .failures = (.failures | map(select(.failure == "denied")) | .[0:1])' "$TMP/digest.json" >"$TMP/other-partial.json"
urec --digest "$TMP/other-partial.json" >/dev/null 2>&1
urec --digest "$TMP/up-partial.json" >/dev/null 2>&1 || bad "the partial record exits 0"
check "the partial digest wrote its two rows" '[ "$(grep -c "\"session\":\"$US\"" "$UF")" = 2 ]'
urec --digest "$TMP/up-ok.json" >"$TMP/up.out" 2>&1 || bad "the upgrading record exits 0: $(head -c 300 "$TMP/up.out")"
check "after the upgrade the session has exactly the ok digest rows" '[ "$(grep -c "\"session\":\"$US\"" "$UF")" = "$(jq ".failures | length" "$TMP/up-ok.json")" ]'
check "no stale class survives the upgrade" 'absent "denied/stale-class" "$UF"'
check "no stale count survives the upgrade" 'absent "\"count\":99" "$UF"'
check "another session's rows are untouched" '[ "$(grep -c "\"session\":\"$OS\"" "$UF")" = 1 ]'
check "the upgraded ledger still validates" 'python3 "$LL" validate "$UF" >/dev/null'
urec --digest "$TMP/up-ok.json" >/dev/null 2>&1
check "a second ok run changes nothing" '[ "$(grep -c "\"session\":\"$US\"" "$UF")" = "$(jq ".failures | length" "$TMP/up-ok.json")" ]'

echo "9. backfill reads the LAST title in the whole journal (HIMMEL-4701)"
P2="$TMP/projects2"; mkdir -p "$P2/-home-x-himmel"
T1=4670b000-0000-4000-8000-000000000011
{ title HIMMEL-1-N1-scratch "$T1"; sed "s#\"sessionId\"#\"cwd\": \"$TMP/w\", \"sessionId\"#" "$FX/classes.jsonl"; title HIMMEL-4701-N1418-late-title "$T1"; } >"$P2/-home-x-himmel/$T1.jsonl"
check "the fixture's final title sits past line 40" '[ "$(grep -n "late-title" "$P2/-home-x-himmel/$T1.jsonl" | cut -d: -f1)" -gt 40 ]'
python3 "$LL" backfill --since 2026-10-01 --projects "$P2" --denials-ledger "$FX/classifier-denials.jsonl" --failures-ledger "$TMP/t-fail.jsonl" --eval-ledger "$TMP/t-eval.jsonl" --state-dir "$TMP/t-state" >"$TMP/t.out" 2>&1 || bad "title backfill exits 0"
check "the title after line 40 wins: leg and ticket come from it" 'jq -e ".meta.leg == \"N1418\" and .meta.ticket == \"HIMMEL-4701\"" "$TMP/t-eval.jsonl" >/dev/null'

echo "10. backfill --live-minutes skips a still-live journal (HIMMEL-4699, HIMMEL-4701)"
P3="$TMP/projects3"; mkdir -p "$P3/-home-x-himmel"
L1=4670b000-0000-4000-8000-000000000021; L2=4670b000-0000-4000-8000-000000000022
NOW="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
{ title HIMMEL-4701-N1-live "$L1"; jq -c --arg n "$NOW" --arg c "$TMP/w" '.cwd = $c | if has("timestamp") then .timestamp = $n else . end' "$FX/classes.jsonl"; } >"$P3/-home-x-himmel/$L1.jsonl"
{ title HIMMEL-4701-N2-old "$L2"; sed "s#\"sessionId\"#\"cwd\": \"$TMP/w\", \"sessionId\"#" "$FX/classes.jsonl"; } >"$P3/-home-x-himmel/$L2.jsonl"
lbf() { python3 "$LL" backfill --since 2026-10-01 --projects "$P3" --denials-ledger "$FX/classifier-denials.jsonl" --failures-ledger "$TMP/l-fail.jsonl" --eval-ledger "$TMP/l-eval.jsonl" --state-dir "$TMP/l-state" "$@"; }
lbf >"$TMP/l1.out" 2>&1 || bad "live backfill exits 0: $(head -c 300 "$TMP/l1.out")"
check "the recent journal is counted live=1 and the old one is digested" 'grep -qE "legs=2 .*eval\+=1 live=1" "$TMP/l1.out" && [ "$(jq -r .run_id "$TMP/l-eval.jsonl")" = "$L2" ]'
check "the live journal has no marker and no rows in either ledger" '[ ! -e "$TMP/l-state/$L1.json" ] && absent "$L1" "$TMP/l-fail.jsonl" "$TMP/l-eval.jsonl"'
lbf --live-minutes 0 >"$TMP/l2.out" 2>&1
check "control: with the skip disabled (--live-minutes 0) the same journal is digested" 'grep -q "live=0" "$TMP/l2.out" && [ -f "$TMP/l-state/$L1.json" ] && grep -q "$L1" "$TMP/l-eval.jsonl"'

echo "test-leg-ledger: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
