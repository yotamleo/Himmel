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

# --- T4d: majority of manifest paths exist -> corpus verified (HIMMEL-2072) ---
# 3 of 4 manifest-named paths exist under the corpus (75%, above the >50%
# threshold) -- must NOT be called orphaned, unlike the old "at least one
# match" rule this replaces (which also would have passed here, but this
# fixture is the one the ratio-based rule is built for).
OUT="$WS/t4d/graphify-out"; CORPUS="$WS/t4d/corpus"
mkdir -p "$OUT" "$CORPUS/notes"
printf '{"a.md":{"mtime":0},"b.md":{"mtime":0},"notes/c.md":{"mtime":0},"missing.md":{"mtime":0}}\n' > "$OUT/manifest.json"
printf '{"nodes":[],"edges":[]}\n' > "$OUT/graph.json"
printf '# a\n' > "$CORPUS/a.md"; printf '# b\n' > "$CORPUS/b.md"; printf '# c\n' > "$CORPUS/notes/c.md"
printf '%s\n' "$CORPUS" > "$OUT/.graphify_root"
out=$( bash "$SCRIPT" --out "$OUT" --max-age-days 7 2>&1 >/dev/null ); rc=$?
[ "$rc" -eq 0 ] && pass "T4d 3/4 manifest paths exist (75%) -> corpus verified, rc=0" || fail "T4d rc=0 (got $rc): $out"
printf '%s\n' "$out" | grep -q '3/4 manifest paths exist' \
  && pass "T4d prints the measured ratio" || fail "T4d ratio not printed: $out"

# --- T4e: majority of manifest paths MISSING -> orphaned (HIMMEL-2072) ---
# The exact regression this ticket reports: most manifest paths exist on
# disk (75% here too, just the complement of T4d) is NOT this case -- this
# is 1 of 4 existing (25%, below >50% missing threshold), which must FAIL.
OUT="$WS/t4e/graphify-out"; CORPUS="$WS/t4e/corpus"
mkdir -p "$OUT" "$CORPUS"
printf '{"only-real.md":{"mtime":0},"gone1.md":{"mtime":0},"gone2.md":{"mtime":0},"gone3.md":{"mtime":0}}\n' > "$OUT/manifest.json"
printf '{"nodes":[],"edges":[]}\n' > "$OUT/graph.json"
printf '# real\n' > "$CORPUS/only-real.md"
printf '%s\n' "$CORPUS" > "$OUT/.graphify_root"
out=$( bash "$SCRIPT" --out "$OUT" --max-age-days 7 2>&1 >/dev/null ); rc=$?
[ "$rc" -eq 2 ] && pass "T4e 1/4 manifest paths exist (25%) -> orphaned, rc=2" || fail "T4e rc=2 (got $rc): $out"

# --- T4f: EXACTLY 50% existing -> corpus verified, not orphaned (boundary) ---
# codex-1 CR nit: the fail message said "threshold >50% required" but the
# implemented condition (exist*2 < total) passes at exactly 50% -- pin the
# boundary so the message and the behavior can never silently drift apart.
OUT="$WS/t4f/graphify-out"; CORPUS="$WS/t4f/corpus"
mkdir -p "$OUT" "$CORPUS"
printf '{"real1.md":{"mtime":0},"real2.md":{"mtime":0},"gone1.md":{"mtime":0},"gone2.md":{"mtime":0}}\n' > "$OUT/manifest.json"
printf '{"nodes":[],"edges":[]}\n' > "$OUT/graph.json"
printf '# 1\n' > "$CORPUS/real1.md"; printf '# 2\n' > "$CORPUS/real2.md"
printf '%s\n' "$CORPUS" > "$OUT/.graphify_root"
out=$( bash "$SCRIPT" --out "$OUT" --max-age-days 7 2>&1 >/dev/null ); rc=$?
[ "$rc" -eq 0 ] && pass "T4f exactly 2/4 (50%) exist -> corpus verified, rc=0" || fail "T4f rc=0 (got $rc): $out"

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

# Make a git commit N days ago in $1 (repo dir); print its SHA. HIMMEL-1647 fixtures.
git_commit_days_ago() {  # $1=repo dir, $2=days ago
  local repo="$1" days="$2" epoch
  epoch=$(python3 -c 'import time,sys; print(int(time.time()-float(sys.argv[1])*86400))' "$days")
  ( cd "$repo" \
    && git init -q . \
    && git config user.email test@example.com \
    && git config user.name test \
    && git add -A \
    && GIT_AUTHOR_DATE="@$epoch +0000" GIT_COMMITTER_DATE="@$epoch +0000" git commit -q -m init \
    && git rev-parse HEAD )
}

# --- T9: build-identity age overrides a FALSE-FRESH mtime (HIMMEL-1647) ---
# graph.json's own mtime is fresh (just written) but its embedded
# built_at_commit points at a commit 10 days old -- the exact checkout/
# restore shape the ticket describes. Must WARN off the commit's age.
OUT="$WS/t9/graphify-out"; CORPUS="$WS/t9/corpus"; build_out "$OUT" "$CORPUS"
SHA="$(git_commit_days_ago "$CORPUS" 10)"
python3 -c 'import json,sys
json.dump({"built_at_commit": sys.argv[2]}, open(sys.argv[1], "w"))' "$OUT/graph.json" "$SHA"
printf '%s\n' "$CORPUS" > "$OUT/.graphify_root"
bash "$SCRIPT" --out "$OUT" --max-age-days 7 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "T9 fresh mtime + old built_at_commit -> rc=1 (identity wins)" || fail "T9 rc=1 (got $rc)"

# --- T9b: build-identity age also clears a falsely-stale mtime ---
# graph.json's mtime is backdated (would WARN under mtime-only logic) but its
# built_at_commit is fresh (today) -- must report OK.
OUT="$WS/t9b/graphify-out"; CORPUS="$WS/t9b/corpus"; build_out "$OUT" "$CORPUS"
SHA="$(git_commit_days_ago "$CORPUS" 0)"
python3 -c 'import json,sys
json.dump({"built_at_commit": sys.argv[2]}, open(sys.argv[1], "w"))' "$OUT/graph.json" "$SHA"
printf '%s\n' "$CORPUS" > "$OUT/.graphify_root"
backdate_days "$OUT/graph.json" 30
out=$( bash "$SCRIPT" --out "$OUT" --max-age-days 7 2>/dev/null ); rc=$?
[ "$rc" -eq 0 ] && pass "T9b stale mtime + fresh built_at_commit -> rc=0 (identity wins)" || fail "T9b rc=0 (got $rc): $out"

# --- T9c: unresolvable built_at_commit falls back to mtime (unaffected) ---
OUT="$WS/t9c/graphify-out"; CORPUS="$WS/t9c/corpus"; build_out "$OUT" "$CORPUS"
python3 -c 'import json,sys
json.dump({"built_at_commit": "deadbeef"}, open(sys.argv[1], "w"))' "$OUT/graph.json"
printf '%s\n' "$CORPUS" > "$OUT/.graphify_root"
backdate_days "$OUT/graph.json" 10
bash "$SCRIPT" --out "$OUT" --max-age-days 7 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "T9c unresolvable built_at_commit falls back to mtime -> rc=1" || fail "T9c rc=1 (got $rc)"

# --- T9d: non-SHA built_at_commit ("--all") is rejected, falls back to mtime ---
# codex-1 CR finding: an unvalidated built_at_commit passed straight to
# `git log` lets a value like "--all" be parsed as a git OPTION (not a
# revision), resolving to an unrelated, often-fresher timestamp. Must be
# rejected before reaching git.
OUT="$WS/t9d/graphify-out"; CORPUS="$WS/t9d/corpus"; build_out "$OUT" "$CORPUS"
git_commit_days_ago "$CORPUS" 0 >/dev/null
python3 -c 'import json,sys
json.dump({"built_at_commit": "--all"}, open(sys.argv[1], "w"))' "$OUT/graph.json"
printf '%s\n' "$CORPUS" > "$OUT/.graphify_root"
backdate_days "$OUT/graph.json" 10
bash "$SCRIPT" --out "$OUT" --max-age-days 7 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "T9d built_at_commit=--all rejected, falls back to mtime -> rc=1" || fail "T9d rc=1 (got $rc)"

# --- T9e: non-SHA built_at_commit ("HEAD") is rejected, falls back to mtime ---
OUT="$WS/t9e/graphify-out"; CORPUS="$WS/t9e/corpus"; build_out "$OUT" "$CORPUS"
git_commit_days_ago "$CORPUS" 0 >/dev/null
python3 -c 'import json,sys
json.dump({"built_at_commit": "HEAD"}, open(sys.argv[1], "w"))' "$OUT/graph.json"
printf '%s\n' "$CORPUS" > "$OUT/.graphify_root"
backdate_days "$OUT/graph.json" 10
bash "$SCRIPT" --out "$OUT" --max-age-days 7 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "T9e built_at_commit=HEAD rejected, falls back to mtime -> rc=1" || fail "T9e rc=1 (got $rc)"

if [ "$FAILS" -ne 0 ]; then echo "$FAILS FAILURES"; exit 1; fi
echo "ALL PASS"
