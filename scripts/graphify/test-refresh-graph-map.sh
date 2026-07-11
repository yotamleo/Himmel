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
# F4 (HIMMEL-907): a .md added AFTER T1's stamp but BEFORE this no-update run
# must NOT appear in manifest.json — pins that --no-update never re-stamps (a
# refactor dragging the stamp block below the fi would re-attest old graphs).
printf '# t2 added\nadded between T1 stamp and no-update\n' > "$CORPUS/notes/t2-added.md"
rm -f "$MAPS/graphify-luna-map.md"
out=$( bash "$SCRIPT" --name luna --corpus-root "$CORPUS" --maps-dir "$MAPS" \
  --title "Graphify Luna Map" --slug graphify-luna-map --no-update 2>&1 ); rc=$?
[ "$rc" -eq 0 ] || fail "no-update exit 0 (got $rc): $out"
[ -f "$MAPS/graphify-luna-map.md" ] && pass "T2 no-update republishes MOC" || fail "T2 no-update MOC"
grep -q "SENTINEL-EXISTING" "$CORPUS/graphify-out/graph.json" 2>/dev/null && pass "T2 no-update leaves graph.json untouched" || fail "T2 graph.json clobbered under --no-update"
if grep -q "t2-added.md" "$CORPUS/graphify-out/manifest.json" 2>/dev/null; then
  fail "T2/F4 --no-update re-stamped manifest (gained t2-added.md)"
else
  pass "T2/F4 --no-update did not re-stamp manifest"
fi

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

# --- T6: HIMMEL-907 a SUCCESSFUL refresh stamps manifest.json + .graphify_root
# at the out root, and check-graph-freshness.sh PASSES on that dir. This last
# assertion is the real acceptance: the guard can VERIFY the refreshed graph
# (no longer "fresh by age" only). Uses its own hermetic corpus so it is
# independent of the T1-T5 mutations above. ---
FRESH="$WS/fresh"; FCORPUS="$FRESH/corpus"; FMAPS="$FRESH/maps"
mkdir -p "$FCORPUS/notes" "$FMAPS"
printf '# a\nalpha content\n' > "$FCORPUS/a.md"
printf '# b\nbeta content\n' > "$FCORPUS/notes/b.md"
out=$( bash "$SCRIPT" --name fresh --corpus-root "$FCORPUS" --backend deepseek \
  --maps-dir "$FMAPS" --title "Fresh Map" --slug fresh-map --corpus-tag fresh 2>&1 ); rc=$?
[ "$rc" -eq 0 ] || { fail "T6 refresh exit 0 (got $rc): $out"; }
FOUT="$FCORPUS/graphify-out"
[ -f "$FOUT/manifest.json" ] && pass "T6 manifest.json written at out root" || fail "T6 manifest.json missing at out root"
[ -f "$FOUT/.graphify_root" ] && pass "T6 .graphify_root marker written" || fail "T6 .graphify_root marker missing"
out=$( bash "$HERE/check-graph-freshness.sh" --out "$FOUT" --max-age-days 7 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && pass "T6 guard PASSES on refreshed dir (corpus verified)" || fail "T6 guard should PASS on refreshed dir (got rc=$rc): $out"

# --- T6b: manifest.json shape — a non-empty object keyed by corpus md paths
# (the source of truth for shape is the guard's parser: keys only; values are
# free-form). ---
python3 - "$FOUT/manifest.json" <<'PY' 2>/dev/null && pass "T6b manifest.json is a non-empty object keyed by corpus md paths" || fail "T6b manifest.json shape"
import json, sys
d = json.load(open(sys.argv[1]))
assert isinstance(d, dict) and d, "manifest is not a non-empty object"
assert "a.md" in d and "notes/b.md" in d, "expected corpus md keys missing"
# F5 (HIMMEL-907): the derived out dir must be pruned from the manifest walk —
# GRAPH_REPORT.md sits in graphify-out/ at walk time and must not leak into keys.
assert not any(k.startswith("graphify-out/") for k in d), "graphify-out leaked into manifest keys"
PY

# --- T6c: a FAILED refresh stamps NOTHING (graphify --update fails -> exit 2
# before manifest/marker writing; a fresh out dir is left with neither). ---
FAILBIN="$WS/failbin"; mkdir -p "$FAILBIN"
cat > "$FAILBIN/graphify" <<'STUB'
#!/usr/bin/env bash
echo "simulated graphify failure" >&2
exit 2
STUB
chmod +x "$FAILBIN/graphify"
FCORPUS2="$WS/failcorpus"; FMAPS2="$WS/failmaps"
mkdir -p "$FCORPUS2/notes" "$FMAPS2"
printf '# x\n' > "$FCORPUS2/x.md"
out=$( env GRAPHIFY_MAP_BIN="$FAILBIN/graphify" PATH="$FAILBIN:$PATH" \
  bash "$SCRIPT" --name fail --corpus-root "$FCORPUS2" --backend deepseek \
  --maps-dir "$FMAPS2" --title "Fail Map" --slug fail-map --corpus-tag fail 2>&1 ); rc=$?
[ "$rc" -eq 2 ] && pass "T6c failed refresh exits 2" || fail "T6c failed refresh should exit 2 (got $rc): $out"
FOUT2="$FCORPUS2/graphify-out"
if [ -e "$FOUT2/manifest.json" ] || [ -e "$FOUT2/.graphify_root" ]; then
  fail "T6c failed refresh stamped freshness artifacts (must never stamp a failed run as fresh)"
else
  pass "T6c failed refresh stamped nothing"
fi

# --- T6d: idempotent re-run — a second successful refresh rewrites the same
# artifacts and the guard still PASSES. ---
# F6 (HIMMEL-907): add a NEW .md between the T6 stamp and this re-run; the
# re-run manifest must CONTAIN it (refresh semantics — a real re-walk — not mere
# presence of the old manifest).
printf '# t6d added\nadded between T6 and the idempotent re-run\n' > "$FCORPUS/notes/t6d-added.md"
out=$( bash "$SCRIPT" --name fresh --corpus-root "$FCORPUS" --backend deepseek \
  --maps-dir "$FMAPS" --title "Fresh Map" --slug fresh-map --corpus-tag fresh 2>&1 ); rc=$?
[ "$rc" -eq 0 ] || fail "T6d idempotent re-run exit 0 (got $rc): $out"
[ -f "$FOUT/manifest.json" ] && [ -f "$FOUT/.graphify_root" ] && pass "T6d artifacts present after re-run" || fail "T6d artifacts missing after re-run"
grep -q "t6d-added.md" "$FOUT/manifest.json" 2>/dev/null && pass "T6d/F6 re-run manifest gained the new key (real refresh)" || fail "T6d/F6 re-run manifest missing the new key (stale, not a real rewrite)"
out=$( bash "$HERE/check-graph-freshness.sh" --out "$FOUT" --max-age-days 7 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && pass "T6d guard PASSES after idempotent re-run" || fail "T6d guard should PASS after re-run (got rc=$rc): $out"

# --- T6e (HIMMEL-907 F1): manifest.json must come from the SCRATCH corpus the
# graph actually saw, NOT the live corpus. A graphify stub that, mid --update,
# ALSO drops a new .md into the LIVE corpus (via MUTATE_TARGET) — the manifest
# must NOT attest that file: the scratch copy was made before the mutation, so
# the graph never saw it. RED until the manifest walks the scratch copy. ---
ECORPUS="$WS/ecorpus"; EMAPS="$WS/emaps"; mkdir -p "$ECORPUS/notes" "$EMAPS"
printf '# e\nexisting\n' > "$ECORPUS/notes/e.md"
EBIN="$WS/ebin"; mkdir -p "$EBIN"
cat > "$EBIN/graphify" <<STUB
#!/usr/bin/env bash
# args: either "<path> --update ..." or "cluster-only <path> ..."
target=""
if [ "\$1" = "cluster-only" ]; then target="\$2"; else target="\$1"; fi
mkdir -p "\$target/graphify-out"
printf '{"nodes":[],"edges":[]}' > "\$target/graphify-out/graph.json"
cat > "\$target/graphify-out/GRAPH_REPORT.md" <<'RPT'
$REPORT_FIXTURE
RPT
# mid-extraction mutation of the LIVE corpus — the graph (run on the scratch
# copy) never sees this file, so the manifest must not attest it.
if [ "\$1" != "cluster-only" ] && [ -n "\$MUTATE_TARGET" ]; then
  printf '# mutated\nmutated during extraction\n' > "\$MUTATE_TARGET/MUTATED-DURING-EXTRACTION.md"
fi
exit 0
STUB
chmod +x "$EBIN/graphify"
out=$( MUTATE_TARGET="$ECORPUS" GRAPHIFY_MAP_BIN="$EBIN/graphify" PATH="$EBIN:$PATH" \
  bash "$SCRIPT" --name emut --corpus-root "$ECORPUS" --backend deepseek \
  --maps-dir "$EMAPS" --title "E Map" --slug e-map --corpus-tag e 2>&1 ); rc=$?
[ "$rc" -eq 0 ] || { fail "T6e mutate-stub refresh exit 0 (got $rc): $out"; }
if grep -q "MUTATED-DURING-EXTRACTION.md" "$ECORPUS/graphify-out/manifest.json" 2>/dev/null; then
  fail "T6e manifest attests a file mutated mid-extraction (must walk scratch, not live corpus)"
else
  pass "T6e manifest excludes mid-extraction corpus mutation (walks scratch copy)"
fi

# --- T6f (HIMMEL-907 F2+F3): a python3-less box must fail BEFORE spending
# extraction money AND before promoting a new graph. Run under a hermetic PATH
# that carries every tool the script needs EXCEPT python3 (graphify stays an
# absolute GRAPHIFY_MAP_BIN); pre-seed a sentinel graph.json; assert rc=2, stderr
# mentions python3, AND the sentinel is UNCHANGED (no promotion happened). RED
# until the python3 preflight is hoisted above the promote step. ---
# shellcheck source=../lib/hermetic-path.sh
# shellcheck disable=SC1091
. "$HERE/../lib/hermetic-path.sh"
HBIN="$WS/hbin"; mkdir -p "$HBIN"
for _tool in bash env find cp mkdir rm mv dirname date cat node; do
  link_hermetic_tool "$_tool" "$HBIN"
done
# Hermetic PATH carrying every tool EXCEPT python3. scrub_path drops every dir
# that carries python3. On stock Ubuntu python3 shares /usr/bin with bash +
# coreutils, so the blind scrub takes bash down too — the linked $HBIN stub bin
# (prepended) restores them there. On Git Bash/MSys python3 lives in a user dir
# (not /usr/bin), so the scrub leaves the real /usr/bin tools — and the COPIED
# stubs in $HBIN can't load msys-2.0.dll from the stub dir anyway, so prefer the
# scrubbed REAL path when it still runs bash; fall back to the stub bin only when
# the scrub took bash down (probe = actually exec, not just command -v, because a
# copied-but-DLL-broken bash still resolves via command -v on MSys).
PYFREE="$(scrub_path "$PATH" python3)"
HPATH="$HBIN:$PYFREE"
if PATH="$PYFREE" bash -c 'true' 2>/dev/null; then HPATH="$PYFREE"; fi
# belt-and-braces: the chosen hermetic PATH must really lack python3.
if PATH="$HPATH" command -v python3 >/dev/null 2>&1; then
  fail "T6f hermetic PATH still resolves python3 — scrub did not isolate it"
fi
PBIN="$WS/pbin"; mkdir -p "$PBIN"
cat > "$PBIN/graphify" <<STUB
#!/usr/bin/env bash
target=""
if [ "\$1" = "cluster-only" ]; then target="\$2"; else target="\$1"; fi
mkdir -p "\$target/graphify-out"
printf '{"nodes":[],"edges":[]}' > "\$target/graphify-out/graph.json"
cat > "\$target/graphify-out/GRAPH_REPORT.md" <<'RPT'
$REPORT_FIXTURE
RPT
exit 0
STUB
chmod +x "$PBIN/graphify"
PCORPUS="$WS/pcorpus"; PMAPS="$WS/pmaps"; mkdir -p "$PCORPUS/graphify-out" "$PMAPS"
printf '# c\ncontent\n' > "$PCORPUS/c.md"
printf 'SENTINEL-PRE-PYTHON' > "$PCORPUS/graphify-out/graph.json"
out=$( PATH="$HPATH" GRAPHIFY_MAP_BIN="$PBIN/graphify" \
  bash "$SCRIPT" --name hpy --corpus-root "$PCORPUS" --backend deepseek \
  --maps-dir "$PMAPS" --title "H Map" --slug h-map --corpus-tag h 2>&1 ); rc=$?
[ "$rc" -eq 2 ] && pass "T6f python3-less box exits 2" || fail "T6f python3-less box should exit 2 (got $rc): $out"
echo "$out" | grep -q "python3" && pass "T6f stderr mentions python3" || fail "T6f stderr should mention python3: $out"
grep -q "SENTINEL-PRE-PYTHON" "$PCORPUS/graphify-out/graph.json" 2>/dev/null \
  && pass "T6f sentinel graph.json unchanged (no promotion before python3 check)" \
  || fail "T6f sentinel graph.json clobbered (promoted before the python3 check)"

# --- T6g (HIMMEL-907 F2/F7): publish-failure semantics. A graphify stub that
# emits a VALID graph.json but a GARBAGE report (unparseable by the curator) →
# the run exits NON-ZERO at the publish step, AND the freshness stamps ARE
# present: the graph itself is fresh (promote + stamp happen before publish), so
# only the MOC publish failed. Pins F2's invariant that stamps precede publish
# and survive a publish failure. ---
GBIN="$WS/gbin"; mkdir -p "$GBIN"
cat > "$GBIN/graphify" <<STUB
#!/usr/bin/env bash
target=""
if [ "\$1" = "cluster-only" ]; then target="\$2"; else target="\$1"; fi
mkdir -p "\$target/graphify-out"
printf '{"nodes":[],"edges":[]}' > "\$target/graphify-out/graph.json"
printf 'totally unparseable garbage report - no recognizable headers at all\n' > "\$target/graphify-out/GRAPH_REPORT.md"
exit 0
STUB
chmod +x "$GBIN/graphify"
GCORPUS="$WS/gcorpus"; GMAPS="$WS/gmaps"; mkdir -p "$GCORPUS/notes" "$GMAPS"
printf '# g\ncontent\n' > "$GCORPUS/notes/g.md"
out=$( GRAPHIFY_MAP_BIN="$GBIN/graphify" PATH="$GBIN:$PATH" \
  bash "$SCRIPT" --name gbg --corpus-root "$GCORPUS" --backend deepseek \
  --maps-dir "$GMAPS" --title "G Map" --slug g-map --corpus-tag g 2>&1 ); rc=$?
[ "$rc" -ne 0 ] && pass "T6g garbage report → non-zero exit at publish" || fail "T6g garbage report should exit non-zero (got $rc): $out"
GOUT="$GCORPUS/graphify-out"
if [ -f "$GOUT/manifest.json" ] && [ -f "$GOUT/.graphify_root" ]; then
  pass "T6g freshness stamps present despite publish failure (graph is fresh)"
else
  fail "T6g freshness stamps missing after publish failure (F2 stamp-before-publish broke)"
fi

if [ "$FAILS" -ne 0 ]; then echo "$FAILS FAILURES"; exit 1; fi
echo "ALL PASS"
