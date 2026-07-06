#!/usr/bin/env bash
# Test for scripts/hooks/refresh-statusline-caches-periodic.sh (HIMMEL-718 3.2).
# Hermetic: seeded projects dir + rollup stub; no network. Asserts the hook
# rebuilds the all-sessions economics cache and invokes the rollup for the
# branch key — synchronously, exit 0, no orphan.
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$DIR/refresh-statusline-caches-periodic.sh"

FAILED=0; PASSED=0
pass() { echo "PASS $1"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Seeded transcript history (proj_root/<dir>/<file>.jsonl, one level down).
PROJ="$TMP/projects"; mkdir -p "$PROJ/sess-a" "$PROJ/sess-b"
printf '%s\n' '{"type":"assistant","message":{"usage":{"cache_read_input_tokens":1000000,"cache_creation_input_tokens":50000,"input_tokens":10000}}}' > "$PROJ/sess-a/t.jsonl"
printf '%s\n' '{"type":"assistant","message":{"usage":{"cache_read_input_tokens":3000000,"cache_creation_input_tokens":100000,"input_tokens":20000}}}' > "$PROJ/sess-b/t.jsonl"
# Totals: reads 4,000,000  writes 150,000  inputs 30,000.

ECON="$TMP/econ"; mkdir -p "$ECON"
ROLLDIR="$TMP/roll"; mkdir -p "$ROLLDIR"

# Rollup stub records that it was called with the right --key/--out.
rollup_marker="$TMP/rollup-called"
rollup_stub="$TMP/rollup-stub.sh"
cat > "$rollup_stub" <<STUB
#!/usr/bin/env bash
echo "\$*" > "$rollup_marker"
# Emulate statusline-rollup.sh: write the --out cache so TTL-freshness is testable.
out=""
while [ \$# -gt 0 ]; do case "\$1" in --out) out="\$2"; shift 2;; *) shift;; esac; done
[ -n "\$out" ] && printf '%s\n' '{"epic":"HIMMEL-999","done":1,"total":3}' > "\$out"
STUB
chmod +x "$rollup_stub"

# A temp git repo on a ticket branch so the hook derives a key.
GITDIR="$TMP/repo"; mkdir -p "$GITDIR"
git -C "$GITDIR" init -q 2>/dev/null
git -C "$GITDIR" checkout -q -b feat/HIMMEL-999-demo 2>/dev/null

# ── Case 1: all-sessions economics cache rebuilt with correct totals ─────────
CLAUDE_PROJECTS_DIR="$PROJ" CLAUDE_ALL_SESSIONS_CACHE_DIR="$ECON" \
    HIMMEL_WHERE_ARE_WE_ROLLUP_DIR="$ROLLDIR" HIMMEL_WHERE_ARE_WE_ROLLUP_CMD="bash $rollup_stub" \
    bash "$HOOK" --cwd "$GITDIR" </dev/null >/dev/null 2>&1; rc=$?
cache="$ECON/cache-all-stats.json"
if [ "$rc" -eq 0 ] && [ -f "$cache" ]; then
    r=$(jq -r '.reads' "$cache" 2>/dev/null); w=$(jq -r '.writes' "$cache" 2>/dev/null); i=$(jq -r '.inputs' "$cache" 2>/dev/null)
    if [ "$r" = "4000000" ] && [ "$w" = "150000" ] && [ "$i" = "30000" ]; then
        pass "all-sessions rebuild -> reads/writes/inputs = 4000000/150000/30000"
    else
        fail "all-sessions rebuild -> got $r/$w/$i"
    fi
else
    fail "all-sessions rebuild -> rc=$rc, cache exists=$([ -f "$cache" ] && echo yes || echo no)"
fi

# ── Case 2: rollup invoked for the branch key ───────────────────────────────
if [ -f "$rollup_marker" ] && grep -qF -- '--key HIMMEL-999' "$rollup_marker"; then
    pass "rollup invoked with --key HIMMEL-999"
else
    fail "rollup not invoked for key: $(cat "$rollup_marker" 2>/dev/null || echo '(no marker)')"
fi

# ── Case 2.5: TTL-throttle — a second call within TTL skips the fresh refresh ─
# After Case 1 the rollup cache is fresh (<900s); a repeat call must NOT invoke
# the rollup stub (a per-turn UserPromptSubmit trigger stays a cheap no-op).
rm -f "$rollup_marker"
CLAUDE_PROJECTS_DIR="$PROJ" CLAUDE_ALL_SESSIONS_CACHE_DIR="$ECON" \
    HIMMEL_WHERE_ARE_WE_ROLLUP_DIR="$ROLLDIR" HIMMEL_WHERE_ARE_WE_ROLLUP_CMD="bash $rollup_stub" \
    bash "$HOOK" --cwd "$GITDIR" </dev/null >/dev/null 2>&1
if [ ! -f "$rollup_marker" ]; then
    pass "TTL-throttle -> fresh rollup cache skips refresh (no stub call)"
else
    fail "TTL-throttle -> refreshed despite fresh cache"
fi
# And with TTL=0 the throttle is bypassed → refresh runs again.
rm -f "$rollup_marker"
CLAUDE_PROJECTS_DIR="$PROJ" CLAUDE_ALL_SESSIONS_CACHE_DIR="$ECON" \
    HIMMEL_WHERE_ARE_WE_ROLLUP_DIR="$ROLLDIR" HIMMEL_WHERE_ARE_WE_ROLLUP_CMD="bash $rollup_stub" \
    HIMMEL_WHERE_ARE_WE_ROLLUP_TTL=0 \
    bash "$HOOK" --cwd "$GITDIR" </dev/null >/dev/null 2>&1
if [ -f "$rollup_marker" ] && grep -qF -- '--key HIMMEL-999' "$rollup_marker"; then
    pass "TTL=0 -> throttle bypassed, refresh runs"
else
    fail "TTL=0 -> refresh did not run"
fi

# ── Case 2.6: economics-cache TTL throttle (mtime-based, the leak-relevant gate)
# The econ rebuild is the expensive/leak-relevant one; assert its cache is NOT
# rewritten on a fresh second call, and IS on TTL=0.
econ_cache="$ECON/cache-all-stats.json"
before_mt=$(stat -c %Y "$econ_cache" 2>/dev/null || stat -f %m "$econ_cache" 2>/dev/null || echo 0)
sleep 1
CLAUDE_PROJECTS_DIR="$PROJ" CLAUDE_ALL_SESSIONS_CACHE_DIR="$ECON" \
    HIMMEL_WHERE_ARE_WE_ROLLUP_DIR="$ROLLDIR" HIMMEL_WHERE_ARE_WE_ROLLUP_CMD="bash $rollup_stub" \
    bash "$HOOK" --cwd "$GITDIR" </dev/null >/dev/null 2>&1
after_mt=$(stat -c %Y "$econ_cache" 2>/dev/null || stat -f %m "$econ_cache" 2>/dev/null || echo 0)
if [ "$before_mt" = "$after_mt" ]; then
    pass "econ TTL-throttle -> fresh cache NOT rewritten (mtime unchanged)"
else
    fail "econ TTL-throttle -> cache rewritten despite fresh ($before_mt -> $after_mt)"
fi
sleep 1   # advance the clock so a rewrite is detectable at 1s mtime granularity
CLAUDE_PROJECTS_DIR="$PROJ" CLAUDE_ALL_SESSIONS_CACHE_DIR="$ECON" \
    HIMMEL_WHERE_ARE_WE_ROLLUP_DIR="$ROLLDIR" HIMMEL_WHERE_ARE_WE_ROLLUP_CMD="bash $rollup_stub" \
    HIMMEL_STATUSLINE_REFRESH_TTL=0 \
    bash "$HOOK" --cwd "$GITDIR" </dev/null >/dev/null 2>&1
after0_mt=$(stat -c %Y "$econ_cache" 2>/dev/null || stat -f %m "$econ_cache" 2>/dev/null || echo 0)
if [ "$after0_mt" -gt "$after_mt" ]; then
    pass "econ TTL=0 -> throttle bypassed, cache rewritten (mtime advanced)"
else
    fail "econ TTL=0 -> cache not rewritten ($after_mt -> $after0_mt)"
fi

# ── Case 2.7: windowed rebuild THROUGH the hook (period=week, else-branch) ────
# Drives the hook's else-branch (rebuild with window bounds), covering the
# non-all path end-to-end. Deterministic window via HIMMEL_STATUSLINE_NOW.
NOW_FIXED=1751803200   # 2025-07-06 12:00 UTC — same day as the transcript below
ECON_WK="$TMP/econ-wk"; mkdir -p "$ECON_WK"
PROJ_WK="$TMP/proj-wk"; mkdir -p "$PROJ_WK/s"
printf '%s\n' '{"type":"assistant","timestamp":"2025-07-06T12:00:00.000Z","message":{"usage":{"cache_read_input_tokens":700000,"cache_creation_input_tokens":7000,"input_tokens":3000}}}' > "$PROJ_WK/s/t.jsonl"
wk_id="week-$(HIMMEL_STATUSLINE_NOW=$NOW_FIXED bash -c '
    now=$1; dow=$(date -d "@$now" +%u 2>/dev/null || date -r "$now" +%u); \
    ymd=$(date -d "@$now" +%Y-%m-%d 2>/dev/null || date -r "$now" +%Y-%m-%d); \
    mid=$(date -d "$ymd 00:00:00" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M:%S" "$ymd 00:00:00" +%s); \
    ws=$(( mid - (dow-1)*86400 )); date -d "@$ws" +%Y%m%d 2>/dev/null || date -r "$ws" +%Y%m%d' _ "$NOW_FIXED")"
CLAUDE_PROJECTS_DIR="$PROJ_WK" CLAUDE_ALL_SESSIONS_CACHE_DIR="$ECON_WK" \
    HIMMEL_STATUSLINE_PERIOD=week HIMMEL_STATUSLINE_NOW=$NOW_FIXED \
    HIMMEL_WHERE_ARE_WE_ROLLUP_DIR="$ROLLDIR" HIMMEL_WHERE_ARE_WE_ROLLUP_CMD="true" \
    bash "$HOOK" --cwd "$GITDIR" </dev/null >/dev/null 2>&1; rc=$?
wk_cache="$ECON_WK/cache-${wk_id}.json"
if [ "$rc" -eq 0 ] && [ -f "$wk_cache" ] && [ "$(jq -r '.reads' "$wk_cache" 2>/dev/null)" = "700000" ]; then
    pass "windowed rebuild through hook (period=week) -> reads=700000 in cache-${wk_id}.json"
else
    fail "windowed hook rebuild -> rc=$rc cache=$wk_cache reads=$(jq -r '.reads' "$wk_cache" 2>/dev/null || echo none)"
fi

# ── Case 3: no key branch (main) → no rollup call, still exits 0, econ still refreshed
git -C "$GITDIR" checkout -q -B main 2>/dev/null
rm -f "$rollup_marker"
ECON2="$TMP/econ2"; mkdir -p "$ECON2"
CLAUDE_PROJECTS_DIR="$PROJ" CLAUDE_ALL_SESSIONS_CACHE_DIR="$ECON2" \
    HIMMEL_WHERE_ARE_WE_ROLLUP_DIR="$ROLLDIR" HIMMEL_WHERE_ARE_WE_ROLLUP_CMD="bash $rollup_stub" \
    bash "$HOOK" --cwd "$GITDIR" </dev/null >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ ! -f "$rollup_marker" ] && [ -f "$ECON2/cache-all-stats.json" ]; then
    pass "main branch -> no rollup call, econ still rebuilt, exit 0"
else
    fail "main branch -> rc=$rc rollup_called=$([ -f "$rollup_marker" ] && echo yes || echo no)"
fi

# ── Case 4: static no-spawn — the hook itself carries no detached-fork pattern
strip_comments() { sed -E 's/^[[:space:]]*#.*//; s/([[:space:]])#.*/\1/' "$1"; }
if [ -z "$(strip_comments "$HOOK" | grep -nE '&[[:space:]]*disown|\([^)]*&[[:space:]]*\)|[^&>|]&[[:space:]]*$' || true)" ]; then
    pass "static no-spawn: hook carries no detached-fork pattern"
else
    fail "static no-spawn: hook carries a detached-fork pattern"
fi

echo "---"
echo "hook: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
