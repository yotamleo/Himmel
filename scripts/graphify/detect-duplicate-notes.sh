#!/usr/bin/env bash
# detect-duplicate-notes.sh -- himmel-side detection for HIMMEL-1391: flag a
# re-mint of graphify person-note duplicates (twins, and curated-vs-importer
# overlaps) so a future graphify-out/vault refresh doesn't silently regrow
# the mess dedup-ed by the HIMMEL-1391 luna cleanup.
#
# WHAT IT FLAGS (report-only, never mutates anything):
#   1. TWIN: two files directly under --graph-dir whose basenames are
#      identical once case-folded and a leading "@" stripped (the shape
#      graphify mints per surface-string variant: "@cyrilXBT.md" vs
#      "cyrilxbt.md" vs "CyrilXBT.md").
#   2. OVERLAP: a --graph-dir file whose normalized basename matches a
#      --curated-dir file's normalized basename (a hand-curated person note
#      graphify independently re-minted as an importer stub).
# `_COMMUNITY_*` files are graphify's own community-summary notes, not
# per-entity extractions -- excluded from both checks (never a "twin" of
# anything by design).
#
# Usage:
#   detect-duplicate-notes.sh --graph-dir <dir> [--curated-dir <dir>]
#
# Exit: 0 clean; 1 findings printed (report-only -- the caller decides
# whether that's a lint failure or just an advisory; this script never
# blocks or mutates on its own); 2 usage/arg error.
set -euo pipefail

GRAPH_DIR="" CURATED_DIR=""
usage() { echo "usage: detect-duplicate-notes.sh --graph-dir <dir> [--curated-dir <dir>]" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --graph-dir|--curated-dir)
      # A value-taking flag with no following argument must still hit
      # usage() (rc=2), not an undocumented rc=1 -- `shift 2` with only one
      # positional argument left is itself a FAILING command under
      # `set -e`, and bash aborts on that failure before usage() ever runs
      # (codex-1 CR finding). Check the count first.
      [ $# -ge 2 ] || usage
      [ "$1" = "--graph-dir" ] && GRAPH_DIR="$2" || CURATED_DIR="$2"
      shift 2 ;;
    -h|--help) usage ;;
    *) echo "detect-duplicate-notes: unknown flag: $1" >&2; usage ;;
  esac
done
[ -n "$GRAPH_DIR" ] || usage
[ -d "$GRAPH_DIR" ] || { echo "detect-duplicate-notes: --graph-dir not found: $GRAPH_DIR" >&2; exit 2; }
if [ -n "$CURATED_DIR" ] && [ ! -d "$CURATED_DIR" ]; then
  echo "detect-duplicate-notes: --curated-dir not found: $CURATED_DIR" >&2
  exit 2
fi
command -v python3 >/dev/null 2>&1 || { echo "detect-duplicate-notes: python3 not found" >&2; exit 2; }

python3 - "$GRAPH_DIR" "$CURATED_DIR" <<'PYEOF'
import os, sys

graph_dir, curated_dir = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else "")

def norm(basename_no_ext):
    s = basename_no_ext
    if s.startswith("@"):
        s = s[1:]
    return s.casefold()

def list_notes(d):
    out = {}  # norm-key -> [basenames]
    for fn in os.listdir(d):
        if not fn.lower().endswith(".md"):
            continue
        if not os.path.isfile(os.path.join(d, fn)):
            continue  # a directory (or other non-file) named "*.md" is not a note
        stem = fn[:-3]
        if stem.upper().startswith("_COMMUNITY_"):
            continue
        out.setdefault(norm(stem), []).append(fn)
    return out

graph_notes = list_notes(graph_dir)

findings = 0

for key, files in sorted(graph_notes.items()):
    if len(files) > 1:
        findings += 1
        print("TWIN: " + " | ".join(sorted(files)) + f"  (under {graph_dir})")

if curated_dir:
    curated_notes = list_notes(curated_dir)
    for key, cfiles in sorted(curated_notes.items()):
        if key in graph_notes:
            findings += 1
            print("OVERLAP: curated " + " | ".join(sorted(cfiles)) +
                  " vs importer " + " | ".join(sorted(graph_notes[key])))

if findings:
    print(f"\ndetect-duplicate-notes: {findings} finding(s) -- see HIMMEL-1391 for the dedup pattern/remedy.", file=sys.stderr)
    sys.exit(1)
print("detect-duplicate-notes: clean, no twins/overlaps found.")
sys.exit(0)
PYEOF
