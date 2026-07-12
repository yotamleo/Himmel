#!/usr/bin/env bash
# Smoke test for scripts/hooks/refresh-where-are-we-on-end.sh (HIMMEL-572).
#
# Usage: bash scripts/hooks/test-refresh-where-are-we-on-end.sh
# Hermetic: HIMMEL_REPO points at the real repo (so resolve-node works) but the
# STATE DIR is a temp override and the refresh is a STUB — no real jira/gh/git
# network, no writes to the repo's own .where-are-we.
#
# Exit: 0 = all cases pass, 1 = at least one failed.
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HOOK_DIR/refresh-where-are-we-on-end.sh"
REPO_ROOT="$(cd "$HOOK_DIR/../.." && pwd)"
[ -x "$HOOK" ] || chmod +x "$HOOK" 2>/dev/null || true

FAILED=0
PASSED=0
pass() { echo "PASS $1"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- Case 1: OFF → no refresh, exit 0 ---------------------------------------
state1="$TMP/s1"; mkdir -p "$state1"
sentinel1="$TMP/sentinel1"
HIMMEL_REPO="$REPO_ROOT" WHERE_ARE_WE_STATE_DIR="$state1" \
    HIMMEL_WHERE_ARE_WE="" \
    HIMMEL_WHERE_ARE_WE_COLLECT_CMD="touch '$sentinel1'" \
    bash "$HOOK" </dev/null >/dev/null 2>&1; rc1=$?
# Gate now runs in the detached child (HIMMEL-636) — give it time to (not) fire
# before asserting the refresh stayed off; a regressed gate would touch by now.
sleep 0.5
if [ "$rc1" = 0 ] && [ ! -e "$sentinel1" ]; then
    pass "OFF -> no refresh, exit 0"
else
    sv=no; [ -e "$sentinel1" ] && sv=yes
    fail "OFF -> expected no refresh+0, got rc=$rc1 sentinel=$sv"
fi

# --- Case 2: ON → refresh runs DETACHED + marker stamped on success ----------
# The hook returns immediately (non-blocking); the detached child runs the
# refresh then stamps the marker. Poll for both (HIMMEL-576 detach conversion).
state2="$TMP/s2"; mkdir -p "$state2"
sentinel2="$TMP/sentinel2"
HIMMEL_REPO="$REPO_ROOT" WHERE_ARE_WE_STATE_DIR="$state2" \
    HIMMEL_WHERE_ARE_WE=1 \
    HIMMEL_WHERE_ARE_WE_COLLECT_CMD="touch '$sentinel2'" \
    bash "$HOOK" </dev/null >/dev/null 2>&1; rc2=$?
i=0; while { [ ! -e "$sentinel2" ] || [ ! -e "$state2/.refreshed-at" ]; } && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
if [ "$rc2" = 0 ] && [ -e "$sentinel2" ] && [ -e "$state2/.refreshed-at" ]; then
    pass "ON -> detached refresh ran + marker stamped, exit 0"
else
    sv=no; [ -e "$sentinel2" ] && sv=yes
    mv=no; [ -e "$state2/.refreshed-at" ] && mv=yes
    fail "ON -> expected detached refresh + marker, rc=$rc2 sentinel=$sv marker=$mv"
fi

# --- Case 2b: OFF via falsy grammar ('false') -------------------------------
state2b="$TMP/s2b"; mkdir -p "$state2b"
sentinel2b="$TMP/sentinel2b"
HIMMEL_REPO="$REPO_ROOT" WHERE_ARE_WE_STATE_DIR="$state2b" \
    HIMMEL_WHERE_ARE_WE=false \
    HIMMEL_WHERE_ARE_WE_COLLECT_CMD="touch '$sentinel2b'" \
    bash "$HOOK" </dev/null >/dev/null 2>&1; rc2b=$?
sleep 0.5   # gate runs in the detached child now — barrier before the negative check
if [ "$rc2b" = 0 ] && [ ! -e "$sentinel2b" ]; then
    pass "OFF via 'false' grammar -> no refresh, exit 0"
else
    fail "OFF via 'false' -> expected no refresh+0, got rc=$rc2b"
fi

# --- Case 3: ON but refresh FAILS → marker NOT stamped (no freshness lie) ----
# Detached: give the child a moment to run+fail, then assert the marker is absent.
state3="$TMP/s3"; mkdir -p "$state3"
HIMMEL_REPO="$REPO_ROOT" WHERE_ARE_WE_STATE_DIR="$state3" \
    HIMMEL_WHERE_ARE_WE=1 \
    HIMMEL_WHERE_ARE_WE_COLLECT_CMD="exit 1" \
    bash "$HOOK" </dev/null >/dev/null 2>&1; rc3=$?
sleep 0.5
if [ "$rc3" = 0 ] && [ ! -e "$state3/.refreshed-at" ]; then
    pass "failed refresh -> marker NOT stamped (stays stale), exit 0"
else
    mv=no; [ -e "$state3/.refreshed-at" ] && mv=yes
    fail "failed refresh -> expected no marker, rc=$rc3 marker=$mv"
fi

# --- Case 4: ON but broken root → still exit 0 (fail-open) -------------------
state4="$TMP/s4"; mkdir -p "$state4"
HIMMEL_REPO="$TMP/nonexistent-repo" WHERE_ARE_WE_STATE_DIR="$state4" \
    HIMMEL_WHERE_ARE_WE=1 bash "$HOOK" </dev/null >/dev/null 2>&1; rc4=$?
if [ "$rc4" = 0 ]; then
    pass "broken root -> fail-open exit 0"
else
    fail "broken root -> expected exit 0, got rc=$rc4"
fi

# --- Case 5: full-body detach keeps the PARENT fast (HIMMEL-636) -------------
# The discriminating test: inject latency into the PREAMBLE (HIMMEL_WHERE_ARE_WE_TEST_DELAY
# sleeps at the start of the child body) — NOT into the collect, which was already
# detached pre-HIMMEL-636 (so a slow COLLECT_CMD would pass on the OLD code too).
# With the full-body detach the preamble runs in the detached child, so the parent
# returns immediately; a regression that un-detached the body would run this 12s
# delay in the FOREGROUND and blow the <10s assertion. Then confirm the child still
# completes async (sentinel + marker) AFTER the delay. Skipped where GNU coreutils
# `timeout` is absent (stock macOS); the detach primitive is covered portably by
# scripts/lib/test-detach.sh.
if command -v timeout >/dev/null 2>&1; then
    state5="$TMP/s5"; mkdir -p "$state5"
    sentinel5="$TMP/sentinel5"
    _t0=$(date +%s)
    timeout 20 env HIMMEL_REPO="$REPO_ROOT" WHERE_ARE_WE_STATE_DIR="$state5" \
        HIMMEL_WHERE_ARE_WE=1 \
        HIMMEL_WHERE_ARE_WE_TEST_DELAY=12 \
        HIMMEL_WHERE_ARE_WE_COLLECT_CMD="touch '$sentinel5'" \
        bash "$HOOK" </dev/null >/dev/null 2>&1; rc5=$?
    _elapsed=$(( $(date +%s) - _t0 ))
    # Wait out the 12s preamble delay, then confirm the child completed.
    i=0; while { [ ! -e "$sentinel5" ] || [ ! -e "$state5/.refreshed-at" ]; } && [ "$i" -lt 250 ]; do sleep 0.1; i=$((i + 1)); done
    if [ "$rc5" = 0 ] && [ "$_elapsed" -lt 10 ] && [ -e "$sentinel5" ] && [ -e "$state5/.refreshed-at" ]; then
        pass "slow PREAMBLE -> parent returns fast AND child completes async"
    else
        sv=no; [ -e "$sentinel5" ] && sv=yes
        mv=no; [ -e "$state5/.refreshed-at" ] && mv=yes
        fail "slow preamble -> rc=$rc5 elapsed=${_elapsed}s sentinel=$sv marker=$mv"
    fi
else
    echo "SKIP slow-preamble-fast-return (no GNU coreutils timeout on this runner)"
fi

echo "---"
echo "PASSED=$PASSED FAILED=$FAILED"
[ "$FAILED" = 0 ]
