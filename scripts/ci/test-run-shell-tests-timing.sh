#!/usr/bin/env bash
# scripts/ci/test-run-shell-tests-timing.sh — the run-shell-tests.sh cases
# that spend their wall clock WAITING on the runner's own watchdog
# (HIMMEL-2895, split out of test-run-shell-tests.sh).
#
#   16. CAP EXCEEDED vs a genuine rc=124 (HIMMEL-2233): a watchdog-killed
#       suite renders distinctly from a real assertion failure, keyed on
#       `capped` not on the exit code; the Disposition order block appears
#       only when fail>0.
#   20. CAP EXCEEDED with every OBSERVED assertion passing (HIMMEL-2401)
#       renders distinctly from a genuine failure in the same run.
#
# Both fixtures must outlive a real cap, so their 41s is timer waits, not work
# that could be made cheaper — but they were never the reason the pre-split
# file took 382s. That was Case 17, at 327s. The rest of the family is
# test-run-shell-tests.sh (the core cases), -discovery.sh (18, 21) and the
# three -rotation*.sh suites; shared fixtures are in
# run-shell-tests-fixture.sh.
#
# Platform guard: bash-only, like every suite in this family, and no .ps1
# twin — it runs under Git Bash on Windows as well as Linux.
#
# Usage: bash scripts/ci/test-run-shell-tests-timing.sh
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
# Case 16 — CAP EXCEEDED renders distinctly from a genuine rc=124 (HIMMEL-2233).
# Before this fix a suite the watchdog killed for exceeding its wall-clock cap
# rendered identically to a suite that failed its own assertions and merely
# happened to exit 124 — a leg reading a red run could not tell "the runner's
# clock ran out" from "the suite is broken" without re-running it, costing
# 10-30 minutes of adjudication per occurrence (4 of 10 failures in the
# 2026-08-29 run were this). The fix keys the rendering off `capped`, set only
# when the watchdog's rc file was never written, NOT off `[ "$rc" -eq 124 ]` —
# a suite is free to exit 124 on its own and that must still read as a plain
# assertion failure. Assertion 2 below is the one pinning that: it fails the
# instant someone "simplifies" the condition back to checking rc==124, because
# a genuinely-124 suite would then wrongly render as CAP EXCEEDED too.
# --------------------------------------------------------------------------
echo "== Case 16: CAP EXCEEDED vs genuine rc=124 (HIMMEL-2233) =="
sb16=$(mktemp -d "${TMPDIR:-/tmp}/rst-case16.XXXXXX") || { fail "16: mktemp failed"; sb16=""; }
if [ -n "$sb16" ]; then
mkdir -p "$sb16/scripts"
cat > "$sb16/scripts/test-quick.sh" <<'SHEOF'
#!/usr/bin/env bash
echo hi
exit 0
SHEOF
cat > "$sb16/scripts/test-genuine124.sh" <<'SHEOF'
#!/usr/bin/env bash
echo "assertion failed, exiting 124 on my own"
exit 124
SHEOF
cat > "$sb16/scripts/test-slowpoke.sh" <<'SHEOF'
#!/usr/bin/env bash
sleep 30
SHEOF
chmod +x "$sb16/scripts/test-quick.sh" "$sb16/scripts/test-genuine124.sh" "$sb16/scripts/test-slowpoke.sh"

out16=$(SUITE_TIMEOUT=5 env -u SUITE_TIER_MODE bash "$RUNNER" "$sb16/scripts" 2>&1)
rc16=$?

# 1. slowpoke -> [CAP EXCEEDED] header, carrying both elapsed time and cap.
if grepq "$out16" -E '\[CAP EXCEEDED\].*test-slowpoke\.sh \(ran [0-9]+s, cap 5s\)'; then
  pass "16: test-slowpoke.sh renders [CAP EXCEEDED] with elapsed time and cap"
else
  fail "16: expected a [CAP EXCEEDED] header for test-slowpoke.sh with elapsed+cap; out: $out16"
fi

# 2. genuine124 -> plain [FAIL] with rc=124, NOT [CAP EXCEEDED]. The negative
# is the one that pins `capped` rather than the exit code.
if grepq "$out16" -E '\[FAIL\].*test-genuine124\.sh \(rc=124,'; then
  pass "16: test-genuine124.sh renders plain [FAIL] with rc=124"
else
  fail "16: expected plain [FAIL] (rc=124,...) for test-genuine124.sh; out: $out16"
fi
if ! grepq "$out16" -E '\[CAP EXCEEDED\].*test-genuine124\.sh'; then
  pass "16: test-genuine124.sh is NOT rendered as [CAP EXCEEDED] (capped, not rc, discrimination)"
else
  fail "16: test-genuine124.sh wrongly rendered as [CAP EXCEEDED]; out: $out16"
fi

# 3. quick -> [PASS].
if grepq "$out16" -E '\[PASS\].*test-quick\.sh'; then
  pass "16: test-quick.sh renders [PASS]"
else
  fail "16: expected [PASS] for test-quick.sh; out: $out16"
fi

# 4. Failed suites: block carries both, each with its own wording.
if grepq "$out16" -E 'test-slowpoke\.sh \(CAP EXCEEDED after [0-9]+s, cap 5s — no exit status observed\)'; then
  pass "16: Failed suites block carries the CAP EXCEEDED wording for test-slowpoke.sh"
else
  fail "16: expected 'CAP EXCEEDED after ...s, cap 5s — no exit status observed' in Failed suites block; out: $out16"
fi
if grepq "$out16" -E 'test-genuine124\.sh \(rc=124\)'; then
  pass "16: Failed suites block carries the plain (rc=124) wording for test-genuine124.sh"
else
  fail "16: expected '(rc=124)' in Failed suites block for test-genuine124.sh; out: $out16"
fi

# 5. Disposition order block present on a red run.
if grepq "$out16" -F 'Disposition order for a red suite (HIMMEL-2231):'; then
  pass "16: Disposition order block is present on a red run"
else
  fail "16: expected the Disposition order block; out: $out16"
fi

# 6. Runner exits 1.
if [ "$rc16" -eq 1 ]; then
  pass "16: runner exits 1"
else
  fail "16: expected exit 1, got $rc16"
fi
rm -rf "$sb16"
fi

# Inverse: an all-green sandbox must NOT print the Disposition order block —
# it is printed only when fail>0.
sb16g=$(mktemp -d "${TMPDIR:-/tmp}/rst-case16g.XXXXXX") || { fail "16: mktemp failed (all-green sandbox)"; sb16g=""; }
if [ -n "$sb16g" ]; then
cat > "$sb16g/test-ok.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
chmod +x "$sb16g/test-ok.sh"
out16g=$(bash "$RUNNER" "$sb16g" 2>&1)
rc16g=$?
if [ "$rc16g" -eq 0 ] && ! grepq "$out16g" -F 'Disposition order for a red suite (HIMMEL-2231):'; then
  pass "16: all-green sandbox omits the Disposition order block"
else
  fail "16: expected no Disposition order block on an all-green run; rc=$rc16g out: $out16g"
fi
rm -rf "$sb16g"
fi


# --------------------------------------------------------------------------
# Case 20 (HIMMEL-2401) — a watchdog-killed suite with every OBSERVED
# assertion passing renders distinctly from a genuine failure in the same
# run. Before this fix both cases rendered identically as FAIL: 1, which is
# what cost a leg two extra full runs to disposition (a green 195/195 suite
# read exactly like a broken one). Red-first: a fixture that sleeps past a
# tiny cap while printing only "ok" lines must get the new wording; a
# fixture that prints a "not ok" line before the cap must NOT.
# --------------------------------------------------------------------------
echo "== Case 20 (HIMMEL-2401): CAP EXCEEDED (assertions passing) vs a genuine cap failure =="
sb20=$(mktemp -d "${TMPDIR:-/tmp}/rst-case20.XXXXXX") || { fail "20: mktemp failed"; sb20=""; }
if [ -n "$sb20" ]; then
cat > "$sb20/test-cleanslow.sh" <<'SHEOF'
#!/usr/bin/env bash
echo "ok - assertion one"
echo "ok - assertion two"
sleep 30
SHEOF
cat > "$sb20/test-dirtyslow.sh" <<'SHEOF'
#!/usr/bin/env bash
echo "ok - assertion one"
echo "not ok - assertion two"
sleep 30
SHEOF
cat > "$sb20/test-okayword.sh" <<'SHEOF'
#!/usr/bin/env bash
echo "okay, starting up"
echo "okay, still going"
sleep 30
SHEOF
cat > "$sb20/test-indentednotok.sh" <<'SHEOF'
#!/usr/bin/env bash
echo "ok - top-level case"
echo "  not ok - nested TAP subtest"
sleep 30
SHEOF
chmod +x "$sb20/test-cleanslow.sh" "$sb20/test-dirtyslow.sh" "$sb20/test-okayword.sh" "$sb20/test-indentednotok.sh"

out20=$(SUITE_TIMEOUT=5 env -u SUITE_TIER_MODE bash "$RUNNER" "$sb20" 2>&1)
rc20=$?

# 1. cleanslow (only "ok" lines observed) -> the new "assertions passing"
# wording, both on its own line and in the Failed suites block.
if grepq "$out20" -E '\[CAP EXCEEDED\].*test-cleanslow\.sh \(ran [0-9]+s, cap 5s\) .* assertions passing'; then
  pass "20: test-cleanslow.sh (only ok lines) renders [CAP EXCEEDED] ... assertions passing"
else
  fail "20: expected 'assertions passing' for test-cleanslow.sh; out: $out20"
fi
if grepq "$out20" -E 'test-cleanslow\.sh \(CAP EXCEEDED after [0-9]+s, cap 5s — no exit status observed, assertions passing\)'; then
  pass "20: Failed suites block carries the assertions-passing wording for test-cleanslow.sh"
else
  fail "20: expected the assertions-passing wording in Failed suites block; out: $out20"
fi

# 2. dirtyslow (a "not ok" line observed before the cap) -> the PLAIN
# CAP EXCEEDED wording, no "assertions passing" anywhere for this suite. The
# negative is the one that pins the heuristic actually reads the log instead
# of always claiming success.
if ! grepq "$out20" -E '\[CAP EXCEEDED\].*test-dirtyslow\.sh.*assertions passing'; then
  pass "20: test-dirtyslow.sh (a not-ok line present) does NOT get 'assertions passing'"
else
  fail "20: test-dirtyslow.sh wrongly rendered as assertions passing; out: $out20"
fi
if grepq "$out20" -E 'test-dirtyslow\.sh \(CAP EXCEEDED after [0-9]+s, cap 5s — no exit status observed\)$'; then
  pass "20: Failed suites block carries the PLAIN wording for test-dirtyslow.sh"
else
  fail "20: expected the plain CAP EXCEEDED wording for test-dirtyslow.sh; out: $out20"
fi

# 3a (HIMMEL-2401 codex-1). okayword (only "okay, ..." lines -- never a real
# TAP "ok" token) -> the PLAIN wording. A bare `^ok` line-prefix match would
# false-positive here; the fix anchors on a whole token.
if ! grepq "$out20" -E '\[CAP EXCEEDED\].*test-okayword\.sh.*assertions passing'; then
  pass "20: test-okayword.sh ('okay' prefix only, no real ok token) does NOT get 'assertions passing'"
else
  fail "20: test-okayword.sh wrongly rendered as assertions passing; out: $out20"
fi

# 3b (HIMMEL-2401 codex-1). indentednotok (a "not ok" line INDENTED, TAP
# subtest style) -> the PLAIN wording. A bare `^not ok` anchor would miss the
# leading whitespace and misread this suite as clean.
if ! grepq "$out20" -E '\[CAP EXCEEDED\].*test-indentednotok\.sh.*assertions passing'; then
  pass "20: test-indentednotok.sh (an indented not-ok line) does NOT get 'assertions passing'"
else
  fail "20: test-indentednotok.sh wrongly rendered as assertions passing; out: $out20"
fi

# 3c. Summary carries exactly one clean cap-exceeded (from cleanslow only —
# the other three all correctly fail to qualify).
if grepq "$out20" -F ' CAP EXCEEDED (assertions passing): 1'; then
  pass "20: Summary carries 'CAP EXCEEDED (assertions passing): 1'"
else
  fail "20: expected the Summary line 'CAP EXCEEDED (assertions passing): 1'; out: $out20"
fi

# 4. Still a real failure: exit code non-zero, all four counted under
# FAIL/TIMED OUT — a cap overrun is not green just because it carries the new
# label.
if [ "$rc20" -eq 1 ] && grepq "$out20" -F ' FAIL: 4' && grepq "$out20" -F ' TIMED OUT: 4 (counted in FAIL)'; then
  pass "20: exit code stays non-zero and all four suites still count under FAIL/TIMED OUT"
else
  fail "20: expected rc=1, FAIL: 4, TIMED OUT: 4; rc=$rc20 out: $out20"
fi

rm -rf "$sb20"
fi


rst_tally
