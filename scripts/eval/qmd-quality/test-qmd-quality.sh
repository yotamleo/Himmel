#!/usr/bin/env bash
# scripts/eval/qmd-quality/test-qmd-quality.sh - suite for the qmd retrieval
# quality eval (HIMMEL-4184). Scoring runs on a synthetic fixture (no qmd, no
# models); the wrapper cases check its refusals, which fire before qmd loads.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
FIX="$HERE/fixtures"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/qmd-quality-test.XXXXXX")" || { echo "test-qmd-quality: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL $1"; }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) pass "$1";; *) fail "$1: '$3' not in '$2'";; esac; }

if ! command -v bun >/dev/null 2>&1; then
  echo "SKIP test-qmd-quality: bun not on PATH"
  exit 0
fi

# --- score.ts: hit@1, hit@5, MRR per mode and collection ----------------------
out=$(bun "$HERE/score.ts" --golden "$FIX/golden.jsonl" --runs "$FIX/runs.jsonl" 2>&1); rc=$?
eq "score: exit code" "$rc" "0"
row() { printf '%s\n' "$out" | awk -F'\t' -v m="$1" -v c="$2" '$1==m && $2==c {print $3" "$4" "$5" "$6" "$7}'; }
# columns: n hit@1 hit@5 mrr missing
eq "lex ALL"  "$(row lex ALL)" "3 0.333 0.667 0.444 0"
eq "lex a"    "$(row lex a)"   "2 0.500 1.000 0.667 0"
eq "lex b"    "$(row lex b)"   "1 0.000 0.000 0.000 0"
# rank 6 is past hit@5 but still counts for MRR; paths compare case-blind.
eq "vec ALL"  "$(row vec ALL)" "3 0.333 0.667 0.556 0"
# a golden query with no run row for a mode is a miss, and is counted.
eq "hybrid ALL (missing row)" "$(row hybrid ALL)" "3 0.667 0.667 0.667 1"
has "score: header row" "$out" "mode	collection	n	hit@1	hit@5	mrr	missing"

# --- score.ts: bad input is refused, not scored as zero -----------------------
printf '{"id":"g1","query":"q","collections":["a"],"expect":[]}\n' >"$TMP/empty-expect.jsonl"
bun "$HERE/score.ts" --golden "$TMP/empty-expect.jsonl" --runs "$FIX/runs.jsonl" >/dev/null 2>&1; rc=$?
eq "score: a golden row with no expect doc is refused" "$rc" "2"
cat "$FIX/golden.jsonl" "$FIX/golden.jsonl" >"$TMP/dup.jsonl"
bun "$HERE/score.ts" --golden "$TMP/dup.jsonl" --runs "$FIX/runs.jsonl" >/dev/null 2>&1; rc=$?
eq "score: a duplicate golden id is refused" "$rc" "2"
# A mode whose every query errored is a broken run, not a quality of zero.
{ cat "$FIX/runs.jsonl"
  printf '{"id":"g%s","mode":"auto","ranked":[],"ms":1,"error":"model load failed"}\n' 1 2 3; } >"$TMP/all-err.jsonl"
out=$(bun "$HERE/score.ts" --golden "$FIX/golden.jsonl" --runs "$TMP/all-err.jsonl" 2>&1); rc=$?
eq "score: a mode where every query errored is refused" "$rc" "2"
has "score: the refusal names the mode" "$out" "auto"
# Empty inputs measure nothing; a header-only report must not read as success.
: >"$TMP/empty.jsonl"
bun "$HERE/score.ts" --golden "$FIX/golden.jsonl" --runs "$TMP/empty.jsonl" >/dev/null 2>&1; rc=$?
eq "score: an empty runs file is refused" "$rc" "2"
bun "$HERE/score.ts" --golden "$TMP/empty.jsonl" --runs "$FIX/runs.jsonl" >/dev/null 2>&1; rc=$?
eq "score: an empty golden set is refused" "$rc" "2"

# --- latency.ts: median and p90 per mode, input order irrelevant --------------
out=$(bun "$HERE/latency.ts" --runs "$FIX/latency-runs.jsonl" 2>&1); rc=$?
eq "latency: exit code" "$rc" "0"
has "latency: lex n=4 median=25 (mean of the middle two) p90=40" "$out" "$(printf 'lex\t4\t25\t40')"
has "latency: vec single row" "$out" "$(printf 'vec\t1\t5\t5')"
bun "$HERE/latency.ts" >/dev/null 2>&1; rc=$?
eq "latency: missing --runs is a usage error" "$rc" "2"

# --- qmd-quality.sh: refusals before any qmd/model load -----------------------
out=$(bash "$HERE/qmd-quality.sh" --out "$TMP/o1" 2>&1); rc=$?
eq "wrapper: no --index is a usage error" "$rc" "64"
has "wrapper: no --index names the flag" "$out" "--index"
out=$(bash "$HERE/qmd-quality.sh" --index "$TMP/nope.sqlite" --out "$TMP/o2" 2>&1); rc=$?
eq "wrapper: a missing index is refused" "$rc" "64"
: >"$TMP/idx.sqlite"
mkdir -p "$TMP/xdg/qmd/models"
out=$(XDG_CACHE_HOME="$TMP/xdg" bash "$HERE/qmd-quality.sh" --golden "$FIX/golden.jsonl" --index "$TMP/idx.sqlite" --out "$TMP/o3" 2>&1); rc=$?
eq "wrapper: an uncached model is refused (no network)" "$rc" "3"
has "wrapper: the refusal names the missing model" "$out" "embeddinggemma-300M-Q8_0.gguf"
if [ ! -e "$TMP/o3/index.sqlite" ]; then
  pass "wrapper: nothing is snapshotted before the model check"
else
  fail "wrapper: snapshot made before refusal"
fi
mkdir -p "$TMP/o4"
echo keep >"$TMP/o4/index.sqlite"
out=$(XDG_CACHE_HOME="$TMP/xdg" bash "$HERE/qmd-quality.sh" --golden "$FIX/golden.jsonl" --index "$TMP/o4/index.sqlite" --out "$TMP/o4" 2>&1); rc=$?
eq "wrapper: --index equal to the snapshot target is refused" "$rc" "64"
eq "wrapper: the source index survives that refusal" "$(cat "$TMP/o4/index.sqlite" 2>/dev/null)" "keep"
# shellcheck source=../../lib/timeout-bin.sh
. "$HERE/../../lib/timeout-bin.sh" 2>/dev/null
if [ -n "$_TIMEOUT_BIN" ]; then
  out=$("$_TIMEOUT_BIN" 10 bash "$HERE/qmd-quality.sh" --out "$TMP/o5" --index 2>&1); rc=$?
  eq "wrapper: a value flag with no value is a usage error, not a hang" "$rc" "64"
else
  echo "SKIP wrapper: valueless flag (no timeout binary to bound the row)"
fi
out=$(XDG_CACHE_HOME="$TMP/xdg" bash "$HERE/qmd-quality.sh" --golden "$FIX/golden.jsonl" --index "$TMP/idx.sqlite" --out "$TMP/o6" --modes "" 2>&1); rc=$?
eq "wrapper: an empty --modes is a usage error" "$rc" "64"
for bad in 0 -5 abc; do
  out=$(XDG_CACHE_HOME="$TMP/xdg" bash "$HERE/qmd-quality.sh" --golden "$FIX/golden.jsonl" --index "$TMP/idx.sqlite" --out "$TMP/o7" --candidate-limit "$bad" 2>&1); rc=$?
  eq "wrapper: --candidate-limit $bad is a usage error" "$rc" "64"
done
# The real golden set lives outside the repo, so there is no default path.
out=$(env -u QMD_QUALITY_GOLDEN XDG_CACHE_HOME="$TMP/xdg" bash "$HERE/qmd-quality.sh" --index "$TMP/idx.sqlite" --out "$TMP/o8" 2>&1); rc=$?
eq "wrapper: no golden set named is a usage error" "$rc" "64"
has "wrapper: the refusal names --golden" "$out" "--golden"
has "wrapper: the refusal names QMD_QUALITY_GOLDEN" "$out" "QMD_QUALITY_GOLDEN"
out=$(QMD_QUALITY_GOLDEN="$FIX/golden.jsonl" XDG_CACHE_HOME="$TMP/xdg" bash "$HERE/qmd-quality.sh" --index "$TMP/idx.sqlite" --out "$TMP/o9" 2>&1); rc=$?
eq "wrapper: QMD_QUALITY_GOLDEN names the golden set (reaches the model check)" "$rc" "3"

# --- HIMMEL-4439: the eval uses the index's embed model, or names the mismatch -
QWEN='hf:Qwen/Qwen3-Embedding-0.6B-GGUF/Qwen3-Embedding-0.6B-Q8_0.gguf'
GEMMA='hf:ggml-org/embeddinggemma-300M-GGUF/embeddinggemma-300M-Q8_0.gguf'
if command -v sqlite3 >/dev/null 2>&1; then
  sqlite3 "$TMP/qwen.sqlite" "CREATE TABLE content_vectors(hash TEXT, seq INT, pos INT, model TEXT); INSERT INTO content_vectors VALUES('h',0,0,'$QWEN');"
  echo x >"$TMP/xdg/qmd/models/hf_ggml-org_embeddinggemma-300M-Q8_0.gguf"
  # Explicit model that differs from the index: refused up front, both models named.
  out=$(QMD_EMBED_MODEL="$GEMMA" XDG_CACHE_HOME="$TMP/xdg" bash "$HERE/qmd-quality.sh" --golden "$FIX/golden.jsonl" --index "$TMP/qwen.sqlite" --modes vec --out "$TMP/m1" 2>&1); rc=$?
  eq "model: QMD_EMBED_MODEL differing from the index is refused" "$rc" "2"
  has "model: the refusal names the index's model" "$out" "Qwen3-Embedding-0.6B"
  has "model: the refusal names the configured model" "$out" "embeddinggemma-300M"
  # Unset: the index's model is used (not the gemma default), so it is Qwen that must be cached.
  out=$(env -u QMD_EMBED_MODEL XDG_CACHE_HOME="$TMP/xdg" bash "$HERE/qmd-quality.sh" --golden "$FIX/golden.jsonl" --index "$TMP/qwen.sqlite" --modes vec --out "$TMP/m2" 2>&1); rc=$?
  eq "model: unset QMD_EMBED_MODEL adopts the index's model (uncached = exit 3)" "$rc" "3"
  has "model: the missing model named is the index's" "$out" "Qwen3-Embedding-0.6B-Q8_0.gguf"
  # An index mixing two models cannot be evaluated by one model.
  sqlite3 "$TMP/qwen.sqlite" "INSERT INTO content_vectors VALUES('h2',0,0,'$GEMMA');"
  out=$(env -u QMD_EMBED_MODEL XDG_CACHE_HOME="$TMP/xdg" bash "$HERE/qmd-quality.sh" --golden "$FIX/golden.jsonl" --index "$TMP/qwen.sqlite" --modes vec --out "$TMP/m3" 2>&1); rc=$?
  eq "model: a mixed-model index is refused" "$rc" "2"
else
  echo "SKIP model: sqlite3 not on PATH"
fi

echo "test-qmd-quality: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
