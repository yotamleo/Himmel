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
# When GRAPHIFY_CALL_LOG is set, append the full arg line of every invocation
# (one per line) so a test can assert what flags reached graphify (T21 uses this
# to verify GRAPHIFY_MAX_CONCURRENCY is wired to --max-concurrency, and that an
# invalid value fails BEFORE any extraction call).
[ -n "\$GRAPHIFY_CALL_LOG" ] && printf '%s\n' "\$*" >> "\$GRAPHIFY_CALL_LOG"
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
printf '{"nodes":[],"edges":[]}' > "\$target/graphify-out/graph.json"
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
printf '{"nodes":[],"edges":[]}' > "\$target/graphify-out/graph.json"
printf '# Graph Report - X\ntotally unparseable garbage body - no recognizable sections at all\n' > "\$target/graphify-out/GRAPH_REPORT.md"
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
UCORPUS="$WS/ucorpus"; UMAPS="$WS/umaps"; mkdir -p "$UMAPS"
git_corpus "$UCORPUS"
# THE REPRO: hide untracked files from `git status --porcelain`, then leave
# untracked work in the tree.
git -C "$UCORPUS" config status.showUntrackedFiles no
printf '# WIP\nuncommitted untracked work\n' > "$UCORPUS/wip.md"
out=$( bash "$SCRIPT" --name upd --corpus-root "$UCORPUS" --backend deepseek \
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
out=$( bash "$SCRIPT" --name cln --corpus-root "$CCORPUS" --backend deepseek \
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
  --backend deepseek --maps-dir "$DMAPS_G" --title "R Map" --slug r-map --corpus-tag r 2>&1 ); rc=$?
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
printf '{"nodes":[],"edges":[]}' > "\$target/graphify-out/graph.json"
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
printf '{"nodes":[],"edges":[]}' > "\$target/graphify-out/graph.json"
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
  bash "$SCRIPT" --name himmel --corpus-root "$LEAKCORPUS" --backend deepseek \
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
printf '{"nodes":[],"edges":[]}' > "\$target/graphify-out/graph.json"
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
  bash "$SCRIPT" --name guardtest --corpus-root "$GUARDCORPUS" --backend deepseek \
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
printf '{"nodes":[],"edges":[]}' > "$target/graphify-out/graph.json"
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
  bash "$SCRIPT" --name multi --corpus-root "$MULTICORPUS" --backend deepseek \
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
# the way T12 is for Part A -- it stays green on both sides of that change. ---
JSONBIN="$WS/jsonbin"; mkdir -p "$JSONBIN"
cat > "$JSONBIN/graphify" <<'STUB'
#!/usr/bin/env bash
target=""
if [ "$1" = "cluster-only" ]; then target="$2"; else target="$1"; fi
mkdir -p "$target/graphify-out"
printf '{"nodes":[{"id":"n1","path":"C:\\\\Users\\\\leaker\\\\AppData\\\\Local\\\\Temp\\\\case"}],"edges":[]}' \
  > "$target/graphify-out/graph.json"
printf '# Graph Report - X  (2026-07-17)\n\n## Summary\n- 1 nodes . 0 edges . 1 communities (1 shown)\n' \
  > "$target/graphify-out/GRAPH_REPORT.md"
exit 0
STUB
chmod +x "$JSONBIN/graphify"
JSONCORPUS="$WS/jsoncorpus"; JSONMAPS="$WS/jsonmaps"; mkdir -p "$JSONCORPUS/notes" "$JSONMAPS"
printf '# n\ncontent\n' > "$JSONCORPUS/notes/n.md"
out=$( GRAPHIFY_MAP_BIN="$JSONBIN/graphify" PATH="$JSONBIN:$PATH" \
  bash "$SCRIPT" --name jsontest --corpus-root "$JSONCORPUS" --backend deepseek \
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
printf '{"nodes":[],"edges":[]}' > "\$target/graphify-out/graph.json"
cat > "\$target/graphify-out/GRAPH_REPORT.md" <<'RPT'
$FP_REPORT_FIXTURE
RPT
exit 0
STUB
chmod +x "$FPBIN/graphify"
FPCORPUS="$WS/fpcorpus"; FPMAPS="$WS/fpmaps"; mkdir -p "$FPCORPUS/notes" "$FPMAPS"
printf '# n\ncontent\n' > "$FPCORPUS/notes/n.md"
out=$( GRAPHIFY_MAP_BIN="$FPBIN/graphify" PATH="$FPBIN:$PATH" \
  bash "$SCRIPT" --name fptest --corpus-root "$FPCORPUS" --backend deepseek \
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
printf '{"nodes":[],"edges":[]}' > "\$target/graphify-out/graph.json"
cat > "\$target/graphify-out/GRAPH_REPORT.md" <<'RPT'
$TP_REPORT_FIXTURE
RPT
exit 0
STUB
chmod +x "$TPBIN/graphify"
TPCORPUS="$WS/tpcorpus"; TPMAPS="$WS/tpmaps"; mkdir -p "$TPCORPUS/notes" "$TPMAPS"
printf '# n\ncontent\n' > "$TPCORPUS/notes/n.md"
out=$( GRAPHIFY_MAP_BIN="$TPBIN/graphify" PATH="$TPBIN:$PATH" \
  bash "$SCRIPT" --name tptest --corpus-root "$TPCORPUS" --backend deepseek \
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
printf '{"nodes":[],"edges":[]}' > "\$target/graphify-out/graph.json"
cat > "\$target/graphify-out/GRAPH_REPORT.md" <<'RPT'
$REPORT_FIXTURE
RPT
exit 0
STUB
chmod +x "$SCANBIN/graphify"
SCANCORPUS="$WS/scancorpus"; SCANMAPS="$WS/scanmaps"; mkdir -p "$SCANCORPUS/notes" "$SCANMAPS"
printf '# n\ncontent\n' > "$SCANCORPUS/notes/n.md"
out=$( GRAPHIFY_MAP_BIN="$SCANBIN/graphify" PATH="$SCANFAILBIN:$PATH" \
  bash "$SCRIPT" --name scanfail --corpus-root "$SCANCORPUS" --backend deepseek \
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
printf '{"nodes":[],"edges":[]}' > "\$target/graphify-out/graph.json"
cat > "\$target/graphify-out/GRAPH_REPORT.md" <<'RPT'
$REPORT_FIXTURE
RPT
exit 0
STUB
chmod +x "$AWKBIN/graphify"
AWKCORPUS="$WS/awkcorpus"; AWKMAPS="$WS/awkmaps"; mkdir -p "$AWKCORPUS/notes" "$AWKMAPS"
printf '# n\ncontent\n' > "$AWKCORPUS/notes/n.md"
out=$( GRAPHIFY_MAP_BIN="$AWKBIN/graphify" PATH="$AWKFAILBIN:$PATH" \
  bash "$SCRIPT" --name awkfail --corpus-root "$AWKCORPUS" --backend deepseek \
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
printf '{"nodes":[],"edges":[]}' > "\$target/graphify-out/graph.json"
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
  bash "$SCRIPT" --name priortest --corpus-root "$PRIORCORPUS" --backend deepseek \
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
# Deliberately OMIT graph.json -- simulates a partial extraction.
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
  bash "$SCRIPT" --name misstest --corpus-root "$MISSCORPUS" --backend deepseek \
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
printf '{"nodes":[],"edges":[]}' > "$target/graphify-out/graph.json"
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
  bash "$SCRIPT" --name badhdrtest --corpus-root "$BADHDRCORPUS" --backend deepseek \
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
printf '{"nodes":[],"edges":[]}' > "$target/graphify-out/graph.json"
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
  bash "$SCRIPT" --name nultest --corpus-root "$NULCORPUS" --backend deepseek \
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
out=$( GRAPHIFY_CALL_LOG="$t21log" GRAPHIFY_MAX_CONCURRENCY=abc bash "$SCRIPT" --name luna --corpus-root "$CORPUS" --backend deepseek \
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
out=$( GRAPHIFY_CALL_LOG="$t21log" GRAPHIFY_MAX_CONCURRENCY=0 bash "$SCRIPT" --name luna --corpus-root "$CORPUS" --backend deepseek \
  --maps-dir "$MAPS" --title "T" --slug graphify-luna-map --corpus-tag luna 2>&1 ); rc=$?
{ [ "$rc" -eq 1 ] && echo "$out" | grep -q "GRAPHIFY_MAX_CONCURRENCY must be"; } \
  && pass "T21b zero GRAPHIFY_MAX_CONCURRENCY rejected (rc=1 + validation msg)" \
  || fail "T21b zero GRAPHIFY_MAX_CONCURRENCY should fail rc=1 with the validation msg (got $rc): $out"
[ ! -s "$t21log" ] && pass "T21b zero value fails before any extraction call" \
  || fail "T21b extraction ran on a zero value: $(cat "$t21log")"
# Explicitly-empty value fails loud too (unset-only `-6` default preserves it
# for the validation instead of silently defaulting to 6).
: > "$t21log"
out=$( GRAPHIFY_CALL_LOG="$t21log" GRAPHIFY_MAX_CONCURRENCY='' bash "$SCRIPT" --name luna --corpus-root "$CORPUS" --backend deepseek \
  --maps-dir "$MAPS" --title "T" --slug graphify-luna-map --corpus-tag luna 2>&1 ); rc=$?
{ [ "$rc" -eq 1 ] && echo "$out" | grep -q "GRAPHIFY_MAX_CONCURRENCY must be"; } \
  && pass "T21b2 explicitly-empty GRAPHIFY_MAX_CONCURRENCY rejected (rc=1 + validation msg)" \
  || fail "T21b2 empty GRAPHIFY_MAX_CONCURRENCY should fail rc=1 with the validation msg (got $rc): $out"
[ ! -s "$t21log" ] && pass "T21b2 empty value fails before any extraction call" \
  || fail "T21b2 extraction ran on an empty value: $(cat "$t21log")"
# Negative value: the leading '-' is a non-digit, so it hits the same
# positive-integer branch as T21a and fails before extraction.
: > "$t21log"
out=$( GRAPHIFY_CALL_LOG="$t21log" GRAPHIFY_MAX_CONCURRENCY=-1 bash "$SCRIPT" --name luna --corpus-root "$CORPUS" --backend deepseek \
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
out=$( GRAPHIFY_CALL_LOG="$t21log" GRAPHIFY_MAX_CONCURRENCY=3 bash "$SCRIPT" --name luna --corpus-root "$CORPUS" --backend deepseek \
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
out=$( GRAPHIFY_MAX_CONCURRENCY=abc bash "$SCRIPT" --name luna --corpus-root "$CORPUS" --backend deepseek \
  --maps-dir "$MAPS" --title "T" --slug graphify-luna-map --corpus-tag luna --no-update 2>&1 ); rc=$?
echo "$out" | grep -q "GRAPHIFY_MAX_CONCURRENCY must be" \
  && fail "T21d --no-update wrongly validated the irrelevant throttle value: $out" \
  || pass "T21d --no-update skips throttle validation (invalid value tolerated on publish-only path)"

if [ "$FAILS" -ne 0 ]; then echo "$FAILS FAILURES"; exit 1; fi
echo "ALL PASS"
