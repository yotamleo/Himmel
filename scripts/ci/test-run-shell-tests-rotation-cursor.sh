#!/usr/bin/env bash
# scripts/ci/test-run-shell-tests-rotation-cursor.sh — run-shell-tests.sh
# resume rotation (HIMMEL-2243), sub-cases 17k-17m: the cursor FILE'S PATH —
# what the runner refuses to follow, and how it keys one cursor per scan root.
#
# CASE 17 SPANS THREE FILES. If you grepped "Case 17" and landed here, the
# other two are test-run-shell-tests-rotation.sh (17a-17f: the rotation
# contract proper) and test-run-shell-tests-rotation-guards.sh (17g-17j: HOME
# unset, narrowed plans). HIMMEL-2895 split them because each sub-case costs
# 25-51s against the same 25s-sleep sandbox, and the eleven of them were 327s
# of the original file's 382s — the floor on every shard of the sharded
# shell-unit job.
#
#   17k  a symlinked cursor path is refused outright, read or write, rather
#        than followed through to overwrite whatever it targets (FIX 9).
#   17l  two scan roots that collide under the lock's lossy slug ("a/b" vs a
#        literal "a__b") still get distinct cursor files.
#   17m  completing one root's run never clears or overwrites the other
#        root's cursor (CodeRabbit Major finding on the cursor-key encoding).
#
# 17k drives the shared six-suite sandbox; 17l/17m build their own two-root
# fixture. Shared fixtures, including mk_rotate_sandbox, are in
# run-shell-tests-fixture.sh.
#
# Platform guard: bash-only, like every suite in this family, and no .ps1
# twin — it runs under Git Bash on Windows as well as Linux.
#
# Usage: bash scripts/ci/test-run-shell-tests-rotation-cursor.sh
#
# Exit codes: 0 — all cases passed; 1 — at least one failed.
set -uo pipefail

# shellcheck source=run-shell-tests-fixture.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/run-shell-tests-fixture.sh"

# --------------------------------------------------------------------------
# Each case builds its own minimal sandbox inline (only the suites that case
# needs), so the fixtures stay local to the assertion that reads them.
# --------------------------------------------------------------------------

# --------------------------------------------------------------------------
# Case 17 -- resume rotation (HIMMEL-2243), the cursor file's own path. 17a-17j are in the -rotation and -rotation-guards siblings.
# --------------------------------------------------------------------------
echo "== Case 17 (cursor path): symlink refusal and key encoding (17k-17m) =="
sb17=$(mktemp -d "${TMPDIR:-/tmp}/himmel-suite-rotate.XXXXXX") || {
  echo "FAIL: Case 17 sandbox: mktemp -d failed"
  exit 1
}
order17="$sb17/order.log"
mk_rotate_sandbox "$sb17" "$order17"

# 17k — a symlinked cursor path must be refused outright, not followed for
# either read or write (HIMMEL-2243 FIX 9, panel finding [codex-1]). A plain
# redirect FOLLOWS symlinks, and the default cursor path is entirely
# predictable ($HOME/.himmel/himmel-shell-suite-<slug>.cursor), so a symlink
# planted (or created by accident) there would make a budget-truncated run
# overwrite whatever it targets with a suite name -- real data loss from a
# code path that has no business writing anywhere but its own cursor. Point
# SUITE_ROTATE_STATE at a symlink targeting a decoy file with known contents;
# the assertion that actually distinguishes pre- from post-FIX-9 is that the
# decoy's CONTENTS are unchanged, not merely that the decoy still exists
# (existence survives even a corrupting write, since a write only overwrites,
# never removes). Uses the SAME "attempt it, skip if the host can't" guard as
# test-suite-concurrency.sh's own symlinked-lock-path case, for the same
# reason: symlink creation needs a privilege this box may not have.
echo "== Case 17k: symlinked cursor path is refused, not followed (FIX 9) =="
decoy17k="$sb17/decoy.txt"
link17k="$sb17/symlink.cursor"
printf 'do not touch\n' > "$decoy17k"
if ln -s "$decoy17k" "$link17k" 2>/dev/null && [ -L "$link17k" ]; then
  before17k=$(cat "$decoy17k")
  : > "$order17"
  out17k=$(SUITE_ROTATE_STATE="$link17k" SUITE_RUN_BUDGET=15 bash "$RUNNER" "$sb17" 2>&1)
  rc17k=$?
  if [ "$rc17k" -eq 1 ]; then
    pass "17k: truncating budget against a symlinked cursor -> still exit 1"
  else
    fail "17k: expected exit 1 got $rc17k; output: $out17k"
  fi
  if grepq "$out17k" -F 'is a symlink'; then
    pass "17k: the refusal names the reason"
  else
    fail "17k: expected 'is a symlink' in output; output: $out17k"
  fi
  after17k=$(cat "$decoy17k" 2>/dev/null)
  if [ "$after17k" = "$before17k" ]; then
    pass "17k: the decoy's contents are unchanged (this is the assertion that fails pre-FIX-9)"
  else
    fail "17k: the decoy was overwritten through the symlink -- before: '$before17k' after: '$after17k'"
  fi
else
  echo "  SKIP  symlink creation unavailable on this host"
fi

rm -rf "$sb17"

# --------------------------------------------------------------------------
# Case 17l/17m -- rotation-cursor key no longer collides across scan roots
# (HIMMEL-2243 CodeRabbit Major finding). The cursor key used to be the
# SAME lossy slug the lock uses: "/" folds to "__" before the rest collapses
# to "-", so a scan root "a/b" and a literal scan root "a__b" slug to the
# IDENTICAL key. That collision is benign for the lock (it only
# over-serialises two runs) but destructive for the cursor (a completed run
# over one root would clear or overwrite the other root's resume point).
#
# rootA17lm and rootB17lm are built to collide under the OLD encoding:
# ".../roots/a/b" folds its one real "/" between "a" and "b" to "__", giving
# "...roots__a__b"; ".../roots/a__b" already contains that literal "__" and
# folds to the SAME "...roots__a__b". Both cases below use the runner's own
# default cursor-path derivation (SUITE_ROTATE_STATE is left unset, HOME
# points at a sandbox) so the assertions exercise the real key derivation,
# not a hand-computed path.
# --------------------------------------------------------------------------
echo "== Case 17l/17m: rotation-cursor key no longer collides across scan roots =="
sb17lm=$(mktemp -d "${TMPDIR:-/tmp}/himmel-suite-rotate-key.XXXXXX")
home17lm="$sb17lm/home"
mkdir -p "$home17lm"
rootA17lm="$sb17lm/roots/a/b"
rootB17lm="$sb17lm/roots/a__b"
mkdir -p "$rootA17lm" "$rootB17lm"
for r in "$rootA17lm" "$rootB17lm"; do
  # Same asymmetric-sleep shape as the main Case 17 fixture above, and for
  # the same reason: a 25s suite against a 15s budget guarantees the budget
  # is spent before the check ahead of the second suite, regardless of
  # setup cost, so which suite runs is deterministic rather than a race.
  cat > "$r/test-x.sh" <<'SHEOF'
#!/usr/bin/env bash
sleep 25
exit 0
SHEOF
  chmod +x "$r/test-x.sh"
  cat > "$r/test-y.sh" <<'SHEOF'
#!/usr/bin/env bash
sleep 1
exit 0
SHEOF
  chmod +x "$r/test-y.sh"
done

# 17l — distinct roots produce distinct cursor files.
echo "== Case 17l: distinct (colliding-slug) roots get distinct cursor files =="

# Seed root B's cursor first via a truncating run over root B alone, so
# afterwards exactly one *.cursor file exists under $home17lm/.himmel --
# the runner derives and writes this path itself; SUITE_ROTATE_STATE is
# never set here.
out17l_b=$(env -u SUITE_ROTATE_STATE HOME="$home17lm" SUITE_RUN_BUDGET=15 bash "$RUNNER" "$rootB17lm" 2>&1)
rc17l_b=$?
if [ "$rc17l_b" -eq 1 ]; then
  pass "17l: truncating run over root B -> exit 1"
else
  fail "17l: expected exit 1 for root B got $rc17l_b; output: $out17l_b"
fi

cursorB17lm=""
cursorB_count17lm=0
for f in "$home17lm"/.himmel/*.cursor; do
  [ -e "$f" ] || continue
  cursorB_count17lm=$((cursorB_count17lm + 1))
  cursorB17lm="$f"
done
if [ "$cursorB_count17lm" -eq 1 ]; then
  pass "17l: root B's truncating run wrote exactly one cursor file: $cursorB17lm"
else
  fail "17l: expected exactly 1 cursor file after root B's run, found $cursorB_count17lm under $home17lm/.himmel"
fi
cursorB_before17m=$(cat "$cursorB17lm" 2>/dev/null)

# Same truncating shape over root A. Under the OLD lossy encoding this
# write would land on the SAME file as root B's (the collision this case
# exists to disprove); under the fix it must land on a distinct file.
out17l_a=$(env -u SUITE_ROTATE_STATE HOME="$home17lm" SUITE_RUN_BUDGET=15 bash "$RUNNER" "$rootA17lm" 2>&1)
rc17l_a=$?
if [ "$rc17l_a" -eq 1 ]; then
  pass "17l: truncating run over root A -> exit 1"
else
  fail "17l: expected exit 1 for root A got $rc17l_a; output: $out17l_a"
fi

cursorA17lm=""
cursor_total17lm=0
for f in "$home17lm"/.himmel/*.cursor; do
  [ -e "$f" ] || continue
  cursor_total17lm=$((cursor_total17lm + 1))
  [ "$f" = "$cursorB17lm" ] || cursorA17lm="$f"
done
if [ "$cursor_total17lm" -eq 2 ] && [ -n "$cursorA17lm" ] && [ "$cursorA17lm" != "$cursorB17lm" ]; then
  pass "17l: two distinct cursor files exist, one per scan root"
else
  fail "17l: expected 2 distinct cursor files under $home17lm/.himmel, found $cursor_total17lm (rootA='$cursorA17lm' rootB='$cursorB17lm')"
fi
echo "  root A cursor file: $cursorA17lm"
echo "  root B cursor file: $cursorB17lm"

# 17m — completing root A leaves root B's cursor byte-identical.
echo "== Case 17m: completing root A leaves root B's cursor untouched =="
out17m=$(env -u SUITE_ROTATE_STATE HOME="$home17lm" SUITE_RUN_BUDGET=600 bash "$RUNNER" "$rootA17lm" 2>&1)
rc17m=$?
if [ "$rc17m" -eq 0 ]; then
  pass "17m: ample-budget (completing) run over root A -> exit 0"
else
  fail "17m: expected exit 0 got $rc17m; output: $out17m"
fi
if [ -n "$cursorA17lm" ] && [ ! -f "$cursorA17lm" ]; then
  pass "17m: root A's own cursor was cleared by its completing run"
else
  fail "17m: expected root A's cursor ($cursorA17lm) to be cleared; output: $out17m"
fi
cursorB_after17m=$(cat "$cursorB17lm" 2>/dev/null)
if [ -f "$cursorB17lm" ] && [ "$cursorB_after17m" = "$cursorB_before17m" ]; then
  pass "17m: root B's cursor file still exists and is byte-identical (this is the assertion that fails on the old colliding key)"
else
  fail "17m: root B's cursor at $cursorB17lm changed or vanished -- before: '$cursorB_before17m' after: '$cursorB_after17m'"
fi

rm -rf "$sb17lm"


rst_tally
