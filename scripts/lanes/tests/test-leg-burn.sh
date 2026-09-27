#!/usr/bin/env bash
# scripts/lanes/tests/test-leg-burn.sh - suite for scripts/lanes/leg-burn.sh
# (HIMMEL-2830). Drives the real script against the checked-in 20-line
# transcript fixture, whose expected numbers are hand-computable from the file
# itself - see fixtures/leg-burn-sample.jsonl:
#   msg_A  text row + tool_use row, usage 3 + 1000 + 200 = 1203 ctx, 50 out
#   msg_B  text only,               usage 1 + 2000 +   0 = 2001 ctx, 100 out
#   msg_C  two tool_use rows,       usage 0 +  500 +  50 =  550 ctx, 25 out
#   msg_D  text only,               usage 0 +  100 +   0 =  100 ctx, 10 out
#   => calls 4, ctx 3854, avg 963, first 1203, out 185, compactions 2,
#      text-only 2 (B and D; A is NOT text-only - its tool_use is in a
#      SECOND row under the same message id, which is exactly the trap this
#      suite exists to pin).
#
#   HIMMEL-2987 price-weighted fields (weights: cache-read 0.1, cache-create
#   1.25, input 1, output 5):
#     cache-read sum  = 1000+2000+500+100 = 3600 -> "3.6k"
#     cache-create sum = 200+0+50+0       =  250 -> "250"
#     input sum         = 3+1+0+0         =    4 -> "4"
#     cost-eq = 4*1 + 3600*0.1 + 250*1.25 + 185*5
#             = 4 + 360 + 312.5 + 925 = 1601.5 -> "1.6k"
#     floor-share = first-turn(1203) * calls(4) / cache-read(3600) * 100
#                 = 133.7%
#     cache-health = cache-read(3600) / (input(4) + cache-read(3600)) * 100
#                  = 99.88901...% -> 99.9%
#     compaction-rewarm: 2 compact_boundary markers; the first NEW message
#     after each is msg_C (ctx 550) then msg_D (ctx 100), mean 325 * 2 = 650
#
# Platform guard: no .ps1 twin, by design - it drives leg-burn.sh, which is
# itself twin-less for the reason its own header gives.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
BURN="$HERE/../leg-burn.sh"
FIXTURE="$HERE/fixtures/leg-burn-sample.jsonl"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/leg-burn-test.XXXXXX")" || { echo "test-leg-burn: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL $1"; }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) pass "$1";; *) fail "$1: '$3' not in '$2'";; esac; }

# --- the whole line, pinned -------------------------------------------------
out=$(bash "$BURN" "$FIXTURE"); rc=$?
eq "fixture exits 0" "$rc" "0"
eq "one line, every field, hand-computed" "$out" \
   "leg-burn leg-burn-sample.jsonl: calls=4 avg-ctx=963 first-turn=1.2k out=185 compactions=2 text-only=2 cache-read=3.6k cache-create=250 input=4 cache-health=99.9% cost-eq=1.6k floor-share=133.7% compaction-rewarm=650"

# --- HIMMEL-2987: price-weighted fields --------------------------------------
has "cache-read sum" "$out" "cache-read=3.6k"
has "cache-create sum" "$out" "cache-create=250"
has "input sum" "$out" "input=4"
has "cache-health pct" "$out" "cache-health=99.9%"
has "cost-eq weighted sum" "$out" "cost-eq=1.6k"
has "floor-share pct" "$out" "floor-share=133.7%"
has "compaction-rewarm" "$out" "compaction-rewarm=650"

# env override: cache-read weight 0.1 -> 1 moves cost-eq from 1.6k to 4.8k
# (4 + 3600*1 + 312.5 + 925 = 4841.5 -> 4.8k) - pins that the weight is
# actually read from env, not hardcoded.
out_override=$(LEG_BURN_W_CACHE_READ=1 bash "$BURN" "$FIXTURE")
has "cache-read weight override changes cost-eq" "$out_override" "cost-eq=4.8k"

# --- HIMMEL-2996: --raw prints exact integers, default line untouched -------
# Only cache-read is >=1000 in this fixture (3600), so it's the one field
# where --raw visibly differs from the default (3.6k -> 3600); out/cache-create/
# input are already <1000 and print the same integer either way.
out_raw=$(bash "$BURN" --raw "$FIXTURE")
eq "--raw: same line except the four counters are exact integers" "$out_raw" \
   "leg-burn leg-burn-sample.jsonl: calls=4 avg-ctx=963 first-turn=1.2k out=185 compactions=2 text-only=2 cache-read=3600 cache-create=250 input=4 cache-health=99.9% cost-eq=1.6k floor-share=133.7% compaction-rewarm=650"
eq "default output matches --raw except the four k-rounded counters" "$out" \
   "leg-burn leg-burn-sample.jsonl: calls=4 avg-ctx=963 first-turn=1.2k out=185 compactions=2 text-only=2 cache-read=3.6k cache-create=250 input=4 cache-health=99.9% cost-eq=1.6k floor-share=133.7% compaction-rewarm=650"

out_raw_env=$(LEG_BURN_RAW=1 bash "$BURN" "$FIXTURE")
eq "LEG_BURN_RAW=1 env is equivalent to --raw" "$out_raw_env" "$out_raw"

# --- the dedupe is the point ------------------------------------------------
# 6 assistant ROWS, 4 message IDS. Counting rows would report calls=6 and
# overstate the leg's cost; that is the error leg-burn exists to prevent.
rows=$(grep -c '"type":"assistant"' "$FIXTURE")
eq "the fixture really does have more rows than calls" "$rows" "6"
has "calls counts message ids, not rows" "$out" "calls=4"

# --- first-turn is the FIRST call, not the smallest or the last -------------
# msg_A (1203) is first; msg_D (100) is smaller and msg_C (550) is later.
has "first-turn is the first call's context" "$out" "first-turn=1.2k"

# --- session-name resolution ------------------------------------------------
mkdir -p "$TMP/projects/-some-repo"
cp "$FIXTURE" "$TMP/projects/-some-repo/fixture-0000.jsonl"
out2=$(LEG_BURN_PROJECTS_DIR="$TMP/projects" bash "$BURN" leg-burn-fixture-legN000); rc2=$?
eq "a bare session name resolves via the custom-title row" "$rc2" "0"
has "resolved transcript reports the same numbers" "$out2" "calls=4 avg-ctx=963"

out3=$(LEG_BURN_PROJECTS_DIR="$TMP/projects" bash "$BURN" no-such-leg 2>&1); rc3=$?
eq "an unknown session name exits 2" "$rc3" "2"
has "and says what it searched" "$out3" "no transcript found for session name"

# --- refusals ---------------------------------------------------------------
out4=$(bash "$BURN" "$TMP/nope.jsonl" 2>&1); rc4=$?
eq "a missing transcript path exits 2" "$rc4" "2"
has "and names the path" "$out4" "no such transcript"

out5=$(bash "$BURN" 2>&1); rc5=$?
eq "no argument exits 2" "$rc5" "2"
has "and prints usage" "$out5" "usage: leg-burn.sh"

# An arm that never ran is a real outcome and must not read as a free leg.
printf '%s\n' '{"type":"custom-title","customTitle":"empty-leg","sessionId":"x"}' \
              '{"type":"user","message":{"role":"user","content":"load the brief and continue"}}' \
              > "$TMP/empty.jsonl"
out6=$(bash "$BURN" "$TMP/empty.jsonl" 2>&1); rc6=$?
eq "a transcript with no assistant calls exits 3, not 0" "$rc6" "3"
has "and says the arm never ran" "$out6" "the arm never ran"

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
