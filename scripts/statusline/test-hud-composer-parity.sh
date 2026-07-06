#!/usr/bin/env bash
# Test for scripts/statusline/hud-custom-lines.sh — the spawn-free hud composer
# (HIMMEL-718 Task 3.2). Hermetic: seeded transcript + seeded economics caches +
# seeded rollup/handover; no git/jira/network beyond the local worktree branch.
# Exit: 0 = all pass, 1 = at least one failed.
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
COMPOSER="$DIR/hud-custom-lines.sh"
SEGMENT="$ROOT/where-are-we/statusline-segment.sh"

FAILED=0; PASSED=0
pass() { echo "PASS $1"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── Case 1: static no-spawn — no detached fork in the composer OR the segment ─
# The whole leak class is the detached rebuild/refresh; the render-path files
# must contain no `& disown`, no `( … & )` subshell-background, and no bare
# line-final `&` (the most common backgrounding form — the pattern excludes
# `&&`, `>&`, `|&` so logical-and and redirects don't false-positive).
spawn_hits=0
# Strip real comments before matching (a `#` at line-start or after whitespace),
# WITHOUT touching `${x#…}` parameter expansions (# preceded by a non-space).
strip_comments() { sed -E 's/^[[:space:]]*#.*//; s/([[:space:]])#.*/\1/' "$1"; }
for f in "$COMPOSER" "$SEGMENT"; do
    hit="$(strip_comments "$f" | grep -nE '&[[:space:]]*disown|\([^)]*&[[:space:]]*\)|[^&>|]&[[:space:]]*$' || true)"
    if [ -n "$hit" ]; then
        echo "  detached-spawn pattern in $f:"
        printf '%s\n' "$hit" | sed 's/^/    /'
        spawn_hits=$((spawn_hits + 1))
    fi
done
if [ "$spawn_hits" -eq 0 ]; then
    pass "static no-spawn: composer + segment carry no detached-fork pattern"
else
    fail "static no-spawn: $spawn_hits file(s) carry a detached-fork pattern"
fi

# ── Fixtures for economics parity ───────────────────────────────────────────
# A transcript whose assistant messages sum to KNOWN reads/writes/inputs.
#   reads = 2,000,000  writes = 100,000  inputs = 50,000
TRANSCRIPT="$TMP/transcript.jsonl"
{
  printf '%s\n' '{"type":"assistant","message":{"usage":{"cache_read_input_tokens":1500000,"cache_creation_input_tokens":60000,"input_tokens":30000}}}'
  printf '%s\n' '{"type":"assistant","message":{"usage":{"cache_read_input_tokens":500000,"cache_creation_input_tokens":40000,"input_tokens":20000}}}'
  printf '%s\n' '{"type":"user","message":{"content":"ignored"}}'
} > "$TRANSCRIPT"

# All-sessions cache (period=all → window_id all-stats).
ECON_DIR="$TMP/econ"; mkdir -p "$ECON_DIR"
printf '%s\n' '{"reads":45000000,"writes":12000000,"inputs":3000000}' > "$ECON_DIR/cache-all-stats.json"

# Rollup + handover for the WAW line, keyed to THIS worktree's branch.
branch="$(git -C "$ROOT/.." symbolic-ref --short HEAD 2>/dev/null || true)"
key=""
case "$branch" in
    */*) key="$(printf '%s' "${branch#*/}" | sed -n 's/^\([A-Za-z][A-Za-z]*-[0-9][0-9]*\).*/\1/p' | tr '[:lower:]' '[:upper:]')" ;;
esac
ROLLDIR="$TMP/roll"; mkdir -p "$ROLLDIR"
HROOT="$TMP/handover"; mkdir -p "$HROOT/breadcrumbs"
if [ -n "$key" ]; then
    printf '%s\n' "{\"epic\":\"HIMMEL-654\",\"done\":7,\"total\":20,\"refreshed_at\":\"2026-07-06T00:00:00Z\"}" > "$ROLLDIR/where-are-we-rollup-$key.json"
    printf '%s\n' "{\"version\":1,\"ticket\":\"$key\"}" > "$HROOT/breadcrumbs/$key.json"
fi

WT="$(cd "$ROOT/.." && pwd)"
stdin_json="$(printf '{"model":{"id":"claude-opus-4-8"},"transcript_path":"%s","cwd":"%s"}' "$TRANSCRIPT" "$WT")"

run_composer() {
    # $@ = extra env assignments already exported by caller.
    printf '%s' "$stdin_json" | \
        HIMMEL_WHERE_ARE_WE_ROLLUP_DIR="$ROLLDIR" HANDOVER_DIR="$HROOT" \
        CLAUDE_ALL_SESSIONS_CACHE_DIR="$ECON_DIR" \
        bash "$COMPOSER" 2>/dev/null
}

# ── Case 2: session economics line (exact computed values) ──────────────────
# claude-opus: read_savings=(5-0.5)/1e6, write_overhead=(10-5)/1e6.
# net = 2e6*4.5e-6 - 1e5*5e-6 = 9.0 - 0.5 = 8.5. hit = 2e6*100/2.05e6 = 97.
out="$(run_composer)"
if printf '%s\n' "$out" | grep -qF 'session  r:2.0M  w:100k  hit:97%  net +$8.5000'; then
    pass "session economics -> exact 'r:2.0M w:100k hit:97% net +\$8.5000'"
else
    fail "session economics -> got: $(printf '%s\n' "$out" | grep -F 'session' || echo '(no session line)')"
fi

# ── Case 3: all-sessions economics line (exact computed values) ─────────────
# net = 45e6*4.5e-6 - 12e6*5e-6 = 202.5 - 60 = 142.5. hit = 45e6*100/48e6 = 93.
if printf '%s\n' "$out" | grep -qE '^all +r:45\.0M  w:12\.0M  hit:93%  net [+]\$142\.5000$'; then
    pass "all-sessions economics -> exact 'all r:45.0M w:12.0M hit:93% net +\$142.5000'"
else
    fail "all-sessions economics -> got: $(printf '%s\n' "$out" | grep -E '^all ' || echo '(no all line)')"
fi

# ── Case 4: WAW parity — composer's WAW line == the segment's own output ─────
if [ -n "$key" ]; then
    seg_line="$(printf '%s' "$stdin_json" | HIMMEL_WHERE_ARE_WE_ROLLUP_DIR="$ROLLDIR" HANDOVER_DIR="$HROOT" \
                bash "$SEGMENT" --cwd "$WT" 2>/dev/null)"
    if [ -n "$seg_line" ] && printf '%s\n' "$out" | grep -qF "$seg_line"; then
        pass "WAW parity -> composer emits the segment line verbatim ('$seg_line')"
    else
        fail "WAW parity -> seg='$seg_line' not found in composer out"
    fi
    # And it must carry the seeded epic rollup.
    if printf '%s\n' "$out" | grep -qF 'HIMMEL-654 7/20'; then
        pass "WAW rollup -> 'HIMMEL-654 7/20' present"
    else
        fail "WAW rollup -> epic part missing"
    fi
else
    pass "WAW parity -> SKIPPED (branch '$branch' yields no ticket key)"
fi

# ── Case 5: env-knob — HIMMEL_WHERE_ARE_WE off suppresses the WAW line ───────
out_off="$(printf '%s' "$stdin_json" | HIMMEL_WHERE_ARE_WE=0 \
    HIMMEL_WHERE_ARE_WE_ROLLUP_DIR="$ROLLDIR" HANDOVER_DIR="$HROOT" \
    CLAUDE_ALL_SESSIONS_CACHE_DIR="$ECON_DIR" bash "$COMPOSER" 2>/dev/null)"
first_line="$(printf '%s\n' "$out_off" | head -n1)"
if ! printf '%s\n' "$out_off" | grep -qF '⎇'; then
    pass "env-knob HIMMEL_WHERE_ARE_WE=0 -> WAW suppressed (first line: '$first_line')"
else
    fail "env-knob HIMMEL_WHERE_ARE_WE=0 -> WAW still present"
fi

# ── Case 6: env-knob — HIMMEL_STATUSLINE_PERIOD switches the all-line label ──
# Seed a week window cache; the composer must read it and label the row 'week'.
NOW_FIXED=1751760000   # 2025-07-06 (deterministic), avoids wall-clock drift
wk_id="week-$(HIMMEL_STATUSLINE_NOW=$NOW_FIXED bash -c '
    now=$1; dow=$(date -d "@$now" +%u 2>/dev/null || date -r "$now" +%u); \
    ymd=$(date -d "@$now" +%Y-%m-%d 2>/dev/null || date -r "$now" +%Y-%m-%d); \
    mid=$(date -d "$ymd 00:00:00" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M:%S" "$ymd 00:00:00" +%s); \
    ws=$(( mid - (dow-1)*86400 )); date -d "@$ws" +%Y%m%d 2>/dev/null || date -r "$ws" +%Y%m%d' _ "$NOW_FIXED")"
printf '%s\n' '{"reads":1000000,"writes":2000,"inputs":500}' > "$ECON_DIR/cache-${wk_id}.json"
out_wk="$(printf '%s' "$stdin_json" | HIMMEL_STATUSLINE_PERIOD=week HIMMEL_STATUSLINE_NOW=$NOW_FIXED \
    HIMMEL_WHERE_ARE_WE_ROLLUP_DIR="$ROLLDIR" HANDOVER_DIR="$HROOT" \
    CLAUDE_ALL_SESSIONS_CACHE_DIR="$ECON_DIR" bash "$COMPOSER" 2>/dev/null)"
if printf '%s\n' "$out_wk" | grep -qE '^week +r:1.0M  w:2k  hit:'; then
    pass "env-knob HIMMEL_STATUSLINE_PERIOD=week -> 'week' row from week cache"
else
    fail "env-knob period=week -> got: $(printf '%s\n' "$out_wk" | grep -E '^(week|all) ' || echo '(no period line)')"
fi

# ── Case 7: fail-open — missing transcript + missing caches → still exits 0 ──
out_empty="$(printf '{"model":{"id":"claude-opus-4-8"},"transcript_path":"/nonexistent","cwd":"%s"}' "$WT" | \
    CLAUDE_ALL_SESSIONS_CACHE_DIR="$TMP/empty" bash "$COMPOSER" 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out_empty" | grep -qF 'session  r:0  w:0  hit:0%  net +$0.0000'; then
    pass "fail-open -> missing inputs render zeros, exit 0"
else
    fail "fail-open -> rc=$rc out='$out_empty'"
fi

echo "---"
echo "composer: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
