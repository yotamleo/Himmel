#!/usr/bin/env bash
# test-repo-map.sh — repo-map.py ranks files by PageRank over cross-file graph
# edges, names each file's most-referenced symbols, and never exceeds the
# token cap. A small inline graph stands in for graphify-out/graph.json.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/repo-map.py"
FAILS=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS+1)); }

T="$(mktemp -d "${TMPDIR:-/tmp}/repo-map-test.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT
G="$T/graph.json"
# hub.sh is called from three other files; leaf.sh from one; archive/ is
# excluded by default; edges inside one file add no rank; a file's own node
# (label hub.sh) is not repeated as a symbol.
cat > "$G" <<'JSON'
{"directed": false, "built_at_commit": "abc1234def", "nodes": [
 {"id": "hub_main", "label": "hub_main()", "source_file": "scripts/hub.sh"},
 {"id": "hub_aux", "label": "hub_aux()", "source_file": "scripts/hub.sh"},
 {"id": "hub_file", "label": "hub.sh", "source_file": "scripts/hub.sh"},
 {"id": "c_file", "label": "c.md", "source_file": "docs/c.md"},
 {"id": "a", "label": "a()", "source_file": "scripts/a.sh"},
 {"id": "b", "label": "b()", "source_file": "scripts/b.sh"},
 {"id": "c", "label": "c()", "source_file": "docs/c.md"},
 {"id": "leaf", "label": "leaf\u001b[31m()", "source_file": "scripts/leaf.sh"},
 {"id": "old", "label": "old()", "source_file": "archive/windows/old.ps1"},
 {"id": "nofile", "label": "concept"}
], "links": [
 {"source": "a", "target": "hub_main", "relation": "calls"},
 {"source": "b", "target": "hub_main", "relation": "calls"},
 {"source": "c", "target": "hub_main", "relation": "references"},
 {"source": "c", "target": "hub_aux", "relation": "references"},
 {"source": "hub_main", "target": "hub_aux", "relation": "calls"},
 {"source": "a", "target": "leaf", "relation": "calls"},
 {"source": "c", "target": "c_file", "relation": "contains"},
 {"source": "b", "target": "hub_file", "relation": "references"},
 {"source": "old", "target": "a", "relation": "calls"},
 {"source": "old", "target": "a", "relation": "calls"},
 {"source": "old", "target": "a", "relation": "calls"},
 {"source": "nofile", "target": "b", "relation": "calls"}
]}
JSON

# T1: the most-referenced file ranks first, with its top symbol named first.
out="$(python3 -I "$SCRIPT" --graph "$G" --max-tokens 2000 --order rank)"; rc=$?
first="$(printf '%s\n' "$out" | grep -v '^#' | head -1)"
if [ "$rc" = 0 ] && [ "$first" = "scripts/hub.sh: hub_main(), hub_aux()" ]; then
  pass "T1 hub.sh ranks first and names its most-referenced symbol first"
else fail "T1 rc=$rc first='$first' out=$out"; fi

# T2: the header names the graph commit and the cap.
if grep -q '^# Repo map .*abc1234' <<<"$out" && grep -q '2000' <<<"$out"; then pass "T2 header names commit and cap"
else fail "T2 out=$out"; fi

# T3: archive/ is excluded by default; a path-less node is ignored.
if ! grep -q 'archive/' <<<"$out" && ! grep -q 'concept' <<<"$out"; then pass "T3 archive/ and path-less nodes excluded"
else fail "T3 out=$out"; fi

# T4: the token cap (chars/4) is never exceeded; a tiny cap keeps only the top file.
out="$(python3 -I "$SCRIPT" --graph "$G" --max-tokens 35)"
chars="$(printf '%s\n' "$out" | wc -c)"
if [ "$chars" -le 140 ] && grep -q 'scripts/hub.sh' <<<"$out" && ! grep -q 'leaf.sh' <<<"$out"; then
  pass "T4 cap 35 tokens holds ($chars chars) and keeps the top file"
else fail "T4 chars=$chars out=$out"; fi

# T5: default order is by path, so a directory's files sit together.
out="$(python3 -I "$SCRIPT" --graph "$G")"
body="$(printf '%s\n' "$out" | grep -v '^#' | cut -d: -f1)"
if [ "$body" = "$(printf '%s\n' "$body" | LC_ALL=C sort)" ] && grep -q 'docs/c.md' <<<"$body"; then pass "T5 default order is by path"
else fail "T5 body=$body"; fi

# T5b: control bytes in a label never reach the map.
if grep -q '^scripts/leaf.sh: leaf \[31m()$' <<<"$out" && ! grep -q $'\x1b' <<<"$out"; then pass "T5b control bytes stripped from labels"
else fail "T5b out=$(printf '%q' "$out")"; fi

# T6: a missing graph is loud, exit 2.
python3 -I "$SCRIPT" --graph "$T/none.json" >/dev/null 2>"$T/err"; rc=$?
if [ "$rc" = 2 ] && grep -q 'no graph' "$T/err"; then pass "T6 missing graph exits 2"
else fail "T6 rc=$rc err=$(cat "$T/err")"; fi

if [ "$FAILS" -ne 0 ]; then echo "$FAILS FAILURES"; exit 1; fi
echo "ALL PASS"
