#!/usr/bin/env bash
# test-refresh-graph-map-scratch.sh — HIMMEL-1414: refresh-graph-map.sh must
# never rm -rf a scratch dir it did not create this run. The old scratch path
# was "$SCRATCH_PARENT/graphify-refresh-$NAME-$$" followed by an unconditional
# startup rm -rf, so a later run whose PID collided with an earlier run's
# suffix destroyed that run's finished-but-unpromoted graph (live loss,
# 2026-07-31). Hermetic: stubs graphify (GRAPHIFY_MAP_BIN), no network, no
# real vault. Run: bash scripts/graphify/test-refresh-graph-map-scratch.sh
# shellcheck disable=SC2015  # A && pass || fail is the intentional test-assert idiom (pass/fail echo, always rc 0)
# shellcheck disable=SC2016  # the heredoc report fixture is literal on purpose (no expansion wanted)
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/refresh-graph-map.sh"
FAILS=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS+1)); }

WS="$(mktemp -d "${TMPDIR:-/tmp}/rgm-scratch.XXXXXX")" || { echo "cannot create test workspace" >&2; exit 1; }; trap 'rm -rf "$WS"' EXIT
export TMPDIR="$WS/tmp"; mkdir -p "$TMPDIR"
export GRAPHIFY_LEDGER="$WS/graphify-egress.jsonl"
unset ANTHROPIC_BASE_URL
HERMETIC_HOME="$WS/hermetic-home"; mkdir -p "$HERMETIC_HOME/.claude"
printf 'test-subscription-auth\n' > "$HERMETIC_HOME/.claude/.credentials.json"
printf '{}\n' > "$HERMETIC_HOME/.claude/settings.json"
export HOME="$HERMETIC_HOME"

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

# stub graphify: writes graphify-out/graph.json + GRAPH_REPORT.md for the target.
BIN="$WS/bin"; mkdir -p "$BIN"
cat > "$BIN/graphify" <<STUB
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
chmod +x "$BIN/graphify"
export PATH="$BIN:$PATH"
export GRAPHIFY_MAP_BIN="$BIN/graphify"

CORPUS="$WS/vault"; mkdir -p "$CORPUS/notes"; printf '# n\ncontent\n' > "$CORPUS/notes/a.md"
MAPS="$WS/vault/60-Maps"; mkdir -p "$MAPS"
SP="$WS/scratch"; mkdir -p "$SP"

run_refresh() {
  bash "$SCRIPT" --name luna --corpus-root "$CORPUS" --backend claude \
    --maps-dir "$MAPS" --title "Graphify Luna Map" --slug graphify-luna-map --corpus-tag luna \
    --scratch "$SP"
}

# --- S1: a finished graph at the exact path the OLD scheme would compute for
# this run's PID must survive. The run is started through a wrapper that
# publishes its own PID and then `exec`s the script (exec keeps the PID), so
# the fixture can be planted at graphify-refresh-luna-<that pid> before the
# script's first line runs -- a deterministic PID collision, no script seam. ---
echo "S1: a pre-existing scratch dir at the run's PID-suffix path survives startup"
PIDF="$WS/s1.pid"; GO="$WS/s1.go"
export S1_PIDF="$PIDF" S1_GO="$GO" S1_SCRIPT="$SCRIPT" S1_CORPUS="$CORPUS" S1_MAPS="$MAPS" S1_SP="$SP"
bash -c '
  echo $$ > "$S1_PIDF"
  while [ ! -e "$S1_GO" ]; do sleep 0.05; done
  exec bash "$S1_SCRIPT" --name luna --corpus-root "$S1_CORPUS" --backend claude \
    --maps-dir "$S1_MAPS" --title "Graphify Luna Map" --slug graphify-luna-map --corpus-tag luna \
    --scratch "$S1_SP"
' > "$WS/s1.out" 2> "$WS/s1.err" &
S1_BG=$!
i=0
while [ ! -s "$PIDF" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
S1_PID="$(cat "$PIDF" 2>/dev/null)"
VICTIM="$SP/graphify-refresh-luna-$S1_PID"
mkdir -p "$VICTIM/graphify-out"
printf '{"nodes":[{"id":"finished-unpromoted"}],"links":[]}' > "$VICTIM/graphify-out/graph.json"
: > "$GO"
wait "$S1_BG"; rc=$?
[ "$rc" -eq 0 ] && pass "S1 the run itself completes (rc=0)" \
  || fail "S1 the run should exit 0 (got $rc): $(cat "$WS/s1.err")"
if [ -f "$VICTIM/graphify-out/graph.json" ] && grep -q 'finished-unpromoted' "$VICTIM/graphify-out/graph.json"; then
  pass "S1 the pre-existing finished graph.json survived startup"
else
  fail "S1 startup destroyed a finished unpromoted graph.json at $VICTIM (PID-suffix collision)"
fi
grep -q "leftover.* $VICTIM " "$WS/s1.err" \
  && pass "S1 stderr names the leftover scratch" \
  || fail "S1 stderr should name the leftover scratch $VICTIM: $(cat "$WS/s1.err")"
rm -rf "$VICTIM"

# --- S2: leftovers holding a finished graph.json (an unpromoted workdir AND a
# quarantine dir) are REPORTED on stderr, named, and never deleted; a leftover
# for a different --name and one with no graph.json are not reported. ---
echo "S2: leftover scratches/quarantines holding a graph.json are named, not deleted"
LEFT1="$SP/graphify-refresh-luna-4242"; mkdir -p "$LEFT1/graphify-out"
printf '{"nodes":[{"id":"left1"}]}' > "$LEFT1/graphify-out/graph.json"
LEFT2="$SP/graphify-refresh-luna-4243.quarantine"; mkdir -p "$LEFT2"
printf '{"nodes":[{"id":"left2"}]}' > "$LEFT2/graph.json"
OTHER="$SP/graphify-refresh-other-4244"; mkdir -p "$OTHER/graphify-out"
printf '{"nodes":[]}' > "$OTHER/graphify-out/graph.json"
EMPTY="$SP/graphify-refresh-luna-4245"; mkdir -p "$EMPTY"
out=$( run_refresh 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && pass "S2 the run completes (rc=0)" || fail "S2 the run should exit 0 (got $rc): $out"
[ -f "$LEFT1/graphify-out/graph.json" ] && [ -f "$LEFT2/graph.json" ] \
  && pass "S2 both leftover artifacts still exist" || fail "S2 a leftover artifact was deleted"
echo "$out" | grep -q "$LEFT1" && echo "$out" | grep -q "$LEFT2" \
  && pass "S2 stderr names both leftovers" || fail "S2 stderr should name $LEFT1 and $LEFT2: $out"
echo "$out" | grep -q "$OTHER" && fail "S2 reported a leftover of a different --name" \
  || pass "S2 a different --name's leftover is not reported"
echo "$out" | grep -q "$EMPTY" && fail "S2 reported a leftover with no graph.json" \
  || pass "S2 a leftover with no graph.json is not reported"
rm -rf "$LEFT1" "$LEFT2" "$OTHER" "$EMPTY"

# --- S3: the failure-path quarantine must never overwrite an older quarantine.
# A mktemp shim pins the scratch dir name (the only way a "$SCRATCH.quarantine"
# collision can happen) and a pre-existing quarantine sits at exactly that
# path; a host-path leak in the report forces this run to quarantine. ---
echo "S3: a failing run's quarantine does not clobber an older quarantine dir"
LBIN="$WS/lbin"; mkdir -p "$LBIN"
cat > "$LBIN/graphify" <<'STUB'
#!/usr/bin/env bash
target=""
if [ "$1" = "cluster-only" ]; then target="$2"; else target="$1"; fi
mkdir -p "$target/graphify-out"
printf '{"nodes":[{"id":"fresh-extraction"}],"links":[]}' > "$target/graphify-out/graph.json"
{
  printf '# Graph Report - X  (2026-07-17)\n\n'
  printf '## Summary\n- 42 nodes . 30 edges . 5 communities (5 shown)\n\n'
  printf '## God Nodes (most connected - your core abstractions)\n'
  printf '1. `C:/Users/quarantoken/AppData/Local/Temp/case` - 9 edges\n\n'
  printf '## Communities (5 total)\n\n### Community 0 - "Alpha"\nCohesion: 0.06\nNodes (20): a, b (+18 more)\n'
} > "$target/graphify-out/GRAPH_REPORT.md"
exit 0
STUB
chmod +x "$LBIN/graphify"
REAL_MKTEMP="$(command -v mktemp)"
cat > "$LBIN/mktemp" <<SHIM
#!/usr/bin/env bash
last="\${!#}"
case "\$last" in
  *graphify-refresh-luna-XXXXXX) d="\${last%XXXXXX}FIXED"; mkdir "\$d" && printf '%s\n' "\$d"; exit \$? ;;
esac
exec "$REAL_MKTEMP" "\$@"
SHIM
chmod +x "$LBIN/mktemp"
OLDQ="$SP/graphify-refresh-luna-FIXED.quarantine"; mkdir -p "$OLDQ"
printf '{"nodes":[{"id":"older-quarantine"}]}' > "$OLDQ/graph.json"
out=$( GRAPHIFY_MAP_BIN="$LBIN/graphify" PATH="$LBIN:$PATH" run_refresh 2>&1 ); rc=$?
[ "$rc" -eq 2 ] && pass "S3 the leaking run fails loudly (rc=2)" \
  || fail "S3 the leaking run should exit 2 (got $rc): $out"
grep -q 'older-quarantine' "$OLDQ/graph.json" 2>/dev/null \
  && pass "S3 the older quarantine was not overwritten" \
  || fail "S3 the older quarantine dir was clobbered"
newq=$(printf '%s\n' "$out" | grep -oE '/[^ ]*graphify-refresh-luna-FIXED[^ ]*quarantine' | grep -v -F "$OLDQ" | head -n1)
[ -n "$newq" ] && grep -q 'fresh-extraction' "$newq/graph.json" 2>/dev/null \
  && pass "S3 this run's extraction is preserved in a distinct quarantine dir" \
  || fail "S3 this run's extraction should land in its own quarantine dir (named: '$newq'): $out"

if [ "$FAILS" -ne 0 ]; then echo "$FAILS FAILURES"; exit 1; fi
echo "ALL PASS"
