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

# --- latency.ts: median and p90 per mode, input order irrelevant --------------
out=$(bun "$HERE/latency.ts" --runs "$FIX/latency-runs.jsonl" 2>&1); rc=$?
eq "latency: exit code" "$rc" "0"
has "latency: lex n=4 median=30 p90=40" "$out" "$(printf 'lex\t4\t30\t40')"
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
out=$(XDG_CACHE_HOME="$TMP/xdg" bash "$HERE/qmd-quality.sh" --index "$TMP/idx.sqlite" --out "$TMP/o3" 2>&1); rc=$?
eq "wrapper: an uncached model is refused (no network)" "$rc" "3"
has "wrapper: the refusal names the missing model" "$out" "embeddinggemma-300M-Q8_0.gguf"
if [ ! -e "$TMP/o3/index.sqlite" ]; then
  pass "wrapper: nothing is snapshotted before the model check"
else
  fail "wrapper: snapshot made before refusal"
fi

echo "test-qmd-quality: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
