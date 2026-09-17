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
echo "$out1" | grep -qF "bridges=1 code-facts=1 skipped-ambiguous=1 skipped-path-mismatch=0 unchanged=0" \
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
# cmp -s (not sha256sum) checks byte-identity directly: an absent/failing
# checksum tool would silently compare two empty strings and false-pass
# (codex-2, HIMMEL-2983 round 2), whereas a missing cmp itself fails loudly.
echo "T2: re-run is idempotent and byte-identical"
cp "$D1/graph.json" "$D1/graph.json.before"
out2=$( python3 "$SCRIPT" --out "$D1" --allowlist "$D1/allowlist.json" ); rc2=$?
[ "$rc2" -eq 0 ] || fail "T2 exit 0 (got $rc2): $out2"
echo "$out2" | grep -qF "unchanged=1" && pass "T2 reports unchanged=1" || fail "T2 did not report unchanged=1: $out2"
cmp -s "$D1/graph.json.before" "$D1/graph.json" && pass "T2 graph.json byte-identical after re-run" || fail "T2 graph.json changed on re-run"

# --- T3: --dry-run writes nothing ---
echo "T3: --dry-run writes nothing"
D3="$WS/t3"; make_fixture "$D3"
cp "$D3/graph.json" "$D3/graph.json.before"
out3=$( python3 "$SCRIPT" --out "$D3" --allowlist "$D3/allowlist.json" --dry-run ); rc3=$?
[ "$rc3" -eq 0 ] || fail "T3 exit 0 (got $rc3): $out3"
echo "$out3" | grep -qF "bridges=1 code-facts=1 skipped-ambiguous=1 skipped-path-mismatch=0 unchanged=0" \
  && pass "T3 dry-run still reports the real counts" || fail "T3 dry-run counts wrong: $out3"
cmp -s "$D3/graph.json.before" "$D3/graph.json" && pass "T3 dry-run left graph.json untouched" || fail "T3 dry-run wrote to graph.json"

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
assert "bridges=1 code-facts=1 skipped-ambiguous=1 skipped-path-mismatch=0 unchanged=0" in note, note
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
echo "$out9" | grep -qF "code-facts=0 skipped-ambiguous=0 skipped-path-mismatch=0 unchanged=1" \
  && pass "T9 reverse-order existing edge suppresses the duplicate" \
  || fail "T9 added a duplicate reverse-direction edge: $out9"

# --- T10: an allowlisted dotfile-style path (leading "." that is not a "./"
# prefix) must match itself exactly, never get mangled by a character-class
# lstrip into an unrelated same-tail path (codex-1, HIMMEL-2983 round 2) ---
echo "T10: allowlist source_file starting with a bare dot matches exactly, no character-class stripping"
D10="$WS/t10"; mkdir -p "$D10"
cat > "$D10/graph.json" <<'JSON'
{
  "directed": false,
  "multigraph": false,
  "graph": {},
  "nodes": [
    {"id": "dotfile_tool", "label": "tool.sh", "source_file": ".config/tool.sh", "file_type": "code", "source_location": "L1"},
    {"id": "decoy_tool", "label": "tool.sh", "source_file": "config/tool.sh", "file_type": "code", "source_location": "L1"},
    {"id": "scripts_resolve", "label": "resolve.mjs", "source_file": "scripts/lanes/resolve.mjs", "file_type": "code", "source_location": "L1"}
  ],
  "links": [],
  "hyperedges": []
}
JSON
cat > "$D10/allowlist.json" <<'JSON'
[
  {"source_file": ".config/tool.sh", "target_file": "scripts/lanes/resolve.mjs", "relation": "calls", "source_location": "L1", "note": "test fixture"}
]
JSON
out10=$( python3 "$SCRIPT" --out "$D10" --allowlist "$D10/allowlist.json" ); rc10=$?
[ "$rc10" -eq 0 ] || fail "T10 exit 0 (got $rc10): $out10"
echo "$out10" | grep -qF "code-facts=1" \
  && pass "T10 dotfile-style source_file resolves" \
  || fail "T10 did not add the code-fact edge: $out10"
if python3 - "$D10/graph.json" <<'PY'
import json, sys
g = json.load(open(sys.argv[1]))
fact = next(e for e in g["links"] if e["hardened"] == "subprocess-exec")
assert fact["source"] == "dotfile_tool", f"expected dotfile_tool, got {fact['source']} (mangled by lstrip)"
print("OK")
PY
then
  pass "T10 code-fact edge points at the exact dotfile path, not the decoy"
else
  fail "T10 code-fact edge points at the wrong node (lstrip character-class bug)"
fi

# --- T11: an explicit --allowlist path that does not exist is a typo, not
# the normal "no allowlist yet" case -- it must exit 1, never silently
# suppress every code-fact edge while reporting success (codex-2,
# HIMMEL-2983 round 3) ---
echo "T11: explicit --allowlist pointing nowhere exits 1, not a silent no-op"
D11="$WS/t11"; make_fixture "$D11"
out11=$( python3 "$SCRIPT" --out "$D11" --allowlist "$D11/does-not-exist.json" 2>&1 ); rc11=$?
[ "$rc11" -eq 1 ] && pass "T11 missing explicit --allowlist exits 1" || fail "T11 expected exit 1, got $rc11: $out11"

# --- T12: a doc token with a directory component that CONTRADICTS the only
# same-basename AST file must NOT fall back to a bare-basename guess -- it is
# unresolved and counted in skipped-path-mismatch, never bridged (HIMMEL-3005;
# this is the RED case on the pre-fix resolver, which bridges it via the
# basename fallback) ---
echo "T12: directory-qualified token with no matching path is unresolved, not basename-guessed"
D12="$WS/t12"; mkdir -p "$D12"
cat > "$D12/graph.json" <<'JSON'
{
  "directed": false,
  "multigraph": false,
  "graph": {},
  "nodes": [
    {"id": "doc_mismatch", "label": "nonexistent/foo.mjs file", "source_file": "docs/z.md", "file_type": "concept"},
    {"id": "scripts_foo", "label": "foo.mjs", "source_file": "scripts/foo.mjs", "file_type": "code", "source_location": "L1"}
  ],
  "links": [],
  "hyperedges": []
}
JSON
out12=$( python3 "$SCRIPT" --out "$D12" ); rc12=$?
[ "$rc12" -eq 0 ] || fail "T12 exit 0 (got $rc12): $out12"
echo "$out12" | grep -qF "bridges=0 code-facts=0 skipped-ambiguous=0 skipped-path-mismatch=1 unchanged=1" \
  && pass "T12 directory-qualified mismatch is skipped-path-mismatch, not bridged" \
  || fail "T12 summary wrong (RED: pre-fix resolver bridges via basename fallback): $out12"

# --- T13: a partial-but-correct token (directory component that matches a
# SUFFIX of the real path, not the whole thing) resolves by path suffix --
# this is the common real-corpus shape (docs writing "lanes/resolve.mjs" for
# "scripts/lanes/resolve.mjs") that a strict bare-token-only rule would drop
# (HIMMEL-3005, console ruling E1) ---
echo "T13: directory-qualified token resolves by unique path suffix"
D13="$WS/t13"; mkdir -p "$D13"
cat > "$D13/graph.json" <<'JSON'
{
  "directed": false,
  "multigraph": false,
  "graph": {},
  "nodes": [
    {"id": "doc_suffix", "label": "lanes/resolve.mjs module", "source_file": "docs/w.md", "file_type": "concept"},
    {"id": "scripts_resolve", "label": "resolve.mjs", "source_file": "scripts/lanes/resolve.mjs", "file_type": "code", "source_location": "L1"}
  ],
  "links": [],
  "hyperedges": []
}
JSON
out13=$( python3 "$SCRIPT" --out "$D13" ); rc13=$?
[ "$rc13" -eq 0 ] || fail "T13 exit 0 (got $rc13): $out13"
echo "$out13" | grep -qF "bridges=1 code-facts=0 skipped-ambiguous=0 skipped-path-mismatch=0 unchanged=0" \
  && pass "T13 partial-but-correct token bridges via path suffix" \
  || fail "T13 suffix match failed: $out13"
if python3 - "$D13/graph.json" <<'PY'
import json, sys
g = json.load(open(sys.argv[1]))
bridge = next(e for e in g["links"] if e["hardened"] == "doc-label-names-code-file")
assert bridge["source"] == "doc_suffix" and bridge["target"] == "scripts_resolve", bridge
print("OK")
PY
then
  pass "T13 bridge targets the suffix-matched node"
else
  fail "T13 bridge targeted the wrong node"
fi

# --- T14: a directory-qualified token matching a suffix of TWO different AST
# files is ambiguous, not resolved by guessing ---
echo "T14: directory-qualified token matching two path suffixes is ambiguous"
D14="$WS/t14"; mkdir -p "$D14"
cat > "$D14/graph.json" <<'JSON'
{
  "directed": false,
  "multigraph": false,
  "graph": {},
  "nodes": [
    {"id": "doc_ambig", "label": "lib/x.sh script", "source_file": "docs/v.md", "file_type": "concept"},
    {"id": "a_lib_x", "label": "x.sh", "source_file": "a/lib/x.sh", "file_type": "code", "source_location": "L1"},
    {"id": "b_lib_x", "label": "x.sh", "source_file": "b/lib/x.sh", "file_type": "code", "source_location": "L1"}
  ],
  "links": [],
  "hyperedges": []
}
JSON
out14=$( python3 "$SCRIPT" --out "$D14" ); rc14=$?
[ "$rc14" -eq 0 ] || fail "T14 exit 0 (got $rc14): $out14"
echo "$out14" | grep -qF "bridges=0 code-facts=0 skipped-ambiguous=1 skipped-path-mismatch=0 unchanged=1" \
  && pass "T14 two-way suffix match is skipped-ambiguous, not guessed" \
  || fail "T14 summary wrong: $out14"

if [ "$FAILS" -ne 0 ]; then echo "$FAILS FAILURES"; exit 1; fi
echo "ALL PASS"
