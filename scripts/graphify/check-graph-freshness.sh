#!/usr/bin/env bash
# check-graph-freshness.sh — freshness + corpus-orphan CHECK for one graphify-out
# snapshot (HIMMEL-621/824/825 family). The check companion to
# refresh-graph-map.sh (HIMMEL-825): the refresher REBUILDS the graph; this tells
# a caller (scheduler / operator / query path) whether an existing graphify-out/
# is still trustworthy to query, or has gone stale / orphaned.
#
# WHY: graphify graphs are point-in-time snapshots under <repo>/graphify-out/.
# They drift silently as the corpus changes, and a graphify-out can be left
# pointing at a corpus that no longer exists (orphaned) — queries against a
# stale/orphaned graph return confidently-wrong structure. This guard fails loud
# before that happens.
#
# WHAT IT CHECKS (exit code):
#   rc=2 FAIL — out dir missing; manifest.json missing/unparseable/empty;
#               --corpus-root given but the dir does not exist;
#               corpus orphaned (no --corpus-root AND no .graphify_root marker,
#               OR no file named in manifest.json resolves under the corpus root).
#   rc=1 WARN — graph.json (or manifest.json if graph.json is absent) mtime is
#               older than --max-age-days.
#   rc=0 OK   — fresh AND corpus verified; prints exactly one line:
#               "graph-freshness: OK (<age-days>d old, corpus verified)"
#
# CORPUS RESOLUTION (orphan detection):
#   --corpus-root given → that dir is the corpus root (must exist); the orphan
#     check is skipped (the operator asserted the corpus).
#   no --corpus-root → the .graphify_root marker file in the out dir is read; its
#     first non-blank line is the corpus-root path (absolute, or relative to the
#     out dir's parent). Marker absent OR empty → orphan (rc=2). With the root
#     resolved, at least one file NAMED in manifest.json must exist under it;
#     none found → orphan (rc=2).
#
# Usage:
#   check-graph-freshness.sh --out <graphify-out dir> [--max-age-days N] [--corpus-root <path>]
#
# Exit: 0 ok; 1 stale (warn) / usage; 2 fail (missing/orphaned/unparseable).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REFRESH="$HERE/refresh-graph-map.sh"

OUT="" MAX_AGE_DAYS=7 CORPUS_ROOT=""
usage() { echo "usage: check-graph-freshness.sh --out <graphify-out dir> [--max-age-days N] [--corpus-root <path>]" >&2; exit 1; }
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="${2:-}"; shift 2 ;;
    --max-age-days) MAX_AGE_DAYS="${2:-}"; shift 2 ;;
    --corpus-root) CORPUS_ROOT="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "check-graph-freshness: unknown flag: $1" >&2; usage ;;
  esac
done
[ -n "$OUT" ] || usage
case "$MAX_AGE_DAYS" in
  ''|*[!0-9]*) echo "check-graph-freshness: --max-age-days must be a non-negative integer, got: $MAX_AGE_DAYS" >&2; exit 1 ;;
esac

# Remediation embedded in every non-OK message: the refresh invocation shape
# (mirrors refresh-graph-map.sh's own usage). No --backend: the runner's own
# default (claude-cli since HIMMEL-1049) is the one we want a copy-paste of this
# hint to use — naming a backend here is how it went stale in the first place.
REMEDIATION="Rebuild with: bash $REFRESH --name <N> --corpus-root <path> --maps-dir <vault>/60-Maps --title \"<Title>\" --slug <slug>"

# python3 is required (manifest.json parse + cross-platform mtime). `stat -c %Y`
# is GNU-only and `stat -f %m` is BSD-only, so mtime goes through python3.
command -v python3 >/dev/null 2>&1 || {
  echo "graph-freshness: FAIL python3 not found (needed to parse manifest.json + read mtime)." >&2
  echo "  $REMEDIATION" >&2; exit 2
}

# FAIL: print a one-line reason + the remediation, exit 2.
fail() {
  echo "graph-freshness: FAIL $1" >&2
  echo "  $REMEDIATION" >&2
  exit 2
}

# --- 1. out dir ---
[ -d "$OUT" ] || fail "out dir not found: $OUT"

# --- 2. manifest.json present + parseable (flat object of filename -> {...}) ---
MANIFEST="$OUT/manifest.json"
[ -f "$MANIFEST" ] || fail "manifest.json missing at $MANIFEST."
# Emit one manifest key per line.
#
# UTF-8 IS LOAD-BEARING, BOTH WAYS (HIMMEL-1116). The manifest keys are
# corpus-relative FILENAMES, and a real vault has filenames outside the Windows
# default codepage (Hebrew, emoji). Two separate crashes came from that:
#   * `open()` without encoding= decodes the manifest as cp1252 on Windows -> UnicodeDecodeError
#   * `print(k)` encodes to a cp1252 stdout                                -> UnicodeEncodeError
# Either killed python, which the shell then reported as "manifest unparseable"
# — so the guard failed CLOSED on a perfectly good graph and sent the operator
# into a ~45min/$3 rebuild for nothing. Same class the salus vault_health.py
# already handles with PYTHONUTF8=1.
#
# Exit codes are DISTINCT on purpose: a crash and a corrupt manifest are
# different facts and must not share one message (they did, and that is what
# made the bug hard to see).
#   0 = ok   1 = genuinely not a non-empty JSON object   3 = internal/encoding error
KEYS_RC=0
KEYS="$(python3 - "$MANIFEST" <<'PYEOF'
import json, sys

try:
    sys.stdout.reconfigure(encoding="utf-8")  # py3.7+; keys may be non-cp1252
except AttributeError:                        # pragma: no cover - ancient python
    sys.exit(3)

try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        d = json.load(fh)
except (OSError, UnicodeError) as exc:
    print("read/decode failed: %s" % exc, file=sys.stderr)
    sys.exit(3)
except ValueError:
    sys.exit(1)          # real corruption: not JSON

if not isinstance(d, dict) or not d:
    sys.exit(1)          # real: parsed, but not a non-empty object

for k in d:
    print(k)
PYEOF
)" || KEYS_RC=$?
case "$KEYS_RC" in
  0) ;;
  1) fail "manifest.json at $MANIFEST is not a non-empty JSON object (unparseable/empty)." ;;
  *) fail "manifest.json at $MANIFEST could not be READ (rc=$KEYS_RC; see stderr above) — this is an internal/encoding error, NOT proof the manifest is corrupt. The graph may be fine." ;;
esac

# --- 3. corpus resolution + orphan check ---
if [ -n "$CORPUS_ROOT" ]; then
  # operator asserted the corpus root; only require it to exist.
  [ -d "$CORPUS_ROOT" ] || fail "--corpus-root not found: $CORPUS_ROOT."
  CORPUS_RESOLVED="$CORPUS_ROOT"
else
  MARKER="$OUT/.graphify_root"
  [ -f "$MARKER" ] || fail "corpus orphaned: no --corpus-root given and no .graphify_root marker in $OUT (cannot locate the corpus this graph was built from)."
  # first non-blank line of the marker = corpus-root path
  MARKER_ROOT="$(grep -m1 -v '^[[:space:]]*$' "$MARKER" 2>/dev/null || true)"
  [ -n "$MARKER_ROOT" ] || fail "corpus orphaned: .graphify_root marker in $OUT is empty (cannot locate the corpus)."
  # absolute (POSIX /c/... or drive C:\...) as-is; else relative to the out dir's parent
  case "$MARKER_ROOT" in
    /*|[A-Za-z]:*) CORPUS_RESOLVED="$MARKER_ROOT" ;;
    *)             CORPUS_RESOLVED="$OUT/../$MARKER_ROOT" ;;
  esac
  # at least one manifest-named file must exist under the resolved corpus root.
  # Keys are UNTRUSTED (a corrupt/crafted manifest could carry absolute or
  # ..-traversal paths that "verify" via files OUTSIDE the root — codex CR):
  # only plain relative keys may join the path; others are skipped.
  found=0
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    case "$key" in
      /*|[A-Za-z]:*|../*|*/../*|*/..|..) continue ;;
    esac
    if [ -e "$CORPUS_RESOLVED/$key" ]; then found=1; break; fi
  done <<< "$KEYS"
  [ "$found" -eq 1 ] || fail "corpus orphaned: no file named in manifest.json exists under $CORPUS_RESOLVED (graph references a gone/moved corpus)."
fi

# --- 4. age check (graph.json preferred, else manifest.json mtime) ---
AGE_FILE="$OUT/graph.json"
[ -f "$AGE_FILE" ] || AGE_FILE="$MANIFEST"
# verdict = STALE when real-valued age (days) > max-age-days; floor days for display.
AGE_OUT="$(python3 -c 'import os,sys,time
age=(time.time()-os.path.getmtime(sys.argv[1]))/86400.0
print("STALE" if age > float(sys.argv[2]) else "FRESH", int(age))' "$AGE_FILE" "$MAX_AGE_DAYS")" \
  || fail "cannot read mtime of $AGE_FILE."
read -r AGE_VERDICT AGE_DAYS_FLOOR <<< "$AGE_OUT"
if [ "$AGE_VERDICT" = "STALE" ]; then
  echo "graph-freshness: WARN $AGE_FILE is ${AGE_DAYS_FLOOR}d old (older than --max-age-days $MAX_AGE_DAYS)." >&2
  echo "  $REMEDIATION" >&2
  exit 1
fi

echo "graph-freshness: OK (${AGE_DAYS_FLOOR}d old, corpus verified)"
