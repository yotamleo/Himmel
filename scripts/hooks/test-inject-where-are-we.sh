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

# --- Case 2: ON, global-digest route → injects a POINTER, persists latest.md -
# Force the digest route with the branch seam (independent of REPO_ROOT's real
# branch). Assert the WRAPPER, the freshness line (L1 contract's first body
# line), the POINTER marker, and that the full digest was persisted to
# latest.md (so the pointer is not dangling).
state2="$TMP/s2"; seed_ledger "$state2"; touch "$state2/.refreshed-at"
out2="$(HIMMEL_REPO="$REPO_ROOT" WHERE_ARE_WE_STATE_DIR="$state2" \
    WHERE_ARE_WE_BRANCH_OVERRIDE=main \
    HIMMEL_WHERE_ARE_WE=1 bash "$HOOK" </dev/null 2>/dev/null)"; rc2=$?
if [ "$rc2" = 0 ] \
    && printf '%s' "$out2" | grep -qF '<system-reminder>' \
    && printf '%s' "$out2" | grep -qF 'where-are-we ·' \
    && printf '%s' "$out2" | grep -qF 'digest not loaded' \
    && [ -s "$state2/latest.md" ] \
    && grep -qF 'where-are-we ·' "$state2/latest.md"; then
    pass "digest route -> injects pointer + persists latest.md, exit 0"
else
    fail "digest route -> expected pointer+latest.md+0, got rc=$rc2 out='$out2'"
fi

# --- Case 2big: LARGE digest (> pipe buffer) still injects the pointer -------
# Guards the fail-open contract against a first-line extraction that EPIPEs: a
# render exceeding the OS pipe buffer (~64KB) must still emit the pointer, not
# silently exit after writing latest.md. (codex adversarial CR — large digest.)
state2b2="$TMP/s2big"; mkdir -p "$state2b2"
big2=$(head -c 90000 /dev/zero | tr '\0' 'x')
printf '{"ts":"2026-01-01T00:00:00Z","source":"jira","key":"HIMMEL-9","kind":"ticket","status":"%s"}\n' "$big2" > "$state2b2/ledger.jsonl"
touch "$state2b2/.refreshed-at"
out2b2="$(HIMMEL_REPO="$REPO_ROOT" WHERE_ARE_WE_STATE_DIR="$state2b2" \
    WHERE_ARE_WE_BRANCH_OVERRIDE=main \
    HIMMEL_WHERE_ARE_WE=1 bash "$HOOK" </dev/null 2>/dev/null)"; rc2b2=$?
if [ "$rc2b2" = 0 ] \
    && printf '%s' "$out2b2" | grep -qF '<system-reminder>' \
    && printf '%s' "$out2b2" | grep -qF 'digest not loaded' \
    && [ -s "$state2b2/latest.md" ]; then
    pass "large digest -> pointer still injected (no EPIPE silent exit), exit 0"
else
    fail "large digest -> expected pointer+latest.md+0, got rc=$rc2b2 out(head)='$(printf '%s' "$out2b2" | head -c 200)'"
fi

# --- Case 2card: active-ticket CARD route → injected INLINE, not pointerized -
# A ticket branch renders a small high-value card (status/next/blockers/locks).
# It must NOT be pointerized (that would hide blockers/locks); assert the card
# body appears inline and the pointer marker is absent. (codex-adv HIMMEL CR.)
state2c="$TMP/s2card"; seed_ledger "$state2c"; touch "$state2c/.refreshed-at"
out2c="$(HIMMEL_REPO="$REPO_ROOT" WHERE_ARE_WE_STATE_DIR="$state2c" \
    WHERE_ARE_WE_BRANCH_OVERRIDE=feat/himmel-9-card \
    HIMMEL_WHERE_ARE_WE=1 bash "$HOOK" </dev/null 2>/dev/null)"; rc2card=$?
if [ "$rc2card" = 0 ] \
    && printf '%s' "$out2c" | grep -qF '# HIMMEL-9' \
    && printf '%s' "$out2c" | grep -qF 'status:' \
    && ! printf '%s' "$out2c" | grep -qF 'digest not loaded' \
    && [ ! -e "$state2c/latest.md" ]; then
    pass "card route -> injected inline, latest.md reserved (not written), exit 0"
else
    fail "card route -> expected inline card + no latest.md, got rc=$rc2card out='$out2c'"
fi

# --- Case 2share: latest.md is reserved for the digest across a card render --
# Sequence on ONE shared state dir: a digest session persists latest.md (pointer
# target), then an active-ticket card session runs. The card MUST NOT overwrite
# latest.md — a later reader of the digest pointer must still find the digest,
# not unrelated ticket-local content. (codex adversarial CR — shared-state race.)
state2s="$TMP/s2share"; seed_ledger "$state2s"; touch "$state2s/.refreshed-at"
HIMMEL_REPO="$REPO_ROOT" WHERE_ARE_WE_STATE_DIR="$state2s" \
    WHERE_ARE_WE_BRANCH_OVERRIDE=main \
    HIMMEL_WHERE_ARE_WE=1 bash "$HOOK" </dev/null >/dev/null 2>&1
HIMMEL_REPO="$REPO_ROOT" WHERE_ARE_WE_STATE_DIR="$state2s" \
    WHERE_ARE_WE_BRANCH_OVERRIDE=feat/himmel-9-x \
    HIMMEL_WHERE_ARE_WE=1 bash "$HOOK" </dev/null >/dev/null 2>&1
if [ -s "$state2s/latest.md" ] && grep -qxF '# Where are we' "$state2s/latest.md"; then
    pass "latest.md stays the digest after a later card render (reserved)"
else
    fail "latest.md was clobbered by the card render: $(cat "$state2s/latest.md" 2>/dev/null)"
fi

# --- Case 2card-adv: card whose field embeds a "# Where are we" line ---------
# A whole-body search would misclassify this card as the global digest and
# pointerize it (hiding blockers/locks). The structural first-H1 check must
# still treat it as a card (first H1 = "# HIMMEL-9") and inject inline.
# (codex adversarial CR — multiline card field containing the digest heading.)
state2ca="$TMP/s2card_adv"; mkdir -p "$state2ca"
printf '%s\n' '{"ts":"2026-01-01T00:00:00Z","source":"jira","key":"HIMMEL-9","kind":"ticket","status":"in-progress\n# Where are we\ndone"}' > "$state2ca/ledger.jsonl"
touch "$state2ca/.refreshed-at"
out2ca="$(HIMMEL_REPO="$REPO_ROOT" WHERE_ARE_WE_STATE_DIR="$state2ca" \
    WHERE_ARE_WE_BRANCH_OVERRIDE=feat/himmel-9-card \
    HIMMEL_WHERE_ARE_WE=1 bash "$HOOK" </dev/null 2>/dev/null)"; rc2ca=$?
if [ "$rc2ca" = 0 ] \
    && printf '%s' "$out2ca" | grep -qF '# HIMMEL-9' \
    && ! printf '%s' "$out2ca" | grep -qF 'digest not loaded'; then
    pass "card w/ embedded heading -> still inline (not misclassified), exit 0"
else
    fail "card w/ embedded heading -> expected inline+0, got rc=$rc2ca out='$out2ca'"
fi

# --- Case 2a: persistence FAILS → fail-open, inject the FULL digest inline ---
# Force the latest.md write to fail by pre-creating a DIRECTORY at that path
# (mv then moves the temp inside it, so the `[ -f latest.md ]` guard fails).
# The hook must then fall back to injecting the full digest (no pointer marker)
# so the session never loses it. Digest route (branch=main) to prove the
# fail-open path applies even where a pointer WOULD have been emitted.
state2a="$TMP/s2a"; seed_ledger "$state2a"; touch "$state2a/.refreshed-at"
mkdir -p "$state2a/latest.md"   # occupy the target path with a directory
out2a="$(HIMMEL_REPO="$REPO_ROOT" WHERE_ARE_WE_STATE_DIR="$state2a" \
    WHERE_ARE_WE_BRANCH_OVERRIDE=main \
    HIMMEL_WHERE_ARE_WE=1 bash "$HOOK" </dev/null 2>/dev/null)"; rc2a=$?
if [ "$rc2a" = 0 ] \
    && printf '%s' "$out2a" | grep -qF '<system-reminder>' \
    && printf '%s' "$out2a" | grep -qF 'where-are-we ·' \
    && ! printf '%s' "$out2a" | grep -qF 'digest not loaded'; then
    pass "persist fails -> fail-open, full digest injected inline, exit 0"
else
    fail "persist fails -> expected full inline digest+0, got rc=$rc2a out='$out2a'"
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
