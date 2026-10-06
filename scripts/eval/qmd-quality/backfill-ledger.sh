#!/usr/bin/env bash
# scripts/eval/qmd-quality/backfill-ledger.sh - turn a stored qmd-quality --out
# dir into an eval-runs baseline row (HIMMEL-4650). Pure over files: no qmd, no
# model, no bank. Writes ci.json and cases.json into the dir from its runs.jsonl,
# then appends one row, marked meta.backfill, via ledger-row.py.
#
#   backfill-ledger.sh <out-dir> --golden G --modes M --embed-model E
#                      [--rerank-model R] [--index I] [--scope S] [--ledger PATH]
#
# <out-dir> needs runs.jsonl, scores.tsv and (optional) latency.tsv. The row
# goes to $HIMMEL_EVAL_RUNS_LEDGER, else ~/.himmel/eval-runs.jsonl, unless
# --ledger names another file: point it at a scratch file to rehearse.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
[ "$#" -ge 1 ] || { echo "usage: backfill-ledger.sh <out-dir> --golden G --modes M --embed-model E [...]" >&2; exit 64; }
DIR="$1"; shift
GOLDEN=""
PASS_THROUGH=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --golden) [ "$#" -ge 2 ] || exit 64; GOLDEN="$2"; PASS_THROUGH+=("$1" "$2"); shift 2 ;;
    --modes | --embed-model | --rerank-model | --index | --scope | --candidate-limit | --ledger) [ "$#" -ge 2 ] || exit 64; PASS_THROUGH+=("$1" "$2"); shift 2 ;;
    *) echo "backfill-ledger: unknown argument '$1'" >&2; exit 64 ;;
  esac
done
[ -d "$DIR" ] || { echo "backfill-ledger: no out dir '$DIR'" >&2; exit 64; }
[ -f "$GOLDEN" ] || { echo "backfill-ledger: --golden <golden.jsonl> is required" >&2; exit 64; }
{ [ -f "$DIR/runs.jsonl" ] && [ -f "$DIR/scores.tsv" ]; } || { echo "backfill-ledger: $DIR needs runs.jsonl and scores.tsv" >&2; exit 64; }
FRESH="$(mktemp)" || exit 2
trap 'rm -f "$FRESH"' EXIT
bun "$HERE/score.ts" --golden "$GOLDEN" --runs "$DIR/runs.jsonl" --ci-out "$DIR/ci.json" --cases-out "$DIR/cases.json" >"$FRESH" || exit 2
# The row's metrics come from scores.tsv and its CIs from the rescore: they must describe the same data.
cmp -s "$FRESH" "$DIR/scores.tsv" || { echo "backfill-ledger: $DIR/scores.tsv does not match runs.jsonl scored against $GOLDEN; refusing a row of mixed data" >&2; exit 2; }
META="$(python3 -c 'import json,sys; print(json.dumps({"backfill": "HIMMEL-4650", "stored_out": sys.argv[1]}))' "$DIR")" || exit 2
python3 "$HERE/ledger-row.py" "$DIR" --meta-json "$META" "${PASS_THROUGH[@]}"
