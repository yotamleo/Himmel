#!/usr/bin/env bash
# Smoke test for the /overnight-shift dispatch-loop plumbing (HIMMEL-2724
# lead 4, HIMMEL-2722 item 1).
#
# .claude/commands/overnight-shift.md is a markdown command, not a script —
# no harness executes it directly. This test exercises the two pieces of
# plumbing the runbook now documents at each dispatch point: a
# stop-marker.sh poll gating whether a ticket starts, and fanout-plan.mjs
# resolving an explicit model per ticket. It reproduces the runbook's own
# shell shape (`if bash stop-marker.sh check; then halt; fi`, then
# `node fanout-plan.mjs items.json`) rather than re-deriving new logic —
# the two scripts are the tested unit here, not a copy of them. The plan is
# resolved ONCE up front and the simulated loop consumes the model it named
# for each id at dispatch time (CR round 2, codex-2) — not checked
# after the fact, which could pass even if the loop ignored routing.
#
# Covers (acceptance):
#   1. Marker SET before the loop starts -> zero dispatches, a
#      "halted by /stop"-shaped line naming EVERY skipped ticket ID
#      (CR round 2, codex-1), not just the first.
#   2. Marker ABSENT -> the loop proceeds for every ticket, consuming the
#      model fanout-plan.mjs resolved for that exact id.
#   3. Marker set MID-LOOP (armed after ticket 1's poll passes) -> ticket 1
#      dispatches (with its model), ticket 2's poll halts before it starts
#      and names it — proves the poll is PER-DISPATCH, not just a
#      one-time check before the loop.
#
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+ —
# no .ps1 twin needed, same as the sibling test-stop-marker.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
STOP_MARKER="$SCRIPT_DIR/stop-marker.sh"
FANOUT_PLAN="$REPO_ROOT/scripts/lanes/fanout-plan.mjs"

PASS=0; FAIL=0; TMP_ROOT=""
# shellcheck disable=SC2329,SC2317
cleanup() {
    if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
        rm -rf "$TMP_ROOT" 2>/dev/null || true
    fi
}
trap cleanup EXIT
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/dispatch-stop-poll.XXXXXX") || { echo "FATAL: mktemp -d failed" >&2; exit 1; }
if command -v cygpath >/dev/null 2>&1; then TMP_ROOT=$(cygpath -m "$TMP_ROOT"); fi
export OVERNIGHT_STOP_DIR="$TMP_ROOT"

# HIMMEL-9002 pins an explicit lane override so it resolves to a DIFFERENT
# model than HIMMEL-9001's default (sonnet) — two identically-routed
# fixtures cannot distinguish "used my own resolved model" from "used the
# other ticket's" (CR round 3, codex-2).
ITEMS_FILE="$TMP_ROOT/items.json"
cat > "$ITEMS_FILE" <<'EOF'
[
  {"id": "HIMMEL-9001", "type": "implementation", "destructive": false, "effort": "medium", "why": "test ticket A"},
  {"id": "HIMMEL-9002", "type": "implementation", "destructive": false, "lane": "opus", "effort": "medium", "why": "test ticket B"}
]
EOF

# Resolve the plan ONCE, up front — the simulated loop below looks up each
# id's model from THIS, exactly as the runbook's step 4 resolves it once
# then dispatches from the resolved plan.
plan_json=$(node "$FANOUT_PLAN" "$ITEMS_FILE") || { echo "FATAL: fanout-plan.mjs exited non-zero: $plan_json" >&2; exit 1; }
fixture_model_9001=$(printf '%s' "$plan_json" | node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>{const p=JSON.parse(s).find(x=>x.id==="HIMMEL-9001");process.stdout.write(p?p.model:"")})')
fixture_model_9002=$(printf '%s' "$plan_json" | node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>{const p=JSON.parse(s).find(x=>x.id==="HIMMEL-9002");process.stdout.write(p?p.model:"")})')
if [ -n "$fixture_model_9001" ] && [ -n "$fixture_model_9002" ] && [ "$fixture_model_9001" != "$fixture_model_9002" ]; then
    pass "fixture tickets resolve to DISTINCT models ($fixture_model_9001 vs $fixture_model_9002) -- a swap is detectable"
else
    fail "expected distinct non-empty models for the two fixtures" "9001=$fixture_model_9001 9002=$fixture_model_9002"
fi

# model_for_id <id> -- print the plan's resolved model for <id>, empty if
# absent/malformed. A small node lookup rather than grep/sed: the plan is
# JSON, and PLAN_JSON is exported once so this can't drift from what the
# loop below actually consumes.
model_for_id() {
    PLAN_JSON="$plan_json" QUERY_ID="$1" node -e '
        let s = process.env.PLAN_JSON || "[]";
        let plan;
        try { plan = JSON.parse(s); } catch { plan = []; }
        const entry = plan.find(p => p.id === process.env.QUERY_ID);
        process.stdout.write(entry && typeof entry.model === "string" ? entry.model : "");
    '
}

# The dispatch-loop shape overnight-shift.md step 4 documents: poll, then
# (only if clear) dispatch that one ticket using the plan's resolved model.
# Returns via globals so the test can inspect what "dispatched" (and with
# which model) without an actual Agent call.
#   DISPATCHED       space-separated ticket ids that were dispatched
#   DISPATCHED_MODELS space-separated "id=model" pairs, in dispatch order —
#                     built from model_for_id AT dispatch time, so a loop
#                     that ignored the resolved model (or used the wrong
#                     id's) shows up here, not just a total count.
#   HALT_LINE         the halt message, when the marker stops the loop —
#                     names EVERY ticket id not yet dispatched, not just
#                     the one whose poll tripped.
DISPATCHED=""
DISPATCHED_MODELS=""
HALT_LINE=""
run_dispatch_loop() {
    DISPATCHED=""
    DISPATCHED_MODELS=""
    HALT_LINE=""
    local ids="$1"  # space-separated ticket ids, in order
    local mid_loop_arm="${2:-}"  # ticket id after which to SET the marker (simulates a concurrent /stop)
    local id remaining model
    local -a id_array
    # shellcheck disable=SC2206  # deliberate word-splitting of a space-separated id list
    id_array=($ids)
    local i=0
    while [ "$i" -lt "${#id_array[@]}" ]; do
        id="${id_array[$i]}"
        if bash "$STOP_MARKER" check; then
            remaining="${id_array[*]:$i}"
            HALT_LINE="stop marker armed — blocked (reason: stop marker armed): $remaining"
            return 0
        fi
        model=$(model_for_id "$id")
        DISPATCHED="$DISPATCHED $id"
        DISPATCHED_MODELS="$DISPATCHED_MODELS $id=$model"
        if [ "$id" = "$mid_loop_arm" ]; then
            bash "$STOP_MARKER" set >/dev/null 2>&1
        fi
        i=$((i + 1))
    done
}

# Test 1: marker SET before the loop starts -> zero dispatches ------------
echo "TEST: marker set before the loop -> zero dispatches, halted line names every skipped ticket"
bash "$STOP_MARKER" set >/dev/null 2>&1
run_dispatch_loop "HIMMEL-9001 HIMMEL-9002"
if [ -z "$DISPATCHED" ]; then pass "zero dispatches with marker armed"; else fail "expected zero dispatches" "got:$DISPATCHED"; fi
case "$HALT_LINE" in
    *"blocked"*"stop marker armed"*) pass "halted line names the documented reporting reason (blocked / stop marker armed)" ;;
    *) fail "expected 'blocked' and 'stop marker armed' in the halt line" "got: $HALT_LINE" ;;
esac
case "$HALT_LINE" in
    *"HIMMEL-9001"*"HIMMEL-9002"*) pass "halted line names BOTH skipped ticket IDs" ;;
    *) fail "expected both HIMMEL-9001 and HIMMEL-9002 named in the halt line" "got: $HALT_LINE" ;;
esac
bash "$STOP_MARKER" clear >/dev/null 2>&1

# Test 2: marker ABSENT -> every ticket dispatches, consuming its model ---
echo "TEST: marker absent -> N dispatches, each consuming the model fanout-plan.mjs resolved for its id"
run_dispatch_loop "HIMMEL-9001 HIMMEL-9002"
if [ "$DISPATCHED" = " HIMMEL-9001 HIMMEL-9002" ]; then
    pass "both tickets dispatched"
else
    fail "expected both tickets dispatched" "got:$DISPATCHED"
fi
if [ -z "$HALT_LINE" ]; then pass "no halt line when marker absent"; else fail "unexpected halt line" "$HALT_LINE"; fi

expected_9001="HIMMEL-9001=$(model_for_id HIMMEL-9001)"
expected_9002="HIMMEL-9002=$(model_for_id HIMMEL-9002)"
case "$DISPATCHED_MODELS" in
    *"$expected_9001"*"$expected_9002"*)
        pass "dispatch loop consumed the plan's model for each dispatched id" ;;
    *)
        fail "expected '$expected_9001' and '$expected_9002' in dispatch order" "got: $DISPATCHED_MODELS" ;;
esac
if [ -n "$(model_for_id HIMMEL-9001)" ] && [ -n "$(model_for_id HIMMEL-9002)" ]; then
    pass "fanout-plan.mjs named a non-empty model for both ids"
else
    fail "expected a non-empty model for both ids" "9001=$(model_for_id HIMMEL-9001) 9002=$(model_for_id HIMMEL-9002)"
fi

# Test 3: marker armed MID-LOOP -> per-dispatch poll, not one-time --------
echo "TEST: marker armed after ticket 1's poll -> ticket 2's poll halts before it starts"
run_dispatch_loop "HIMMEL-9001 HIMMEL-9002" "HIMMEL-9001"
if [ "$DISPATCHED" = " HIMMEL-9001" ]; then
    pass "ticket 1 dispatched before the marker was armed"
else
    fail "expected only ticket 1 dispatched" "got:$DISPATCHED"
fi
case "$DISPATCHED_MODELS" in
    *"$expected_9001"*) pass "ticket 1's dispatch consumed its resolved model" ;;
    *) fail "expected '$expected_9001' recorded" "got: $DISPATCHED_MODELS" ;;
esac
case "$HALT_LINE" in
    *"HIMMEL-9002"*) pass "halt line names the ticket that did not start" ;;
    *) fail "expected halt line to name HIMMEL-9002" "got: $HALT_LINE" ;;
esac
bash "$STOP_MARKER" clear >/dev/null 2>&1

# Summary --------------------------------------------------------------
echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
