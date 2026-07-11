#!/usr/bin/env bash
# test-refresh-graph-map-lock.sh — HIMMEL-910: interleaved two-process test for
# refresh-graph-map.sh's exclusive per-out-dir promote lock. Hermetic: stubs
# graphify (GRAPHIFY_MAP_BIN), no network, no real vault.
# Run: bash scripts/graphify/test-refresh-graph-map-lock.sh
# shellcheck disable=SC2015  # A && pass || fail is the intentional test-assert idiom (pass/fail echo, always rc 0)
# shellcheck disable=SC2016  # the heredoc report fixture is literal on purpose (no expansion wanted)
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/refresh-graph-map.sh"
FAILS=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS+1)); }

WS="$(mktemp -d)"; trap 'rm -rf "$WS"' EXIT

# report_for_gen <gen> -- a valid, publish-parseable GRAPH_REPORT.md carrying
# a generation tag in the community title, so a completed run's report is
# distinguishable from another generation's.
report_for_gen() {
  gen="$1"
  cat <<EOF
# Graph Report - X

## Summary
- 42 nodes · 30 edges · 5 communities (5 shown)

## God Nodes (most connected - your core abstractions)
1. \`Core\` - 9 edges

## Surprising Connections (you probably didn't know these)
- \`A\` --references--> \`B\`  [INFERRED]

## Communities (5 total)

### Community 0 - "GEN_${gen}"
Cohesion: 0.06
Nodes (20): a, b (+18 more)
EOF
}

# make_stub <bindir> <gen> -- a graphify stub that writes graph.json tagged
# "gen":"<gen>" and a report tagged GEN_<gen>, so a completed refresh's
# out-dir artifacts can be attributed to exactly one racer.
make_stub() {
  local dir="$1" gen="$2" content
  mkdir -p "$dir"
  content="$(report_for_gen "$gen")"
  cat > "$dir/graphify" <<STUB
#!/usr/bin/env bash
target=""
if [ "\$1" = "cluster-only" ]; then target="\$2"; else target="\$1"; fi
mkdir -p "\$target/graphify-out"
printf '{"nodes":[],"edges":[],"gen":"$gen"}' > "\$target/graphify-out/graph.json"
cat > "\$target/graphify-out/GRAPH_REPORT.md" <<'RPT'
$content
RPT
exit 0
STUB
  chmod +x "$dir/graphify"
}

# --- T1: overlapping refreshes of the SAME out dir serialize -- the second
# process genuinely WAITS for the first (mutual exclusion), and the final
# artifacts (graph.json + GRAPH_REPORT.md + manifest.json) are a single
# self-consistent generation -- never a splice of the two racers. ---
echo "T1: overlapping refreshes serialize (mutual exclusion + no clobber)"
CORPUS1="$WS/c1"; mkdir -p "$CORPUS1/notes"
MAPS1="$WS/m1"; mkdir -p "$MAPS1"
OUT1="$CORPUS1/graphify-out"
printf '# a\ncontent a\n' > "$CORPUS1/notes/a.md"

ABIN="$WS/abin"; make_stub "$ABIN" "A"
BBIN="$WS/bbin"; make_stub "$BBIN" "B"

# Process A: acquires the promote lock, then holds it for 4s (test-only hook)
# before doing any actual promote work -- a wide, deterministic overlap window.
GRAPHIFY_MAP_BIN="$ABIN/graphify" PATH="$ABIN:$PATH" GRAPHIFY_PROMOTE_TEST_HOLD_SECONDS=4 \
  bash "$SCRIPT" --name lock1 --corpus-root "$CORPUS1" --backend deepseek \
  --maps-dir "$MAPS1" --title "Lock Map" --slug lock-map --corpus-tag lock \
  > "$WS/a.out" 2> "$WS/a.err" &
APID=$!

# Wait (bounded) for A to actually be holding the lock before proceeding.
i=0
while [ ! -d "$OUT1/.promote.lock" ] && [ "$i" -lt 200 ]; do
  sleep 0.05
  i=$((i + 1))
done
if [ -d "$OUT1/.promote.lock" ]; then
  pass "T1 process A holds the promote lock"
else
  fail "T1 process A never acquired the promote lock (setup failed)"
fi

# Mutate the corpus AFTER A is holding (A's scratch snapshot was already
# taken before the hold, so this file must NOT appear in A's own manifest).
printf '# b\ncontent b\n' > "$CORPUS1/notes/b.md"

START=$(date -u +%s)
out_b=$( GRAPHIFY_MAP_BIN="$BBIN/graphify" PATH="$BBIN:$PATH" \
  bash "$SCRIPT" --name lock1 --corpus-root "$CORPUS1" --backend deepseek \
  --maps-dir "$MAPS1" --title "Lock Map" --slug lock-map --corpus-tag lock 2>&1 ); rc_b=$?
END=$(date -u +%s)
ELAPSED=$(( END - START ))

wait "$APID"; rc_a=$?

[ "$rc_a" -eq 0 ] && pass "T1 process A completes successfully" || fail "T1 process A should exit 0 (got $rc_a): $(cat "$WS/a.err" 2>/dev/null)"
[ "$rc_b" -eq 0 ] && pass "T1 process B completes successfully (waited for the lock)" || fail "T1 process B should exit 0 (got $rc_b): $out_b"
[ "$ELAPSED" -ge 3 ] && pass "T1 process B waited for A's hold (elapsed ${ELAPSED}s >= 3s) -- proves mutual exclusion, not a race-through" \
  || fail "T1 process B did not wait long enough (elapsed ${ELAPSED}s < 3s) -- the lock did not serialize the two processes"

grep -q '"gen":"B"' "$OUT1/graph.json" 2>/dev/null && pass "T1 final graph.json is B's (the later, fully-serialized run)" \
  || fail "T1 final graph.json is not B's -- possible clobber/interleave"
grep -q 'GEN_B' "$OUT1/GRAPH_REPORT.md" 2>/dev/null && pass "T1 final GRAPH_REPORT.md is B's" \
  || fail "T1 final GRAPH_REPORT.md is not B's -- possible clobber/interleave"
if grep -q '"notes/a.md"' "$OUT1/manifest.json" 2>/dev/null && grep -q '"notes/b.md"' "$OUT1/manifest.json" 2>/dev/null; then
  pass "T1 final manifest.json reflects B's own corpus scan (a.md + b.md) -- self-consistent triple, no mixed artifacts"
else
  fail "T1 final manifest.json does not match B's own corpus scan -- mixed artifacts"
fi

# --- T2: a bounded second process (short lock timeout) FAILS LOUDLY instead
# of silently clobbering while the first still holds the lock. ---
echo "T2: a bounded second process fails loudly rather than silently clobbering"
CORPUS2="$WS/c2"; mkdir -p "$CORPUS2/notes"
MAPS2="$WS/m2"; mkdir -p "$MAPS2"
OUT2="$CORPUS2/graphify-out"
printf '# c\ncontent c\n' > "$CORPUS2/notes/c.md"

CBIN="$WS/cbin"; make_stub "$CBIN" "C"
DBIN="$WS/dbin"; make_stub "$DBIN" "D"

GRAPHIFY_MAP_BIN="$CBIN/graphify" PATH="$CBIN:$PATH" GRAPHIFY_PROMOTE_TEST_HOLD_SECONDS=4 \
  bash "$SCRIPT" --name lock2 --corpus-root "$CORPUS2" --backend deepseek \
  --maps-dir "$MAPS2" --title "Lock Map 2" --slug lock-map-2 --corpus-tag lock2 \
  > "$WS/c.out" 2> "$WS/c.err" &
CPID=$!

i=0
while [ ! -d "$OUT2/.promote.lock" ] && [ "$i" -lt 200 ]; do
  sleep 0.05
  i=$((i + 1))
done
[ -d "$OUT2/.promote.lock" ] || fail "T2 setup: process C did not acquire the promote lock in time"

out_d=$( GRAPHIFY_MAP_BIN="$DBIN/graphify" PATH="$DBIN:$PATH" GRAPHIFY_PROMOTE_LOCK_TIMEOUT_SECONDS=1 \
  bash "$SCRIPT" --name lock2 --corpus-root "$CORPUS2" --backend deepseek \
  --maps-dir "$MAPS2" --title "Lock Map 2" --slug lock-map-2 --corpus-tag lock2 2>&1 ); rc_d=$?

[ "$rc_d" -eq 2 ] && pass "T2 the bounded second process (1s timeout) fails with rc=2, not a silent clobber" \
  || fail "T2 bounded process should exit 2 (got $rc_d): $out_d"
echo "$out_d" | grep -q "giving up" && pass "T2 stderr carries a loud explanation" \
  || fail "T2 stderr should explain the refusal: $out_d"
[ -e "$OUT2/graph.json" ] && fail "T2 out dir was written by the failed/blocked process (clobber!)" \
  || pass "T2 out dir untouched by the failed process while C still holds the lock"

wait "$CPID"; rc_c=$?
[ "$rc_c" -eq 0 ] && pass "T2 process C (the lock holder) still completes normally afterward" \
  || fail "T2 process C should exit 0 (got $rc_c): $(cat "$WS/c.err" 2>/dev/null)"
grep -q '"gen":"C"' "$OUT2/graph.json" 2>/dev/null && pass "T2 out dir ends up fully C's (the only writer) after C completes" \
  || fail "T2 out dir does not reflect C's own promote"

# --- T3: a stale lock (crashed holder, no heartbeat) is taken over
# automatically, with a loud trail on stderr. ---
echo "T3: a stale lock is taken over with a loud trail"
CORPUS3="$WS/c3"; mkdir -p "$CORPUS3/notes"
MAPS3="$WS/m3"; mkdir -p "$MAPS3"
OUT3="$CORPUS3/graphify-out"
printf '# e\ncontent e\n' > "$CORPUS3/notes/e.md"
mkdir -p "$OUT3/.promote.lock"
STALE_AT=$(( $(date -u +%s) - 100 ))
printf '%s\n' "$STALE_AT" > "$OUT3/.promote.lock/acquired"

EBIN="$WS/ebin"; make_stub "$EBIN" "E"
out_e=$( GRAPHIFY_MAP_BIN="$EBIN/graphify" PATH="$EBIN:$PATH" GRAPHIFY_PROMOTE_LOCK_STALE_SECONDS=10 \
  bash "$SCRIPT" --name lock3 --corpus-root "$CORPUS3" --backend deepseek \
  --maps-dir "$MAPS3" --title "Lock Map 3" --slug lock-map-3 --corpus-tag lock3 2>&1 ); rc_e=$?

[ "$rc_e" -eq 0 ] && pass "T3 refresh succeeds by taking over the stale lock" || fail "T3 should exit 0 (got $rc_e): $out_e"
if echo "$out_e" | grep -q "stale" && echo "$out_e" | grep -qi "taking over"; then
  pass "T3 stderr carries a loud takeover trail"
else
  fail "T3 stderr should mention the stale takeover: $out_e"
fi
grep -q '"gen":"E"' "$OUT3/graph.json" 2>/dev/null && pass "T3 the refresh completed and promoted normally after takeover" \
  || fail "T3 promote did not complete after takeover"
[ -d "$OUT3/.promote.lock" ] && fail "T3 lock dir left behind after takeover run (takeover -> acquire -> release did not compose)" \
  || pass "T3 lock dir gone after the takeover run (takeover -> acquire -> eager release composed)"

# --- T4 (CR r1, codex-adv-1): two SIMULTANEOUS contenders against one stale
# lock -- the takeover must be single-winner. The rm-then-continue takeover
# let both contenders judge the same stale stamp, then the second's rm -rf
# destroy the first's freshly-won lock -- both inside the promote block at
# once. Asserts: exactly ONE takeover trail, the two holds are fully
# serialized (elapsed >= 2x the hold), and the final triple is one
# self-consistent generation. NOTE: the buggy interleave is a genuine race
# (a ~tens-of-ms window), so this test is probabilistic as a RED detector --
# but it must be deterministically GREEN under the single-winner fix. ---
echo "T4: two simultaneous contenders against one stale lock -- single-winner takeover"
CORPUS4="$WS/c4"; mkdir -p "$CORPUS4/notes"
MAPS4="$WS/m4"; mkdir -p "$MAPS4"
OUT4="$CORPUS4/graphify-out"
printf '# k\ncontent k\n' > "$CORPUS4/notes/k.md"
mkdir -p "$OUT4/.promote.lock"
STALE_AT4=$(( $(date -u +%s) - 100000 ))
printf '%s\n' "$STALE_AT4" > "$OUT4/.promote.lock/acquired"

GBIN4="$WS/g4bin"; make_stub "$GBIN4" "G"
HBIN4="$WS/h4bin"; make_stub "$HBIN4" "H"

START4=$(date -u +%s)
GRAPHIFY_MAP_BIN="$GBIN4/graphify" PATH="$GBIN4:$PATH" \
  GRAPHIFY_PROMOTE_LOCK_STALE_SECONDS=10 GRAPHIFY_PROMOTE_TEST_HOLD_SECONDS=5 \
  bash "$SCRIPT" --name lock4 --corpus-root "$CORPUS4" --backend deepseek \
  --maps-dir "$MAPS4" --title "Lock Map 4" --slug lock-map-4 --corpus-tag lock4 \
  > "$WS/g4.out" 2> "$WS/g4.err" &
GPID=$!
GRAPHIFY_MAP_BIN="$HBIN4/graphify" PATH="$HBIN4:$PATH" \
  GRAPHIFY_PROMOTE_LOCK_STALE_SECONDS=10 GRAPHIFY_PROMOTE_TEST_HOLD_SECONDS=5 \
  bash "$SCRIPT" --name lock4 --corpus-root "$CORPUS4" --backend deepseek \
  --maps-dir "$MAPS4" --title "Lock Map 4" --slug lock-map-4 --corpus-tag lock4 \
  > "$WS/h4.out" 2> "$WS/h4.err" &
HPID=$!
wait "$GPID"; rc_g=$?
wait "$HPID"; rc_h=$?
END4=$(date -u +%s)
ELAPSED4=$(( END4 - START4 ))

[ "$rc_g" -eq 0 ] && [ "$rc_h" -eq 0 ] && pass "T4 both contenders complete successfully" \
  || fail "T4 contenders should both exit 0 (got $rc_g/$rc_h): $(cat "$WS/g4.err" "$WS/h4.err" 2>/dev/null)"
TAKEOVERS4=$(cat "$WS/g4.err" "$WS/h4.err" 2>/dev/null | grep -c "taking over")
[ "$TAKEOVERS4" -eq 1 ] && pass "T4 exactly ONE contender took over the stale lock (single-winner)" \
  || fail "T4 takeover count should be exactly 1 (got $TAKEOVERS4) -- both contenders won the stale takeover: $(cat "$WS/g4.err" "$WS/h4.err" 2>/dev/null)"
[ "$ELAPSED4" -ge 9 ] && pass "T4 the two 5s holds serialized (elapsed ${ELAPSED4}s >= 9s) -- never concurrent inside the promote block" \
  || fail "T4 holds overlapped (elapsed ${ELAPSED4}s < 9s) -- both contenders were inside the promote block at once"
GEN_GRAPH4=$(grep -o '"gen":"[GH]"' "$OUT4/graph.json" 2>/dev/null | head -1 | tr -dc 'GH')
GEN_REPORT4=$(grep -o 'GEN_[GH]' "$OUT4/GRAPH_REPORT.md" 2>/dev/null | head -1)
G4="$GEN_GRAPH4"; R4="${GEN_REPORT4#GEN_}"
if [ -n "$G4" ] && [ "$G4" = "$R4" ]; then
  pass "T4 final graph.json + GRAPH_REPORT.md are one self-consistent generation ($G4)"
else
  fail "T4 final artifacts are spliced across generations (graph=$GEN_GRAPH4 report=$GEN_REPORT4)"
fi

# --- T5 (CR r1, codex-1): owner-blind release. A stale-but-ALIVE former
# holder (machine-sleep mid-promote) that was taken over must NOT, on wake,
# delete the SUCCESSOR's lock -- release only removes the lock dir when its
# owner token is still ours; on mismatch it WARNs loudly and leaves the
# successor's lock alone. ---
echo "T5: taken-over former owner's release leaves the successor's lock alone"
CORPUS5="$WS/c5"; mkdir -p "$CORPUS5/notes"
MAPS5="$WS/m5"; mkdir -p "$MAPS5"
OUT5="$CORPUS5/graphify-out"
printf '# f\ncontent f\n' > "$CORPUS5/notes/f.md"

FBIN5="$WS/f5bin"; make_stub "$FBIN5" "F"
SBIN5="$WS/s5bin"; make_stub "$SBIN5" "S"

# Former owner F: acquires, then holds 6s (simulates a machine-sleep pause
# mid-promote -- alive, but paused past the stale threshold).
GRAPHIFY_MAP_BIN="$FBIN5/graphify" PATH="$FBIN5:$PATH" GRAPHIFY_PROMOTE_TEST_HOLD_SECONDS=6 \
  bash "$SCRIPT" --name lock5 --corpus-root "$CORPUS5" --backend deepseek \
  --maps-dir "$MAPS5" --title "Lock Map 5" --slug lock-map-5 --corpus-tag lock5 \
  > "$WS/f5.out" 2> "$WS/f5.err" &
FPID=$!
i=0
while { [ ! -d "$OUT5/.promote.lock" ] || [ ! -f "$OUT5/.promote.lock/acquired" ]; } && [ "$i" -lt 200 ]; do
  sleep 0.05
  i=$((i + 1))
done
[ -f "$OUT5/.promote.lock/acquired" ] || fail "T5 setup: former owner F never acquired the promote lock"
# Backdate F's stamp so a successor judges the lock stale while F is alive.
BACKDATE5=$(( $(date -u +%s) - 100000 ))
printf '%s\n' "$BACKDATE5" > "$OUT5/.promote.lock/acquired"

# Successor S: takes over the (apparently) stale lock, then holds 8s so it
# is still the lock holder when F wakes and releases.
GRAPHIFY_MAP_BIN="$SBIN5/graphify" PATH="$SBIN5:$PATH" \
  GRAPHIFY_PROMOTE_LOCK_STALE_SECONDS=10 GRAPHIFY_PROMOTE_TEST_HOLD_SECONDS=8 \
  bash "$SCRIPT" --name lock5 --corpus-root "$CORPUS5" --backend deepseek \
  --maps-dir "$MAPS5" --title "Lock Map 5" --slug lock-map-5 --corpus-tag lock5 \
  > "$WS/s5.out" 2> "$WS/s5.err" &
SPID=$!
# Wait (bounded) until S's takeover replaced the backdated stamp.
i=0
while [ "$(cat "$OUT5/.promote.lock/acquired" 2>/dev/null)" = "$BACKDATE5" ] && [ "$i" -lt 200 ]; do
  sleep 0.05
  i=$((i + 1))
done
[ "$(cat "$OUT5/.promote.lock/acquired" 2>/dev/null)" != "$BACKDATE5" ] && pass "T5 successor S took over the stale lock while F is paused" \
  || fail "T5 setup: successor S never took over the stale lock"

wait "$FPID"; rc_f=$?
[ "$rc_f" -eq 0 ] && pass "T5 former owner F still completes its own run (rc=0)" || fail "T5 F should exit 0 (got $rc_f): $(cat "$WS/f5.err" 2>/dev/null)"
[ -d "$OUT5/.promote.lock" ] && pass "T5 successor's lock SURVIVES the former owner's release (owner-token mismatch)" \
  || fail "T5 former owner's release deleted the successor's lock (owner-blind rm -rf)"
grep -q "not releasing" "$WS/f5.err" 2>/dev/null && pass "T5 former owner WARNs loudly instead of releasing" \
  || fail "T5 former owner's release printed no takeover WARN: $(cat "$WS/f5.err" 2>/dev/null)"

wait "$SPID"; rc_s=$?
[ "$rc_s" -eq 0 ] && pass "T5 successor S completes successfully" || fail "T5 S should exit 0 (got $rc_s): $(cat "$WS/s5.err" 2>/dev/null)"
grep -q '"gen":"S"' "$OUT5/graph.json" 2>/dev/null && grep -q 'GEN_S' "$OUT5/GRAPH_REPORT.md" 2>/dev/null \
  && pass "T5 final artifacts are the successor's self-consistent generation" \
  || fail "T5 final artifacts are not the successor's own generation"
[ -d "$OUT5/.promote.lock" ] && fail "T5 successor's own release left the lock behind" \
  || pass "T5 successor's own release removed its lock normally"

# --- T6 (CR r1, code-reviewer): a STAMP-LESS lock (holder hard-crashed
# between mkdir and the acquired-stamp write) must be reclaimed after a short
# grace window -- with rm-then-continue removed, a missing/corrupt stamp
# skipped the staleness branch entirely, bricking the out dir forever (every
# future run waits the full timeout, exits 2). Two variants share one code
# path: acquired MISSING, and acquired non-numeric garbage (the case
# sanitizer). Timeout is overridden low so the pre-fix behavior (wait
# forever, exit 2) fails FAST instead of stalling the suite. ---
echo "T6: a stamp-less/garbage-stamped lock is reclaimed after a grace window"
CORPUS6="$WS/c6"; mkdir -p "$CORPUS6/notes"
MAPS6="$WS/m6"; mkdir -p "$MAPS6"
OUT6="$CORPUS6/graphify-out"
printf '# j\ncontent j\n' > "$CORPUS6/notes/j.md"
JBIN6="$WS/j6bin"; make_stub "$JBIN6" "J"
KBIN6="$WS/k6bin"; make_stub "$KBIN6" "K"

# variant 1: acquired file MISSING entirely.
mkdir -p "$OUT6/.promote.lock"
out_j=$( GRAPHIFY_MAP_BIN="$JBIN6/graphify" PATH="$JBIN6:$PATH" GRAPHIFY_PROMOTE_LOCK_TIMEOUT_SECONDS=20 \
  bash "$SCRIPT" --name lock6 --corpus-root "$CORPUS6" --backend deepseek \
  --maps-dir "$MAPS6" --title "Lock Map 6" --slug lock-map-6 --corpus-tag lock6 2>&1 ); rc_j=$?
[ "$rc_j" -eq 0 ] && pass "T6 refresh reclaims the stamp-less lock and succeeds" \
  || fail "T6 refresh should exit 0 after reclaiming the stamp-less lock (got $rc_j): $out_j"
if echo "$out_j" | grep -q "no readable acquired stamp" && echo "$out_j" | grep -q "taking over"; then
  pass "T6 stderr carries a loud stamp-less takeover trail"
else
  fail "T6 stderr should carry the stamp-less takeover trail: $out_j"
fi
grep -q '"gen":"J"' "$OUT6/graph.json" 2>/dev/null && pass "T6 promote completed normally after the stamp-less takeover" \
  || fail "T6 promote did not complete after the stamp-less takeover"
[ -d "$OUT6/.promote.lock" ] && fail "T6 lock dir left behind after the stamp-less takeover run" \
  || pass "T6 lock dir gone after the stamp-less takeover run"

# variant 2: acquired file present but non-numeric garbage (case-sanitizer path).
mkdir -p "$OUT6/.promote.lock"
printf 'not-a-number\n' > "$OUT6/.promote.lock/acquired"
out_k=$( GRAPHIFY_MAP_BIN="$KBIN6/graphify" PATH="$KBIN6:$PATH" GRAPHIFY_PROMOTE_LOCK_TIMEOUT_SECONDS=20 \
  bash "$SCRIPT" --name lock6 --corpus-root "$CORPUS6" --backend deepseek \
  --maps-dir "$MAPS6" --title "Lock Map 6" --slug lock-map-6 --corpus-tag lock6 2>&1 ); rc_k=$?
[ "$rc_k" -eq 0 ] && pass "T6 refresh reclaims the garbage-stamped lock and succeeds" \
  || fail "T6 refresh should exit 0 after reclaiming the garbage-stamped lock (got $rc_k): $out_k"
grep -q '"gen":"K"' "$OUT6/graph.json" 2>/dev/null && pass "T6 promote completed normally after the garbage-stamp takeover" \
  || fail "T6 promote did not complete after the garbage-stamp takeover"

# --- T7 (CR r1, pr-test-analyzer): the EXIT trap must release the lock on a
# POST-acquire promote failure -- a pre-planted $OUT/.manifest.tmp DIRECTORY
# makes the python manifest open() fail right after acquire; the run must
# fail non-zero, leave NO lock behind, and an immediate re-run (blocker
# removed) must succeed with no stale/takeover warning. ---
echo "T7: EXIT trap releases the lock on a post-acquire promote failure"
CORPUS7="$WS/c7"; mkdir -p "$CORPUS7/notes"
MAPS7="$WS/m7"; mkdir -p "$MAPS7"
OUT7="$CORPUS7/graphify-out"
printf '# l\ncontent l\n' > "$CORPUS7/notes/l.md"
LBIN7="$WS/l7bin"; make_stub "$LBIN7" "L"
mkdir -p "$OUT7/.manifest.tmp"   # a DIRECTORY at the tmp name -> python open() fails post-acquire
out_l=$( GRAPHIFY_MAP_BIN="$LBIN7/graphify" PATH="$LBIN7:$PATH" \
  bash "$SCRIPT" --name lock7 --corpus-root "$CORPUS7" --backend deepseek \
  --maps-dir "$MAPS7" --title "Lock Map 7" --slug lock-map-7 --corpus-tag lock7 2>&1 ); rc_l=$?
[ "$rc_l" -ne 0 ] && pass "T7 planted promote failure exits non-zero" \
  || fail "T7 planted promote failure should exit non-zero (got $rc_l): $out_l"
[ -d "$OUT7/.promote.lock" ] && fail "T7 lock left behind after a post-acquire failure (EXIT trap did not release)" \
  || pass "T7 lock released by the EXIT trap after the post-acquire failure"
rmdir "$OUT7/.manifest.tmp" 2>/dev/null || rm -rf "$OUT7/.manifest.tmp"
out_l2=$( GRAPHIFY_MAP_BIN="$LBIN7/graphify" PATH="$LBIN7:$PATH" \
  bash "$SCRIPT" --name lock7 --corpus-root "$CORPUS7" --backend deepseek \
  --maps-dir "$MAPS7" --title "Lock Map 7" --slug lock-map-7 --corpus-tag lock7 2>&1 ); rc_l2=$?
[ "$rc_l2" -eq 0 ] && pass "T7 immediate re-run succeeds (no leftover lock to fight)" \
  || fail "T7 immediate re-run should exit 0 (got $rc_l2): $out_l2"
if echo "$out_l2" | grep -q -e "stale" -e "taking over" -e "giving up"; then
  fail "T7 re-run hit stale/takeover/timeout handling -- the failed run left lock residue: $out_l2"
else
  pass "T7 re-run saw a clean lock (no stale/takeover warnings)"
fi
grep -q '"gen":"L"' "$OUT7/graph.json" 2>/dev/null && pass "T7 re-run promoted normally" \
  || fail "T7 re-run did not promote"

# --- T8 (CR r2, codex-adv-r2): the lock must be held THROUGH the publish
# step -- releasing right after the promote let a second refresh overwrite
# the shared GRAPH_REPORT.md (non-atomic cp) while the first run's publish
# was mid-read. First run pauses at the post-promote/pre-publish seam
# (GRAPHIFY_PUBLISH_TEST_HOLD_SECONDS): during that window the lock must
# still be held and the MOC must not yet exist; the first run's published
# MOC must then carry its OWN generation, and the second (also seam-paused)
# publishes its own generation after. ---
echo "T8: lock held through publish -- promote-vs-publish overlap"
CORPUS8="$WS/c8"; mkdir -p "$CORPUS8/notes"
MAPS8="$WS/m8"; mkdir -p "$MAPS8"
OUT8="$CORPUS8/graphify-out"
MOC8="$MAPS8/lock-map-8.md"
printf '# m\ncontent m\n' > "$CORPUS8/notes/m.md"
MBIN8="$WS/m8bin"; make_stub "$MBIN8" "M"
NBIN8="$WS/n8bin"; make_stub "$NBIN8" "N"

GRAPHIFY_MAP_BIN="$MBIN8/graphify" PATH="$MBIN8:$PATH" GRAPHIFY_PUBLISH_TEST_HOLD_SECONDS=5 \
  bash "$SCRIPT" --name lock8 --corpus-root "$CORPUS8" --backend deepseek \
  --maps-dir "$MAPS8" --title "Lock Map 8" --slug lock-map-8 --corpus-tag lock8 \
  > "$WS/m8.out" 2> "$WS/m8.err" &
MPID=$!
# Wait until the first run's PROMOTE has landed (graph.json is gen M).
i=0
while ! grep -q '"gen":"M"' "$OUT8/graph.json" 2>/dev/null && [ "$i" -lt 300 ]; do
  sleep 0.05
  i=$((i + 1))
done
grep -q '"gen":"M"' "$OUT8/graph.json" 2>/dev/null || fail "T8 setup: first run never promoted"
# Inside the promote->publish window now (first run is seam-paused): the
# lock must STILL be held and the MOC must not have been published yet.
sleep 1
[ -d "$OUT8/.promote.lock" ] && pass "T8 lock still held between promote and publish" \
  || fail "T8 lock released before publish -- the report read is unprotected"
[ -f "$MOC8" ] && fail "T8 MOC already published inside the seam window (seam missing?)" \
  || pass "T8 publish has not run yet inside the seam window"
# Second refresh meanwhile: must WAIT for the first's publish to finish.
GRAPHIFY_MAP_BIN="$NBIN8/graphify" PATH="$NBIN8:$PATH" GRAPHIFY_PUBLISH_TEST_HOLD_SECONDS=5 \
  bash "$SCRIPT" --name lock8 --corpus-root "$CORPUS8" --backend deepseek \
  --maps-dir "$MAPS8" --title "Lock Map 8" --slug lock-map-8 --corpus-tag lock8 \
  > "$WS/n8.out" 2> "$WS/n8.err" &
NPID=$!
wait "$MPID"; rc_m=$?
[ "$rc_m" -eq 0 ] && pass "T8 first run completes successfully" || fail "T8 first run should exit 0 (got $rc_m): $(cat "$WS/m8.err" 2>/dev/null)"
# Immediately after the first run exits, its published MOC must be its OWN
# generation -- never a mixed/truncated read of the second run's report
# (the second is still seam-paused pre-publish, so this read is stable).
grep -q 'GEN_M' "$MOC8" 2>/dev/null && pass "T8 first run's published MOC matches its own generation (unmixed read)" \
  || fail "T8 first run's MOC is not its own generation -- report was overwritten mid-publish"
wait "$NPID"; rc_n=$?
[ "$rc_n" -eq 0 ] && pass "T8 second run completes successfully after waiting" || fail "T8 second run should exit 0 (got $rc_n): $(cat "$WS/n8.err" 2>/dev/null)"
grep -q 'GEN_N' "$MOC8" 2>/dev/null && pass "T8 second run's MOC is its own generation" \
  || fail "T8 second run's final MOC is not its own generation"

# --- T9 (CR r2): the --no-update path READS the same shared report with no
# extraction -- it must take the same lock so a reader never publishes from
# a report a concurrent writer is mid-overwriting. While a full refresh
# holds the lock, a bounded --no-update reader (1s timeout) must fail
# loudly (rc=2) and publish NOTHING; after the writer finishes, a default
# reader waits its turn and publishes the writer's generation. ---
echo "T9: --no-update reader serializes against a concurrent writer"
CORPUS9="$WS/c9"; mkdir -p "$CORPUS9/notes"
MAPS9="$WS/m9"; mkdir -p "$MAPS9"
OUT9="$CORPUS9/graphify-out"
MOC9="$MAPS9/lock-map-9.md"
printf '# p\ncontent p\n' > "$CORPUS9/notes/p.md"
PBIN9="$WS/p9bin"; make_stub "$PBIN9" "P"
QBIN9="$WS/q9bin"; make_stub "$QBIN9" "Q"
# Seed a published-from state (gen P), then clear the MOC.
out_seed=$( GRAPHIFY_MAP_BIN="$PBIN9/graphify" PATH="$PBIN9:$PATH" \
  bash "$SCRIPT" --name lock9 --corpus-root "$CORPUS9" --backend deepseek \
  --maps-dir "$MAPS9" --title "Lock Map 9" --slug lock-map-9 --corpus-tag lock9 2>&1 ); rc_seed=$?
[ "$rc_seed" -eq 0 ] || fail "T9 setup: seed refresh failed (rc=$rc_seed): $out_seed"
rm -f "$MOC9"
# Writer: full refresh (gen Q) holding the lock pre-promote for 4s.
GRAPHIFY_MAP_BIN="$QBIN9/graphify" PATH="$QBIN9:$PATH" GRAPHIFY_PROMOTE_TEST_HOLD_SECONDS=4 \
  bash "$SCRIPT" --name lock9 --corpus-root "$CORPUS9" --backend deepseek \
  --maps-dir "$MAPS9" --title "Lock Map 9" --slug lock-map-9 --corpus-tag lock9 \
  > "$WS/q9.out" 2> "$WS/q9.err" &
QPID=$!
i=0
while [ ! -d "$OUT9/.promote.lock" ] && [ "$i" -lt 200 ]; do
  sleep 0.05
  i=$((i + 1))
done
[ -d "$OUT9/.promote.lock" ] || fail "T9 setup: writer never acquired the lock"
# Bounded reader while the writer holds: must refuse loudly, publish nothing.
out_r1=$( GRAPHIFY_PROMOTE_LOCK_TIMEOUT_SECONDS=1 \
  bash "$SCRIPT" --name lock9 --corpus-root "$CORPUS9" --maps-dir "$MAPS9" \
  --title "Lock Map 9" --slug lock-map-9 --no-update 2>&1 ); rc_r1=$?
[ "$rc_r1" -eq 2 ] && pass "T9 bounded --no-update reader fails rc=2 while the writer holds the lock" \
  || fail "T9 bounded reader should exit 2 (got $rc_r1): $out_r1"
echo "$out_r1" | grep -q "giving up" && pass "T9 bounded reader refusal is loud" \
  || fail "T9 bounded reader refusal should explain itself: $out_r1"
[ -f "$MOC9" ] && fail "T9 bounded reader published a MOC despite the held lock (unserialized read)" \
  || pass "T9 bounded reader published nothing"
wait "$QPID"; rc_q=$?
[ "$rc_q" -eq 0 ] && pass "T9 writer completes successfully" || fail "T9 writer should exit 0 (got $rc_q): $(cat "$WS/q9.err" 2>/dev/null)"
# Default reader after the writer released: publishes the writer's generation.
out_r2=$( bash "$SCRIPT" --name lock9 --corpus-root "$CORPUS9" --maps-dir "$MAPS9" \
  --title "Lock Map 9" --slug lock-map-9 --no-update 2>&1 ); rc_r2=$?
[ "$rc_r2" -eq 0 ] && pass "T9 default reader publishes once the lock is free" \
  || fail "T9 default reader should exit 0 (got $rc_r2): $out_r2"
grep -q 'GEN_Q' "$MOC9" 2>/dev/null && pass "T9 reader's MOC is the writer's promoted generation" \
  || fail "T9 reader's MOC is not the writer's generation"
[ -d "$OUT9/.promote.lock" ] && fail "T9 reader left the lock behind" \
  || pass "T9 reader released the lock after publishing"

if [ "$FAILS" -ne 0 ]; then echo "$FAILS FAILURES"; exit 1; fi
echo "ALL PASS"
