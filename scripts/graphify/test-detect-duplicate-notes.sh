#!/usr/bin/env bash
# test-detect-duplicate-notes.sh -- HIMMEL-1391. Hermetic: temp dirs only.
# Run: bash scripts/graphify/test-detect-duplicate-notes.sh
# shellcheck disable=SC2015  # A && pass || fail is the intentional test-assert idiom
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/detect-duplicate-notes.sh"
FAILS=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS+1)); }

WS="$(mktemp -d)"; trap 'rm -rf "$WS"' EXIT

# --- T1: clean graph dir (no twins, no overlap) -> rc=0 ---
G1="$WS/t1/graph"; mkdir -p "$G1"
printf 'x' > "$G1/@alice.md"
printf 'x' > "$G1/@bob.md"
out=$( bash "$SCRIPT" --graph-dir "$G1" 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && pass "T1 clean graph dir -> rc=0" || fail "T1 rc=0 (got $rc): $out"
echo "$out" | grep -q "clean" && pass "T1 reports clean" || fail "T1 should report clean: $out"

# --- T2: @-vs-bare twin within graph dir -> rc=1, TWIN reported ---
G2="$WS/t2/graph"; mkdir -p "$G2"
printf 'x' > "$G2/@cyrilXBT.md"
printf 'x' > "$G2/cyrilxbt.md"
out=$( bash "$SCRIPT" --graph-dir "$G2" 2>&1 ); rc=$?
[ "$rc" -eq 1 ] && pass "T2 @-vs-bare twin -> rc=1" || fail "T2 rc=1 (got $rc): $out"
echo "$out" | grep -q "^TWIN:" && pass "T2 reports a TWIN line" || fail "T2 should report TWIN: $out"

# --- T3: @-vs-bare twin that ALSO differs in case (both normalizations
# stack: strip leading @, then case-fold) -> rc=1. NOTE: a case-insensitive
# filesystem (Windows, default macOS) cannot hold two files whose names
# differ ONLY by case -- "NykBuilderz.md" and "nykbuilderz.md" collide to
# one directory entry -- so that shape is untestable via real fixtures here
# and isn't the shape graphify actually produces anyway (every real twin
# pair found in HIMMEL-1391 differs by the leading @, not by case alone).
G3="$WS/t3/graph"; mkdir -p "$G3"
printf 'x' > "$G3/@NykBuilderz.md"
printf 'x' > "$G3/nykbuilderz.md"
out=$( bash "$SCRIPT" --graph-dir "$G3" 2>&1 ); rc=$?
[ "$rc" -eq 1 ] && pass "T3 @-vs-bare twin with case difference -> rc=1" || fail "T3 rc=1 (got $rc): $out"

# --- T4: _COMMUNITY_ files excluded from twin detection ---
# Both carry the exact graphify "_COMMUNITY_" prefix and would otherwise
# case-fold-collide on the remainder ("Foo" vs "foo") -- must NOT report a
# TWIN, since community-summary notes are never per-entity extractions.
G4="$WS/t4/graph"; mkdir -p "$G4"
printf 'x' > "$G4/_COMMUNITY_Foo.md"
printf 'x' > "$G4/_COMMUNITY_foo.md"
out=$( bash "$SCRIPT" --graph-dir "$G4" 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && pass "T4 _COMMUNITY_ files excluded -> rc=0" || fail "T4 rc=0 (got $rc): $out"

# --- T5: curated-vs-importer overlap -> rc=1, OVERLAP reported ---
G5="$WS/t5/graph"; C5="$WS/t5/curated"; mkdir -p "$G5" "$C5"
printf 'x' > "$C5/@tom_doerr.md"
printf 'x' > "$G5/tom_doerr.md"
out=$( bash "$SCRIPT" --graph-dir "$G5" --curated-dir "$C5" 2>&1 ); rc=$?
[ "$rc" -eq 1 ] && pass "T5 curated-vs-importer overlap -> rc=1" || fail "T5 rc=1 (got $rc): $out"
echo "$out" | grep -q "^OVERLAP:" && pass "T5 reports an OVERLAP line" || fail "T5 should report OVERLAP: $out"

# --- T6: no --curated-dir -> overlap check skipped, no crash ---
G6="$WS/t6/graph"; mkdir -p "$G6"
printf 'x' > "$G6/@solo.md"
out=$( bash "$SCRIPT" --graph-dir "$G6" 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && pass "T6 no --curated-dir, single note -> rc=0" || fail "T6 rc=0 (got $rc): $out"

# --- T7: usage error on missing --graph-dir ---
out=$( bash "$SCRIPT" 2>&1 ); rc=$?
[ "$rc" -eq 2 ] && pass "T7 missing --graph-dir -> usage rc=2" || fail "T7 usage rc=2 (got $rc)"

# --- T8: bad --graph-dir path -> rc=2 ---
out=$( bash "$SCRIPT" --graph-dir "$WS/no-such-dir" 2>&1 ); rc=$?
[ "$rc" -eq 2 ] && pass "T8 missing dir -> rc=2" || fail "T8 rc=2 (got $rc)"

if [ "$FAILS" -ne 0 ]; then echo "$FAILS FAILURES"; exit 1; fi
echo "ALL PASS"
