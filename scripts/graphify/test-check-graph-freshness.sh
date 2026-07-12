#!/usr/bin/env bash
# Hermetic test for check-graph-freshness.sh — temp dirs only, never touches a
# real graphify-out. Run: bash scripts/graphify/test-check-graph-freshness.sh
# shellcheck disable=SC2015  # A && pass || fail is the intentional test-assert idiom (pass/fail echo, always rc 0)
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/check-graph-freshness.sh"
FAILS=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS+1)); }

WS="$(mktemp -d)"; trap 'rm -rf "$WS"' EXIT

# Build a graphify-out fixture: manifest (flat + nested key) + graph.json + a
# corpus holding both named files. Does NOT write the .graphify_root marker.
build_out() {  # $1=out dir, $2=corpus dir
  mkdir -p "$1" "$2/notes"
  printf '{"real.md": {"mtime": 0, "ast_hash": "x"}, "notes/sub.md": {"mtime": 0}}\n' > "$1/manifest.json"
  printf '{"nodes":[],"edges":[]}\n' > "$1/graph.json"
  printf '# real\n' > "$2/real.md"
  printf '# sub\n' > "$2/notes/sub.md"
}

# Backdate a file's mtime by N days (portable os.utime; touch -d is GNU-only).
backdate_days() {  # $1=file, $2=days ago
  python3 -c 'import os,sys,time
f=sys.argv[1]; d=float(sys.argv[2])*86400; now=time.time(); os.utime(f,(now-d,now-d))' "$1" "$2"
}

# --- T1: ok fresh (marker points at a corpus holding a manifest-named file) ---
OUT="$WS/t1/graphify-out"; CORPUS="$WS/t1/corpus"; build_out "$OUT" "$CORPUS"
printf '%s\n' "$CORPUS" > "$OUT/.graphify_root"
out=$( bash "$SCRIPT" --out "$OUT" --max-age-days 7 2>/dev/null ); rc=$?
[ "$rc" -eq 0 ] && pass "T1 fresh + verified corpus exits 0" || fail "T1 exit 0 (got $rc): $out"
printf '%s\n' "$out" | grep -Eq '^graph-freshness: OK \([0-9]+d old, corpus verified\)$' \
  && pass "T1 OK line shape" || fail "T1 OK line shape: $out"

# --- T2: warn old (graph.json backdated beyond --max-age-days) ---
OUT="$WS/t2/graphify-out"; CORPUS="$WS/t2/corpus"; build_out "$OUT" "$CORPUS"
printf '%s\n' "$CORPUS" > "$OUT/.graphify_root"
backdate_days "$OUT/graph.json" 10
bash "$SCRIPT" --out "$OUT" --max-age-days 7 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "T2 stale graph -> rc=1 (warn)" || fail "T2 rc=1 (got $rc)"

# --- T2b: under --max-age-days stays OK (comparison not inverted; 3d < 7d) ---
OUT="$WS/t2b/graphify-out"; CORPUS="$WS/t2b/corpus"; build_out "$OUT" "$CORPUS"
printf '%s\n' "$CORPUS" > "$OUT/.graphify_root"
backdate_days "$OUT/graph.json" 3
out=$( bash "$SCRIPT" --out "$OUT" --max-age-days 7 2>/dev/null ); rc=$?
[ "$rc" -eq 0 ] && pass "T2b 3d-old graph under --max-age-days 7 -> rc=0" || fail "T2b rc=0 (got $rc): $out"

# --- T3: fail missing manifest ---
OUT="$WS/t3/graphify-out"; CORPUS="$WS/t3/corpus"; build_out "$OUT" "$CORPUS"
rm -f "$OUT/manifest.json"
bash "$SCRIPT" --out "$OUT" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && pass "T3 missing manifest -> rc=2" || fail "T3 rc=2 (got $rc)"

# --- T3b: fail unparseable manifest ---
OUT="$WS/t3b/graphify-out"; CORPUS="$WS/t3b/corpus"; build_out "$OUT" "$CORPUS"
printf '{not json' > "$OUT/manifest.json"
bash "$SCRIPT" --out "$OUT" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && pass "T3b unparseable manifest -> rc=2" || fail "T3b rc=2 (got $rc)"

# --- T4: fail orphaned (no marker AND no --corpus-root) ---
OUT="$WS/t4/graphify-out"; CORPUS="$WS/t4/corpus"; build_out "$OUT" "$CORPUS"
# deliberately no .graphify_root, no --corpus-root
bash "$SCRIPT" --out "$OUT" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && pass "T4 orphaned (no marker, no --corpus-root) -> rc=2" || fail "T4 rc=2 (got $rc)"

# --- T4b: fail orphaned (marker present but no manifest-named file under it) ---
OUT="$WS/t4b/graphify-out"; CORPUS="$WS/t4b/corpus"; build_out "$OUT" "$CORPUS"
EMPTYCORPUS="$WS/t4b/empty"; mkdir -p "$EMPTYCORPUS"
printf '%s\n' "$EMPTYCORPUS" > "$OUT/.graphify_root"
bash "$SCRIPT" --out "$OUT" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && pass "T4b orphaned (marker -> empty corpus) -> rc=2" || fail "T4b rc=2 (got $rc)"

# --- T4c: traversal/absolute manifest keys must NOT verify the corpus (codex CR) ---
# Manifest carries only an absolute key and a ..-traversal key, both resolving
# to REAL files OUTSIDE the (empty) corpus root — the guard must still call it
# orphaned (rc=2), never "verified" through an escaped path join.
OUT="$WS/t4c/graphify-out"; CORPUS="$WS/t4c/corpus"; build_out "$OUT" "$CORPUS"
EMPTYCORPUS="$WS/t4c/empty"; mkdir -p "$EMPTYCORPUS"
printf '# outside\n' > "$WS/t4c/outside.md"
printf '{"%s": {"mtime": 0}, "../outside.md": {"mtime": 0}}\n' "$WS/t4c/outside.md" > "$OUT/manifest.json"
printf '%s\n' "$EMPTYCORPUS" > "$OUT/.graphify_root"
bash "$SCRIPT" --out "$OUT" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && pass "T4c absolute/traversal manifest keys skipped -> rc=2" || fail "T4c rc=2 (got $rc)"

# --- T5: fail bad --corpus-root (dir does not exist) ---
OUT="$WS/t5/graphify-out"; CORPUS="$WS/t5/corpus"; build_out "$OUT" "$CORPUS"
bash "$SCRIPT" --out "$OUT" --corpus-root "$WS/nope" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && pass "T5 missing --corpus-root -> rc=2" || fail "T5 rc=2 (got $rc)"

# --- T6: ok with explicit --corpus-root (no marker needed) ---
OUT="$WS/t6/graphify-out"; CORPUS="$WS/t6/corpus"; build_out "$OUT" "$CORPUS"
out=$( bash "$SCRIPT" --out "$OUT" --corpus-root "$CORPUS" --max-age-days 7 2>/dev/null ); rc=$?
[ "$rc" -eq 0 ] && pass "T6 explicit --corpus-root exits 0 (no marker)" || fail "T6 exit 0 (got $rc): $out"

# --- T7: fail missing out dir ---
bash "$SCRIPT" --out "$WS/no-such-dir" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && pass "T7 missing out dir -> rc=2" || fail "T7 rc=2 (got $rc)"

# --- T8: usage error on missing --out ---
bash "$SCRIPT" --max-age-days 7 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "T8 missing --out -> usage rc=1" || fail "T8 usage rc=1 (got $rc)"

if [ "$FAILS" -ne 0 ]; then echo "$FAILS FAILURES"; exit 1; fi
echo "ALL PASS"
