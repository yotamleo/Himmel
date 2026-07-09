#!/usr/bin/env bash
# Hermetic test for refresh-graph-map.sh — stubs graphify (GRAPHIFY_MAP_BIN), no
# network, no real vault. Run: bash scripts/graphify/test-refresh-graph-map.sh
# shellcheck disable=SC2015  # A && pass || fail is the intentional test-assert idiom (pass/fail echo, always rc 0)
# shellcheck disable=SC2016  # the heredoc report fixture is literal on purpose (no expansion wanted)
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/refresh-graph-map.sh"
FAILS=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS+1)); }

WS="$(mktemp -d)"; trap 'rm -rf "$WS"' EXIT
CORPUS="$WS/vault"; mkdir -p "$CORPUS/notes"; printf '# n\ncontent\n' > "$CORPUS/notes/a.md"
MAPS="$WS/vault/60-Maps"; mkdir -p "$MAPS"

REPORT_FIXTURE='# Graph Report - X

## Summary
- 42 nodes · 30 edges · 5 communities (5 shown)

## God Nodes (most connected - your core abstractions)
1. `Core` - 9 edges

## Surprising Connections (you probably didn'"'"'t know these)
- `A` --references--> `B`  [INFERRED]

## Communities (5 total)

### Community 0 - "Alpha"
Cohesion: 0.06
Nodes (20): a, b (+18 more)
'

# stub graphify: on `<path> --update` and `cluster-only <path>` write graphify-out/graph.json + GRAPH_REPORT.md
BIN="$WS/bin"; mkdir -p "$BIN"
cat > "$BIN/graphify" <<STUB
#!/usr/bin/env bash
# args: either "<path> --update ..." or "cluster-only <path> ..."
target=""
if [ "\$1" = "cluster-only" ]; then target="\$2"; else target="\$1"; fi
mkdir -p "\$target/graphify-out"
printf '{"nodes":[],"edges":[]}' > "\$target/graphify-out/graph.json"
cat > "\$target/graphify-out/GRAPH_REPORT.md" <<'RPT'
$REPORT_FIXTURE
RPT
exit 0
STUB
chmod +x "$BIN/graphify"
export PATH="$BIN:$PATH"           # satisfies the command -v graphify check
export GRAPHIFY_MAP_BIN="$BIN/graphify"

# --- T1: full path (copy → update → cluster-only → publish) ---
SCRATCH_PARENT="$WS/scratch"; mkdir -p "$SCRATCH_PARENT"
# pre-seed an unrelated file under the scratch parent — it must SURVIVE (the
# launcher must only rm -rf its own PID-owned subdir, not the parent).
printf 'KEEP' > "$SCRATCH_PARENT/unrelated.txt"
out=$( bash "$SCRIPT" --name luna --corpus-root "$CORPUS" --backend deepseek \
  --maps-dir "$MAPS" --title "Graphify Luna Map" --slug graphify-luna-map --corpus-tag luna \
  --scratch "$SCRATCH_PARENT" 2>&1 ); rc=$?
[ "$rc" -eq 0 ] || { fail "full run exit 0 (got $rc): $out"; }
[ -f "$MAPS/graphify-luna-map.md" ] || fail "MOC published to maps-dir"
[ -f "$CORPUS/graphify-out/graph.json" ] || fail "graph.json promoted to repo-local graphify-out"
grep -q "type: moc" "$MAPS/graphify-luna-map.md" 2>/dev/null && pass "T1 published MOC has moc frontmatter" || fail "T1 MOC frontmatter"
grep -q "graph_nodes: 42" "$MAPS/graphify-luna-map.md" 2>/dev/null && pass "T1 MOC carries parsed stats" || fail "T1 stats"
grep -q "Alpha" "$MAPS/graphify-luna-map.md" 2>/dev/null && pass "T1 MOC carries community" || fail "T1 community"
# owned PID-subdir cleaned up, but the operator-supplied scratch PARENT + its
# unrelated contents are untouched (codex-adv [codex-1] regression pin).
ls "$SCRATCH_PARENT"/graphify-refresh-* >/dev/null 2>&1 && fail "owned scratch subdir left behind" || pass "T1 owned scratch subdir cleaned"
[ -f "$SCRATCH_PARENT/unrelated.txt" ] && pass "T1 scratch-parent unrelated data preserved" || fail "T1 clobbered unrelated data in scratch parent"

# --- T2: --no-update publishes from an existing repo-local report without re-extracting ---
printf 'SENTINEL-EXISTING' > "$CORPUS/graphify-out/graph.json"   # must NOT be overwritten under --no-update
rm -f "$MAPS/graphify-luna-map.md"
out=$( bash "$SCRIPT" --name luna --corpus-root "$CORPUS" --maps-dir "$MAPS" \
  --title "Graphify Luna Map" --slug graphify-luna-map --no-update 2>&1 ); rc=$?
[ "$rc" -eq 0 ] || fail "no-update exit 0 (got $rc): $out"
[ -f "$MAPS/graphify-luna-map.md" ] && pass "T2 no-update republishes MOC" || fail "T2 no-update MOC"
grep -q "SENTINEL-EXISTING" "$CORPUS/graphify-out/graph.json" 2>/dev/null && pass "T2 no-update leaves graph.json untouched" || fail "T2 graph.json clobbered under --no-update"

# --- T2c: --no-update works even when graphify is NOT on PATH (publish-only
# must not require the extraction tool — CR: code-reviewer). node must stay
# reachable (the curator is node); only graphify is absent. ---
rm -f "$MAPS/graphify-luna-map.md"
NODE_DIR="$(dirname "$(command -v node)")"
out=$( env -u GRAPHIFY_MAP_BIN PATH="$NODE_DIR:/usr/bin:/bin" bash "$SCRIPT" --name luna --corpus-root "$CORPUS" \
  --maps-dir "$MAPS" --title "Graphify Luna Map" --slug graphify-luna-map --no-update 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && [ -f "$MAPS/graphify-luna-map.md" ] && pass "T2c no-update publishes without graphify on PATH" || fail "T2c no-update needs graphify (rc=$rc): $out"

# --- T3: missing report under --no-update fails closed (exit 1) ---
rm -f "$CORPUS/graphify-out/GRAPH_REPORT.md"
bash "$SCRIPT" --name luna --corpus-root "$CORPUS" --maps-dir "$MAPS" \
  --title T --slug graphify-luna-map --no-update >/dev/null 2>&1
[ "$?" -eq 1 ] && pass "T3 missing report under --no-update exits 1" || fail "T3 missing report exit code"

# --- T4: missing required flag → usage exit 1 ---
bash "$SCRIPT" --name luna >/dev/null 2>&1
[ "$?" -eq 1 ] && pass "T4 missing flags exits 1" || fail "T4 usage exit code"

# --- T5: a garbage/malformed report must NOT clobber the last-good MOC
# (curator refuses to publish → exit propagates; existing MOC survives). ---
printf 'GOOD-MAP-KEEP' > "$MAPS/graphify-luna-map.md"
printf 'garbage text, no recognizable headers at all\n' > "$CORPUS/graphify-out/GRAPH_REPORT.md"
bash "$SCRIPT" --name luna --corpus-root "$CORPUS" --maps-dir "$MAPS" \
  --title T --slug graphify-luna-map --no-update >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "T5 garbage report → non-zero exit (publish refused)" || fail "T5 garbage report exit code (got $rc)"
grep -q "GOOD-MAP-KEEP" "$MAPS/graphify-luna-map.md" 2>/dev/null && pass "T5 last-good MOC not clobbered by garbage report" || fail "T5 garbage report clobbered the good MOC"

if [ "$FAILS" -ne 0 ]; then echo "$FAILS FAILURES"; exit 1; fi
echo "ALL PASS"
