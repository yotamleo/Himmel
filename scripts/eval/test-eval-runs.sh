#!/usr/bin/env bash
# scripts/eval/test-eval-runs.sh - suite for the eval-runs ledger writer
# (scripts/eval/lib/eval_runs.py) and eval-compare (HIMMEL-4647).
# Fixture ledgers only: no eval runs, no model calls, no live ledger.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/lib/eval_runs.py"
CMP="$HERE/eval-compare"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/eval-runs-test.XXXXXX")" || { echo "test-eval-runs: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
# Never the live ledger, whatever a case forgets to pass.
export HIMMEL_EVAL_RUNS_LEDGER="$TMP/never.jsonl"

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL $1"; }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) pass "$1";; *) fail "$1: '$3' not in '$2'";; esac; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP test-eval-runs: python3 not on PATH"; exit 0; }

field() { python3 -c 'import json,sys; r=[json.loads(l) for l in open(sys.argv[1]) if l.strip()][int(sys.argv[2])]
v=r
for k in sys.argv[3].split("."): v=v[k] if isinstance(v,dict) else None
print(json.dumps(v) if isinstance(v,(dict,list,bool)) or v is None else v)' "$@"; }

# --- writer: one valid row with the registry envelope -----------------------------
L="$TMP/w.jsonl"
out=$(python3 "$LIB" append --ledger "$L" --eval demo --source scripts/eval/test-eval-runs.sh \
  --config-json '{"b":2,"a":1}' --metrics-json '{"score":0.5,"gap":null}' --n 4 --model m1 --lane native \
  --ci-json '{"score":{"lo":0.4,"hi":0.6}}' --artifact /x/y 2>&1); rc=$?
eq "append: exit 0" "$rc" "0"
eq "append: one row" "$(grep -c . "$L" 2>/dev/null)" "1"
for k in v ts host source kind run_id eval gitsha confighash config model lane n metrics ci artifact status; do
  if python3 -c 'import json,sys; sys.exit(0 if sys.argv[2] in json.loads(open(sys.argv[1]).readline()) else 1)' "$L" "$k"; then pass "append: row carries $k"; else fail "append: row lacks $k"; fi
done
eq "append: kind" "$(field "$L" 0 kind)" "eval-run"
eq "append: v" "$(field "$L" 0 v)" "1"
eq "append: gitsha is this checkout's HEAD" "$(field "$L" 0 gitsha)" "$(git -C "$HERE" rev-parse HEAD)"
h1="$(field "$L" 0 confighash)"
python3 "$LIB" append --ledger "$L" --eval demo --source s --config-json '{"a":1,"b":2}' --metrics-json '{"score":0.5}' >/dev/null 2>&1
eq "append: confighash ignores key order" "$(field "$L" 1 confighash)" "$h1"
python3 "$LIB" append --ledger "$L" --eval demo --source s --config-json '{"a":1,"b":3}' --metrics-json '{"score":0.5}' >/dev/null 2>&1
if [ "$(field "$L" 2 confighash)" != "$h1" ]; then pass "append: confighash changes with config"; else fail "append: confighash did not change"; fi
out=$(python3 "$LIB" validate "$L" 2>&1); rc=$?
eq "validate: the written rows are valid" "$rc" "0"

# --- writer: refusals append nothing ------------------------------------------
L2="$TMP/bad.jsonl"
python3 "$LIB" append --ledger "$L2" --eval demo --source s --config-json '{}' --metrics-json '{"score":"high"}' >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ]; then pass "append: a non-numeric metric is refused"; else fail "append: a non-numeric metric was accepted"; fi
python3 "$LIB" append --ledger "$L2" --eval demo --source s --config-json '{}' --metrics-json '{"s":1}' --ci-json '{"s":{"lo":2,"hi":1}}' >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ]; then pass "append: an inverted CI is refused"; else fail "append: an inverted CI was accepted"; fi
python3 "$LIB" append --ledger "$L2" --eval "" --source s --config-json '{}' --metrics-json '{"s":1}' >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ]; then pass "append: an empty eval id is refused"; else fail "append: an empty eval id was accepted"; fi
if [ ! -s "$L2" ]; then pass "append: refusals wrote nothing"; else fail "append: a refused row landed"; fi
echo '{"v":1,"kind":"eval-run"}' >"$TMP/broken.jsonl"
python3 "$LIB" validate "$TMP/broken.jsonl" >/dev/null 2>&1; rc=$?
eq "validate: a row missing fields fails" "$rc" "1"

# --- writer: the env var names the default ledger -----------------------------
HIMMEL_EVAL_RUNS_LEDGER="$TMP/env.jsonl" python3 "$LIB" append --eval demo --source s --config-json '{}' --metrics-json '{"s":1}' >/dev/null 2>&1
eq "append: HIMMEL_EVAL_RUNS_LEDGER is the default path" "$(grep -c . "$TMP/env.jsonl" 2>/dev/null)" "1"

# --- eval-compare fixtures ----------------------------------------------------
# row <ledger> <eval> <run-id> <config-json> <metrics-json> [ci-json] [status]
row() { python3 "$LIB" append --ledger "$1" --eval "$2" --run-id "$3" --source s --config-json "$4" --metrics-json "$5" \
  ${6:+--ci-json "$6"} ${7:+--status "$7"} >/dev/null 2>&1 || fail "fixture row $3 not written"; }
TH="$TMP/thresholds.json"
cat >"$TH" <<'EOF'
{
  "qmd-quality": {
    "*.mrr": {"higher_is_better": true, "band": 0.05},
    "*.median_ms": {"higher_is_better": false, "band_rel": 0.5}
  },
  "civ": {"acc": {"higher_is_better": true, "band": 0.5}}
}
EOF
C='{"modes":"hybrid"}'
Q="$TMP/q.jsonl"
row "$Q" qmd-quality r1 "$C" '{"hybrid.mrr":0.80,"hybrid.median_ms":100}'
row "$Q" qmd-quality r2 "$C" '{"hybrid.mrr":0.80,"hybrid.median_ms":100}'
out=$(python3 "$CMP" qmd-quality --ledger "$Q" --thresholds "$TH" 2>&1); rc=$?
eq "compare: an unchanged run exits 0" "$rc" "0"
has "compare: names the baseline run" "$out" "r1"
has "compare: prints the metric" "$out" "hybrid.mrr"

row "$Q" qmd-quality r3 "$C" '{"hybrid.mrr":0.60,"hybrid.median_ms":100}'
out=$(python3 "$CMP" qmd-quality --ledger "$Q" --thresholds "$TH" 2>&1); rc=$?
eq "compare: a seeded MRR regression exits 1" "$rc" "1"
has "compare: the regression is named" "$out" "REGRESSION"
has "compare: the delta is printed" "$out" "-0.2"

row "$Q" qmd-quality r4 "$C" '{"hybrid.mrr":0.58,"hybrid.median_ms":100}'
out=$(python3 "$CMP" qmd-quality --ledger "$Q" --thresholds "$TH" 2>&1); rc=$?
eq "compare: a drop inside the band exits 0" "$rc" "0"

out=$(python3 "$CMP" qmd-quality --ledger "$Q" --thresholds "$TH" --baseline r1 2>&1); rc=$?
eq "compare: --baseline picks that run (0.80 to 0.58 regresses)" "$rc" "1"
out=$(python3 "$CMP" qmd-quality --ledger "$Q" --thresholds "$TH" --best-of 3 2>&1); rc=$?
eq "compare: --best-of 3 compares to the best of the last 3 (0.80)" "$rc" "1"
out=$(python3 "$CMP" qmd-quality --ledger "$Q" --thresholds "$TH" --best-of 1 2>&1); rc=$?
eq "compare: --best-of 1 is the previous run (0.60, inside the band)" "$rc" "0"
out=$(python3 "$CMP" qmd-quality --ledger "$Q" --thresholds "$TH" --baseline nope 2>&1); rc=$?
eq "compare: an unknown --baseline is exit 3" "$rc" "3"

row "$Q" qmd-quality r5 "$C" '{"hybrid.mrr":0.58,"hybrid.median_ms":200}'
out=$(python3 "$CMP" qmd-quality --ledger "$Q" --thresholds "$TH" 2>&1); rc=$?
eq "compare: a lower-is-better metric rising past its relative band exits 1" "$rc" "1"
has "compare: latency named as the regression" "$out" "hybrid.median_ms"

# Another config is not a baseline by default.
row "$Q" qmd-quality r6 '{"modes":"lex"}' '{"lex.mrr":0.1}'
out=$(python3 "$CMP" qmd-quality --ledger "$Q" --thresholds "$TH" 2>&1); rc=$?
eq "compare: no run of the same config is exit 3 (no baseline)" "$rc" "3"
has "compare: says there is no baseline" "$out" "no baseline"

# A partial run is never a baseline.
P="$TMP/p.jsonl"
row "$P" qmd-quality p1 "$C" '{"hybrid.mrr":0.99}' "" partial
row "$P" qmd-quality p2 "$C" '{"hybrid.mrr":0.70}'
out=$(python3 "$CMP" qmd-quality --ledger "$P" --thresholds "$TH" 2>&1); rc=$?
eq "compare: a partial run is skipped as a baseline" "$rc" "3"

# CI bounds beat the per-eval band.
V="$TMP/ci.jsonl"
row "$V" civ c1 '{}' '{"acc":0.80}' '{"acc":{"lo":0.75,"hi":0.85}}'
row "$V" civ c2 '{}' '{"acc":0.70}'
out=$(python3 "$CMP" civ --ledger "$V" --thresholds "$TH" 2>&1); rc=$?
eq "compare: below the baseline's CI lower bound exits 1 (band 0.5 ignored)" "$rc" "1"
row "$V" civ c3 '{}' '{"acc":0.78}'
out=$(python3 "$CMP" civ --ledger "$V" --thresholds "$TH" --baseline c1 2>&1); rc=$?
eq "compare: inside the baseline's CI exits 0" "$rc" "0"

# A metric with no direction is reported, never gated.
U="$TMP/u.jsonl"
row "$U" other u1 '{}' '{"x":1}'
row "$U" other u2 '{}' '{"x":0}'
out=$(python3 "$CMP" other --ledger "$U" --thresholds "$TH" 2>&1); rc=$?
eq "compare: an ungated metric does not fail" "$rc" "0"
has "compare: an ungated metric is marked info" "$out" "info"

out=$(python3 "$CMP" nothing-here --ledger "$U" --thresholds "$TH" 2>&1); rc=$?
eq "compare: no run of the eval at all is exit 3" "$rc" "3"
out=$(python3 "$CMP" --ledger "$U" 2>&1); rc=$?
eq "compare: no eval named is a usage error" "$rc" "2"

# The shipped thresholds table parses and names every wired eval.
for e in lane-quality qmd-quality guard-corpus scrape-bench; do
  if python3 -c 'import json,sys; sys.exit(0 if sys.argv[2] in json.load(open(sys.argv[1])) else 1)' "$HERE/eval-compare.json" "$e"; then pass "thresholds: $e has an entry"; else fail "thresholds: $e has no entry"; fi
done

# --- adapter: qmd-quality outputs to one row (also the backfill path) ---------
QO="$TMP/qo"; mkdir -p "$QO"
printf 'mode\tcollection\tn\thit@1\thit@5\tmrr\tmissing\nlex\tALL\t38\t0.711\t0.895\t0.781\t0\nlex\thimmel\t14\t0.714\t0.929\t0.810\t0\nhybrid\tALL\t38\t0.500\t0.700\t0.575\t1\n' >"$QO/scores.tsv"
printf 'mode\tn\tmedian_ms\tp90_ms\nlex\t38\t22\t160\nhybrid\t38\t7203.5\t8857\n' >"$QO/latency.tsv"
printf '{"id":"g1"}\n' >"$TMP/golden.jsonl"
QL="$TMP/qmd.jsonl"
python3 "$LIB" qmd-quality "$QO" --ledger "$QL" --golden "$TMP/golden.jsonl" --modes lex,hybrid --scope all --candidate-limit 40 >/dev/null 2>&1; rc=$?
eq "qmd adapter: exit 0" "$rc" "0"
eq "qmd adapter: lex.mrr" "$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["metrics"]["lex.mrr"])' "$QL")" "0.781"
eq "qmd adapter: hybrid.median_ms" "$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["metrics"]["hybrid.median_ms"])' "$QL")" "7203.5"
eq "qmd adapter: n is the query count" "$(field "$QL" 0 n)" "38"
eq "qmd adapter: per-collection rows are not run metrics" "$(python3 -c 'import json,sys; print(any("himmel" in k for k in json.loads(open(sys.argv[1]).readline())["metrics"]))' "$QL")" "False"
if python3 "$LIB" validate "$QL" >/dev/null 2>&1; then pass "qmd adapter: the row is valid"; else fail "qmd adapter: the row is invalid"; fi
python3 "$LIB" qmd-quality "$TMP/empty-dir" --ledger "$QL" --golden "$TMP/golden.jsonl" --modes lex >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ]; then pass "qmd adapter: a dir with no scores.tsv is refused"; else fail "qmd adapter: accepted a dir with no scores.tsv"; fi

echo "test-eval-runs: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
