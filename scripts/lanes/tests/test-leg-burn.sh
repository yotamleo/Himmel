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
# Platform guard: no .ps1 twin, by design - it drives leg-burn.sh, which is
# itself twin-less for the reason its own header gives.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
BURN="$HERE/../leg-burn.sh"
FIXTURE="$HERE/fixtures/leg-burn-sample.jsonl"
TMP="$(mktemp -d)"
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
   "leg-burn leg-burn-sample.jsonl: calls=4 avg-ctx=963 first-turn=1.2k out=185 compactions=2 text-only=2"

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
