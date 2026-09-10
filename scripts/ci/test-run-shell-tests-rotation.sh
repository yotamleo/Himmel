#!/usr/bin/env bash
# scripts/ci/test-run-shell-tests-rotation.sh — run-shell-tests.sh resume
# rotation (HIMMEL-2243), sub-cases 17a-17f.
#
# CASE 17 SPANS THREE FILES. If you grepped "Case 17" and landed here, the
# other two are test-run-shell-tests-rotation-guards.sh (17g-17j: HOME unset,
# narrowed plans) and test-run-shell-tests-rotation-cursor.sh (17k-17m: the
# cursor file's path — symlink refusal and key encoding).
#
# Why three files: every 17x sub-case drives the same six-suite sandbox whose
# test-a.sh sleeps 25s, so each one costs 25-51s and the eleven of them were
# 327s of the original single file's 382s (HIMMEL-2895 measurement). The
# sharded shell-unit job (HIMMEL-2872) parallelises across FILES, so that was
# the floor on every shard count. The sleep is load-bearing — a
# SUITE_RUN_BUDGET below it is what truncates the run — so the cases were
# split, not made cheaper.
#
# 17a-17f, the rotation contract proper: a truncated run writes a cursor
# naming the first unrun suite; the next run resumes there and wraps, covering
# every suite without re-running the same front section forever (17a, 17b); a
# completed run clears the cursor (17c); a stale cursor falls back loudly
# (17d); SUITE_ROTATE=0 disables it (17e); --list never rotates or writes a
# cursor (17f).
#
# Shared fixtures, including mk_rotate_sandbox, are in
# run-shell-tests-fixture.sh.
#
# Platform guard: bash-only, like every suite in this family, and no .ps1
# twin — it runs under Git Bash on Windows as well as Linux.
#
# Usage: bash scripts/ci/test-run-shell-tests-rotation.sh
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
# Case 17 -- resume rotation (HIMMEL-2243), the contract proper. 17g-17m are in the -rotation-guards and -rotation-cursor siblings.
# --------------------------------------------------------------------------
echo "== Case 17: resume rotation (17a-17f) =="
sb17=$(mktemp -d "${TMPDIR:-/tmp}/himmel-suite-rotate.XXXXXX") || {
  echo "FAIL: Case 17 sandbox: mktemp -d failed"
  exit 1
}
order17="$sb17/order.log"
cursor17="$sb17/rotate.cursor"
mk_rotate_sandbox "$sb17" "$order17"

# 17a — truncation writes the cursor.
echo "== Case 17a: truncation writes the cursor =="
out17a=$(SUITE_ROTATE_STATE="$cursor17" SUITE_RUN_BUDGET=15 bash "$RUNNER" "$sb17" 2>&1)
rc17a=$?
# Guard first: if this ever fails, the assertions below are meaningless — it
# means the runner's OWN pre-first-suite setup ate the 15s budget on this box,
# not a rotation bug. The fix for a red HERE is to raise the fixture's budget
# (or test-a.sh's sleep), never to touch the rotation logic.
if [ "$(cat "$order17" 2>/dev/null)" = "test-a.sh" ]; then
  pass "17a: exactly test-a.sh ran before the budget expired"
else
  fail "17a: expected only test-a.sh in the order log, got: '$(cat "$order17" 2>/dev/null)' -- this means the runner's pre-first-suite setup (git_test_env_pin_perf / runtime preflight / lock acquire) exceeded the 15s budget on this box; raise the fixture's budget, do not change the rotation logic"
fi
if [ "$rc17a" -eq 1 ]; then
  pass "17a: truncated run -> exit 1"
else
  fail "17a: expected exit 1 got $rc17a; output: $out17a"
fi
if grepq "$out17a" -F 'run budget of 15s expired'; then
  pass "17a: names the expired budget"
else
  fail "17a: expected 'run budget of 15s expired'; output: $out17a"
fi
if [ -f "$cursor17" ]; then
  cursor_val17a=$(cat "$cursor17")
  if [ "$cursor_val17a" = "test-b.sh" ]; then
    pass "17a: cursor names test-b.sh, the first unrun suite"
  else
    fail "17a: expected cursor 'test-b.sh', got '$cursor_val17a'"
  fi
else
  fail "17a: cursor file was not written at $cursor17"
fi
if grepq "$out17a" -F 'NOTE: rotation'; then
  pass "17a: a NOTE: rotation line names the resume point"
else
  fail "17a: expected a NOTE: rotation line; output: $out17a"
fi

# 17b — resume + wrap covers everything.
echo "== Case 17b: resume + wrap covers everything =="
: > "$order17"
out17b=$(SUITE_ROTATE_STATE="$cursor17" SUITE_RUN_BUDGET=600 bash "$RUNNER" "$sb17" 2>&1)
rc17b=$?
if [ "$rc17b" -eq 0 ]; then
  pass "17b: resumed run with an ample budget -> exit 0"
else
  fail "17b: expected exit 0 got $rc17b; output: $out17b"
fi
if grepq "$out17b" -F 'NOTE: rotation — resuming at test-b.sh'; then
  pass "17b: NOTE: rotation names the resume point"
else
  fail "17b: expected 'NOTE: rotation — resuming at test-b.sh'; output: $out17b"
fi
if [ "$(head -n1 "$order17" 2>/dev/null)" = "test-b.sh" ]; then
  pass "17b: order log starts at test-b.sh"
else
  fail "17b: expected order log to start at test-b.sh; order log: $(cat "$order17" 2>/dev/null)"
fi
if [ "$(tail -n1 "$order17" 2>/dev/null)" = "test-a.sh" ]; then
  pass "17b: order log wraps and ends at test-a.sh"
else
  fail "17b: expected order log to end at test-a.sh; order log: $(cat "$order17" 2>/dev/null)"
fi
all_six17b=1
for c in a b c d e f; do
  count17b=$(grep -c -x "test-$c.sh" "$order17")
  [ "$count17b" = "1" ] || all_six17b=0
done
if [ "$all_six17b" -eq 1 ]; then
  pass "17b: all six suites ran exactly once (rotation reorders, never filters)"
else
  fail "17b: not all six suites ran exactly once; order log: $(cat "$order17" 2>/dev/null)"
fi

# 17c — a completed run clears the cursor.
echo "== Case 17c: a completed run clears the cursor =="
if [ ! -f "$cursor17" ]; then
  pass "17c: cursor cleared after a completed run"
else
  fail "17c: cursor still present at $cursor17 after a completed run"
fi

# 17d — a stale cursor falls back, loudly.
echo "== Case 17d: a stale cursor falls back loudly =="
: > "$order17"
printf 'test-zzz-gone.sh\n' > "$cursor17"
out17d=$(SUITE_ROTATE_STATE="$cursor17" SUITE_RUN_BUDGET=600 bash "$RUNNER" "$sb17" 2>&1)
rc17d=$?
if [ "$rc17d" -eq 0 ]; then
  pass "17d: stale-cursor run -> exit 0"
else
  fail "17d: expected exit 0 got $rc17d; output: $out17d"
fi
if grepq "$out17d" -F 'no longer discovers'; then
  pass "17d: names the stale cursor and falls back"
else
  fail "17d: expected 'no longer discovers' in output; output: $out17d"
fi
if [ "$(head -n1 "$order17" 2>/dev/null)" = "test-a.sh" ]; then
  pass "17d: fell back to the canonical order, starting at test-a.sh"
else
  fail "17d: expected order log to start at test-a.sh; order log: $(cat "$order17" 2>/dev/null)"
fi
all_six17d=1
for c in a b c d e f; do
  count17d=$(grep -c -x "test-$c.sh" "$order17")
  [ "$count17d" = "1" ] || all_six17d=0
done
if [ "$all_six17d" -eq 1 ]; then
  pass "17d: all six suites ran"
else
  fail "17d: not all six suites ran; order log: $(cat "$order17" 2>/dev/null)"
fi

# 17e — SUITE_ROTATE=0 disables it.
echo "== Case 17e: SUITE_ROTATE=0 disables rotation =="
rm -f "$cursor17"
: > "$order17"
out17e=$(SUITE_ROTATE=0 SUITE_ROTATE_STATE="$cursor17" SUITE_RUN_BUDGET=15 bash "$RUNNER" "$sb17" 2>&1)
rc17e=$?
if [ "$rc17e" -eq 1 ]; then
  pass "17e: still a truncation -> exit 1"
else
  fail "17e: expected exit 1 got $rc17e; output: $out17e"
fi
if [ ! -f "$cursor17" ]; then
  pass "17e: SUITE_ROTATE=0 -> no cursor written"
else
  fail "17e: cursor was written despite SUITE_ROTATE=0"
fi

# 17f — --list never rotates and never writes a cursor.
echo "== Case 17f: --list never rotates or writes a cursor =="
printf 'test-d.sh\n' > "$cursor17"
before17f=$(cat "$cursor17")
out17f=$(SUITE_ROTATE_STATE="$cursor17" bash "$RUNNER" --list "$sb17" 2>&1)
rc17f=$?
if [ "$rc17f" -eq 0 ]; then
  pass "17f: --list -> exit 0"
else
  fail "17f: expected exit 0 got $rc17f; output: $out17f"
fi
run_lines17f=$(printf '%s\n' "$out17f" | grep -E '^\[RUN \]')
# Pipe-free: a single awk per name finds the first matching line number and
# exits, in place of a grep -n | head -n1 | cut -d: -f1 chain.
idx_a17f=$(awk '/test-a\.sh/ { print NR; exit }' <<< "$run_lines17f")
idx_d17f=$(awk '/test-d\.sh/ { print NR; exit }' <<< "$run_lines17f")
if [ -n "$idx_a17f" ] && [ -n "$idx_d17f" ] && [ "$idx_a17f" -lt "$idx_d17f" ]; then
  pass "17f: [RUN ] lines stay in canonical sorted order (test-a before test-d)"
else
  fail "17f: expected test-a before test-d in --list output; got: $run_lines17f"
fi
if ! grepq "$out17f" -F 'NOTE: rotation'; then
  pass "17f: no NOTE: rotation line during --list"
else
  fail "17f: unexpected NOTE: rotation line during --list; output: $out17f"
fi
after17f=$(cat "$cursor17")
if [ "$after17f" = "$before17f" ]; then
  pass "17f: cursor file unchanged by --list"
else
  fail "17f: cursor changed during --list: before='$before17f' after='$after17f'"
fi


rm -rf "$sb17"

rst_tally
