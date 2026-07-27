#!/usr/bin/env bash
# Test for scripts/statusline/lib/all-sessions-index.sh (HIMMEL-718 Task 3.2).
# The lib is an EXTRACTED-VERBATIM copy of resolve_window +
# rebuild_all_sessions_index from the legacy bar (scripts/statusline/bin/
# statusline.sh); until the legacy bar is decommissioned (plan Task 5.4) both
# copies must stay byte-identical or the composer/hook economics silently drift
# from the bash bar. This test enforces that "do NOT diverge" invariant
# STRUCTURALLY (not by prose), plus a windowed-rebuild smoke through the lib.
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$DIR/lib/all-sessions-index.sh"
LEGACY="$DIR/bin/statusline.sh"
COMPOSER="$DIR/hud-custom-lines.sh"

FAILED=0; PASSED=0
pass() { echo "PASS $1"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Extract a top-level function body (def line .. its column-0 closing brace).
extract_fn() { sed -n "/^$1() {/,/^}/p" "$2"; }

# Extract a top-level single-quoted heredoc-style assignment
# (`NAME='` .. the lone closing `'`). Used for the shared jq program below,
# which is a VARIABLE, not a function, so extract_fn cannot reach it.
extract_var() { sed -n "/^$1='/,/^'\$/p" "$2"; }

# ── Case 1: resolve_window byte-identical between lib and legacy ─────────────
lib_rw="$TMP/lib-rw"; leg_rw="$TMP/leg-rw"
extract_fn resolve_window "$LIB"    > "$lib_rw"
extract_fn resolve_window "$LEGACY" > "$leg_rw"
if [ -s "$lib_rw" ] && [ -s "$leg_rw" ] && diff -u "$leg_rw" "$lib_rw" >/dev/null 2>&1; then
    pass "resolve_window byte-identical (lib == legacy)"
else
    fail "resolve_window DIVERGED (lib vs legacy):"
    diff -u "$leg_rw" "$lib_rw" | head -20
fi

# ── Case 2: rebuild_all_sessions_index byte-identical ───────────────────────
lib_rb="$TMP/lib-rb"; leg_rb="$TMP/leg-rb"
extract_fn rebuild_all_sessions_index "$LIB"    > "$lib_rb"
extract_fn rebuild_all_sessions_index "$LEGACY" > "$leg_rb"
if [ -s "$lib_rb" ] && [ -s "$leg_rb" ] && diff -u "$leg_rb" "$lib_rb" >/dev/null 2>&1; then
    pass "rebuild_all_sessions_index byte-identical (lib == legacy)"
else
    fail "rebuild_all_sessions_index DIVERGED (lib vs legacy):"
    diff -u "$leg_rb" "$lib_rb" | head -40
fi

# ── Cases 3-4: the rebuild's HELPERS byte-identical (glm-2, HIMMEL-1300) ─────
# _hud_write_index_checkpoint and _hud_rb_rmtemps are duplicated into the
# legacy bar under the SAME "do NOT diverge" invariant as the two functions
# above, but nothing enforced it — and they are not incidental: the checkpoint
# writer owns the atomic publish AND the R3-1 index-mtime pinning, so a drifted
# copy silently changes which files the NEXT pass considers stale. The temp
# reaper is the kill-path cleanup the periodic hook calls by name. Same
# structural enforcement, one case each.
for _fn in _hud_write_index_checkpoint _hud_rb_rmtemps; do
    _lib_h="$TMP/lib-$_fn"; _leg_h="$TMP/leg-$_fn"
    extract_fn "$_fn" "$LIB"    > "$_lib_h"
    extract_fn "$_fn" "$LEGACY" > "$_leg_h"
    if [ -s "$_lib_h" ] && [ -s "$_leg_h" ] && diff -u "$_leg_h" "$_lib_h" >/dev/null 2>&1; then
        pass "$_fn byte-identical (lib == legacy)"
    else
        fail "$_fn DIVERGED (lib vs legacy):"
        diff -u "$_leg_h" "$_lib_h" | head -40
    fi
done

# ── Cases 5-6: _HUD_DEDUP_JQ byte-identical across ALL THREE copies ──────────
# The dedup jq program is the actual accounting rule (HIMMEL-1300): if the
# composer's copy drifts from the rebuild's, the `session` row and the `all` row
# start counting the SAME transcripts differently and the discrepancy is
# invisible — both rows still render, just with numbers that no longer agree.
# It lives in three files (lib, legacy bar, composer) and is a variable, so the
# two function diffs above never covered it. Same structural enforcement, one
# case per pair against the lib as the reference copy.
lib_jq="$TMP/lib-jq"
extract_var _HUD_DEDUP_JQ "$LIB" > "$lib_jq"
if [ ! -s "$lib_jq" ]; then
    fail "_HUD_DEDUP_JQ not extractable from the lib (extractor or definition changed shape)"
fi
for _pair in "legacy:$LEGACY" "composer:$COMPOSER"; do
    _name="${_pair%%:*}"; _file="${_pair#*:}"
    _out="$TMP/$_name-jq"
    extract_var _HUD_DEDUP_JQ "$_file" > "$_out"
    if [ -s "$lib_jq" ] && [ -s "$_out" ] && diff -u "$_out" "$lib_jq" >/dev/null 2>&1; then
        pass "_HUD_DEDUP_JQ byte-identical (lib == $_name)"
    else
        fail "_HUD_DEDUP_JQ DIVERGED (lib vs $_name):"
        diff -u "$_out" "$lib_jq" | head -40
    fi
done

# ── Case 7: windowed rebuild through the lib (the else-branch path) ──────────
# Drive rebuild_all_sessions_index in WINDOWED mode directly and assert only the
# in-window assistant messages are summed (the fromdateiso8601 timestamp filter).
# shellcheck source=scripts/statusline/lib/all-sessions-index.sh disable=SC1091
. "$LIB"
PROJ="$TMP/projects"; mkdir -p "$PROJ/s"
# One message inside the window (2026-07-06), one outside (2026-06-01).
{
  printf '%s\n' '{"type":"assistant","timestamp":"2026-07-06T12:00:00.000Z","message":{"usage":{"cache_read_input_tokens":1000000,"cache_creation_input_tokens":10000,"input_tokens":5000}}}'
  printf '%s\n' '{"type":"assistant","timestamp":"2026-06-01T12:00:00.000Z","message":{"usage":{"cache_read_input_tokens":9000000,"cache_creation_input_tokens":90000,"input_tokens":45000}}}'
} > "$PROJ/s/t.jsonl"
ws=$(date -d "2026-07-06 00:00:00" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M:%S" "2026-07-06 00:00:00" +%s 2>/dev/null)
we=$(( ws + 86400 ))
cf="$TMP/cache-win.json"; xf="$TMP/cache-win-index.json"
rebuild_all_sessions_index "$PROJ" "$cf" "$xf" "$ws" "$we"
if [ -f "$cf" ]; then
    r=$(jq -r '.reads' "$cf" 2>/dev/null)
    if [ "$r" = "1000000" ]; then
        pass "windowed rebuild -> only in-window message summed (reads=1000000)"
    else
        fail "windowed rebuild -> reads=$r (expected 1000000, out-of-window leaked?)"
    fi
else
    fail "windowed rebuild -> no cache written"
fi

echo "---"
echo "lib-parity: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
