#!/usr/bin/env bash
# plan-index.sh — HIMMEL-4000. Index the roadmap plan (HIMMEL-3882) into the
# `roadmap-plan` qmd collection, rebuilding only when something it depends on
# changed. Same "no change = no rebuild" idea as tick.sh's tracker= freshness.
#
#   plan-index.sh --refresh [--force] --plan-dir D [--out DIR] [--watch P]...
#   plan-index.sh --check             --plan-dir D [--out DIR] [--watch P]...
#
# --watch P (repeatable): the Jira mirror dir, a handover status file/dir, the
# fleet manifest. Their size+mtime joins the plan files' content hashes in the
# change key. --out defaults to ~/.himmel/state/roadmap-plan (outside any repo or
# vault; docs land in <out>/docs, the graphify graph.json (HIMMEL-4050) in
# <out>/graph.json, the key in <out>/.fp). The key is written ONLY
# after the rebuild (docs AND graph: a failed emit fails the refresh) and the qmd
# register+embed both succeed, so a failed run is retried next time; a missing or failing qmd exits non-zero. ROADMAP_QMD_BIN
# overrides the qmd binary (test seam).
#
# Exit: 0 ok/unchanged (--check: fresh), 1 failure or (--check) stale, 2 usage.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COLLECTION=roadmap-plan
mode="" force=0 plan="" out="${HOME:-/tmp}/.himmel/state/roadmap-plan"
watches=()
need() { [ $# -ge 2 ] || { echo "plan-index: $1 needs a value" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
    case "$1" in
        --refresh) mode=refresh ;;
        --check) mode=check ;;
        --force) force=1 ;;
        --plan-dir) need "$@"; plan="$2"; shift ;;
        --out) need "$@"; out="$2"; shift ;;
        --watch) need "$@"; watches+=(--watch "$2"); shift ;;
        *) echo "plan-index: unknown argument $1" >&2; exit 2 ;;
    esac
    shift
done
if [ -z "$mode" ] || [ ! -d "$plan" ]; then
    echo "usage: plan-index.sh --refresh|--check --plan-dir D [--out DIR] [--watch P]..." >&2
    exit 2
fi

want="$(python3 "$HERE/plan_docs.py" --plan-dir "$plan" --emit-fp ${watches[@]+"${watches[@]}"})"
have="$(cat "$out/.fp" 2>/dev/null || true)"

# fresh = the inputs match AND the generated docs and graph.json still exist (a deleted docs dir or graph with a kept key is stale)
fresh=0; [ "$want" = "$have" ] && [ -d "$out/docs" ] && [ -f "$out/graph.json" ] && fresh=1
if [ "$mode" = check ]; then
    if [ "$fresh" = 1 ]; then echo "plan-index: fresh"; exit 0; fi
    echo "plan-index: stale"; exit 1
fi

if [ "$force" = 0 ] && [ "$fresh" = 1 ]; then
    echo "plan-index: unchanged"; exit 0
fi

qmd="${ROADMAP_QMD_BIN:-qmd}"
command -v "$qmd" >/dev/null 2>&1 || { echo "plan-index: qmd not found ($qmd); not rebuilding" >&2; exit 1; }

mkdir -p "$out"
# one refresh at a time: generation, indexing and the key publish share docs.new and the qmd index
# ponytail: a kill -9 leaves .lock behind (remove it by hand), a pid-aware stale-lock takeover when it bites
mkdir "$out/.lock" 2>/dev/null || { echo "plan-index: another refresh holds $out/.lock" >&2; exit 1; }
trap 'rmdir "$out/.lock" 2>/dev/null || true' EXIT
python3 "$HERE/plan_docs.py" --plan-dir "$plan" --docs "$out/docs" --graph "$out/graph.json" ${watches[@]+"${watches[@]}"}
registered="$("$qmd" collection list 2>/dev/null | grep -F "$COLLECTION (" || true)"
if [ -z "$registered" ]; then
    "$qmd" collection add "$out/docs" --name "$COLLECTION" || { echo "plan-index: qmd collection add failed" >&2; exit 1; }
else
    # the name alone is not enough: a collection of this name over another directory would be embedded instead
    cpath="$("$qmd" collection show "$COLLECTION" 2>/dev/null | sed -n 's/^[[:space:]]*Path:[[:space:]]*//p' | head -n 1)"
    if [ "$cpath" != "$out/docs" ] && [ "$(cd "$cpath" 2>/dev/null && pwd -P)" != "$(cd "$out/docs" && pwd -P)" ]; then
        echo "plan-index: collection $COLLECTION points at ${cpath:-an unknown path}, not $out/docs" >&2; exit 1
    fi
fi
# update rescans the files (embed alone only embeds what the index already knows)
"$qmd" update || { echo "plan-index: qmd update failed" >&2; exit 1; }
"$qmd" embed -c "$COLLECTION" || { echo "plan-index: qmd embed failed" >&2; exit 1; }
printf '%s\n' "$want" > "$out/.fp"
echo "plan-index: rebuilt"
