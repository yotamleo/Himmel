#!/usr/bin/env bash
# scripts/ci/test-run-shell-tests-rotation-guards.sh — run-shell-tests.sh
# resume rotation (HIMMEL-2243), sub-cases 17g-17j: the cases where rotation
# must DISABLE itself rather than guess.
#
# CASE 17 SPANS THREE FILES. If you grepped "Case 17" and landed here, the
# other two are test-run-shell-tests-rotation.sh (17a-17f: the rotation
# contract proper) and test-run-shell-tests-rotation-cursor.sh (17k-17m: the
# cursor file's path — symlink refusal and key encoding). HIMMEL-2895 split
# them because each sub-case costs 25-51s against the same 25s-sleep sandbox,
# and the eleven of them were 327s of the original file's 382s — the floor on
# every shard of the sharded shell-unit job.
#
#   17g  HOME unset does not crash the runner (FIX 3): a bare $HOME under
#        `set -u` would abort the WHOLE runner on a host that merely lacks a
#        home directory.
#   17h  HOME unset DISABLES rotation rather than synthesising a shared
#        root-level cursor path (FIX 4).
#   17i  a plan narrowed by --skip-extra leaves an existing cursor untouched
#        rather than clearing it on the strength of a partial plan (FIX 8).
#   17j  the same proof via SUITE_TIER_MODE=fast instead of --skip-extra.
#
# Shared fixtures, including mk_rotate_sandbox, are in
# run-shell-tests-fixture.sh.
#
# Platform guard: bash-only, like every suite in this family, and no .ps1
# twin — it runs under Git Bash on Windows as well as Linux.
#
# Usage: bash scripts/ci/test-run-shell-tests-rotation-guards.sh
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
# Case 17 -- resume rotation (HIMMEL-2243), the cases where rotation must disable itself. 17a-17f and 17k-17m are in the -rotation and -rotation-cursor siblings.
# --------------------------------------------------------------------------
echo "== Case 17 (guards): rotation disables itself rather than guessing (17g-17j) =="
sb17=$(mktemp -d "${TMPDIR:-/tmp}/himmel-suite-rotate.XXXXXX")
order17="$sb17/order.log"
cursor17="$sb17/rotate.cursor"
mk_rotate_sandbox "$sb17" "$order17"

# 17g — HOME unset must degrade, not crash (HIMMEL-2243 FIX 3). A bare $HOME
# reference under `set -u` would abort the WHOLE runner on a host that merely
# lacks a home directory (a bare container runner). SUITE_ROTATE_STATE is
# deliberately left UNSET here, unlike every other sub-case above, so the
# runner's own default expansion -- the one FIX 3 touched -- is what actually
# runs. An ample budget keeps this on the "clear the cursor" branch (a no-op
# `rm -f` on a path that cannot exist, since it is rooted at "/" and slugged by
# this sandbox's own mktemp path), never the write branch, so nothing outside
# this sandbox is ever touched.
echo "== Case 17g: HOME unset does not crash the runner (FIX 3) =="
: > "$order17"
out17g=$(env -u HOME -u SUITE_ROTATE_STATE SUITE_RUN_BUDGET=600 bash "$RUNNER" "$sb17" 2>&1)
rc17g=$?
if [ "$rc17g" -eq 0 ]; then
  pass "17g: HOME unset -> run still completes, rc 0"
else
  fail "17g: expected exit 0 got $rc17g; output: $out17g"
fi
if grepq "$out17g" -iF 'unbound variable' || grepq "$out17g" -iF 'HOME: parameter not set'; then
  fail "17g: runner aborted on HOME; output: $out17g"
else
  pass "17g: no unbound-variable abort on HOME"
fi

# 17h — HOME unset must DISABLE rotation, not synthesise a shared root path
# (HIMMEL-2243 FIX 4, panel finding [codex-1]). 17g only proves the run does
# not CRASH with HOME unset -- it uses an ample budget, so it only ever
# reaches the harmless "clear the cursor" branch and never exercises the
# WRITE branch that used to build the dangerous "/.himmel/..." path in the
# first place (that omission is exactly why 17g did not catch this). This
# sub-case reuses the SAME truncating 15s budget as 17a/17e specifically to
# reach that write branch.
#
# The real vulnerability was `mkdir -p /.himmel` SUCCEEDING when run as root
# in a bare container -- not reproducible here: this account cannot write to
# "/" on this box (`mkdir -p /.himmel` returns Permission Denied
# unconditionally), which would make a direct filesystem check on "/" pass
# whether or not FIX 4 exists -- a non-discriminating assertion, and a check
# against the real root is not something this file should risk regardless.
# So the check that actually distinguishes pre- from post-FIX-4 is on the
# runner's OWN OUTPUT: before FIX 4, this exact invocation still built the
# "/.himmel/himmel-shell-suite-<slug>.cursor" string and printed it, either in
# a "resumes at" NOTE (had the write succeeded) or a "could not write the
# cursor to /..." WARN (as it would on THIS box, where the write fails on
# permissions alone) -- either way, the dangerous root path is right there in
# the text. After FIX 4 that path is never constructed at all: rotation
# disables outright, and a single new NOTE says so instead. Asserting the new
# note appears AND the old dangerous path string never does is therefore a
# no-write assertion that fails against the pre-FIX-4 code on ANY box,
# without this test ever touching a real "/" itself.
echo "== Case 17h: HOME unset disables rotation, no shared-root path (FIX 4) =="
: > "$order17"
out17h=$(env -u HOME -u SUITE_ROTATE_STATE SUITE_RUN_BUDGET=15 bash "$RUNNER" "$sb17" 2>&1)
rc17h=$?
if [ "$rc17h" -eq 1 ]; then
  pass "17h: HOME unset, truncating budget -> still exit 1"
else
  fail "17h: expected exit 1 got $rc17h; output: $out17h"
fi
if grepq "$out17h" -F 'NOTE: rotation — disabled'; then
  pass "17h: rotation-disabled NOTE explains the missing resume point"
else
  fail "17h: expected a 'NOTE: rotation — disabled' line; output: $out17h"
fi
if grepq "$out17h" -F '/.himmel/himmel-shell-suite'; then
  fail "17h: the dangerous root-rooted cursor path was constructed; output: $out17h"
else
  pass "17h: no /.himmel path was ever synthesised (this is the assertion that fails pre-FIX-4)"
fi

# 17i — a run narrowed by --skip-extra must not touch an existing cursor
# (HIMMEL-2243 FIX 8, panel finding [codex-1]). Before this fix, "reached the
# end and executed suites" was treated as "covered the ring": this run skips
# test-c.sh, still finishes cleanly with an ample budget, and would have
# CLEARED the pre-seeded cursor -- silently discarding another run's resume
# point over a plan this run never fully executed. Seed the cursor with an
# arbitrary value first; the point is only to prove it survives untouched, not
# to exercise resume itself (that is 17b's job).
echo "== Case 17i: --skip-extra narrows the plan, cursor stays untouched (FIX 8) =="
: > "$order17"
printf 'test-b.sh\n' > "$cursor17"
before17i=$(cat "$cursor17")
out17i=$(SUITE_ROTATE_STATE="$cursor17" SUITE_RUN_BUDGET=600 bash "$RUNNER" "$sb17" --skip-extra test-c.sh 2>&1)
rc17i=$?
if [ "$rc17i" -eq 0 ]; then
  pass "17i: narrowed (--skip-extra) run completes -> exit 0"
else
  fail "17i: expected exit 0 got $rc17i; output: $out17i"
fi
if grepq "$out17i" -F 'NOTE: rotation — left untouched'; then
  pass "17i: left-untouched NOTE names the narrowing"
else
  fail "17i: expected a 'NOTE: rotation — left untouched' line; output: $out17i"
fi
if [ -f "$cursor17" ] && [ "$(cat "$cursor17" 2>/dev/null)" = "$before17i" ]; then
  pass "17i: cursor file untouched by a narrowed completing run (pre-FIX-8 this would have been cleared)"
else
  fail "17i: expected the cursor to remain '$before17i' at $cursor17; got: $(cat "$cursor17" 2>/dev/null || echo '<missing>')"
fi

# 17j — same proof, via SUITE_TIER_MODE=fast instead of --skip-extra. Uses the
# SUITE_TIER env override seam (see the production table's own comment) to
# list one sandbox suite as extended, rather than touching the real table.
# SUITE_TIER_MODE=fast is CI's own per-PR setting, not an exotic knob, so this
# is the common shape of the bug, not a corner case.
echo "== Case 17j: SUITE_TIER_MODE=fast narrows the plan, cursor stays untouched (FIX 8) =="
: > "$order17"
printf 'test-b.sh\n' > "$cursor17"
before17j=$(cat "$cursor17")
out17j=$(SUITE_ROTATE_STATE="$cursor17" SUITE_RUN_BUDGET=600 SUITE_TIER_MODE=fast \
  SUITE_TIER='test-c.sh  extended  # test override' \
  bash "$RUNNER" "$sb17" 2>&1)
rc17j=$?
if [ "$rc17j" -eq 0 ]; then
  pass "17j: narrowed (SUITE_TIER_MODE=fast) run completes -> exit 0"
else
  fail "17j: expected exit 0 got $rc17j; output: $out17j"
fi
if grepq "$out17j" -F 'NOTE: rotation — left untouched'; then
  pass "17j: left-untouched NOTE names the narrowing"
else
  fail "17j: expected a 'NOTE: rotation — left untouched' line; output: $out17j"
fi
if [ -f "$cursor17" ] && [ "$(cat "$cursor17" 2>/dev/null)" = "$before17j" ]; then
  pass "17j: cursor file untouched by a narrowed completing run (pre-FIX-8 this would have been cleared)"
else
  fail "17j: expected the cursor to remain '$before17j' at $cursor17; got: $(cat "$cursor17" 2>/dev/null || echo '<missing>')"
fi


rm -rf "$sb17"

rst_tally
