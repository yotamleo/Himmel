#!/usr/bin/env bash
# test-plan-graph.sh — HIMMEL-4050. Hermetic tests for the graph.json that
# plan-index.sh --refresh emits next to the qmd docs: schema + the four typed
# edges (pure python, always run), a graphify explain/query fixture (SKIPs when the
# graphify binary is absent), the egress hook allowing the no-backend run, a failed
# emit failing the whole refresh before the fingerprint moves, and the source plan
# dir / any graphify-out left untouched. Fixture plan dir + stub qmd + temp out dir;
# graphify is only ever pointed at the temp graph by absolute --graph, from a temp cwd.
#
# PLATFORM GUARD: no .ps1 twin, by design — operator-side roadmap tooling (Linux);
# this suite needs bash + python3.
# shellcheck disable=SC2015  # `[ cond ] && pass || fail`: pass() cannot fail
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/plan-index.sh"
HOOK="$HERE/../hooks/block-graphify-egress.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/plan-graph-test.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
fails=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
contains() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3')" ;; esac; }

command -v python3 >/dev/null 2>&1 || { printf 'skip - python3 not available\n'; exit 0; }

plan="$W/plan"; out="$W/out"
mkdir -p "$plan/stage1" "$plan/stage3"
printf 'key\ttheme\tepic\tgoals\timpact\timpact_evidence\talignment\tdeps\tdup_of\tclose_flag\tclose_evidence\tnotes\nHIMMEL-111\tKnowledge substrate\tHIMMEL-100\tG7;G3\t2\te\t0.5\t\t\tnone\t\tn\nHIMMEL-222\tGuard safety\tPROPOSED-EPIC:Guard safety\tG1\t2\te\t0.5\t\t\tnone\t\tn\n' > "$plan/stage1/C01.tsv"
printf 'key\tuser_impact\tissue_plain\nHIMMEL-111\tinternal\tA plain sentence.\nHIMMEL-222\tinternal\tGuards plain text.\n' > "$plan/stage1/C01.explain.tsv"
printf 'key\troi\tconfidence\teffort_mid\trank\tversion\tcommit\tslice_effort\tlayer\treason\nHIMMEL-111\t1\t1\t1\t1\tv1.0.1\tcommitted\t\tbugs\twhy-one\nHIMMEL-222\t1\t1\t1\t2\tv1.0.2\tcommitted\t\tfeatures\twhy-two\n' > "$plan/stage3/placement.tsv"
plan_sum() { (cd "$plan" && find . -type f | sort | xargs sha256sum | sha256sum); }

cat > "$W/qmd" <<'STUB'
#!/usr/bin/env bash
reg="$QMD_CALLS.registered"
case "$1 ${2:-}" in
    "collection list") [ -f "$reg" ] && echo "roadmap-plan (3 files)"; exit 0 ;;
    "collection add") printf '%s\n' "$3" > "$reg"; exit 0 ;;
    "collection show") [ -f "$reg" ] && echo "Path: $(cat "$reg")"; exit 0 ;;
esac
exit 0
STUB
chmod +x "$W/qmd"
export QMD_CALLS="$W/qmd-calls"
run() { ROADMAP_QMD_BIN="$W/qmd" bash "$SUT" "$@" --plan-dir "$plan" --out "$out"; }

before="$(plan_sum)"
r="$(run --refresh 2>&1)"; rc=$?
[ "$rc" = 0 ] && pass "refresh rc=0" || fail "refresh rc=$rc: $r"
g="$out/graph.json"
[ -f "$g" ] && pass "graph.json written beside the docs" || fail "no $g"

# schema + the four typed edges, pure python
py="$(python3 - "$g" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
ids = {n["id"]: n for n in d["nodes"]}
ok = d.get("directed") is True and all("label" in n and "file_type" in n for n in d["nodes"])
print("schema", ok)
edges = {(l["source"], l["target"], l["relation"]) for l in d["links"]}
want = [
    ("ticket:HIMMEL-111", "version:v1.0.1", "inversion"),
    ("ticket:HIMMEL-111", "theme:Knowledge substrate", "intheme"),
    ("ticket:HIMMEL-111", "epic:HIMMEL-100", "inepic"),
    ("ticket:HIMMEL-111", "goal:G7", "servesgoal"),
    ("ticket:HIMMEL-111", "goal:G3", "servesgoal"),
    ("ticket:HIMMEL-222", "version:v1.0.2", "inversion"),
]
for e in want:
    print("edge", e in edges, "|".join(e))
print("dangling", all(s in ids and t in ids for s, t, _ in edges))
print("count", len(d["links"]) == 9)
print("conf", all(l.get("confidence") == "EXTRACTED" for l in d["links"]))
PY
)"
contains "schema: directed node_link, labelled nodes" "$py" "schema True"
[ "$(printf '%s\n' "$py" | grep -c '^edge True')" = 6 ] && pass "all six expected edges present" || fail "edges missing: $py"
contains "no dangling edge endpoints" "$py" "dangling True"
contains "edge count is exactly the plan's rows" "$py" "count True"
contains "edges are EXTRACTED (no LLM)" "$py" "conf True"

# same inputs => byte-identical graph (deterministic)
cp "$g" "$W/g1"; run --refresh --force >/dev/null 2>&1
cmp -s "$W/g1" "$g" && pass "deterministic: forced rebuild is byte-identical" || fail "graph differs between rebuilds"

# graphify reads it: query + explain over a scratch copy, absolute --graph, tmp cwd, never `path`
if command -v graphify >/dev/null 2>&1; then
    mkdir -p "$W/scratch/gout" "$W/cwd"; cp "$g" "$W/scratch/gout/graph.json"
    e="$(cd "$W/cwd" && graphify explain "HIMMEL-111" --graph "$W/scratch/gout/graph.json" 2>&1)"
    contains "graphify explain: version neighbour" "$e" "v1.0.1"
    contains "graphify explain: theme neighbour" "$e" "Knowledge substrate"
    contains "graphify explain: epic neighbour" "$e" "HIMMEL-100"
    contains "graphify explain: goal neighbour" "$e" "G7"
    q="$(cd "$W/cwd" && graphify query "HIMMEL-111" --graph "$W/scratch/gout/graph.json" 2>&1)"
    contains "graphify query: intheme edge" "$q" "intheme"
    contains "graphify query: servesgoal edge" "$q" "servesgoal"
    # the egress hook: the plan is handover-state derived, so the staged copy declares that
    # corpus (.graphify-corpus). The fence denies a query with no backend on a non-himmel
    # corpus (graphify auto-detects cloud keys; it cannot see which), and allows the same
    # run once it names the local backend. Fence ledger + luna root are test-local.
    printf 'handover-state\n' > "$W/scratch/.graphify-corpus"; mkdir -p "$W/luna"
    hook() {
        python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1],"cwd":sys.argv[2]}}))' "$1" "$W/cwd" \
            | GRAPHIFY_LEDGER="$W/ledger.jsonl" LUNA_VAULT_PATH="$W/luna" bash "$HOOK" 2>&1
    }
    hmsg="$(hook "graphify query HIMMEL-111 --graph $W/scratch/gout/graph.json")"; hrc=$?
    [ "$hrc" != 0 ] && pass "block-graphify-egress denies the bare no-backend query on a staged copy" || fail "bare no-backend query allowed"
    hmsg="$(hook "graphify query HIMMEL-111 --graph $W/scratch/gout/graph.json --backend ollama")"; hrc=$?
    [ "$hrc" = 0 ] && pass "block-graphify-egress allows the local-backend scratch run" || fail "egress hook rc=$hrc: $hmsg"
    [ -s "$W/ledger.jsonl" ] && pass "staged-copy run is ledgered (test-local ledger)" || fail "no ledger line"
    [ ! -e "$W/cwd/graphify-out" ] && pass "no graphify-out created in the run cwd" || fail "graphify-out created in cwd"
else
    printf 'skip - graphify binary not available (graphify query/explain + egress-hook cases)\n'
fi

[ "$before" = "$(plan_sum)" ] && pass "source plan dir untouched" || fail "plan dir changed"
[ "$(find "$plan" -type f | wc -l)" = 3 ] && pass "no file added to the plan dir" || fail "plan dir gained files"
[ -z "$(find "$plan" "$out" -name graphify-out)" ] && pass "no graphify-out under plan or out" || fail "graphify-out appeared"

# a failed graph emit fails the whole refresh and the fingerprint does not move
cp "$out/.fp" "$W/fp.keep"; rm -f "$g"; mkdir "$g"; echo x > "$g/blocker"
echo bump >> "$plan/stage3/meta.json"
r="$(run --refresh 2>&1)"; rc=$?
[ "$rc" != 0 ] && pass "graph emit failure: refresh non-zero" || fail "emit failure rc=0"
[ "$(cat "$out/.fp")" = "$(cat "$W/fp.keep")" ] && pass "graph emit failure: fingerprint not advanced" || fail "fingerprint advanced on emit failure"
rm -rf "$g"
r="$(run --refresh 2>&1)"; contains "failed emit retried next time" "$r" "rebuilt"
[ -f "$g" ] && pass "graph restored after retry" || fail "graph not restored"

# a missing graph.json with a kept key is stale
rm -f "$g"
r="$(run --check 2>&1)"; rc=$?
[ "$rc" != 0 ] && pass "missing graph.json: --check stale" || fail "--check fresh with graph deleted"

if [ "$fails" = 0 ]; then echo "all passed"; exit 0; fi
echo "$fails failed"; exit 1
