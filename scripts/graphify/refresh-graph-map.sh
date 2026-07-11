#!/usr/bin/env bash
# refresh-graph-map.sh — incremental graphify refresh + curated-MOC publish for
# one corpus (HIMMEL-825). The schedulable core behind the interval refresh that
# bounds graph drift.
#
# WHY: graphify graphs are point-in-time snapshots that drift as the corpus
# changes. A full sync is ~$2 (measured 2026-07-09); `graphify --update` is
# INCREMENTAL (only changed files re-extracted) so a frequent (e.g. daily) run
# is cheap. This wraps the fence-safe refresh so a scheduler (or an operator)
# can call it per corpus.
#
# FENCE SAFETY: extraction never runs on a live vault — we operate on a
# scratchpad COPY carrying a `.graphify-corpus` marker (same discipline as the
# harvest tools + the egress matrix). The derived graph.json + full
# GRAPH_REPORT.md land in the corpus's repo-local `graphify-out/` (the "latest
# in repo" substrate); only the curated MOC is published to the vault's
# 60-Maps/ (the tracked artifact that "moves" on update).
#
# Usage:
#   refresh-graph-map.sh --name luna --corpus-root <path> --backend deepseek \
#       --maps-dir <luna>/60-Maps --title "Graphify Luna Map" --slug graphify-luna-map \
#       [--corpus-tag luna] [--scratch <dir>] [--no-update]
#
# Exit: 0 ok; 1 usage/IO; 2 fence/graphify failure.
#
# Freshness guard: this script REBUILDS the graph. To CHECK whether an existing
# graphify-out/ is still fresh (and not orphaned from its corpus) before querying
# it, run check-graph-freshness.sh --out <graphify-out> [--max-age-days N]
# (companion script, same dir). HIMMEL-621/824/825 family.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

NAME="" CORPUS_ROOT="" BACKEND="deepseek" MAPS_DIR="" TITLE="" SLUG="" CORPUS_TAG=""
SCRATCH="" DO_UPDATE=1 CORPUS_CLASS="luna-personal"
usage() { echo "usage: refresh-graph-map.sh --name N --corpus-root P --maps-dir D --title T --slug S [--backend B] [--corpus-tag T] [--corpus-class C] [--scratch DIR] [--no-update]" >&2; exit 1; }
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="${2:-}"; shift 2 ;;
    --corpus-root) CORPUS_ROOT="${2:-}"; shift 2 ;;
    --backend) BACKEND="${2:-}"; shift 2 ;;
    --maps-dir) MAPS_DIR="${2:-}"; shift 2 ;;
    --title) TITLE="${2:-}"; shift 2 ;;
    --slug) SLUG="${2:-}"; shift 2 ;;
    --corpus-tag) CORPUS_TAG="${2:-}"; shift 2 ;;
    --corpus-class) CORPUS_CLASS="${2:-}"; shift 2 ;;
    --scratch) SCRATCH="${2:-}"; shift 2 ;;
    --no-update) DO_UPDATE=0; shift ;;
    *) echo "refresh-graph-map: unknown flag: $1" >&2; usage ;;
  esac
done
if [ -z "$NAME" ] || [ -z "$CORPUS_ROOT" ] || [ -z "$MAPS_DIR" ] || [ -z "$TITLE" ] || [ -z "$SLUG" ]; then usage; fi
[ -d "$CORPUS_ROOT" ] || { echo "refresh-graph-map: corpus root not found: $CORPUS_ROOT" >&2; exit 1; }

GRAPHIFY_MAP="${GRAPHIFY_MAP_BIN:-graphify}"   # test hook: stub graphify
# graphify is only needed for the extraction path — --no-update publishes from
# an existing report and must not require it (CR: code-reviewer).

# Off-peak advisory (DeepSeek peak-valley UTC 1-4 + 6-10 = 2x). Advisory only —
# a scheduler should aim off-peak; we never hard-refuse (an operator may run ad hoc).
if [ "$BACKEND" = "deepseek" ]; then
  H=$(date -u +%H)
  case "$H" in 01|02|03|06|07|08|09) echo "refresh-graph-map: WARN inside DeepSeek peak window (2x); off-peak resumes 10:00 UTC. Advisory." >&2 ;; esac
fi

OUT_DIR="$CORPUS_ROOT/graphify-out"
REPORT="$OUT_DIR/GRAPH_REPORT.md"

if [ "$DO_UPDATE" -eq 1 ]; then
  command -v "$GRAPHIFY_MAP" >/dev/null 2>&1 || { echo "refresh-graph-map: '$GRAPHIFY_MAP' not on PATH (needed for --update; use --no-update to publish from an existing report)" >&2; exit 2; }
  # F3 (HIMMEL-907): python3 writes the freshness manifest (see stamp step
  # below). Preflight it next to the graphify check so a python3-less box fails
  # BEFORE the scratch copy / paid extraction — never after promoting a new graph.
  command -v python3 >/dev/null 2>&1 || { echo "refresh-graph-map: python3 not found (needed to write manifest.json for freshness verification)" >&2; exit 2; }
  # Fence-safe incremental refresh on a scratchpad COPY (never the live corpus).
  # Always work inside a uniquely-named, launcher-OWNED subdir (PID-suffixed) so
  # we never rm -rf an operator-supplied --scratch that may point at an existing
  # directory holding unrelated data (codex-adv [codex-1]). --scratch names only
  # the PARENT under which the owned workdir is created.
  SCRATCH_PARENT="${SCRATCH:-${TMPDIR:-/tmp}}"
  mkdir -p "$SCRATCH_PARENT" || { echo "refresh-graph-map: cannot create scratch parent: $SCRATCH_PARENT" >&2; exit 1; }
  SCRATCH="$SCRATCH_PARENT/graphify-refresh-$NAME-$$"
  rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"
  # Clean the owned subdir on ANY exit — a graphify/cluster-only failure (exit 2)
  # otherwise leaks it (CR suggestion). Scoped to the PID-owned dir only.
  trap 'rm -rf "$SCRATCH" 2>/dev/null || true' EXIT
  # Copy only markdown (matches the extraction corpus); carry the fence marker.
  # No 2>/dev/null on find — a scan failure (permission/IO) is aborted by
  # set -euo pipefail, and find's own stderr is the ONLY diagnostic for it (CR).
  ( cd "$CORPUS_ROOT" && find . -name '*.md' -not -path './graphify-out/*' -print0 \
      | while IFS= read -r -d '' f; do mkdir -p "$SCRATCH/$(dirname "$f")"; cp "$f" "$SCRATCH/$f"; done ) \
    || { echo "refresh-graph-map: corpus scan/copy failed (see find/cp output above)" >&2; exit 1; }
  printf '%s\n' "$CORPUS_CLASS" > "$SCRATCH/.graphify-corpus"
  echo "refresh-graph-map: incremental update on scratchpad copy ($SCRATCH) backend=$BACKEND" >&2
  "$GRAPHIFY_MAP" "$SCRATCH" --update --backend "$BACKEND" --max-concurrency 6 --api-timeout 300 >&2 || { echo "refresh-graph-map: graphify --update failed" >&2; exit 2; }
  "$GRAPHIFY_MAP" cluster-only "$SCRATCH" --backend "$BACKEND" >&2 || { echo "refresh-graph-map: cluster-only failed" >&2; exit 2; }
  # HIMMEL-907: stamp freshness artifacts so the companion guard
  # check-graph-freshness.sh can VERIFY this graph (not "fresh by age" only).
  # Source-of-truth for shape is the guard's parser: manifest.json = flat
  # non-empty JSON object of corpus-relative path -> {mtime} (the parser uses
  # the KEYS to prove the corpus still exists; values are free-form, so we carry
  # the file mtime as honest provenance — stored as an INT epoch for compact,
  # human-greppable provenance — and invent nothing else); .graphify_root =
  # first non-blank line is the corpus root. graphify itself emits no manifest,
  # so we synthesize one from the same corpus predicate the extraction copy used
  # (find -name '*.md' -not -path './graphify-out/*'). A zero-md corpus stamps
  # `{}`, which the guard rejects with rc=2 — fail-loud by design, no
  # special-casing. Only written on a SUCCESSFUL refresh — this branch is reached
  # solely after graphify --update + cluster-only both succeeded; a failed run
  # exits above before reaching here, so we never stamp a failed run as fresh.
  #
  # F1: walk the SCRATCH copy (the exact corpus the graph saw), NOT the live
  # corpus — a file added/removed mid-extraction would otherwise make
  # manifest.json attest a corpus state the graph never saw. The scratch's own
  # graphify-out is pruned so GRAPH_REPORT.md doesn't leak into the keys. Keys
  # stay corpus-relative (scratch mirrors the corpus's relative md layout).
  #
  # F2: transactional promote so any interruption (disk full, kill, python3
  # gone mid-run, ...) leaves a stamp-LESS out dir the guard fails closed on —
  # never a NEW graph beside OLD stamps. Order: build the new manifest into a
  # tmp name -> invalidate the old stamps -> promote the derived graph ->
  # atomically install the new stamps (same-dir mv + marker write).
  mkdir -p "$OUT_DIR"
  CORPUS_ROOT_ABS="$(cd "$CORPUS_ROOT" && pwd)"
  OUT_DIR_ABS="$(cd "$OUT_DIR" && pwd)"
  SCRATCH_ABS="$(cd "$SCRATCH" && pwd)"
  # 1. build the new manifest from the scratch corpus into a tmp name (atomic
  #    content write is fine — it's a tmp name, not the stamp itself).
  python3 - "$SCRATCH_ABS" "$OUT_DIR_ABS" <<'PYEOF'
import json, os, sys
root, out = sys.argv[1], sys.argv[2]
scratch_out = os.path.join(root, "graphify-out")
manifest = {}
for dirpath, dirs, files in os.walk(root):
    # prune the derived out dir graphify wrote into the scratch so it doesn't
    # leak GRAPH_REPORT.md into the manifest keys.
    dirs[:] = [d for d in dirs if os.path.join(dirpath, d) != scratch_out]
    for fn in files:
        if not fn.endswith(".md"):
            continue
        full = os.path.join(dirpath, fn)
        rel = os.path.relpath(full, root).replace(os.sep, "/")
        try:
            mtime = int(os.path.getmtime(full))
        except OSError:
            mtime = 0
        manifest[rel] = {"mtime": mtime}
with open(os.path.join(out, ".manifest.tmp"), "w") as fh:
    json.dump(manifest, fh, sort_keys=True)
    fh.write("\n")
PYEOF
  # 2. INVALIDATE the old stamps so a half-promoted out dir is never mistaken
  #    for fresh (no manifest marker <-> guard fails closed).
  rm -f "$OUT_DIR/manifest.json" "$OUT_DIR/.graphify_root"
  # 3. promote the refreshed derived artifacts into the corpus's repo-local out.
  cp "$SCRATCH/graphify-out/graph.json" "$OUT_DIR/graph.json"
  cp "$SCRATCH/graphify-out/GRAPH_REPORT.md" "$REPORT"
  # 4. STAMP: same-dir rename = atomic install of the manifest, then (re)write
  #    the marker. .graphify_root stays CORPUS_ROOT_ABS — the guard joins the
  #    corpus-relative manifest keys against the LIVE corpus root.
  mv "$OUT_DIR/.manifest.tmp" "$OUT_DIR/manifest.json"
  printf '%s\n' "$CORPUS_ROOT_ABS" > "$OUT_DIR/.graphify_root"
  rm -rf "$SCRATCH"   # eager clean on success; the EXIT trap is the failure-path backstop
fi

[ -f "$REPORT" ] || { echo "refresh-graph-map: no GRAPH_REPORT.md at $REPORT (run without --no-update, or generate one first)" >&2; exit 1; }

# Publish the curated MOC into the vault's 60-Maps (the tracked artifact).
OUT_NOTE="$MAPS_DIR/$SLUG.md"
node "$REPO_ROOT/scripts/graphify/publish-graph-map.mjs" \
  --report "$REPORT" --out "$OUT_NOTE" --title "$TITLE" --slug "$SLUG" \
  ${CORPUS_TAG:+--corpus "$CORPUS_TAG"} --source-graph "graphify-out/graph.json"

echo "refresh-graph-map: published $OUT_NOTE" >&2
