#!/usr/bin/env bash
# scripts/eval/review-panel/test-review-panel.sh - suite for the review-panel
# recall eval (HIMMEL-4649): fixture/key integrity, the seed-leak lint, the
# finding parser + matcher on canned critic outputs, the eval-runs row, and
# run.sh driven by a stub panel. No model call, no codex, no live ledger.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCORE="$HERE/score.py"
RUN="$HERE/run.sh"
FIX="$HERE/fixtures"
KEY="$HERE/key/seeds.json"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/review-panel-test.XXXXXX")" || { echo "test-review-panel: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
# Never the live ledger, whatever a case forgets to pass.
export HIMMEL_EVAL_RUNS_LEDGER="$TMP/never.jsonl"

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL $1"; }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) pass "$1";; *) fail "$1: '$3' not in '$2'";; esac; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP test-review-panel: python3 not on PATH"; exit 0; }

# metric <scores.json> <name> - one metric from score.py --json output.
metric() { python3 -c 'import json,sys; v=json.load(open(sys.argv[1]))["metrics"].get(sys.argv[2]); print("null" if v is None else (round(v,4) if isinstance(v,float) else v))' "$1" "$2"; }
jget() { python3 -c 'import json,sys
v=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("/"): v=v.get(k) if isinstance(v,dict) else None
print(json.dumps(v) if isinstance(v,(dict,list,bool)) or v is None else v)' "$1" "$2"; }
# case_of <pair> <kind> - the opaque case id the key gives that twin.
case_of() { python3 -c 'import json,sys; k=json.load(open(sys.argv[1]))["cases"]; print([c for c,v in sorted(k.items()) if v["pair"]==sys.argv[2] and v["kind"]==sys.argv[3]][0])' "$KEY" "$1" "$2"; }
seed_line() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["cases"][sys.argv[2]]["defects"][0]["line"])' "$KEY" "$1"; }
seed_file() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["cases"][sys.argv[2]]["defects"][0]["file"])' "$KEY" "$1"; }

# review <out-file> <critic> <severity:file:line:text>... - a canned merged panel block.
review() {
  local out="$1" critic="$2"; shift 2
  python3 - "$out" "$critic" "$@" <<'PY'
import sys
out, critic, items = sys.argv[1], sys.argv[2], sys.argv[3:]
secs = {"crit": [], "imp": [], "sug": []}
for n, it in enumerate(items, 1):
    sev, f, line, text = it.split(":", 3)
    secs[sev].append("- [%s-%d]: %s [%s:%s]" % (critic, n, text, f, line))
with open(out, "w") as fh:
    fh.write("# Critic Panel Review (1/1 critics responded)\n\n")
    for head, k in (("Critical Issues", "crit"), ("Important Issues", "imp"), ("Suggestions", "sug")):
        fh.write("## %s (%d found)\n" % (head, len(secs[k])))
        fh.write("".join(l + "\n" for l in secs[k]))
        fh.write("\n")
PY
}

# --- fixture + key integrity ------------------------------------------------------
eq "fixtures: 24 frozen diffs" "$(find "$FIX" -name 'case-*.patch' | wc -l | tr -d ' ')" "24"
out=$(python3 "$SCORE" lint --fixtures "$FIX" --key "$KEY" 2>&1); rc=$?
eq "lint: the shipped set is clean" "$rc" "0"
has "lint: reports seeded and clean counts" "$out" "12 seeded, 12 clean"
classes=$(python3 -c 'import json,sys; print(" ".join(sorted({d["class"] for v in json.load(open(sys.argv[1]))["cases"].values() for d in v["defects"]})))' "$KEY")
eq "key: every ticket class is seeded" "$classes" "fail-open logic quoting scope-creep test-cannot-fail toctou"

# --- the seed-leak lint refuses a fixture that names its own seed -----------------
mkdir -p "$TMP/leak/fixtures"
cp "$FIX"/case-*.patch "$TMP/leak/fixtures/"
canary=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["canary"])' "$KEY")
printf '+# %s\n' "$canary" >> "$TMP/leak/fixtures/case-01.patch"
out=$(python3 "$SCORE" lint --fixtures "$TMP/leak/fixtures" --key "$KEY" 2>&1); rc=$?
eq "lint: a fixture carrying the key canary is refused" "$rc" "1"
has "lint: names the leaking fixture" "$out" "case-01"
cp "$FIX/case-01.patch" "$TMP/leak/fixtures/case-01.patch"
printf '+# planted bug: off by one here\n' >> "$TMP/leak/fixtures/case-02.patch"
out=$(python3 "$SCORE" lint --fixtures "$TMP/leak/fixtures" --key "$KEY" 2>&1); rc=$?
eq "lint: a fixture carrying a seed hint word is refused" "$rc" "1"
cp "$FIX/case-02.patch" "$TMP/leak/fixtures/case-02.patch"
printf '+see review-panel/key/seeds.json\n' >> "$TMP/leak/fixtures/case-03.patch"
out=$(python3 "$SCORE" lint --fixtures "$TMP/leak/fixtures" --key "$KEY" 2>&1); rc=$?
eq "lint: a fixture naming the key path is refused" "$rc" "1"
cp "$FIX/case-03.patch" "$TMP/leak/fixtures/case-03.patch"
# A key line that is not an added line of its own diff is a broken key.
python3 -c 'import json,sys; k=json.load(open(sys.argv[1])); c=[c for c,v in sorted(k["cases"].items()) if v["defects"]][0]; k["cases"][c]["defects"][0]["line"]=999; json.dump(k,open(sys.argv[2],"w"))' "$KEY" "$TMP/leak/badkey.json"
out=$(python3 "$SCORE" lint --fixtures "$TMP/leak/fixtures" --key "$TMP/leak/badkey.json" 2>&1); rc=$?
eq "lint: a seed line outside its diff's added lines is refused" "$rc" "1"

# --- matcher on canned outputs --------------------------------------------------
LA=$(case_of logic-a seeded); LAc=$(case_of logic-a clean)
QA=$(case_of quoting-a seeded); QAc=$(case_of quoting-a clean)
TA=$(case_of toctou-a seeded)
la_line=$(seed_line "$LA"); la_file=$(seed_file "$LA")
qa_line=$(seed_line "$QA"); qa_file=$(seed_file "$QA")
ta_line=$(seed_line "$TA"); ta_file=$(seed_file "$TA")
O="$TMP/out1"; mkdir -p "$O"
# logic-a: hit at the exact line, Important, logic words.
review "$O/$LA.md" codex "imp:$la_file:$la_line:off-by-one: tail -n +keep keeps one fewer archive than asked"
# quoting-a: right place, wrong class (a style remark) - a location hit, not a class hit.
review "$O/$QA.md" codex "sug:$qa_file:$qa_line:prefer long option names for readability"
# toctou-a: a Suggestion 3 lines off (inside the window) plus an unrelated finding.
review "$O/$TA.md" codex "sug:$ta_file:$((ta_line + 3)):race between the existence check and the write; use mkdir for an atomic lock" "imp:$ta_file:1:shebang should be sh"
# clean twin of logic-a: one Important false positive; clean twin of quoting-a: none.
review "$O/$LAc.md" codex "imp:$la_file:3:retention default of 5 is undocumented"
review "$O/$QAc.md" codex
python3 "$SCORE" score --outputs "$O" --fixtures "$FIX" --key "$KEY" --critics codex --only "$LA,$QA,$TA,$LAc,$QAc" --no-ledger --json "$TMP/s1.json" >"$TMP/s1.txt" 2>&1; rc=$?
eq "score: exit 0" "$rc" "0"
eq "score: defects counted on the scored subset" "$(metric "$TMP/s1.json" defects)" "3"
eq "score: recall = location AND class hits" "$(metric "$TMP/s1.json" codex.recall)" "0.6667"
eq "score: recall_loc also counts a right-place wrong-class hit" "$(metric "$TMP/s1.json" codex.recall_loc)" "1.0"
eq "score: recall_gating counts only Critical/Important hits" "$(metric "$TMP/s1.json" codex.recall_gating)" "0.3333"
eq "score: precision = matching findings / all findings" "$(metric "$TMP/s1.json" codex.precision)" "0.4"
eq "score: fp_rate = clean twins with a gating finding" "$(metric "$TMP/s1.json" codex.fp_rate)" "0.5"
eq "score: per-class recall" "$(metric "$TMP/s1.json" codex.class.toctou.recall)" "1.0"
eq "score: per-class recall for a missed class" "$(metric "$TMP/s1.json" codex.class.quoting.recall)" "0.0"
eq "score: panel union equals the lone critic" "$(metric "$TMP/s1.json" panel.recall)" "0.6667"
eq "score: nothing leaked" "$(metric "$TMP/s1.json" leaked)" "0"
has "score: a Wilson interval on recall" "$(jget "$TMP/s1.json" ci/codex.recall)" '"lo"'
has "score: the table names n" "$(cat "$TMP/s1.txt")" "n="

# Window edge: 4 lines off misses, 3 lines off hits (default window 3).
O2="$TMP/out2"; mkdir -p "$O2"
review "$O2/$LA.md" codex "imp:$la_file:$((la_line + 4)):off-by-one in the retention count"
python3 "$SCORE" score --outputs "$O2" --fixtures "$FIX" --key "$KEY" --critics codex --only "$LA" --no-ledger --json "$TMP/s2.json" >/dev/null 2>&1
eq "window: 4 lines off is a miss" "$(metric "$TMP/s2.json" codex.recall_loc)" "0.0"
review "$O2/$LA.md" codex "imp:$la_file:$((la_line - 3)):off-by-one in the retention count"
python3 "$SCORE" score --outputs "$O2" --fixtures "$FIX" --key "$KEY" --critics codex --only "$LA" --no-ledger --json "$TMP/s2.json" >/dev/null 2>&1
eq "window: 3 lines off is a hit" "$(metric "$TMP/s2.json" codex.recall)" "1.0"
# A different file at the right line is a miss.
review "$O2/$LA.md" codex "imp:scripts/other.sh:$la_line:off-by-one in the retention count"
python3 "$SCORE" score --outputs "$O2" --fixtures "$FIX" --key "$KEY" --critics codex --only "$LA" --no-ledger --json "$TMP/s2.json" >/dev/null 2>&1
eq "match: the wrong file is a miss" "$(metric "$TMP/s2.json" codex.recall_loc)" "0.0"

# Two critics: per-critic attribution by the finding id's slug; the panel is their union.
O3="$TMP/out3"; mkdir -p "$O3"
cat > "$O3/$LA.md" <<EOF
# Critic Panel Review (2/2 critics responded)

## Critical Issues (1 found)
- [glm-1]: tail -n +keep deletes one archive too many (off by one) [$la_file:$la_line]

## Important Issues (0 found)

## Suggestions (1 found)
- [codex-2]: consider logging the count [$la_file:2]
EOF
cat > "$O3/$QA.md" <<EOF
# Critic Panel Review (1/2 critics responded)

## Note: 1 of 2 critics did not respond (review proceeds on the rest)

- glm: unavailable reason=timeout

## Critical Issues (1 found)
- [codex-1]: unquoted \$cache_dir is word-split; a space in the workspace path deletes the wrong tree [$qa_file:$qa_line]

## Important Issues (0 found)

## Suggestions (0 found)
EOF
python3 "$SCORE" score --outputs "$O3" --fixtures "$FIX" --key "$KEY" --critics codex,glm --only "$LA,$QA" --no-ledger --json "$TMP/s3.json" >/dev/null 2>&1
eq "multi: codex found quoting only" "$(metric "$TMP/s3.json" codex.recall)" "0.5"
eq "multi: glm's unavailable case leaves its denominator" "$(metric "$TMP/s3.json" glm.recall)" "1.0"
eq "multi: glm scored on 1 seeded case" "$(metric "$TMP/s3.json" glm.seeded_scored)" "1"
eq "multi: the panel union found both" "$(metric "$TMP/s3.json" panel.recall)" "1.0"

# Unscored fixtures: a missing output and a REVIEW NOT PERFORMED block.
O4="$TMP/out4"; mkdir -p "$O4"
printf '# Critic Panel Review (0/1 critics responded)\n\n## REVIEW NOT PERFORMED (0 of 1 critics responded)\n' > "$O4/$LA.md"
python3 "$SCORE" score --outputs "$O4" --fixtures "$FIX" --key "$KEY" --critics codex --only "$LA,$QA" --no-ledger --json "$TMP/s4.json" >/dev/null 2>&1; rc=$?
eq "unscored: exit 0 still" "$rc" "0"
eq "unscored: both counted" "$(metric "$TMP/s4.json" unscored)" "2"
eq "unscored: recall is null, not 0" "$(metric "$TMP/s4.json" codex.recall)" "null"
eq "unscored: status inconclusive" "$(jget "$TMP/s4.json" status)" "inconclusive"
# A transcript cut short (a missing severity heading) or a nonzero panel exit is
# not a zero-finding review.
O4b="$TMP/out4b"; mkdir -p "$O4b"
printf '# Critic Panel Review (1/1 critics responded)\n\n## Critical Issues (0 found)\n\n' > "$O4b/$LA.md"
review "$O4b/$QA.md" codex
echo 1 > "$O4b/$QA.rc"
python3 "$SCORE" score --outputs "$O4b" --fixtures "$FIX" --key "$KEY" --critics codex --only "$LA,$QA" --no-ledger --json "$TMP/s4b.json" >/dev/null 2>&1
eq "unscored: a truncated transcript and a nonzero rc are both unscored" "$(metric "$TMP/s4b.json" unscored)" "2"

# A transcript that touches the key is flagged and the run marked inconclusive.
O5="$TMP/out5"; mkdir -p "$O5"
review "$O5/$LA.md" codex "imp:$la_file:$la_line:off-by-one"
printf 'hermes: read /x/scripts/eval/review-panel/key/seeds.json\n' > "$O5/$LA.err"
python3 "$SCORE" score --outputs "$O5" --fixtures "$FIX" --key "$KEY" --critics codex --only "$LA" --no-ledger --json "$TMP/s5.json" >"$TMP/s5.txt" 2>&1
eq "leak: the transcript naming the key is counted" "$(metric "$TMP/s5.json" leaked)" "1"
eq "leak: the run is inconclusive" "$(jget "$TMP/s5.json" status)" "inconclusive"
has "leak: the report names the case" "$(cat "$TMP/s5.txt")" "LEAK $LA"
review "$O5/$LA.md" codex "imp:$la_file:$la_line:off-by-one $canary"
rm -f "$O5/$LA.err"
python3 "$SCORE" score --outputs "$O5" --fixtures "$FIX" --key "$KEY" --critics codex --only "$LA" --no-ledger --json "$TMP/s5.json" >/dev/null 2>&1
eq "leak: the canary in a finding is counted" "$(metric "$TMP/s5.json" leaked)" "1"

# --- the eval-runs row --------------------------------------------------------------
L="$TMP/ledger.jsonl"
python3 "$SCORE" score --outputs "$O" --fixtures "$FIX" --key "$KEY" --critics codex --only "$LA,$QA,$TA,$LAc,$QAc" --ledger "$L" --meta-json '{"codex_bank_delta_pct":3}' >/dev/null 2>&1; rc=$?
eq "ledger: exit 0" "$rc" "0"
eq "ledger: one row" "$(grep -c . "$L" 2>/dev/null)" "1"
python3 "$HERE/../lib/eval_runs.py" validate "$L" >/dev/null 2>&1; rc=$?
eq "ledger: the row is a valid eval-runs v1 row" "$rc" "0"
eq "ledger: eval id" "$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["eval"])' "$L")" "review-panel"
eq "ledger: the meta carries the bank cost" "$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["meta"]["codex_bank_delta_pct"])' "$L")" "3"
eq "ledger: per-case rows recorded" "$(python3 -c 'import json,sys; print(len(json.loads(open(sys.argv[1]).readline())["cases"]))' "$L")" "5"
eq "ledger: the config fingerprints the class patterns" "$(python3 -c 'import json,sys; print(len(json.loads(open(sys.argv[1]).readline())["config"].get("class_patterns", "")))' "$L")" "16"
eq "ledger: the live ledger was never touched" "$([ -e "$TMP/never.jsonl" ] && echo yes || echo no)" "no"

# --- run.sh with a stub panel -----------------------------------------------------
# The stub proves what the critic sees: a cwd outside any git checkout that holds
# nothing but the diff, and a stdin with no canary. It answers like a panel.
cat > "$TMP/stub-panel.sh" <<'EOF'
#!/usr/bin/env bash
diff="$(cat)"
here="$(pwd)"
if git rev-parse --show-toplevel >/dev/null 2>&1; then echo "STUB: cwd is inside a git checkout: $here" >&2; exit 9; fi
if [ "$(ls -A "$here" | tr '\n' ' ')" != "diff.patch " ]; then echo "STUB: cwd holds more than the diff: $(ls -A "$here")" >&2; exit 9; fi
case "$diff" in *rpk-canary*|*seeds.json*) echo "STUB: the canary reached stdin" >&2; exit 9 ;; esac
printf '%s\n' "$CRITIC_PANEL_TIERS" > "$STUB_LOG_DIR/tiers"
printf '%s %s\n' "${CR_TRIVIALITY_OVERRIDE:-}" "${CRITIC_KNOWN_FINDINGS:-}" > "$STUB_LOG_DIR/env"
printf '# Critic Panel Review (1/1 critics responded)\n\n## Critical Issues (0 found)\n\n## Important Issues (0 found)\n\n## Suggestions (0 found)\n'
EOF
mkdir -p "$TMP/stublog"
STUB_LOG_DIR="$TMP/stublog" REVIEW_PANEL_CMD="$TMP/stub-panel.sh" REVIEW_PANEL_SCRATCH="$TMP/scratch" \
  bash "$RUN" --out "$TMP/run1" --ledger "$TMP/run-ledger.jsonl" --critics codex --tiers paid >"$TMP/run1.txt" 2>&1; rc=$?
eq "run: exit 0 on a stub panel" "$rc" "0"
eq "run: one output per fixture" "$(find "$TMP/run1" -name 'case-*.md' | wc -l | tr -d ' ')" "24"
eq "run: no stub refusal" "$(grep -c 'STUB:' "$TMP"/run1/*.err 2>/dev/null | awk -F: '{s+=$2} END {print s+0}')" "0"
eq "run: the tier set reaches the panel" "$(cat "$TMP/stublog/tiers" 2>/dev/null)" "paid"
eq "run: triviality override on, known-findings off" "$(cat "$TMP/stublog/env" 2>/dev/null)" "full 0"
eq "run: one ledger row" "$(grep -c . "$TMP/run-ledger.jsonl" 2>/dev/null)" "1"
eq "run: an empty review scores recall 0" "$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["metrics"]["codex.recall"])' "$TMP/run-ledger.jsonl")" "0.0"
# run.sh refuses before any panel call when the lint fails.
mkdir -p "$TMP/badfix"; cp "$FIX"/case-*.patch "$TMP/badfix/"; printf '+# injected defect\n' >> "$TMP/badfix/case-05.patch"
: > "$TMP/stublog/tiers"
STUB_LOG_DIR="$TMP/stublog" REVIEW_PANEL_CMD="$TMP/stub-panel.sh" REVIEW_PANEL_SCRATCH="$TMP/scratch" \
  bash "$RUN" --out "$TMP/run2" --fixtures "$TMP/badfix" --no-ledger --critics codex >/dev/null 2>&1; rc=$?
eq "run: a failing lint refuses the sweep" "$rc" "2"
eq "run: no panel call on a refused sweep" "$(cat "$TMP/stublog/tiers")" ""
timeout 10 bash "$RUN" --out >/dev/null 2>&1; rc=$?
eq "run: an option missing its value is a usage error, not a hang" "$rc" "2"

echo
echo "test-review-panel: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
