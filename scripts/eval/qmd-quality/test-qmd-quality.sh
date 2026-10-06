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

# --- eval-runs ledger (HIMMEL-4647): a finished run appends one valid row ------
# A stub bun stands in for run-eval/score/latency, so no qmd and no model loads.
mkdir -p "$TMP/stub"
cat >"$TMP/stub/bun" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  *run-eval.ts) while [ $# -gt 0 ]; do [ "$1" = --out ] && : >"$2"; shift; done ;;
  *score.ts) printf 'mode\tcollection\tn\thit@1\thit@5\tmrr\tmissing\nlex\tALL\t3\t0.333\t0.667\t0.444\t0\n' ;;
  *latency.ts) printf 'mode\tn\tmedian_ms\tp90_ms\nlex\t3\t25\t40\n' ;;
esac
STUB
chmod +x "$TMP/stub/bun"
echo x >"$TMP/xdg/qmd/models/hf_ggml-org_embeddinggemma-300M-Q8_0.gguf"
LEDGER="$TMP/eval-runs.jsonl"
out=$(HIMMEL_EVAL_RUNS_LEDGER="$LEDGER" PATH="$TMP/stub:$PATH" XDG_CACHE_HOME="$TMP/xdg" bash "$HERE/qmd-quality.sh" \
  --golden "$FIX/golden.jsonl" --index "$TMP/idx.sqlite" --no-snapshot --modes lex --out "$TMP/l1" 2>&1); rc=$?
eq "ledger: stubbed run exits 0" "$rc" "0"
eq "ledger: one row appended" "$(wc -l <"$LEDGER" 2>/dev/null | tr -d ' ')" "1"
eq "ledger: row carries the run's metrics" \
  "$(python3 -c 'import json,sys; r=json.loads(open(sys.argv[1]).readline()); print(r["eval"], r["n"], r["metrics"]["lex.mrr"], r["metrics"]["lex.median_ms"], r["config"]["modes"])' "$LEDGER" 2>&1)" \
  "qmd-quality 3 0.444 25.0 lex"
python3 "$HERE/../lib/eval_runs.py" validate "$LEDGER" >/dev/null 2>&1; rc=$?
eq "ledger: row passes validate" "$rc" "0"

# --- HIMMEL-4650: bootstrap CIs, paired compare, config-stamped ledger row -----
# Fixture: 8 queries; run A misses all; run B hits all at rank 1; run C hits 4 of 8.
: >"$TMP/g8.jsonl"; : >"$TMP/ra.jsonl"; : >"$TMP/rb.jsonl"; : >"$TMP/rc.jsonl"
for i in 1 2 3 4 5 6 7 8; do
  printf '{"id":"q%s","query":"q","collections":["a"],"expect":["a/q%s.md"]}\n' "$i" "$i" >>"$TMP/g8.jsonl"
  printf '{"id":"q%s","mode":"hybrid","ranked":["a/zz.md"]}\n' "$i" >>"$TMP/ra.jsonl"
  printf '{"id":"q%s","mode":"hybrid","ranked":["a/q%s.md"]}\n' "$i" "$i" >>"$TMP/rb.jsonl"
  if [ "$i" -le 4 ]; then
    printf '{"id":"q%s","mode":"hybrid","ranked":["a/q%s.md"]}\n' "$i" "$i" >>"$TMP/rc.jsonl"
  else
    printf '{"id":"q%s","mode":"hybrid","ranked":["a/zz.md"]}\n' "$i" >>"$TMP/rc.jsonl"
  fi
done
cj() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))[sys.argv[2]]; print(d["lo"], d["hi"])' "$1" "$2"; }
bun "$HERE/score.ts" --golden "$TMP/g8.jsonl" --runs "$TMP/rb.jsonl" --ci-out "$TMP/ci-b.json" --cases-out "$TMP/cases-b.json" >/dev/null 2>&1; rc=$?
eq "ci: score.ts --ci-out exits 0" "$rc" "0"
eq "ci: an all-hit run has a degenerate hit1 interval [1,1]" "$(cj "$TMP/ci-b.json" hybrid.hit1)" "1 1"
bun "$HERE/score.ts" --golden "$TMP/g8.jsonl" --runs "$TMP/ra.jsonl" --ci-out "$TMP/ci-a.json" >/dev/null 2>&1
eq "ci: an all-miss run has [0,0]" "$(cj "$TMP/ci-a.json" hybrid.mrr)" "0 0"
bun "$HERE/score.ts" --golden "$TMP/g8.jsonl" --runs "$TMP/rc.jsonl" --ci-out "$TMP/ci-c1.json" >/dev/null 2>&1
bun "$HERE/score.ts" --golden "$TMP/g8.jsonl" --runs "$TMP/rc.jsonl" --ci-out "$TMP/ci-c2.json" >/dev/null 2>&1
eq "ci: the bootstrap is seeded, so two runs give the same interval" "$(cat "$TMP/ci-c1.json")" "$(cat "$TMP/ci-c2.json")"
eq "ci: 4 of 8 hits gives an interval that brackets 0.5 and has width" \
  "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["hybrid.hit1"]; print(d["lo"] < 0.5 < d["hi"] and d["hi"] - d["lo"] > 0.3)' "$TMP/ci-c1.json")" "True"
eq "ci: cases hold the per-query reciprocal rank" \
  "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["q1"]["hybrid.rr"], len(d))' "$TMP/cases-b.json")" "1 8"

out=$(bun "$HERE/compare.ts" --golden "$TMP/g8.jsonl" --a "$TMP/ra.jsonl" --b "$TMP/rb.jsonl" 2>&1); rc=$?
eq "compare: exit code" "$rc" "0"
# 8 tied diffs: tie-corrected variance 51 - 504/48 = 40.5, z = 17.5/sqrt(40.5), p = 0.0060.
has "compare: 8 up 0 down, sign p = 2 * 0.5^8, tie-corrected wilcoxon p" "$out" "$(printf 'hybrid\t8\t0.000\t1.000\t+1.000\t8\t0\t0.0078\t0.0060')"
eq "compare: every flipped query is listed" "$(printf '%s\n' "$out" | grep -c '^flip')" "8"
has "compare: a flip names the ranks" "$out" "$(printf 'flip\thybrid\tq1\trank_a=-\trank_b=1')"
out=$(bun "$HERE/compare.ts" --golden "$TMP/g8.jsonl" --a "$TMP/rb.jsonl" --b "$TMP/rb.jsonl" 2>&1)
has "compare: identical runs give p = 1 and no flips" "$out" "$(printf 'hybrid\t0\t1.000\t1.000\t+0.000\t0\t0\t1.0000\t1.0000')"
bun "$HERE/compare.ts" --golden "$TMP/g8.jsonl" --a "$TMP/ra.jsonl" >/dev/null 2>&1; rc=$?
eq "compare: a missing --b is a usage error" "$rc" "2"
printf '{"id":"q1","mode":"lex","ranked":[]}\n' >"$TMP/rlex.jsonl"
bun "$HERE/compare.ts" --golden "$TMP/g8.jsonl" --a "$TMP/ra.jsonl" --b "$TMP/rlex.jsonl" >/dev/null 2>&1; rc=$?
eq "compare: no mode in common is refused" "$rc" "2"
printf '{"id":"q1","mode":"hybrid","ranked":[],"error":"boom"}\n{"id":"q2","mode":"hybrid","ranked":[],"error":"boom"}\n' >"$TMP/rerr.jsonl"
bun "$HERE/compare.ts" --golden "$TMP/g8.jsonl" --a "$TMP/ra.jsonl" --b "$TMP/rerr.jsonl" >/dev/null 2>&1; rc=$?
eq "compare: a mode where every query errored is refused" "$rc" "2"
bun "$HERE/compare.ts" --golden "$TMP/g8.jsonl" --a "$TMP/ra.jsonl" --b "$TMP/rb.jsonl" --mode hybrid >/dev/null 2>&1; rc=$?
eq "compare: --mode compares a healthy mode" "$rc" "0"
cat "$TMP/rb.jsonl" "$TMP/rerr.jsonl" | sed 's/"mode":"hybrid","ranked":\[\],"error"/"mode":"vec","ranked":[],"error"/' >"$TMP/rmix.jsonl"
bun "$HERE/compare.ts" --golden "$TMP/g8.jsonl" --a "$TMP/ra.jsonl" --b "$TMP/rmix.jsonl" --mode hybrid >/dev/null 2>&1; rc=$?
eq "compare: an all-error mode other than --mode does not block it" "$rc" "0"

# ledger-row.py: CI, cases, and the config stamp land in the row.
mkdir -p "$TMP/lr"
printf 'mode\tcollection\tn\thit@1\thit@5\tmrr\tmissing\nhybrid-rerank\tALL\t8\t0.500\t0.500\t0.500\t0\n' >"$TMP/lr/scores.tsv"
cp "$TMP/ci-c1.json" "$TMP/lr/ci.json"
python3 - "$TMP" <<'PY'
import json, sys
t = sys.argv[1]
ci = json.load(open(t + "/ci-c1.json"))
json.dump({k.replace("hybrid.", "hybrid-rerank."): v for k, v in ci.items()}, open(t + "/lr/ci.json", "w"))
json.dump({"q1": {"hybrid-rerank.rr": 1.0}}, open(t + "/lr/cases.json", "w"))
PY
echo idx >"$TMP/lr-index.sqlite"
LL="$TMP/lr-ledger.jsonl"
python3 "$HERE/ledger-row.py" "$TMP/lr" --golden "$TMP/g8.jsonl" --modes hybrid-rerank --embed-model E1 --index "$TMP/lr-index.sqlite" --ledger "$LL" >/dev/null 2>&1; rc=$?
eq "ledger-row: exit 0" "$rc" "0"
python3 "$HERE/../lib/eval_runs.py" validate "$LL" >/dev/null 2>&1; rc=$?
eq "ledger-row: the row passes validate" "$rc" "0"
eq "ledger-row: ci, level, method and cases are filled" \
  "$(python3 -c 'import json,sys; r=json.loads(open(sys.argv[1]).readline()); print(sorted(r["ci"]), r["ci_level"], r["ci_method"], r["cases"])' "$LL")" \
  "['hybrid-rerank.hit1', 'hybrid-rerank.hit5', 'hybrid-rerank.mrr'] 0.95 bootstrap {'q1': {'hybrid-rerank.rr': 1.0}}"
eq "ledger-row: embed model, the DEFAULT rerank model and the index sha are stamped" \
  "$(python3 -c 'import json,sys,hashlib; r=json.loads(open(sys.argv[1]).readline()); print(r["config"]["embed_model"], "qwen3-reranker" in r["config"]["rerank_model"], r["meta"]["index_sha256"]==hashlib.sha256(b"idx\n").hexdigest(), r["meta"]["index_bytes"])' "$LL")" \
  "E1 True True 4"
# eval-compare gates on the CI the row now carries (a delta inside the interval is not a regression).
printf '%s\n' "$(python3 -c 'import json,sys; r=json.loads(open(sys.argv[1]).readline()); r["run_id"]="r2"; r["metrics"]["hybrid-rerank.hit1"]=0.45; print(json.dumps(r))' "$LL")" >>"$LL"
HIMMEL_EVAL_RUNS_LEDGER="$LL" python3 "$HERE/../eval-compare" qmd-quality >/dev/null 2>&1; rc=$?
eq "eval-compare: a drop inside the bootstrap CI is not a regression" "$rc" "0"

# backfill-ledger.sh: a stored out dir becomes a baseline row; stale scores are refused.
mkdir -p "$TMP/bf"
cp "$TMP/ra.jsonl" "$TMP/bf/runs.jsonl"
bun "$HERE/score.ts" --golden "$TMP/g8.jsonl" --runs "$TMP/bf/runs.jsonl" >"$TMP/bf/scores.tsv"
BL="$TMP/bf-ledger.jsonl"
bash "$HERE/backfill-ledger.sh" "$TMP/bf" --golden "$TMP/g8.jsonl" --modes hybrid --embed-model E1 --candidate-limit 25 --ledger "$BL" >/dev/null 2>&1; rc=$?
eq "backfill: a matching stored dir appends a row" "$rc" "0"
eq "backfill: the row is marked backfill and keeps --candidate-limit" \
  "$(python3 -c 'import json,sys; r=json.loads(open(sys.argv[1]).readline()); print(r["meta"]["backfill"], r["config"]["candidate_limit"])' "$BL")" "HIMMEL-4650 25"
sed -i 's/\t[0-9.]*\t0$/\t0.123\t0/' "$TMP/bf/scores.tsv"
bash "$HERE/backfill-ledger.sh" "$TMP/bf" --golden "$TMP/g8.jsonl" --modes hybrid --embed-model E1 --ledger "$TMP/bf-ledger2.jsonl" >/dev/null 2>&1; rc=$?
eq "backfill: scores.tsv that disagrees with the golden set is refused" "$rc" "2"
eq "backfill: a refused run writes no row" "$([ -s "$TMP/bf-ledger2.jsonl" ] && echo row || echo none)" "none"

echo "test-qmd-quality: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
