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

# ── Cases 3.1-3.3: economics lock reaping (HIMMEL-1300) ─────────────────────
# All three drive the reaper through the SAME discriminator: if the lock is
# reaped, the hook acquires it and writes cache-all-stats.json; if it is not,
# the hook skips the refresh entirely and no cache appears. TTL=0 forces past
# the freshness gate so the reaper is always reached.
#
# Ages the lock dir past the 300s staleness threshold. Returns 1 when this
# platform's touch(1) cannot set an explicit mtime, so a case can skip rather
# than assert on a setup that never happened.
# `touch -d @epoch` is GNU-only, so on a stock macOS this returned 1 and cases
# 3.1/3.2 SKIPped permanently — silently dropping coverage of the heartbeat-vs-age
# reaper logic on one of the three declared platforms. Falls back to the POSIX
# `-t` form via `date -r`, the same pair lib/all-sessions-index.sh already uses to
# build its `find -newer` reference (~324-326). Still returns 1 when NEITHER form
# works, so a case can skip rather than assert on a setup that never happened.
_age_lock() {
    local _when=$(( $(date +%s) - 600 ))
    touch -d "@$_when" "$1" 2>/dev/null \
        || touch -t "$(date -r "$_when" +%Y%m%d%H%M.%S 2>/dev/null)" "$1" 2>/dev/null
}

run_hook_econ() {  # $1 = econ dir
    CLAUDE_PROJECTS_DIR="$PROJ" CLAUDE_ALL_SESSIONS_CACHE_DIR="$1" \
        HIMMEL_STATUSLINE_REFRESH_TTL=0 \
        HIMMEL_WHERE_ARE_WE_ROLLUP_DIR="$ROLLDIR" HIMMEL_WHERE_ARE_WE_ROLLUP_CMD="bash $rollup_stub" \
        bash "$HOOK" --cwd "$GITDIR" </dev/null >/dev/null 2>&1
}

# 3.1 — a LIVE owner whose heartbeat is fresh must SURVIVE, even though the lock
# dir itself is older than the 300s threshold. This is the regression the
# heartbeat exists for: before it, a genuine rebuild running longer than 300s
# was reaped out from under itself and a second refresher ran concurrently on
# the same cache files. $$ is this test process — unambiguously alive.
ECON_HB="$TMP/econ-hb"; mkdir -p "$ECON_HB"
LOCK_HB="$ECON_HB/cache-all-stats-index.json.lock"
mkdir -p "$LOCK_HB"
printf '%s\n' "$$" > "$LOCK_HB/owner.pid"
printf '%s\n' "$$" > "$LOCK_HB/heartbeat"     # fresh: written just now
if ! _age_lock "$LOCK_HB"; then
    echo "SKIP live-owner heartbeat -> touch(1) cannot set an explicit mtime here"
else
    run_hook_econ "$ECON_HB"
    if [ -d "$LOCK_HB" ] && [ ! -f "$ECON_HB/cache-all-stats.json" ]; then
        pass "live owner + fresh heartbeat -> lock NOT reaped, refresh skipped"
    else
        fail "live owner + fresh heartbeat -> lock reaped (lock=$([ -d "$LOCK_HB" ] && echo kept || echo gone), cache=$([ -f "$ECON_HB/cache-all-stats.json" ] && echo written || echo none))"
    fi
fi

# 3.2 — an alive PID with a STALE heartbeat is a recycled PID number sitting on
# a dead lock (a real owner would have re-stamped it), so the age fallback must
# still reap it. Without this the 3.1 fix would wedge the refresh forever.
ECON_ST="$TMP/econ-stale"; mkdir -p "$ECON_ST"
LOCK_ST="$ECON_ST/cache-all-stats-index.json.lock"
mkdir -p "$LOCK_ST"
printf '%s\n' "$$" > "$LOCK_ST/owner.pid"
printf '%s\n' "$$" > "$LOCK_ST/heartbeat"
if ! _age_lock "$LOCK_ST/heartbeat" || ! _age_lock "$LOCK_ST"; then
    echo "SKIP recycled-pid stale heartbeat -> touch(1) cannot set an explicit mtime here"
else
    run_hook_econ "$ECON_ST"
    if [ -f "$ECON_ST/cache-all-stats.json" ]; then
        pass "alive pid + stale heartbeat -> reaped by the age fallback, refresh ran"
    else
        fail "alive pid + stale heartbeat -> not reaped, refresh never ran"
    fi
fi

# 3.3 — release must survive an UNEXPECTED entry in the lock dir. `rmdir` only
# removes an empty dir, so a stray file made the release silently fail and
# wedged every later session. Uses a dead owner pid so the reap path (not the
# acquire path) does the removal.
ECON_FR="$TMP/econ-force"; mkdir -p "$ECON_FR"
LOCK_FR="$ECON_FR/cache-all-stats-index.json.lock"
mkdir -p "$LOCK_FR"
( exit 0 ) & dead_pid=$!; wait "$dead_pid" 2>/dev/null
printf '%s\n' "$dead_pid" > "$LOCK_FR/owner.pid"
printf '%s\n' 'stray marker from some future version' > "$LOCK_FR/unexpected-entry"
if kill -0 "$dead_pid" 2>/dev/null; then
    echo "SKIP force-release -> reaped pid $dead_pid is somehow still alive (pid reuse)"
else
    run_hook_econ "$ECON_FR"
    if [ -f "$ECON_FR/cache-all-stats.json" ]; then
        pass "dead owner + stray lock entry -> force-release reaped it, refresh ran"
    else
        fail "dead owner + stray lock entry -> rmdir-only release wedged the refresh"
    fi
fi

# 3.4 — a SIGTERM mid-rebuild must TERMINATE the hook, not merely clean up.
# A bash INT/TERM trap RESUMES the interrupted script when the handler returns,
# so a cleanup-only signal trap released the lock and deleted the pass's temps
# while rebuild_all_sessions_index kept running — a second refresher could then
# acquire the lock and write the same cache/index concurrently. Killing is the
# NORMAL termination mode for this hook (the SessionStart timeout), so this is
# the common path, not a corner case. A slow-jq PATH shim makes the rebuild long
# enough to signal mid-pass; the assertion is that the process is GONE shortly
# after the TERM, which fails if the trap only cleans up.
ECON_SIG="$TMP/econ-sig"; mkdir -p "$ECON_SIG"
SIGPROJ="$TMP/sigprojects"; mkdir -p "$SIGPROJ"
for n in 1 2 3 4 5 6 7 8; do
    mkdir -p "$SIGPROJ/s$n"
    printf '%s\n' '{"type":"assistant","message":{"usage":{"cache_read_input_tokens":1000}}}' > "$SIGPROJ/s$n/t.jsonl"
done
SLOWJQ="$TMP/slowjq"; mkdir -p "$SLOWJQ"
REAL_JQ=$(command -v jq)
cat > "$SLOWJQ/jq" <<SIGJQ
#!/usr/bin/env bash
sleep 1
exec "$REAL_JQ" "\$@"
SIGJQ
chmod +x "$SLOWJQ/jq"
SIGLOCK="$ECON_SIG/cache-all-stats-index.json.lock"
CLAUDE_PROJECTS_DIR="$SIGPROJ" CLAUDE_ALL_SESSIONS_CACHE_DIR="$ECON_SIG" \
    HIMMEL_STATUSLINE_REFRESH_TTL=0 PATH="$SLOWJQ:$PATH" \
    HIMMEL_WHERE_ARE_WE_ROLLUP_DIR="$ROLLDIR" HIMMEL_WHERE_ARE_WE_ROLLUP_CMD="bash $rollup_stub" \
    bash "$HOOK" --cwd "$GITDIR" </dev/null >/dev/null 2>&1 &
sig_pid=$!
# Wait for the rebuild to actually be under way (lock acquired), bounded.
waited=0
while [ ! -d "$SIGLOCK" ] && [ "$waited" -lt 100 ]; do sleep 0.1; waited=$((waited + 1)); done
if [ ! -d "$SIGLOCK" ]; then
    echo "SKIP signal-exit -> hook never acquired the lock within 10s (cannot stage the scenario)"
    kill -TERM "$sig_pid" 2>/dev/null; wait "$sig_pid" 2>/dev/null
else
    kill -TERM "$sig_pid" 2>/dev/null
    # Poll for death rather than `wait` — `wait` would block until the process
    # ends either way and could not distinguish "exited on the signal" from
    # "ran the whole rebuild to completion", which is the entire distinction.
    gone=0
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        kill -0 "$sig_pid" 2>/dev/null || { gone=1; break; }
        sleep 0.2
    done
    wait "$sig_pid" 2>/dev/null
    if [ "$gone" -eq 1 ]; then
        pass "SIGTERM mid-rebuild -> hook exited on the signal (did not resume the rebuild past its own lock release)"
    else
        fail "SIGTERM mid-rebuild -> hook still running 3s after TERM; the signal trap cleaned up but did not exit"
    fi
fi

# ── Case 3.5: own-or-lose reap (HIMMEL-1327) ────────────────────────────────
# The stale-lock reap must be OWN-OR-LOSE: only the refresher whose rename wins
# removes anything, and it removes its OWN private `.dead.$$` copy — never
# another owner's live lock. Before this the reap shared its target (`rm -rf
# "$lock"`) with every concurrent refresher, so two that both classified the same
# lock stale could both delete it (and one could delete the other's freshly-
# acquired LIVE lock). Three assertions:
#   (a) runtime  — a stale lock is reaped through the hook and leaves NO orphaned
#                  `.dead.*` sibling (the rename-first reap removed its copy);
#   (b) unit     — the rename is own-or-lose: of two concurrent reapers of the
#                  same lock, exactly one wins;
#   (c) static   — the hook reaps via the private rename (regression guard).

# (a) Stale lock (dead owner) reaped end-to-end, no `.dead.*` orphan left behind.
ECON_OL="$TMP/econ-ol"; mkdir -p "$ECON_OL"
LOCK_OL="$ECON_OL/cache-all-stats-index.json.lock"; mkdir -p "$LOCK_OL"
( exit 0 ) & dead_pid=$!; wait "$dead_pid" 2>/dev/null
printf '%s\n' "$dead_pid" > "$LOCK_OL/owner.pid"
if kill -0 "$dead_pid" 2>/dev/null; then
    echo "SKIP own-or-lose reap -> reaped pid $dead_pid is somehow still alive (pid reuse)"
else
    run_hook_econ "$ECON_OL"
    if [ -f "$ECON_OL/cache-all-stats.json" ]; then
        pass "own-or-lose reap -> stale lock reaped, refresh ran"
    else
        fail "own-or-lose reap -> stale lock not reaped, refresh never ran"
    fi
    if [ -z "$(find "$ECON_OL" -name '*.dead.*' 2>/dev/null)" ]; then
        pass "own-or-lose reap -> no orphaned .dead.* reaped-lock sibling left"
    else
        fail "own-or-lose reap -> orphaned .dead.* left behind ($(find "$ECON_OL" -name '*.dead.*'))"
    fi
fi

# (b) The rename the reap relies on is own-or-lose: two concurrent `mv` reaps of
# the SAME lock dir → exactly one wins (rename is atomic on one volume; the
# loser's source is already gone). This is what stops two refreshers both
# deleting the same stale lock.
OL2="$TMP/econ-ol2"; mkdir -p "$OL2"; mkdir -p "$OL2/ol.lock"
rm -f "$OL2/a" "$OL2/b"
( mv "$OL2/ol.lock" "$OL2/ol.lock.dead.a" 2>/dev/null && : >"$OL2/a" ) &
( mv "$OL2/ol.lock" "$OL2/ol.lock.dead.b" 2>/dev/null && : >"$OL2/b" ) &
wait
_wins=0
[ -f "$OL2/a" ] && _wins=$((_wins + 1))
[ -f "$OL2/b" ] && _wins=$((_wins + 1))
if [ "$_wins" -eq 1 ]; then
    pass "own-or-lose reap -> exactly one of two concurrent reapers wins the rename"
else
    fail "own-or-lose reap -> $_wins of two reapers won the rename (expected exactly 1)"
fi
rm -rf "$OL2/ol.lock.dead.a" "$OL2/ol.lock.dead.b"

# (c) Static guard: the hook reaps via a private `.dead.$$` rename, not a shared
# `rm -rf "$lock"` on the reap path.
# shellcheck disable=SC2016  # single quotes are required: this is a LITERAL
# source-text pattern to find inside $HOOK, not an expression to expand here.
if grep -qF 'mv "$lock" "$lock.dead.$$"' "$HOOK"; then
    # Single-quoted: `.dead.$$` is the literal source pattern being asserted on,
    # not this test's own pid. Double quotes printed `.dead.4271`, which reads as
    # a different claim than the FAIL branch right below it.
    pass 'own-or-lose reap -> hook reaps via a private .dead.$$ rename'
else
    fail "own-or-lose reap -> hook does not reap via a private rename (regression?)"
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
