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
# hit = 2e6*100/2.05e6 = 97. The row is END-ANCHORED: HIMMEL-2265 removed the
# trailing `net <±>$<n>` cache-savings figure, and an unanchored match would
# still pass if it came back.
out="$(run_composer)"
if grepq "$out" -E '^session  r:2\.0M  w:100k  hit:97%$'; then
    pass "session economics -> exact 'r:2.0M w:100k hit:97%' (no net figure)"
else
    fail "session economics -> got: $(printf '%s\n' "$out" | grep -F 'session' || echo '(no session line)')"
fi

# ── Case 2b: REMOVED by HIMMEL-2265 ─────────────────────────────────────────
# This case asserted the HIMMEL-1316 `?` guess-marker on the session row's
# `net` — the marker that flagged a model priced by the per-model price
# table's `*)` Sonnet-rate fallback. HIMMEL-2265 removed the whole
# cache-savings figure (and the price table with it) from the composer, so
# there is no net to mark and no rate to guess: the enforcement is deliberately
# deleted WITH the feature it enforced, not weakened. Cases 2 and 3 are now
# END-ANCHORED, which is what keeps the figure from silently returning.
# (The legacy bar keeps its own price table until Task 5.4 decommissions it;
# its `?`-marker coverage lives on in test/test_cache.sh.)

# ── Case 3: all-sessions economics line (exact computed values) ─────────────
# hit = 45e6*100/48e6 = 93. END-ANCHORED for the same reason as Case 2.
if grepq "$out" -E '^all +r:45\.0M  w:12\.0M  hit:93%$'; then
    pass "all-sessions economics -> exact 'all r:45.0M w:12.0M hit:93%' (no net figure)"
else
    fail "all-sessions economics -> got: $(printf '%s\n' "$out" | grep -E '^all ' || echo '(no all line)')"
fi

# ── Case 3b: token-volume row — `used:` only, no `cache:` (HIMMEL-2265) ──────
# total used = inputs + reads + writes + outputs = 3e6 + 45e6 + 12e6 + 0 = 60.0M
# (the seeded all-stats cache carries no `.outputs`, so it reads as 0).
# END-ANCHORED, and paired with the whole-render negative below: together they
# pin that the removed `cache:<read+creation>` field does not come back — on
# this row or any other.
if grepq "$out" -E '^total +used:60\.0M$'; then
    pass "token volume -> exact 'total used:60.0M' (cache: field removed)"
else
    fail "token volume -> got: $(printf '%s\n' "$out" | grep -E '^total ' || echo '(no total line)')"
fi

# ── Case 3c: whole-render negative — no money figure, no `cache:` field ──────
# The composer no longer prices anything: HIMMEL-2265 deleted the hand-
# maintained per-model rate card whose figures drifted from live pricing. The
# end-anchored cases above pin the three rows they each name; this pins the
# ABSENCE across the WHOLE render, so a savings figure or a `cache:` field
# reintroduced on some OTHER row still fails. Kept as two separate assertions
# so a failure names which one came back.
if grepq "$out" -E 'net +[+-]?\$'; then
    fail "no-money -> a '\$' net figure is back: $(printf '%s\n' "$out" | grep -E 'net +[+-]?\$')"
else
    pass "no-money -> no net \$ figure anywhere in the render"
fi
if grepq "$out" -F 'cache:'; then
    fail "no-cache-field -> 'cache:' is back: $(printf '%s\n' "$out" | grep -F 'cache:')"
else
    pass "no-cache-field -> no 'cache:' field anywhere in the render"
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

# ── Case 4b: EMPTY transcript_path must not shift cwd (HIMMEL-2265) ──────────
# The stdin fields are read through ONE `read` with a single-char IFS. Tab is
# IFS *whitespace*, so a leading EMPTY field collapses and every later field
# shifts left — and `.transcript_path` is legitimately empty on a session with
# no transcript yet. Under a tab separator that silently handed the WAW segment
# an empty --cwd (it fell back to $PWD), which is invisible in the econ rows and
# only shows up as a wrong/missing where-are-we line. The composer uses the US
# (\037) separator for exactly this reason; this case is what keeps it there.
#
# Asserted through a STUB segment that echoes the --cwd it was handed, because
# the real segment's output does not reveal which cwd it received. The stub
# lives beside a COPY of the composer so $ROOT/where-are-we resolves to it.
# (the composer invokes it as `bash "$seg" --cwd "$cwd"`, so the value is $2.)
SHIFT_TMP="$TMP/cwdshift"
mkdir -p "$SHIFT_TMP/where-are-we"
printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null 2>&1 || true' 'echo "SEG-CWD=$2"' \
    > "$SHIFT_TMP/where-are-we/statusline-segment.sh"
cp -r "$DIR" "$SHIFT_TMP/statusline"
out_shift="$(printf '{"transcript_path":"","cwd":"/expected/cwd"}' | \
    CLAUDE_ALL_SESSIONS_CACHE_DIR="$ECON_DIR" bash "$SHIFT_TMP/statusline/hud-custom-lines.sh" 2>/dev/null)"
if grepq "$out_shift" -F 'SEG-CWD=/expected/cwd'; then
    pass "empty transcript_path -> cwd survives (no leading-empty-field shift)"
else
    fail "empty transcript_path -> cwd shifted: $(printf '%s\n' "$out_shift" | grep -F 'SEG-CWD=' || echo '(no SEG-CWD line)')"
fi
# Negative control for the SAME fixture: a NON-empty transcript_path must still
# parse both fields, so the fix cannot be "always ignore the first field".
out_shift2="$(printf '{"transcript_path":"%s","cwd":"/expected/cwd"}' "$TRANSCRIPT" | \
    CLAUDE_ALL_SESSIONS_CACHE_DIR="$ECON_DIR" bash "$SHIFT_TMP/statusline/hud-custom-lines.sh" 2>/dev/null)"
if grepq "$out_shift2" -F 'SEG-CWD=/expected/cwd' && grepq "$out_shift2" -E '^session  r:2\.0M'; then
    pass "non-empty transcript_path -> both fields parse (cwd AND the transcript)"
else
    fail "non-empty transcript_path -> got: $(printf '%s\n' "$out_shift2" | grep -E 'SEG-CWD=|^session' || echo '(nothing)')"
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
# explicit "session~ r:? w:? hit:?%" marker for this case (see
# read_session_cache_stats' sess_unknown in hud-custom-lines.sh).
out_empty="$(printf '{"model":{"id":"claude-opus-4-8"},"transcript_path":"/nonexistent","cwd":"%s"}' "$WT" | \
    CLAUDE_ALL_SESSIONS_CACHE_DIR="$TMP/empty" bash "$COMPOSER" 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] && grepq "$out_empty" -E '^session~  r:\?  w:\?  hit:\?%$'; then
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
if [ "$rc" -eq 0 ] && grepq "$out_slow" -E '^session~  r:\?  w:\?  hit:\?%$'; then
    pass "HIMMEL-797: slow transcript parse -> session row degrades to unknown marker, exit 0"
else
    fail "HIMMEL-797: slow transcript parse -> rc=$rc session line: $(printf '%s\n' "$out_slow" | grep -F 'session' || echo '(none)')"
fi
if grepq "$out_slow" -E '^all +r:45\.0M  w:12\.0M  hit:93%$'; then
    pass "HIMMEL-797: slow transcript parse -> all row still renders (isolated from the slow session parse)"
else
    fail "HIMMEL-797: slow transcript parse -> all row missing/wrong: $(printf '%s\n' "$out_slow" | grep -E '^all ' || echo '(none)')"
fi

# ── Case 9: env-knob — HIMMEL_STATUSLINE_ECON off suppresses lines 2-4 ───────
# Group toggle, not three: one knob suppresses session + all + total together.
# Same normalisation contract as HIMMEL_WHERE_ARE_WE (Case 5) — WAW stays on
# here so this case can't be confused with WAW's own suppression.
out_econ_off="$(printf '%s' "$stdin_json" | HIMMEL_STATUSLINE_ECON=0 \
    HIMMEL_WHERE_ARE_WE_ROLLUP_DIR="$ROLLDIR" HANDOVER_DIR="$HROOT" \
    CLAUDE_ALL_SESSIONS_CACHE_DIR="$ECON_DIR" HIMMEL_WHERE_ARE_WE_SEG_TIMEOUT=30 \
    bash "$COMPOSER" 2>/dev/null)"
if ! grepq "$out_econ_off" -E '^(session|session~|all|week|month|all~|total) '; then
    pass "env-knob HIMMEL_STATUSLINE_ECON=0 -> all three econ rows suppressed"
else
    fail "env-knob HIMMEL_STATUSLINE_ECON=0 -> an econ row survived: $(printf '%s\n' "$out_econ_off" | grep -E '^(session|session~|all|week|month|all~|total) ')"
fi
if grepq "$out_econ_off" -F '⎇'; then
    pass "env-knob HIMMEL_STATUSLINE_ECON=0 -> WAW line untouched (group toggle scoped to econ only)"
else
    fail "env-knob HIMMEL_STATUSLINE_ECON=0 -> WAW line disappeared too (knob over-scoped)"
fi
# Accepted-value parity with HIMMEL_WHERE_ARE_WE: 'off' (mixed case, padded
# whitespace) must normalise the same way (tr-lowercase then tr-d-whitespace).
out_econ_off2="$(printf '%s' "$stdin_json" | HIMMEL_STATUSLINE_ECON=' Off ' \
    HIMMEL_WHERE_ARE_WE_ROLLUP_DIR="$ROLLDIR" HANDOVER_DIR="$HROOT" \
    CLAUDE_ALL_SESSIONS_CACHE_DIR="$ECON_DIR" HIMMEL_WHERE_ARE_WE_SEG_TIMEOUT=30 \
    bash "$COMPOSER" 2>/dev/null)"
if ! grepq "$out_econ_off2" -E '^(session|session~|all|week|month|all~|total) '; then
    pass "env-knob HIMMEL_STATUSLINE_ECON=' Off ' -> normalises like HIMMEL_WHERE_ARE_WE"
else
    fail "env-knob HIMMEL_STATUSLINE_ECON=' Off ' -> not suppressed: $(printf '%s\n' "$out_econ_off2" | grep -E '^(session|session~|all|week|month|all~|total) ')"
fi

# ── Case 10: HIMMEL_STATUSLINE_ECON gates the WORK, not just the emit ────────
# Proven by INSTRUMENTATION, not wall-clock: the composer's own stdin-parse jq
# call (line ~63, unconditional) would confound a timing assertion against a
# stub that sleeps on every jq invocation. read_session_cache_stats is the
# ONLY caller in this file that passes jq the `-rs` (slurp) flag, so a stub
# that marks a sentinel file only on `-rs` isolates "read_session_cache_stats
# ran" from every other jq call in the render.
MARKDIR="$TMP/callmark"; mkdir -p "$MARKDIR"
cat > "$STUBDIR/jq" <<STUBEOF
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = "-rs" ] && touch "$MARKDIR/hit"; done
exec "$REAL_JQ" "\$@"
STUBEOF
chmod +x "$STUBDIR/jq"
rm -f "$MARKDIR/hit"
out_skip="$(printf '%s' "$stdin_json" | HIMMEL_STATUSLINE_ECON=0 PATH="$STUBDIR:$PATH" \
    HIMMEL_WHERE_ARE_WE=0 CLAUDE_ALL_SESSIONS_CACHE_DIR="$ECON_DIR" \
    bash "$COMPOSER" 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out_skip" ] && [ ! -f "$MARKDIR/hit" ]; then
    pass "HIMMEL-2319: ECON=0 skips the read_session_cache_stats CALL (no -rs jq invocation, no compute-then-discard)"
else
    hit_state=no; [ -f "$MARKDIR/hit" ] && hit_state=yes
    fail "HIMMEL-2319: ECON=0 -> rc=$rc out='$out_skip' -rs-invoked=$hit_state (expensive call still fired)"
fi
# Negative control: with the knob left on (default), the call DOES fire — this
# proves the marker mechanism itself works live, not just that it defaults to
# absent.
rm -f "$MARKDIR/hit"
out_on="$(printf '%s' "$stdin_json" | PATH="$STUBDIR:$PATH" HIMMEL_WHERE_ARE_WE=0 \
    CLAUDE_ALL_SESSIONS_CACHE_DIR="$ECON_DIR" bash "$COMPOSER" 2>/dev/null)"; rc2=$?
if [ "$rc2" -eq 0 ] && [ -f "$MARKDIR/hit" ]; then
    pass "negative control: ECON on (default) -> read_session_cache_stats DOES fire (marker mechanism verified live)"
else
    fail "negative control: ECON on -> marker not set (rc=$rc2), mechanism did not verify the CALL"
fi

echo "---"
echo "composer: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
