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
  # Promote the refreshed derived artifacts into the corpus's repo-local graphify-out.
  mkdir -p "$OUT_DIR"
  cp "$SCRATCH/graphify-out/graph.json" "$OUT_DIR/graph.json"
  cp "$SCRATCH/graphify-out/GRAPH_REPORT.md" "$REPORT"
  rm -rf "$SCRATCH"   # eager clean on success; the EXIT trap is the failure-path backstop
fi

[ -f "$REPORT" ] || { echo "refresh-graph-map: no GRAPH_REPORT.md at $REPORT (run without --no-update, or generate one first)" >&2; exit 1; }

# Publish the curated MOC into the vault's 60-Maps (the tracked artifact).
OUT_NOTE="$MAPS_DIR/$SLUG.md"
node "$REPO_ROOT/scripts/graphify/publish-graph-map.mjs" \
  --report "$REPORT" --out "$OUT_NOTE" --title "$TITLE" --slug "$SLUG" \
  ${CORPUS_TAG:+--corpus "$CORPUS_TAG"} --source-graph "graphify-out/graph.json"

echo "refresh-graph-map: published $OUT_NOTE" >&2
