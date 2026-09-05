#!/usr/bin/env bash
# Hermetic test for refresh-graph-map.sh — stubs graphify (GRAPHIFY_MAP_BIN), no
# network, no real vault. Run: bash scripts/graphify/test-refresh-graph-map.sh
# shellcheck disable=SC2015  # A && pass || fail is the intentional test-assert idiom (pass/fail echo, always rc 0)
# shellcheck disable=SC2016  # the heredoc report fixture is literal on purpose (no expansion wanted)
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/refresh-graph-map.sh"
FAILS=0
SKIPS=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS+1)); }
skip() { echo "  SKIP: $1"; SKIPS=$((SKIPS+1)); }

WS="$(mktemp -d)"; trap 'rm -rf "$WS"' EXIT
# HIMMEL-1406: scope the default scratch parent to $WS. Most tests below
# don't pass --scratch, so refresh-graph-map.sh falls back to
# ${TMPDIR:-/tmp} -- and a promote-refusal now quarantines the extracted
# graphify-out there (see _scratch_cleanup) instead of deleting it. Without
# this, every leak/refusal test in this file would leave a quarantine dir
# behind in the REAL system temp dir on every run. Scoping TMPDIR to $WS
# keeps them inside the hermetic workspace this file's own EXIT trap sweeps.
export TMPDIR="$WS/tmp"; mkdir -p "$TMPDIR"
export GRAPHIFY_LEDGER="$WS/graphify-egress.jsonl"
# Keep default claude/claude-cli + kimi cases hermetic: the runner's launching
# shell may itself be routed through an Anthropic-compatible proxy or carry a
# stale KIMI_BASE_URL (T40b assumes no inherited Kimi endpoint; the preflight
# check at refresh-graph-map.sh:176 would otherwise misfire). Endpoint-specific
# tests below set these explicitly.
unset ANTHROPIC_BASE_URL KIMI_BASE_URL
HERMETIC_HOME="$WS/hermetic-home"; mkdir -p "$HERMETIC_HOME/.claude"
printf 'test-subscription-auth\n' > "$HERMETIC_HOME/.claude/.credentials.json"
printf '{}\n' > "$HERMETIC_HOME/.claude/settings.json"
export HOME="$HERMETIC_HOME"
export GIT_AUTHOR_NAME="himmel test" GIT_AUTHOR_EMAIL="test@himmel.invalid"
export GIT_COMMITTER_NAME="himmel test" GIT_COMMITTER_EMAIL="test@himmel.invalid"
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
# Evidence-producing stubs also short-circuit `--version`: production probes it
# after extraction, so treating it as another update can overwrite their evidence.
BIN="$WS/bin"; mkdir -p "$BIN"
cat > "$BIN/graphify" <<STUB
#!/usr/bin/env bash
# args: either "<path> --update ..." or "cluster-only <path> ..."
# When GRAPHIFY_CALL_LOG is set, append the full arg line of every invocation
# (one per line) so a test can assert what flags reached graphify (T21 uses this
# to verify GRAPHIFY_MAX_CONCURRENCY is wired to --max-concurrency, and that an
# invalid value fails BEFORE any extraction call).
[ -n "\$GRAPHIFY_CALL_LOG" ] && printf '%s\n' "\$*" >> "\$GRAPHIFY_CALL_LOG"
target=""
if [ "\$1" = "cluster-only" ]; then target="\$2"; else target="\$1"; fi
mkdir -p "\$target/graphify-out"
printf '{"nodes":[],"links":[]}' > "\$target/graphify-out/graph.json"
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
out=$( bash "$SCRIPT" --name luna --corpus-root "$CORPUS" --backend claude-cli \
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

# --- T1b: DEFAULT backend is claude-cli (HIMMEL-1049 "himmel off deepseek") —
# when no --backend is passed, refresh-graph-map must invoke graphify with
# --backend claude-cli: graphify's `claude-cli` routes through the local `claude`
# CLI on the operator's Pro/Max SUBSCRIPTION (no ANTHROPIC_API_KEY, priced 0.0),
# whereas `claude` is the pay-as-you-go Anthropic API path — the claude-only
# adopter story needs claude-cli. A logging stub records the argv so we can
# assert the exact default flowed through. ---
LOGBIN="$WS/logbin"; mkdir -p "$LOGBIN"
BACKEND_LOG="$WS/backend.log"; : > "$BACKEND_LOG"
cat > "$LOGBIN/graphify" <<STUB
#!/usr/bin/env bash
# Log argv ONE-PER-LINE (CodeRabbit): preserves argument boundaries so the
# assertion can check the exact token after --backend (a joined-string grep
# would let --backend claude-cli satisfy a "--backend claude" substring match).
printf '%s\n' "\$@" >> "$BACKEND_LOG"
target=""
if [ "\$1" = "cluster-only" ]; then target="\$2"; else target="\$1"; fi
mkdir -p "\$target/graphify-out"
printf '{"nodes":[],"links":[]}' > "\$target/graphify-out/graph.json"
cat > "\$target/graphify-out/GRAPH_REPORT.md" <<'RPT'
$REPORT_FIXTURE
RPT
exit 0
STUB
chmod +x "$LOGBIN/graphify"
DCORPUS="$WS/dvault"; mkdir -p "$DCORPUS/notes"; printf '# n\ncontent\n' > "$DCORPUS/notes/a.md"
DMAPS="$WS/dmaps"; mkdir -p "$DMAPS"
out=$( GRAPHIFY_MAP_BIN="$LOGBIN/graphify" bash "$SCRIPT" --name dtest --corpus-root "$DCORPUS" \
  --maps-dir "$DMAPS" --title "D" --slug d-map --corpus-tag dtest 2>&1 ); rc=$?
[ "$rc" -eq 0 ] || fail "T1b default-backend run exit 0 (got $rc): $out"
# Assert the token IMMEDIATELY AFTER --backend is EXACTLY claude-cli (not the
# paid-API `claude`, not deepseek) — arg-boundary robust per the one-per-line log.
got_backend=$(awk 'prev=="--backend"{print; exit} {prev=$0}' "$BACKEND_LOG")
[ "$got_backend" = "claude-cli" ] && pass "T1b default backend is exactly claude-cli" || fail "T1b default backend not exactly claude-cli (got: '$got_backend')"
[ "$got_backend" != "deepseek" ] && pass "T1b default no longer deepseek" || fail "T1b default still uses deepseek"

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
out=$( bash "$SCRIPT" --name fresh --corpus-root "$FCORPUS" --backend claude-cli \
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
  bash "$SCRIPT" --name fail --corpus-root "$FCORPUS2" --backend claude-cli \
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
out=$( bash "$SCRIPT" --name fresh --corpus-root "$FCORPUS" --backend claude-cli \
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
printf '{"nodes":[],"links":[]}' > "\$target/graphify-out/graph.json"
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
  bash "$SCRIPT" --name emut --corpus-root "$ECORPUS" --backend claude-cli \
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
printf '{"nodes":[],"links":[]}' > "\$target/graphify-out/graph.json"
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
  bash "$SCRIPT" --name hpy --corpus-root "$PCORPUS" --backend claude-cli \
  --maps-dir "$PMAPS" --title "H Map" --slug h-map --corpus-tag h 2>&1 ); rc=$?
[ "$rc" -eq 2 ] && pass "T6f python3-less box exits 2" || fail "T6f python3-less box should exit 2 (got $rc): $out"
echo "$out" | grep -q "python3" && pass "T6f stderr mentions python3" || fail "T6f stderr should mention python3: $out"
grep -q "SENTINEL-PRE-PYTHON" "$PCORPUS/graphify-out/graph.json" 2>/dev/null \
  && pass "T6f sentinel graph.json unchanged (no promotion before python3 check)" \
  || fail "T6f sentinel graph.json clobbered (promoted before the python3 check)"

# --- T6g (HIMMEL-907 F2/F7): publish-failure semantics. A graphify stub that
# emits a VALID graph.json but a GARBAGE report BODY (unparseable by the
# curator) → the run exits NON-ZERO at the publish step, AND the freshness
# stamps ARE present: the graph itself is fresh (promote + stamp happen
# before publish), so only the MOC publish failed. Pins F2's invariant that
# stamps precede publish and survive a publish failure. The report's LINE 1
# is deliberately a valid `# Graph Report - ...` header (CR follow-up round
# 6, CodeRabbit App PR #1274): the sanitize step now has a default `*)` case
# that exits 2 on an unrecognized header shape, so a header-less garbage
# blob would now be rejected at sanitize instead of reaching promote+stamp
# -- this test's whole point is the LATER curator failure, so only the BODY
# stays garbage/unparseable. ---
GBIN="$WS/gbin"; mkdir -p "$GBIN"
cat > "$GBIN/graphify" <<STUB
#!/usr/bin/env bash
target=""
if [ "\$1" = "cluster-only" ]; then target="\$2"; else target="\$1"; fi
mkdir -p "\$target/graphify-out"
printf '{"nodes":[],"links":[]}' > "\$target/graphify-out/graph.json"
printf '# Graph Report - X\ntotally unparseable garbage body - no recognizable sections at all\n' > "\$target/graphify-out/GRAPH_REPORT.md"
exit 0
STUB
chmod +x "$GBIN/graphify"
GCORPUS="$WS/gcorpus"; GMAPS="$WS/gmaps"; mkdir -p "$GCORPUS/notes" "$GMAPS"
printf '# g\ncontent\n' > "$GCORPUS/notes/g.md"
out=$( GRAPHIFY_MAP_BIN="$GBIN/graphify" PATH="$GBIN:$PATH" \
  bash "$SCRIPT" --name gbg --corpus-root "$GCORPUS" --backend claude-cli \
  --maps-dir "$GMAPS" --title "G Map" --slug g-map --corpus-tag g 2>&1 ); rc=$?
[ "$rc" -ne 0 ] && pass "T6g garbage report → non-zero exit at publish" || fail "T6g garbage report should exit non-zero (got $rc): $out"
GOUT="$GCORPUS/graphify-out"
if [ -f "$GOUT/manifest.json" ] && [ -f "$GOUT/.graphify_root" ]; then
  pass "T6g freshness stamps present despite publish failure (graph is fresh)"
else
  fail "T6g freshness stamps missing after publish failure (F2 stamp-before-publish broke)"
fi

# --- T7 (HIMMEL-1070): the clean-tree probe must not be defeatable by config.
# `git status --porcelain` HONORS status.showUntrackedFiles, so on a repo (or a
# machine) configured with `showUntrackedFiles=no` a tree full of untracked work
# reported CLEAN and the refresh pulled straight over it. The probe now forces
# --untracked-files=normal on the command line, where no config can weaken it.
# Asserting on the PROBE's own decision ("not a clean git toplevel") keeps this
# pin independent of whether a bounded `timeout` binary exists on the host. ---
git_corpus() { # <dir> — a git repo with one commit, hermetic identity
  mkdir -p "$1"
  git -C "$1" init -q 2>/dev/null
  git -C "$1" config user.email t@t.invalid
  git -C "$1" config user.name  T
  git -C "$1" config commit.gpgsign false
  printf '# tracked\ncontent\n' > "$1/tracked.md"
  git -C "$1" add -A >/dev/null 2>&1
  git -C "$1" -c core.hooksPath=/dev/null commit -qm init >/dev/null 2>&1
}
# HIMMEL-2245: install a pre-commit hook into a fixture corpus, hook body on
# stdin. `git init` materializes `.git/hooks/` by COPYING the git template dir,
# and that copy is not guaranteed: observed absent on a concurrent Windows
# full-corpus run (HIMMEL-2231 evidence, 2026-08-29). A bare
# `cat > "$c/.git/hooks/pre-commit"` then fails with ENOENT — unchecked — and
# the hook is silently never installed, so T42a (asserts the hook RAN) and T42e
# (asserts a rejecting hook BLOCKED the commit) go red on the hook's absence
# with a message that blames refresh-graph-map.sh. Own the directory, and make
# a failed install a NAMED failure instead of a mystery red (HIMMEL-1128: never
# a vacuous pass, never an unexplained one).
install_pre_commit() { # <corpus-dir> — hook body on stdin
  local hook="$1/.git/hooks/pre-commit"
  mkdir -p "$1/.git/hooks" && cat > "$hook" && chmod +x "$hook" && [ -x "$hook" ] \
    || { fail "could not install pre-commit hook at $hook (fixture setup, not the code under test)"; return 1; }
}
UCORPUS="$WS/ucorpus"; UMAPS="$WS/umaps"; mkdir -p "$UMAPS"
git_corpus "$UCORPUS"
# THE REPRO: hide untracked files from `git status --porcelain`, then leave
# untracked work in the tree.
git -C "$UCORPUS" config status.showUntrackedFiles no
printf '# WIP\nuncommitted untracked work\n' > "$UCORPUS/wip.md"
out=$( bash "$SCRIPT" --name upd --corpus-root "$UCORPUS" --backend claude-cli \
  --maps-dir "$UMAPS" --title "U Map" --slug u-map --corpus-tag u 2>&1 ); rc=$?
[ "$rc" -eq 0 ] || fail "T7 run exit 0 (got $rc): $out"
echo "$out" | grep -q "not a clean git toplevel" \
  && pass "T7 untracked work seen despite showUntrackedFiles=no (pull skipped)" \
  || fail "T7 probe was fooled by showUntrackedFiles=no (would pull over untracked work): $out"
grep -q "uncommitted untracked work" "$UCORPUS/wip.md" 2>/dev/null \
  && pass "T7 untracked work survived" || fail "T7 untracked work lost"

# --- T7b: the inverse — a genuinely CLEAN git toplevel must still be judged
# pullable (the strict flags must not make every repo look dirty forever). ---
CCORPUS="$WS/ccorpus"; CMAPS="$WS/cmaps"; mkdir -p "$CMAPS"
git_corpus "$CCORPUS"
out=$( bash "$SCRIPT" --name cln --corpus-root "$CCORPUS" --backend claude-cli \
  --maps-dir "$CMAPS" --title "C Map" --slug c-map --corpus-tag c 2>&1 ); rc=$?
[ "$rc" -eq 0 ] || fail "T7b run exit 0 (got $rc): $out"
echo "$out" | grep -q "not a clean git toplevel" \
  && fail "T7b a clean repo was judged unpullable (probe over-tightened): $out" \
  || pass "T7b clean repo still judged pullable"

# --- T8 (HIMMEL-1070): the clean-tree verdict must not go STALE across the
# fetch. The probe ran before a bounded NETWORK op that can take the better part
# of a minute; this refresh is unattended, so an operator starting to edit during
# that window is routine. Merging on the stale verdict fast-forwards the worktree
# out from under live work. Re-probing before `merge --ff-only` fixes it.
# Harness: a fake `git` that forwards to the real one, DIRTIES the corpus during
# `fetch` (the exact race), and logs which subcommands were reached; a fake
# `timeout` so the bounded-fetch branch is taken on hosts without coreutils
# timeout. The assertion is that `merge` is never reached. ---
FAKEBIN="$WS/fakebin"; mkdir -p "$FAKEBIN"
GIT_LOG="$WS/git-calls.log"; : > "$GIT_LOG"
REAL_GIT="$(command -v git)"
DCORPUS_G="$WS/gitrace"; DMAPS_G="$WS/gitracemaps"; mkdir -p "$DMAPS_G"
git_corpus "$DCORPUS_G"
cat > "$FAKEBIN/git" <<STUB
#!/usr/bin/env bash
# Log the subcommand (first non-flag, non -C/-c value token) and forward.
sub=""; skip=0
for a in "\$@"; do
  if [ "\$skip" = 1 ]; then skip=0; continue; fi
  case "\$a" in
    -C|-c) skip=1 ;;
    -*)    : ;;
    *)     sub="\$a"; break ;;
  esac
done
printf '%s\n' "\$sub" >> "$GIT_LOG"
if [ "\$sub" = fetch ]; then
  # THE RACE: the operator starts editing while the fetch is in flight.
  printf '# racing\nwork started during the fetch\n' > "$DCORPUS_G/raced.md"
  exit 0   # a "successful" fetch, so the script proceeds to the merge decision
fi
exec "$REAL_GIT" "\$@"
STUB
chmod +x "$FAKEBIN/git"
# Minimal `timeout` stub: supports the script's `-k N N true` capability probe
# and otherwise drops `-k <n> <duration>` and execs the command.
cat > "$FAKEBIN/timeout" <<'STUB'
#!/usr/bin/env bash
[ "$1" = "-k" ] && shift 2
shift   # duration
exec "$@"
STUB
chmod +x "$FAKEBIN/timeout"
out=$( PATH="$FAKEBIN:$PATH" bash "$SCRIPT" --name race --corpus-root "$DCORPUS_G" \
  --backend claude-cli --maps-dir "$DMAPS_G" --title "R Map" --slug r-map --corpus-tag r 2>&1 ); rc=$?
[ "$rc" -eq 0 ] || fail "T8 run exit 0 (got $rc): $out"
grep -qx "fetch" "$GIT_LOG" 2>/dev/null \
  && pass "T8 harness reached the fetch (bounded branch taken)" \
  || fail "T8 harness never reached the fetch — the pin is vacuous: $(cat "$GIT_LOG")"
if grep -qx "merge" "$GIT_LOG" 2>/dev/null; then
  fail "T8 merged on a STALE clean-tree verdict (tree went dirty during the fetch)"
else
  pass "T8 re-probe caught the mid-fetch dirty tree (merge skipped)"
fi
grep -q "work started during the fetch" "$DCORPUS_G/raced.md" 2>/dev/null \
  && pass "T8 racing work survived" || fail "T8 racing work lost"

# --- T9 (HIMMEL-1070 codex-adv-1): the scheduled path must not egress to
# another cloud. graphify-fence.sh hard-denies the CLAUDE_CODE_USE_* reroute
# selectors, but it is a PreToolUse hook — it only sees what an AGENT types,
# never this script fired directly by cron/schtasks. So the fence's guarantee is
# worthless here unless THIS script clears them: an inherited
# CLAUDE_CODE_USE_BEDROCK would reroute the claude-cli backend to AWS with
# nothing in the path to stop it. A stub records the env it was dispatched with;
# every selector must be gone by then. ---
RCORPUS="$WS/rcorpus"; RMAPS="$WS/rmaps"; mkdir -p "$RCORPUS/notes" "$RMAPS"
printf '# r\ncontent\n' > "$RCORPUS/notes/r.md"
RBIN="$WS/rbin"; mkdir -p "$RBIN"
REROUTE_LOG="$WS/reroute-env.log"; : > "$REROUTE_LOG"
cat > "$RBIN/graphify" <<STUB
#!/usr/bin/env bash
# Record every reroute selector still visible at dispatch time.
for v in CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY \\
         CLAUDE_CODE_USE_GATEWAY CLAUDE_CODE_USE_MANTLE CLAUDE_CODE_USE_ANTHROPIC_AWS; do
  eval "val=\\\${\$v:-}"
  [ -n "\$val" ] && printf '%s=%s\n' "\$v" "\$val" >> "$REROUTE_LOG"
done
target=""
if [ "\$1" = "cluster-only" ]; then target="\$2"; else target="\$1"; fi
mkdir -p "\$target/graphify-out"
printf '{"nodes":[],"links":[]}' > "\$target/graphify-out/graph.json"
cat > "\$target/graphify-out/GRAPH_REPORT.md" <<'RPT'
$REPORT_FIXTURE
RPT
exit 0
STUB
chmod +x "$RBIN/graphify"
out=$( env CLAUDE_CODE_USE_BEDROCK=1 CLAUDE_CODE_USE_VERTEX=1 CLAUDE_CODE_USE_FOUNDRY=1 \
  CLAUDE_CODE_USE_GATEWAY=1 CLAUDE_CODE_USE_MANTLE=1 CLAUDE_CODE_USE_ANTHROPIC_AWS=1 \
  GRAPHIFY_MAP_BIN="$RBIN/graphify" PATH="$RBIN:$PATH" \
  bash "$SCRIPT" --name reroute --corpus-root "$RCORPUS" --backend claude-cli \
  --maps-dir "$RMAPS" --title "R2 Map" --slug r2-map --corpus-tag r2 2>&1 ); rc=$?
[ "$rc" -eq 0 ] || fail "T9 run exit 0 (got $rc): $out"
[ -s "$REROUTE_LOG" ] \
  && fail "T9 reroute selectors survived into the graphify dispatch (scheduled path can egress to another cloud): $(cat "$REROUTE_LOG")" \
  || pass "T9 reroute selectors cleared before the graphify dispatch"

# --- T10 (HIMMEL-1134): reproduce the real leak — graphify titles
# GRAPH_REPORT.md by the EXTRACTION PATH it was handed (here: the scratch dir
# the stub receives as its target arg), which is a PID-suffixed scratchpad
# dir = the operator's home dir + username. The stub below embeds that exact
# target arg into a synthetic Windows-drive-letter host path (forward-slash
# form, e.g. C:/Users/.../AppData/...), mirroring the verbatim bug report
# (`# Graph Report - C:\Users\<user>\AppData\Local\Temp\graphify-refresh-himmel-3093639  (2026-07-17)`)
# without hand-escaping backslashes through an unquoted heredoc (the guard's
# pattern covers both slash directions — see refresh-graph-map.sh). Assert
# the PROMOTED report's line 1 carries the corpus NAME ($NAME, here "himmel")
# and that no host-path shape survives anywhere in the promoted file. ---
LEAKBIN="$WS/leakbin"; mkdir -p "$LEAKBIN"
cat > "$LEAKBIN/graphify" <<STUB
#!/usr/bin/env bash
target=""
if [ "\$1" = "cluster-only" ]; then target="\$2"; else target="\$1"; fi
mkdir -p "\$target/graphify-out"
printf '{"nodes":[],"links":[]}' > "\$target/graphify-out/graph.json"
winpath="C:/Users/testop/AppData/Local/Temp/\$(basename "\$target")"
{
  printf '# Graph Report - %s  (2026-07-17)\n\n' "\$winpath"
  printf '## Summary\n- 42 nodes . 30 edges . 5 communities (5 shown)\n\n'
  printf '## God Nodes (most connected - your core abstractions)\n1. \`Core\` - 9 edges\n\n'
  printf '## Communities (5 total)\n\n### Community 0 - "Alpha"\nCohesion: 0.06\nNodes (20): a, b (+18 more)\n'
} > "\$target/graphify-out/GRAPH_REPORT.md"
exit 0
STUB
chmod +x "$LEAKBIN/graphify"
LEAKCORPUS="$WS/leakcorpus"; LEAKMAPS="$WS/leakmaps"; mkdir -p "$LEAKCORPUS/notes" "$LEAKMAPS"
printf '# n\ncontent\n' > "$LEAKCORPUS/notes/n.md"
out=$( GRAPHIFY_MAP_BIN="$LEAKBIN/graphify" PATH="$LEAKBIN:$PATH" \
  bash "$SCRIPT" --name himmel --corpus-root "$LEAKCORPUS" --backend claude-cli \
  --maps-dir "$LEAKMAPS" --title "Leak Map" --slug leak-map --corpus-tag leak 2>&1 ); rc=$?
[ "$rc" -eq 0 ] || fail "T10 leak-repro run exit 0 (got $rc): $out"
LEAKOUT="$LEAKCORPUS/graphify-out"
leak_line1="$(head -n 1 "$LEAKOUT/GRAPH_REPORT.md" 2>/dev/null)"
case "$leak_line1" in
  "# Graph Report - himmel"*) pass "T10 promoted header carries corpus NAME (himmel), not the scratch path" ;;
  *) fail "T10 promoted header does not carry corpus NAME (got: $leak_line1)" ;;
esac
grep -qiE '\\Users\\|/Users/|AppData' "$LEAKOUT/GRAPH_REPORT.md" 2>/dev/null \
  && fail "T10 promoted GRAPH_REPORT.md still contains a host-path shape" \
  || pass "T10 promoted GRAPH_REPORT.md contains no host-path shape"

# --- T11 (HIMMEL-1134): the guard is a real backstop, not vacuous. The
# sanitize above only rewrites LINE 1 — a leak on any OTHER line is a shape
# the sanitize genuinely cannot clean. Stub emits a clean line 1 (sanitize
# succeeds trivially) but plants a host path a few lines further down (as if
# an entity/path surfaced in the report body). Assert the refresh FAILS
# LOUDLY (non-zero exit) instead of promoting the leak, that stderr names
# the offending file, and (CR follow-up) that stderr does NOT itself leak the
# rejected host path -- the fixture's path contains the distinctive token
# "shouldnotleak"; the guard must report only the file + line NUMBER, never
# the matched line's content (a guard that prints the secret while refusing
# to promote it just relocates the leak from the artifact to stderr/CI
# logs). ---
GUARDBIN="$WS/guardbin"; mkdir -p "$GUARDBIN"
cat > "$GUARDBIN/graphify" <<STUB
#!/usr/bin/env bash
target=""
if [ "\$1" = "cluster-only" ]; then target="\$2"; else target="\$1"; fi
mkdir -p "\$target/graphify-out"
printf '{"nodes":[],"links":[]}' > "\$target/graphify-out/graph.json"
{
  printf '# Graph Report - X  (2026-07-17)\n\n'
  printf '## Summary\n- 42 nodes . 30 edges . 5 communities (5 shown)\n\n'
  printf '## God Nodes (most connected - your core abstractions)\n'
  printf '1. \`C:/Users/shouldnotleak/AppData/Local/Temp/case\` - 9 edges\n\n'
  printf '## Communities (5 total)\n\n### Community 0 - "Alpha"\nCohesion: 0.06\nNodes (20): a, b (+18 more)\n'
} > "\$target/graphify-out/GRAPH_REPORT.md"
exit 0
STUB
chmod +x "$GUARDBIN/graphify"
GUARDCORPUS="$WS/guardcorpus"; GUARDMAPS="$WS/guardmaps"; mkdir -p "$GUARDCORPUS/notes" "$GUARDMAPS"
printf '# n\ncontent\n' > "$GUARDCORPUS/notes/n.md"
out=$( GRAPHIFY_MAP_BIN="$GUARDBIN/graphify" PATH="$GUARDBIN:$PATH" \
  bash "$SCRIPT" --name guardtest --corpus-root "$GUARDCORPUS" --backend claude-cli \
  --maps-dir "$GUARDMAPS" --title "Guard Map" --slug guard-map --corpus-tag guard 2>&1 ); rc=$?
[ "$rc" -ne 0 ] && pass "T11 host-path-on-body-line refresh fails loudly (rc=$rc)" || fail "T11 leaking refresh should fail loudly (got rc=$rc): $out"
echo "$out" | grep -q "GRAPH_REPORT.md" \
  && pass "T11 error names the offending file" || fail "T11 error should name the offending file: $out"
echo "$out" | grep -q "shouldnotleak" \
  && fail "T11 error output exposes the rejected host path: $out" \
  || pass "T11 error output redacts the rejected host path"
GUARDOUT="$GUARDCORPUS/graphify-out"
if [ -e "$GUARDOUT/manifest.json" ] || [ -e "$GUARDOUT/.graphify_root" ]; then
  fail "T11 leaking refresh stamped freshness artifacts (must never stamp a refused promote as fresh)"
else
  pass "T11 leaking refresh stamped nothing (fails closed before the stamp step)"
fi

# --- T12 (HIMMEL-1134 CR follow-up, Part A): multi-match fail-open
# regression. The guard used to run `grep -inE ... | head -n 1` under
# `set -o pipefail` (line 30 of refresh-graph-map.sh) -- when `head` closes
# the pipe after its first line while `grep` still has thousands more
# matches queued to write, `grep` can be SIGPIPE'd (rc 141); under pipefail
# THAT non-zero pipeline rc wins even though a real match occurred, so the
# `if leak_line=... && [ -n "$leak_line" ]` short-circuited PAST the `exit 2`
# below it -- the guard failed OPEN on exactly the leaks with a second match
# past the closed pipe. A single match is NOT enough to reproduce this (the
# pipe buffer has to fill before `head` closes it) -- reproducing reliably on
# this host needed several thousand matching lines below line 1 (measured
# reliable at N=5000; smaller counts sometimes still raced clean). The fix
# (`grep -m1`, no pipe) never SIGPIPEs, so this must exit 2 either way. ---
MULTIBIN="$WS/multibin"; mkdir -p "$MULTIBIN"
cat > "$MULTIBIN/graphify" <<'STUB'
#!/usr/bin/env bash
target=""
if [ "$1" = "cluster-only" ]; then target="$2"; else target="$1"; fi
mkdir -p "$target/graphify-out"
printf '{"nodes":[],"links":[]}' > "$target/graphify-out/graph.json"
{
  printf '# Graph Report - X  (2026-07-17)\n'
  i=1
  while [ "$i" -le 5000 ]; do
    printf 'Node%d references C:/Users/leaker/AppData/Local/Temp/thing%d\n' "$i" "$i"
    i=$((i + 1))
  done
} > "$target/graphify-out/GRAPH_REPORT.md"
exit 0
STUB
chmod +x "$MULTIBIN/graphify"
MULTICORPUS="$WS/multicorpus"; MULTIMAPS="$WS/multimaps"; mkdir -p "$MULTICORPUS/notes" "$MULTIMAPS"
printf '# n\ncontent\n' > "$MULTICORPUS/notes/n.md"
out=$( GRAPHIFY_MAP_BIN="$MULTIBIN/graphify" PATH="$MULTIBIN:$PATH" \
  bash "$SCRIPT" --name multi --corpus-root "$MULTICORPUS" --backend claude-cli \
  --maps-dir "$MULTIMAPS" --title "Multi Map" --slug multi-map --corpus-tag multi 2>&1 ); rc=$?
[ "$rc" -eq 2 ] && pass "T12 multi-match leak (thousands of matches from line 2 on) still fails loudly (rc=2)" \
  || fail "T12 multi-match leak should fail loudly with rc=2 (got $rc) -- guard failed OPEN on SIGPIPE-under-pipefail: $out"

# --- T13 (HIMMEL-1134 CR follow-up, Part B): JSON-escaped graph.json leak.
# graph.json is JSON, so a Windows path embedded in it is serialized with
# each backslash DOUBLED (a real path C:\Users\name becomes the literal
# on-disk bytes C:\\Users\\name). Positive regression pin: the guard traps it
# in graph.json specifically (not just GRAPH_REPORT.md). NOTE (verified via a
# real old-vs-new A/B run, not just this in-suite assertion): this EXACT
# construction is caught even by the pre-Part-B pattern -- the bare `\Users\`
# alternative (present since the original HIMMEL-1134 cut) needs only ONE
# literal backslash on each side of "Users" as a substring match, and a run
# of 2 backslashes trivially contains 1, so it already matches the doubled
# form via its innermost backslash on each side. The JSON-escaped
# alternatives added in Part B are still worth keeping (explicit,
# defense-in-depth against a future edit that narrows/removes the bare
# alternative), but this test is NOT a red/green differentiator for Part B
# the way T12 is for Part A -- it stays green on both sides of that change.
# HIMMEL-1406: the leaked value now sits on `source_file` rather than the
# synthetic `path` key this fixture originally used -- the guard's graph.json
# scan is now scoped to STRUCTURAL fields only (id/source_file/source_url/
# source/target, per graphify's real schema), so a leak has to live on one of
# those field names to still be caught; `source_file` is real schema, `path`
# is not. ---
JSONBIN="$WS/jsonbin"; mkdir -p "$JSONBIN"
cat > "$JSONBIN/graphify" <<'STUB'
#!/usr/bin/env bash
target=""
if [ "$1" = "cluster-only" ]; then target="$2"; else target="$1"; fi
mkdir -p "$target/graphify-out"
printf '{"nodes":[{"id":"n1","source_file":"C:\\\\Users\\\\leaker\\\\AppData\\\\Local\\\\Temp\\\\case"}],"links":[]}' \
  > "$target/graphify-out/graph.json"
printf '# Graph Report - X  (2026-07-17)\n\n## Summary\n- 1 nodes . 0 edges . 1 communities (1 shown)\n' \
  > "$target/graphify-out/GRAPH_REPORT.md"
exit 0
STUB
chmod +x "$JSONBIN/graphify"
JSONCORPUS="$WS/jsoncorpus"; JSONMAPS="$WS/jsonmaps"; mkdir -p "$JSONCORPUS/notes" "$JSONMAPS"
printf '# n\ncontent\n' > "$JSONCORPUS/notes/n.md"
out=$( GRAPHIFY_MAP_BIN="$JSONBIN/graphify" PATH="$JSONBIN:$PATH" \
  bash "$SCRIPT" --name jsontest --corpus-root "$JSONCORPUS" --backend claude-cli \
  --maps-dir "$JSONMAPS" --title "Json Map" --slug json-map --corpus-tag jsontest 2>&1 ); rc=$?
[ "$rc" -eq 2 ] && pass "T13 JSON-escaped host path in graph.json fails loudly (rc=2)" \
  || fail "T13 JSON-escaped host path in graph.json should fail loudly with rc=2 (got $rc): $out"
echo "$out" | grep -q "graph.json" \
  && pass "T13 error names graph.json as the offending artifact" || fail "T13 error should name graph.json: $out"

# --- T14 (HIMMEL-1134 CR follow-up, Part 3): the bare `AppData` alternative
# used to match ANYWHERE, unbounded -- a legit node name or prose containing
# the word (no path delimiter immediately before/after it) would false-
# positive-refuse a perfectly clean refresh. The pattern now requires a path
# delimiter (start-of-string or / or \) on each side. Two halves: (a) a
# report whose ONLY "AppData" mentions are non-path (a node named
# MyAppDataStore, prose "AppData sync") must publish normally (rc 0); (b) a
# report with a delimited AppData path segment must still trip the guard
# (rc 2) -- the fix must not have collaterally weakened real-leak detection.
# T14b's leaked line is deliberately "workspace/AppData/Local/Temp/thing"
# (NOT a /Users/... path) -- CR-caught (HIMMEL-1134 follow-up round 3): an
# earlier draft's leaked line also contained /Users/, so it tripped the
# /Users/ alternative and never actually exercised the new
# (^|[/\\])AppData([/\\]|$) alternative this test is meant to pin. ---
FP_REPORT_FIXTURE='# Graph Report - X

## Summary
- 42 nodes . 30 edges . 5 communities (5 shown)

## God Nodes (most connected - your core abstractions)
1. `MyAppDataStore` - 9 edges

## Surprising Connections (you probably didn'"'"'t know these)
- `A` --references--> `B`  [INFERRED]
- Note: AppData sync integration keeps local caches warm

## Communities (5 total)

### Community 0 - "Alpha"
Cohesion: 0.06
Nodes (20): a, b (+18 more)
'
FPBIN="$WS/fpbin"; mkdir -p "$FPBIN"
cat > "$FPBIN/graphify" <<STUB
#!/usr/bin/env bash
target=""
if [ "\$1" = "cluster-only" ]; then target="\$2"; else target="\$1"; fi
mkdir -p "\$target/graphify-out"
printf '{"nodes":[],"links":[]}' > "\$target/graphify-out/graph.json"
cat > "\$target/graphify-out/GRAPH_REPORT.md" <<'RPT'
$FP_REPORT_FIXTURE
RPT
exit 0
STUB
chmod +x "$FPBIN/graphify"
FPCORPUS="$WS/fpcorpus"; FPMAPS="$WS/fpmaps"; mkdir -p "$FPCORPUS/notes" "$FPMAPS"
printf '# n\ncontent\n' > "$FPCORPUS/notes/n.md"
out=$( GRAPHIFY_MAP_BIN="$FPBIN/graphify" PATH="$FPBIN:$PATH" \
  bash "$SCRIPT" --name fptest --corpus-root "$FPCORPUS" --backend claude-cli \
  --maps-dir "$FPMAPS" --title "FP Map" --slug fp-map --corpus-tag fp 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && pass "T14a non-path AppData mention (node name / prose) does not false-positive the guard" \
  || fail "T14a legit AppData mention should NOT trip the guard (got rc=$rc): $out"
[ -f "$FPMAPS/fp-map.md" ] && pass "T14a MOC published despite the non-path AppData mention" \
  || fail "T14a MOC not published: $out"

TP_REPORT_FIXTURE='# Graph Report - X

## Summary
- 42 nodes . 30 edges . 5 communities (5 shown)

## God Nodes (most connected - your core abstractions)
1. `Core` - 9 edges

## Surprising Connections (you probably didn'"'"'t know these)
- Leaked path: workspace/AppData/Local/Temp/thing

## Communities (5 total)

### Community 0 - "Alpha"
Cohesion: 0.06
Nodes (20): a, b (+18 more)
'
TPBIN="$WS/tpbin"; mkdir -p "$TPBIN"
cat > "$TPBIN/graphify" <<STUB
#!/usr/bin/env bash
target=""
if [ "\$1" = "cluster-only" ]; then target="\$2"; else target="\$1"; fi
mkdir -p "\$target/graphify-out"
printf '{"nodes":[],"links":[]}' > "\$target/graphify-out/graph.json"
cat > "\$target/graphify-out/GRAPH_REPORT.md" <<'RPT'
$TP_REPORT_FIXTURE
RPT
exit 0
STUB
chmod +x "$TPBIN/graphify"
TPCORPUS="$WS/tpcorpus"; TPMAPS="$WS/tpmaps"; mkdir -p "$TPCORPUS/notes" "$TPMAPS"
printf '# n\ncontent\n' > "$TPCORPUS/notes/n.md"
out=$( GRAPHIFY_MAP_BIN="$TPBIN/graphify" PATH="$TPBIN:$PATH" \
  bash "$SCRIPT" --name tptest --corpus-root "$TPCORPUS" --backend claude-cli \
  --maps-dir "$TPMAPS" --title "TP Map" --slug tp-map --corpus-tag tp 2>&1 ); rc=$?
[ "$rc" -eq 2 ] && pass "T14b delimited AppData path (no /Users/ in the leak) still trips the guard (rc=2)" \
  || fail "T14b delimited AppData path leak should still trip the guard with rc=2 (got $rc): $out"

# --- T15 (HIMMEL-1134 CR follow-up round 3, Part 1): the leak scan itself
# must fail CLOSED on a grep SCAN ERROR (unreadable artifact, engine
# failure, ...), not just on rc 1 (no match). grep has THREE exit statuses:
# 0 = match, 1 = no match, >1 = scan error. `leak_line=$(grep ...) &&
# [ -n "$leak_line" ]` treated rc>1 the SAME as rc 1 (clean) -- a scan the
# guard couldn't even perform was silently read as "nothing found", so a
# real leak in an artifact grep failed to scan would still ship. Simulate a
# scan error by shadowing `grep` with a stub that fails ONLY the guard's
# exact invocation shape (`-m1 -inE ...`) and forwards every other call
# (e.g. the header-sanitize's `grep -oE` date extraction) to the real grep.
# The corpus's report is otherwise perfectly CLEAN (no leak at all) -- this
# pins the SCAN-FAILURE path specifically, distinct from the leak-found
# path already covered by T10-T14. RED against the pre-fix code: without an
# explicit captured rc, grep's rc-2 (scan error) short-circuited the `&&`
# exactly like a real rc-1 miss, and the run continued to a clean rc 0. ---
REALGREP="$(command -v grep)"
SCANFAILBIN="$WS/scanfailbin"; mkdir -p "$SCANFAILBIN"
cat > "$SCANFAILBIN/grep" <<STUB
#!/usr/bin/env bash
# Matches the guard's exact invocation shape (CR follow-up round 6 added
# -a/--binary-files=text as the first flag: "-a -m1 -inE ...").
case "\$*" in
  "-a -m1 -inE "*) exit 2 ;;
esac
exec "$REALGREP" "\$@"
STUB
chmod +x "$SCANFAILBIN/grep"
SCANBIN="$WS/scanbin"; mkdir -p "$SCANBIN"
cat > "$SCANBIN/graphify" <<STUB
#!/usr/bin/env bash
target=""
if [ "\$1" = "cluster-only" ]; then target="\$2"; else target="\$1"; fi
mkdir -p "\$target/graphify-out"
printf '{"nodes":[],"links":[]}' > "\$target/graphify-out/graph.json"
cat > "\$target/graphify-out/GRAPH_REPORT.md" <<'RPT'
$REPORT_FIXTURE
RPT
exit 0
STUB
chmod +x "$SCANBIN/graphify"
SCANCORPUS="$WS/scancorpus"; SCANMAPS="$WS/scanmaps"; mkdir -p "$SCANCORPUS/notes" "$SCANMAPS"
printf '# n\ncontent\n' > "$SCANCORPUS/notes/n.md"
out=$( GRAPHIFY_MAP_BIN="$SCANBIN/graphify" PATH="$SCANFAILBIN:$PATH" \
  bash "$SCRIPT" --name scanfail --corpus-root "$SCANCORPUS" --backend claude-cli \
  --maps-dir "$SCANMAPS" --title "Scan Map" --slug scan-map --corpus-tag scan 2>&1 ); rc=$?
[ "$rc" -eq 2 ] && pass "T15 grep scan error fails CLOSED (rc=2), not silently clean" \
  || fail "T15 a grep scan error should fail closed with rc=2 (got $rc) -- guard failed OPEN on scan error: $out"
echo "$out" | grep -q "SCAN FAILED" \
  && pass "T15 error names the scan failure explicitly" || fail "T15 error should mention SCAN FAILED: $out"

# --- T16 (HIMMEL-1134 CR follow-up round 4): the header-sanitize's
# `awk ... > "$REPORT.tmp" && mv "$REPORT.tmp" "$REPORT"` put awk on the
# LEFT of `&&` -- under `set -euo pipefail` that side is EXEMPT from set -e,
# so an awk failure there short-circuited past the mv and fell through
# SILENTLY: execution continued with the un-sanitized (leaked-header)
# $REPORT still in place and a stale $REPORT.tmp left behind in the tracked
# out dir. Shadow `awk` (this script has exactly ONE awk call -- the
# sanitize step -- so blanket-shadowing it is safe and unambiguous) with a
# stub that always fails, and assert the refresh fails LOUDLY (rc 2, the
# same fence/tooling-failure convention as the guard) with no
# GRAPH_REPORT.md.tmp left behind. RED against the pre-fix code (verified via
# a real old-vs-new A/B run, not just this in-suite assertion): the old
# `awk ... && mv` swallowed the awk failure with NO error message and let
# the run continue to a clean rc 0 -- with the fixture's placeholder header
# (`# Graph Report - X`, no real host-path shape) the guard never even
# catches it as a fallback, so the awk failure is not just silent, it is
# fully invisible; a stale GRAPH_REPORT.md.tmp is left in the tracked out
# dir either way. ---
AWKFAILBIN="$WS/awkfailbin"; mkdir -p "$AWKFAILBIN"
cat > "$AWKFAILBIN/awk" <<'STUB'
#!/usr/bin/env bash
echo "simulated awk failure" >&2
exit 1
STUB
chmod +x "$AWKFAILBIN/awk"
AWKBIN="$WS/awkbin"; mkdir -p "$AWKBIN"
cat > "$AWKBIN/graphify" <<STUB
#!/usr/bin/env bash
target=""
if [ "\$1" = "cluster-only" ]; then target="\$2"; else target="\$1"; fi
mkdir -p "\$target/graphify-out"
printf '{"nodes":[],"links":[]}' > "\$target/graphify-out/graph.json"
cat > "\$target/graphify-out/GRAPH_REPORT.md" <<'RPT'
$REPORT_FIXTURE
RPT
exit 0
STUB
chmod +x "$AWKBIN/graphify"
AWKCORPUS="$WS/awkcorpus"; AWKMAPS="$WS/awkmaps"; mkdir -p "$AWKCORPUS/notes" "$AWKMAPS"
printf '# n\ncontent\n' > "$AWKCORPUS/notes/n.md"
out=$( GRAPHIFY_MAP_BIN="$AWKBIN/graphify" PATH="$AWKFAILBIN:$PATH" \
  bash "$SCRIPT" --name awkfail --corpus-root "$AWKCORPUS" --backend claude-cli \
  --maps-dir "$AWKMAPS" --title "Awk Map" --slug awk-map --corpus-tag awk 2>&1 ); rc=$?
[ "$rc" -eq 2 ] && pass "T16 awk sanitize failure fails loudly (rc=2), not silently" \
  || fail "T16 an awk failure during sanitize should fail loudly with rc=2 (got $rc): $out"
echo "$out" | grep -q "sanitize report header" \
  && pass "T16 error names the sanitize failure explicitly" || fail "T16 error should mention the sanitize failure: $out"
[ -e "$AWKCORPUS/graphify-out/GRAPH_REPORT.md.tmp" ] \
  && fail "T16 stale GRAPH_REPORT.md.tmp left behind after awk failure" \
  || pass "T16 no stale GRAPH_REPORT.md.tmp left behind"

# --- T17 (HIMMEL-1134 CR follow-up round 5): a REJECTED (leaking) refresh
# must leave the corpus's PRIOR clean graphify-out/ completely untouched --
# no leaked bytes written, no stamp invalidation, no stray tmp files.
# Previously the promote block invalidated manifest.json/.graphify_root and
# cp'd the new (unsanitized) graph.json/GRAPH_REPORT.md into the TRACKED
# $OUT_DIR BEFORE sanitizing + guard-scanning those PROMOTED copies -- so a
# rejected refresh had already destroyed the prior stamps and written
# leaked bytes into graphify-out/ before the guard's exit 2 ever ran
# (fail-closed on PUBLISH, but not on the out-dir WRITE -- a later
# `git add -A` could still commit the leaked bytes). Sanitize + guard now
# run on the SCRATCH staging copies, before $OUT_DIR is touched at all.
# Seed the corpus with PRIOR clean artifacts + a valid manifest/marker
# (distinct sentinel content in each), run a refresh whose fresh extraction
# leaks a host path, and assert every prior artifact is byte-identical
# afterward. ---
PRIORCORPUS="$WS/priorcorpus"; PRIORMAPS="$WS/priormaps"
mkdir -p "$PRIORCORPUS/notes" "$PRIORMAPS" "$PRIORCORPUS/graphify-out"
printf '# n\ncontent\n' > "$PRIORCORPUS/notes/n.md"
printf 'PRIOR-GOOD-GRAPH-JSON' > "$PRIORCORPUS/graphify-out/graph.json"
printf 'PRIOR-GOOD-REPORT' > "$PRIORCORPUS/graphify-out/GRAPH_REPORT.md"
printf 'PRIOR-GOOD-MANIFEST' > "$PRIORCORPUS/graphify-out/manifest.json"
printf 'PRIOR-GOOD-ROOT' > "$PRIORCORPUS/graphify-out/.graphify_root"
# CR follow-up round 6 (CodeRabbit App PR #1274): snapshot the four prior
# artifacts to a SIDE dir and compare with `cmp`, not `[ "$(cat a)" =
# "$(cat b)" ]` -- command substitution strips trailing newlines and can't
# hold embedded NULs, so the old form could miss a mutation that only
# changed trailing whitespace or binary content. `cmp` compares raw bytes.
PRIOR_SNAPSHOT="$WS/prior-snapshot"; mkdir -p "$PRIOR_SNAPSHOT"
cp "$PRIORCORPUS/graphify-out/graph.json" "$PRIOR_SNAPSHOT/graph.json"
cp "$PRIORCORPUS/graphify-out/GRAPH_REPORT.md" "$PRIOR_SNAPSHOT/GRAPH_REPORT.md"
cp "$PRIORCORPUS/graphify-out/manifest.json" "$PRIOR_SNAPSHOT/manifest.json"
cp "$PRIORCORPUS/graphify-out/.graphify_root" "$PRIOR_SNAPSHOT/.graphify_root"
PRIORBIN="$WS/priorbin"; mkdir -p "$PRIORBIN"
cat > "$PRIORBIN/graphify" <<STUB
#!/usr/bin/env bash
target=""
if [ "\$1" = "cluster-only" ]; then target="\$2"; else target="\$1"; fi
mkdir -p "\$target/graphify-out"
printf '{"nodes":[],"links":[]}' > "\$target/graphify-out/graph.json"
{
  printf '# Graph Report - X  (2026-07-17)\n\n'
  printf '## Summary\n- 42 nodes . 30 edges . 5 communities (5 shown)\n\n'
  printf '## God Nodes (most connected - your core abstractions)\n'
  printf '1. \`C:/Users/priorleak/AppData/Local/Temp/case\` - 9 edges\n\n'
  printf '## Communities (5 total)\n\n### Community 0 - "Alpha"\nCohesion: 0.06\nNodes (20): a, b (+18 more)\n'
} > "\$target/graphify-out/GRAPH_REPORT.md"
exit 0
STUB
chmod +x "$PRIORBIN/graphify"
out=$( GRAPHIFY_MAP_BIN="$PRIORBIN/graphify" PATH="$PRIORBIN:$PATH" \
  bash "$SCRIPT" --name priortest --corpus-root "$PRIORCORPUS" --backend claude-cli \
  --maps-dir "$PRIORMAPS" --title "Prior Map" --slug prior-map --corpus-tag prior 2>&1 ); rc=$?
[ "$rc" -eq 2 ] && pass "T17 leaking refresh over a seeded corpus still fails loudly (rc=2)" \
  || fail "T17 leaking refresh should fail loudly with rc=2 (got $rc): $out"
cmp -s "$PRIOR_SNAPSHOT/graph.json" "$PRIORCORPUS/graphify-out/graph.json" \
  && pass "T17 prior graph.json byte-identical after rejection" \
  || fail "T17 prior graph.json was mutated by a rejected refresh"
cmp -s "$PRIOR_SNAPSHOT/GRAPH_REPORT.md" "$PRIORCORPUS/graphify-out/GRAPH_REPORT.md" \
  && pass "T17 prior GRAPH_REPORT.md byte-identical after rejection" \
  || fail "T17 prior GRAPH_REPORT.md was mutated by a rejected refresh"
cmp -s "$PRIOR_SNAPSHOT/manifest.json" "$PRIORCORPUS/graphify-out/manifest.json" \
  && pass "T17 prior manifest.json byte-identical (stamps NOT invalidated) after rejection" \
  || fail "T17 prior manifest.json was invalidated/mutated by a rejected refresh"
cmp -s "$PRIOR_SNAPSHOT/.graphify_root" "$PRIORCORPUS/graphify-out/.graphify_root" \
  && pass "T17 prior .graphify_root byte-identical after rejection" \
  || fail "T17 prior .graphify_root was invalidated/mutated by a rejected refresh"
[ -e "$PRIORCORPUS/graphify-out/.manifest.tmp" ] \
  && fail "T17 stray .manifest.tmp left behind after rejection" \
  || pass "T17 no stray .manifest.tmp left behind after rejection"

# --- T18 (HIMMEL-1134 CR follow-up round 6, CodeRabbit App PR #1274): a
# missing staging artifact must fail CLOSED, not fall through. A stub that
# emits GRAPH_REPORT.md but omits graph.json entirely (a partial/crashed
# extraction that still exits 0) used to sail past every check: sanitize
# only reads the report, the guard's `[ -f ] || continue` skipped the
# missing graph.json rather than refusing, and nothing upstream noticed --
# letting a half-produced staging area reach $OUT_DIR mutation. Assert the
# refresh now fails loudly BEFORE that, naming the missing artifact --
# AND (CR follow-up round 7, CodeRabbit App re-review) seed the corpus's
# $OUT_DIR with PRIOR clean artifacts + stamps first, snapshot them, and
# `cmp` each against its snapshot afterward -- proving the rejection didn't
# just exit 2 but genuinely left $OUT_DIR untouched (the same proof T17
# applies to a leak rejection, applied here to a missing-artifact
# rejection). ---
MISSBIN="$WS/missbin"; mkdir -p "$MISSBIN"
cat > "$MISSBIN/graphify" <<'STUB'
#!/usr/bin/env bash
target=""
if [ "$1" = "cluster-only" ]; then target="$2"; else target="$1"; fi
mkdir -p "$target/graphify-out"
# The runner now seeds prior graphify-out before --update (HIMMEL-1097), so
# remove the seeded graph and deliberately OMIT its replacement to simulate a
# partial extraction whose final staging area genuinely lacks graph.json.
rm -f "$target/graphify-out/graph.json"
printf '# Graph Report - X\n' > "$target/graphify-out/GRAPH_REPORT.md"
exit 0
STUB
chmod +x "$MISSBIN/graphify"
MISSCORPUS="$WS/misscorpus"; MISSMAPS="$WS/missmaps"
mkdir -p "$MISSCORPUS/notes" "$MISSMAPS" "$MISSCORPUS/graphify-out"
printf '# n\ncontent\n' > "$MISSCORPUS/notes/n.md"
printf 'PRIOR-GOOD-GRAPH-JSON' > "$MISSCORPUS/graphify-out/graph.json"
printf 'PRIOR-GOOD-REPORT' > "$MISSCORPUS/graphify-out/GRAPH_REPORT.md"
printf 'PRIOR-GOOD-MANIFEST' > "$MISSCORPUS/graphify-out/manifest.json"
printf 'PRIOR-GOOD-ROOT' > "$MISSCORPUS/graphify-out/.graphify_root"
MISS_SNAPSHOT="$WS/miss-snapshot"; mkdir -p "$MISS_SNAPSHOT"
cp "$MISSCORPUS/graphify-out/graph.json" "$MISS_SNAPSHOT/graph.json"
cp "$MISSCORPUS/graphify-out/GRAPH_REPORT.md" "$MISS_SNAPSHOT/GRAPH_REPORT.md"
cp "$MISSCORPUS/graphify-out/manifest.json" "$MISS_SNAPSHOT/manifest.json"
cp "$MISSCORPUS/graphify-out/.graphify_root" "$MISS_SNAPSHOT/.graphify_root"
out=$( GRAPHIFY_MAP_BIN="$MISSBIN/graphify" PATH="$MISSBIN:$PATH" \
  bash "$SCRIPT" --name misstest --corpus-root "$MISSCORPUS" --backend claude-cli \
  --maps-dir "$MISSMAPS" --title "Miss Map" --slug miss-map --corpus-tag miss 2>&1 ); rc=$?
[ "$rc" -eq 2 ] && pass "T18 missing scratch graph.json fails loudly (rc=2)" \
  || fail "T18 missing scratch graph.json should fail loudly with rc=2 (got $rc): $out"
echo "$out" | grep -q "missing required scratch artifact" \
  && pass "T18 error names the missing-artifact failure" || fail "T18 error should mention missing required scratch artifact: $out"
echo "$out" | grep -q "graph.json" \
  && pass "T18 error names graph.json as the missing artifact" || fail "T18 error should name graph.json: $out"
cmp -s "$MISS_SNAPSHOT/graph.json" "$MISSCORPUS/graphify-out/graph.json" \
  && pass "T18 prior graph.json byte-identical after rejection" \
  || fail "T18 prior graph.json was mutated by a rejected refresh"
cmp -s "$MISS_SNAPSHOT/GRAPH_REPORT.md" "$MISSCORPUS/graphify-out/GRAPH_REPORT.md" \
  && pass "T18 prior GRAPH_REPORT.md byte-identical after rejection" \
  || fail "T18 prior GRAPH_REPORT.md was mutated by a rejected refresh"
cmp -s "$MISS_SNAPSHOT/manifest.json" "$MISSCORPUS/graphify-out/manifest.json" \
  && pass "T18 prior manifest.json byte-identical (stamps NOT invalidated) after rejection" \
  || fail "T18 prior manifest.json was invalidated/mutated by a rejected refresh"
cmp -s "$MISS_SNAPSHOT/.graphify_root" "$MISSCORPUS/graphify-out/.graphify_root" \
  && pass "T18 prior .graphify_root byte-identical after rejection" \
  || fail "T18 prior .graphify_root was invalidated/mutated by a rejected refresh"

# --- T19 (HIMMEL-1134 CR follow-up round 6, CodeRabbit App PR #1274): an
# unrecognized header format must fail CLOSED, not silently skip the
# sanitize. The `case "$report_line1"` previously had no default branch --
# a report whose line 1 doesn't start with `# Graph Report - ` (a shape
# graphify never actually emits, but nothing upstream GUARANTEES it) just
# fell through with the header untouched. Assert the refresh now fails
# loudly instead, naming the unexpected-format failure -- AND (CR follow-up
# round 7, CodeRabbit App re-review) seed + snapshot + `cmp` the corpus's
# prior $OUT_DIR artifacts, same as T18/T17, proving this rejection path
# also leaves $OUT_DIR untouched. ---
BADHDRBIN="$WS/badhdrbin"; mkdir -p "$BADHDRBIN"
cat > "$BADHDRBIN/graphify" <<'STUB'
#!/usr/bin/env bash
target=""
if [ "$1" = "cluster-only" ]; then target="$2"; else target="$1"; fi
mkdir -p "$target/graphify-out"
printf '{"nodes":[],"links":[]}' > "$target/graphify-out/graph.json"
printf 'Totally Different Header Format\nnot a graphify report at all\n' > "$target/graphify-out/GRAPH_REPORT.md"
exit 0
STUB
chmod +x "$BADHDRBIN/graphify"
BADHDRCORPUS="$WS/badhdrcorpus"; BADHDRMAPS="$WS/badhdrmaps"
mkdir -p "$BADHDRCORPUS/notes" "$BADHDRMAPS" "$BADHDRCORPUS/graphify-out"
printf '# n\ncontent\n' > "$BADHDRCORPUS/notes/n.md"
printf 'PRIOR-GOOD-GRAPH-JSON' > "$BADHDRCORPUS/graphify-out/graph.json"
printf 'PRIOR-GOOD-REPORT' > "$BADHDRCORPUS/graphify-out/GRAPH_REPORT.md"
printf 'PRIOR-GOOD-MANIFEST' > "$BADHDRCORPUS/graphify-out/manifest.json"
printf 'PRIOR-GOOD-ROOT' > "$BADHDRCORPUS/graphify-out/.graphify_root"
BADHDR_SNAPSHOT="$WS/badhdr-snapshot"; mkdir -p "$BADHDR_SNAPSHOT"
cp "$BADHDRCORPUS/graphify-out/graph.json" "$BADHDR_SNAPSHOT/graph.json"
cp "$BADHDRCORPUS/graphify-out/GRAPH_REPORT.md" "$BADHDR_SNAPSHOT/GRAPH_REPORT.md"
cp "$BADHDRCORPUS/graphify-out/manifest.json" "$BADHDR_SNAPSHOT/manifest.json"
cp "$BADHDRCORPUS/graphify-out/.graphify_root" "$BADHDR_SNAPSHOT/.graphify_root"
out=$( GRAPHIFY_MAP_BIN="$BADHDRBIN/graphify" PATH="$BADHDRBIN:$PATH" \
  bash "$SCRIPT" --name badhdrtest --corpus-root "$BADHDRCORPUS" --backend claude-cli \
  --maps-dir "$BADHDRMAPS" --title "BadHdr Map" --slug badhdr-map --corpus-tag badhdr 2>&1 ); rc=$?
[ "$rc" -eq 2 ] && pass "T19 unexpected header format fails loudly (rc=2)" \
  || fail "T19 unexpected header format should fail loudly with rc=2 (got $rc): $out"
echo "$out" | grep -q "unexpected format" \
  && pass "T19 error names the unexpected-format failure" || fail "T19 error should mention unexpected format: $out"
cmp -s "$BADHDR_SNAPSHOT/graph.json" "$BADHDRCORPUS/graphify-out/graph.json" \
  && pass "T19 prior graph.json byte-identical after rejection" \
  || fail "T19 prior graph.json was mutated by a rejected refresh"
cmp -s "$BADHDR_SNAPSHOT/GRAPH_REPORT.md" "$BADHDRCORPUS/graphify-out/GRAPH_REPORT.md" \
  && pass "T19 prior GRAPH_REPORT.md byte-identical after rejection" \
  || fail "T19 prior GRAPH_REPORT.md was mutated by a rejected refresh"
cmp -s "$BADHDR_SNAPSHOT/manifest.json" "$BADHDRCORPUS/graphify-out/manifest.json" \
  && pass "T19 prior manifest.json byte-identical (stamps NOT invalidated) after rejection" \
  || fail "T19 prior manifest.json was invalidated/mutated by a rejected refresh"
cmp -s "$BADHDR_SNAPSHOT/.graphify_root" "$BADHDRCORPUS/graphify-out/.graphify_root" \
  && pass "T19 prior .graphify_root byte-identical after rejection" \
  || fail "T19 prior .graphify_root was invalidated/mutated by a rejected refresh"

# --- T20 (HIMMEL-1134 CR follow-up round 6, CodeRabbit App PR #1274): a NUL
# byte in the report must not defeat the guard. GNU grep switches to
# "Binary file X matches" mode on a NUL byte -- that mode's output has NO
# "N:content" line-number prefix, so `${leak_line%%:*}` (which normally
# strips grep's own "N:" prefix) instead captures the ENTIRE "Binary file
# <path> matches" string as the "line number" -- both a nonsense line number
# AND (worse) a re-leak of the scanned artifact's absolute path through the
# guard's own error message, defeating the redaction work from an earlier
# round. `-a` forces text mode so a NUL is just another byte and the normal
# "N:content" line format holds. Verified (direct grep repro) that WITHOUT
# -a the match is still FOUND (rc 0 either way -- binary mode preserves the
# match/no-match exit code), so this pins the MESSAGE quality, not the bare
# exit code: RED against the pre-fix grep invocation is "the message leaks
# 'Binary file ... matches'", not "the guard misses the leak". ---
NULBIN="$WS/nulbin"; mkdir -p "$NULBIN"
cat > "$NULBIN/graphify" <<'STUB'
#!/usr/bin/env bash
target=""
if [ "$1" = "cluster-only" ]; then target="$2"; else target="$1"; fi
mkdir -p "$target/graphify-out"
printf '{"nodes":[],"links":[]}' > "$target/graphify-out/graph.json"
{
  printf '# Graph Report - X\n\nsome text'
  printf '\0'
  printf 'more text with C:/Users/nulleak/AppData/Local/Temp/x\n'
} > "$target/graphify-out/GRAPH_REPORT.md"
exit 0
STUB
chmod +x "$NULBIN/graphify"
NULCORPUS="$WS/nulcorpus"; NULMAPS="$WS/nulmaps"; mkdir -p "$NULCORPUS/notes" "$NULMAPS"
printf '# n\ncontent\n' > "$NULCORPUS/notes/n.md"
out=$( GRAPHIFY_MAP_BIN="$NULBIN/graphify" PATH="$NULBIN:$PATH" \
  bash "$SCRIPT" --name nultest --corpus-root "$NULCORPUS" --backend claude-cli \
  --maps-dir "$NULMAPS" --title "Nul Map" --slug nul-map --corpus-tag nul 2>&1 ); rc=$?
[ "$rc" -eq 2 ] && pass "T20 NUL-byte report still trips the guard (rc=2)" \
  || fail "T20 NUL-byte report should still trip the guard with rc=2 (got $rc): $out"
echo "$out" | grep -q "Binary file" \
  && fail "T20 guard message leaked 'Binary file <path> matches' (grep fell into binary mode)" \
  || pass "T20 guard stayed in text mode (-a) -- no 'Binary file' leak in the message"
# CR follow-up round 7 (CodeRabbit App re-review): the "no 'Binary file'"
# check above only proves grep stayed in text mode -- it doesn't directly
# prove the LEAKED host path itself was redacted from the message (mirrors
# the T11 "shouldnotleak" token check). The fixture's distinctive token is
# "nulleak" (from the planted path C:/Users/nulleak/AppData/Local/Temp/x).
echo "$out" | grep -q "nulleak" \
  && fail "T20 error output exposes the rejected host path: $out" \
  || pass "T20 error output redacts the rejected host path"

# --- T21: GRAPHIFY_MAX_CONCURRENCY knob (HIMMEL-1097 throttle) ---
# Invalid values fail LOUD (rc=1) before any extraction, rather than silently
# reverting to a concurrency that 429s the rate-limited backend.
# GRAPHIFY_CALL_LOG lets the stub record every graphify invocation, so these
# tests can assert an invalid value fails BEFORE any extraction call (empty log),
# and a valid value wires --max-concurrency into both graphify subcommands.
t21log="$WS/t21-calls.log"; : > "$t21log"
out=$( GRAPHIFY_CALL_LOG="$t21log" GRAPHIFY_MAX_CONCURRENCY=abc bash "$SCRIPT" --name luna --corpus-root "$CORPUS" --backend claude-cli \
  --maps-dir "$MAPS" --title "T" --slug graphify-luna-map --corpus-tag luna 2>&1 ); rc=$?
[ "$rc" -eq 1 ] && pass "T21a non-numeric GRAPHIFY_MAX_CONCURRENCY rejected (rc=1)" \
  || fail "T21a non-numeric GRAPHIFY_MAX_CONCURRENCY should fail rc=1 (got $rc): $out"
echo "$out" | grep -q "GRAPHIFY_MAX_CONCURRENCY must be a positive integer" \
  && pass "T21a error names the invalid knob" \
  || fail "T21a error should name GRAPHIFY_MAX_CONCURRENCY: $out"
[ ! -s "$t21log" ] && pass "T21a invalid value fails before any extraction call" \
  || fail "T21a extraction ran on an invalid value: $(cat "$t21log")"
# Assert rc=1 AND the concurrency-validation message (not just any rc=1), so an
# unrelated early failure cannot pass these. Zero and empty hit different
# branches ("must be >= 1" vs "must be a positive integer") — assert the common
# `GRAPHIFY_MAX_CONCURRENCY must be` prefix both emit.
: > "$t21log"
out=$( GRAPHIFY_CALL_LOG="$t21log" GRAPHIFY_MAX_CONCURRENCY=0 bash "$SCRIPT" --name luna --corpus-root "$CORPUS" --backend claude-cli \
  --maps-dir "$MAPS" --title "T" --slug graphify-luna-map --corpus-tag luna 2>&1 ); rc=$?
{ [ "$rc" -eq 1 ] && echo "$out" | grep -q "GRAPHIFY_MAX_CONCURRENCY must be"; } \
  && pass "T21b zero GRAPHIFY_MAX_CONCURRENCY rejected (rc=1 + validation msg)" \
  || fail "T21b zero GRAPHIFY_MAX_CONCURRENCY should fail rc=1 with the validation msg (got $rc): $out"
[ ! -s "$t21log" ] && pass "T21b zero value fails before any extraction call" \
  || fail "T21b extraction ran on a zero value: $(cat "$t21log")"
# Explicitly-empty value fails loud too (unset-only `-6` default preserves it
# for the validation instead of silently defaulting to 6).
: > "$t21log"
out=$( GRAPHIFY_CALL_LOG="$t21log" GRAPHIFY_MAX_CONCURRENCY='' bash "$SCRIPT" --name luna --corpus-root "$CORPUS" --backend claude-cli \
  --maps-dir "$MAPS" --title "T" --slug graphify-luna-map --corpus-tag luna 2>&1 ); rc=$?
{ [ "$rc" -eq 1 ] && echo "$out" | grep -q "GRAPHIFY_MAX_CONCURRENCY must be"; } \
  && pass "T21b2 explicitly-empty GRAPHIFY_MAX_CONCURRENCY rejected (rc=1 + validation msg)" \
  || fail "T21b2 empty GRAPHIFY_MAX_CONCURRENCY should fail rc=1 with the validation msg (got $rc): $out"
[ ! -s "$t21log" ] && pass "T21b2 empty value fails before any extraction call" \
  || fail "T21b2 extraction ran on an empty value: $(cat "$t21log")"
# Negative value: the leading '-' is a non-digit, so it hits the same
# positive-integer branch as T21a and fails before extraction.
: > "$t21log"
out=$( GRAPHIFY_CALL_LOG="$t21log" GRAPHIFY_MAX_CONCURRENCY=-1 bash "$SCRIPT" --name luna --corpus-root "$CORPUS" --backend claude-cli \
  --maps-dir "$MAPS" --title "T" --slug graphify-luna-map --corpus-tag luna 2>&1 ); rc=$?
{ [ "$rc" -eq 1 ] && echo "$out" | grep -q "GRAPHIFY_MAX_CONCURRENCY must be"; } \
  && pass "T21b3 negative GRAPHIFY_MAX_CONCURRENCY rejected (rc=1 + validation msg)" \
  || fail "T21b3 negative GRAPHIFY_MAX_CONCURRENCY should fail rc=1 with the validation msg (got $rc): $out"
[ ! -s "$t21log" ] && pass "T21b3 negative value fails before any extraction call" \
  || fail "T21b3 extraction ran on a negative value: $(cat "$t21log")"
# A valid non-default value still drives the full path to a published MOC AND
# reaches BOTH graphify subcommands as --max-concurrency (the wiring this change
# adds — verified via the stub call-log, since GRAPHIFY_MAP_BIN is a stub).
T21MAPS="$WS/t21maps"; mkdir -p "$T21MAPS"; : > "$t21log"
out=$( GRAPHIFY_CALL_LOG="$t21log" GRAPHIFY_MAX_CONCURRENCY=3 bash "$SCRIPT" --name luna --corpus-root "$CORPUS" --backend claude-cli \
  --maps-dir "$T21MAPS" --title "T" --slug graphify-luna-map --corpus-tag luna 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && [ -f "$T21MAPS/graphify-luna-map.md" ] \
  && pass "T21c valid non-default GRAPHIFY_MAX_CONCURRENCY still publishes (rc=0)" \
  || fail "T21c valid GRAPHIFY_MAX_CONCURRENCY=3 should publish (rc=$rc): $out"
# Require TWO distinct call records — one --update, one cluster-only — each with
# --max-concurrency 3, and reject any single record combining both (guards against
# a future stub logging both phases on one line masking a half-wired change).
awk '
  /--update/ && /cluster-only/ { combined=1 }
  /--update/ && /--max-concurrency 3( |$)/ { update=1 }
  /cluster-only/ && /--max-concurrency 3( |$)/ { cluster=1 }
  END { exit !((update && cluster) && !combined) }
' "$t21log" \
  && pass "T21c both graphify subprocesses received --max-concurrency 3 (distinct records)" \
  || fail "T21c concurrency propagation not verified on two distinct records: $(cat "$t21log")"
# T21d: --no-update (publish-only) never makes the extraction/cluster-only calls,
# so an invalid throttle value is irrelevant and must NOT trip the validation
# (the run may still fail later for other reasons, but never on the throttle msg).
out=$( GRAPHIFY_MAX_CONCURRENCY=abc bash "$SCRIPT" --name luna --corpus-root "$CORPUS" --backend claude-cli \
  --maps-dir "$MAPS" --title "T" --slug graphify-luna-map --corpus-tag luna --no-update 2>&1 ); rc=$?
echo "$out" | grep -q "GRAPHIFY_MAX_CONCURRENCY must be" \
  && fail "T21d --no-update wrongly validated the irrelevant throttle value: $out" \
  || pass "T21d --no-update skips throttle validation (invalid value tolerated on publish-only path)"

# --- T23 (HIMMEL-1645): GRAPHIFY_API_TIMEOUT knob — backend-scoped default
# (900 for claude-cli ONLY; 300 = graphify's own default otherwise, incl. claude/glm),
# unset-only, validated on the extraction path only (mirrors GRAPHIFY_MAX_CONCURRENCY / T21).
# The logging stub records (a) the GRAPHIFY_API_TIMEOUT env var visible to the
# graphify subprocess — graphify's override channel — AND (b) its full argv one
# token per line, so we can assert BOTH the exported env var and the --api-timeout
# CLI flag wiring. Required cases: unset -> worker-exported 900 default visible +
# --api-timeout 900; caller-set value preserved (env + flag); invalid fails loud
# before any extraction call. Plus zero/explicitly-empty (the unset-only `-` default
# preserves them for the validation instead of silently becoming 900/300) and
# --no-update (publish-only must not validate the irrelevant timeout), matching T21. ---
T23BIN="$WS/t23bin"; mkdir -p "$T23BIN"
cat > "$T23BIN/graphify" <<STUB
#!/usr/bin/env bash
# Capture the GRAPHIFY_API_TIMEOUT env var visible to the graphify subprocess
# (one record per invocation: --update then cluster-only) and the full argv
# (one token per line, so the --api-timeout value is assertable arg-boundary-robust).
[ -n "\$GRAPHIFY_T23_ENVLOG" ] && printf 'GRAPHIFY_API_TIMEOUT=%s\n' "\${GRAPHIFY_API_TIMEOUT:-}" >> "\$GRAPHIFY_T23_ENVLOG"
[ -n "\$GRAPHIFY_CALL_LOG" ] && printf '%s\n' "\$@" >> "\$GRAPHIFY_CALL_LOG"
target=""
if [ "\$1" = "cluster-only" ]; then target="\$2"; else target="\$1"; fi
mkdir -p "\$target/graphify-out"
printf '{"nodes":[],"links":[]}' > "\$target/graphify-out/graph.json"
cat > "\$target/graphify-out/GRAPH_REPORT.md" <<'RPT'
$REPORT_FIXTURE
RPT
exit 0
STUB
chmod +x "$T23BIN/graphify"
T23CORPUS="$WS/t23corpus"; mkdir -p "$T23CORPUS/notes"
printf '# t23\ncontent\n' > "$T23CORPUS/notes/a.md"
T23MAPS="$WS/t23maps"; mkdir -p "$T23MAPS"

# (a) unset GRAPHIFY_API_TIMEOUT -> default backend (claude-cli) exports the 900
# default, visible to the stub's env AND wired into --api-timeout.
t23env="$WS/t23-env.log"; t23calls="$WS/t23-calls.log"
: > "$t23env"; : > "$t23calls"
out=$( env -u GRAPHIFY_API_TIMEOUT \
  GRAPHIFY_T23_ENVLOG="$t23env" GRAPHIFY_CALL_LOG="$t23calls" \
  GRAPHIFY_MAP_BIN="$T23BIN/graphify" PATH="$T23BIN:$PATH" \
  bash "$SCRIPT" --name t23a --corpus-root "$T23CORPUS" \
  --maps-dir "$T23MAPS" --title "T23" --slug t23a-map --corpus-tag t23a 2>&1 ); rc=$?
[ "$rc" -eq 0 ] || fail "T23a unset-timeout run exit 0 (got $rc): $out"
# env var visible to the graphify subprocess == the worker-exported 900 default.
got_env=$(sed -n 's/^GRAPHIFY_API_TIMEOUT=//p' "$t23env" | head -n 1)
[ "$got_env" = "900" ] && pass "T23a unset -> worker-exported GRAPHIFY_API_TIMEOUT=900 visible to graphify env" \
  || fail "T23a unset should export GRAPHIFY_API_TIMEOUT=900 to the graphify env (got: '$got_env')"
# --api-timeout CLI flag carries the same value (arg-boundary-robust: the token
# immediately after --api-timeout in the one-per-line call log).
got_flag=$(awk 'prev=="--api-timeout"{print; exit} {prev=$0}' "$t23calls")
[ "$got_flag" = "900" ] && pass "T23a --api-timeout flag wired to 900" \
  || fail "T23a --api-timeout should be 900 (got: '$got_flag')"

# (b) caller-set GRAPHIFY_API_TIMEOUT is preserved (env + flag), not clobbered.
: > "$t23env"; : > "$t23calls"
out=$( GRAPHIFY_API_TIMEOUT=600 \
  GRAPHIFY_T23_ENVLOG="$t23env" GRAPHIFY_CALL_LOG="$t23calls" \
  GRAPHIFY_MAP_BIN="$T23BIN/graphify" PATH="$T23BIN:$PATH" \
  bash "$SCRIPT" --name t23b --corpus-root "$T23CORPUS" \
  --maps-dir "$T23MAPS" --title "T23" --slug t23b-map --corpus-tag t23b 2>&1 ); rc=$?
[ "$rc" -eq 0 ] || fail "T23b caller-set timeout run exit 0 (got $rc): $out"
got_env=$(sed -n 's/^GRAPHIFY_API_TIMEOUT=//p' "$t23env" | head -n 1)
[ "$got_env" = "600" ] && pass "T23b caller-set GRAPHIFY_API_TIMEOUT=600 preserved in graphify env" \
  || fail "T23b caller-set 600 should be preserved (got: '$got_env')"
got_flag=$(awk 'prev=="--api-timeout"{print; exit} {prev=$0}' "$t23calls")
[ "$got_flag" = "600" ] && pass "T23b --api-timeout flag wired to the caller's 600" \
  || fail "T23b --api-timeout should be 600 (got: '$got_flag')"

# (c) invalid GRAPHIFY_API_TIMEOUT fails LOUD (rc=1) before any extraction call.
: > "$t23env"; : > "$t23calls"
out=$( GRAPHIFY_API_TIMEOUT=abc \
  GRAPHIFY_T23_ENVLOG="$t23env" GRAPHIFY_CALL_LOG="$t23calls" \
  GRAPHIFY_MAP_BIN="$T23BIN/graphify" PATH="$T23BIN:$PATH" \
  bash "$SCRIPT" --name t23c --corpus-root "$T23CORPUS" \
  --maps-dir "$T23MAPS" --title "T23" --slug t23c-map --corpus-tag t23c 2>&1 ); rc=$?
[ "$rc" -eq 1 ] && pass "T23c non-numeric GRAPHIFY_API_TIMEOUT rejected (rc=1)" \
  || fail "T23c non-numeric GRAPHIFY_API_TIMEOUT should fail rc=1 (got $rc): $out"
echo "$out" | grep -q "GRAPHIFY_API_TIMEOUT must be a positive integer" \
  && pass "T23c error names the invalid knob" \
  || fail "T23c error should name GRAPHIFY_API_TIMEOUT: $out"
[ ! -s "$t23calls" ] && pass "T23c invalid value fails before any extraction call" \
  || fail "T23c extraction ran on an invalid value: $(cat "$t23calls")"
# Zero and explicitly-empty also fail loud (unset-only `-` default preserves them for
# the validation instead of silently becoming 900/300), matching T21's contract.
: > "$t23calls"
out=$( GRAPHIFY_API_TIMEOUT=0 \
  GRAPHIFY_CALL_LOG="$t23calls" GRAPHIFY_MAP_BIN="$T23BIN/graphify" PATH="$T23BIN:$PATH" \
  bash "$SCRIPT" --name t23c0 --corpus-root "$T23CORPUS" \
  --maps-dir "$T23MAPS" --title "T23" --slug t23c0-map --corpus-tag t23c0 2>&1 ); rc=$?
{ [ "$rc" -eq 1 ] && echo "$out" | grep -q "GRAPHIFY_API_TIMEOUT must be"; } \
  && pass "T23c2 zero GRAPHIFY_API_TIMEOUT rejected (rc=1 + validation msg)" \
  || fail "T23c2 zero GRAPHIFY_API_TIMEOUT should fail rc=1 with the validation msg (got $rc): $out"
: > "$t23calls"
out=$( env GRAPHIFY_API_TIMEOUT='' \
  GRAPHIFY_CALL_LOG="$t23calls" GRAPHIFY_MAP_BIN="$T23BIN/graphify" PATH="$T23BIN:$PATH" \
  bash "$SCRIPT" --name t23c3 --corpus-root "$T23CORPUS" \
  --maps-dir "$T23MAPS" --title "T23" --slug t23c3-map --corpus-tag t23c3 2>&1 ); rc=$?
{ [ "$rc" -eq 1 ] && echo "$out" | grep -q "GRAPHIFY_API_TIMEOUT must be"; } \
  && pass "T23c3 explicitly-empty GRAPHIFY_API_TIMEOUT rejected (rc=1 + validation msg, not silently defaulted)" \
  || fail "T23c3 explicitly-empty GRAPHIFY_API_TIMEOUT should fail rc=1 with the validation msg (got $rc): $out"
# --no-update (publish-only) never makes the extraction call, so an invalid timeout is
# irrelevant and must NOT trip the validation (mirrors T21d). T23a/t23b already promoted
# a GRAPH_REPORT.md into this corpus, so the publish-only read succeeds.
out=$( GRAPHIFY_API_TIMEOUT=abc \
  GRAPHIFY_MAP_BIN="$T23BIN/graphify" PATH="$T23BIN:$PATH" \
  bash "$SCRIPT" --name t23d --corpus-root "$T23CORPUS" \
  --maps-dir "$T23MAPS" --title "T23" --slug t23d-map --corpus-tag t23d --no-update 2>&1 ); rc=$?
echo "$out" | grep -q "GRAPHIFY_API_TIMEOUT must be" \
  && fail "T23d --no-update wrongly validated the irrelevant timeout value: $out" \
  || pass "T23d --no-update skips timeout validation (invalid value tolerated on publish-only path)"

# Backend-matrix (codex-adv-1): the 900 default is claude-cli ONLY. The claude
# (Anthropic API) backend and the glm remap (-> claude, the Z.ai API endpoint) are
# NOT contending-headless backends, so they stay at graphify's own 300 default on the
# --api-timeout flag. The else-branch does NOT export (300 is graphify's own default;
# an unset env already means 300 to graphify), so the env var visible to the subprocess
# is EMPTY for these backends (unlike the worker-exported 900 in T23a).

# (e) --backend claude with GRAPHIFY_API_TIMEOUT unset -> 300 flag, no export (env empty).
: > "$t23env"; : > "$t23calls"
out=$( env -u GRAPHIFY_API_TIMEOUT \
  GRAPHIFY_T23_ENVLOG="$t23env" GRAPHIFY_CALL_LOG="$t23calls" \
  GRAPHIFY_MAP_BIN="$T23BIN/graphify" PATH="$T23BIN:$PATH" \
  bash "$SCRIPT" --name t23e --corpus-root "$T23CORPUS" \
  --maps-dir "$T23MAPS" --title "T23" --slug t23e-map --corpus-tag t23e --backend claude 2>&1 ); rc=$?
[ "$rc" -eq 0 ] || fail "T23e --backend claude run exit 0 (got $rc): $out"
got_env=$(sed -n 's/^GRAPHIFY_API_TIMEOUT=//p' "$t23env" | head -n 1)
[ "$got_env" = "" ] && pass "T23e --backend claude does NOT export a raised timeout (env unset = graphify's own 300 default)" \
  || fail "T23e --backend claude should NOT export GRAPHIFY_API_TIMEOUT (got: '$got_env')"
got_flag=$(awk 'prev=="--api-timeout"{print; exit} {prev=$0}' "$t23calls")
[ "$got_flag" = "300" ] && pass "T23e --backend claude --api-timeout flag wired to 300 (graphify's own default)" \
  || fail "T23e --backend claude --api-timeout should be 300 (got: '$got_flag')"

# (f) --backend glm (-> claude remap) with GRAPHIFY_API_TIMEOUT unset + ANTHROPIC_API_KEY
# set (so the remap's key check passes; the graphify binary is the T23 stub, no real
# calls) -> reaches claude, so it stays at 300 too, NOT the claude-cli 900.
# --corpus-class himmel-code (HIMMEL-2224): every zai-glm VAULT cell is explicit
# deny now, so the default luna-personal class would fail this run closed at the
# egress preflight before graphify is ever called, leaving the timeout wiring --
# the only thing this case tests -- unexercised. himmel-code x zai-glm is still
# `allow` (public code, wildcard row), which is exactly the corpus the glm remap
# still legitimately serves.
: > "$t23env"; : > "$t23calls"
out=$( env -u GRAPHIFY_API_TIMEOUT ANTHROPIC_API_KEY=dummy-test-key ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic \
  GRAPHIFY_T23_ENVLOG="$t23env" GRAPHIFY_CALL_LOG="$t23calls" \
  GRAPHIFY_MAP_BIN="$T23BIN/graphify" PATH="$T23BIN:$PATH" \
  bash "$SCRIPT" --name t23f --corpus-root "$T23CORPUS" --corpus-class himmel-code \
  --maps-dir "$T23MAPS" --title "T23" --slug t23f-map --corpus-tag t23f --backend glm 2>&1 ); rc=$?
[ "$rc" -eq 0 ] || fail "T23f --backend glm run exit 0 (got $rc): $out"
got_env=$(sed -n 's/^GRAPHIFY_API_TIMEOUT=//p' "$t23env" | head -n 1)
[ "$got_env" = "" ] && pass "T23f --backend glm (-> claude) does NOT export a raised timeout (env unset = graphify's own 300 default)" \
  || fail "T23f --backend glm should NOT export GRAPHIFY_API_TIMEOUT (got: '$got_env')"
got_flag=$(awk 'prev=="--api-timeout"{print; exit} {prev=$0}' "$t23calls")
[ "$got_flag" = "300" ] && pass "T23f --backend glm --api-timeout flag wired to 300 (graphify's own default)" \
  || fail "T23f --backend glm --api-timeout should be 300 (got: '$got_flag')"

# --- T22 (HIMMEL-1097): semantic cache continuity. graphify keeps its
# content-keyed cache inside graphify-out/, while refresh extracts from a fresh
# scratch path. Seed only the live cache artifacts (never derived reports); the
# stub records whether they were present BEFORE an actual --update invocation,
# then writes refreshed cache state and removes one seeded artifact during
# cluster-only. The runner must (a) seed only cache state, (b) transactionally
# mirror the final scratch cache/markers without preserving stale artifacts, and
# (c) replace graphify's native manifest with the synthesized HIMMEL-907
# freshness manifest keyed by corpus markdown paths. ---
CACHECORPUS="$WS/cachecorpus"; CACHEMAPS="$WS/cachemaps"; CACHEBIN="$WS/cachebin"
mkdir -p "$CACHECORPUS/notes" "$CACHEMAPS" "$CACHEBIN" "$CACHECORPUS/graphify-out/cache"
printf '# cache\ncontent\n' > "$CACHECORPUS/notes/cache.md"
printf 'PRIOR-CACHE' > "$CACHECORPUS/graphify-out/cache/prior.cache"
printf 'PRIOR-MARKER' > "$CACHECORPUS/graphify-out/.graphify_semantic_marker"
printf '{"state":"prior"}' > "$CACHECORPUS/graphify-out/.graphify_analysis.json"
printf 'PRIOR-REPORT' > "$CACHECORPUS/graphify-out/GRAPH_REPORT.md"
printf 'PRIOR-HTML' > "$CACHECORPUS/graphify-out/graph.html"
printf '{"nodes":["prior"]}' > "$CACHECORPUS/graphify-out/graph.json"
printf '{"prior_native":true}' > "$CACHECORPUS/graphify-out/manifest.json"
printf '.' > "$CACHECORPUS/graphify-out/.graphify_root"
CACHE_LOG="$WS/cache-seed.log"; : > "$CACHE_LOG"
cat > "$CACHEBIN/graphify" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "--version" ]; then printf 'graphify 0.0.0\n'; exit 0; fi
target=""
if [ "\$1" = "cluster-only" ]; then target="\$2"; else target="\$1"; fi
if [ "\$1" != "cluster-only" ]; then
  if [ "\$2" = "--update" ] \
     && [ -f "\$target/graphify-out/cache/prior.cache" ] \
     && grep -q 'PRIOR-MARKER' "\$target/graphify-out/.graphify_semantic_marker" \
     && grep -q '"state":"prior"' "\$target/graphify-out/.graphify_analysis.json" \
     && [ ! -e "\$target/graphify-out/GRAPH_REPORT.md" ] \
     && [ ! -e "\$target/graphify-out/graph.html" ] \
     && [ ! -e "\$target/graphify-out/graph.json" ] \
     && [ ! -e "\$target/graphify-out/manifest.json" ] \
     && [ ! -e "\$target/graphify-out/.graphify_root" ]; then
    printf 'seeded\n' > "$CACHE_LOG"
  else
    printf 'missing-or-derived\n' > "$CACHE_LOG"
  fi
  mkdir -p "\$target/graphify-out/cache"
  printf 'FRESH-CACHE' > "\$target/graphify-out/cache/fresh.cache"
  printf 'FRESH-MARKER' > "\$target/graphify-out/.graphify_semantic_marker"
  printf '{"state":"fresh"}' > "\$target/graphify-out/.graphify_analysis.json"
  printf '{"graphify_native":true}' > "\$target/graphify-out/manifest.json"
else
  rm -f "\$target/graphify-out/.graphify_analysis.json"
fi
printf '{"nodes":[],"links":[]}' > "\$target/graphify-out/graph.json"
cat > "\$target/graphify-out/GRAPH_REPORT.md" <<'RPT'
$REPORT_FIXTURE
RPT
exit 0
STUB
chmod +x "$CACHEBIN/graphify"
out=$( GRAPHIFY_MAP_BIN="$CACHEBIN/graphify" PATH="$CACHEBIN:$PATH" \
  bash "$SCRIPT" --name cachetest --corpus-root "$CACHECORPUS" --backend claude-cli \
  --maps-dir "$CACHEMAPS" --title "Cache Map" --slug cache-map --corpus-tag cache 2>&1 ); rc=$?
[ "$rc" -eq 0 ] || fail "T22 cache refresh exit 0 (got $rc): $out"
grep -qx 'seeded' "$CACHE_LOG" 2>/dev/null \
  && pass "T22a only semantic cache artifacts seeded into scratch before --update" \
  || fail "T22a cache seed missing, derived output copied, or --update evidence absent"
CACHEOUT="$CACHECORPUS/graphify-out"
[ -f "$CACHEOUT/cache/prior.cache" ] && [ -f "$CACHEOUT/cache/fresh.cache" ] \
  && pass "T22b refreshed cache directory persisted back to OUT_DIR" \
  || fail "T22b cache directory did not persist back to OUT_DIR"
grep -q 'FRESH-MARKER' "$CACHEOUT/.graphify_semantic_marker" 2>/dev/null \
  && pass "T22b semantic marker persisted back to OUT_DIR" \
  || fail "T22b semantic marker did not persist back to OUT_DIR"
[ ! -e "$CACHEOUT/.graphify_analysis.json" ] \
  && pass "T22b semantic artifact removed when absent from final scratch output" \
  || fail "T22b stale seeded analysis survived despite absence from scratch output"
python3 - "$CACHEOUT/manifest.json" <<'PY' 2>/dev/null \
  && pass "T22c synthesized HIMMEL-907 manifest replaces graphify native manifest" \
  || fail "T22c promoted manifest is not the synthesized freshness manifest"
import json, sys
d = json.load(open(sys.argv[1]))
assert "notes/cache.md" in d
assert "graphify_native" not in d
PY

# --- T23 (HIMMEL-1097 CR follow-up): the sideline `mv "$OUT_DIR/cache"
# "$CACHE_BACKUP"` that makes room for the staged cache was unguarded (no
# `if !`, no error message, no controlled exit). This script runs under
# `set -euo pipefail`, so a bare failing `mv` here DOES still halt it via
# errexit -- but uncontrolled: the raw mv stderr (no "refresh-graph-map:"
# prefix or explanation of what failed) is the only diagnostic, and the exit
# code is whatever `mv` returned (commonly 1) rather than this script's own
# "2 = fence/tooling failure" convention used by every sibling failure in
# this same promote block. Guard it explicitly instead: on failure, emit a
# clear prefixed error, exit 2 (matching the sibling `! mv ...; exit 2` right
# below it), and make sure the staged cache is never subsequently moved onto
# the still-occupied destination (which -- on a shell WITHOUT errexit, or a
# platform where the sideline mv fails partway rather than outright -- is
# exactly the nesting corruption CodeRabbit flagged: `mv src dst` nests src
# inside dst when dst already exists, rather than replacing it). Shadow `mv`
# with a stub that fails ONLY the exact sideline call (matched on its source
# arg, "$OUT_DIR/cache") so every other mv in the script (graph.json,
# GRAPH_REPORT.md, the staged-cache install itself, semantic artifacts, the
# manifest/marker stamps) still goes through to the real mv. ---
REALMV="$(command -v mv)"
MVFAILCORPUS="$WS/mvfailcorpus"; MVFAILMAPS="$WS/mvfailmaps"; MVFAILBIN="$WS/mvfailbin"
mkdir -p "$MVFAILCORPUS/notes" "$MVFAILMAPS" "$MVFAILBIN" "$MVFAILCORPUS/graphify-out/cache"
printf '# n\ncontent\n' > "$MVFAILCORPUS/notes/n.md"
printf 'ORIGINAL' > "$MVFAILCORPUS/graphify-out/cache/original.marker"
cat > "$MVFAILBIN/mv" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "$MVFAILCORPUS/graphify-out/cache" ]; then
  echo "simulated sideline mv failure" >&2
  exit 1
fi
exec "$REALMV" "\$@"
STUB
chmod +x "$MVFAILBIN/mv"
cat > "$MVFAILBIN/graphify" <<STUB
#!/usr/bin/env bash
target=""
if [ "\$1" = "cluster-only" ]; then target="\$2"; else target="\$1"; fi
mkdir -p "\$target/graphify-out/cache"
printf 'STAGED' > "\$target/graphify-out/cache/staged.marker"
printf '{"nodes":[],"links":[]}' > "\$target/graphify-out/graph.json"
cat > "\$target/graphify-out/GRAPH_REPORT.md" <<'RPT'
$REPORT_FIXTURE
RPT
exit 0
STUB
chmod +x "$MVFAILBIN/graphify"
out=$( GRAPHIFY_MAP_BIN="$MVFAILBIN/graphify" PATH="$MVFAILBIN:$PATH" \
  bash "$SCRIPT" --name mvfail --corpus-root "$MVFAILCORPUS" --backend claude-cli \
  --maps-dir "$MVFAILMAPS" --title "Mv Fail Map" --slug mvfail-map --corpus-tag mvfail 2>&1 ); rc=$?
[ "$rc" -eq 2 ] && pass "T23a failed sideline mv aborts promotion (rc=2), not a silent rc=0" \
  || fail "T23a a failed sideline mv should abort the promotion with rc=2 (got $rc): $out"
echo "$out" | grep -q "failed to sideline existing cache" \
  && pass "T23a error names the sideline failure explicitly" \
  || fail "T23a error should mention the sideline failure: $out"
MVFAILOUT="$MVFAILCORPUS/graphify-out"
[ ! -d "$MVFAILOUT/cache/cache" ] \
  && pass "T23b destination cache not nested (staged cache never moved onto the still-occupied dir)" \
  || fail "T23b staged cache was nested inside the existing cache dir (\$OUT_DIR/cache/cache exists) -- promotion corruption"
[ -f "$MVFAILOUT/cache/original.marker" ] \
  && pass "T23b original cache left untouched after the aborted promotion" \
  || fail "T23b original cache content was lost despite the promotion aborting"
[ ! -e "$MVFAILOUT/cache/staged.marker" ] \
  && pass "T23b staged cache content did not leak into the existing cache dir" \
  || fail "T23b staged cache content appeared in \$OUT_DIR/cache despite the aborted promotion"

# --- T24 (HIMMEL-1097 CR follow-up): when the refreshed scratch output has NO
# staged semantic cache, a prior $OUT_DIR/cache must NOT survive -- the cache
# path must be consistent with the sibling semantic artifacts handled right
# below it (which rm -f the unstaged marker/analysis), else stale cache
# artifacts persist in graphify-out and silently reseed later runs. The runner
# seeds the live cache into scratch before --update; this stub RECEIVES that
# seeded cache, then DROPS it (rm -rf) and writes none back -- a refresh whose
# extraction produced no cache. RED against the pre-fix code: the
# `if [ -d "$PROMOTE_STAGE/cache" ]` promote block had no else branch, so a
# missing staged cache left the stale $OUT_DIR/cache untouched. ---
NOCACHEBIN="$WS/nocachebin"; mkdir -p "$NOCACHEBIN"
cat > "$NOCACHEBIN/graphify" <<STUB
#!/usr/bin/env bash
target=""
if [ "\$1" = "cluster-only" ]; then target="\$2"; else target="\$1"; fi
mkdir -p "\$target/graphify-out"
# The refresh produced NO semantic cache: drop whatever the runner seeded into
# scratch and write none back.
rm -rf "\$target/graphify-out/cache"
printf '{"nodes":[],"links":[]}' > "\$target/graphify-out/graph.json"
cat > "\$target/graphify-out/GRAPH_REPORT.md" <<'RPT'
$REPORT_FIXTURE
RPT
exit 0
STUB
chmod +x "$NOCACHEBIN/graphify"
NOCACHECORPUS="$WS/nocachecorpus"; NOCACHEMAPS="$WS/nocachemaps"
mkdir -p "$NOCACHECORPUS/notes" "$NOCACHEMAPS" "$NOCACHECORPUS/graphify-out/cache"
printf '# n\ncontent\n' > "$NOCACHECORPUS/notes/n.md"
# Prior stale cache in the LIVE out dir -- the artifact the defect lets survive.
printf 'STALE-CACHE' > "$NOCACHECORPUS/graphify-out/cache/stale.marker"
out=$( GRAPHIFY_MAP_BIN="$NOCACHEBIN/graphify" PATH="$NOCACHEBIN:$PATH" \
  bash "$SCRIPT" --name nocache --corpus-root "$NOCACHECORPUS" --backend claude-cli \
  --maps-dir "$NOCACHEMAPS" --title "NoCache Map" --slug nocache-map --corpus-tag nocache 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && pass "T24 cache-less refresh exit 0" \
  || fail "T24 cache-less refresh should exit 0 (got $rc): $out"
NOCACHEOUT="$NOCACHECORPUS/graphify-out"
[ -f "$NOCACHEOUT/graph.json" ] && pass "T24 graph still promoted despite no cache" \
  || fail "T24 graph.json missing after a cache-less refresh: $out"
[ ! -e "$NOCACHEOUT/cache" ] && pass "T24 stale cache removed when scratch produced none" \
  || fail "T24 stale \$OUT_DIR/cache survived a refresh that produced no staged cache (should be removed)"

# --- T25 (HIMMEL-1406, defect 1): a promote-refusal must PRESERVE the
# extracted scratch graphify-out instead of the EXIT trap deleting it --
# the real 2026-07-30 luna/glm incident spent a full extraction (14,569
# nodes, 16.7M tokens in) only to have the refusal's cleanup discard the
# only copy, leaving the offending line unverifiable. Reuses a T11-style
# report-body leak (sentinel graph.json content + a leaking GRAPH_REPORT.md)
# and asserts: (a) the refusal message names a quarantine path, (b) that
# path exists and holds the promoted-would-be graph.json + GRAPH_REPORT.md
# (the paid artifact, byte-identical to what extraction produced) plus a
# semantic-cache marker (HIMMEL-1406: "keep any semantic cache reusable for
# the next run"), (c) a non-printed context snippet file also landed there,
# and (d) the leaked host path itself never appears in stdout/stderr (same
# redaction rule as T11/T20 -- the quarantine message must not itself leak
# the secret it's preserving). ---
QBIN="$WS/qbin"; mkdir -p "$QBIN"
cat > "$QBIN/graphify" <<'STUB'
#!/usr/bin/env bash
target=""
if [ "$1" = "cluster-only" ]; then target="$2"; else target="$1"; fi
mkdir -p "$target/graphify-out/cache"
printf 'SENTINEL-PAID-EXTRACTION-CACHE' > "$target/graphify-out/cache/semantic.cache"
printf '{"nodes":[{"id":"sentinel-node"}],"links":[]}' > "$target/graphify-out/graph.json"
{
  printf '# Graph Report - X  (2026-07-17)\n\n'
  printf '## Summary\n- 42 nodes . 30 edges . 5 communities (5 shown)\n\n'
  printf '## God Nodes (most connected - your core abstractions)\n'
  printf '1. `C:/Users/quarantoken/AppData/Local/Temp/case` - 9 edges\n\n'
  printf '## Communities (5 total)\n\n### Community 0 - "Alpha"\nCohesion: 0.06\nNodes (20): a, b (+18 more)\n'
} > "$target/graphify-out/GRAPH_REPORT.md"
exit 0
STUB
chmod +x "$QBIN/graphify"
QCORPUS="$WS/qcorpus"; QMAPS="$WS/qmaps"; mkdir -p "$QCORPUS/notes" "$QMAPS"
printf '# n\ncontent\n' > "$QCORPUS/notes/n.md"
out=$( GRAPHIFY_MAP_BIN="$QBIN/graphify" PATH="$QBIN:$PATH" \
  bash "$SCRIPT" --name quarantest --corpus-root "$QCORPUS" --backend claude-cli \
  --maps-dir "$QMAPS" --title "Q Map" --slug q-map --corpus-tag q 2>&1 ); rc=$?
[ "$rc" -eq 2 ] && pass "T25 leaking refresh still fails loudly (rc=2)" \
  || fail "T25 leaking refresh should fail loudly with rc=2 (got $rc): $out"
qdir=$(printf '%s\n' "$out" | grep -oE '/[^ ]*\.quarantine' | head -n1)
[ -n "$qdir" ] && pass "T25 refusal message names a quarantine path" \
  || fail "T25 refusal message should name a quarantine path: $out"
[ -n "$qdir" ] && [ -d "$qdir" ] && pass "T25 quarantine path exists as a directory" \
  || fail "T25 quarantine path missing/not a directory: $qdir"
[ -n "$qdir" ] && grep -q "sentinel-node" "$qdir/graph.json" 2>/dev/null \
  && pass "T25 quarantined graph.json preserves the paid extraction" \
  || fail "T25 quarantined graph.json missing/does not match the extracted artifact"
[ -n "$qdir" ] && [ -f "$qdir/GRAPH_REPORT.md" ] \
  && pass "T25 quarantined GRAPH_REPORT.md preserved" \
  || fail "T25 quarantined GRAPH_REPORT.md missing"
[ -n "$qdir" ] && grep -q "SENTINEL-PAID-EXTRACTION-CACHE" "$qdir/cache/semantic.cache" 2>/dev/null \
  && pass "T25 quarantined semantic cache preserved (reusable for the next run)" \
  || fail "T25 quarantined semantic cache missing"
[ -n "$qdir" ] && [ -f "$qdir/.leak-context-GRAPH_REPORT.md.txt" ] \
  && pass "T25 leak context snippet saved into the quarantine copy" \
  || fail "T25 leak context snippet file missing from quarantine copy"
echo "$out" | grep -q "quarantoken" \
  && fail "T25 refusal/quarantine message exposes the rejected host path: $out" \
  || pass "T25 refusal/quarantine message redacts the rejected host path"
[ -e "$QCORPUS/graphify-out/graph.json" ] \
  && fail "T25 leaking refresh still promoted into \$CORPUS_ROOT/graphify-out" \
  || pass "T25 nothing promoted under \$CORPUS_ROOT on a leaking refresh"

# --- T26 (HIMMEL-1406, defect 2): graph.json's host-path scan is scoped to
# STRUCTURAL fields only. Two halves against the SAME node shape (id/label/
# source_file), differing only in WHICH field carries the host path:
# (a) the path lives only in `label` (a content/summary field a vault note's
#     extracted text can legitimately carry, e.g. a rationale quoting
#     C:\Users\...) -- must PROMOTE normally (rc 0), and the promoted
#     graph.json still carries that content verbatim (scoping the SCAN, not
#     redacting the artifact);
# (b) the path lives on `source_file` (a structural field graphify itself
#     writes) -- must still REFUSE (rc 2), proving the scoping didn't
#     collaterally blind the guard to a real structural leak. ---
CONTENTBIN="$WS/contentbin"; mkdir -p "$CONTENTBIN"
cat > "$CONTENTBIN/graphify" <<'STUB'
#!/usr/bin/env bash
target=""
if [ "$1" = "cluster-only" ]; then target="$2"; else target="$1"; fi
mkdir -p "$target/graphify-out"
printf '{"nodes":[{"id":"n1","label":"See C:\\\\Users\\\\labelleaktoken\\\\notes.md for details","source_file":"notes/a.md"}],"links":[]}' \
  > "$target/graphify-out/graph.json"
printf '# Graph Report - X  (2026-07-17)\n\n## Summary\n- 1 nodes . 0 edges . 1 communities (1 shown)\n' \
  > "$target/graphify-out/GRAPH_REPORT.md"
exit 0
STUB
chmod +x "$CONTENTBIN/graphify"
CONTENTCORPUS="$WS/contentcorpus"; CONTENTMAPS="$WS/contentmaps"; mkdir -p "$CONTENTCORPUS/notes" "$CONTENTMAPS"
printf '# n\ncontent\n' > "$CONTENTCORPUS/notes/n.md"
out=$( GRAPHIFY_MAP_BIN="$CONTENTBIN/graphify" PATH="$CONTENTBIN:$PATH" \
  bash "$SCRIPT" --name contenttest --corpus-root "$CONTENTCORPUS" --backend claude-cli \
  --maps-dir "$CONTENTMAPS" --title "Content Map" --slug content-map --corpus-tag content 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && pass "T26a host path ONLY in a content field (label) promotes normally (rc=0)" \
  || fail "T26a content-only host path should promote (got rc=$rc): $out"
[ -f "$CONTENTMAPS/content-map.md" ] && pass "T26a MOC published despite the content-borne host path" \
  || fail "T26a MOC not published: $out"
grep -q "labelleaktoken" "$CONTENTCORPUS/graphify-out/graph.json" 2>/dev/null \
  && pass "T26a promoted graph.json still carries the content verbatim (scan scoped, artifact untouched)" \
  || fail "T26a promoted graph.json lost the content-borne text"

STRUCTBIN="$WS/structbin"; mkdir -p "$STRUCTBIN"
cat > "$STRUCTBIN/graphify" <<'STUB'
#!/usr/bin/env bash
target=""
if [ "$1" = "cluster-only" ]; then target="$2"; else target="$1"; fi
mkdir -p "$target/graphify-out"
printf '{"nodes":[{"id":"n1","label":"a perfectly ordinary node","source_file":"C:\\\\Users\\\\structleaktoken\\\\notes.md"}],"links":[]}' \
  > "$target/graphify-out/graph.json"
printf '# Graph Report - X  (2026-07-17)\n\n## Summary\n- 1 nodes . 0 edges . 1 communities (1 shown)\n' \
  > "$target/graphify-out/GRAPH_REPORT.md"
exit 0
STUB
chmod +x "$STRUCTBIN/graphify"
STRUCTCORPUS="$WS/structcorpus"; STRUCTMAPS="$WS/structmaps"; mkdir -p "$STRUCTCORPUS/notes" "$STRUCTMAPS"
printf '# n\ncontent\n' > "$STRUCTCORPUS/notes/n.md"
out=$( GRAPHIFY_MAP_BIN="$STRUCTBIN/graphify" PATH="$STRUCTBIN:$PATH" \
  bash "$SCRIPT" --name structtest --corpus-root "$STRUCTCORPUS" --backend claude-cli \
  --maps-dir "$STRUCTMAPS" --title "Struct Map" --slug struct-map --corpus-tag struct 2>&1 ); rc=$?
[ "$rc" -eq 2 ] && pass "T26b host path in a structural field (source_file) still refuses (rc=2)" \
  || fail "T26b structural-field host path should still refuse (got rc=$rc): $out"
echo "$out" | grep -q "graph.json" \
  && pass "T26b error names graph.json as the offending artifact" || fail "T26b error should name graph.json: $out"
echo "$out" | grep -q "structleaktoken" \
  && fail "T26b error output exposes the rejected host path: $out" \
  || pass "T26b error output redacts the rejected host path"
[ ! -e "$STRUCTCORPUS/graphify-out/graph.json" ] \
  && pass "T26b nothing promoted under \$CORPUS_ROOT on a structural-field leak" \
  || fail "T26b leaking refresh still promoted into \$CORPUS_ROOT/graphify-out"

# --- T27 (HIMMEL-1415): corpus-copy excludes graphify's own published
# derived pages -- <maps-dir>/graph/* (per-node/community notes graphify
# mints there) and <maps-dir>/<slug>.md (the curated MOC this script's own
# publish step writes) -- from the extraction corpus, closing the feedback
# loop where graphify's own output gets re-extracted into itself. A
# legitimate, hand-authored note living directly under maps-dir (not under
# graph/, not the MOC) must still reach the corpus -- this isn't "exclude all
# of maps-dir wholesale". The stub snapshots what the corpus-copy actually
# staged into the scratch dir before writing its own output. ---
EXCLBIN="$WS/exclbin"; mkdir -p "$EXCLBIN"
cat > "$EXCLBIN/graphify" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "--version" ]; then printf 'graphify 0.0.0\n'; exit 0; fi
target=""
if [ "\$1" = "cluster-only" ]; then target="\$2"; else target="\$1"; fi
if [ "\$1" != "cluster-only" ]; then
  ( cd "\$target" && find . -type f -name '*.md' | sort ) > "$WS/excl-scratch-listing.txt"
fi
mkdir -p "\$target/graphify-out"
printf '{"nodes":[],"links":[]}' > "\$target/graphify-out/graph.json"
cat > "\$target/graphify-out/GRAPH_REPORT.md" <<'RPT'
$REPORT_FIXTURE
RPT
exit 0
STUB
chmod +x "$EXCLBIN/graphify"
EXCLCORPUS="$WS/exclcorpus"; EXCLMAPS="$EXCLCORPUS/60-Maps"
mkdir -p "$EXCLCORPUS/notes" "$EXCLMAPS/graph"
printf '# n\ncontent\n' > "$EXCLCORPUS/notes/n.md"
printf '# derived node note\nminted by graphify\n' > "$EXCLMAPS/graph/some-node.md"
printf '# Legit Maps Note\nhand-authored, not graphify output\n' > "$EXCLMAPS/legit-note.md"
# Pre-seed the MOC this run's OWN publish step will (re)write -- simulates a
# prior run's published output already sitting in the vault when the NEXT
# refresh's corpus-copy runs.
printf '# stale MOC from a prior run\n' > "$EXCLMAPS/excl-map.md"
out=$( GRAPHIFY_MAP_BIN="$EXCLBIN/graphify" PATH="$EXCLBIN:$PATH" \
  bash "$SCRIPT" --name excltest --corpus-root "$EXCLCORPUS" --backend claude-cli \
  --maps-dir "$EXCLMAPS" --title "Excl Map" --slug excl-map --corpus-tag excl 2>&1 ); rc=$?
[ "$rc" -eq 0 ] || fail "T27 run exit 0 (got $rc): $out"
if grep -qF "60-Maps/graph/some-node.md" "$WS/excl-scratch-listing.txt" 2>/dev/null; then
  fail "T27 derived-page note (maps-dir/graph/*) leaked into the extraction corpus"
else
  pass "T27 derived-page note (maps-dir/graph/*) excluded from the extraction corpus"
fi
if grep -qF "60-Maps/excl-map.md" "$WS/excl-scratch-listing.txt" 2>/dev/null; then
  fail "T27 the corpus's own published MOC (maps-dir/slug.md) leaked into the extraction corpus"
else
  pass "T27 the corpus's own published MOC (maps-dir/slug.md) excluded from the extraction corpus"
fi
if grep -qF "60-Maps/legit-note.md" "$WS/excl-scratch-listing.txt" 2>/dev/null; then
  pass "T27 a hand-authored maps-dir note (not under graph/, not the MOC) still reaches the corpus"
else
  fail "T27 over-excluded: a legitimate maps-dir note was dropped from the corpus"
fi

# --- T28 (HIMMEL-1415 CR follow-up, codex-adv-1): the computed maps-prefix
# and slug land inside `find -path` PATTERN arguments, where *, ?, and [ are
# fnmatch wildcard syntax even though the arguments are shell-quoted -- shell
# quoting only stops the SHELL from globbing them; find's own matcher still
# treats them as wildcards. A maps-dir/slug containing one of these could
# either (a) fail to match its OWN literal path (its derived pages re-enter
# the corpus, reopening the feedback loop T27 just closed) or (b) over-match
# an unrelated sibling (silently dropping real content). Uses a maps-dir
# literally named "60-[Maps]" (the CR's own example) and a slug containing
# "[v2]" -- both real, valid filename characters (unlike a literal "*", which
# a native Win32 file API refuses even though MSYS/bash can create one --
# tried, and publish-graph-map.mjs's write ENOENT'd on it -- so "[" "]" alone
# carries this regression without depending on Windows/MSYS path-translation
# quirks). ---
EXCL2BIN="$WS/excl2bin"; mkdir -p "$EXCL2BIN"
cat > "$EXCL2BIN/graphify" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "--version" ]; then printf 'graphify 0.0.0\n'; exit 0; fi
target=""
if [ "\$1" = "cluster-only" ]; then target="\$2"; else target="\$1"; fi
if [ "\$1" != "cluster-only" ]; then
  ( cd "\$target" && find . -type f -name '*.md' | sort ) > "$WS/excl2-scratch-listing.txt"
fi
mkdir -p "\$target/graphify-out"
printf '{"nodes":[],"links":[]}' > "\$target/graphify-out/graph.json"
cat > "\$target/graphify-out/GRAPH_REPORT.md" <<'RPT'
$REPORT_FIXTURE
RPT
exit 0
STUB
chmod +x "$EXCL2BIN/graphify"
EXCL2CORPUS="$WS/excl2corpus"
EXCL2MAPS="$EXCL2CORPUS/60-[Maps]"
EXCL2SLUG='map-[v2]-note'
mkdir -p "$EXCL2CORPUS/notes" "$EXCL2MAPS/graph"
printf '# n\ncontent\n' > "$EXCL2CORPUS/notes/n.md"
# The derived page + the MOC this run's own publish step will (re)write --
# both must be EXCLUDED (the "under-match" direction: escaping must not
# break the exclusion on its own metachar-laden literal path). Unescaped,
# the bracket class "[Maps]" matches exactly ONE char from {M,a,p,s} -- it
# can never match the literal 6-char "[Maps]" substring in the real dirname,
# so without the fix these would leak straight back into the corpus.
printf '# derived node note\nminted by graphify\n' > "$EXCL2MAPS/graph/some-node.md"
printf '# stale MOC from a prior run\n' > "$EXCL2MAPS/$EXCL2SLUG.md"
# A sibling maps-dir named "60-M" -- exactly what the UNESCAPED bracket class
# "[Maps]" (one char from {M,a,p,s}) would ALSO match -- carrying its own
# unrelated graph/ page. Proves no over-match spillover into a
# similarly-named sibling once escaped (the "over-match" direction).
mkdir -p "$EXCL2CORPUS/60-M/graph"
printf '# unrelated sibling page\nnot derived from THIS maps-dir\n' > "$EXCL2CORPUS/60-M/graph/sibling.md"
# A file directly under the real maps-dir whose name is exactly what the
# UNESCAPED slug pattern "map-[v2]-note.md" ([v2] -> one char from {v,2})
# would also match -- "map-v-note.md" -- must survive as real corpus
# content, not get swept up by an over-permissive class.
printf '# unrelated note\nresembles the slug pattern, is not the MOC\n' > "$EXCL2MAPS/map-v-note.md"
out=$( GRAPHIFY_MAP_BIN="$EXCL2BIN/graphify" PATH="$EXCL2BIN:$PATH" \
  bash "$SCRIPT" --name excl2test --corpus-root "$EXCL2CORPUS" --backend claude-cli \
  --maps-dir "$EXCL2MAPS" --title "Excl2 Map" --slug "$EXCL2SLUG" --corpus-tag excl2 2>&1 ); rc=$?
[ "$rc" -eq 0 ] || fail "T28 run exit 0 (got $rc): $out"
if grep -qF "60-[Maps]/graph/some-node.md" "$WS/excl2-scratch-listing.txt" 2>/dev/null; then
  fail "T28 derived-page under a metachar-laden maps-dir leaked into the corpus (escaping broke the exclusion)"
else
  pass "T28 derived-page under a metachar-laden maps-dir still excluded"
fi
if grep -qF "60-[Maps]/map-[v2]-note.md" "$WS/excl2-scratch-listing.txt" 2>/dev/null; then
  fail "T28 the MOC under a metachar-laden slug leaked into the corpus (escaping broke the exclusion)"
else
  pass "T28 the MOC under a metachar-laden slug still excluded"
fi
if grep -qF "60-M/graph/sibling.md" "$WS/excl2-scratch-listing.txt" 2>/dev/null; then
  pass "T28 a similarly-named sibling maps-dir's page still reaches the corpus (no bracket-class over-match)"
else
  fail "T28 over-matched: an unrelated sibling maps-dir's page was wrongly excluded"
fi
if grep -qF "60-[Maps]/map-v-note.md" "$WS/excl2-scratch-listing.txt" 2>/dev/null; then
  pass "T28 a note resembling the slug pattern still reaches the corpus (no bracket-class over-match)"
else
  fail "T28 over-matched: a legitimate note resembling the slug pattern was wrongly excluded"
fi

# --- T29 (HIMMEL-1415 CR follow-up round 2, codex-1-r2): a trailing slash on
# --maps-dir must not defeat the exclusion. Passed raw, "$MAPS_DIR" ends with
# "/" and the exclusion pattern becomes "./60-Maps//graph/*" -- find's -path
# matcher never matches that against the real "./60-Maps/graph/..." path, so
# the derived page silently leaks back into the corpus (the exact feedback
# loop T27 exists to close). Same fixture shape as T27, just with a trailing
# slash on --maps-dir. ---
EXCL3BIN="$WS/excl3bin"; mkdir -p "$EXCL3BIN"
cat > "$EXCL3BIN/graphify" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "--version" ]; then printf 'graphify 0.0.0\n'; exit 0; fi
target=""
if [ "\$1" = "cluster-only" ]; then target="\$2"; else target="\$1"; fi
if [ "\$1" != "cluster-only" ]; then
  ( cd "\$target" && find . -type f -name '*.md' | sort ) > "$WS/excl3-scratch-listing.txt"
fi
mkdir -p "\$target/graphify-out"
printf '{"nodes":[],"links":[]}' > "\$target/graphify-out/graph.json"
cat > "\$target/graphify-out/GRAPH_REPORT.md" <<'RPT'
$REPORT_FIXTURE
RPT
exit 0
STUB
chmod +x "$EXCL3BIN/graphify"
EXCL3CORPUS="$WS/excl3corpus"; EXCL3MAPS="$EXCL3CORPUS/60-Maps"
mkdir -p "$EXCL3CORPUS/notes" "$EXCL3MAPS/graph"
printf '# n\ncontent\n' > "$EXCL3CORPUS/notes/n.md"
printf '# derived node note\nminted by graphify\n' > "$EXCL3MAPS/graph/some-node.md"
printf '# stale MOC from a prior run\n' > "$EXCL3MAPS/excl3-map.md"
out=$( GRAPHIFY_MAP_BIN="$EXCL3BIN/graphify" PATH="$EXCL3BIN:$PATH" \
  bash "$SCRIPT" --name excl3test --corpus-root "$EXCL3CORPUS" --backend claude-cli \
  --maps-dir "$EXCL3MAPS/" --title "Excl3 Map" --slug excl3-map --corpus-tag excl3 2>&1 ); rc=$?
[ "$rc" -eq 0 ] || fail "T29 run exit 0 (got $rc): $out"
if grep -qF "60-Maps/graph/some-node.md" "$WS/excl3-scratch-listing.txt" 2>/dev/null; then
  fail "T29 derived-page leaked into the corpus with a trailing-slash --maps-dir (double-slash pattern no-op)"
else
  pass "T29 derived-page still excluded with a trailing-slash --maps-dir"
fi
if grep -qF "60-Maps/excl3-map.md" "$WS/excl3-scratch-listing.txt" 2>/dev/null; then
  fail "T29 the MOC leaked into the corpus with a trailing-slash --maps-dir (double-slash pattern no-op)"
else
  pass "T29 the MOC still excluded with a trailing-slash --maps-dir"
fi
# CodeRabbit App follow-up: a bare `[ -f ]` here would pass even if publish
# never ran at all (the pre-seeded stale MOC from setup, above, already
# satisfies existence). Assert the stale sentinel is GONE -- proof the
# publish step actually rewrote the file at the trimmed path, not proof of
# nothing.
if [ -f "$EXCL3MAPS/excl3-map.md" ] && ! grep -qF "stale MOC from a prior run" "$EXCL3MAPS/excl3-map.md" 2>/dev/null; then
  pass "T29 MOC republished (stale sentinel replaced) without a double slash in its path"
else
  fail "T29 MOC not republished at the expected (trimmed) path (missing, or still the stale sentinel)"
fi

# --- T30a (HIMMEL-1415 CR follow-up round 3, codex-adv-3): a CALLER-generated
# internal double slash must not defeat the exclusion. graphmap-cadence.sh
# accepts a --vault value that may itself end in "/" and constructs
# --maps-dir as "$VAULT/60-Maps" by naive concatenation -- if $VAULT already
# ends in "/", that produces an internal double slash the --maps-dir-only
# trailing-slash trim (T29) never sees (it isn't a trailing slash on
# --maps-dir itself; --corpus-root ends in "/", --maps-dir does not). Mirrors
# the exact repro: --corpus-root "$vault/" --maps-dir "$vault//60-Maps". ---
EXCL4BIN="$WS/excl4bin"; mkdir -p "$EXCL4BIN"
cat > "$EXCL4BIN/graphify" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "--version" ]; then printf 'graphify 0.0.0\n'; exit 0; fi
target=""
if [ "\$1" = "cluster-only" ]; then target="\$2"; else target="\$1"; fi
if [ "\$1" != "cluster-only" ]; then
  ( cd "\$target" && find . -type f -name '*.md' | sort ) > "$WS/excl4-scratch-listing.txt"
fi
mkdir -p "\$target/graphify-out"
printf '{"nodes":[],"links":[]}' > "\$target/graphify-out/graph.json"
cat > "\$target/graphify-out/GRAPH_REPORT.md" <<'RPT'
$REPORT_FIXTURE
RPT
exit 0
STUB
chmod +x "$EXCL4BIN/graphify"
CADENCE_VAULT="$WS/cadence-vault"
mkdir -p "$CADENCE_VAULT/notes" "$CADENCE_VAULT/60-Maps/graph"
printf '# n\ncontent\n' > "$CADENCE_VAULT/notes/n.md"
printf '# derived node note\nminted by graphify\n' > "$CADENCE_VAULT/60-Maps/graph/some-node.md"
printf '# stale MOC from a prior run\n' > "$CADENCE_VAULT/60-Maps/excl4-map.md"
printf '# Legit Maps Note\nhand-authored, not graphify output\n' > "$CADENCE_VAULT/60-Maps/legit-note.md"
CADENCE_VAULT_TS="$CADENCE_VAULT/"          # mimics `--vault /vault/`
CADENCE_MAPS_ARG="$CADENCE_VAULT_TS/60-Maps" # mimics `$VAULT/60-Maps` -> internal "//"
out=$( GRAPHIFY_MAP_BIN="$EXCL4BIN/graphify" PATH="$EXCL4BIN:$PATH" \
  bash "$SCRIPT" --name excl4test --corpus-root "$CADENCE_VAULT_TS" --backend claude-cli \
  --maps-dir "$CADENCE_MAPS_ARG" --title "Excl4 Map" --slug excl4-map --corpus-tag excl4 2>&1 ); rc=$?
[ "$rc" -eq 0 ] || fail "T30a run exit 0 (got $rc): $out"
if grep -qF "60-Maps/graph/some-node.md" "$WS/excl4-scratch-listing.txt" 2>/dev/null; then
  fail "T30a derived-page leaked into the corpus via a cadence-generated internal double slash"
else
  pass "T30a derived-page still excluded via a cadence-generated internal double slash"
fi
if grep -qF "60-Maps/excl4-map.md" "$WS/excl4-scratch-listing.txt" 2>/dev/null; then
  fail "T30a the MOC leaked into the corpus via a cadence-generated internal double slash"
else
  pass "T30a the MOC still excluded via a cadence-generated internal double slash"
fi
if grep -qF "60-Maps/legit-note.md" "$WS/excl4-scratch-listing.txt" 2>/dev/null; then
  pass "T30a a hand-authored maps-dir note still reaches the corpus despite the internal double slash"
else
  fail "T30a over-excluded: a legitimate maps-dir note was dropped from the corpus"
fi

# --- T30b (HIMMEL-1415 CR follow-up round 3): a DOUBLE trailing slash on
# --maps-dir (e.g. "60-Maps//") must be fully trimmed, not just one of the
# two -- pins that the trailing-slash trim is a loop, not a single `%/`. ---
EXCL5BIN="$WS/excl5bin"; mkdir -p "$EXCL5BIN"
cat > "$EXCL5BIN/graphify" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "--version" ]; then printf 'graphify 0.0.0\n'; exit 0; fi
target=""
if [ "\$1" = "cluster-only" ]; then target="\$2"; else target="\$1"; fi
if [ "\$1" != "cluster-only" ]; then
  ( cd "\$target" && find . -type f -name '*.md' | sort ) > "$WS/excl5-scratch-listing.txt"
fi
mkdir -p "\$target/graphify-out"
printf '{"nodes":[],"links":[]}' > "\$target/graphify-out/graph.json"
cat > "\$target/graphify-out/GRAPH_REPORT.md" <<'RPT'
$REPORT_FIXTURE
RPT
exit 0
STUB
chmod +x "$EXCL5BIN/graphify"
EXCL5CORPUS="$WS/excl5corpus"; EXCL5MAPS="$EXCL5CORPUS/60-Maps"
mkdir -p "$EXCL5CORPUS/notes" "$EXCL5MAPS/graph"
printf '# n\ncontent\n' > "$EXCL5CORPUS/notes/n.md"
printf '# derived node note\nminted by graphify\n' > "$EXCL5MAPS/graph/some-node.md"
printf '# stale MOC from a prior run\n' > "$EXCL5MAPS/excl5-map.md"
out=$( GRAPHIFY_MAP_BIN="$EXCL5BIN/graphify" PATH="$EXCL5BIN:$PATH" \
  bash "$SCRIPT" --name excl5test --corpus-root "$EXCL5CORPUS" --backend claude-cli \
  --maps-dir "$EXCL5MAPS//" --title "Excl5 Map" --slug excl5-map --corpus-tag excl5 2>&1 ); rc=$?
[ "$rc" -eq 0 ] || fail "T30b run exit 0 (got $rc): $out"
if grep -qF "60-Maps/graph/some-node.md" "$WS/excl5-scratch-listing.txt" 2>/dev/null; then
  fail "T30b derived-page leaked into the corpus with a double-trailing-slash --maps-dir"
else
  pass "T30b derived-page still excluded with a double-trailing-slash --maps-dir"
fi
if grep -qF "60-Maps/excl5-map.md" "$WS/excl5-scratch-listing.txt" 2>/dev/null; then
  fail "T30b the MOC leaked into the corpus with a double-trailing-slash --maps-dir"
else
  pass "T30b the MOC still excluded with a double-trailing-slash --maps-dir"
fi
# CodeRabbit App follow-up: a bare `[ -f ]` here would pass even if publish
# never ran at all (the pre-seeded stale MOC from setup, above, already
# satisfies existence). Assert the stale sentinel is GONE -- proof the
# publish step actually rewrote the file at the fully-trimmed path, not
# proof of nothing.
if [ -f "$EXCL5MAPS/excl5-map.md" ] && ! grep -qF "stale MOC from a prior run" "$EXCL5MAPS/excl5-map.md" 2>/dev/null; then
  pass "T30b MOC republished (stale sentinel replaced) without a lingering double slash in its path"
else
  fail "T30b MOC not republished at the expected (fully-trimmed) path (missing, or still the stale sentinel)"
fi

# --- T31 (HIMMEL-1421): relative-vs-absolute corpus-root/maps-dir spellings
# must still be recognized as CONTAINED. Mirrors the exact bypass repro from
# the ticket: `--corpus-root . --maps-dir "$PWD/60-Maps"` share no literal
# string prefix (one begins with ".", the other with an absolute path) even
# though maps-dir IS "./60-Maps" -- the OLD lexical-prefix check silently
# disabled the HIMMEL-1415 exclusion for exactly this spelling, reopening
# the derived-page feedback loop. ---
EXCL6BIN="$WS/excl6bin"; mkdir -p "$EXCL6BIN"
cat > "$EXCL6BIN/graphify" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "--version" ]; then printf 'graphify 0.0.0\n'; exit 0; fi
target=""
if [ "\$1" = "cluster-only" ]; then target="\$2"; else target="\$1"; fi
if [ "\$1" != "cluster-only" ]; then
  ( cd "\$target" && find . -type f -name '*.md' | sort ) > "$WS/excl6-scratch-listing.txt"
fi
mkdir -p "\$target/graphify-out"
printf '{"nodes":[],"links":[]}' > "\$target/graphify-out/graph.json"
cat > "\$target/graphify-out/GRAPH_REPORT.md" <<'RPT'
$REPORT_FIXTURE
RPT
exit 0
STUB
chmod +x "$EXCL6BIN/graphify"
EXCL6CORPUS="$WS/excl6corpus"; EXCL6MAPS="$EXCL6CORPUS/60-Maps"
mkdir -p "$EXCL6CORPUS/notes" "$EXCL6MAPS/graph"
printf '# n\ncontent\n' > "$EXCL6CORPUS/notes/n.md"
printf '# derived node note\nminted by graphify\n' > "$EXCL6MAPS/graph/some-node.md"
printf '# stale MOC from a prior run\n' > "$EXCL6MAPS/excl6-map.md"
printf '# Legit Maps Note\nhand-authored, not graphify output\n' > "$EXCL6MAPS/legit-note.md"
out=$( cd "$EXCL6CORPUS" && GRAPHIFY_MAP_BIN="$EXCL6BIN/graphify" PATH="$EXCL6BIN:$PATH" \
  bash "$SCRIPT" --name excl6test --corpus-root . --backend claude-cli \
  --maps-dir "$EXCL6CORPUS/60-Maps" --title "Excl6 Map" --slug excl6-map --corpus-tag excl6 2>&1 ); rc=$?
[ "$rc" -eq 0 ] || fail "T31 run exit 0 (got $rc): $out"
if grep -qF "60-Maps/graph/some-node.md" "$WS/excl6-scratch-listing.txt" 2>/dev/null; then
  fail "T31 derived-page leaked into the corpus with a relative --corpus-root + absolute --maps-dir pairing"
else
  pass "T31 derived-page still excluded with a relative --corpus-root + absolute --maps-dir pairing"
fi
if grep -qF "60-Maps/excl6-map.md" "$WS/excl6-scratch-listing.txt" 2>/dev/null; then
  fail "T31 the MOC leaked into the corpus with a relative --corpus-root + absolute --maps-dir pairing"
else
  pass "T31 the MOC still excluded with a relative --corpus-root + absolute --maps-dir pairing"
fi
if grep -qF "60-Maps/legit-note.md" "$WS/excl6-scratch-listing.txt" 2>/dev/null; then
  pass "T31 a hand-authored maps-dir note still reaches the corpus despite the relative/absolute pairing"
else
  fail "T31 over-excluded: a legitimate maps-dir note was dropped from the corpus"
fi

# --- Case-insensitive filesystem probe (HIMMEL-1421 CR round 1 addendum,
# codex-adv-4): T32/T33 below assert that a REAL case-variant --maps-dir
# spelling still resolves to the SAME on-disk directory as --corpus-root --
# true only on a case-insensitive filesystem (Windows/NTFS, default
# macOS). On a genuinely case-sensitive filesystem (Linux -- the public
# mirror's ubuntu shell-unit CI job), uppercasing the whole absolute tmp
# path produces a DIFFERENT, non-existent directory the exclusion can
# never legitimately match against the real corpus files, so those two
# tests would fail for real (not hang) and gate that CI job -- the exact
# failure class #543 is fixing separately, so this avoids adding a second
# instance rather than duplicating that fix here. Probed once, cheaply:
# write "x", stat "X" in a throwaway dir. The portable, OS-independent
# regression for the underlying containment logic itself (not tied to
# real on-disk case resolution) is T36 below, which forces the comparison
# via GRAPHIFY_FS_CASE_INSENSITIVE instead of relying on the real
# filesystem's behavior.
FS_PROBE_DIR="$WS/case-probe"; mkdir -p "$FS_PROBE_DIR"
printf 'x' > "$FS_PROBE_DIR/x"
if [ -f "$FS_PROBE_DIR/X" ]; then FS_IS_CASE_INSENSITIVE=1; else FS_IS_CASE_INSENSITIVE=0; fi

# --- T32 (HIMMEL-1421): Windows case variants (C:/Users vs c:/users) must
# still be recognized as CONTAINED -- NTFS is case-insensitive but the
# pre-fix `case` pattern prefix match was case-sensitive. --corpus-root is
# passed with its real spelling; --maps-dir is passed with its corpus-root
# PREFIX case-flipped (same physical directory, different bytes). Only
# meaningful on a case-insensitive filesystem -- see the probe above. ---
if [ "$FS_IS_CASE_INSENSITIVE" -ne 1 ]; then
  skip "T32 SKIPPED (filesystem is case-sensitive; this real-directory scenario needs a case-insensitive fs -- the comparison logic itself is covered portably by T36)"
else
EXCL7BIN="$WS/excl7bin"; mkdir -p "$EXCL7BIN"
cat > "$EXCL7BIN/graphify" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "--version" ]; then printf 'graphify 0.0.0\n'; exit 0; fi
target=""
if [ "\$1" = "cluster-only" ]; then target="\$2"; else target="\$1"; fi
if [ "\$1" != "cluster-only" ]; then
  ( cd "\$target" && find . -type f -name '*.md' | sort ) > "$WS/excl7-scratch-listing.txt"
fi
mkdir -p "\$target/graphify-out"
printf '{"nodes":[],"links":[]}' > "\$target/graphify-out/graph.json"
cat > "\$target/graphify-out/GRAPH_REPORT.md" <<'RPT'
$REPORT_FIXTURE
RPT
exit 0
STUB
chmod +x "$EXCL7BIN/graphify"
EXCL7CORPUS="$WS/excl7corpus"; EXCL7MAPS="$EXCL7CORPUS/60-Maps"
mkdir -p "$EXCL7CORPUS/notes" "$EXCL7MAPS/graph"
printf '# n\ncontent\n' > "$EXCL7CORPUS/notes/n.md"
printf '# derived node note\nminted by graphify\n' > "$EXCL7MAPS/graph/some-node.md"
printf '# stale MOC from a prior run\n' > "$EXCL7MAPS/excl7-map.md"
printf '# Legit Maps Note\nhand-authored, not graphify output\n' > "$EXCL7MAPS/legit-note.md"
EXCL7MAPS_ARG="$(printf '%s' "$EXCL7CORPUS" | tr '[:lower:]' '[:upper:]')/60-Maps"
out=$( GRAPHIFY_MAP_BIN="$EXCL7BIN/graphify" PATH="$EXCL7BIN:$PATH" \
  bash "$SCRIPT" --name excl7test --corpus-root "$EXCL7CORPUS" --backend claude-cli \
  --maps-dir "$EXCL7MAPS_ARG" --title "Excl7 Map" --slug excl7-map --corpus-tag excl7 2>&1 ); rc=$?
[ "$rc" -eq 0 ] || fail "T32 run exit 0 (got $rc): $out"
if grep -qF "60-Maps/graph/some-node.md" "$WS/excl7-scratch-listing.txt" 2>/dev/null; then
  fail "T32 derived-page leaked into the corpus with a case-variant --maps-dir prefix"
else
  pass "T32 derived-page still excluded with a case-variant --maps-dir prefix"
fi
if grep -qF "60-Maps/excl7-map.md" "$WS/excl7-scratch-listing.txt" 2>/dev/null; then
  fail "T32 the MOC leaked into the corpus with a case-variant --maps-dir prefix"
else
  pass "T32 the MOC still excluded with a case-variant --maps-dir prefix"
fi
if grep -qF "60-Maps/legit-note.md" "$WS/excl7-scratch-listing.txt" 2>/dev/null; then
  pass "T32 a hand-authored maps-dir note still reaches the corpus despite the case-variant prefix"
else
  fail "T32 over-excluded: a legitimate maps-dir note was dropped from the corpus"
fi
fi

# --- T33 (HIMMEL-1421): the THREE required regressions TOGETHER --
# relative-vs-absolute, case variants, AND a metacharacter/space-laden path
# -- is exactly the combination that broke the python3-round-trip attempt
# tried on the HIMMEL-1415 branch (MSYS's argv-to-Windows-path translation
# resolved --corpus-root/--maps-dir to DIFFERENT drive roots for a maps-dir
# containing "[", silently disabling the exclusion -- observed live, T28).
# --corpus-root is relative ("."), --maps-dir is absolute with its
# corpus-root prefix case-flipped, and the maps-dir/slug both carry "[" "]"
# and a space. Proves the pure-bash cd/pwd -P canonicalization survives the
# combination the python3 approach could not. Only meaningful on a
# case-insensitive filesystem -- see the probe above T32. ---
if [ "$FS_IS_CASE_INSENSITIVE" -ne 1 ]; then
  skip "T33 SKIPPED (filesystem is case-sensitive; this real-directory scenario needs a case-insensitive fs -- the comparison logic itself is covered portably by T36)"
else
EXCL8BIN="$WS/excl8bin"; mkdir -p "$EXCL8BIN"
cat > "$EXCL8BIN/graphify" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "--version" ]; then printf 'graphify 0.0.0\n'; exit 0; fi
target=""
if [ "\$1" = "cluster-only" ]; then target="\$2"; else target="\$1"; fi
if [ "\$1" != "cluster-only" ]; then
  ( cd "\$target" && find . -type f -name '*.md' | sort ) > "$WS/excl8-scratch-listing.txt"
fi
mkdir -p "\$target/graphify-out"
printf '{"nodes":[],"links":[]}' > "\$target/graphify-out/graph.json"
cat > "\$target/graphify-out/GRAPH_REPORT.md" <<'RPT'
$REPORT_FIXTURE
RPT
exit 0
STUB
chmod +x "$EXCL8BIN/graphify"
EXCL8CORPUS="$WS/excl8corpus"
EXCL8SLUG='map-[v2] note'
EXCL8MAPS="$EXCL8CORPUS/60 [Maps v2]"
mkdir -p "$EXCL8CORPUS/notes" "$EXCL8MAPS/graph"
printf '# n\ncontent\n' > "$EXCL8CORPUS/notes/n.md"
printf '# derived node note\nminted by graphify\n' > "$EXCL8MAPS/graph/some-node.md"
printf '# stale MOC from a prior run\n' > "$EXCL8MAPS/$EXCL8SLUG.md"
printf '# Legit Maps Note\nhand-authored, not graphify output\n' > "$EXCL8MAPS/legit-note.md"
EXCL8MAPS_ARG="$(printf '%s' "$EXCL8CORPUS" | tr '[:lower:]' '[:upper:]')/60 [Maps v2]"
out=$( cd "$EXCL8CORPUS" && GRAPHIFY_MAP_BIN="$EXCL8BIN/graphify" PATH="$EXCL8BIN:$PATH" \
  bash "$SCRIPT" --name excl8test --corpus-root . --backend claude-cli \
  --maps-dir "$EXCL8MAPS_ARG" --title "Excl8 Map" --slug "$EXCL8SLUG" --corpus-tag excl8 2>&1 ); rc=$?
[ "$rc" -eq 0 ] || fail "T33 run exit 0 (got $rc): $out"
if grep -qF "60 [Maps v2]/graph/some-node.md" "$WS/excl8-scratch-listing.txt" 2>/dev/null; then
  fail "T33 derived-page leaked into the corpus under the combined relative+case+metachar spelling"
else
  pass "T33 derived-page still excluded under the combined relative+case+metachar spelling"
fi
if grep -qF "60 [Maps v2]/$EXCL8SLUG.md" "$WS/excl8-scratch-listing.txt" 2>/dev/null; then
  fail "T33 the MOC leaked into the corpus under the combined relative+case+metachar spelling"
else
  pass "T33 the MOC still excluded under the combined relative+case+metachar spelling"
fi
if grep -qF "60 [Maps v2]/legit-note.md" "$WS/excl8-scratch-listing.txt" 2>/dev/null; then
  pass "T33 a hand-authored maps-dir note still reaches the corpus under the combined spelling"
else
  fail "T33 over-excluded: a legitimate maps-dir note was dropped from the corpus"
fi
fi

# --- T34a (HIMMEL-1421): a maps-dir genuinely OUTSIDE corpus-root stays a
# SANCTIONED no-op (never an error) -- but when the two paths share no
# common prefix even after canonicalization AND were passed in different
# FORM CLASSES (one relative, one absolute), that's the ambiguous case the
# design calls out for a loud advisory instead of a silent no-op. Own
# GRAPHIFY_MAP_BIN/PATH stub (CR round 1 addendum, glm-4 sug): T31-T33 each
# set one explicitly; T34a/T34b previously relied on the global $BIN stub
# exported at the top of this file instead. ---
T34BIN="$WS/t34bin"; mkdir -p "$T34BIN"
cat > "$T34BIN/graphify" <<STUB
#!/usr/bin/env bash
target=""
if [ "\$1" = "cluster-only" ]; then target="\$2"; else target="\$1"; fi
mkdir -p "\$target/graphify-out"
printf '{"nodes":[],"links":[]}' > "\$target/graphify-out/graph.json"
cat > "\$target/graphify-out/GRAPH_REPORT.md" <<'RPT'
$REPORT_FIXTURE
RPT
exit 0
STUB
chmod +x "$T34BIN/graphify"
T34_OUTSIDE="$WS/t34-outside"; mkdir -p "$T34_OUTSIDE"
T34_CORPUS="$WS/t34-corpus"; mkdir -p "$T34_CORPUS/notes"
printf '# n\ncontent\n' > "$T34_CORPUS/notes/n.md"
out=$( cd "$T34_CORPUS" && GRAPHIFY_MAP_BIN="$T34BIN/graphify" PATH="$T34BIN:$PATH" \
  bash "$SCRIPT" --name t34a --corpus-root . --backend claude-cli \
  --maps-dir "$T34_OUTSIDE" --title "T34a Map" --slug t34a-map --corpus-tag t34a 2>&1 ); rc=$?
[ "$rc" -eq 0 ] || fail "T34a run exit 0 (got $rc; a genuinely-outside maps-dir must be a sanctioned no-op, not an error): $out"
if printf '%s' "$out" | grep -qF "WARN --corpus-root and --maps-dir share no common path"; then
  pass "T34a WARN advisory emitted for a no-prefix, mixed-form (relative vs absolute) corpus-root/maps-dir pair"
else
  fail "T34a expected a WARN advisory for the ambiguous mixed-form, no-overlap case; none seen: $out"
fi

# --- T34b: same no-overlap outside-maps-dir case, but SAME form class (both
# absolute) -- must stay a silent no-op with no advisory (the design
# constraint reserves the WARN for the mixed-form case only). ---
T34B_CORPUS="$WS/t34b-corpus"; mkdir -p "$T34B_CORPUS/notes"
printf '# n\ncontent\n' > "$T34B_CORPUS/notes/n.md"
out=$( GRAPHIFY_MAP_BIN="$T34BIN/graphify" PATH="$T34BIN:$PATH" \
  bash "$SCRIPT" --name t34b --corpus-root "$T34B_CORPUS" --backend claude-cli \
  --maps-dir "$T34_OUTSIDE" --title "T34b Map" --slug t34b-map --corpus-tag t34b 2>&1 ); rc=$?
[ "$rc" -eq 0 ] || fail "T34b run exit 0 (got $rc; a genuinely-outside maps-dir must be a sanctioned no-op, not an error): $out"
if printf '%s' "$out" | grep -qF "WARN --corpus-root and --maps-dir share no common path"; then
  fail "T34b unexpected WARN advisory for a same-form (both absolute), no-overlap corpus-root/maps-dir pair: $out"
else
  pass "T34b no WARN advisory for a same-form, no-overlap corpus-root/maps-dir pair (silent no-op, as designed)"
fi

# --- T35 (HIMMEL-1421 CR round 1, codex-1 + glm-3, sharpened by codex-adv):
# _canon_path's ancestor walk must TERMINATE for a maps-dir that can never
# resolve to an existing ancestor via forward-slash splitting -- a bare
# drive-absolute form with nothing beneath it, a backslash-form path (no
# "/" to strip at all), and (for completeness/pinning) a relative
# non-existent path. Each run is bounded by `timeout` -- a hang shows up
# as rc=124 (timeout's own "killed" exit code), not as a normal script
# failure, so the test itself would otherwise hang forever without the
# bound.
#
# CR round 2 (codex-r2-1): `timeout` is GNU coreutils and is NOT present by
# default on macOS (this repo's Bash-3.2/macOS compatibility floor, which
# this same CR round just went out of its way to protect elsewhere -- T35
# unconditionally requiring it would break the suite on exactly that
# floor). Probed once, cheaply, and SKIPPED (via skip(), not silently) when
# absent -- mirrors the T32/T33 filesystem-capability probe/skip pattern
# above. The loop-termination property stays guarded wherever `timeout` IS
# available (Linux/Windows CI, and any macOS box with GNU coreutils
# installed). A bash-native watchdog was considered instead (fork the run,
# background it, poll+kill on a deadline) but is a materially bigger diff
# for the same coverage this probe+skip already gets on the CI platforms
# that actually run this suite. ---
if ! command -v timeout >/dev/null 2>&1; then
  skip "T35a SKIPPED (no 'timeout' binary -- GNU coreutils, not present by default on macOS; loop-termination is still guarded on Linux/Windows CI)"
  skip "T35b SKIPPED (no 'timeout' binary -- GNU coreutils, not present by default on macOS; loop-termination is still guarded on Linux/Windows CI)"
  skip "T35c SKIPPED (no 'timeout' binary -- GNU coreutils, not present by default on macOS; loop-termination is still guarded on Linux/Windows CI)"
else
T35BIN="$WS/t35bin"; mkdir -p "$T35BIN"
cat > "$T35BIN/graphify" <<STUB
#!/usr/bin/env bash
target=""
if [ "\$1" = "cluster-only" ]; then target="\$2"; else target="\$1"; fi
mkdir -p "\$target/graphify-out"
printf '{"nodes":[],"links":[]}' > "\$target/graphify-out/graph.json"
cat > "\$target/graphify-out/GRAPH_REPORT.md" <<'RPT'
$REPORT_FIXTURE
RPT
exit 0
STUB
chmod +x "$T35BIN/graphify"
T35_CORPUS="$WS/t35-corpus"; mkdir -p "$T35_CORPUS/notes"
printf '# n\ncontent\n' > "$T35_CORPUS/notes/n.md"

# T35a: non-existent drive-absolute maps-dir -- the walk must shrink down
# to a bare "Q:" (no "/" left) and stop, not spin.
out=$( cd "$T35_CORPUS" && GRAPHIFY_MAP_BIN="$T35BIN/graphify" PATH="$T35BIN:$PATH" \
  timeout -k 5 20 bash "$SCRIPT" --name t35a --corpus-root "$T35_CORPUS" --backend claude-cli \
  --maps-dir "Q:/nope-1421/deeply/nested" --title "T35a Map" --slug t35a-map --corpus-tag t35a 2>&1 ); rc=$?
if [ "$rc" -eq 124 ]; then
  fail "T35a HUNG (timeout killed it, rc=124) on a non-existent drive-absolute --maps-dir"
elif [ "$rc" -eq 0 ]; then
  pass "T35a terminated (rc=0) on a non-existent drive-absolute --maps-dir"
elif printf '%s' "$out" | grep -qF "ENOENT" && printf '%s' "$out" | grep -qF "mkdir"; then
  # A non-existent DRIVE LETTER can never be created by Node's mkdirSync at
  # publish time (Windows has no notion of creating a new drive root) --
  # this is an EXPECTED, PROMPT downstream failure, not a hang. What T35a
  # actually verifies is termination of _canon_path's ancestor walk (the
  # loop-fix); success against an inherently uncreatable target is a
  # separate, unrelated property this test isn't making a claim about.
  pass "T35a terminated promptly (rc=$rc, expected ENOENT creating a non-existent drive at publish time) on a non-existent drive-absolute --maps-dir"
else
  fail "T35a terminated but with an unexpected failure (rc=$rc): $out"
fi

# T35b: backslash-form maps-dir -- _abs_path accepts it as already-absolute
# but the pre-fix walk only ever split on "/"; without the up-front
# backslash -> forward-slash normalization this never shrinks and spins
# forever.
out=$( cd "$T35_CORPUS" && GRAPHIFY_MAP_BIN="$T35BIN/graphify" PATH="$T35BIN:$PATH" \
  timeout -k 5 20 bash "$SCRIPT" --name t35b --corpus-root "$T35_CORPUS" --backend claude-cli \
  --maps-dir 'C:\nonexistent-1421-backslash\deep\path' --title "T35b Map" --slug t35b-map --corpus-tag t35b 2>&1 ); rc=$?
if [ "$rc" -eq 124 ]; then
  fail "T35b HUNG (timeout killed it, rc=124) on a backslash-form --maps-dir"
elif [ "$rc" -eq 0 ]; then
  pass "T35b terminated (rc=0) on a backslash-form --maps-dir"
else
  fail "T35b terminated but unexpectedly failed (rc=$rc): $out"
fi

# T35c: relative non-existent maps-dir -- already worked before this CR
# round (the walk always had forward slashes to strip via $PWD); pinned
# here so a future change to the walk can't silently regress it.
out=$( cd "$T35_CORPUS" && GRAPHIFY_MAP_BIN="$T35BIN/graphify" PATH="$T35BIN:$PATH" \
  timeout -k 5 20 bash "$SCRIPT" --name t35c --corpus-root . --backend claude-cli \
  --maps-dir "nonexistent-1421-rel/deeply/nested" --title "T35c Map" --slug t35c-map --corpus-tag t35c 2>&1 ); rc=$?
if [ "$rc" -eq 124 ]; then
  fail "T35c HUNG (timeout killed it, rc=124) on a relative non-existent --maps-dir"
elif [ "$rc" -eq 0 ]; then
  pass "T35c terminated (rc=0) on a relative non-existent --maps-dir"
else
  fail "T35c terminated but unexpectedly failed (rc=$rc): $out"
fi
fi

# --- T36 (HIMMEL-1421 CR round 1, codex-2, doubles as codex-adv-4's
# "comparison-level test"): on a case-SENSITIVE filesystem (this script
# also runs on ubuntu CI in the public mirror), the containment comparison
# must NOT fold case -- a maps-dir spelled with a different-case
# corpus-root prefix is a DIFFERENT path there, not the same directory.
# GRAPHIFY_FS_CASE_INSENSITIVE=0 forces the case-sensitive comparison
# branch deterministically and portably (this doesn't depend on the real
# filesystem's actual case behavior -- only on the forced flag -- so it
# runs identically on Windows/macOS/Linux, unlike T32/T33 above). Mirrors
# T32's case-variant setup but asserts the OPPOSITE outcome: the derived
# page must LEAK (not be excluded), proving a case-variant maps-dir prefix
# is correctly treated as a DIFFERENT, non-contained path when folding is
# off. ---
EXCL10BIN="$WS/excl10bin"; mkdir -p "$EXCL10BIN"
cat > "$EXCL10BIN/graphify" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "--version" ]; then printf 'graphify 0.0.0\n'; exit 0; fi
target=""
if [ "\$1" = "cluster-only" ]; then target="\$2"; else target="\$1"; fi
if [ "\$1" != "cluster-only" ]; then
  ( cd "\$target" && find . -type f -name '*.md' | sort ) > "$WS/excl10-scratch-listing.txt"
fi
mkdir -p "\$target/graphify-out"
printf '{"nodes":[],"links":[]}' > "\$target/graphify-out/graph.json"
cat > "\$target/graphify-out/GRAPH_REPORT.md" <<'RPT'
$REPORT_FIXTURE
RPT
exit 0
STUB
chmod +x "$EXCL10BIN/graphify"
EXCL10CORPUS="$WS/excl10corpus"; EXCL10MAPS="$EXCL10CORPUS/60-Maps"
mkdir -p "$EXCL10CORPUS/notes" "$EXCL10MAPS/graph"
printf '# n\ncontent\n' > "$EXCL10CORPUS/notes/n.md"
printf '# derived node note\nminted by graphify\n' > "$EXCL10MAPS/graph/some-node.md"
printf '# stale MOC from a prior run\n' > "$EXCL10MAPS/excl10-map.md"
# HIMMEL-1444: case-flip ONLY the corpus-root subdir under the writable $WS
# temp root, not the whole $WS path. The original uppercased the entire
# absolute path, rooting the publish target at "/TMP" (uppercased "/tmp") --
# non-creatable for a non-root user on a case-SENSITIVE filesystem (the public
# mirror's ubuntu CI), so publish-graph-map.mjs's recursive mkdirSync died with
# EACCES and refresh-graph-map.sh exited 1 (the "pull-before-regenerate
# skipped ... not a clean git toplevel" line above is an unrelated advisory --
# these corpora aren't git repos on either platform). Flipping just the subdir
# keeps the case-variant prefix the containment comparison exercises (still a
# DIFFERENT path when folding is forced off) while leaving the publish target
# creatable on every platform. On a case-insensitive fs the flipped spelling
# resolves to the same real dir, so the publish target there is unchanged.
EXCL10MAPS_ARG="$WS/$(printf '%s' "${EXCL10CORPUS##*/}" | tr '[:lower:]' '[:upper:]')/60-Maps"
out=$( GRAPHIFY_FS_CASE_INSENSITIVE=0 GRAPHIFY_MAP_BIN="$EXCL10BIN/graphify" PATH="$EXCL10BIN:$PATH" \
  bash "$SCRIPT" --name excl10test --corpus-root "$EXCL10CORPUS" --backend claude-cli \
  --maps-dir "$EXCL10MAPS_ARG" --title "Excl10 Map" --slug excl10-map --corpus-tag excl10 2>&1 ); rc=$?
[ "$rc" -eq 0 ] || fail "T36 run exit 0 (got $rc): $out"
if grep -qF "60-Maps/graph/some-node.md" "$WS/excl10-scratch-listing.txt" 2>/dev/null; then
  pass "T36 derived-page LEAKS into the corpus on the forced case-sensitive branch (case-variant prefix correctly treated as a DIFFERENT, non-contained path)"
else
  fail "T36 over-excluded: the forced case-sensitive comparison wrongly treated a case-variant maps-dir prefix as contained"
fi

# --- T38 (HIMMEL-1421 CR round 3, [codex-1]): _fs_case_insensitive now
# PROBES the corpus filesystem instead of trusting OS type. Assert the
# predicate's decision AGREES with an independent write-"x"/stat-"X" probe
# of the test workspace (FS_IS_CASE_INSENSITIVE, set once near T32 above):
# with GRAPHIFY_FS_CASE_INSENSITIVE UNSET (so the real probe decides, not a
# forced branch), a case-variant --maps-dir prefix must be treated as
# CONTAINED -- derived page excluded -- iff the workspace filesystem is
# actually case-insensitive, and as a DIFFERENT non-contained path -- derived
# page leaks -- iff it is case-sensitive. Portable: it asserts AGREEMENT
# with the real filesystem, not a fixed value, so it runs (and passes) on
# Windows, macOS, AND Linux CI without skipping -- unlike T32/T33, which
# skip on a case-sensitive fs. This is the direct regression for the
# probe-first path the round-3 rework introduced. ---
EXCL11BIN="$WS/excl11bin"; mkdir -p "$EXCL11BIN"
cat > "$EXCL11BIN/graphify" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "--version" ]; then printf 'graphify 0.0.0\n'; exit 0; fi
target=""
if [ "\$1" = "cluster-only" ]; then target="\$2"; else target="\$1"; fi
if [ "\$1" != "cluster-only" ]; then
  ( cd "\$target" && find . -type f -name '*.md' | sort ) > "$WS/excl11-scratch-listing.txt"
fi
mkdir -p "\$target/graphify-out"
printf '{"nodes":[],"links":[]}' > "\$target/graphify-out/graph.json"
cat > "\$target/graphify-out/GRAPH_REPORT.md" <<'RPT'
$REPORT_FIXTURE
RPT
exit 0
STUB
chmod +x "$EXCL11BIN/graphify"
EXCL11CORPUS="$WS/excl11corpus"; EXCL11MAPS="$EXCL11CORPUS/60-Maps"
mkdir -p "$EXCL11CORPUS/notes" "$EXCL11MAPS/graph"
printf '# n\ncontent\n' > "$EXCL11CORPUS/notes/n.md"
printf '# derived node note\nminted by graphify\n' > "$EXCL11MAPS/graph/some-node.md"
# HIMMEL-1444: same root-under-$WS case-flip as T36 -- see that test's comment.
EXCL11MAPS_ARG="$WS/$(printf '%s' "${EXCL11CORPUS##*/}" | tr '[:lower:]' '[:upper:]')/60-Maps"
# env -u scrubs any inherited override so the real filesystem probe decides;
# GNU/BSD/MSYS `env` all support -u. If env -u is somehow unavailable this
# still degrades correctly because nothing in this suite exports the var.
out=$( env -u GRAPHIFY_FS_CASE_INSENSITIVE GRAPHIFY_MAP_BIN="$EXCL11BIN/graphify" PATH="$EXCL11BIN:$PATH" \
  bash "$SCRIPT" --name excl11test --corpus-root "$EXCL11CORPUS" --backend claude-cli \
  --maps-dir "$EXCL11MAPS_ARG" --title "Excl11 Map" --slug excl11-map --corpus-tag excl11 2>&1 ); rc=$?
[ "$rc" -eq 0 ] || fail "T38 run exit 0 (got $rc): $out"
if [ "$FS_IS_CASE_INSENSITIVE" -eq 1 ]; then
  if grep -qF "60-Maps/graph/some-node.md" "$WS/excl11-scratch-listing.txt" 2>/dev/null; then
    fail "T38 derived-page LEAKED on a case-insensitive fs -- the probe-first predicate should have folded (case-variant prefix must read as contained) but did not"
  else
    pass "T38 derived-page excluded on a case-insensitive fs -- probe-first predicate AGREES with the independent write-x/stat-X probe"
  fi
else
  if grep -qF "60-Maps/graph/some-node.md" "$WS/excl11-scratch-listing.txt" 2>/dev/null; then
    pass "T38 derived-page leaks on a case-sensitive fs -- probe-first predicate AGREES with the independent write-x/stat-X probe (no fold; case-variant prefix is a different, non-contained path)"
  else
    fail "T38 over-excluded on a case-sensitive fs -- the probe-first predicate should NOT have folded (case-variant prefix is a different path) but treated it as contained"
  fi
fi

# --- T39 (HIMMEL-1421 CR round 4, [codex-r4-2]): a stale UPPERCASE probe
# leftover (.GRAPHIFY-FS-PROBE-<pid>-0-X) from a crashed prior run must NOT
# poison the verdict -- the candidate whose uppercase twin already exists
# must be SKIPPED, and the probe must still agree with the real filesystem.
# _fs_case_insensitive is a NESTED function inside _corpus_clean (not
# sourceable in isolation), and a child `bash "$SCRIPT"` has its own
# unknowable $$, so an end-to-end poison can never deterministically land on
# the child's candidate-0 twin. So this exercises the production probe loop
# in THIS shell (shared, known $$) on a poisoned corpus -- a faithful mirror
# of refresh-graph-map.sh's _fs_case_insensitive loop; keep the two in sync.
# It asserts (a) candidate 0 is SKIPPED (the loop lands on a later suffix)
# and (b) the verdict still AGREES with the independent write-x/stat-X
# reference probe (FS_IS_CASE_INSENSITIVE) with the poisoned twin present.
# Portable -- passes on case-insensitive AND case-sensitive filesystems: on
# the former the poisoned uppercase name IS the lowercase inode (the
# existence check still rejects candidate 0); on the latter it is a separate
# file (the twin check rejects it). ---
T39PROBE="$WS/excl12probe"; mkdir -p "$T39PROBE"
# Poison candidate 0's UPPERCASE twin with THIS shell's $$ (the in-shell
# replica loop below uses the same $$). This is exactly the [codex-r4-2]
# hazard: a leftover a crashed prior run (possibly with a reused PID) leaves
# behind that a single-shot probe would mistake for case-insensitivity.
printf 'stale' > "$T39PROBE/$(printf '%s' ".graphify-fs-probe-$$-0-x" | tr '[:lower:]' '[:upper:]')"
unset GRAPHIFY_FS_CASE_INSENSITIVE
CORPUS_ROOT_CANON="$T39PROBE"
_GRAPHIFY_FS_CASE=""
suffix_used=""
probe_lo=""; probe_up=""; i=""
# --- in-process mirror of refresh-graph-map.sh _fs_case_insensitive loop ---
for i in 0 1 2 3 4 5 6 7 8 9; do
  probe_lo="$CORPUS_ROOT_CANON/.graphify-fs-probe-$$-$i-x"
  probe_up="$CORPUS_ROOT_CANON/$(printf '%s' ".graphify-fs-probe-$$-$i-x" | tr '[:lower:]' '[:upper:]')"
  if [ -e "$probe_lo" ] || [ -L "$probe_lo" ] \
     || [ -e "$probe_up" ] || [ -L "$probe_up" ]; then
    continue
  fi
  if ( umask 077; set -C; printf 'x' > "$probe_lo" ) 2>/dev/null; then
    if [ -e "$probe_up" ]; then
      _GRAPHIFY_FS_CASE=1
    else
      _GRAPHIFY_FS_CASE=0
    fi
    suffix_used="$i"
    rm -f "$probe_lo" 2>/dev/null || true
    break
  fi
done
# Sweep the poison + any stray candidate file (case-insensitive fs: the two
# names are one inode; case-sensitive fs: only the uppercase poison lingers,
# the chosen lowercase file was already removed above).
rm -f "$T39PROBE/.GRAPHIFY-FS-PROBE-$$-0-X" "$T39PROBE/.graphify-fs-probe-$$-0-x" 2>/dev/null || true
if [ -z "$suffix_used" ] || [ "$suffix_used" -eq 0 ]; then
  fail "T39 stale-uppercase leftover was NOT skipped (probe landed on suffix '${suffix_used:-<none>}'); candidate 0 should have been rejected by the both-twins-absent check"
elif [ "$_GRAPHIFY_FS_CASE" -ne "$FS_IS_CASE_INSENSITIVE" ]; then
  fail "T39 probe verdict ($_GRAPHIFY_FS_CASE) DISAGREES with the independent write-x/stat-X reference probe ($FS_IS_CASE_INSENSITIVE) with a poisoned candidate-0 twin present"
else
  pass "T39 stale-uppercase probe leftover skipped (landed on suffix $suffix_used) and verdict ($_GRAPHIFY_FS_CASE) AGREES with the reference probe -- [codex-r4-2] hazard closed"
fi
unset probe_lo probe_up i suffix_used _GRAPHIFY_FS_CASE CORPUS_ROOT_CANON

# --- T40 (HIMMEL-1748): native Kimi backend key wiring, backend passthrough,
# scheduled-path egress preflight, and one allow+log ledger line per run. Run the
# missing-key case from a separate git repo whose .env deliberately lacks the key
# so the primary checkout's real .env cannot satisfy the hermetic negative case. ---
KENVROOT="$WS/kimi-env-root"; mkdir -p "$KENVROOT"
git -C "$KENVROOT" init -q 2>/dev/null
printf 'UNRELATED_KEY=stub\n' > "$KENVROOT/.env"
KCORPUS="$WS/kcorpus"; KMAPS="$WS/kmaps"; mkdir -p "$KCORPUS/notes" "$KMAPS"
printf '# kimi\ncontent\n' > "$KCORPUS/notes/a.md"
KMISSING_CALLS="$WS/kimi-missing-calls.log"; : > "$KMISSING_CALLS"
out=$( cd "$KENVROOT" && env -u MOONSHOT_API_KEY GRAPHIFY_CALL_LOG="$KMISSING_CALLS" GRAPHIFY_MAP_BIN="$BIN/graphify" \
  bash "$SCRIPT" --name kimi-missing --corpus-root "$KCORPUS" --backend kimi \
  --maps-dir "$KMAPS" --title "Kimi" --slug kimi-missing-map --corpus-tag kimi 2>&1 ); rc=$?
{ [ "$rc" -eq 1 ] && grep -q "MOONSHOT_API_KEY" <<< "$out" && [ ! -s "$KMISSING_CALLS" ]; } \
  && pass "T40a --backend kimi without MOONSHOT_API_KEY fails before graphify (rc=1)" \
  || fail "T40a missing MOONSHOT_API_KEY should fail rc=1 before graphify and name the key (got $rc): $out calls=$(cat "$KMISSING_CALLS")"

KCALLS="$WS/kimi-calls.log"; KLEDGER="$WS/kimi-ledger.jsonl"; : > "$KCALLS"; rm -f "$KLEDGER"
out=$( MOONSHOT_API_KEY=stub GRAPHIFY_LEDGER="$KLEDGER" GRAPHIFY_CALL_LOG="$KCALLS" \
  GRAPHIFY_MAP_BIN="$BIN/graphify" bash "$SCRIPT" --name kimi-ok --corpus-root "$KCORPUS" --backend kimi \
  --maps-dir "$KMAPS" --title "Kimi" --slug kimi-ok-map --corpus-tag kimi 2>&1 ); rc=$?
[ "$rc" -eq 0 ] || fail "T40b Kimi stub run exit 0 (got $rc): $out"
awk '/--backend kimi( |$)/ { found=1 } END { exit !found }' "$KCALLS" \
  && pass "T40b native --backend kimi passes through to graphify" \
  || fail "T40b Kimi backend did not reach graphify: $(cat "$KCALLS")"
kledger_lines=$(wc -l < "$KLEDGER" | tr -d ' ')
if [ "$kledger_lines" -eq 1 ] && grep -q '"provider":"moonshot"' "$KLEDGER" \
   && grep -q '"tool":"refresh-graph-map"' "$KLEDGER"; then
  pass "T40b Kimi appends exactly one Moonshot refresh-graph-map ledger line"
else
  fail "T40b expected one Moonshot refresh-graph-map ledger line (lines=$kledger_lines): $(cat "$KLEDGER" 2>/dev/null)"
fi

# Arbitrary input strings in a JSONL ledger entry must be JSON-escaped completely,
# including literal tab/newline/ESC bytes in the corpus path. One invocation still
# produces exactly one physical line, and that line must parse as JSON.
KCTRL_PARENT="$WS/kctrl"; mkdir -p "$KCTRL_PARENT"
KCTRL_CORPUS="$KCTRL_PARENT/$(printf 'corpus\tline\nbreak\033escape')"
KCTRL_MAPS="$WS/kctrl-maps"; mkdir -p "$KCTRL_MAPS"
# A literal tab/newline in a directory name is not a portable filesystem
# component (Windows NTFS / Git Bash rejects it -> mkdir fails). The ledger
# encoder must still handle such bytes as ARBITRARY INPUT, so on filesystems
# that allow them, seed the corpus and run the escaping assertion; on
# filesystems that reject them, skip cleanly rather than report a confusing
# escaping failure that is really an OS path limit (CR r5, finding 2).
if mkdir -p "$KCTRL_CORPUS/notes" 2>/dev/null; then
  printf '# controls\n' > "$KCTRL_CORPUS/notes/a.md"
  KCTRL_LEDGER="$WS/kctrl-ledger.jsonl"; rm -f "$KCTRL_LEDGER"
  # Stop after the preflight ledger with the failing graphify stub: a literal
  # newline is not a portable Windows output-path component, while the ledger
  # encoder itself must still handle it as arbitrary input.
  out=$( MOONSHOT_API_KEY=stub GRAPHIFY_LEDGER="$KCTRL_LEDGER" GRAPHIFY_MAP_BIN="$FAILBIN/graphify" \
    bash "$SCRIPT" --name kimi-controls --corpus-root "$KCTRL_CORPUS" --backend kimi \
    --maps-dir "$KCTRL_MAPS" --title "Kimi Controls" --slug kimi-controls 2>&1 ); rc=$?
  kctrl_lines=$(wc -l < "$KCTRL_LEDGER" | tr -d ' ')
  if [ "$rc" -eq 2 ] && [ "$kctrl_lines" -eq 1 ] \
     && grep -qF "$(printf '\\u%04x' 27)" "$KCTRL_LEDGER" \
     && node -e "JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'))" "$KCTRL_LEDGER"; then
    pass "T40b2 C0 control characters are escaped into one well-formed JSONL ledger line"
  else
    fail "T40b2 ledger escaping failed (rc=$rc lines=$kctrl_lines): $out"
  fi
else
  skip "T40b2 skipped: filesystem rejects control-char corpus paths (ledger escaping covered where allowed)"
fi

KCUSTOM_CALLS="$WS/kimi-custom-calls.log"; KCUSTOM_LEDGER="$WS/kimi-custom-ledger.jsonl"
: > "$KCUSTOM_CALLS"; rm -f "$KCUSTOM_LEDGER"
out=$( MOONSHOT_API_KEY=stub KIMI_BASE_URL=https://api.moonshot.ai.evil/v1 \
  GRAPHIFY_LEDGER="$KCUSTOM_LEDGER" GRAPHIFY_CALL_LOG="$KCUSTOM_CALLS" GRAPHIFY_MAP_BIN="$BIN/graphify" \
  bash "$SCRIPT" --name kimi-custom --corpus-root "$KCORPUS" --backend kimi \
  --maps-dir "$KMAPS" --title "Kimi" --slug kimi-custom-map --corpus-tag kimi 2>&1 ); rc=$?
{ [ "$rc" -eq 2 ] && grep -q "KIMI_BASE_URL is set to an unverified endpoint" <<< "$out" \
  && ! grep -q "api.moonshot.ai.evil" <<< "$out" \
  && [ ! -s "$KCUSTOM_CALLS" ] && [ ! -e "$KCUSTOM_LEDGER" ]; } \
  && pass "T40c scheduled Kimi rejects a Moonshot lookalike before ledger/graphify without echoing it" \
  || fail "T40c scheduled Kimi custom endpoint should fail rc=2 before ledger/graphify without URL disclosure (got $rc): $out calls=$(cat "$KCUSTOM_CALLS")"

# Both CN backend arms must fail closed before graphify dispatch when the selected
# corpus class has no ratified extraction cell.
for cn_backend in glm kimi; do
  KCALLS_DENY="$WS/${cn_backend}-deny-calls.log"; : > "$KCALLS_DENY"
  if [ "$cn_backend" = glm ]; then
    out=$( ANTHROPIC_API_KEY=stub ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic GRAPHIFY_CALL_LOG="$KCALLS_DENY" GRAPHIFY_MAP_BIN="$BIN/graphify" \
      bash "$SCRIPT" --name "${cn_backend}-deny" --corpus-root "$KCORPUS" --backend "$cn_backend" --corpus-class salus \
      --maps-dir "$KMAPS" --title "Deny" --slug "${cn_backend}-deny-map" 2>&1 ); rc=$?
  else
    out=$( MOONSHOT_API_KEY=stub GRAPHIFY_CALL_LOG="$KCALLS_DENY" GRAPHIFY_MAP_BIN="$BIN/graphify" \
      bash "$SCRIPT" --name "${cn_backend}-deny" --corpus-root "$KCORPUS" --backend "$cn_backend" --corpus-class salus \
      --maps-dir "$KMAPS" --title "Deny" --slug "${cn_backend}-deny-map" 2>&1 ); rc=$?
  fi
  { [ "$rc" -eq 2 ] && grep -q "egress matrix DENIES salus" <<< "$out" && [ ! -s "$KCALLS_DENY" ]; } \
    && pass "T40d $cn_backend denied corpus class fails closed before graphify" \
    || fail "T40d $cn_backend salus run should fail rc=2 before graphify (got $rc): $out calls=$(cat "$KCALLS_DENY")"
done

GLM_BAD_CALLS="$WS/glm-bad-calls.log"; GLM_BAD_LEDGER="$WS/glm-bad-ledger.jsonl"
: > "$GLM_BAD_CALLS"; rm -f "$GLM_BAD_LEDGER"
out=$( ANTHROPIC_API_KEY=stub ANTHROPIC_BASE_URL=https://evil.example/v1 \
  GRAPHIFY_LEDGER="$GLM_BAD_LEDGER" GRAPHIFY_CALL_LOG="$GLM_BAD_CALLS" GRAPHIFY_MAP_BIN="$BIN/graphify" \
  bash "$SCRIPT" --name glm-bad --corpus-root "$KCORPUS" --backend glm \
  --maps-dir "$KMAPS" --title "GLM" --slug glm-bad-map --corpus-tag glm 2>&1 ); rc=$?
{ [ "$rc" -eq 2 ] && grep -q "unverified GLM endpoint" <<< "$out" \
  && ! grep -q "evil.example" <<< "$out" \
  && [ ! -s "$GLM_BAD_CALLS" ] && [ ! -e "$GLM_BAD_LEDGER" ]; } \
  && pass "T40e scheduled GLM rejects a custom effective endpoint before ledger/graphify without echoing it" \
  || fail "T40e custom GLM endpoint should fail rc=2 before ledger/graphify without URL disclosure (got $rc): $out calls=$(cat "$GLM_BAD_CALLS")"

GLM_OK_CALLS="$WS/glm-ok-calls.log"; GLM_OK_LEDGER="$WS/glm-ok-ledger.jsonl"
: > "$GLM_OK_CALLS"; rm -f "$GLM_OK_LEDGER"
out=$( ANTHROPIC_API_KEY=stub ANTHROPIC_MODEL=glm-5.2 ANTHROPIC_BASE_URL='https://test-user:test-pass@api.z.ai:443/api/anthropic?token=secret-token' \
  GRAPHIFY_LEDGER="$GLM_OK_LEDGER" GRAPHIFY_CALL_LOG="$GLM_OK_CALLS" GRAPHIFY_MAP_BIN="$BIN/graphify" \
  bash "$SCRIPT" --name glm-ok --corpus-root "$KCORPUS" --backend glm \
  --maps-dir "$KMAPS" --title "GLM" --slug glm-ok-map --corpus-tag glm 2>&1 ); rc=$?
# HIMMEL-2224: luna-personal x zai-glm x extraction is explicit deny now, so this
# run fails CLOSED instead of proceeding. Both of this case's subjects survive the
# flip, and one of them gets STRONGER:
#   (1) REDACTION must still hold on the DENY path -- a deny message that echoed
#       the userinfo/path/query would leak credentials exactly as an allow one
#       would, and that path was previously untested.
#   (2) CLASSIFICATION is still proved, now by the deny naming zai-glm: a run
#       misclassified as `anthropic` would have hit luna-personal x anthropic =
#       allow and exited 0, so rc=2-naming-zai-glm discriminates just as the
#       ledger line used to. The allow+log LEDGER SHAPE for this producer stays
#       covered by the kimi case above ('"provider":"moonshot"').
{ [ "$rc" -eq 2 ] && [ ! -s "$GLM_OK_CALLS" ] \
  && grep -qF 'egress matrix DENIES luna-personal x zai-glm x extraction' <<< "$out" \
  && grep -qF 'claude backend @ https://api.z.ai (model glm-5.2)' <<< "$out" \
  && ! grep -qF 'test-user:test-pass' <<< "$out" && ! grep -qF '/api/anthropic' <<< "$out" \
  && ! grep -qF 'secret-token' <<< "$out"; } \
  && pass "T40f de-listed GLM endpoint denies before graphify, still redacting credentials/path/query (HIMMEL-2224)" \
  || fail "T40f de-listed GLM endpoint should deny rc=2 before graphify naming zai-glm, without URL disclosure (rc=$rc): $out"

GLM_HTTP_CALLS="$WS/glm-http-calls.log"; : > "$GLM_HTTP_CALLS"
out=$( ANTHROPIC_API_KEY=stub ANTHROPIC_BASE_URL=http://api.z.ai/api/anthropic \
  GRAPHIFY_CALL_LOG="$GLM_HTTP_CALLS" GRAPHIFY_MAP_BIN="$BIN/graphify" \
  bash "$SCRIPT" --name glm-http --corpus-root "$KCORPUS" --backend glm \
  --maps-dir "$KMAPS" --title "GLM" --slug glm-http-map --corpus-tag glm 2>&1 ); rc=$?
{ [ "$rc" -eq 2 ] && grep -q "unverified GLM endpoint" <<< "$out" \
  && ! grep -qF "http://api.z.ai" <<< "$out" && [ ! -s "$GLM_HTTP_CALLS" ]; } \
  && pass "T40g scheduled GLM rejects plaintext api.z.ai before graphify without echoing it" \
  || fail "T40g plaintext GLM endpoint should fail rc=2 before graphify without URL disclosure (got $rc): $out"

# --- T40h-l (HIMMEL-1748/HIMMEL-1084): scheduled claude/claude-cli resolve
# their effective ANTHROPIC_BASE_URL before any graphify call. Unknown endpoints
# are hard-denied on every corpus without echoing them; default Anthropic proceeds
# without a ledger; exact Z.ai is classified and ledgered; malformed hosts cannot
# collapse into the himmel-code wildcard allow. ---
CLAUDE_PREFLIGHT_CALLS="$WS/claude-preflight-calls.log"
CLAUDE_PREFLIGHT_LEDGER="$WS/claude-preflight-ledger.jsonl"
: > "$CLAUDE_PREFLIGHT_CALLS"; rm -f "$CLAUDE_PREFLIGHT_LEDGER"
out=$( ANTHROPIC_BASE_URL=https://evil.example/v1 GRAPHIFY_LEDGER="$CLAUDE_PREFLIGHT_LEDGER" \
  GRAPHIFY_CALL_LOG="$CLAUDE_PREFLIGHT_CALLS" GRAPHIFY_MAP_BIN="$BIN/graphify" \
  bash "$SCRIPT" --name claude-custom-deny --corpus-root "$KCORPUS" --backend claude-cli \
  --maps-dir "$KMAPS" --title "Claude" --slug claude-custom-deny-map 2>&1 ); rc=$?
{ [ "$rc" -eq 2 ] && grep -q "unverified endpoint" <<< "$out" \
  && ! grep -q "evil.example" <<< "$out" && [ ! -s "$CLAUDE_PREFLIGHT_CALLS" ]; } \
  && pass "T40h claude-cli custom endpoint fails closed before graphify without echoing the URL" \
  || fail "T40h claude-cli custom endpoint should fail rc=2 before graphify without URL disclosure (got $rc): $out calls=$(cat "$CLAUDE_PREFLIGHT_CALLS")"

: > "$CLAUDE_PREFLIGHT_CALLS"; rm -f "$CLAUDE_PREFLIGHT_LEDGER"
out=$( env -u ANTHROPIC_BASE_URL GRAPHIFY_LEDGER="$CLAUDE_PREFLIGHT_LEDGER" \
  GRAPHIFY_CALL_LOG="$CLAUDE_PREFLIGHT_CALLS" GRAPHIFY_MAP_BIN="$BIN/graphify" \
  bash "$SCRIPT" --name claude-default --corpus-root "$KCORPUS" --backend claude-cli \
  --maps-dir "$KMAPS" --title "Claude" --slug claude-default-map 2>&1 ); rc=$?
{ [ "$rc" -eq 0 ] && [ -s "$CLAUDE_PREFLIGHT_CALLS" ] && [ ! -e "$CLAUDE_PREFLIGHT_LEDGER" ]; } \
  && pass "T40i claude-cli default Anthropic endpoint proceeds without a ledger line" \
  || fail "T40i claude-cli default endpoint should proceed without ledger (rc=$rc): $out calls=$(cat "$CLAUDE_PREFLIGHT_CALLS") ledger=$(cat "$CLAUDE_PREFLIGHT_LEDGER" 2>/dev/null)"

: > "$CLAUDE_PREFLIGHT_CALLS"; rm -f "$CLAUDE_PREFLIGHT_LEDGER"
out=$( ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic GRAPHIFY_LEDGER="$CLAUDE_PREFLIGHT_LEDGER" \
  GRAPHIFY_CALL_LOG="$CLAUDE_PREFLIGHT_CALLS" GRAPHIFY_MAP_BIN="$BIN/graphify" \
  bash "$SCRIPT" --name claude-zai --corpus-root "$KCORPUS" --backend claude-cli \
  --maps-dir "$KMAPS" --title "Claude" --slug claude-zai-map 2>&1 ); rc=$?
# HIMMEL-2224: this case exists to prove claude-cli is classified by its EFFECTIVE
# ENDPOINT, not by its backend NAME (HIMMEL-1049). That proof gets STRONGER after
# the de-listing rather than weaker: luna-personal x anthropic is `allow`, so a run
# wrongly waved through as anthropic would exit 0 -- only correct zai-glm
# classification produces this deny. The discriminator moved from the ledger line
# to the verdict; no graphify call and no ledger line may be produced.
{ [ "$rc" -eq 2 ] && [ ! -s "$CLAUDE_PREFLIGHT_CALLS" ] && [ ! -e "$CLAUDE_PREFLIGHT_LEDGER" ] \
  && grep -qF 'egress matrix DENIES luna-personal x zai-glm x extraction' <<< "$out"; } \
  && pass "T40j claude-cli exact Z.ai endpoint is classified zai-glm and denied (HIMMEL-2224; anthropic would have allowed)" \
  || fail "T40j claude-cli Z.ai endpoint should deny rc=2 naming zai-glm, no call, no ledger (rc=$rc): $out ledger=$(cat "$CLAUDE_PREFLIGHT_LEDGER" 2>/dev/null)"

: > "$CLAUDE_PREFLIGHT_CALLS"; rm -f "$CLAUDE_PREFLIGHT_LEDGER"
out=$( ANTHROPIC_API_KEY=stub ANTHROPIC_BASE_URL=https://proxy.example/v1 GRAPHIFY_LEDGER="$CLAUDE_PREFLIGHT_LEDGER" \
  GRAPHIFY_CALL_LOG="$CLAUDE_PREFLIGHT_CALLS" GRAPHIFY_MAP_BIN="$BIN/graphify" \
  bash "$SCRIPT" --name claude-custom-code --corpus-root "$KCORPUS" --backend claude --corpus-class himmel-code \
  --maps-dir "$KMAPS" --title "Claude" --slug claude-custom-code-map 2>&1 ); rc=$?
{ [ "$rc" -eq 2 ] && grep -q "unverified endpoint" <<< "$out" \
  && ! grep -q "proxy.example" <<< "$out" && [ ! -s "$CLAUDE_PREFLIGHT_CALLS" ] \
  && [ ! -e "$CLAUDE_PREFLIGHT_LEDGER" ]; } \
  && pass "T40k himmel-code claude custom endpoint is refused before the wildcard allow" \
  || fail "T40k himmel-code claude custom endpoint should fail rc=2 before wildcard/graphify without URL disclosure (got $rc): $out calls=$(cat "$CLAUDE_PREFLIGHT_CALLS") ledger=$(cat "$CLAUDE_PREFLIGHT_LEDGER" 2>/dev/null)"

: > "$CLAUDE_PREFLIGHT_CALLS"; rm -f "$CLAUDE_PREFLIGHT_LEDGER"
out=$( ANTHROPIC_API_KEY=stub ANTHROPIC_BASE_URL=not-a-url GRAPHIFY_LEDGER="$CLAUDE_PREFLIGHT_LEDGER" \
  GRAPHIFY_CALL_LOG="$CLAUDE_PREFLIGHT_CALLS" GRAPHIFY_MAP_BIN="$BIN/graphify" \
  bash "$SCRIPT" --name claude-malformed-code --corpus-root "$KCORPUS" --backend claude --corpus-class himmel-code \
  --maps-dir "$KMAPS" --title "Claude" --slug claude-malformed-code-map 2>&1 ); rc=$?
{ [ "$rc" -eq 2 ] && grep -q "unverified endpoint" <<< "$out" \
  && ! grep -q "not-a-url" <<< "$out" && [ ! -s "$CLAUDE_PREFLIGHT_CALLS" ] \
  && [ ! -e "$CLAUDE_PREFLIGHT_LEDGER" ]; } \
  && pass "T40l malformed claude backend host is refused instead of collapsing into the himmel-code wildcard allow" \
  || fail "T40l malformed claude host should fail rc=2 before wildcard/graphify without value disclosure (got $rc): $out calls=$(cat "$CLAUDE_PREFLIGHT_CALLS") ledger=$(cat "$CLAUDE_PREFLIGHT_LEDGER" 2>/dev/null)"

# --- T41 (HIMMEL-1748): claude-cli model pin is unset-only. The stub captures
# the exported value on both graphify dispatches; unset defaults to sonnet,
# explicit empty opts back into the CLI default, and an operator value wins. ---
MODELBIN="$WS/modelbin"; mkdir -p "$MODELBIN"
MODELLOG="$WS/model-env.log"
cat > "$MODELBIN/graphify" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\${GRAPHIFY_CLAUDE_CLI_MODEL-__UNSET__}:\${CLAUDE_CODE_EFFORT_LEVEL-__UNSET__}" >> "$MODELLOG"
target=""
if [ "\$1" = "cluster-only" ]; then target="\$2"; else target="\$1"; fi
mkdir -p "\$target/graphify-out"
printf '{"nodes":[],"links":[]}' > "\$target/graphify-out/graph.json"
cat > "\$target/graphify-out/GRAPH_REPORT.md" <<'RPT'
$REPORT_FIXTURE
RPT
exit 0
STUB
chmod +x "$MODELBIN/graphify"
MODELCORPUS="$WS/modelcorpus"; MODELMAPS="$WS/modelmaps"; mkdir -p "$MODELCORPUS/notes" "$MODELMAPS"
printf '# model\ncontent\n' > "$MODELCORPUS/notes/a.md"
for model_case in unset empty haiku; do
  : > "$MODELLOG"
  # Each case also pins the EFFORT expectation (HIMMEL-1748 follow-up): unset
  # env defaults to low, an operator CLAUDE_CODE_EFFORT_LEVEL wins. The stub
  # logs "model:effort" per dispatch.
  case "$model_case" in
    unset) out=$( env -u GRAPHIFY_CLAUDE_CLI_MODEL -u CLAUDE_CODE_EFFORT_LEVEL GRAPHIFY_MAP_BIN="$MODELBIN/graphify" bash "$SCRIPT" \
      --name model-unset --corpus-root "$MODELCORPUS" --maps-dir "$MODELMAPS" --title Model --slug model-unset 2>&1 ); rc=$?; expected=sonnet:low ;;
    empty) out=$( env -u CLAUDE_CODE_EFFORT_LEVEL GRAPHIFY_CLAUDE_CLI_MODEL='' GRAPHIFY_MAP_BIN="$MODELBIN/graphify" bash "$SCRIPT" \
      --name model-empty --corpus-root "$MODELCORPUS" --maps-dir "$MODELMAPS" --title Model --slug model-empty 2>&1 ); rc=$?; expected=:low ;;
    haiku) out=$( GRAPHIFY_CLAUDE_CLI_MODEL=haiku CLAUDE_CODE_EFFORT_LEVEL=medium GRAPHIFY_MAP_BIN="$MODELBIN/graphify" bash "$SCRIPT" \
      --name model-haiku --corpus-root "$MODELCORPUS" --maps-dir "$MODELMAPS" --title Model --slug model-haiku 2>&1 ); rc=$?; expected=haiku:medium ;;
  esac
  # HIMMEL-1787 (PR #1680 round-4 deferral): the stub logs a line on BOTH
  # graphify dispatches (comment above -- refresh-graph-map.sh:404 exports
  # the model so the cluster-only labeling call inherits it), so checking
  # only `head -n 1` would still pass a regression that set the model for
  # the first dispatch only. Dedup with sort -u and require exactly ONE
  # distinct value across every logged line, equal to the expected value.
  got_lines=$(sort -u "$MODELLOG")
  got_count=$(printf '%s\n' "$got_lines" | grep -c .)
  { [ "$rc" -eq 0 ] && [ "$got_count" -eq 1 ] && [ "$got_lines" = "$expected" ]; } \
    && pass "T41 claude-cli model+effort case $model_case passes '$expected' on every dispatch" \
    || fail "T41 model+effort case $model_case expected '$expected' on every dispatch (got: $(tr '\n' '|' < "$MODELLOG"), rc=$rc): $out"
done

# --- T42 (HIMMEL-1748): dirty single-writer corpora are auto-committed before
# the freshness fetch, while an ordinary dirty corpus keeps the old skip behavior.
# A git wrapper forwards local probes/add/commit, stubs the network fetch and
# ff-only merge as successful, and logs the reached subcommands. ---
PULLBIN="$WS/pullbin"; mkdir -p "$PULLBIN"
PULLLOG="$WS/pull-git.log"; REAL_GIT_T42="$(command -v git)"
cat > "$PULLBIN/git" <<STUB
#!/usr/bin/env bash
sub=""; skip=0
for a in "\$@"; do
  if [ "\$skip" = 1 ]; then skip=0; continue; fi
  case "\$a" in
    -C|-c) skip=1 ;;
    -*) : ;;
    *) sub="\$a"; break ;;
  esac
done
printf '%s\n' "\$sub" >> "$PULLLOG"
case "\$sub" in
  fetch|merge) exit 0 ;;
  commit) [ "\${T42_COMMIT_FAIL:-0}" = 1 ] && exit 1; exec "$REAL_GIT_T42" "\$@" ;;
  *) exec "$REAL_GIT_T42" "\$@" ;;
esac
STUB
cat > "$PULLBIN/timeout" <<'STUB'
#!/usr/bin/env bash
[ "$1" = "-k" ] && shift 2
shift
exec "$@"
STUB
chmod +x "$PULLBIN/git" "$PULLBIN/timeout"
SWCORPUS="$WS/swcorpus"; SWMAPS="$WS/swmaps"; mkdir -p "$SWMAPS"
git_corpus "$SWCORPUS"
printf 'single writer\n' > "$SWCORPUS/.single-writer"
git -C "$SWCORPUS" add .single-writer >/dev/null 2>&1
git -C "$SWCORPUS" -c core.hooksPath=/dev/null commit -qm marker >/dev/null 2>&1
SW_HOOK_LOG="$WS/sw-hook.log"; : > "$SW_HOOK_LOG"
install_pre_commit "$SWCORPUS" <<STUB
#!/usr/bin/env bash
printf 'ran\n' >> "$SW_HOOK_LOG"
exit 0
STUB
printf '# dirty\n' > "$SWCORPUS/dirty.md"
: > "$PULLLOG"
out=$( PATH="$PULLBIN:$PATH" bash "$SCRIPT" --name sw --corpus-root "$SWCORPUS" --backend claude-cli \
  --maps-dir "$SWMAPS" --title SW --slug sw-map 2>&1 ); rc=$?
# The pre-pull auto-commit must track the formerly-dirty note, and the successful
# fake fetch/merge must reach the fast-forwarded advisory. The refresh itself
# then creates repo-local graphify-out/, so post-run whole-tree cleanliness is
# intentionally not asserted.
if [ "$rc" -eq 0 ] && grep -q "single-writer corpus was dirty" <<< "$out" \
   && grep -q "fast-forwarded" <<< "$out" && grep -qx commit "$PULLLOG" \
   && grep -qx fetch "$PULLLOG" && grep -qx merge "$PULLLOG" \
   && [ -s "$SW_HOOK_LOG" ] \
   && git -C "$SWCORPUS" ls-files --error-unmatch dirty.md >/dev/null 2>&1; then
  pass "T42a dirty .single-writer corpus auto-committed through hooks and freshness path fast-forwarded"
else
  fail "T42a single-writer pull path failed (rc=$rc): $out calls=$(cat "$PULLLOG") status=$(git -C "$SWCORPUS" status --porcelain)"
fi

NSWCORPUS="$WS/nswcorpus"; NSWMaps="$WS/nswmaps"; mkdir -p "$NSWMaps"
git_corpus "$NSWCORPUS"
printf '# dirty ordinary repo\n' > "$NSWCORPUS/dirty.md"
: > "$PULLLOG"
out=$( PATH="$PULLBIN:$PATH" bash "$SCRIPT" --name nsw --corpus-root "$NSWCORPUS" --backend claude-cli \
  --maps-dir "$NSWMaps" --title NSW --slug nsw-map 2>&1 ); rc=$?
if [ "$rc" -eq 0 ] && grep -q "not a clean git toplevel" <<< "$out" \
   && ! grep -qx add "$PULLLOG" && ! grep -qx commit "$PULLLOG" \
   && ! grep -qx fetch "$PULLLOG" && [ -f "$NSWCORPUS/dirty.md" ]; then
  pass "T42b dirty corpus without .single-writer still skips pull and preserves work"
else
  fail "T42b ordinary dirty corpus behavior changed (rc=$rc): $out calls=$(cat "$PULLLOG")"
fi

PSTCORPUS="$WS/pstcorpus"; PSTMAPS="$WS/pstmaps"; mkdir -p "$PSTMAPS"
git_corpus "$PSTCORPUS"
printf 'single writer\n' > "$PSTCORPUS/.single-writer"
git -C "$PSTCORPUS" add .single-writer >/dev/null 2>&1
git -C "$PSTCORPUS" -c core.hooksPath=/dev/null commit -qm marker >/dev/null 2>&1
printf '# staged\n' > "$PSTCORPUS/staged.md"
git -C "$PSTCORPUS" add staged.md >/dev/null 2>&1
printf '# dirty separate\n' > "$PSTCORPUS/dirty.md"
: > "$PULLLOG"
out=$( PATH="$PULLBIN:$PATH" bash "$SCRIPT" --name pst --corpus-root "$PSTCORPUS" --backend claude-cli \
  --maps-dir "$PSTMAPS" --title PST --slug pst-map 2>&1 ); rc=$?
if [ "$rc" -eq 0 ] && grep -q "index already has staged work" <<< "$out" \
   && ! grep -qx commit "$PULLLOG" && ! grep -qx fetch "$PULLLOG" \
   && git -C "$PSTCORPUS" diff --cached --name-only | grep -qx staged.md \
   && ! git -C "$PSTCORPUS" diff --cached --name-only | grep -qx dirty.md; then
  pass "T42c pre-staged single-writer index is preserved; auto-commit and pull are skipped"
else
  fail "T42c pre-staged work was mixed into auto-commit or pull path (rc=$rc): $out calls=$(cat "$PULLLOG")"
fi

CFCORPUS="$WS/cfcorpus"; CFMAPS="$WS/cfmaps"; mkdir -p "$CFMAPS"
git_corpus "$CFCORPUS"
printf 'single writer\n' > "$CFCORPUS/.single-writer"
git -C "$CFCORPUS" add .single-writer >/dev/null 2>&1
git -C "$CFCORPUS" -c core.hooksPath=/dev/null commit -qm marker >/dev/null 2>&1
printf '# commit failure\n' > "$CFCORPUS/dirty.md"
: > "$PULLLOG"
out=$( T42_COMMIT_FAIL=1 PATH="$PULLBIN:$PATH" bash "$SCRIPT" --name cf --corpus-root "$CFCORPUS" --backend claude-cli \
  --maps-dir "$CFMAPS" --title CF --slug cf-map 2>&1 ); rc=$?
if [ "$rc" -eq 0 ] && grep -q "restored the clean index" <<< "$out" \
   && grep -qx commit "$PULLLOG" && grep -qx reset "$PULLLOG" \
   && git -C "$CFCORPUS" diff --cached --quiet; then
  pass "T42d failed pre-pull commit restores the index before skipping freshness pull"
else
  fail "T42d failed commit left staging residue (rc=$rc): $out calls=$(cat "$PULLLOG") status=$(git -C "$CFCORPUS" status --porcelain)"
fi

# The auto-commit must run through the vault's real hooks. A rejecting pre-commit
# stands in for the vault gitleaks scan: rejection lands no commit, restores the
# formerly-clean index, skips the fetch, and remains a best-effort rc=0 refresh.
HKCORPUS="$WS/hkcorpus"; HKMAPS="$WS/hkmaps"; mkdir -p "$HKMAPS"
git_corpus "$HKCORPUS"
printf 'single writer\n' > "$HKCORPUS/.single-writer"
git -C "$HKCORPUS" add .single-writer >/dev/null 2>&1
git -C "$HKCORPUS" -c core.hooksPath=/dev/null commit -qm marker >/dev/null 2>&1
install_pre_commit "$HKCORPUS" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
printf '# rejected secret stand-in\n' > "$HKCORPUS/dirty.md"
hk_head_before=$(git -C "$HKCORPUS" rev-parse HEAD)
: > "$PULLLOG"
out=$( PATH="$PULLBIN:$PATH" bash "$SCRIPT" --name hk --corpus-root "$HKCORPUS" --backend claude-cli \
  --maps-dir "$HKMAPS" --title HK --slug hk-map 2>&1 ); rc=$?
hk_head_after=$(git -C "$HKCORPUS" rev-parse HEAD)
if [ "$rc" -eq 0 ] && [ "$hk_head_after" = "$hk_head_before" ] \
   && grep -q "restored the clean index" <<< "$out" \
   && grep -qx commit "$PULLLOG" && grep -qx reset "$PULLLOG" \
   && ! grep -qx fetch "$PULLLOG" && git -C "$HKCORPUS" diff --cached --quiet; then
  pass "T42e rejecting vault pre-commit hook blocks auto-commit, restores index, and skips pull"
else
  fail "T42e auto-commit bypassed or mishandled the rejecting hook (rc=$rc head=$hk_head_before->$hk_head_after): $out calls=$(cat "$PULLLOG") status=$(git -C "$HKCORPUS" status --porcelain)"
fi

# T42f (CR codex-adv r4): the sweep only runs on the corpus's DEFAULT branch —
# a vault temporarily on a PR-lane feature branch must not receive sweep
# commits there (.single-writer's commit-straight-to-main design is about main).
BRCORPUS="$WS/brcorpus"; BRMAPS="$WS/brmaps"; mkdir -p "$BRMAPS"
git_corpus "$BRCORPUS"
printf 'single writer\n' > "$BRCORPUS/.single-writer"
git -C "$BRCORPUS" add .single-writer >/dev/null 2>&1
git -C "$BRCORPUS" -c core.hooksPath=/dev/null commit -qm marker >/dev/null 2>&1
git -C "$BRCORPUS" checkout -qb pr-lane-work >/dev/null 2>&1
printf 'wip\n' > "$BRCORPUS/dirty.md"
br_head_before=$(git -C "$BRCORPUS" rev-parse HEAD)
: > "$PULLLOG"
out=$( PATH="$PULLBIN:$PATH" bash "$SCRIPT" --name br --corpus-root "$BRCORPUS" --backend claude-cli \
  --maps-dir "$BRMAPS" --title BR --slug br-map 2>&1 ); rc=$?
br_head_after=$(git -C "$BRCORPUS" rev-parse HEAD)
if [ "$rc" -eq 0 ] && [ "$br_head_after" = "$br_head_before" ] \
   && grep -q "not its default" <<< "$out" \
   && ! grep -qx commit "$PULLLOG"; then
  pass "T42f feature-branch single-writer corpus is not swept"
else
  fail "T42f sweep ran off the default branch (rc=$rc head=$br_head_before->$br_head_after): $out calls=$(cat "$PULLLOG")"
fi

# T42g (CR r5, finding 4): the pre-pull sweep is bounded by a GNU -k-capable
# timeout/gtimeout. When the functional probe at refresh-graph-map.sh:728 FAILS
# for BOTH (binary present but `timeout -k 1 1 true` nonzero, or absent), a dirty
# single-writer corpus on its default branch must SKIP the sweep (never run vault
# hooks unbounded), print the explicit "no 'timeout'/'gtimeout'" message, leave
# HEAD untouched, and pull nothing.
NTCORPUS="$WS/ntcorpus"; NTMAPS="$WS/ntmaps"; mkdir -p "$NTMAPS"
git_corpus "$NTCORPUS"
printf 'single writer\n' > "$NTCORPUS/.single-writer"
git -C "$NTCORPUS" add .single-writer >/dev/null 2>&1
git -C "$NTCORPUS" -c core.hooksPath=/dev/null commit -qm marker >/dev/null 2>&1
printf 'dirty\n' > "$NTCORPUS/dirty.md"
nt_head_before=$(git -C "$NTCORPUS" rev-parse HEAD)
# NOBIN: timeout + gtimeout present but failing the GNU -k functional probe, so
# refresh-graph-map's probe loop leaves timeout_bin empty.
NOBIN="$WS/nobin"; mkdir -p "$NOBIN"
printf '#!/usr/bin/env bash\nexit 1\n' > "$NOBIN/timeout"
printf '#!/usr/bin/env bash\nexit 1\n' > "$NOBIN/gtimeout"
chmod +x "$NOBIN/timeout" "$NOBIN/gtimeout"
: > "$PULLLOG"
out=$( PATH="$NOBIN:$PULLBIN:$PATH" bash "$SCRIPT" --name nt --corpus-root "$NTCORPUS" --backend claude-cli \
  --maps-dir "$NTMAPS" --title NT --slug nt-map 2>&1 ); rc=$?
nt_head_after=$(git -C "$NTCORPUS" rev-parse HEAD)
if [ "$rc" -eq 0 ] && [ "$nt_head_after" = "$nt_head_before" ] \
   && grep -q "no 'timeout'/'gtimeout'" <<< "$out" \
   && ! grep -qx commit "$PULLLOG" && ! grep -qx fetch "$PULLLOG"; then
  pass "T42g missing-timeout gate skips the single-writer sweep and prints the no-timeout message"
else
  fail "T42g missing-timeout gate should skip sweep + print message (rc=$rc head=$nt_head_before->$nt_head_after): $out calls=$(cat "$PULLLOG")"
fi

# T42h (HIMMEL-2245): T42a/T42e's hooks must not vanish when `git init` leaves
# no `.git/hooks/` (the template copy is not guaranteed — observed absent on a
# concurrent Windows full-corpus run, where the old bare `cat >` failed with
# ENOENT and both cases then went red on the hook's ABSENCE, blaming the code
# under test). install_pre_commit owns the directory; this pins that with the
# directory moved aside.
NHCORPUS="$WS/nhcorpus"; NHMAPS="$WS/nhmaps"; mkdir -p "$NHMAPS"
git_corpus "$NHCORPUS"
printf 'single writer\n' > "$NHCORPUS/.single-writer"
git -C "$NHCORPUS" add .single-writer >/dev/null 2>&1
git -C "$NHCORPUS" -c core.hooksPath=/dev/null commit -qm marker >/dev/null 2>&1
mv "$NHCORPUS/.git/hooks" "$NHCORPUS/.git/hooks-absent" 2>/dev/null
NH_HOOK_LOG="$WS/nh-hook.log"; : > "$NH_HOOK_LOG"
install_pre_commit "$NHCORPUS" <<STUB
#!/usr/bin/env bash
printf 'ran\n' >> "$NH_HOOK_LOG"
exit 0
STUB
printf '# dirty\n' > "$NHCORPUS/dirty.md"
: > "$PULLLOG"
out=$( PATH="$PULLBIN:$PATH" bash "$SCRIPT" --name nh --corpus-root "$NHCORPUS" --backend claude-cli \
  --maps-dir "$NHMAPS" --title NH --slug nh-map 2>&1 ); rc=$?
if [ "$rc" -eq 0 ] && [ -s "$NH_HOOK_LOG" ] \
   && git -C "$NHCORPUS" ls-files --error-unmatch dirty.md >/dev/null 2>&1; then
  pass "T42h fixture hook is installed even when git init left no .git/hooks"
else
  fail "T42h missing .git/hooks silently skipped the fixture hook (rc=$rc hooklog-bytes=$(wc -c < "$NH_HOOK_LOG")): $out calls=$(cat "$PULLLOG")"
fi

# T43 (CR codex-adv r4): a corpus root that classifies as SALUS BY PATH (a
# `.salus` marker here; phi-roots/denylist membership covered by the same
# helper) is refused BEFORE any egress or graphify call, regardless of the
# asserted --corpus-class — which deliberately defaults to luna-personal in
# this invocation: the mislabel under test.
SALCORPUS="$WS/salcorpus"; SALMAPS="$WS/salmaps"; mkdir -p "$SALCORPUS" "$SALMAPS"
printf 'phi note\n' > "$SALCORPUS/note.md"
: > "$SALCORPUS/.salus"
SALHOME="$WS/salhome"; mkdir -p "$SALHOME"
SALBIN="$WS/salbin"; mkdir -p "$SALBIN"; SALLOG="$WS/sal-calls.log"; : > "$SALLOG"
cat > "$SALBIN/graphify" <<STUB
#!/usr/bin/env bash
echo "\$@" >> "$SALLOG"
exit 0
STUB
chmod +x "$SALBIN/graphify"
out=$( HOME="$SALHOME" MOONSHOT_API_KEY=stub GRAPHIFY_MAP_BIN="$SALBIN/graphify" bash "$SCRIPT" \
  --name sal --corpus-root "$SALCORPUS" --backend kimi \
  --maps-dir "$SALMAPS" --title SAL --slug sal-map 2>&1 ); rc=$?
if [ "$rc" -eq 2 ] && grep -q "SALUS by path" <<< "$out" && [ ! -s "$SALLOG" ]; then
  pass "T43 salus-by-path corpus refused before any egress despite asserted class"
else
  fail "T43 salus path guard failed (rc=$rc): $out calls=$(cat "$SALLOG")"
fi

# T43b (CR r5, finding 5): the .salus marker (T43) is only the FIRST branch of
# _corpus_is_salus_root. The phi-roots/egress-denylist prefix-match loop at
# refresh-graph-map.sh:264-273 (with its backslash normalization at :269) must
# ALSO classify a corpus SALUS when it is LISTED in phi-roots -- with NO .salus
# marker at all. The phi-roots entry carries a backslash, so it matches ONLY
# after the backslash->slash normalization runs (exercising :269, not just :263).
PHICORPUS="$WS/phicorpus"; PHIMAPS="$WS/phimaps"; mkdir -p "$PHICORPUS" "$PHIMAPS"
printf 'phi note\n' > "$PHICORPUS/note.md"
PHIHOME="$WS/phihome"; mkdir -p "$PHIHOME/.config/claude-glm"
phi_canon="$(cd "$PHICORPUS" && pwd -P)"
# swap the final path separator for a backslash -> the entry matches only AFTER
# the backslash->slash normalization in _corpus_is_salus_root (:269).
printf '%s\n' "${phi_canon%/*}\\${phi_canon##*/}" > "$PHIHOME/.config/claude-glm/phi-roots"
PHIBIN="$WS/phibin"; mkdir -p "$PHIBIN"; PHILOG="$WS/phi-calls.log"; : > "$PHILOG"
cat > "$PHIBIN/graphify" <<STUB
#!/usr/bin/env bash
echo "\$@" >> "$PHILOG"
exit 0
STUB
chmod +x "$PHIBIN/graphify"
out=$( HOME="$PHIHOME" MOONSHOT_API_KEY=stub GRAPHIFY_MAP_BIN="$PHIBIN/graphify" bash "$SCRIPT" \
  --name phi --corpus-root "$PHICORPUS" --backend kimi \
  --maps-dir "$PHIMAPS" --title PHI --slug phi-map 2>&1 ); rc=$?
if [ "$rc" -eq 2 ] && grep -q "SALUS by path" <<< "$out" && [ ! -s "$PHILOG" ]; then
  pass "T43b phi-roots prefix-match (with backslash normalization) classifies a corpus SALUS before any egress"
else
  fail "T43b phi-roots path guard failed (rc=$rc): $out calls=$(cat "$PHILOG")"
fi

# T43c: fence parity requires a `.salus` marker on ANY ancestor, not only the
# selected corpus root. A scheduled refresh aimed at a vault subdirectory must
# still refuse before graphify.
SALANCESTOR="$WS/sal-ancestor"; SALNEST="$SALANCESTOR/nested/corpus"; SALNESTMAPS="$WS/sal-nested-maps"
mkdir -p "$SALNEST" "$SALNESTMAPS"
printf 'phi note\n' > "$SALNEST/note.md"
: > "$SALANCESTOR/.salus"
: > "$SALLOG"
out=$( HOME="$SALHOME" MOONSHOT_API_KEY=stub GRAPHIFY_MAP_BIN="$SALBIN/graphify" bash "$SCRIPT" \
  --name sal-nested --corpus-root "$SALNEST" --backend kimi \
  --maps-dir "$SALNESTMAPS" --title SAL --slug sal-nested-map 2>&1 ); rc=$?
if [ "$rc" -eq 2 ] && grep -q "SALUS by path" <<< "$out" && [ ! -s "$SALLOG" ]; then
  pass "T43c corpus nested below a .salus-marked ancestor is refused before graphify"
else
  fail "T43c ancestor .salus guard failed (rc=$rc): $out calls=$(cat "$SALLOG")"
fi

# T43d: the ancestor walk must not create a false positive for an ordinary
# corpus with no marker/config signal.
CLEANCORPUS="$WS/clean-corpus"; CLEANMAPS="$WS/clean-maps"; mkdir -p "$CLEANCORPUS" "$CLEANMAPS"
printf 'ordinary note\n' > "$CLEANCORPUS/note.md"
out=$( HOME="$SALHOME" MOONSHOT_API_KEY=stub GRAPHIFY_MAP_BIN="$BIN/graphify" bash "$SCRIPT" \
  --name clean --corpus-root "$CLEANCORPUS" --backend kimi \
  --maps-dir "$CLEANMAPS" --title Clean --slug clean-map 2>&1 ); rc=$?
[ "$rc" -eq 0 ] \
  && pass "T43d corpus with no salus signal still proceeds" \
  || fail "T43d clean corpus was falsely classified as salus (rc=$rc): $out"

# T43e: fence parity also requires an existing phi-roots/egress-denylist path
# that is not a readable regular file to deny, rather than silently acting like
# no PHI signal. A directory is the portable unreadable-policy fixture.
UNREADABLEHOME="$WS/unreadable-phi-home"; mkdir -p "$UNREADABLEHOME/.config/claude-glm/phi-roots"
UNREADABLECALLS="$WS/unreadable-phi-calls.log"; : > "$UNREADABLECALLS"
out=$( HOME="$UNREADABLEHOME" MOONSHOT_API_KEY=stub GRAPHIFY_CALL_LOG="$UNREADABLECALLS" \
  GRAPHIFY_MAP_BIN="$BIN/graphify" bash "$SCRIPT" \
  --name unreadable-phi --corpus-root "$CLEANCORPUS" --backend kimi \
  --maps-dir "$CLEANMAPS" --title Clean --slug unreadable-phi-map 2>&1 ); rc=$?
if [ "$rc" -eq 2 ] && grep -q "PHI root list.*not readable" <<< "$out" \
   && [ ! -s "$UNREADABLECALLS" ]; then
  pass "T43e existing unreadable phi-roots policy fails closed before graphify"
else
  fail "T43e unreadable phi-roots policy should fail rc=2 before graphify (rc=$rc): $out calls=$(cat "$UNREADABLECALLS")"
fi

# T43f/T43g/T43h (HIMMEL-1748 r4): the phi-roots prefix-match loop fails OPEN
# on untrimmed entries — on Windows Git Bash an operator config saved with CRLF
# line endings leaves a trailing \r on every entry, and a stray leading/trailing
# space does the same: the prefix pattern then never matches, a corpus that IS
# under a declared PHI root classifies non-SALUS, and the run PROCEEDS (PHI
# egresses). The guard must trim \r + surrounding whitespace (then the existing
# backslash/trailing-slash normalization) and skip entries left empty — an
# empty entry would prefix-match EVERY path.
CRLFHOME="$WS/crlf-phi-home"; mkdir -p "$CRLFHOME/.config/claude-glm"
CRLFPARENT="$WS/crlf-phi"; CRLFCORPUS="$CRLFPARENT/corpus"; CRLFMAPS="$WS/crlf-phi-maps"
mkdir -p "$CRLFCORPUS" "$CRLFMAPS"; printf 'phi note\n' > "$CRLFCORPUS/note.md"
crlf_canon="$(cd "$CRLFPARENT" && pwd -P)"
printf '# managed roots\r\n\r\n%s\r\n' "$crlf_canon" > "$CRLFHOME/.config/claude-glm/phi-roots"
CRLFBIN="$WS/crlf-phi-bin"; mkdir -p "$CRLFBIN"; CRLFLOG="$WS/crlf-phi-calls.log"; : > "$CRLFLOG"
cat > "$CRLFBIN/graphify" <<STUB
#!/usr/bin/env bash
echo "\$@" >> "$CRLFLOG"
exit 0
STUB
chmod +x "$CRLFBIN/graphify"
out=$( HOME="$CRLFHOME" MOONSHOT_API_KEY=stub GRAPHIFY_MAP_BIN="$CRLFBIN/graphify" bash "$SCRIPT" \
  --name crlf-phi --corpus-root "$CRLFCORPUS" --backend kimi \
  --maps-dir "$CRLFMAPS" --title PHI --slug crlf-phi-map 2>&1 ); rc=$?
if [ "$rc" -eq 2 ] && grep -q "SALUS by path" <<< "$out" && [ ! -s "$CRLFLOG" ]; then
  pass "T43f phi-roots saved with CRLF endings (ancestor entry + trailing \\r) classifies a corpus SALUS before any egress"
else
  fail "T43f CRLF phi-roots guard failed (rc=$rc): $out calls=$(cat "$CRLFLOG")"
fi

SPCHOME="$WS/space-phi-home"; mkdir -p "$SPCHOME/.config/claude-glm"
SPCPARENT="$WS/space-phi"; SPCCORPUS="$SPCPARENT/corpus"; SPCMAPS="$WS/space-phi-maps"
mkdir -p "$SPCCORPUS" "$SPCMAPS"; printf 'phi note\n' > "$SPCCORPUS/note.md"
spc_canon="$(cd "$SPCPARENT" && pwd -P)"
printf '   %s   \n' "$spc_canon" > "$SPCHOME/.config/claude-glm/phi-roots"
SPCBIN="$WS/space-phi-bin"; mkdir -p "$SPCBIN"; SPCLOG="$WS/space-phi-calls.log"; : > "$SPCLOG"
cat > "$SPCBIN/graphify" <<STUB
#!/usr/bin/env bash
echo "\$@" >> "$SPCLOG"
exit 0
STUB
chmod +x "$SPCBIN/graphify"
out=$( HOME="$SPCHOME" MOONSHOT_API_KEY=stub GRAPHIFY_MAP_BIN="$SPCBIN/graphify" bash "$SCRIPT" \
  --name space-phi --corpus-root "$SPCCORPUS" --backend kimi \
  --maps-dir "$SPCMAPS" --title PHI --slug space-phi-map 2>&1 ); rc=$?
if [ "$rc" -eq 2 ] && grep -q "SALUS by path" <<< "$out" && [ ! -s "$SPCLOG" ]; then
  pass "T43g phi-roots entry with leading/trailing spaces classifies a corpus SALUS before any egress"
else
  fail "T43g space-padded phi-roots guard failed (rc=$rc): $out calls=$(cat "$SPCLOG")"
fi

# T43h: trimming must not over-match — a phi-roots file holding ONLY blank/CRLF
# lines carries no entry at all, so an unrelated non-SALUS corpus still proceeds
# (an entry emptied by the trim is skipped, never compared as a "" prefix).
BLANKHOME="$WS/blank-phi-home"; mkdir -p "$BLANKHOME/.config/claude-glm"
printf '\r\n   \r\n\t\n' > "$BLANKHOME/.config/claude-glm/phi-roots"
BLANKCORPUS="$WS/blank-phi-corpus"; BLANKMAPS="$WS/blank-phi-maps"
mkdir -p "$BLANKCORPUS" "$BLANKMAPS"; printf 'ordinary note\n' > "$BLANKCORPUS/note.md"
out=$( HOME="$BLANKHOME" MOONSHOT_API_KEY=stub GRAPHIFY_MAP_BIN="$BIN/graphify" bash "$SCRIPT" \
  --name blank-phi --corpus-root "$BLANKCORPUS" --backend kimi \
  --maps-dir "$BLANKMAPS" --title Blank --slug blank-phi-map 2>&1 ); rc=$?
[ "$rc" -eq 0 ] \
  && pass "T43h whitespace-only phi-roots lines are skipped, not treated as a match-everything prefix" \
  || fail "T43h blank phi-roots lines must not classify an unrelated corpus SALUS (rc=$rc): $out"

# T44: an extraction backend without an egress-matrix provider mapping must
# fail closed before graphify. Publish-only --no-update remains unaffected.
UNKNOWNCORPUS="$WS/unknown-corpus"; UNKNOWNMAPS="$WS/unknown-maps"
mkdir -p "$UNKNOWNCORPUS" "$UNKNOWNMAPS"
printf 'ordinary note\n' > "$UNKNOWNCORPUS/note.md"
UNKNOWNCALLS="$WS/unknown-calls.log"; : > "$UNKNOWNCALLS"
out=$( HOME="$SALHOME" GRAPHIFY_CALL_LOG="$UNKNOWNCALLS" GRAPHIFY_MAP_BIN="$BIN/graphify" bash "$SCRIPT" \
  --name unknown --corpus-root "$UNKNOWNCORPUS" --backend unmapped-test \
  --maps-dir "$UNKNOWNMAPS" --title Unknown --slug unknown-map 2>&1 ); rc=$?
if [ "$rc" -eq 2 ] && grep -q "backend 'unmapped-test' has no egress-matrix provider mapping" <<< "$out" \
   && [ ! -s "$UNKNOWNCALLS" ]; then
  pass "T44a unknown backend extraction fails closed before graphify and names the backend"
else
  fail "T44a unknown backend should fail rc=2 before graphify and name itself (rc=$rc): $out calls=$(cat "$UNKNOWNCALLS")"
fi

UNKNOWNNOUPDATE="$WS/unknown-no-update"; UNKNOWNNOUPDATEMAPS="$WS/unknown-no-update-maps"
mkdir -p "$UNKNOWNNOUPDATE/graphify-out" "$UNKNOWNNOUPDATEMAPS"
printf '%s\n' "$REPORT_FIXTURE" > "$UNKNOWNNOUPDATE/graphify-out/GRAPH_REPORT.md"
out=$( HOME="$SALHOME" GRAPHIFY_MAP_BIN="$BIN/graphify" bash "$SCRIPT" \
  --name unknown-no-update --corpus-root "$UNKNOWNNOUPDATE" --backend unmapped-test \
  --maps-dir "$UNKNOWNNOUPDATEMAPS" --title Unknown --slug unknown-no-update-map --no-update 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && [ -f "$UNKNOWNNOUPDATEMAPS/unknown-no-update-map.md" ] \
  && pass "T44b unknown backend is unaffected on --no-update publish-only path" \
  || fail "T44b unknown backend --no-update should publish normally (rc=$rc): $out"

# --- T45 (HIMMEL-1902): artifact-level proof for the billed-retry fix. Run a
# one-file corpus through a stub graphify whose update call shells a stub
# `claude`, exactly where graphify's claude-cli backend would. The source user
# settings deliberately contain a SessionEnd hook. The chunk log must show the
# dedicated config reached the child with native auth + disableAllHooks + the
# bare floor, and contain ZERO SessionEnd lines. No real extraction/API call. ---
ARTHOME="$WS/artifact-home"; ARTCORPUS="$WS/artifact-corpus"; ARTMAPS="$WS/artifact-maps"
ARTBIN="$WS/artifact-bin"; ARTLOG="$WS/graphify-chunk.log"
mkdir -p "$ARTHOME/.claude" "$ARTCORPUS" "$ARTMAPS" "$ARTBIN"
printf 'artifact-subscription-auth\n' > "$ARTHOME/.claude/.credentials.json"
cat > "$ARTHOME/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "SessionEnd": [{"hooks": [{"type": "command", "command": "simulated-cancelled-hook"}]}]
  },
  "enabledPlugins": {"himmel-ops@himmel": true}
}
JSON
printf '# one file\nartifact fixture\n' > "$ARTCORPUS/only.md"
cat > "$ARTBIN/claude" <<'STUB'
#!/usr/bin/env bash
printf 'config=%s\n' "$CLAUDE_CONFIG_DIR"
node - "$CLAUDE_CONFIG_DIR" <<'NODE'
const fs = require('fs');
const dir = process.argv[2];
let settings = {};
try { settings = JSON.parse(fs.readFileSync(dir + '/settings.json', 'utf8')); } catch (_) {}
console.log('auth=' + (fs.existsSync(dir + '/.credentials.json') ? 'present' : 'missing'));
console.log('disableAllHooks=' + String(settings.disableAllHooks));
const floor = ['handover@himmel', 'himmel-ops@himmel', 'qmd@himmel'];
const plugins = settings.enabledPlugins || {};
const floorOnly = floor.every((id) => plugins[id] === true)
  && Object.entries(plugins).every(([id, enabled]) => floor.includes(id) ? enabled === true : enabled === false);
console.log('plugins=' + (floorOnly ? 'bare-floor' : 'unexpected'));
if (settings.disableAllHooks !== true || Object.hasOwn(settings, 'hooks')) {
  console.log('SessionEnd hook simulated-cancelled-hook exited 1: cancelled');
}
NODE
STUB
chmod +x "$ARTBIN/claude"
cat > "$ARTBIN/graphify" <<STUB
#!/usr/bin/env bash
target=""
if [ "\$1" = "cluster-only" ]; then
  target="\$2"
else
  target="\$1"
  # headless-claude-ok: hermetic PATH stub proves the graphify child config without an API call
  claude -p fixture > "$ARTLOG" 2>&1 || exit \$?
fi
mkdir -p "\$target/graphify-out"
printf '{"nodes":[],"links":[]}' > "\$target/graphify-out/graph.json"
cat > "\$target/graphify-out/GRAPH_REPORT.md" <<'RPT'
$REPORT_FIXTURE
RPT
exit 0
STUB
chmod +x "$ARTBIN/graphify"
out=$( HOME="$ARTHOME" PATH="$ARTBIN:$PATH" GRAPHIFY_MAP_BIN="$ARTBIN/graphify" \
  GRAPHIFY_CLAUDE_CONFIG_DIR="$ARTHOME/.claude-graphify" CADENCE_BANK_SKIP_REFRESH=1 \
  CADENCE_BANK_CACHE="$WS/no-bank-cache.json" GRAPHIFY_RUN_DEADLINE_SECONDS=0 \
  bash "$SCRIPT" --name artifact --corpus-root "$ARTCORPUS" --backend claude-cli \
  --maps-dir "$ARTMAPS" --title Artifact --slug artifact-map 2>&1 ); rc=$?
if [ "$rc" -eq 0 ] && [ -f "$ARTLOG" ] \
   && grep -q "config=$ARTHOME/.claude-graphify" "$ARTLOG" \
   && grep -q '^auth=present$' "$ARTLOG" \
   && grep -q '^disableAllHooks=true$' "$ARTLOG" \
   && grep -q '^plugins=bare-floor$' "$ARTLOG" \
   && ! grep -q 'SessionEnd' "$ARTLOG"; then
  pass "T45 graphify chunk artifact has native auth + bare plugins and zero SessionEnd hook lines"
else
  fail "T45 hook-free chunk artifact failed (rc=$rc): $out chunk-log=$(cat "$ARTLOG" 2>/dev/null)"
fi

# --- T37 (HIMMEL-1421 CR round 1 addendum, codex-adv-1): this repo's
# documented shell compatibility floor (outside a narrow exception list)
# is Bash 3.2 (macOS system bash), which does NOT support the
# `${var,,}`/`${var^^}` case-conversion expansions -- Bash 4+ only, "bad
# substitution" on 3.2, which would kill every refresh before extraction
# even started. shellcheck does not flag this (it's a version-gated
# feature, not a syntax error under shellcheck's default target).
# Grep-guard the whole script for the 4.x-only syntax (excluding comment
# lines, which legitimately reference the pattern as documentation of what
# NOT to do) so a future edit can't silently reintroduce it. ---
if grep -nE '\$\{[A-Za-z_][A-Za-z0-9_]*(,,|\^\^)' "$SCRIPT" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -q .; then
  fail "T37 refresh-graph-map.sh uses a Bash 4+-only \${var,,}/\${var^^} case-conversion expansion (breaks on Bash 3.2 / macOS system bash)"
else
  pass "T37 refresh-graph-map.sh contains no Bash 4+-only \${var,,}/\${var^^} case-conversion expansions"
fi


# --- T46 (HIMMEL-1960): GRAPHIFY_OUT must resolve the out dir, the promote
# lock and the corpus exclusion together. graphify itself reads
# GRAPHIFY_OUT (paths.py) and ast-update.sh mirrors that, so a hardcoded
# "graphify-out" here meant that under an override the semantic leg locked and
# wrote a DIFFERENT directory than the hourly structural leg -- the HIMMEL-1948
# serialization silently guarding nothing.
#
# SCOPE: these pin OUR script's handling, not graphify's resolution. T46a/T46c
# assert our validator's refusals and never reach graphify at all. T46b is the
# ONE upstream-coupled canary in this file: the base stub hardcodes
# graphify-out, so T46b brings its own fixture stub encoding graphify's rule
# (name from GRAPHIFY_OUT, joined under the target) and asserts that OUR
# promote lands under the configured name and never creates the default. If
# upstream ever changed that rule the fixture would be stale — which is what a
# named canary is for, and why there is exactly one. ---
GOBIN="$WS/go-bin"; mkdir -p "$GOBIN"
cat > "$GOBIN/graphify" <<STUB
#!/usr/bin/env bash
[ -n "\$GRAPHIFY_CALL_LOG" ] && printf '%s\n' "\$*" >> "\$GRAPHIFY_CALL_LOG"
target=""
if [ "\$1" = "cluster-only" ]; then target="\$2"; else target="\$1"; fi
# Model graphify/paths.py: out dir name comes from GRAPHIFY_OUT, joined under
# the target (a relative name; absolute is not exercised -- the script refuses
# it before graphify is ever called).
out="\$target/\${GRAPHIFY_OUT:-graphify-out}"
mkdir -p "\$out"
printf '{"nodes":[],"links":[]}' > "\$out/graph.json"
cat > "\$out/GRAPH_REPORT.md" <<'RPT'
$REPORT_FIXTURE
RPT
exit 0
STUB
chmod +x "$GOBIN/graphify"

# T46a: an ABSOLUTE GRAPHIFY_OUT is refused before any graphify call. This
# script extracts into a scratch COPY and promotes; an absolute out dir would
# make graphify write outside the scratch entirely, so honouring it would break
# "extraction never touches the live corpus". Refusing loudly is the contract.
GOCORPUS="$WS/gout-corpus"; GOMAPS="$WS/gout-maps"; mkdir -p "$GOCORPUS" "$GOMAPS"
printf '# note\ngraphify-out fixture\n' > "$GOCORPUS/note.md"
GOCALLS="$WS/gout-calls.log"; : > "$GOCALLS"
out=$( GRAPHIFY_OUT="$WS/somewhere-absolute" GRAPHIFY_CALL_LOG="$GOCALLS" \
  GRAPHIFY_MAP_BIN="$GOBIN/graphify" bash "$SCRIPT" \
  --name gout-abs --corpus-root "$GOCORPUS" --backend claude-cli \
  --maps-dir "$GOMAPS" --title GOut --slug gout-abs-map 2>&1 ); rc=$?
if [ "$rc" -eq 2 ] && grep -q "GRAPHIFY_OUT is an absolute path" <<< "$out" && [ ! -s "$GOCALLS" ]; then
  pass "T46a absolute GRAPHIFY_OUT is refused (rc=2) before graphify is called"
else
  fail "T46a absolute GRAPHIFY_OUT should fail rc=2 before graphify (rc=$rc): $out calls=$(cat "$GOCALLS")"
fi

# T46b: a RELATIVE GRAPHIFY_OUT is honoured end to end -- the graph is promoted
# under the OVERRIDDEN name, and the default directory is never created. The
# second half is the real assertion: creating <corpus>/graphify-out while
# graphify wrote elsewhere is exactly the desynchronised state this fixes.
GOCORPUS2="$WS/gout-corpus2"; GOMAPS2="$WS/gout-maps2"; mkdir -p "$GOCORPUS2" "$GOMAPS2"
printf '# note\ngraphify-out fixture two\n' > "$GOCORPUS2/note.md"
out=$( GRAPHIFY_OUT="graphify-out-alt" GRAPHIFY_MAP_BIN="$GOBIN/graphify" bash "$SCRIPT" \
  --name gout-rel --corpus-root "$GOCORPUS2" --backend claude-cli \
  --maps-dir "$GOMAPS2" --title GOut --slug gout-rel-map 2>&1 ); rc=$?
if [ "$rc" -eq 0 ] && [ -f "$GOCORPUS2/graphify-out-alt/graph.json" ] \
   && [ ! -e "$GOCORPUS2/graphify-out" ]; then
  pass "T46b [upstream canary] our promote lands under the configured out-dir name and never creates the default"
else
  fail "T46b relative GRAPHIFY_OUT (rc=$rc) alt=$( [ -f "$GOCORPUS2/graphify-out-alt/graph.json" ] && echo yes || echo no ) default-created=$( [ -e "$GOCORPUS2/graphify-out" ] && echo yes || echo no ): $out"
fi

# T46c: a GRAPHIFY_OUT that is not a plain relative NAME is refused. "." would
# resolve OUT_DIR onto the corpus root itself, and the value feeds a promote
# path and a `find -path` exclusion.
out=$( GRAPHIFY_OUT=".." GRAPHIFY_MAP_BIN="$GOBIN/graphify" bash "$SCRIPT" \
  --name gout-dots --corpus-root "$GOCORPUS" --backend claude-cli \
  --maps-dir "$GOMAPS" --title GOut --slug gout-dots-map 2>&1 ); rc=$?
[ "$rc" -eq 2 ] && grep -q "must be a single relative directory name" <<< "$out" \
  && pass "T46c a non-name GRAPHIFY_OUT ('..') is refused rc=2" \
  || fail "T46c '..' should be refused rc=2 (rc=$rc): $out"

# --- T47 (HIMMEL-1960 CR r8): the out dir must not be adopted from somebody's
# SOURCE directory. Accepting any well-formed name means GRAPHIFY_OUT=docs
# resolves OUT_DIR to <corpus>/docs, where the promote recursively deletes
# cache/ and removes manifest.json before dropping graph.json in. The refusal
# has to land BEFORE the extraction is paid for, so this also asserts graphify
# was never called. ---
GUARDCORPUS="$WS/guard-corpus"; GUARDMAPS="$WS/guard-maps"
mkdir -p "$GUARDCORPUS/docs" "$GUARDMAPS"
printf '# note\nguard fixture\n' > "$GUARDCORPUS/note.md"
printf 'real source content\n' > "$GUARDCORPUS/docs/handbook.md"
GUARDCALLS="$WS/guard-calls.log"; : > "$GUARDCALLS"
out=$( GRAPHIFY_OUT="docs" GRAPHIFY_CALL_LOG="$GUARDCALLS" GRAPHIFY_MAP_BIN="$GOBIN/graphify" \
  bash "$SCRIPT" --name guard --corpus-root "$GUARDCORPUS" --backend claude-cli \
  --maps-dir "$GUARDMAPS" --title Guard --slug guard-map 2>&1 ); rc=$?
if [ "$rc" -eq 2 ] && grep -q "REFUSING to use" <<< "$out" && [ ! -s "$GUARDCALLS" ]; then
  pass "T47a a non-empty source dir is refused as the out dir, before graphify runs"
else
  fail "T47a should refuse rc=2 before graphify (rc=$rc): $out calls=$(cat "$GUARDCALLS")"
fi
[ -f "$GUARDCORPUS/docs/handbook.md" ] \
  && pass "T47b the refused directory's contents are untouched" \
  || fail "T47b the guard must not modify the directory it refuses"

# T47b2: a source directory carrying GENERIC names must still be refused. The
# guard briefly accepted graph.json/manifest.json/cache as proof of ownership,
# so a corpus with docs/cache satisfied it under GRAPHIFY_OUT=docs and the
# promote would have destroyed that cache -- the guard passing on precisely the
# input it exists to stop.
GENERICCORPUS="$WS/guard-generic"; GENERICMAPS="$WS/guard-generic-maps"
mkdir -p "$GENERICCORPUS/docs/cache" "$GENERICMAPS"
printf '# note\ngeneric fixture\n' > "$GENERICCORPUS/note.md"
printf 'source cache entry\n' > "$GENERICCORPUS/docs/cache/entry.txt"
printf '{}\n' > "$GENERICCORPUS/docs/manifest.json"
GENERICCALLS="$WS/guard-generic-calls.log"; : > "$GENERICCALLS"
out=$( GRAPHIFY_OUT="docs" GRAPHIFY_CALL_LOG="$GENERICCALLS" GRAPHIFY_MAP_BIN="$GOBIN/graphify" \
  bash "$SCRIPT" --name guard-generic --corpus-root "$GENERICCORPUS" --backend claude-cli \
  --maps-dir "$GENERICMAPS" --title Guard --slug guard-generic-map 2>&1 ); rc=$?
if [ "$rc" -eq 2 ] && [ -f "$GENERICCORPUS/docs/cache/entry.txt" ] && [ ! -s "$GENERICCALLS" ]; then
  pass "T47b2 generic names (cache/, manifest.json) are not proof of graphify ownership"
else
  fail "T47b2 a source dir with generic names must still be refused (rc=$rc, cache survived=$( [ -f "$GENERICCORPUS/docs/cache/entry.txt" ] && echo yes || echo NO )): $out"
fi

# T47h: a single-segment GRAPHIFY_OUT whose path is a SYMLINK escapes the
# corpus -- the name check only proves the NAME is one segment, and `-d`
# follows the link, so the promote would write into (and delete graph-named
# content from) a directory outside the corpus. Skipped, loudly, where symlinks
# cannot be created (Git Bash without Developer Mode copies instead of links).
SYMPROBE2="$WS/symprobe2"; mkdir -p "$SYMPROBE2/target"
if ln -s "$SYMPROBE2/target" "$SYMPROBE2/link" 2>/dev/null && [ -L "$SYMPROBE2/link" ]; then
  SYMCORPUS="$WS/guard-symlink"; SYMMAPS="$WS/guard-symlink-maps"; SYMEXT="$WS/guard-symlink-external"
  mkdir -p "$SYMCORPUS" "$SYMMAPS" "$SYMEXT"
  printf '# note\nsymlink fixture\n' > "$SYMCORPUS/note.md"
  printf 'external content\n' > "$SYMEXT/keep.txt"
  ln -s "$SYMEXT" "$SYMCORPUS/outlink"
  SYMCALLS="$WS/guard-symlink-calls.log"; : > "$SYMCALLS"
  out=$( GRAPHIFY_OUT="outlink" GRAPHIFY_CALL_LOG="$SYMCALLS" GRAPHIFY_MAP_BIN="$GOBIN/graphify" \
    bash "$SCRIPT" --name guard-sym --corpus-root "$SYMCORPUS" --backend claude-cli \
    --maps-dir "$SYMMAPS" --title Guard --slug guard-sym-map 2>&1 ); rc=$?
  if [ "$rc" -eq 2 ] && [ -f "$SYMEXT/keep.txt" ] && [ ! -s "$SYMCALLS" ]; then
    pass "T47h a symlinked override is refused before graphify, external content untouched"
  else
    fail "T47h a symlinked override must be refused rc=2 (rc=$rc, external survived=$( [ -f "$SYMEXT/keep.txt" ] && echo yes || echo NO )): $out"
  fi
else
  skip "T47h SKIPPED (this environment cannot create symlinks -- unprivileged Windows without Developer Mode; guarded on POSIX CI)"
fi

# T47g: under an OVERRIDE, a leftover DEFAULT graphify-out/ must still be
# excluded from the corpus scan. The exclusion list used to be hardcoded to
# ./graphify-out/*; making it follow GRAPHIFY_OUT stopped excluding the default,
# so a corpus that had ever run with the default fed its own GRAPH_REPORT.md
# back into the next extraction as source content.
LEAKCORPUS="$WS/guard-leak"; LEAKMAPS="$WS/guard-leak-maps"
mkdir -p "$LEAKCORPUS/graphify-out" "$LEAKMAPS"
printf '# note\nleak fixture\n' > "$LEAKCORPUS/note.md"
printf '%s\n' "$REPORT_FIXTURE" > "$LEAKCORPUS/graphify-out/GRAPH_REPORT.md"
printf 'stale root\n' > "$LEAKCORPUS/graphify-out/.graphify_root"
out=$( GRAPHIFY_OUT="graphify-out-alt" GRAPHIFY_MAP_BIN="$GOBIN/graphify" bash "$SCRIPT" \
  --name guard-leak --corpus-root "$LEAKCORPUS" --backend claude-cli \
  --maps-dir "$LEAKMAPS" --title Guard --slug guard-leak-map 2>&1 ); rc=$?
if [ "$rc" -eq 0 ] && [ -f "$LEAKCORPUS/graphify-out-alt/manifest.json" ]; then
  python3 - "$LEAKCORPUS/graphify-out-alt/manifest.json" <<'PY' 2>/dev/null \
    && pass "T47g a leftover default graphify-out/ is excluded under an override" \
    || fail "T47g the default out dir leaked into the corpus scan under an override"
import json, sys
d = json.load(open(sys.argv[1]))
assert not any(k.startswith("graphify-out/") for k in d), "default graphify-out leaked into manifest keys"
assert not any(k.startswith("graphify-out-alt/") for k in d), "overridden out dir leaked into manifest keys"
PY
else
  fail "T47g run should succeed and write a manifest (rc=$rc): $out"
fi

# T47b3: `.graphify-corpus-ignore` (HIMMEL-1903, a CORPUS-side file this repo
# tells operators to create) must NOT read as proof of out-dir ownership. The
# guard briefly globbed `.graphify*`, which matched it -- so a source tree
# following this repo's own advice could be adopted and have its cache deleted.
IGNCORPUS="$WS/guard-ignorefile"; IGNMAPS="$WS/guard-ignorefile-maps"
mkdir -p "$IGNCORPUS/docs/cache" "$IGNMAPS"
printf '# note\nignore-file fixture\n' > "$IGNCORPUS/note.md"
printf 'sessions/\n' > "$IGNCORPUS/docs/.graphify-corpus-ignore"
printf 'source cache entry\n' > "$IGNCORPUS/docs/cache/entry.txt"
IGNCALLS="$WS/guard-ignorefile-calls.log"; : > "$IGNCALLS"
out=$( GRAPHIFY_OUT="docs" GRAPHIFY_CALL_LOG="$IGNCALLS" GRAPHIFY_MAP_BIN="$GOBIN/graphify" \
  bash "$SCRIPT" --name guard-ign --corpus-root "$IGNCORPUS" --backend claude-cli \
  --maps-dir "$IGNMAPS" --title Guard --slug guard-ign-map 2>&1 ); rc=$?
if [ "$rc" -eq 2 ] && [ -f "$IGNCORPUS/docs/cache/entry.txt" ] && [ ! -s "$IGNCALLS" ]; then
  pass "T47b3 .graphify-corpus-ignore is not proof of out-dir ownership"
else
  fail "T47b3 a source dir with .graphify-corpus-ignore must be refused (rc=$rc, cache survived=$( [ -f "$IGNCORPUS/docs/cache/entry.txt" ] && echo yes || echo NO )): $out"
fi

# T47c: an EMPTY directory is not somebody's content -- a first run legitimately
# finds (or creates) one, so the guard must not fire there.
EMPTYCORPUS="$WS/guard-empty"; EMPTYMAPS="$WS/guard-empty-maps"
mkdir -p "$EMPTYCORPUS/graphify-out-alt" "$EMPTYMAPS"
printf '# note\nempty-outdir fixture\n' > "$EMPTYCORPUS/note.md"
out=$( GRAPHIFY_OUT="graphify-out-alt" GRAPHIFY_MAP_BIN="$GOBIN/graphify" bash "$SCRIPT" \
  --name guard-empty --corpus-root "$EMPTYCORPUS" --backend claude-cli \
  --maps-dir "$EMPTYMAPS" --title Guard --slug guard-empty-map 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && [ -f "$EMPTYCORPUS/graphify-out-alt/graph.json" ] \
  && pass "T47c an empty out dir is adopted normally (the guard does not over-fire)" \
  || fail "T47c an empty out dir should be usable (rc=$rc): $out"

# T47f: GRAPHIFY_OUT set explicitly to the DEFAULT name is the default, not an
# override, and must not activate the ownership gate -- otherwise a harmless
# explicit setting starts refusing valid out dirs that predate the markers.
EXPCORPUS="$WS/guard-explicit"; EXPMAPS="$WS/guard-explicit-maps"
mkdir -p "$EXPCORPUS/graphify-out/cache" "$EXPMAPS"
printf '# note\nexplicit-default fixture\n' > "$EXPCORPUS/note.md"
printf '{}\n' > "$EXPCORPUS/graphify-out/manifest.json"
out=$( GRAPHIFY_OUT="graphify-out" GRAPHIFY_MAP_BIN="$GOBIN/graphify" bash "$SCRIPT" \
  --name guard-explicit --corpus-root "$EXPCORPUS" --backend claude-cli \
  --maps-dir "$EXPMAPS" --title Guard --slug guard-explicit-map 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && [ -f "$EXPCORPUS/graphify-out/graph.json" ] \
  && pass "T47f an explicit GRAPHIFY_OUT=graphify-out behaves like unset" \
  || fail "T47f the explicit default must not be gated (rc=$rc): $out"

# T47d: an out dir holding ONLY leftovers from an interrupted run -- a promote
# stage dir, a lock -- is still ours, not source content. The first version of
# this guard enumerated finished artifacts only, so one interrupted run made
# every subsequent refresh refuse. Pinned because the failure mode (a cadence
# that quietly stops refreshing) is worse than the one the guard prevents.
LEFTCORPUS="$WS/guard-leftover"; LEFTMAPS="$WS/guard-leftover-maps"
mkdir -p "$LEFTCORPUS/graphify-out-left/.promote-stage.999.1" "$LEFTMAPS"
printf '# note\nleftover fixture\n' > "$LEFTCORPUS/note.md"
out=$( GRAPHIFY_OUT="graphify-out-left" GRAPHIFY_MAP_BIN="$GOBIN/graphify" bash "$SCRIPT" \
  --name guard-leftover --corpus-root "$LEFTCORPUS" --backend claude-cli \
  --maps-dir "$LEFTMAPS" --title Guard --slug guard-leftover-map 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && [ -f "$LEFTCORPUS/graphify-out-left/graph.json" ] \
  && pass "T47d an out dir holding only interrupted-run leftovers is still adopted" \
  || fail "T47d leftovers must not make the guard refuse (rc=$rc): $out"

# T47e: the DEFAULT out-dir name is never gated on its contents. The guard
# exists for a mistyped override; the conventional graphify-out under the
# corpus root is the out dir by definition. Two earlier revisions judged it by
# contents and refused legitimate out dirs (T6f/T23a/T24/T44b all broke), which
# on the cadence would mean a corpus that silently stops refreshing.
DEFCORPUS="$WS/guard-default"; DEFMAPS="$WS/guard-default-maps"
mkdir -p "$DEFCORPUS/graphify-out/cache" "$DEFMAPS"
printf '# note\ndefault-name fixture\n' > "$DEFCORPUS/note.md"
printf '{}\n' > "$DEFCORPUS/graphify-out/manifest.json"
out=$( GRAPHIFY_MAP_BIN="$GOBIN/graphify" bash "$SCRIPT" \
  --name guard-default --corpus-root "$DEFCORPUS" --backend claude-cli \
  --maps-dir "$DEFMAPS" --title Guard --slug guard-default-map 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && [ -f "$DEFCORPUS/graphify-out/graph.json" ] \
  && pass "T47e the default out-dir name is not content-gated" \
  || fail "T47e the default name must never be refused (rc=$rc): $out"

# T48: HIMMEL-1704 TOCTOU guard — source-level pin. T49 below is the
# behavioural version and SKIPS without symlink support (this Windows box
# included, same as T47h), so pin the two mechanisms in the SOURCE too (same
# shape as test-graph-refresh.sh's 16f/16g): the guard functions exist, AND
# both consumption sites (the corpus-root cd/copy, the maps-dir publish)
# actually CALL them — not just define them unused.
grep -q '^_fs_id()' "$SCRIPT" && grep -q '^_verify_fs_id()' "$SCRIPT" \
  && pass "T48a _fs_id/_verify_fs_id are defined in source" \
  || fail "T48a _fs_id/_verify_fs_id definition missing (HIMMEL-1704)"
grep -Fq '_verify_fs_id "corpus-root" "." "$CORPUS_ID"' "$SCRIPT" \
  && pass "T48b the corpus-root copy re-verifies identity after cd, before find/tar" \
  || fail "T48b copy site does not call _verify_fs_id (HIMMEL-1704 TOCTOU reopened)"
grep -Fq '_verify_fs_id "maps-dir" "." "$MAPS_ID"' "$SCRIPT" \
  && pass "T48c the maps-dir publish re-verifies identity before the write" \
  || fail "T48c publish site does not call _verify_fs_id (HIMMEL-1704 TOCTOU reopened)"
# T48d (codex-2 r1): the identity check must be BOUND to the cd'd directory
# (a relative "." probed from inside a `cd "$MAPS_DIR" && ...` subshell,
# where the process's cwd is fixed to the directory's INODE), not merely a
# re-stat of the pathname followed by handing that same pathname to a
# separate node process -- the latter still races node's own open().
grep -Fq 'cd "$MAPS_DIR" && _verify_fs_id "maps-dir" "."' "$SCRIPT" \
  && pass "T48d the maps-dir check is bound to a cd'd cwd, not a re-stat of the pathname" \
  || fail "T48d publish identity check is not cwd-bound (HIMMEL-1704 codex-2 residual reopened)"

# T49 (HIMMEL-1704, behavioural): the ticket's own scenario — an actor with
# write access to the corpus-root's PARENT directory swaps the accepted
# directory entry for a different tree AFTER a caller's preflight pinned an
# identity but BEFORE this runner actually reads it. Assert refusal BEFORE
# any copy (graphify never invoked, the swapped-in content never touched).
# Skipped, loudly (not silently), where symlinks cannot be created
# (unprivileged Windows without Developer Mode — ln -s copies instead of
# linking) — same discipline as T47h above; guarded for real on POSIX CI.
TOCTOU_PARENT="$WS/toctou-parent"; mkdir -p "$TOCTOU_PARENT"
TOCTOU_REAL_A="$WS/toctou-real-a"; mkdir -p "$TOCTOU_REAL_A"
printf '# n\nbenign\n' > "$TOCTOU_REAL_A/note.md"
if ln -s "$TOCTOU_REAL_A" "$TOCTOU_PARENT/vault" 2>/dev/null && [ -L "$TOCTOU_PARENT/vault" ]; then
  TOCTOU_MAPS="$WS/toctou-maps"; mkdir -p "$TOCTOU_MAPS"
  # The identity a caller's preflight would have pinned: the symlink-RESOLVED
  # target, exactly like graph-refresh.sh's own _fs_id probe.
  TOCTOU_ID=$(stat -L -c '%d:%i' "$TOCTOU_PARENT/vault" 2>/dev/null || stat -L -f '%d:%i' "$TOCTOU_PARENT/vault" 2>/dev/null)

  # Positive control first: an UNSWAPPED corpus-root with the identity it
  # actually has must still succeed — the guard is a re-check, not a blanket
  # refusal of every --corpus-id.
  out=$( GRAPHIFY_MAP_BIN="$BIN/graphify" bash "$SCRIPT" --name toctou-ok \
    --corpus-root "$TOCTOU_PARENT/vault" --corpus-id "$TOCTOU_ID" \
    --backend claude-cli --maps-dir "$TOCTOU_MAPS" --title Guard --slug toctou-ok-map 2>&1 ); rc=$?
  [ "$rc" -eq 0 ] && pass "T49a a correctly-pinned identity is not a blanket refusal" \
    || fail "T49a an unswapped corpus-root with the right --corpus-id must still succeed (rc=$rc): $out"

  TOCTOU_REAL_B="$WS/toctou-real-b"; mkdir -p "$TOCTOU_REAL_B"
  printf 'attacker content\n' > "$TOCTOU_REAL_B/secret.md"
  # THE RACE: swap the accepted directory entry to point elsewhere — exactly
  # what an actor with write access to the parent can do between a caller's
  # preflight (which pinned $TOCTOU_ID against $TOCTOU_REAL_A) and this
  # runner's own cd/copy.
  rm "$TOCTOU_PARENT/vault"
  ln -s "$TOCTOU_REAL_B" "$TOCTOU_PARENT/vault"
  TOCTOU_CALLS="$WS/toctou-calls.log"; : > "$TOCTOU_CALLS"
  out=$( GRAPHIFY_CALL_LOG="$TOCTOU_CALLS" GRAPHIFY_MAP_BIN="$BIN/graphify" bash "$SCRIPT" --name toctou \
    --corpus-root "$TOCTOU_PARENT/vault" --corpus-id "$TOCTOU_ID" \
    --backend claude-cli --maps-dir "$TOCTOU_MAPS" --title Guard --slug toctou-map 2>&1 ); rc=$?
  if [ "$rc" -eq 1 ] && grep -q "TOCTOU guard" <<< "$out" && [ ! -s "$TOCTOU_CALLS" ]; then
    pass "T49b a corpus-root swapped after preflight is refused before any copy (TOCTOU closed, HIMMEL-1704)"
  else
    fail "T49b the TOCTOU guard must refuse before graphify runs (rc=$rc, graphify called=$( [ -s "$TOCTOU_CALLS" ] && echo yes || echo NO )): $out"
  fi
else
  skip "T49 SKIPPED (this environment cannot create symlinks -- unprivileged Windows without Developer Mode; guarded on POSIX CI)"
fi

# T50: HIMMEL-1704 round 3 (codex-1) source-level pin. The behavioural T51
# below needs symlink support and SKIPS on this Windows box, so pin the
# first-ever-publish safe-create mechanism in the SOURCE too (same
# discipline as T48 above): --maps-parent-id is accepted, the vault's
# identity is re-verified before mkdir, and 60-Maps is created via a bare
# `mkdir` (TOCTOU-safe: fails if anything already occupies the name) rather
# than left to node's own unguarded mkdirSync.
grep -q -- '--maps-parent-id' "$SCRIPT" \
  && pass "T50a --maps-parent-id flag is accepted" \
  || fail "T50a --maps-parent-id flag missing (HIMMEL-1704 round 3 reopened)"
grep -Fq 'cd "$VAULT_DIR" && _verify_fs_id "maps-dir parent" "." "$MAPS_PARENT_ID"' "$SCRIPT" \
  && pass "T50b first-publish path re-verifies the vault parent identity before mkdir" \
  || fail "T50b first-publish parent-identity check missing (HIMMEL-1704 round 3 reopened)"
grep -Fq '&& mkdir "$MAPS_LEAF"' "$SCRIPT" \
  && pass "T50c first-publish creates 60-Maps via a TOCTOU-safe mkdir, not node's mkdirSync" \
  || fail "T50c mkdir-based safe-create missing (HIMMEL-1704 round 3 reopened)"

# T51 (HIMMEL-1704 round 3, behavioural): the first-ever-publish case -- 60-
# Maps does not exist at preflight time, so no --maps-id was pinned, only
# --maps-parent-id (the vault's own identity, its PARENT). Positive control
# first, and it needs NO symlink support -- a plain vault directory
# exercises the full mkdir+cd+empty-check+node path on every platform,
# including this Windows box. Only the RACE half (T51b) needs symlinks to
# simulate the swap, so only that half is skipped where they're unavailable.
T51_PLAIN_VAULT="$WS/t51-plain-vault"; mkdir -p "$T51_PLAIN_VAULT"
T51_PLAIN_ID=$(stat -c '%d:%i' "$T51_PLAIN_VAULT" 2>/dev/null || stat -f '%d:%i' "$T51_PLAIN_VAULT" 2>/dev/null)
T51_PLAIN_CORPUS="$WS/t51-plain-corpus"; mkdir -p "$T51_PLAIN_CORPUS/graphify-out"
printf '%s\n' "$REPORT_FIXTURE" > "$T51_PLAIN_CORPUS/graphify-out/GRAPH_REPORT.md"
out=$( bash "$SCRIPT" --name t51a --corpus-root "$T51_PLAIN_CORPUS" --backend claude-cli \
  --maps-dir "$T51_PLAIN_VAULT/60-Maps" --maps-parent-id "$T51_PLAIN_ID" \
  --title Guard --slug t51a-map --no-update 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && [ -f "$T51_PLAIN_VAULT/60-Maps/t51a-map.md" ] \
  && pass "T51a first-ever publish with a correctly-pinned vault parent succeeds (mkdir+cd+empty-check+node path exercised)" \
  || fail "T51a first-publish should succeed (rc=$rc): $out"

# T51b: the race -- swap the vault itself (the parent-identity's own
# object) after pinning, before this runner's mkdir -- must refuse before
# any write, external content untouched. Needs symlink support to simulate;
# skipped, loudly, where unavailable (same discipline as T47h/T49 above).
T51_OUTER="$WS/t51-outer"; mkdir -p "$T51_OUTER"
T51_REAL_A="$WS/t51-real-a"; mkdir -p "$T51_REAL_A"
if ln -s "$T51_REAL_A" "$T51_OUTER/vault" 2>/dev/null && [ -L "$T51_OUTER/vault" ]; then
  T51_PARENT_ID=$(stat -L -c '%d:%i' "$T51_OUTER/vault" 2>/dev/null || stat -L -f '%d:%i' "$T51_OUTER/vault" 2>/dev/null)
  T51_CORPUS="$WS/t51-corpus"; mkdir -p "$T51_CORPUS/graphify-out"
  printf '%s\n' "$REPORT_FIXTURE" > "$T51_CORPUS/graphify-out/GRAPH_REPORT.md"

  T51_REAL_B="$WS/t51-real-b"; mkdir -p "$T51_REAL_B"
  printf 'attacker content\n' > "$T51_REAL_B/secret.txt"
  rm "$T51_OUTER/vault"
  ln -s "$T51_REAL_B" "$T51_OUTER/vault"
  out=$( bash "$SCRIPT" --name t51-race --corpus-root "$T51_CORPUS" --backend claude-cli \
    --maps-dir "$T51_OUTER/vault/60-Maps" --maps-parent-id "$T51_PARENT_ID" \
    --title Guard --slug t51-race-map --no-update 2>&1 ); rc=$?
  if [ "$rc" -eq 1 ] && grep -q "TOCTOU guard" <<< "$out" && [ ! -e "$T51_OUTER/vault/60-Maps" ]; then
    pass "T51b a vault swapped after pinning is refused before mkdir, no 60-Maps created (TOCTOU closed, HIMMEL-1704)"
  else
    fail "T51b the parent-identity guard must refuse before mkdir (rc=$rc, 60-Maps exists=$( [ -e "$T51_OUTER/vault/60-Maps" ] && echo yes || echo NO )): $out"
  fi
else
  skip "T51b SKIPPED (this environment cannot create symlinks -- unprivileged Windows without Developer Mode; guarded on POSIX CI)"
fi

if [ "$FAILS" -ne 0 ]; then echo "$FAILS FAILURES"; exit 1; fi
if [ "$SKIPS" -ne 0 ]; then echo "ALL PASS ($SKIPS skipped)"; else echo "ALL PASS"; fi
