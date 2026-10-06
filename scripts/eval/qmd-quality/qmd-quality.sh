#!/usr/bin/env bash
# scripts/eval/qmd-quality/qmd-quality.sh - qmd retrieval-quality eval
# (HIMMEL-4184). Runs the golden set through lex-only, vec-only, hybrid and
# hybrid+rerank and prints hit@1, hit@5 and MRR per mode and per collection.
#
# Usage:
#   qmd-quality.sh --index <index.sqlite> --out <dir> --golden <golden.jsonl>
#                  [--modes lex,vec,hybrid,hybrid-rerank]
#                  [--scope all|golden] [--candidate-limit N] [--no-snapshot]
#
# The golden set names private docs, so it is not in the repo: pass --golden
# or set QMD_QUALITY_GOLDEN. Rows are {id, query, lex?, collections, expect};
# the suite's fixtures/golden.jsonl shows the shape.
#
# Read-only on the index you name: it is first copied to <out>/index.sqlite
# with sqlite3's online backup (opened -readonly), and the eval runs on the
# copy, because the qmd SDK opens its store read-write and caches LLM calls
# into it. --no-snapshot runs on --index in place: only for an index that is
# already a scratch copy (a candidate-model build).
#
# No network: every model the chosen modes load must already sit in qmd's
# model cache ($XDG_CACHE_HOME/qmd/models, else ~/.cache/qmd/models). An
# uncached one is refused (exit 3) rather than downloaded. QMD_EMBED_MODEL /
# QMD_RERANK_MODEL select candidate models, exactly as qmd itself reads them.
#
# Embed model (HIMMEL-4439): with QMD_EMBED_MODEL unset the eval adopts the
# index's single embed model; a set model that differs from the index's (or an
# index mixing models) is refused with exit 2, naming both.
#
# Output in <out>: runs.jsonl (ranked lists + per-query ms), scores.tsv (also
# printed), latency.tsv (median and p90 ms per mode).
# QMD_EVAL_TIMEOUT_SECS bounds each mode (default 1800 s; the whole process group
# is killed, as scripts/lib/qmd-bounded.sh does for qmd itself).
# Exit: 0 scored, 2 eval failed or timed out, 3 a model is not cached, 64 usage error.
# Needs bash 3.2+, bun and sqlite3.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
INDEX=""
OUT=""
GOLDEN="${QMD_QUALITY_GOLDEN:-}"
MODES="lex,vec,hybrid,hybrid-rerank"
SCOPE="all"
CAND=40
SNAPSHOT=1

usage() {
  sed -n '5,9p' "$0" | sed 's/^# //' >&2
  exit 64
}

while [ "$#" -gt 0 ]; do
  # A value flag with nothing after it would make `shift 2` fail and loop forever.
  case "$1" in
    --index | --out | --golden | --modes | --scope | --candidate-limit)
      [ "$#" -ge 2 ] || { echo "qmd-quality: $1 needs a value" >&2; usage; } ;;
  esac
  case "$1" in
    --index) INDEX="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --golden) GOLDEN="$2"; shift 2 ;;
    --modes) MODES="$2"; shift 2 ;;
    --scope) SCOPE="$2"; shift 2 ;;
    --candidate-limit) CAND="$2"; shift 2 ;;
    --no-snapshot) SNAPSHOT=0; shift ;;
    -h | --help) usage ;;
    *) echo "qmd-quality: unknown argument '$1'" >&2; usage ;;
  esac
done

[ -n "$INDEX" ] || { echo "qmd-quality: --index <index.sqlite> is required (no default: name the index explicitly)" >&2; exit 64; }
[ -n "$OUT" ] || { echo "qmd-quality: --out <dir> is required" >&2; exit 64; }
[ -f "$INDEX" ] || { echo "qmd-quality: no index at '$INDEX'" >&2; exit 64; }
[ -n "$GOLDEN" ] || { echo "qmd-quality: name the golden set with --golden <golden.jsonl> or QMD_QUALITY_GOLDEN (it is kept outside the repo; there is no default)" >&2; exit 64; }
[ -f "$GOLDEN" ] || { echo "qmd-quality: no golden set at '$GOLDEN'" >&2; exit 64; }
[ -n "$MODES" ] || { echo "qmd-quality: --modes is empty; nothing would be evaluated" >&2; exit 64; }
case "$CAND" in
  '' | *[!0-9]* | 0*) echo "qmd-quality: --candidate-limit must be a positive integer, got '$CAND'" >&2; exit 64 ;;
esac
# The snapshot step removes <out>/index.sqlite first; it must never be the source.
if [ "$SNAPSHOT" -eq 1 ] && [ "$INDEX" -ef "$OUT/index.sqlite" ]; then
  echo "qmd-quality: --index is the snapshot target $OUT/index.sqlite; pick another --out" >&2
  exit 64
fi

# hf:<user>/<repo>/<file> is cached by qmd as hf_<user>_<file>.
model_file() {
  local uri="$1" rest user file
  rest="${uri#hf:}"
  user="${rest%%/*}"
  file="${rest##*/}"
  printf 'hf_%s_%s\n' "$user" "$file"
}

# The SDK embeds queries with QMD_EMBED_MODEL (else the gemma default), and never
# checks which model made the index's vectors (HIMMEL-4232), so a mismatch gives
# errors or garbage on every vec/hybrid query. Unset: adopt the index's own model,
# as qmd-embed-model.sh and doctor C49 judge it; set but different: refuse, naming
# both. Only modes that embed a query (anything but lex) are checked. An index
# that cannot be read here is left to the eval to report.
embed_modes="$(printf '%s\n' "$MODES" | tr ',' '\n' | grep -vx lex)"
if [ -z "$embed_modes" ]; then
  :
elif ! command -v sqlite3 >/dev/null 2>&1; then
  echo "qmd-quality: sqlite3 not on PATH; the index's embed model was NOT checked against QMD_EMBED_MODEL" >&2
else
  if idx_models="$(sqlite3 -readonly "$INDEX" "SELECT DISTINCT model FROM content_vectors ORDER BY model;" 2>/dev/null)" && [ -n "$idx_models" ]; then
    if [ -z "${QMD_EMBED_MODEL:-}" ] && [ "$(printf '%s\n' "$idx_models" | wc -l)" -eq 1 ]; then
      QMD_EMBED_MODEL="$idx_models"; export QMD_EMBED_MODEL
      echo "qmd-quality: embed model taken from the index: $QMD_EMBED_MODEL" >&2
    else
      want="${QMD_EMBED_MODEL:-hf:ggml-org/embeddinggemma-300M-GGUF/embeddinggemma-300M-Q8_0.gguf}"
      if grep -qvxF -- "$want" <<<"$idx_models"; then
        echo "qmd-quality: embed model mismatch: eval would use '$want' but the index holds vectors from: $(printf '%s' "$idx_models" | tr '\n' ' ')" >&2
        echo "qmd-quality: set QMD_EMBED_MODEL to the index's single model, or evaluate an index built with one model" >&2
        exit 2
      fi
    fi
  fi
fi

MODELS_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/qmd/models"
need="${QMD_EMBED_MODEL:-hf:ggml-org/embeddinggemma-300M-GGUF/embeddinggemma-300M-Q8_0.gguf}"
case ",$MODES," in
  *,hybrid-rerank,* | *,hybrid-hyde,* | *,auto,*)
    need="$need ${QMD_RERANK_MODEL:-hf:ggml-org/Qwen3-Reranker-0.6B-Q8_0-GGUF/qwen3-reranker-0.6b-q8_0.gguf}" ;;
esac
case ",$MODES," in
  *,auto,*) need="$need ${QMD_GENERATE_MODEL:-hf:tobil/qmd-query-expansion-1.7B-gguf/qmd-query-expansion-1.7B-q4_k_m.gguf}" ;;
esac
for uri in $need; do
  case "$uri" in
    hf:*) f="$MODELS_DIR/$(model_file "$uri")" ;;
    *) f="$uri" ;;
  esac
  if [ ! -s "$f" ]; then
    echo "qmd-quality: model not cached (refusing to download): $uri (looked for $f)" >&2
    exit 3
  fi
done

command -v bun >/dev/null 2>&1 || { echo "qmd-quality: bun not on PATH" >&2; exit 2; }
mkdir -p "$OUT" || exit 2

if [ "$SNAPSHOT" -eq 1 ]; then
  command -v sqlite3 >/dev/null 2>&1 || { echo "qmd-quality: sqlite3 not on PATH (needed for the snapshot)" >&2; exit 2; }
  rm -f "$OUT/index.sqlite"
  echo "qmd-quality: snapshotting $INDEX to $OUT/index.sqlite (read-only on the source)" >&2
  sqlite3 -readonly "$INDEX" ".backup '$OUT/index.sqlite'" || { echo "qmd-quality: snapshot failed" >&2; exit 2; }
  EVAL_INDEX="$OUT/index.sqlite"
else
  EVAL_INDEX="$INDEX"
fi

# The SDK runs llama.cpp in-process; a bun blocked in native code ignores
# SIGTERM (HIMMEL-3956), so each mode gets qmd_bounded's whole-group deadline.
# One process per mode, each under its own deadline, so a stalled mode (seen
# while a GPU clock tune was active) is named and stops the run promptly.
# shellcheck source=scripts/lib/qmd-bounded.sh
. "$HERE/../../lib/qmd-bounded.sh"
: >"$OUT/runs.jsonl"
for mode in $(printf '%s\n' "$MODES" | tr ',' ' '); do
  qmd_bounded "${QMD_EVAL_TIMEOUT_SECS:-1800}" bun "$HERE/run-eval.ts" --index "$EVAL_INDEX" --golden "$GOLDEN" --out "$OUT/runs-$mode.jsonl" \
    --modes "$mode" --scope "$SCOPE" --candidate-limit "$CAND"
  rc=$?
  [ "$rc" -eq 124 ] && { echo "qmd-quality: $mode passed its ${QMD_EVAL_TIMEOUT_SECS:-1800}s deadline (QMD_EVAL_TIMEOUT_SECS)" >&2; exit 2; }
  [ "$rc" -eq 0 ] || { echo "qmd-quality: run-eval $mode failed (rc=$rc)" >&2; exit 2; }
  cat "$OUT/runs-$mode.jsonl" >>"$OUT/runs.jsonl"
done
bun "$HERE/score.ts" --golden "$GOLDEN" --runs "$OUT/runs.jsonl" >"$OUT/scores.tsv" || exit 2
bun "$HERE/latency.ts" --runs "$OUT/runs.jsonl" >"$OUT/latency.tsv" || exit 2
cat "$OUT/scores.tsv"
echo
cat "$OUT/latency.tsv"
# HIMMEL-4647: one eval-runs ledger row per run (scripts/eval/lib/eval_runs.py);
# a ledger failure warns and never changes the eval's result.
python3 "$HERE/../lib/eval_runs.py" qmd-quality "$OUT" --golden "$GOLDEN" --modes "$MODES" --scope "$SCOPE" \
  --candidate-limit "$CAND" --embed-model "${QMD_EMBED_MODEL:-}" --rerank-model "${QMD_RERANK_MODEL:-}" --index "$INDEX" \
  || echo "qmd-quality: WARNING eval-runs row not written" >&2
