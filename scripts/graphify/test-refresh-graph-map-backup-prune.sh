#!/usr/bin/env bash
# test-refresh-graph-map-backup-prune.sh — HIMMEL-3708: refresh-graph-map.sh
# prunes upstream graphify's dated backup dirs (<out>/YYYY-MM-DD/, written by
# backup_if_protected before every semantic/curated promote -- see the
# _prune_graphify_backups doc comment in refresh-graph-map.sh) down to the
# newest N after a successful promote, instead of letting them accumulate
# forever (~150MB/corpus/day, plus each dated GRAPH_REPORT.md getting indexed
# by Obsidian in the luna vault).
#
# Exercises the shipped _prune_graphify_backups() function DIRECTLY: the
# marker-delimited region is sliced VERBATIM out of refresh-graph-map.sh
# (same technique test-refresh-graph-map-lock.sh's T11 uses for the
# extraction-lock protocol) and sourced here, so this suite drives the real
# function body rather than a reimplementation, without paying for a full
# stubbed-graphify refresh run.
#
# Run: bash scripts/graphify/test-refresh-graph-map-backup-prune.sh
# shellcheck disable=SC2015  # A && pass || fail is the intentional test-assert idiom (pass/fail echo, always rc 0)
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/refresh-graph-map.sh"
FAILS=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS+1)); }

WS="$(mktemp -d "${TMPDIR:-/tmp}/rgm-backup-prune.XXXXXX")" || { echo "cannot create test workspace" >&2; exit 1; }
trap 'rm -rf "$WS"' EXIT

# --- slice the marker-delimited protocol out of the shipped script ---
PROTOCOL="$WS/backup-prune-protocol.sh"
slice_protocol() {
  local src="$1" dst="$2"
  python3 - "$src" "$dst" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
start_marker = "# >>> HIMMEL-3708 backup prune protocol"
end_marker = "# <<< HIMMEL-3708 backup prune protocol"
try:
    start = source.index(start_marker)
    end = source.index(end_marker, start)
except ValueError as error:
    raise SystemExit(f"backup prune protocol marker missing: {error}")
pathlib.Path(sys.argv[2]).write_text(source[start:end] + "\n")
PY
}

if ! slice_protocol "$SCRIPT" "$PROTOCOL"; then
  fail "setup: could not slice the shipped backup-prune protocol out of $SCRIPT"
  echo "$FAILS FAILURES"
  exit 1
fi
if ! grep -q "^_prune_graphify_backups()" "$PROTOCOL"; then
  fail "setup: sliced protocol is missing _prune_graphify_backups()"
  echo "$FAILS FAILURES"
  exit 1
fi
# shellcheck source=/dev/null
source "$PROTOCOL"

# mkdate <out-dir> <YYYY-MM-DD> [content] -- a real, empty (or one-file) dated
# backup dir, the shape backup_if_protected actually writes.
mkdate() {
  mkdir -p "$1/$2"
  if [ -n "${3:-}" ]; then printf 'x' > "$1/$2/$3"; fi
}

# --- T1: default (GRAPHIFY_BACKUP_KEEP unset) keeps the newest 3 of 5 ---
echo "T1: default keeps newest 3 of 5, prunes the 2 oldest"
OUT1="$WS/t1/graphify-out"; mkdir -p "$OUT1"
for d in 2026-09-01 2026-09-02 2026-09-03 2026-09-04 2026-09-05; do mkdate "$OUT1" "$d"; done
unset GRAPHIFY_BACKUP_KEEP
err1="$(_prune_graphify_backups "$OUT1" 2>&1 1>/dev/null)"
for d in 2026-09-03 2026-09-04 2026-09-05; do
  [ -d "$OUT1/$d" ] && pass "T1 kept $d" || fail "T1 should have kept $d"
done
for d in 2026-09-01 2026-09-02; do
  [ -d "$OUT1/$d" ] && fail "T1 should have pruned $d" || pass "T1 pruned $d"
done
echo "$err1" | grep -q "pruned 2 dated backup dir" \
  && pass "T1 stderr reports the prune count" \
  || fail "T1 stderr should report 2 pruned: $err1"

# --- T2: GRAPHIFY_BACKUP_KEEP=1 keeps only the single newest ---
echo "T2: GRAPHIFY_BACKUP_KEEP=1 keeps only the newest"
OUT2="$WS/t2/graphify-out"; mkdir -p "$OUT2"
for d in 2026-01-01 2026-01-02 2026-01-03; do mkdate "$OUT2" "$d"; done
GRAPHIFY_BACKUP_KEEP=1 _prune_graphify_backups "$OUT2" >/dev/null 2>&1
[ -d "$OUT2/2026-01-03" ] && pass "T2 kept the newest" || fail "T2 should have kept 2026-01-03"
[ -d "$OUT2/2026-01-01" ] && fail "T2 should have pruned 2026-01-01" || pass "T2 pruned 2026-01-01"
[ -d "$OUT2/2026-01-02" ] && fail "T2 should have pruned 2026-01-02" || pass "T2 pruned 2026-01-02"

# --- T3: GRAPHIFY_BACKUP_KEEP=0 disables pruning entirely ---
echo "T3: GRAPHIFY_BACKUP_KEEP=0 prunes nothing"
OUT3="$WS/t3/graphify-out"; mkdir -p "$OUT3"
for d in 2026-02-01 2026-02-02 2026-02-03 2026-02-04; do mkdate "$OUT3" "$d"; done
err3="$(GRAPHIFY_BACKUP_KEEP=0 _prune_graphify_backups "$OUT3" 2>&1 1>/dev/null)"
n3=0; for d in 2026-02-01 2026-02-02 2026-02-03 2026-02-04; do [ -d "$OUT3/$d" ] && n3=$((n3+1)); done
[ "$n3" -eq 4 ] && pass "T3 all 4 backups survive with KEEP=0" || fail "T3 expected all 4 to survive, $n3 did"
[ -z "$err3" ] && pass "T3 no prune-count line printed" || fail "T3 should print nothing (KEEP=0): $err3"

# --- T4: non-date dirs, cache/, a date-named FILE, and a date-named SYMLINK
# (to a real directory) are never touched, even when pruning fires ---
echo "T4: non-date dirs, cache/, a date-named file, and a date-named symlink survive"
OUT4="$WS/t4/graphify-out"; mkdir -p "$OUT4/cache" "$OUT4/wiki"
printf 'x' > "$OUT4/cache/semantic.bin"
for d in 2026-03-01 2026-03-02 2026-03-03 2026-03-04 2026-03-05; do mkdate "$OUT4" "$d"; done
printf 'fake' > "$OUT4/2026-03-06"                    # date-named FILE, not a dir
SYMLINK_TARGET="$WS/t4-symlink-target"; mkdir -p "$SYMLINK_TARGET"; printf 'x' > "$SYMLINK_TARGET/marker"
ln -s "$SYMLINK_TARGET" "$OUT4/2026-03-07"            # date-named SYMLINK to a real dir
unset GRAPHIFY_BACKUP_KEEP
_prune_graphify_backups "$OUT4" >/dev/null 2>&1
[ -d "$OUT4/cache" ] && [ -f "$OUT4/cache/semantic.bin" ] && pass "T4 cache/ survives untouched" \
  || fail "T4 cache/ should never be touched"
[ -d "$OUT4/wiki" ] && pass "T4 non-date dir wiki/ survives" || fail "T4 wiki/ should never be touched"
[ -f "$OUT4/2026-03-06" ] && pass "T4 date-named FILE survives" || fail "T4 date-named file should never be removed"
[ -L "$OUT4/2026-03-07" ] && [ -d "$SYMLINK_TARGET" ] && [ -f "$SYMLINK_TARGET/marker" ] \
  && pass "T4 date-named SYMLINK survives, target untouched" \
  || fail "T4 date-named symlink (or its target) should never be removed/followed"
# 6 real candidates counting only genuine directories (5 dated dirs; the file
# and the symlink are not candidates at all) -- default keep=3 prunes 2026-03-01/02.
[ -d "$OUT4/2026-03-01" ] && fail "T4 should have pruned 2026-03-01" || pass "T4 pruned 2026-03-01"
[ -d "$OUT4/2026-03-02" ] && fail "T4 should have pruned 2026-03-02" || pass "T4 pruned 2026-03-02"
for d in 2026-03-03 2026-03-04 2026-03-05; do
  [ -d "$OUT4/$d" ] && pass "T4 kept $d" || fail "T4 should have kept $d"
done

# --- T5: a non-integer GRAPHIFY_BACKUP_KEEP warns on stderr and falls back
# to the default of 3 (same behaviour as T1) ---
echo "T5: non-integer GRAPHIFY_BACKUP_KEEP warns and falls back to 3"
OUT5="$WS/t5/graphify-out"; mkdir -p "$OUT5"
for d in 2026-04-01 2026-04-02 2026-04-03 2026-04-04 2026-04-05; do mkdate "$OUT5" "$d"; done
err5="$(GRAPHIFY_BACKUP_KEEP=nope _prune_graphify_backups "$OUT5" 2>&1 1>/dev/null)"
echo "$err5" | grep -q "WARN GRAPHIFY_BACKUP_KEEP must be a non-negative integer" \
  && pass "T5 stderr warns about the bad value" \
  || fail "T5 stderr should warn about GRAPHIFY_BACKUP_KEEP=nope: $err5"
echo "$err5" | grep -q "using default 3" \
  && pass "T5 stderr names the fallback default" \
  || fail "T5 stderr should name the default-3 fallback: $err5"
for d in 2026-04-03 2026-04-04 2026-04-05; do
  [ -d "$OUT5/$d" ] && pass "T5 kept $d (fallback keep=3)" || fail "T5 should have kept $d"
done
for d in 2026-04-01 2026-04-02; do
  [ -d "$OUT5/$d" ] && fail "T5 should have pruned $d (fallback keep=3)" || pass "T5 pruned $d"
done

# --- T6: fewer backups than N -- nothing removed, no prune-count line ---
echo "T6: fewer than N backups removes nothing"
OUT6="$WS/t6/graphify-out"; mkdir -p "$OUT6"
for d in 2026-05-01 2026-05-02; do mkdate "$OUT6" "$d"; done
unset GRAPHIFY_BACKUP_KEEP
err6="$(_prune_graphify_backups "$OUT6" 2>&1 1>/dev/null)"
[ -d "$OUT6/2026-05-01" ] && [ -d "$OUT6/2026-05-02" ] \
  && pass "T6 both backups survive (2 < keep=3)" \
  || fail "T6 both backups should survive"
[ -z "$err6" ] && pass "T6 no prune-count line printed" || fail "T6 should print nothing: $err6"

# --- T7: pruning never changes the caller's exit status, even when rm fails
# on one of the doomed dirs (made unremovable via a read-only parent) ---
echo "T7: a prune failure only WARNs, never flips the caller's exit status"
if [ "$(id -u)" -eq 0 ]; then
  # codex-2: root ignores directory permission bits, so chmod 555 below would
  # never actually block the rm -- the assertions would pass for the wrong
  # reason (or not exercise the failure path at all). Skip rather than assert
  # something this privilege level cannot test.
  echo "  skip: T7 (root ignores dir permissions)"
else
  OUT7="$WS/t7/graphify-out"; mkdir -p "$OUT7"
  for d in 2026-06-01 2026-06-02 2026-06-03 2026-06-04; do mkdate "$OUT7" "$d"; done
  chmod 555 "$OUT7"
  err7="$(unset GRAPHIFY_BACKUP_KEEP; _prune_graphify_backups "$OUT7" 2>&1 1>/dev/null)"; rc7=$?
  chmod 755 "$OUT7"
  [ "$rc7" -eq 0 ] && pass "T7 function still returns 0 despite an rm failure" \
    || fail "T7 should return 0 even when a prune rm fails (got rc=$rc7)"
  echo "$err7" | grep -q "WARN could not prune backup dir" \
    && pass "T7 stderr WARNs about the failed prune" \
    || fail "T7 stderr should WARN about the failed prune: $err7"
  rm -rf "$OUT7" 2>/dev/null
fi

# --- T8: codex-1 -- a digit-only value too large for bash's 64-bit integer
# test (e.g. a fat-fingered extra zero) must warn and fall back to 3, not
# silently disable pruning. Without the length cap, `[ "$keep" -gt 0 ]`
# itself errors (rc=2) and the unguarded `||` reads that as "keep is 0",
# silently skipping every prune -- verified empirically: no warning, no
# prune, exit still 0. ---
echo "T8: a huge GRAPHIFY_BACKUP_KEEP warns and falls back to 3 (does not silently disable pruning)"
OUT8="$WS/t8/graphify-out"; mkdir -p "$OUT8"
for d in 2026-07-01 2026-07-02 2026-07-03 2026-07-04 2026-07-05; do mkdate "$OUT8" "$d"; done
err8="$(GRAPHIFY_BACKUP_KEEP=99999999999999999999 _prune_graphify_backups "$OUT8" 2>&1 1>/dev/null)"; rc8=$?
[ "$rc8" -eq 0 ] && pass "T8 function returns 0 for an oversized value" \
  || fail "T8 should return 0 for an oversized value (got rc=$rc8)"
echo "$err8" | grep -q "WARN GRAPHIFY_BACKUP_KEEP must be a non-negative integer" \
  && pass "T8 stderr warns about the oversized value" \
  || fail "T8 stderr should warn about the oversized GRAPHIFY_BACKUP_KEEP: $err8"
echo "$err8" | grep -q "using default 3" \
  && pass "T8 stderr names the fallback default" \
  || fail "T8 stderr should name the default-3 fallback: $err8"
for d in 2026-07-03 2026-07-04 2026-07-05; do
  [ -d "$OUT8/$d" ] && pass "T8 kept $d (fallback keep=3)" || fail "T8 should have kept $d"
done
for d in 2026-07-01 2026-07-02; do
  [ -d "$OUT8/$d" ] && fail "T8 should have pruned $d (fallback keep=3)" || pass "T8 pruned $d"
done

# --- T9: codex-1 -- a leading-zero GRAPHIFY_BACKUP_KEEP ("010") is read as
# DECIMAL (10), never as octal (8). 9 backups: if misread as octal-8 the
# oldest one would be pruned; read correctly as decimal-10, all 9 survive
# (9 is not > 10). ---
echo "T9: a leading-zero GRAPHIFY_BACKUP_KEEP is normalised as decimal, not octal"
OUT9="$WS/t9/graphify-out"; mkdir -p "$OUT9"
for d in 2026-08-01 2026-08-02 2026-08-03 2026-08-04 2026-08-05 2026-08-06 2026-08-07 2026-08-08 2026-08-09; do
  mkdate "$OUT9" "$d"
done
err9="$(GRAPHIFY_BACKUP_KEEP=010 _prune_graphify_backups "$OUT9" 2>&1 1>/dev/null)"
echo "$err9" | grep -q "WARN GRAPHIFY_BACKUP_KEEP" \
  && fail "T9 should not warn on a valid leading-zero value: $err9" \
  || pass "T9 no bad-value warning for '010'"
n9=0; for d in 2026-08-01 2026-08-02 2026-08-03 2026-08-04 2026-08-05 2026-08-06 2026-08-07 2026-08-08 2026-08-09; do
  [ -d "$OUT9/$d" ] && n9=$((n9+1))
done
[ "$n9" -eq 9 ] && pass "T9 all 9 backups survive ('010' read as decimal 10, not octal 8)" \
  || fail "T9 expected all 9 to survive under keep=10, only $n9 did (leading zero misread as octal?)"

if [ "$FAILS" -ne 0 ]; then echo "$FAILS FAILURES"; exit 1; fi
echo "ALL PASS"
