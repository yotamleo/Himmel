#!/usr/bin/env bash
# test-harden-graph.sh — HIMMEL-2983: hermetic tests for harden-graph.py, the
# idempotent post-update step that bridges doc nodes naming a code file to
# that file's AST node and adds allowlisted subprocess-exec code-fact edges.
# Run: bash scripts/graphify/test-harden-graph.sh
# Platform guard (gitbash-only): pure bash + python3, no .ps1 twin needed.
# shellcheck disable=SC2015  # A && pass || fail is the intentional test-assert idiom (pass/fail echo, always rc 0)
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/harden-graph.py"
FAILS=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS+1)); }

WS="$(mktemp -d "${TMPDIR:-/tmp}/harden-graph-test.XXXXXX")" || { echo "FAIL: mktemp -d failed"; exit 1; }
trap 'rm -rf "$WS"' EXIT

# Fixture: one ghost pair (doc label names an existing code file's basename,
# unique -> safe merge), one ambiguous pair (two AST files share a basename),
# one allowlisted subprocess-exec fact.
make_fixture() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/graph.json" <<'JSON'
{
  "directed": false,
  "multigraph": false,
  "graph": {},
  "nodes": [
    {"id": "doc_x", "label": "foo.mjs router", "source_file": "docs/x.md", "file_type": "concept"},
    {"id": "scripts_foo", "label": "foo.mjs", "source_file": "scripts/foo.mjs", "file_type": "code", "source_location": "L1"},
    {"id": "doc_y", "label": "util.sh", "source_file": "docs/y.md", "file_type": "concept"},
    {"id": "a_util", "label": "util.sh", "source_file": "a/util.sh", "file_type": "code", "source_location": "L1"},
    {"id": "b_util", "label": "util.sh", "source_file": "b/util.sh", "file_type": "code", "source_location": "L1"},
    {"id": "scripts_fanout", "label": "fanout-plan.mjs", "source_file": "scripts/lanes/fanout-plan.mjs", "file_type": "code", "source_location": "L1"},
    {"id": "scripts_resolve", "label": "resolve.mjs", "source_file": "scripts/lanes/resolve.mjs", "file_type": "code", "source_location": "L1"}
  ],
  "links": [],
  "hyperedges": []
}
JSON
  cat > "$dir/allowlist.json" <<'JSON'
[
  {"source_file": "scripts/lanes/fanout-plan.mjs", "target_file": "scripts/lanes/resolve.mjs", "relation": "calls", "source_location": "L105", "note": "test fixture"}
]
JSON
}

# --- T1: first run adds exactly the expected bridge + calls edge, skips the
# ambiguous pair, and prints the right counts ---
echo "T1: first run adds bridge + code-fact, skips ambiguous"
D1="$WS/t1"; make_fixture "$D1"
out1=$( python3 "$SCRIPT" --out "$D1" --allowlist "$D1/allowlist.json" ); rc1=$?
[ "$rc1" -eq 0 ] || fail "T1 exit 0 (got $rc1): $out1"
echo "$out1" | grep -qF "bridges=1 code-facts=1 skipped-ambiguous=1 unchanged=0" \
  && pass "T1 summary line has the right counts" \
  || fail "T1 summary line wrong: $out1"

if python3 - "$D1/graph.json" <<'PY'
import json, sys
g = json.load(open(sys.argv[1]))
links = g["links"]
assert len(links) == 2, f"expected 2 links, got {len(links)}: {links}"
bridge = next(e for e in links if e["hardened"] == "doc-label-names-code-file")
assert bridge["source"] == "doc_x" and bridge["target"] == "scripts_foo", bridge
assert bridge["relation"] == "references"
assert bridge["confidence"] == "EXTRACTED"
assert bridge["confidence_score"] == 1.0
assert bridge["source_file"] == "docs/x.md"
assert bridge["weight"] == 1.0
fact = next(e for e in links if e["hardened"] == "subprocess-exec")
assert fact["source"] == "scripts_fanout" and fact["target"] == "scripts_resolve", fact
assert fact["relation"] == "calls"
assert fact["source_location"] == "L105"
assert not any(e["source"] == "doc_y" for e in links), "ambiguous util.sh must not be bridged"
print("OK")
PY
then
  pass "T1 graph.json holds exactly the expected edges"
else
  fail "T1 graph.json content wrong"
fi

# --- T2: idempotent re-run -> unchanged=1, byte-identical graph.json ---
echo "T2: re-run is idempotent and byte-identical"
sum_before=$(sha256sum "$D1/graph.json" | awk '{print $1}')
out2=$( python3 "$SCRIPT" --out "$D1" --allowlist "$D1/allowlist.json" ); rc2=$?
[ "$rc2" -eq 0 ] || fail "T2 exit 0 (got $rc2): $out2"
echo "$out2" | grep -qF "unchanged=1" && pass "T2 reports unchanged=1" || fail "T2 did not report unchanged=1: $out2"
sum_after=$(sha256sum "$D1/graph.json" | awk '{print $1}')
[ "$sum_before" = "$sum_after" ] && pass "T2 graph.json byte-identical after re-run" || fail "T2 graph.json changed on re-run"

# --- T3: --dry-run writes nothing ---
echo "T3: --dry-run writes nothing"
D3="$WS/t3"; make_fixture "$D3"
sum_before3=$(sha256sum "$D3/graph.json" | awk '{print $1}')
out3=$( python3 "$SCRIPT" --out "$D3" --allowlist "$D3/allowlist.json" --dry-run ); rc3=$?
[ "$rc3" -eq 0 ] || fail "T3 exit 0 (got $rc3): $out3"
echo "$out3" | grep -qF "bridges=1 code-facts=1 skipped-ambiguous=1 unchanged=0" \
  && pass "T3 dry-run still reports the real counts" || fail "T3 dry-run counts wrong: $out3"
sum_after3=$(sha256sum "$D3/graph.json" | awk '{print $1}')
[ "$sum_before3" = "$sum_after3" ] && pass "T3 dry-run left graph.json untouched" || fail "T3 dry-run wrote to graph.json"

# --- T4: malformed JSON -> exit 1 ---
echo "T4: malformed graph.json -> exit 1"
D4="$WS/t4"; mkdir -p "$D4"
printf '{not json' > "$D4/graph.json"
out4=$( python3 "$SCRIPT" --out "$D4" 2>&1 ); rc4=$?
[ "$rc4" -eq 1 ] && pass "T4 malformed JSON exits 1" || fail "T4 expected exit 1, got $rc4: $out4"

# --- T5: missing graph.json -> exit 1 (unreadable input, not a crash) ---
echo "T5: missing graph.json -> exit 1"
D5="$WS/t5-missing"
out5=$( python3 "$SCRIPT" --out "$D5" 2>&1 ); rc5=$?
[ "$rc5" -eq 1 ] && pass "T5 missing graph.json exits 1" || fail "T5 expected exit 1, got $rc5: $out5"

# --- T6: cost.json note is appended only on a real (non-dry, non-unchanged) run ---
echo "T6: cost.json newest run note carries the harden summary"
D6="$WS/t6"; make_fixture "$D6"
cat > "$D6/cost.json" <<'JSON'
{"runs": [{"date": "2026-09-01T00:00:00Z", "input_tokens": 1, "output_tokens": 0, "files": 1, "note": "semantic pass"}], "total_input_tokens": 1, "total_output_tokens": 0}
JSON
python3 "$SCRIPT" --out "$D6" --allowlist "$D6/allowlist.json" >/dev/null
if python3 - "$D6/cost.json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
note = c["runs"][-1]["note"]
assert note.startswith("semantic pass; harden-graph:"), note
assert "bridges=1 code-facts=1 skipped-ambiguous=1 unchanged=0" in note, note
print("OK")
PY
then
  pass "T6 cost.json note carries the harden summary"
else
  fail "T6 cost.json note wrong"
fi
before_mtime=$(stat -c %Y "$D6/cost.json" 2>/dev/null || stat -f %m "$D6/cost.json")
sleep 1
python3 "$SCRIPT" --out "$D6" --allowlist "$D6/allowlist.json" >/dev/null
after_mtime=$(stat -c %Y "$D6/cost.json" 2>/dev/null || stat -f %m "$D6/cost.json")
[ "$before_mtime" = "$after_mtime" ] && pass "T6 unchanged re-run leaves cost.json untouched" || fail "T6 unchanged re-run rewrote cost.json"

# --- T7: no cost.json -> never created ---
echo "T7: harden never creates cost.json"
D7="$WS/t7"; make_fixture "$D7"
python3 "$SCRIPT" --out "$D7" --allowlist "$D7/allowlist.json" >/dev/null
[ ! -f "$D7/cost.json" ] && pass "T7 cost.json still absent" || fail "T7 harden created cost.json"

# --- T8: allowlist source_file missing at its exact path must NOT fall back
# to a same-basename file elsewhere -- that would fabricate a false,
# confidence-1.0 "calls" edge (codex-1, HIMMEL-2983 round 1) ---
echo "T8: allowlist entry requires an exact source_file path match, no basename fallback"
D8="$WS/t8"; mkdir -p "$D8"
cat > "$D8/graph.json" <<'JSON'
{
  "directed": false,
  "multigraph": false,
  "graph": {},
  "nodes": [
    {"id": "unrelated_fanout", "label": "fanout-plan.mjs", "source_file": "other/place/fanout-plan.mjs", "file_type": "code", "source_location": "L1"},
    {"id": "scripts_resolve", "label": "resolve.mjs", "source_file": "scripts/lanes/resolve.mjs", "file_type": "code", "source_location": "L1"}
  ],
  "links": [],
  "hyperedges": []
}
JSON
cat > "$D8/allowlist.json" <<'JSON'
[
  {"source_file": "scripts/lanes/fanout-plan.mjs", "target_file": "scripts/lanes/resolve.mjs", "relation": "calls", "source_location": "L105", "note": "test fixture"}
]
JSON
out8=$( python3 "$SCRIPT" --out "$D8" --allowlist "$D8/allowlist.json" ); rc8=$?
[ "$rc8" -eq 0 ] || fail "T8 exit 0 (got $rc8): $out8"
echo "$out8" | grep -qF "code-facts=0" \
  && pass "T8 no code-fact edge when allowlisted source_file is absent at its exact path" \
  || fail "T8 fabricated a code-fact edge via basename fallback: $out8"

# --- T9: a pre-existing edge between the same two nodes in REVERSE order
# must count as a duplicate too -- graph.json is undirected/non-multigraph, so
# (u, v) and (v, u) are the same edge (codex-2, HIMMEL-2983 round 1) ---
echo "T9: reverse-order existing edge is recognized as the same undirected edge"
D9="$WS/t9"; mkdir -p "$D9"
cat > "$D9/graph.json" <<'JSON'
{
  "directed": false,
  "multigraph": false,
  "graph": {},
  "nodes": [
    {"id": "scripts_fanout", "label": "fanout-plan.mjs", "source_file": "scripts/lanes/fanout-plan.mjs", "file_type": "code", "source_location": "L1"},
    {"id": "scripts_resolve", "label": "resolve.mjs", "source_file": "scripts/lanes/resolve.mjs", "file_type": "code", "source_location": "L1"}
  ],
  "links": [
    {"source": "scripts_resolve", "target": "scripts_fanout", "relation": "references"}
  ],
  "hyperedges": []
}
JSON
cat > "$D9/allowlist.json" <<'JSON'
[
  {"source_file": "scripts/lanes/fanout-plan.mjs", "target_file": "scripts/lanes/resolve.mjs", "relation": "calls", "source_location": "L105", "note": "test fixture"}
]
JSON
out9=$( python3 "$SCRIPT" --out "$D9" --allowlist "$D9/allowlist.json" ); rc9=$?
[ "$rc9" -eq 0 ] || fail "T9 exit 0 (got $rc9): $out9"
echo "$out9" | grep -qF "code-facts=0 skipped-ambiguous=0 unchanged=1" \
  && pass "T9 reverse-order existing edge suppresses the duplicate" \
  || fail "T9 added a duplicate reverse-direction edge: $out9"

if [ "$FAILS" -ne 0 ]; then echo "$FAILS FAILURES"; exit 1; fi
echo "ALL PASS"
