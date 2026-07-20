#!/usr/bin/env bash
# scripts/ci/test-run-shell-tests.sh — hermetic test for run-shell-tests.sh.
#
# Creates a mktemp sandbox with fake suites; asserts all cases the runner
# must honour:
#   1. all-pass sandbox (test-pass.sh only) → exit 0.
#   2. failing suite present (test-fail.sh) → exit 1.
#   3. --skip-extra test-skipme.sh → [SKIP], sentinel absent, exit 0.
#   4. --list <sandbox> lists-only, no sentinels, exit 0.
#   5. <sandbox> --list ≡ --list <sandbox> (same output, same exit 0).
#
# Usage: bash scripts/ci/test-run-shell-tests.sh
#
# Exit codes: 0 — all cases passed; 1 — at least one failed.
set -uo pipefail

RUNNER="$(cd "$(dirname "$0")" && pwd)/run-shell-tests.sh"

if [ ! -f "$RUNNER" ]; then
  echo "FAIL: runner not found at $RUNNER"
  exit 1
fi

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }

# --------------------------------------------------------------------------
# Each case builds its own minimal sandbox inline (only the suites that case
# needs), so the fixtures stay local to the assertion that reads them.
# --------------------------------------------------------------------------

# --------------------------------------------------------------------------
# Case 1 — only test-pass.sh → exit 0
# --------------------------------------------------------------------------
echo "== Case 1: all-pass sandbox =="
sb1=$(mktemp -d)
mkdir -p "$sb1"
cat > "$sb1/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
set -uo pipefail
exit 0
SHEOF
chmod +x "$sb1/test-pass.sh"

out1=$(bash "$RUNNER" "$sb1" 2>&1)
rc1=$?
if [ "$rc1" -eq 0 ]; then
  pass "all-pass sandbox -> exit 0"
else
  fail "all-pass sandbox -> expected exit 0 got $rc1; output: $out1"
fi
rm -rf "$sb1"

# --------------------------------------------------------------------------
# Case 2 — test-fail.sh present → exit 1
# --------------------------------------------------------------------------
echo "== Case 2: failing suite present =="
sb2=$(mktemp -d)
cat > "$sb2/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
cat > "$sb2/test-fail.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 1
SHEOF
chmod +x "$sb2/test-pass.sh" "$sb2/test-fail.sh"

out2=$(bash "$RUNNER" "$sb2" 2>&1)
rc2=$?
if [ "$rc2" -eq 1 ]; then
  pass "failing suite -> exit 1"
else
  fail "failing suite -> expected exit 1 got $rc2; output: $out2"
fi
rm -rf "$sb2"

# --------------------------------------------------------------------------
# Case 3 — --skip-extra test-skipme.sh → [SKIP], sentinel absent, exit 0
# --------------------------------------------------------------------------
echo "== Case 3: --skip-extra suppresses skipme, exit 0 =="
# A dedicated sandbox with only test-pass.sh + test-skipme.sh — no test-fail.sh,
# so the only way to exit non-zero is if the skip is NOT honoured.
sb3=$(mktemp -d)
cat > "$sb3/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
cat > "$sb3/test-skipme.sh" <<'SHEOF'
#!/usr/bin/env bash
touch "$(dirname "$0")/skipme.sentinel"
exit 1
SHEOF
chmod +x "$sb3/test-pass.sh" "$sb3/test-skipme.sh"
sentinel3="$sb3/skipme.sentinel"

out3=$(bash "$RUNNER" "$sb3" --skip-extra test-skipme.sh 2>&1)
rc3=$?

if [ "$rc3" -eq 0 ]; then
  pass "--skip-extra: exit 0 when skipme is suppressed"
else
  fail "--skip-extra: expected exit 0 got $rc3; output: $out3"
fi

# Sentinel must NOT exist — proves test-skipme.sh was not executed
if [ ! -f "$sentinel3" ]; then
  pass "--skip-extra: sentinel absent (skipme not executed)"
else
  fail "--skip-extra: sentinel present — skipme ran despite being in skip list"
fi

# Output must mention [SKIP]
if printf '%s' "$out3" | grep -qF '[SKIP]'; then
  pass "--skip-extra: [SKIP] tag present in output"
else
  fail "--skip-extra: expected [SKIP] in output, got: $out3"
fi

rm -rf "$sb3"

# --------------------------------------------------------------------------
# Case 4 — --list <sandbox> → list-only, no execution, exit 0
# --------------------------------------------------------------------------
echo "== Case 4: --list <sandbox> lists only, no execution =="
sb4=$(mktemp -d)
cat > "$sb4/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
cat > "$sb4/test-skipme.sh" <<'SHEOF'
#!/usr/bin/env bash
touch "$(dirname "$0")/list4.sentinel"
exit 0
SHEOF
chmod +x "$sb4/test-pass.sh" "$sb4/test-skipme.sh"
sentinel4="$sb4/list4.sentinel"

out4=$(bash "$RUNNER" --list "$sb4" 2>&1)
rc4=$?

if [ "$rc4" -eq 0 ]; then
  pass "--list <sandbox>: exit 0"
else
  fail "--list <sandbox>: expected exit 0 got $rc4"
fi

if [ ! -f "$sentinel4" ]; then
  pass "--list <sandbox>: no sentinel (nothing executed)"
else
  fail "--list <sandbox>: sentinel present — suite executed during --list mode"
fi

# --------------------------------------------------------------------------
# Case 5 — <sandbox> --list ≡ --list <sandbox> (position-independent grammar)
# --------------------------------------------------------------------------
echo "== Case 5: <sandbox> --list ≡ --list <sandbox> =="
sentinel5="$sb4/list5.sentinel"

out5=$(bash "$RUNNER" "$sb4" --list 2>&1)
rc5=$?

if [ "$rc5" -eq 0 ]; then
  pass "<sandbox> --list: exit 0"
else
  fail "<sandbox> --list: expected exit 0 got $rc5"
fi

if [ ! -f "$sentinel5" ]; then
  pass "<sandbox> --list: no sentinel (nothing executed)"
else
  fail "<sandbox> --list: sentinel present — suite executed"
fi

# Both forms must produce identical output
if [ "$out4" = "$out5" ]; then
  pass "--list <sandbox> and <sandbox> --list produce identical output"
else
  fail "--list <sandbox> vs <sandbox> --list differ:
  form1: $out4
  form2: $out5"
fi

rm -rf "$sb4"

# --------------------------------------------------------------------------
# Case 6 — trailing-slash scan-root: --skip-extra still matches (not un-skipped)
# Regression for: run-shell-tests.sh scripts/ emitting scripts//test-foo.sh which
# breaks the relpath strip, causing every SKIP entry to be missed.
# --------------------------------------------------------------------------
echo "== Case 6: trailing-slash scan-root does not un-skip --skip-extra entries =="
sb6=$(mktemp -d)
cat > "$sb6/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
cat > "$sb6/test-skipme.sh" <<'SHEOF'
#!/usr/bin/env bash
# Creates a sentinel to prove this suite was executed.
touch "$(dirname "$0")/skipme6.sentinel"
exit 1
SHEOF
chmod +x "$sb6/test-pass.sh" "$sb6/test-skipme.sh"
sentinel6="$sb6/skipme6.sentinel"

# Pass the scan-root WITH a trailing slash — this is the bug trigger.
out6=$(bash "$RUNNER" "${sb6}/" --skip-extra test-skipme.sh 2>&1)
rc6=$?

if [ "$rc6" -eq 0 ]; then
  pass "trailing-slash scan-root: exit 0 when skipme is suppressed"
else
  fail "trailing-slash scan-root: expected exit 0 got $rc6; output: $out6"
fi

if [ ! -f "$sentinel6" ]; then
  pass "trailing-slash scan-root: sentinel absent (skipme not executed)"
else
  fail "trailing-slash scan-root: sentinel present — skipme ran despite --skip-extra"
fi

if printf '%s' "$out6" | grep -qF '[SKIP]'; then
  pass "trailing-slash scan-root: [SKIP] tag present in output"
else
  fail "trailing-slash scan-root: expected [SKIP] in output, got: $out6"
fi

rm -rf "$sb6"

# --------------------------------------------------------------------------
# Case 7 — zero discovered suites must FAIL, not silently green (HIMMEL-1128).
# A scan root that resolves to no runnable suite (a typo'd path, an empty dir)
# used to print "OK: all 0 run suites passed" and exit 0 — a false green on a
# process-integrity gate. The runner must exit non-zero when nothing ran.
# --------------------------------------------------------------------------
echo "== Case 7: zero discovered suites -> non-zero exit =="

# 7a — non-existent scan root.
out7a=$(bash "$RUNNER" no-such-directory-xyz 2>&1)
rc7a=$?
if [ "$rc7a" -ne 0 ]; then
  pass "non-existent scan root -> non-zero exit ($rc7a)"
else
  fail "non-existent scan root -> expected non-zero got 0; output: $out7a"
fi

# 7b — empty scan root (exists, but contains no test-*.sh).
sb7=$(mktemp -d)
out7b=$(bash "$RUNNER" "$sb7" 2>&1)
rc7b=$?
if [ "$rc7b" -ne 0 ]; then
  pass "empty scan root -> non-zero exit ($rc7b)"
else
  fail "empty scan root -> expected non-zero got 0; output: $out7b"
fi

# 7c — --list of a zero-discovered root must ALSO fail (the discovered==0 guard
# fires before the --list early exit); listing an empty plan and exiting 0 is
# the same false-green footgun.
out7c=$(bash "$RUNNER" --list no-such-directory-xyz 2>&1)
rc7c=$?
if [ "$rc7c" -ne 0 ]; then
  pass "--list non-existent scan root -> non-zero exit ($rc7c)"
else
  fail "--list non-existent scan root -> expected non-zero got 0; output: $out7c"
fi

out7d=$(bash "$RUNNER" --list "$sb7" 2>&1)
rc7d=$?
if [ "$rc7d" -ne 0 ]; then
  pass "--list empty scan root -> non-zero exit ($rc7d)"
else
  fail "--list empty scan root -> expected non-zero got 0; output: $out7d"
fi
rm -rf "$sb7"

# --------------------------------------------------------------------------
# Case 8 — discovery error masked by a partial result (HIMMEL-1128, codex-adv).
# A `find` that emits at least one suite and THEN exits non-zero (unreadable
# subtree, I/O error) used to slip past: the emitted suite ran, ran>0, and the
# zero-suite guard passed → green on an incomplete scan. The runner must fail
# when discovery itself errored, even though a suite ran.
# --------------------------------------------------------------------------
echo "== Case 8: find discovery error -> non-zero exit =="
sb8=$(mktemp -d)
cat > "$sb8/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
chmod +x "$sb8/test-pass.sh"
# Fake `find` on PATH: prints one real suite path, then exits non-zero.
fakebin=$(mktemp -d)
cat > "$fakebin/find" <<SHEOF
#!/usr/bin/env bash
printf '%s\n' "$sb8/test-pass.sh"
exit 2
SHEOF
chmod +x "$fakebin/find"

out8=$(PATH="$fakebin:$PATH" bash "$RUNNER" "$sb8" 2>&1)
rc8=$?
if [ "$rc8" -ne 0 ]; then
  pass "find discovery error -> non-zero exit ($rc8)"
else
  fail "find discovery error -> expected non-zero got 0; output: $out8"
fi
rm -rf "$sb8" "$fakebin"

# --------------------------------------------------------------------------
# Case 9 — sort discovery-stage error masked by a partial result (HIMMEL-1128,
# codex-adv). Mirror of Case 8 for the second discovery stage: a `sort` that
# emits one suite and THEN exits non-zero must fail the runner, not green.
# --------------------------------------------------------------------------
echo "== Case 9: sort discovery error -> non-zero exit =="
sb9=$(mktemp -d)
cat > "$sb9/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
chmod +x "$sb9/test-pass.sh"
# Fake `sort` on PATH: prints one real suite path, then exits non-zero.
fakebin9=$(mktemp -d)
cat > "$fakebin9/sort" <<SHEOF
#!/usr/bin/env bash
printf '%s\n' "$sb9/test-pass.sh"
exit 2
SHEOF
chmod +x "$fakebin9/sort"

out9=$(PATH="$fakebin9:$PATH" bash "$RUNNER" "$sb9" 2>&1)
rc9=$?
if [ "$rc9" -ne 0 ]; then
  pass "sort discovery error -> non-zero exit ($rc9)"
else
  fail "sort discovery error -> expected non-zero got 0; output: $out9"
fi
rm -rf "$sb9" "$fakebin9"

# --------------------------------------------------------------------------
# Case 10 — all-skipped EXECUTION root must fail (ran==0), but --list of the
# same root must SUCCEED (HIMMEL-1128). Suites were discovered (discovered>0),
# so this is distinct from the empty-root case: the execution path enforces
# run>0, while --list legitimately prints the skip plan and exits 0.
# --------------------------------------------------------------------------
echo "== Case 10: all-skipped root -> execution fails, --list succeeds =="
sb10=$(mktemp -d)
cat > "$sb10/test-skipme.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
chmod +x "$sb10/test-skipme.sh"

out10a=$(bash "$RUNNER" "$sb10" --skip-extra test-skipme.sh 2>&1)
rc10a=$?
if [ "$rc10a" -ne 0 ]; then
  pass "all-skipped execution root -> non-zero exit ($rc10a)"
else
  fail "all-skipped execution root -> expected non-zero got 0; output: $out10a"
fi

out10b=$(bash "$RUNNER" --list "$sb10" --skip-extra test-skipme.sh 2>&1)
rc10b=$?
if [ "$rc10b" -eq 0 ]; then
  pass "--list all-skipped root -> exit 0 (skip plan is valid inspection)"
else
  fail "--list all-skipped root -> expected exit 0 got $rc10b; output: $out10b"
fi
rm -rf "$sb10"

# --------------------------------------------------------------------------
# Final tally
# --------------------------------------------------------------------------
echo
if [ "$failures" -eq 0 ]; then
  echo "OK: all cases passed"
  exit 0
else
  echo "FAIL: $failures case(s) failed"
  exit 1
fi
