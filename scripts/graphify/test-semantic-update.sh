#!/usr/bin/env bash
# test-semantic-update.sh — HIMMEL-4185: hermetic tests for semantic-update.sh
# (the incremental semantic layer). Runs the script from a fake repo tree whose
# scripts/guardrails/ is the REAL fence (so the salus/DENY rows exercise the
# real egress matrix) while bank-preflight, seed-claude-config and `graphify`
# are stubs — never a real extraction, never the real bank.
# Run: bash scripts/graphify/test-semantic-update.sh
# shellcheck disable=SC2015  # A && pass || fail is the intentional test-assert idiom
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_REPO="$(cd "$HERE/../.." && pwd)"
FAILS=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS+1)); }

WS="$(mktemp -d "${TMPDIR:-/tmp}/test-semantic-update.XXXXXX")" || exit 1; trap 'rm -rf "$WS"' EXIT
REPO="$WS/repo"
mkdir -p "$REPO/scripts/graphify" "$REPO/scripts/lib" "$WS/bin" "$WS/tmp" "$WS/glm"
# Other tools share TMPDIR (handover-path.sh's arm-resume-cache.* in CI): the
# scratch checks look only for this script's own graphify-semantic-* dirs.
mkdir "$WS/tmp/arm-resume-cache.foreign"
for f in semantic-update.sh semantic-merge.py harden-graph.py harden-allowlist.json; do
  cp "$HERE/$f" "$REPO/scripts/graphify/$f" 2>/dev/null || true
done
ln -s "$REAL_REPO/scripts/guardrails" "$REPO/scripts/guardrails"
cat > "$REPO/scripts/graphify/seed-claude-config.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
# Bank stub: verdict from $WS/bank (default PROCEED); every call logged.
cat > "$REPO/scripts/lib/bank-preflight.sh" <<EOF
#!/usr/bin/env bash
echo bank >> "$WS/calls.log"
cat "$WS/bank" 2>/dev/null || echo PROCEED
EOF
# graphify stub: `extract <scratch> ...` writes one semantic concept node per
# copied .md (label = first line), plus an AST heading node, plus an edge to
# the existing AST node "code_a". GRAPHIFY_STUB_RC fails it; GRAPHIFY_STUB_LEAK
# writes the absolute scratch path into a node field other than source_file
# (source_file is written absolute on purpose; the merge must normalize it).
cat > "$WS/bin/graphify" <<EOF
#!/usr/bin/env bash
echo "graphify \$*" >> "$WS/calls.log"
echo "OLLAMA_MODEL=\${OLLAMA_MODEL:-}" >> "$WS/env.log"
echo "OLLAMA_API_KEY=\${OLLAMA_API_KEY-unset}" >> "$WS/env.log"
[ "\$1" = extract ] || exit 0
[ -z "\${GRAPHIFY_STUB_RC:-}" ] || exit "\$GRAPHIFY_STUB_RC"
python3 - "\$2" <<'PY'
import json, os, sys
root = sys.argv[1]
nodes, links = [], []
for dp, dn, fn in os.walk(root):
    if "graphify-out" in dp:
        continue
    for f in fn:
        if not f.endswith(".md"):
            continue
        full = os.path.join(dp, f)
        rel = os.path.relpath(full, root)
        if rel == os.environ.get("GRAPHIFY_STUB_SKIP"):
            continue  # the model omitted this file: no nodes for it
        src = full  # absolute, as a scratch extraction may write it: the merge normalizes it
        label = open(full).read().strip().splitlines()[0]
        nid = "sem_" + rel.replace("/", "_") + "_" + label.replace(" ", "_")
        node = {"id": nid, "label": label, "file_type": "concept", "_origin": "semantic", "source_file": src}
        if os.environ.get("GRAPHIFY_STUB_LEAK"):
            node["description"] = "see " + full
        nodes.append(node)
        nodes.append({"id": "head_" + rel, "label": "h", "file_type": "document", "_origin": "ast", "source_file": rel})
        links.append({"source": nid, "target": "code_a", "relation": "references", "_origin": "semantic", "source_file": src})
os.makedirs(os.path.join(root, "graphify-out", "cache", "semantic"), exist_ok=True)
open(os.path.join(root, "graphify-out", "cache", "semantic", "new.json"), "w").write("{}")
json.dump({"directed": False, "multigraph": False, "graph": {}, "nodes": nodes, "links": links, "hyperedges": []},
          open(os.path.join(root, "graphify-out", "graph.json"), "w"))
PY
echo "[graphify extract] tokens: 1,234 in / 56 out, est. cost (~claude-cli): \$0.0000"
EOF
chmod +x "$WS/bin/graphify"

SCRIPT="$REPO/scripts/graphify/semantic-update.sh"
export GRAPHIFY_LEDGER="$WS/ledger.jsonl" CLAUDE_GLM_CONFIG_DIR="$WS/glm" TMPDIR="$WS/tmp"
export GRAPHIFY_SEMANTIC_LOCK_WAIT=0
unset ANTHROPIC_BASE_URL GRAPHIFY_OUT OLLAMA_HOST OLLAMA_BASE_URL OLLAMA_MODEL

# new_corpus <dir>: two docs + a live graph holding an AST node per doc, the
# code node "code_a", and one stale semantic node for a.md.
new_corpus() {
  local c="$1"
  mkdir -p "$c/graphify-out/cache/semantic" "$c/sub"
  printf 'alpha\n' > "$c/a.md"; printf 'beta\n' > "$c/b.md"; printf 'gamma\n' > "$c/sub/c.md"
  cat > "$c/graphify-out/graph.json" <<'EOF'
{"directed": false, "multigraph": false, "graph": {}, "hyperedges": [],
 "nodes": [{"id": "code_a", "label": "a.sh", "file_type": "code", "_origin": "ast", "source_file": "a.sh"},
           {"id": "head_a.md", "label": "h", "file_type": "document", "_origin": "ast", "source_file": "a.md"},
           {"id": "stale_a", "label": "old", "file_type": "concept", "_origin": "semantic", "source_file": "a.md"}],
 "links": [{"source": "stale_a", "target": "code_a", "relation": "references", "_origin": "semantic", "source_file": "a.md"}]}
EOF
}
run() { PATH="$WS/bin:$PATH" bash "$SCRIPT" "$@" 2>&1; }
ids() { python3 -c 'import json,sys;print(" ".join(sorted(n["id"] for n in json.load(open(sys.argv[1]))["nodes"])))' "$1/graphify-out/graph.json"; }
scratch() { find "$WS/tmp" -maxdepth 1 -name 'graphify-semantic-*'; }
lastrun() { tail -1 "$1/graphify-out/semantic-runs.jsonl" | python3 -c "import json,sys;print(json.load(sys.stdin)['$2'])"; }

echo "T1: salus root refuses before any copy (exit 2, no scratch, no graphify, no bank)"
C1="$WS/c1"; new_corpus "$C1"; touch "$C1/.salus"; : > "$WS/calls.log"
out=$(run --name t1 --corpus-root "$C1" --corpus-class himmel-code); rc=$?
[ "$rc" -eq 2 ] && pass "T1 exit 2" || fail "T1 exit 2 (got $rc): $out"
[ -z "$(scratch)" ] && pass "T1 no scratch dir created" || fail "T1 scratch created: $(scratch)"
[ -s "$WS/calls.log" ] && fail "T1 graphify/bank invoked: $(cat "$WS/calls.log")" || pass "T1 nothing invoked"
[ -e "$C1/graphify-out/semantic-manifest.json" ] && fail "T1 manifest written" || pass "T1 no manifest"

echo "T2: an asserted salus class on a plain root also refuses (exit 2, no scratch)"
C2="$WS/c2"; new_corpus "$C2"; : > "$WS/calls.log"
out=$(run --name t2 --corpus-root "$C2" --corpus-class salus); rc=$?
[ "$rc" -eq 2 ] && [ -z "$(scratch)" ] && [ ! -s "$WS/calls.log" ] \
  && pass "T2 exit 2, nothing created or invoked" || fail "T2 (rc=$rc): $out"

echo "T3: first run, cap 2 of 3 changed -> batch 2, backlog 1, stale node replaced"
C3="$WS/c3"; new_corpus "$C3"; : > "$WS/calls.log"
out=$(run --name t3 --corpus-root "$C3" --corpus-class himmel-code --max-files 2); rc=$?
[ "$rc" -eq 0 ] && pass "T3 exit 0" || fail "T3 exit 0 (got $rc): $out"
got=$(ids "$C3")
[ "$got" = "code_a head_a.md sem_a.md_alpha sem_b.md_beta" ] && pass "T3 graph merged (AST kept, stale dropped)" \
  || fail "T3 node ids: $got"
[ "$(lastrun "$C3" backlog)" = 1 ] && [ "$(lastrun "$C3" batch)" = 2 ] && pass "T3 JSONL batch 2 backlog 1" \
  || fail "T3 JSONL: $(tail -1 "$C3/graphify-out/semantic-runs.jsonl")"
[ "$(lastrun "$C3" tokens_in)" = 1234 ] && pass "T3 tokens parsed" || fail "T3 tokens: $(tail -1 "$C3/graphify-out/semantic-runs.jsonl")"
[ -f "$C3/graphify-out/cache/semantic/new.json" ] && pass "T3 cache copied back" || fail "T3 cache not copied back"
[ -z "$(scratch)" ] && pass "T3 scratch cleaned" || fail "T3 scratch left: $(scratch)"

echo "T4: second run drains the backlog"
out=$(run --name t3 --corpus-root "$C3" --corpus-class himmel-code --max-files 2); rc=$?
case "$(ids "$C3")" in *sem_sub_c.md_gamma*) pass "T4 c.md extracted" ;; *) fail "T4 (rc=$rc): $out" ;; esac
[ "$(lastrun "$C3" backlog)" = 0 ] && pass "T4 backlog 0" || fail "T4 backlog"

echo "T5: no change -> no-op, no graphify, no bank"
: > "$WS/calls.log"
out=$(run --name t3 --corpus-root "$C3" --corpus-class himmel-code); rc=$?
[ "$rc" -eq 0 ] && [ ! -s "$WS/calls.log" ] && pass "T5 no-op invokes nothing" || fail "T5 (rc=$rc): $out / $(cat "$WS/calls.log")"

echo "T6: edit a.md -> old semantic node replaced; delete b.md -> its node removed"
printf 'alef\n' > "$C3/a.md"; rm "$C3/b.md"
out=$(run --name t3 --corpus-root "$C3" --corpus-class himmel-code); rc=$?
got=$(ids "$C3")
[ "$got" = "code_a head_a.md sem_a.md_alef sem_sub_c.md_gamma" ] && pass "T6 replace + delete" || fail "T6 (rc=$rc) ids: $got / $out"

echo "T7: deletion only -> merge without graphify"
rm "$C3/sub/c.md"; : > "$WS/calls.log"
out=$(run --name t3 --corpus-root "$C3" --corpus-class himmel-code); rc=$?
[ "$(ids "$C3")" = "code_a head_a.md sem_a.md_alef" ] && ! grep -q graphify "$WS/calls.log" \
  && pass "T7 removed without extraction" || fail "T7 (rc=$rc): $(ids "$C3") / $out"

echo "T8: bank SKIPPED-BANK -> exit 3, graph + manifest untouched"
C8="$WS/c8"; new_corpus "$C8"; echo SKIPPED-BANK > "$WS/bank"
before=$(cat "$C8/graphify-out/graph.json")
out=$(run --name t8 --corpus-root "$C8" --corpus-class himmel-code); rc=$?
rm -f "$WS/bank"
[ "$rc" -eq 3 ] && [ "$before" = "$(cat "$C8/graphify-out/graph.json")" ] && [ ! -e "$C8/graphify-out/semantic-manifest.json" ] \
  && pass "T8 skipped cleanly" || fail "T8 (rc=$rc): $out"

echo "T9: promote lock held -> exit 4, graph untouched"
mkdir "$C8/graphify-out/.promote.lock"; echo other > "$C8/graphify-out/.promote.lock/owner"
out=$(run --name t8 --corpus-root "$C8" --corpus-class himmel-code); rc=$?
[ "$rc" -eq 4 ] && [ "$before" = "$(cat "$C8/graphify-out/graph.json")" ] && [ "$(cat "$C8/graphify-out/.promote.lock/owner")" = other ] \
  && pass "T9 lock respected" || fail "T9 (rc=$rc): $out"
rm -rf "$C8/graphify-out/.promote.lock"

echo "T10: graphify fails -> exit 2, graph + manifest untouched"
out=$(GRAPHIFY_STUB_RC=7 run --name t8 --corpus-root "$C8" --corpus-class himmel-code); rc=$?
[ "$rc" -eq 2 ] && [ "$before" = "$(cat "$C8/graphify-out/graph.json")" ] && [ ! -e "$C8/graphify-out/semantic-manifest.json" ] \
  && pass "T10 failure leaves state" || fail "T10 (rc=$rc): $out"

echo "T11: scratch path leaking into the extraction -> refused, graph untouched"
out=$(GRAPHIFY_STUB_LEAK=1 run --name t8 --corpus-root "$C8" --corpus-class himmel-code); rc=$?
[ "$rc" -eq 2 ] && [ "$before" = "$(cat "$C8/graphify-out/graph.json")" ] && pass "T11 leak refused" || fail "T11 (rc=$rc): $out"

echo "T12: --seed-manifest stamps the baseline without extracting; .graphify-corpus-ignore honoured"
C12="$WS/c12"; new_corpus "$C12"; printf 'sub\n' > "$C12/.graphify-corpus-ignore"; : > "$WS/calls.log"
out=$(run --name t12 --corpus-root "$C12" --corpus-class himmel-code --seed-manifest); rc=$?
n=$(python3 -c 'import json,sys;print(" ".join(sorted(json.load(open(sys.argv[1]))["files"])))' "$C12/graphify-out/semantic-manifest.json" 2>/dev/null)
[ "$rc" -eq 0 ] && [ "$n" = "a.md b.md" ] && [ ! -s "$WS/calls.log" ] && pass "T12 seeded a.md b.md only" || fail "T12 (rc=$rc) '$n': $out"
out=$(run --name t12 --corpus-root "$C12" --corpus-class himmel-code); rc=$?
[ "$rc" -eq 0 ] && [ ! -s "$WS/calls.log" ] && pass "T12 seeded corpus is a no-op" || fail "T12 no-op (rc=$rc): $out"

echo "T13: --max-files must be a positive integer"
out=$(run --name t12 --corpus-root "$C12" --corpus-class himmel-code --max-files 0); rc=$?
[ "$rc" -eq 1 ] && pass "T13 usage error" || fail "T13 (rc=$rc): $out"

echo "T14: a file the extraction omits keeps its old semantic nodes and stays unstamped"
C14="$WS/c14"; new_corpus "$C14"
out=$(GRAPHIFY_STUB_SKIP=a.md run --name t14 --corpus-root "$C14" --corpus-class himmel-code); rc=$?
got=$(ids "$C14")
[ "$rc" -eq 0 ] && [ "$got" = "code_a head_a.md sem_b.md_beta sem_sub_c.md_gamma stale_a" ] && pass "T14 omitted file keeps stale_a" \
  || fail "T14 (rc=$rc) ids: $got :: $out"
[ "$(lastrun "$C14" failed)" = 1 ] && pass "T14 JSONL failed 1" || fail "T14 failed: $(tail -1 "$C14/graphify-out/semantic-runs.jsonl")"
python3 -c 'import json,sys;sys.exit("a.md" in json.load(open(sys.argv[1]))["files"])' "$C14/graphify-out/semantic-manifest.json" \
  && pass "T14 a.md unstamped" || fail "T14 a.md stamped"

echo "T15: a bank preflight with no verdict proceeds, but says so loudly"
C15="$WS/c15"; new_corpus "$C15"; : > "$WS/bank"
out=$(run --name t15 --corpus-root "$C15" --corpus-class himmel-code); rc=$?
rm -f "$WS/bank"
case "$out" in *UNGUARDED*) [ "$rc" -eq 0 ] && pass "T15 empty verdict warned" || fail "T15 rc=$rc: $out" ;;
  *) fail "T15 no UNGUARDED warning (rc=$rc): $out" ;; esac

echo "T16: the plan is taken under the promote lock (a change reverted while waiting is a no-op)"
C16="$WS/c16"; new_corpus "$C16"
run --name t16 --corpus-root "$C16" --corpus-class himmel-code --seed-manifest > /dev/null
printf 'alpha2\n' > "$C16/a.md"; mkdir "$C16/graphify-out/.promote.lock"; : > "$WS/calls.log"
GRAPHIFY_SEMANTIC_LOCK_WAIT=30 run --name t16 --corpus-root "$C16" --corpus-class himmel-code > "$WS/t16.out" &
bgpid=$!
sleep 2; printf 'alpha\n' > "$C16/a.md"; rmdir "$C16/graphify-out/.promote.lock"
wait "$bgpid"; rc=$?
grep -q 'no-op' "$WS/t16.out" && ! grep -q '^graphify' "$WS/calls.log" && [ "$rc" -eq 0 ] \
  && pass "T16 re-planned under the lock" || fail "T16 (rc=$rc): $(cat "$WS/t16.out") calls: $(cat "$WS/calls.log")"

echo "T17: hyperedge members removed with their nodes; a hyperedge left under 2 members is dropped"
C17="$WS/c17"; new_corpus "$C17"
python3 - "$C17/graphify-out/graph.json" <<'PY'
import json, sys
g = json.load(open(sys.argv[1]))
g["hyperedges"] = [
    {"id": "h3", "label": "keep", "nodes": ["stale_a", "code_a", "head_a.md"], "_origin": "semantic", "source_file": "x.md"},
    {"id": "h2", "label": "drop", "nodes": ["stale_a", "code_a"], "_origin": "semantic", "source_file": "x.md"}]
json.dump(g, open(sys.argv[1], "w"))
PY
run --name t17 --corpus-root "$C17" --corpus-class himmel-code --seed-manifest > /dev/null
printf 'alpha2\n' > "$C17/a.md"
out=$(run --name t17 --corpus-root "$C17" --corpus-class himmel-code); rc=$?
got=$(python3 -c 'import json,sys;g=json.load(open(sys.argv[1]));print(";".join(h["id"]+"="+",".join(h["nodes"]) for h in g["hyperedges"]))' "$C17/graphify-out/graph.json")
[ "$rc" -eq 0 ] && [ "$got" = "h3=code_a,head_a.md" ] && pass "T17 hyperedges pruned" || fail "T17 (rc=$rc) '$got': $out"

echo "T18: --seed-manifest respects the promote lock (exit 4, no manifest)"
C18="$WS/c18"; new_corpus "$C18"; mkdir "$C18/graphify-out/.promote.lock"
out=$(run --name t18 --corpus-root "$C18" --corpus-class himmel-code --seed-manifest); rc=$?
[ "$rc" -eq 4 ] && [ ! -e "$C18/graphify-out/semantic-manifest.json" ] && pass "T18 seed waits on the lock" || fail "T18 (rc=$rc): $out"
rmdir "$C18/graphify-out/.promote.lock"

echo "T19: --seed-manifest --dry-run writes nothing"
out=$(run --name t18 --corpus-root "$C18" --corpus-class himmel-code --seed-manifest --dry-run); rc=$?
[ "$rc" -eq 0 ] && [ ! -e "$C18/graphify-out/semantic-manifest.json" ] && pass "T19 dry-run seed wrote nothing" || fail "T19 (rc=$rc): $out"

echo "T20: --max-files 00 is not a positive integer"
out=$(run --name t18 --corpus-root "$C18" --corpus-class himmel-code --max-files 00); rc=$?
[ "$rc" -eq 1 ] && pass "T20 usage error" || fail "T20 (rc=$rc): $out"

echo "T21: an untouched file's edge to a node the re-extraction restores survives (HIMMEL-4211)"
C21="$WS/c21"; new_corpus "$C21"
python3 - "$C21/graphify-out/graph.json" <<'PY'
import json, sys
g = json.load(open(sys.argv[1]))
g["nodes"] += [{"id": "sem_a.md_alpha", "label": "alpha", "file_type": "concept", "_origin": "semantic", "source_file": "a.md"},
               {"id": "sem_b.md_beta", "label": "beta", "file_type": "concept", "_origin": "semantic", "source_file": "b.md"}]
g["links"].append({"source": "sem_b.md_beta", "target": "sem_a.md_alpha", "relation": "mentions", "_origin": "semantic", "source_file": "b.md"})
json.dump(g, open(sys.argv[1], "w"))
PY
run --name t21 --corpus-root "$C21" --corpus-class himmel-code --seed-manifest > /dev/null
printf 'alpha\nmore\n' > "$C21/a.md"
out=$(run --name t21 --corpus-root "$C21" --corpus-class himmel-code); rc=$?
got=$(python3 -c 'import json,sys;g=json.load(open(sys.argv[1]));print(sum(1 for e in g["links"] if e["source"]=="sem_b.md_beta" and e["target"]=="sem_a.md_alpha"))' "$C21/graphify-out/graph.json")
[ "$rc" -eq 0 ] && [ "$got" = 1 ] && pass "T21 b.md edge to restored a.md node kept" || fail "T21 (rc=$rc) edges=$got: $out"

echo "T22: manifest write fails after graph.json landed -> non-zero; the rerun converges to the clean-run graph"
mkdir -p "$WS/pyfail"
cat > "$WS/pyfail/sitecustomize.py" <<'PY'
import os
_real = os.replace
def _replace(src, dst, *a, **k):
    if str(dst).endswith("semantic-manifest.json") and os.path.exists(os.environ.get("FAIL_MANIFEST_FLAG", "/nonexistent")):
        raise OSError("simulated manifest write failure")
    return _real(src, dst, *a, **k)
os.replace = _replace
PY
C22="$WS/c22"; C22B="$WS/c22b"; new_corpus "$C22"; new_corpus "$C22B"
out=$(run --name t22b --corpus-root "$C22B" --corpus-class himmel-code); rc=$?
[ "$rc" -eq 0 ] || fail "T22 clean run (rc=$rc): $out"
: > "$WS/fail-manifest"
export PYTHONPATH="$WS/pyfail" FAIL_MANIFEST_FLAG="$WS/fail-manifest"
out=$(run --name t22 --corpus-root "$C22" --corpus-class himmel-code); rc=$?
unset PYTHONPATH FAIL_MANIFEST_FLAG
norm() { python3 -c 'import json,sys;g=json.load(open(sys.argv[1]));print(json.dumps([sorted(n["id"] for n in g["nodes"]),sorted((e["source"],e["target"]) for e in g["links"])]))' "$1/graphify-out/graph.json"; }
# graph.json must already hold the new content: the failure came AFTER the graph write.
[ "$rc" -ne 0 ] && [ ! -e "$C22/graphify-out/semantic-manifest.json" ] && [ "$(norm "$C22")" = "$(norm "$C22B")" ] \
  && pass "T22 failure is non-zero, graph.json landed, files stay unstamped" || fail "T22 (rc=$rc): $out"
rm -f "$WS/fail-manifest"
out=$(run --name t22 --corpus-root "$C22" --corpus-class himmel-code); rc=$?
m=$(python3 -c 'import json,sys;print(" ".join(sorted(json.load(open(sys.argv[1]))["files"])))' "$C22/graphify-out/semantic-manifest.json" 2>/dev/null)
[ "$rc" -eq 0 ] && [ "$(norm "$C22")" = "$(norm "$C22B")" ] && [ "$m" = "a.md b.md sub/c.md" ] \
  && pass "T22 rerun converges, manifest stamped" || fail "T22 rerun (rc=$rc) m='$m': $out"

echo "T23: --backend ollama -> qwen3.6:27b, --max-concurrency 1, no bank-preflight call"
C23="$WS/c23"; new_corpus "$C23"; : > "$WS/calls.log"; : > "$WS/env.log"
out=$(run --name t23 --corpus-root "$C23" --corpus-class himmel-code --backend ollama); rc=$?
ext=$(grep '^graphify extract' "$WS/calls.log")
[ "$rc" -eq 0 ] && pass "T23 exit 0" || fail "T23 exit 0 (got $rc): $out"
case "$ext" in *"--backend ollama"*"--max-concurrency 1"*) pass "T23 extract args" ;; *) fail "T23 extract args: $ext" ;; esac
grep -qx 'OLLAMA_MODEL=qwen3.6:27b' "$WS/env.log" && pass "T23 model qwen3.6:27b" || fail "T23 model: $(cat "$WS/env.log")"
grep -qx bank "$WS/calls.log" && fail "T23 bank-preflight called on the ollama path" || pass "T23 ollama path does not call bank-preflight"
# T23b (HIMMEL-4512 item 8): graphify warns "no OLLAMA_API_KEY set" on every local
# run; the loopback-verified path hands it the documented placeholder so the log
# stays quiet, and a caller-set key is never overwritten.
grep -qx 'OLLAMA_API_KEY=ollama' "$WS/env.log" && pass "T23b local ollama gets the placeholder OLLAMA_API_KEY" || fail "T23b placeholder key: $(cat "$WS/env.log")"
C23B="$WS/c23b"; new_corpus "$C23B"; : > "$WS/env.log"
out=$(OLLAMA_API_KEY=real-key run --name t23b --corpus-root "$C23B" --corpus-class himmel-code --backend ollama); rc=$?
grep -qx 'OLLAMA_API_KEY=real-key' "$WS/env.log" && pass "T23c a caller-set OLLAMA_API_KEY is preserved" || fail "T23c caller key: $(cat "$WS/env.log")"
# T23d: the claude-cli path never receives the placeholder.
C23D="$WS/c23d"; new_corpus "$C23D"; : > "$WS/env.log"
out=$(run --name t23d --corpus-root "$C23D" --corpus-class himmel-code --backend claude-cli); rc=$?
grep -qx 'OLLAMA_API_KEY=unset' "$WS/env.log" && pass "T23d claude-cli path gets no OLLAMA_API_KEY" || fail "T23d claude-cli key leak: $(cat "$WS/env.log")"

# ollama_refused <name> <VAR=val...>: the script's OWN endpoint/model check
# refuses before the fence, the bank, the copy and graphify.
ollama_refused() {
  local name="$1"; shift
  local c="$WS/c-$name"; new_corpus "$c"; : > "$WS/calls.log"
  out=$(env "$@" PATH="$WS/bin:$PATH" bash "$SCRIPT" --name "$name" --corpus-root "$c" --corpus-class himmel-code --backend ollama 2>&1); rc=$?
  [ "$rc" -eq 2 ] && [[ "$out" == *"semantic-update: refusing ollama"* ]] && [ ! -s "$WS/calls.log" ] && [ -z "$(scratch)" ] \
    && pass "$name refused before anything ran" || fail "$name (rc=$rc): $out / $(cat "$WS/calls.log")"
}
echo "T24-T28: ollama endpoint/model refusals (independent of the fence)"
ollama_refused T24-lan-host OLLAMA_HOST=192.0.2.5
ollama_refused T25-ollama-com OLLAMA_BASE_URL=https://ollama.com/v1
ollama_refused T26-cloud-model OLLAMA_MODEL=gpt-oss:120b-cloud
ollama_refused T26b-cloud-tag OLLAMA_MODEL=glm-4.6:cloud
ollama_refused T27-garbage "OLLAMA_BASE_URL=not a url"
ollama_refused T28-remote-base-loopback-host OLLAMA_BASE_URL=http://198.51.100.5:11434/v1 OLLAMA_HOST=127.0.0.1
ollama_refused T28b-userinfo OLLAMA_BASE_URL=http://127.0.0.1@evil.example:11434/v1

echo "T29: salus root on the ollama path -> exit 2 before any copy"
C29="$WS/c29"; new_corpus "$C29"; touch "$C29/.salus"; : > "$WS/calls.log"
out=$(HOME="$WS/home" run --name t29 --corpus-root "$C29" --corpus-class himmel-code --backend ollama); rc=$?
[ "$rc" -eq 2 ] && [ ! -s "$WS/calls.log" ] && [ -z "$(scratch)" ] && pass "T29 salus refused" || fail "T29 (rc=$rc): $out"

echo "T30: loopback OLLAMA_BASE_URL is accepted"
C30="$WS/c30"; new_corpus "$C30"
out=$(OLLAMA_BASE_URL=http://127.0.0.1:11434/v1 run --name t30 --corpus-root "$C30" --corpus-class himmel-code --backend ollama); rc=$?
[ "$rc" -eq 0 ] && pass "T30 loopback accepted" || fail "T30 (rc=$rc): $out"

echo
[ "$FAILS" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$FAILS FAILED"; exit 1; }
