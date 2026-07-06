#!/usr/bin/env bash
# Test for scripts/where-are-we/statusline-segment.sh (HIMMEL-538).
# Hermetic: real provision.mjs (tracked, in-tree) against a FIXTURE ledger;
# HANDOVER_DIR / rollup-cache-dir / rollup-cmd are temp seams. No git/jira network.
# Exit: 0 = all pass, 1 = at least one failed.
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
SUT="$DIR/statusline-segment.sh"
[ -x "$SUT" ] || chmod +x "$SUT" 2>/dev/null || true

FAILED=0; PASSED=0
pass() { echo "PASS $1"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Fixtures ------------------------------------------------------------------
HROOT="$TMP/handover"; mkdir -p "$HROOT/breadcrumbs"
printf '%s\n' '{"version":1,"ticket":"HIMMEL-538","branch":"feat/HIMMEL-538-x","head_sha":"abc","next_step":"build"}' > "$HROOT/breadcrumbs/HIMMEL-538.json"

LEDGER_INPROG="$TMP/ledger-inprog.jsonl"
printf '%s\n' '{"ts":"2026-01-01T00:00:00Z","source":"jira","key":"HIMMEL-538","kind":"ticket","status":"in-progress"}' > "$LEDGER_INPROG"
LEDGER_NULLSTATUS="$TMP/ledger-null.jsonl"
printf '%s\n' '{"ts":"2026-01-01T00:00:00Z","source":"handover","key":"HIMMEL-538","kind":"ticket","next_action":"do x"}' > "$LEDGER_NULLSTATUS"
LEDGER_CORRUPT="$TMP/ledger-corrupt.jsonl"
printf '%s\n' 'this is not json {{{' > "$LEDGER_CORRUPT"

ROLLDIR_WARM="$TMP/roll-warm"; mkdir -p "$ROLLDIR_WARM"
printf '%s\n' '{"epic":"HIMMEL-514","done":6,"total":9,"refreshed_at":"2026-06-22T00:00:00Z"}' > "$ROLLDIR_WARM/where-are-we-rollup-HIMMEL-538.json"
ROLLDIR_COLD="$TMP/roll-cold"; mkdir -p "$ROLLDIR_COLD"
ROLLDIR_BADSHAPE="$TMP/roll-bad"; mkdir -p "$ROLLDIR_BADSHAPE"
printf '%s\n' '{"foo":1}' > "$ROLLDIR_BADSHAPE/where-are-we-rollup-HIMMEL-538.json"

# Common run: gate ON, fixture handover root + cold rollup unless overridden.
run() { HIMMEL_WHERE_ARE_WE=1 HANDOVER_DIR="$HROOT" HIMMEL_WHERE_ARE_WE_ROLLUP_DIR="$ROLLDIR_COLD" \
        bash "$SUT" "$@" </dev/null 2>/dev/null; }

# --- Case 1: explicit opt-out → empty ---------------------------------------
# (HIMMEL-556: default is now ON, so only an explicit falsy value suppresses.)
for off in 0 false off no FALSE Off " no "; do
    o="$(HIMMEL_WHERE_ARE_WE="$off" HANDOVER_DIR="$HROOT" bash "$SUT" --branch feat/HIMMEL-538-x </dev/null 2>/dev/null)"
    if [ -z "$o" ]; then pass "opt-out '$off' -> empty"; else fail "opt-out '$off' -> '$o'"; fi
done

# --- Case 1b: default ON (unset/empty) on a ticket branch → renders ----------
for on in "" "  "; do
    o="$(HIMMEL_WHERE_ARE_WE="$on" HANDOVER_DIR="$HROOT" HIMMEL_WHERE_ARE_WE_ROLLUP_DIR="$ROLLDIR_COLD" \
         bash "$SUT" --branch feat/HIMMEL-538-x --ledger "$TMP/none.jsonl" </dev/null 2>/dev/null)"
    if printf '%s' "$o" | grep -qF '⎇ HIMMEL-538'; then
        pass "default ON (HIMMEL_WHERE_ARE_WE='$on') -> ticket renders"
    else
        fail "default ON ('$on') -> '$o'"
    fi
done

# --- Case 2: main branch → empty (no key) -----------------------------------
o="$(run --branch main)"
if [ -z "$o" ]; then pass "main -> empty"; else fail "main -> '$o'"; fi

# --- Case 3: no-ticket branch → empty ---------------------------------------
o="$(run --branch chore/no-ticket)"
if [ -z "$o" ]; then pass "no-ticket branch -> empty"; else fail "no-ticket -> '$o'"; fi

# --- Case 4: breadcrumb present → contains the ticket + 📋 -------------------
o="$(run --branch feat/HIMMEL-538-x --ledger "$TMP/none.jsonl")"
if printf '%s' "$o" | grep -qF '⎇ HIMMEL-538' && printf '%s' "$o" | grep -qF '📋'; then
    pass "breadcrumb present -> ticket + 📋"
else
    fail "breadcrumb present -> '$o'"
fi

# --- Case 5: breadcrumb absent → no 📋 --------------------------------------
HROOT2="$TMP/handover-empty"; mkdir -p "$HROOT2/breadcrumbs"
o="$(HIMMEL_WHERE_ARE_WE=1 HANDOVER_DIR="$HROOT2" HIMMEL_WHERE_ARE_WE_ROLLUP_DIR="$ROLLDIR_COLD" \
     bash "$SUT" --branch feat/HIMMEL-538-x --ledger "$TMP/none.jsonl" </dev/null 2>/dev/null)"
if printf '%s' "$o" | grep -qF '⎇ HIMMEL-538' && ! printf '%s' "$o" | grep -qF '📋'; then
    pass "breadcrumb absent -> no 📋"
else
    fail "breadcrumb absent -> '$o'"
fi

# --- Case 6: ledger status in-progress → shown -----------------------------
o="$(run --branch feat/HIMMEL-538-x --ledger "$LEDGER_INPROG")"
if printf '%s' "$o" | grep -qF 'in-progress'; then
    pass "ledger status -> 'in-progress' shown"
else
    fail "ledger status -> '$o'"
fi

# --- Case 7: ledger status null (—) → omitted -------------------------------
o="$(run --branch feat/HIMMEL-538-x --ledger "$LEDGER_NULLSTATUS")"
if ! printf '%s' "$o" | grep -qF '—'; then
    pass "ledger null status (—) -> omitted"
else
    fail "ledger null status -> leaked em-dash: '$o'"
fi

# --- Case 8: corrupt ledger → no status, still exits 0 ----------------------
o="$(run --branch feat/HIMMEL-538-x --ledger "$LEDGER_CORRUPT")"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$o" | grep -qF '⎇ HIMMEL-538'; then
    pass "corrupt ledger -> fail-open, ticket still shown, exit 0"
else
    fail "corrupt ledger -> rc=$rc out='$o'"
fi

# --- Case 9: warm rollup → epic d/t -----------------------------------------
o="$(HIMMEL_WHERE_ARE_WE=1 HANDOVER_DIR="$HROOT" HIMMEL_WHERE_ARE_WE_ROLLUP_DIR="$ROLLDIR_WARM" \
     bash "$SUT" --branch feat/HIMMEL-538-x --ledger "$TMP/none.jsonl" </dev/null 2>/dev/null)"
if printf '%s' "$o" | grep -qF 'HIMMEL-514 6/9'; then
    pass "warm rollup -> 'HIMMEL-514 6/9'"
else
    fail "warm rollup -> '$o'"
fi

# --- Case 10: cold rollup → no epic -----------------------------------------
o="$(run --branch feat/HIMMEL-538-x --ledger "$TMP/none.jsonl")"
if ! printf '%s' "$o" | grep -qF 'HIMMEL-514'; then
    pass "cold rollup -> no epic part"
else
    fail "cold rollup -> '$o'"
fi

# --- Case 11: wrong-shape rollup JSON → no epic, no crash -------------------
o="$(HIMMEL_WHERE_ARE_WE=1 HANDOVER_DIR="$HROOT" HIMMEL_WHERE_ARE_WE_ROLLUP_DIR="$ROLLDIR_BADSHAPE" \
     bash "$SUT" --branch feat/HIMMEL-538-x --ledger "$TMP/none.jsonl" </dev/null 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s' "$o" | grep -qF '/'; then
    pass "wrong-shape rollup -> no epic, no crash"
else
    fail "wrong-shape rollup -> rc=$rc out='$o'"
fi

# --- Case 12: stale-but-present rollup → still shows last d/t ---------------
ROLLDIR_STALE="$TMP/roll-stale"; mkdir -p "$ROLLDIR_STALE"
printf '%s\n' '{"epic":"HIMMEL-514","done":3,"total":9,"refreshed_at":"2020-01-01T00:00:00Z"}' > "$ROLLDIR_STALE/where-are-we-rollup-HIMMEL-538.json"
old="$(date -d '60 minutes ago' +%Y%m%d%H%M 2>/dev/null || date -v-60M +%Y%m%d%H%M 2>/dev/null)"
if [ -n "$old" ]; then touch -t "$old" "$ROLLDIR_STALE/where-are-we-rollup-HIMMEL-538.json" 2>/dev/null || true; fi
# Pre-create the lock so the stale cache does NOT fire a real refresh during the test.
mkdir -p "$ROLLDIR_STALE/where-are-we-rollup-HIMMEL-538.json.lock"
o="$(HIMMEL_WHERE_ARE_WE=1 HANDOVER_DIR="$HROOT" HIMMEL_WHERE_ARE_WE_ROLLUP_DIR="$ROLLDIR_STALE" \
     bash "$SUT" --branch feat/HIMMEL-538-x --ledger "$TMP/none.jsonl" </dev/null 2>/dev/null)"
if printf '%s' "$o" | grep -qF 'HIMMEL-514 3/9'; then
    pass "stale-but-present rollup -> still shows last 3/9"
else
    fail "stale rollup -> '$o'"
fi

# --- Case 13a: pre-spawn guard — lock present + cold → NO refresh -----------
sentinel="$TMP/sentinel-a"
stub="$TMP/rollup-stub.sh"
printf '%s\n' '#!/usr/bin/env bash' "touch \"$sentinel\"" > "$stub"; chmod +x "$stub"
ROLLDIR_A="$TMP/roll-a"; mkdir -p "$ROLLDIR_A"
mkdir -p "$ROLLDIR_A/where-are-we-rollup-HIMMEL-538.json.lock"   # lock present
HIMMEL_WHERE_ARE_WE=1 HANDOVER_DIR="$HROOT" HIMMEL_WHERE_ARE_WE_ROLLUP_DIR="$ROLLDIR_A" \
    HIMMEL_WHERE_ARE_WE_REFRESH_SYNC=1 HIMMEL_WHERE_ARE_WE_ROLLUP_CMD="bash $stub" \
    bash "$SUT" --branch feat/HIMMEL-538-x --ledger "$TMP/none.jsonl" </dev/null >/dev/null 2>&1
if [ ! -e "$sentinel" ]; then
    pass "lock present -> refresh NOT spawned"
else
    fail "lock present -> refresh wrongly spawned"
fi

# --- Case 13b: lock absent + cold → refresh runs (foreground/sync) ----------
sentinel="$TMP/sentinel-b"
printf '%s\n' '#!/usr/bin/env bash' "touch \"$sentinel\"" > "$stub"; chmod +x "$stub"
ROLLDIR_B="$TMP/roll-b"; mkdir -p "$ROLLDIR_B"
HIMMEL_WHERE_ARE_WE=1 HANDOVER_DIR="$HROOT" HIMMEL_WHERE_ARE_WE_ROLLUP_DIR="$ROLLDIR_B" \
    HIMMEL_WHERE_ARE_WE_REFRESH_SYNC=1 HIMMEL_WHERE_ARE_WE_ROLLUP_CMD="bash $stub" \
    bash "$SUT" --branch feat/HIMMEL-538-x --ledger "$TMP/none.jsonl" </dev/null >/dev/null 2>&1
if [ -e "$sentinel" ]; then
    pass "lock absent -> refresh ran (sync)"
else
    fail "lock absent -> refresh did not run"
fi

# --- Case 14: full compose --------------------------------------------------
o="$(HIMMEL_WHERE_ARE_WE=1 HANDOVER_DIR="$HROOT" HIMMEL_WHERE_ARE_WE_ROLLUP_DIR="$ROLLDIR_WARM" \
     bash "$SUT" --branch feat/HIMMEL-538-x --ledger "$LEDGER_INPROG" </dev/null 2>/dev/null)"
if [ "$o" = "⎇ HIMMEL-538 📋 in-progress · HIMMEL-514 6/9" ]; then
    pass "full compose -> exact line"
else
    fail "full compose -> '$o'"
fi

# --- Case 15: hanging node bounded by the segment's own timeout (C1) --------
# A node that never returns must be killed by the segment's timeout (not the
# wrapper's) → no status, ticket still shown, returns quickly.
hangnode="$TMP/hangnode.sh"
printf '%s\n' '#!/usr/bin/env bash' 'sleep 30' > "$hangnode"; chmod +x "$hangnode"
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
    start="$(date +%s)"
    o="$(HIMMEL_WHERE_ARE_WE=1 HANDOVER_DIR="$HROOT" HIMMEL_WHERE_ARE_WE_ROLLUP_DIR="$ROLLDIR_COLD" \
         HIMMEL_WHERE_ARE_WE_ROLLUP_CMD="true" HIMMEL_WHERE_ARE_WE_NODE_BIN="$hangnode" \
         HIMMEL_WHERE_ARE_WE_NODE_TIMEOUT=1 \
         bash "$SUT" --branch feat/HIMMEL-538-x --ledger "$LEDGER_INPROG" </dev/null 2>/dev/null)"
    elapsed="$(( $(date +%s) - start ))"
    if printf '%s' "$o" | grep -qF '⎇ HIMMEL-538' && ! printf '%s' "$o" | grep -qF 'in-progress' && [ "$elapsed" -lt 10 ]; then
        pass "hanging node -> bounded by timeout, no status, ticket still shown (${elapsed}s)"
    else
        fail "hanging node -> elapsed=${elapsed}s out='$o'"
    fi
else
    pass "hanging node bound -> SKIPPED (no timeout/gtimeout on this host)"
fi

# --- Case 16: default path is CACHE-ONLY — NO refresh spawn (HIMMEL-718 3.2) --
# The detached in-render refresh (the orphaned-bash leak class) is GONE: the
# render path never refreshes. The periodic hook
# (scripts/hooks/refresh-statusline-caches-periodic.sh) owns the refresh now.
# Only REFRESH_SYNC (Case 13b) still refreshes, and only in the foreground.
sentinel="$TMP/sentinel-nospawn"
nospawnstub="$TMP/nospawn-stub.sh"
printf '%s\n' '#!/usr/bin/env bash' "touch \"$sentinel\"" > "$nospawnstub"; chmod +x "$nospawnstub"
ROLLDIR_NOSPAWN="$TMP/roll-nospawn"; mkdir -p "$ROLLDIR_NOSPAWN"   # cold cache
HIMMEL_WHERE_ARE_WE=1 HANDOVER_DIR="$HROOT" HIMMEL_WHERE_ARE_WE_ROLLUP_DIR="$ROLLDIR_NOSPAWN" \
    HIMMEL_WHERE_ARE_WE_ROLLUP_CMD="bash $nospawnstub" \
    bash "$SUT" --branch feat/HIMMEL-538-x --ledger "$TMP/none.jsonl" </dev/null >/dev/null 2>&1
# Give any (wrongly) backgrounded refresh a moment to fire before asserting absence.
for _ in 1 2 3 4; do [ -e "$sentinel" ] && break; sleep 0.5; done
if [ ! -e "$sentinel" ]; then
    pass "default path -> cache-only, refresh NOT spawned (leak class removed)"
else
    fail "default path -> refresh wrongly spawned (leak reintroduced)"
fi

# --- Case 17: stdin .cwd + git branch detection (production input route) -----
# Feed JSON with .cwd = this worktree; no --branch seam, so the segment must
# resolve the branch via git. Derive the EXPECTED key from the worktree's actual
# branch (the same branchToKey rule the SUT applies) rather than hardcoding one
# ticket — so the case is correct on whatever branch the test runs from.
WT="$(cd "$DIR/../.." && pwd)"
wt_branch="$(git -C "$WT" symbolic-ref --short HEAD 2>/dev/null || true)"
# Mirror the SUT's branchToKey exactly: a key is only extracted when the branch
# has a `type/` prefix (case "$branch" in */*) in statusline-segment.sh).
exp_key=""
case "$wt_branch" in
    */*) exp_key="$(printf '%s' "${wt_branch#*/}" | sed -n 's/^\([A-Za-z][A-Za-z]*-[0-9][0-9]*\).*/\1/p' | tr '[:lower:]' '[:upper:]')" ;;
esac
if [ -n "$exp_key" ]; then
    o="$(printf '%s' '{"cwd":"'"$WT"'"}' | HIMMEL_WHERE_ARE_WE=1 HANDOVER_DIR="$HROOT2" \
         HIMMEL_WHERE_ARE_WE_ROLLUP_DIR="$ROLLDIR_COLD" HIMMEL_WHERE_ARE_WE_ROLLUP_CMD="true" \
         bash "$SUT" --ledger "$TMP/none.jsonl" 2>/dev/null)"
    if printf '%s' "$o" | grep -qF "⎇ $exp_key"; then
        pass "stdin .cwd + git branch detection -> ticket shown ($exp_key)"
    else
        fail "stdin .cwd path -> '$o' (expected ⎇ $exp_key)"
    fi
else
    pass "stdin .cwd + git branch detection -> SKIPPED (branch '$wt_branch' has no ticket key)"
fi

echo "---"
echo "segment: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
