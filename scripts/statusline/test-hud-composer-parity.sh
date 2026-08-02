#!/usr/bin/env bash
# Test for scripts/statusline/hud-custom-lines.sh — the spawn-free hud composer
# (HIMMEL-718 Task 3.2). Hermetic: seeded transcript + seeded economics caches +
# seeded rollup/handover; no git/jira/network beyond the local worktree branch.
# Exit: 0 = all pass, 1 = at least one failed.
set -uo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone. (HIMMEL-1430.)
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

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
    #
    # The segment timeout is pinned WELL above the 3s production default on
    # purpose. The composer runs the WAW segment under `timeout` and fails open
    # to an empty line when it overruns — correct on the render path, but it
    # turns the two WAW cases below into a measurement of machine speed: on a
    # loaded box (e.g. immediately after test/test_cache.sh, which spawns jq
    # several hundred times) the ~1s segment crosses 3s and both cases fail with
    # no WAW line at all. Verified by forcing the mechanism directly:
    # HIMMEL_WHERE_ARE_WE_SEG_TIMEOUT=1 reproduces exactly that 2-failure
    # signature. These cases assert composer/segment PARITY, so the segment must
    # be allowed to finish; the timeout's own fail-open behaviour is not what is
    # under test here.
    #
    # Pinned UNCONDITIONALLY, not `${VAR:-30}`: honouring an inherited value let
    # an ambient 1 or 3 in the caller's environment silently reintroduce the very
    # missing-segment flake this pin exists to remove, turning a parity assertion
    # back into a machine-speed one. A hermetic test sets its own preconditions.
    printf '%s' "$stdin_json" | \
        HIMMEL_WHERE_ARE_WE_ROLLUP_DIR="$ROLLDIR" HANDOVER_DIR="$HROOT" \
        CLAUDE_ALL_SESSIONS_CACHE_DIR="$ECON_DIR" \
        HIMMEL_WHERE_ARE_WE_SEG_TIMEOUT=30 \
        bash "$COMPOSER" 2>/dev/null
}

# ── Case 2: session economics line (exact computed values) ──────────────────
# claude-opus: read_savings=(5-0.5)/1e6, write_overhead=(10-5)/1e6.
# net = 2e6*4.5e-6 - 1e5*5e-6 = 9.0 - 0.5 = 8.5. hit = 2e6*100/2.05e6 = 97.
out="$(run_composer)"
# shellcheck disable=SC2016 # $ is literal fixed-string text, not an expansion
if grepq "$out" -F 'session  r:2.0M  w:100k  hit:97%  net +$8.5000'; then
    pass "session economics -> exact 'r:2.0M w:100k hit:97% net +\$8.5000'"
else
    fail "session economics -> got: $(printf '%s\n' "$out" | grep -F 'session' || echo '(no session line)')"
fi

# ── Case 2b: unknown-model guess marker, END-TO-END (HIMMEL-1316, glm-2) ────
# The composer renders the net through format_econ_line, a DIFFERENT code path
# from the legacy bar's build_cache_lines. test/test_cache.sh cannot cover it —
# that suite sources only bin/statusline.sh, which does not define
# format_econ_line — so without this case the composer could drop the marker
# and every suite would still be green. The composer is the future default
# renderer, so this is the path that ends up mattering most.
#
# PAIRED against Case 2 immediately above, which is the negative control: it
# runs the SAME fixture through the recognised `claude-opus-4-8` and asserts the
# exact string `net +$8.5000` with no marker. "Mark every net" would pass this
# case and fail that one.
unknown_json="$(printf '{"model":{"id":"zzz-not-a-real-model"},"transcript_path":"%s","cwd":"%s"}' "$TRANSCRIPT" "$WT")"
out_unknown="$(printf '%s' "$unknown_json" | \
    HIMMEL_WHERE_ARE_WE_ROLLUP_DIR="$ROLLDIR" HANDOVER_DIR="$HROOT" \
    CLAUDE_ALL_SESSIONS_CACHE_DIR="$ECON_DIR" \
    HIMMEL_WHERE_ARE_WE_SEG_TIMEOUT=30 \
    bash "$COMPOSER" 2>/dev/null)"
# LC_ALL=C for the same reason Case 4 needs it — see the note there.
if LC_ALL=C grepq "$out_unknown" -E '^session .*net [+-]\$[0-9.]+\?'; then
    pass "unknown model -> composer marks the net with '?' (guess, not fact)"
else
    fail "unknown model -> no '?' marker: $(printf '%s\n' "$out_unknown" | grep -E '^session ' || echo '(no session line)')"
fi

# ── Case 3: all-sessions economics line (exact computed values) ─────────────
# net = 45e6*4.5e-6 - 12e6*5e-6 = 202.5 - 60 = 142.5. hit = 45e6*100/48e6 = 93.
# shellcheck disable=SC2016 # $ anchors/literals are regex text, not expansion
if grepq "$out" -E '^all +r:45\.0M  w:12\.0M  hit:93%  net [+]\$142\.5000$'; then
    pass "all-sessions economics -> exact 'all r:45.0M w:12.0M hit:93% net +\$142.5000'"
else
    fail "all-sessions economics -> got: $(printf '%s\n' "$out" | grep -E '^all ' || echo '(no all line)')"
fi

# ── Case 4: WAW parity — composer's WAW line == the segment's own output ─────
if [ -n "$key" ]; then
    seg_line="$(printf '%s' "$stdin_json" | HIMMEL_WHERE_ARE_WE_ROLLUP_DIR="$ROLLDIR" HANDOVER_DIR="$HROOT" \
                bash "$SEGMENT" --cwd "$WT" 2>/dev/null)"
    # LC_ALL=C is load-bearing, not decoration. The segment line carries 📋
    # (U+1F4CB), a 4-byte astral-plane character, and GNU grep 3.0 — what
    # Git-Bash/MSYS ships — fails to match an astral character through `-F` when
    # the locale is UTF-8 (en_GB.UTF-8 here): the identical byte sequence is
    # reported as absent. Verified in isolation: the same needle matches under
    # LC_ALL=C and does not under LC_ALL=en_GB.UTF-8, while `⎇` (3-byte) and the
    # ASCII parts match under both. This test compares BYTES for a byte-identity
    # claim, so the C locale is also the semantically correct choice.
    if [ -n "$seg_line" ] && LC_ALL=C grepq "$out" -F "$seg_line"; then
        pass "WAW parity -> composer emits the segment line verbatim ('$seg_line')"
    else
        fail "WAW parity -> seg='$seg_line' not found in composer out"
    fi
    # And it must carry the seeded epic rollup.
    if grepq "$out" -F 'HIMMEL-654 7/20'; then
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
if ! grepq "$out_off" -F '⎇'; then
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
if grepq "$out_wk" -E '^week +r:1.0M  w:2k  hit:'; then
    pass "env-knob HIMMEL_STATUSLINE_PERIOD=week -> 'week' row from week cache"
else
    fail "env-knob period=week -> got: $(printf '%s\n' "$out_wk" | grep -E '^(week|all) ' || echo '(no period line)')"
fi

# ── Case 7: fail-open — missing transcript + missing caches → still exits 0 ──
# HIMMEL-797: a missing transcript means the session's cache stats are
# UNKNOWN, not zero — a bare "r:0 w:0" is indistinguishable from a session
# that genuinely computed to zero usage. The composer now renders the
# explicit "session~ r:? w:? hit:?% net ?" marker for this case (see
# read_session_cache_stats' sess_unknown in hud-custom-lines.sh).
out_empty="$(printf '{"model":{"id":"claude-opus-4-8"},"transcript_path":"/nonexistent","cwd":"%s"}' "$WT" | \
    CLAUDE_ALL_SESSIONS_CACHE_DIR="$TMP/empty" bash "$COMPOSER" 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] && grepq "$out_empty" -F 'session~  r:?  w:?  hit:?%  net ?'; then
    pass "fail-open -> missing transcript renders the unknown marker, exit 0"
else
    fail "fail-open -> rc=$rc out='$out_empty'"
fi

# ── Case 8: HIMMEL-797 regression — a slow/hung transcript parse must not ────
# blank the WHOLE render. Reproduced live: read_session_cache_stats' jq -rs
# re-parses the FULL transcript, uncached, on every render; on a large
# real transcript (tens of MB) that alone measured 6-30s+, well past hud's
# OWN 3s render budget (custom-line-cmd.ts TIMEOUT_MS=3000, which discards
# ALL stdout on timeout) — so one slow session silently blanked EVERY line,
# including the all/total rows below, which read a cheap pre-computed cache
# and have nothing to do with the slow parse. Stubs `jq` to outlive
# HIMMEL_SESSION_CACHE_TIMEOUT and asserts the session row degrades to the
# unknown marker while the all/total rows still render correctly.
REAL_JQ="$(command -v jq)"
STUBDIR="$TMP/stubbin"; mkdir -p "$STUBDIR"
cat > "$STUBDIR/jq" <<STUBEOF
#!/usr/bin/env bash
sleep 3
exec "$REAL_JQ" "\$@"
STUBEOF
chmod +x "$STUBDIR/jq"
out_slow="$(printf '%s' "$stdin_json" | HIMMEL_SESSION_CACHE_TIMEOUT=1 PATH="$STUBDIR:$PATH" \
    HIMMEL_WHERE_ARE_WE=0 CLAUDE_ALL_SESSIONS_CACHE_DIR="$ECON_DIR" bash "$COMPOSER" 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] && grepq "$out_slow" -F 'session~  r:?  w:?  hit:?%  net ?'; then
    pass "HIMMEL-797: slow transcript parse -> session row degrades to unknown marker, exit 0"
else
    fail "HIMMEL-797: slow transcript parse -> rc=$rc session line: $(printf '%s\n' "$out_slow" | grep -F 'session' || echo '(none)')"
fi
# shellcheck disable=SC2016 # $ anchors/literals are regex text, not expansion
if grepq "$out_slow" -E '^all +r:45\.0M  w:12\.0M  hit:93%  net [+]\$142\.5000$'; then
    pass "HIMMEL-797: slow transcript parse -> all row still renders (isolated from the slow session parse)"
else
    fail "HIMMEL-797: slow transcript parse -> all row missing/wrong: $(printf '%s\n' "$out_slow" | grep -E '^all ' || echo '(none)')"
fi

echo "---"
echo "composer: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
