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

FAILED=0; PASSED=0
pass() { echo "PASS $1"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Extract a top-level function body (def line .. its column-0 closing brace).
extract_fn() { sed -n "/^$1() {/,/^}/p" "$2"; }

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

# ── Case 3: windowed rebuild through the lib (the else-branch path) ──────────
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
