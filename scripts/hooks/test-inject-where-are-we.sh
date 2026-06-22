#!/usr/bin/env bash
# Smoke test for scripts/hooks/inject-where-are-we.sh (HIMMEL-516).
#
# Usage: bash scripts/hooks/test-inject-where-are-we.sh
# Hermetic: HIMMEL_REPO points at the real repo (so dock.mjs resolves) but the
# STATE DIR is a temp override and the refresh is a STUB — no real jira/gh/git
# network, no writes to the repo's own .where-are-we.
#
# Exit: 0 = all cases pass, 1 = at least one failed.
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HOOK_DIR/inject-where-are-we.sh"
REPO_ROOT="$(cd "$HOOK_DIR/../.." && pwd)"
[ -x "$HOOK" ] || chmod +x "$HOOK" 2>/dev/null || true

FAILED=0
PASSED=0
pass() { echo "PASS $1"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

seed_ledger() {
    local dir="$1"
    mkdir -p "$dir"
    printf '%s\n' '{"ts":"2026-01-01T00:00:00Z","source":"jira","key":"HIMMEL-9","kind":"ticket","status":"in-progress"}' > "$dir/ledger.jsonl"
}

# --- Case 1: OFF → no output, exit 0 ----------------------------------------
state1="$TMP/s1"; seed_ledger "$state1"
out1="$(HIMMEL_REPO="$REPO_ROOT" WHERE_ARE_WE_STATE_DIR="$state1" \
    HIMMEL_WHERE_ARE_WE="" bash "$HOOK" </dev/null 2>/dev/null)"; rc1=$?
if [ "$rc1" = 0 ] && [ -z "$out1" ]; then
    pass "OFF -> empty output, exit 0"
else
    fail "OFF -> expected empty+0, got rc=$rc1 out='$out1'"
fi

# --- Case 2: ON + fresh marker → injects, no spawn --------------------------
state2="$TMP/s2"; seed_ledger "$state2"; touch "$state2/.refreshed-at"
out2="$(HIMMEL_REPO="$REPO_ROOT" WHERE_ARE_WE_STATE_DIR="$state2" \
    HIMMEL_WHERE_ARE_WE=1 bash "$HOOK" </dev/null 2>/dev/null)"; rc2=$?
# Assert the WRAPPER and a real rendered BODY (the freshness line is always the
# first body line when dock.mjs renders — proves the body is non-empty, not just
# the <system-reminder> tag; kimi-1). Branch-independent (freshness shows on
# every route), so it holds whatever the real git branch of REPO_ROOT is.
if [ "$rc2" = 0 ] \
    && printf '%s' "$out2" | grep -qF '<system-reminder>' \
    && printf '%s' "$out2" | grep -qF 'where-are-we ·'; then
    pass "ON -> injects <system-reminder> with a rendered body, exit 0"
else
    fail "ON -> expected reminder+body+0, got rc=$rc2 out='$out2'"
fi

# --- Case 2b: ON + fresh marker → NO refresh spawned (debounce) -------------
state2b="$TMP/s2b"; seed_ledger "$state2b"; touch "$state2b/.refreshed-at"
sentinel2b="$TMP/sentinel2b"
HIMMEL_REPO="$REPO_ROOT" WHERE_ARE_WE_STATE_DIR="$state2b" \
    HIMMEL_WHERE_ARE_WE=1 \
    HIMMEL_WHERE_ARE_WE_COLLECT_CMD="touch '$sentinel2b'" \
    bash "$HOOK" </dev/null >/dev/null 2>&1
sleep 1
if [ ! -e "$sentinel2b" ]; then
    pass "fresh marker -> no refresh spawned (debounced)"
else
    fail "fresh marker -> unexpected refresh spawn"
fi

# --- Case 2c: OFF via falsy grammar ('false') ------------------------------
out2c="$(HIMMEL_REPO="$REPO_ROOT" WHERE_ARE_WE_STATE_DIR="$state2" \
    HIMMEL_WHERE_ARE_WE=false bash "$HOOK" </dev/null 2>/dev/null)"; rc2c=$?
if [ "$rc2c" = 0 ] && [ -z "$out2c" ]; then
    pass "OFF via 'false' grammar -> empty output, exit 0"
else
    fail "OFF via 'false' -> expected empty+0, got rc=$rc2c out='$out2c'"
fi

# --- Case 3: ON + stale (no marker) → detached refresh, non-blocking --------
# ORDERING assertion (not a timing budget): the stub sleeps then touches a
# sentinel; right after the hook returns the sentinel must NOT exist (hook did
# not wait), and the marker must now exist (touched). After a wait the sentinel
# must appear (the detached child really ran).
state3="$TMP/s3"; seed_ledger "$state3"
sentinel="$TMP/sentinel3"
HIMMEL_REPO="$REPO_ROOT" WHERE_ARE_WE_STATE_DIR="$state3" \
    HIMMEL_WHERE_ARE_WE=1 \
    HIMMEL_WHERE_ARE_WE_COLLECT_CMD="sleep 3; touch '$sentinel'" \
    bash "$HOOK" </dev/null >/dev/null 2>&1; rc3=$?
if [ "$rc3" = 0 ] && [ ! -e "$sentinel" ] && [ -e "$state3/.refreshed-at" ]; then
    pass "stale -> hook returned before refresh finished (non-blocking) + marker touched"
else
    sv=no; [ -e "$sentinel" ] && sv=yes
    mv=no; [ -e "$state3/.refreshed-at" ] && mv=yes
    fail "stale -> expected non-blocking + marker, rc=$rc3 sentinel=$sv marker=$mv"
fi
sleep 4
if [ -e "$sentinel" ]; then
    pass "detached refresh actually ran (sentinel appeared)"
else
    fail "detached refresh never ran (no sentinel after wait)"
fi

# --- Case 4: ON but broken node path → still exit 0 (fail-open) -------------
state4="$TMP/s4"; seed_ledger "$state4"
HIMMEL_REPO="$TMP/nonexistent-repo" WHERE_ARE_WE_STATE_DIR="$state4" \
    HIMMEL_WHERE_ARE_WE=1 bash "$HOOK" </dev/null >/dev/null 2>&1; rc4=$?
if [ "$rc4" = 0 ]; then
    pass "broken root -> fail-open exit 0"
else
    fail "broken root -> expected exit 0, got rc=$rc4"
fi

echo "---"
echo "PASSED=$PASSED FAILED=$FAILED"
[ "$FAILED" = 0 ]
