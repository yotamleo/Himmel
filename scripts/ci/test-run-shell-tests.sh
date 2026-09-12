#!/usr/bin/env bash
# scripts/ci/test-run-shell-tests.sh — hermetic test for run-shell-tests.sh.
#
# HIMMEL-2895 split this file's expensive case groups into siblings so the
# sharded shell-unit job (HIMMEL-2872) can place them independently — the
# sharder parallelises across FILES, so one 382s file was a hard floor on
# every shard count. The family, with the measured per-group wall clock that
# decided the cut:
#
#   test-run-shell-tests.sh                  Cases 1-15, 2267, 19, 22   ~18s
#   test-run-shell-tests-timing.sh           Cases 16, 20                41s
#   test-run-shell-tests-discovery.sh        Cases 18, 21                ~4s
#   test-run-shell-tests-rotation.sh         Case 17a-17f               111s
#   test-run-shell-tests-rotation-guards.sh  Case 17g-17j               114s
#   test-run-shell-tests-rotation-cursor.sh  Case 17k-17m               102s
#
# No case was dropped, merged or renumbered: the six files' PASS lines still
# sum to the 193 this file alone printed before the split. Case 17 is the one
# case that spans more than one file (each sub-case drives a sandbox whose
# test-a.sh sleeps 25s, so the eleven of them were 327s of the 382s); every
# sub-case banner 17a..17m is still unique to exactly one file, and each of
# the three carries a header naming its siblings. Shared fixtures (the
# sandboxed lock/cursor, grepq, pass/fail, mk_rotate_sandbox, red-control)
# live in run-shell-tests-fixture.sh.
#
# Creates a mktemp sandbox with fake suites; asserts the cases the runner must
# honour:
#   1. all-pass sandbox (test-pass.sh only) → exit 0.
#   2. failing suite present (test-fail.sh) → exit 1.
#   3. --skip-extra test-skipme.sh → [SKIP], sentinel absent, exit 0.
#   4. --list <sandbox> lists-only, no sentinels, exit 0.
#   5. <sandbox> --list ≡ --list <sandbox> (same output, same exit 0).
#   6-10. scan-root grammar and discovery-failure cases (HIMMEL-1128): a
#       trailing-slash root, zero discovered suites, a masked discovery error
#       in either stage, and an all-skipped EXECUTION root.
#   11. path-specific slow-suite budgets vs an explicit SUITE_TIMEOUT
#       (HIMMEL-1542), plus the malformed-value fallback.
#   12/13. conditional-suite filter (HIMMEL-1589) and SUITE_REQUIRE_TOOL
#       capability gating (HIMMEL-1792).
#   14. SUITE_TIER / SUITE_TIER_MODE (HIMMEL-2120): fast/extended/all filter
#       plus its exit-2 invalid-mode case and its composition with SKIP_LIST
#       and SUITE_REQUIRE_TOOL.
#   15. Docs-only fast lane (HIMMEL-2166): --changed-since + an all-docs diff
#       skips the whole corpus (ran=0 reported as a pass); a mixed or empty
#       diff leaves the fast lane inert.
#   2267. _suite_timeout_for's path-specific timeout table, asserted directly
#       against the function body rather than through a full run.
#   19. --pr <N> / SUITE_REPORT_PR (HIMMEL-2383): the runner posts its
#       after-report to a PR, and does not post when it must not.
#   22. --shard <i>/<n> partitions the run list (HIMMEL-2872).
#
# Usage: bash scripts/ci/test-run-shell-tests.sh
#
# Exit codes: 0 — all cases passed; 1 — at least one failed.
#
# HIMMEL-2915: every sandbox `mktemp -d` below is templated and checked —
# a failed allocation leaves the variable empty, is reported via `fail`, and
# the case body it would have populated is skipped instead of writing at "/".
set -uo pipefail

# shellcheck source=run-shell-tests-fixture.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/run-shell-tests-fixture.sh"

# --------------------------------------------------------------------------
# Each case builds its own minimal sandbox inline (only the suites that case
# needs), so the fixtures stay local to the assertion that reads them.
# --------------------------------------------------------------------------

# --------------------------------------------------------------------------
# Case 1 — only test-pass.sh → exit 0
# --------------------------------------------------------------------------
echo "== Case 1: all-pass sandbox =="
sb1=$(mktemp -d "${TMPDIR:-/tmp}/rst-case1.XXXXXX") || { fail "1: mktemp failed"; sb1=""; }
if [ -n "$sb1" ]; then
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
fi

# --------------------------------------------------------------------------
# Case 2 — test-fail.sh present → exit 1
# --------------------------------------------------------------------------
echo "== Case 2: failing suite present =="
sb2=$(mktemp -d "${TMPDIR:-/tmp}/rst-case2.XXXXXX") || { fail "2: mktemp failed"; sb2=""; }
if [ -n "$sb2" ]; then
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
fi

# --------------------------------------------------------------------------
# Case 3 — --skip-extra test-skipme.sh → [SKIP], sentinel absent, exit 0
# --------------------------------------------------------------------------
echo "== Case 3: --skip-extra suppresses skipme, exit 0 =="
# A dedicated sandbox with only test-pass.sh + test-skipme.sh — no test-fail.sh,
# so the only way to exit non-zero is if the skip is NOT honoured.
sb3=$(mktemp -d "${TMPDIR:-/tmp}/rst-case3.XXXXXX") || { fail "3: mktemp failed"; sb3=""; }
if [ -n "$sb3" ]; then
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
if grepq "$out3" -F '[SKIP]'; then
  pass "--skip-extra: [SKIP] tag present in output"
else
  fail "--skip-extra: expected [SKIP] in output, got: $out3"
fi

rm -rf "$sb3"
fi

# --------------------------------------------------------------------------
# Case 4 — --list <sandbox> → list-only, no execution, exit 0
# --------------------------------------------------------------------------
echo "== Case 4: --list <sandbox> lists only, no execution =="
sb4=$(mktemp -d "${TMPDIR:-/tmp}/rst-case4.XXXXXX") || { fail "4: mktemp failed"; sb4=""; }
if [ -n "$sb4" ]; then
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
fi

# --------------------------------------------------------------------------
# Case 6 — trailing-slash scan-root: --skip-extra still matches (not un-skipped)
# Regression for: run-shell-tests.sh scripts/ emitting scripts//test-foo.sh which
# breaks the relpath strip, causing every SKIP entry to be missed.
# --------------------------------------------------------------------------
echo "== Case 6: trailing-slash scan-root does not un-skip --skip-extra entries =="
sb6=$(mktemp -d "${TMPDIR:-/tmp}/rst-case6.XXXXXX") || { fail "6: mktemp failed"; sb6=""; }
if [ -n "$sb6" ]; then
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

if grepq "$out6" -F '[SKIP]'; then
  pass "trailing-slash scan-root: [SKIP] tag present in output"
else
  fail "trailing-slash scan-root: expected [SKIP] in output, got: $out6"
fi

rm -rf "$sb6"
fi

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
sb7=$(mktemp -d "${TMPDIR:-/tmp}/rst-case7.XXXXXX") || { fail "7: mktemp failed"; sb7=""; }
if [ -n "$sb7" ]; then
out7b=$(bash "$RUNNER" "$sb7" 2>&1)
rc7b=$?
if [ "$rc7b" -ne 0 ]; then
  pass "empty scan root -> non-zero exit ($rc7b)"
else
  fail "empty scan root -> expected non-zero got 0; output: $out7b"
fi
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

if [ -n "$sb7" ]; then
out7d=$(bash "$RUNNER" --list "$sb7" 2>&1)
rc7d=$?
if [ "$rc7d" -ne 0 ]; then
  pass "--list empty scan root -> non-zero exit ($rc7d)"
else
  fail "--list empty scan root -> expected non-zero got 0; output: $out7d"
fi
rm -rf "$sb7"
fi

# --------------------------------------------------------------------------
# Case 8 — discovery error masked by a partial result (HIMMEL-1128, codex-adv).
# A `find` that emits at least one suite and THEN exits non-zero (unreadable
# subtree, I/O error) used to slip past: the emitted suite ran, ran>0, and the
# zero-suite guard passed → green on an incomplete scan. The runner must fail
# when discovery itself errored, even though a suite ran.
# --------------------------------------------------------------------------
echo "== Case 8: find discovery error -> non-zero exit =="
sb8=$(mktemp -d "${TMPDIR:-/tmp}/rst-case8.XXXXXX") || { fail "8: mktemp failed"; sb8=""; }
fakebin=$(mktemp -d "${TMPDIR:-/tmp}/rst-case8-fakebin.XXXXXX") || { fail "8: mktemp failed (fake find fixture)"; fakebin=""; }
# A lone successful allocation is cleaned up here rather than leaked when its
# paired mktemp fails and the combined guard below skips the case body.
[ -n "$sb8" ] && [ -z "$fakebin" ] && { rm -rf "$sb8"; sb8=""; }
[ -z "$sb8" ] && [ -n "$fakebin" ] && { rm -rf "$fakebin"; fakebin=""; }
if [ -n "$sb8" ] && [ -n "$fakebin" ]; then
cat > "$sb8/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
chmod +x "$sb8/test-pass.sh"
# Fake `find` on PATH: prints one real suite path, then exits non-zero.
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
fi

# --------------------------------------------------------------------------
# Case 9 — sort discovery-stage error masked by a partial result (HIMMEL-1128,
# codex-adv). Mirror of Case 8 for the second discovery stage: a `sort` that
# emits one suite and THEN exits non-zero must fail the runner, not green.
# --------------------------------------------------------------------------
echo "== Case 9: sort discovery error -> non-zero exit =="
sb9=$(mktemp -d "${TMPDIR:-/tmp}/rst-case9.XXXXXX") || { fail "9: mktemp failed"; sb9=""; }
fakebin9=$(mktemp -d "${TMPDIR:-/tmp}/rst-case9-fakebin.XXXXXX") || { fail "9: mktemp failed (fake sort fixture)"; fakebin9=""; }
[ -n "$sb9" ] && [ -z "$fakebin9" ] && { rm -rf "$sb9"; sb9=""; }
[ -z "$sb9" ] && [ -n "$fakebin9" ] && { rm -rf "$fakebin9"; fakebin9=""; }
if [ -n "$sb9" ] && [ -n "$fakebin9" ]; then
cat > "$sb9/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
chmod +x "$sb9/test-pass.sh"
# Fake `sort` on PATH: prints one real suite path, then exits non-zero.
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
fi

# --------------------------------------------------------------------------
# Case 10 — all-skipped EXECUTION root must fail (ran==0), but --list of the
# same root must SUCCEED (HIMMEL-1128). Suites were discovered (discovered>0),
# so this is distinct from the empty-root case: the execution path enforces
# run>0, while --list legitimately prints the skip plan and exits 0.
# --------------------------------------------------------------------------
echo "== Case 10: all-skipped root -> execution fails, --list succeeds =="
sb10=$(mktemp -d "${TMPDIR:-/tmp}/rst-case10.XXXXXX") || { fail "10: mktemp failed"; sb10=""; }
if [ -n "$sb10" ]; then
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
fi

# --------------------------------------------------------------------------
# Case 11 — known slow suites get path-specific budgets unless the operator
# supplies an explicit global SUITE_TIMEOUT (HIMMEL-1542). A sleep stub records
# the watchdog delay without waiting for it; the suite exits before the stub's
# real sleep completes, so the runner cancels the watchdog normally.
#
# This sandbox's fixture path (scripts/handover/test-arm-resume-identity.sh)
# happens to match a production SUITE_TIER_DEFAULT entry, and tier_lookup's
# fix (r2 codex-1) now makes that match land on a subtree scan like this
# one's. `env -u SUITE_TIER_MODE` throughout keeps that fixture from being
# tier-skipped under an inherited SUITE_TIER_MODE=fast/extended, the same
# inheritance hole Case 14a closes.
# --------------------------------------------------------------------------
echo "== Case 11: known slow suite budget and explicit override =="
sb11=$(mktemp -d -t himmel-suite-budget.XXXXXX) || { fail "11: mktemp failed"; sb11=""; }
if [ -n "$sb11" ]; then
mkdir -p "$sb11/scripts/handover" "$sb11/bin"
cat > "$sb11/scripts/handover/test-arm-resume-identity.sh" <<'SHEOF'
#!/usr/bin/env bash
command -p sleep 1
exit 0
SHEOF
cat > "$sb11/bin/sleep" <<'SHEOF'
#!/usr/bin/env bash
printf '%s\n' "$1" > "$SLEEP_LOG"
command -p sleep 5
SHEOF
chmod +x "$sb11/scripts/handover/test-arm-resume-identity.sh" "$sb11/bin/sleep"

SLEEP_LOG="$sb11/default-timeout.log" PATH="$sb11/bin:$PATH" \
  env -u SUITE_TIMEOUT -u SUITE_TIER_MODE bash "$RUNNER" "$sb11/scripts" >/dev/null 2>&1
rc11a=$?
if [ "$rc11a" -eq 0 ] && [ "$(cat "$sb11/default-timeout.log" 2>/dev/null)" = "2350" ]; then
  pass "known slow suite receives its 2350s path-specific budget"
else
  fail "known slow suite budget: rc=$rc11a recorded=$(cat "$sb11/default-timeout.log" 2>/dev/null) (want rc=0, 2350)"
fi

SLEEP_LOG="$sb11/explicit-timeout.log" PATH="$sb11/bin:$PATH" SUITE_TIMEOUT=7 \
  env -u SUITE_TIER_MODE bash "$RUNNER" "$sb11/scripts" >/dev/null 2>&1
rc11b=$?
if [ "$rc11b" -eq 0 ] && [ "$(cat "$sb11/explicit-timeout.log" 2>/dev/null)" = "7" ]; then
  pass "explicit SUITE_TIMEOUT overrides the path-specific budget"
else
  fail "explicit timeout override: rc=$rc11b recorded=$(cat "$sb11/explicit-timeout.log" 2>/dev/null) (want rc=0, 7)"
fi
# A MALFORMED SUITE_TIMEOUT must not count as an explicit global override
# (HIMMEL-1542 CR round 1). Presence-only detection let an empty / zero /
# non-numeric value pin every suite to the 180s fallback, which is precisely
# the rc=124 failure the path-specific budgets exist to prevent.
for bad in '' '0' 'abc'; do
  log11="$sb11/bad-${bad:-empty}.log"
  SLEEP_LOG="$log11" PATH="$sb11/bin:$PATH" SUITE_TIMEOUT="$bad" \
    env -u SUITE_TIER_MODE bash "$RUNNER" "$sb11/scripts" >/dev/null 2>&1
  rc11c=$?
  if [ "$rc11c" -eq 0 ] && [ "$(cat "$log11" 2>/dev/null)" = "2350" ]; then
    pass "malformed SUITE_TIMEOUT='$bad' falls back to the path-specific budget"
  else
    fail "malformed SUITE_TIMEOUT='$bad': rc=$rc11c recorded=$(cat "$log11" 2>/dev/null) (want rc=0, 2350)"
  fi
done
rm -rf "$sb11"
fi

# --------------------------------------------------------------------------
# Case 12 — conditional-suite filter (HIMMEL-1589).
#   a. flag absent           -> conditional suite RUNS (filter inert)
#   b. flag + matching change-> conditional suite RUNS
#   c. flag + no match       -> conditional suite SKIPped with the reason
#   d. bad ref               -> fail-open: NOTE printed, every suite runs
# The changed-set the runner diffs against is the REAL repo (it cds to its own
# REPO_ROOT), so b/c drive it through a fake `git` on PATH that emits a
# controlled `diff --name-only` -- the same faking idiom cases 8/9/11 use for
# find/sort/sleep. Only the runner's two changed-set calls hit it; the stub
# suites call no git. The conditional suite under test is test-propagate-public.sh
# (the one real entry in the runner's SUITE_CONDITIONAL table), so a sandbox
# stub of that name exercises the real table, not a hand-rolled one.
# --------------------------------------------------------------------------
echo "== Case 12: conditional-suite filter (--changed-since) =="

# The fixtures live under $1/scripts/ and the runner is pointed at that dir,
# because the built-in table entries are repo-root-relative
# ("scripts/test-propagate-public.sh"). A flat sandbox would not match them and
# the case would silently stop exercising the production table (HIMMEL-2260).
# The nested namesake is the collision control: same basename, different
# directory, so it must NOT inherit the conditional rule.
mk_cond_sandbox() {  # $1 = sandbox dir; test-pass.sh + the prop stub + a namesake
  mkdir -p "$1/scripts/nested"
  cat > "$1/scripts/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
  cat > "$1/scripts/test-propagate-public.sh" <<'SHEOF'
#!/usr/bin/env bash
touch "$(dirname "$0")/prop-ran.sentinel"
exit 0
SHEOF
  cat > "$1/scripts/nested/test-propagate-public.sh" <<'SHEOF'
#!/usr/bin/env bash
touch "$(dirname "$0")/../namesake-ran.sentinel"
exit 0
SHEOF
  chmod +x "$1/scripts/test-pass.sh" "$1/scripts/test-propagate-public.sh" \
           "$1/scripts/nested/test-propagate-public.sh"
}

# Fake `git`: emits a controlled `diff --name-only` (contents of $GIT_FAKE_DIFF)
# and an empty untracked set, so the runner's changed_set is deterministic
# regardless of the real worktree's dirty state. Exits 0 for both so the
# runner's fail-open `&&` chain resolves to "filter active".
fakebin12=$(mktemp -d "${TMPDIR:-/tmp}/rst-case12-fakebin.XXXXXX") || { fail "12: mktemp failed (fake git fixture)"; fakebin12=""; }
if [ -n "$fakebin12" ]; then
cat > "$fakebin12/git" <<'SHEOF'
#!/usr/bin/env bash
case "$1" in
  rev-parse)
    # The runner resolves the ref via `rev-parse --end-of-options "<ref>^{commit}"`
    # BEFORE diffing (HIMMEL-1589). Mimic real git: an OPTION-shaped value
    # (--exit-code, etc.) is not a commit and does not resolve -> exit 1, which
    # drives the runner's fail-open path; anything else resolves to a stable
    # pseudo-SHA so the runner feeds `git diff` a non-empty commit.
    _ref=
    for _a in "$@"; do _ref="$_a"; done   # last arg, e.g. "HEAD^{commit}"
    case "$_ref" in
      -*) exit 1 ;;                       # option-shaped: not a commit
      *) printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n'; exit 0 ;;
    esac
    ;;
  diff)
    [ -f "${GIT_FAKE_DIFF:-}" ] && cat "${GIT_FAKE_DIFF:-}"
    ;;
  ls-files)
    [ -f "${GIT_FAKE_UNTRACKED:-}" ] && cat "${GIT_FAKE_UNTRACKED:-}"
    ;;
esac
exit 0
SHEOF
chmod +x "$fakebin12/git"

# 12a — flag absent: conditional suite RUNS (filter is inert without the flag).
sb12a=$(mktemp -d "${TMPDIR:-/tmp}/rst-case12a.XXXXXX") || { fail "12a: mktemp failed"; sb12a=""; }
if [ -n "$sb12a" ]; then
mk_cond_sandbox "$sb12a"
sentinel12a="$sb12a/scripts/prop-ran.sentinel"
out12a=$(bash "$RUNNER" "$sb12a/scripts" 2>&1); rc12a=$?
if [ "$rc12a" -eq 0 ] && [ -f "$sentinel12a" ]; then
  pass "12a: flag absent -> conditional suite runs"
else
  fail "12a: flag absent expected run (rc=0, sentinel); rc=$rc12a sentinel=$([ -f "$sentinel12a" ] && echo yes || echo no); out: $out12a"
fi
rm -rf "$sb12a"
fi

# 12b — flag + matching change (a propagation path): conditional suite RUNS.
sb12b=$(mktemp -d "${TMPDIR:-/tmp}/rst-case12b.XXXXXX") || { fail "12b: mktemp failed"; sb12b=""; }
if [ -n "$sb12b" ]; then
mk_cond_sandbox "$sb12b"
sentinel12b="$sb12b/scripts/prop-ran.sentinel"
diff12b="$sb12b/diff.txt"; printf 'scripts/propagate-public.sh\n' > "$diff12b"
out12b=$(GIT_FAKE_DIFF="$diff12b" PATH="$fakebin12:$PATH" bash "$RUNNER" "$sb12b/scripts" --changed-since HEAD 2>&1); rc12b=$?
if [ "$rc12b" -eq 0 ] && [ -f "$sentinel12b" ] && ! grepq "$out12b" "conditional: no changed path matches"; then
  pass "12b: flag + matching change -> conditional suite runs"
else
  fail "12b: expected run on matching change; rc=$rc12b sentinel=$([ -f "$sentinel12b" ] && echo yes || echo no); out: $out12b"
fi
rm -rf "$sb12b"
fi

# 12c — flag + NO matching change: conditional suite SKIPped with the reason.
# A real path that does NOT match the propagation ERE.
sb12c=$(mktemp -d "${TMPDIR:-/tmp}/rst-case12c.XXXXXX") || { fail "12c: mktemp failed"; sb12c=""; }
if [ -n "$sb12c" ]; then
mk_cond_sandbox "$sb12c"
sentinel12c="$sb12c/scripts/prop-ran.sentinel"
diff12c="$sb12c/diff.txt"; printf 'scripts/ci/run-shell-tests.sh\n' > "$diff12c"
out12c=$(GIT_FAKE_DIFF="$diff12c" PATH="$fakebin12:$PATH" bash "$RUNNER" "$sb12c/scripts" --changed-since HEAD 2>&1); rc12c=$?
if [ "$rc12c" -eq 0 ] && [ ! -f "$sentinel12c" ] && grepq "$out12c" "conditional: no changed path matches"; then
  pass "12c: flag + no matching change -> conditional suite SKIPped with reason"
else
  fail "12c: expected SKIP with reason; rc=$rc12c sentinel=$([ -f "$sentinel12c" ] && echo yes || echo no); out: $out12c"
fi
# Collision control (HIMMEL-2260, CR): scripts/nested/test-propagate-public.sh
# shares its BASENAME with the SUITE_CONDITIONAL entry but is a different
# suite, so it must RUN even while the real entry is conditional-skipped. An
# under-qualified entry would suffix-match it and silently withhold an
# unrelated suite from the run.
if [ -f "$sb12c/scripts/namesake-ran.sentinel" ]; then
  pass "12c: the nested same-basename suite still RAN — the conditional entry did not suffix-match it"
else
  fail "12c: scripts/nested/test-propagate-public.sh was withheld by the conditional entry; out: $out12c"
fi
rm -rf "$sb12c"
fi

# 12d — bad ref: fail-open (REAL git, no fake). NOTE printed, every suite runs.
sb12d=$(mktemp -d "${TMPDIR:-/tmp}/rst-case12d.XXXXXX") || { fail "12d: mktemp failed"; sb12d=""; }
if [ -n "$sb12d" ]; then
mk_cond_sandbox "$sb12d"
sentinel12d="$sb12d/scripts/prop-ran.sentinel"
out12d=$(bash "$RUNNER" "$sb12d/scripts" --changed-since definitely-not-a-ref-xyz-1589 2>&1); rc12d=$?
if [ "$rc12d" -eq 0 ] && [ -f "$sentinel12d" ] && grepq "$out12d" "running every suite"; then
  pass "12d: bad ref -> fail-open runs every suite (NOTE printed)"
else
  fail "12d: expected fail-open run-all; rc=$rc12d sentinel=$([ -f "$sentinel12d" ] && echo yes || echo no); out: $out12d"
fi
rm -rf "$sb12d"
fi

# 12e — option-shaped value (--changed-since --exit-code): MUST fail-open, never
# silently skip. A raw --changed-since value interpolated into `git diff` is
# parsed by git as an OPTION, not a ref: `git diff --name-only --exit-code` on a
# clean tree SUCCEEDS with EMPTY output, which (pre-fix) set
# conditional_filter_active=1 over an empty changed_set and skipped every
# conditional suite — a false green, the inverse of the fail-open contract.
# The fake `git` makes that clean-tree condition deterministic: rev-parse fails
# (an option is not a commit) so the FIXED runner fails-open, while `diff` with
# no GIT_FAKE_DIFF returns empty+success, the exact state that fooled the
# UNFIXED runner. No GIT_FAKE_DIFF is set on purpose.
sb12e=$(mktemp -d "${TMPDIR:-/tmp}/rst-case12e.XXXXXX") || { fail "12e: mktemp failed"; sb12e=""; }
if [ -n "$sb12e" ]; then
mk_cond_sandbox "$sb12e"
sentinel12e="$sb12e/scripts/prop-ran.sentinel"
out12e=$(PATH="$fakebin12:$PATH" bash "$RUNNER" "$sb12e/scripts" --changed-since --exit-code 2>&1); rc12e=$?
if [ "$rc12e" -eq 0 ] && [ -f "$sentinel12e" ] && grepq "$out12e" "running every suite"; then
  pass "12e: option-shaped --changed-since value -> fail-open runs every suite (NOTE printed)"
else
  fail "12e: expected fail-open run-all for option-shaped value; rc=$rc12e sentinel=$([ -f "$sentinel12e" ] && echo yes || echo no); out: $out12e"
fi
rm -rf "$sb12e"
fi

rm -rf "$fakebin12"
fi

# --------------------------------------------------------------------------
# Case 13 — capability-conditional suites / SUITE_REQUIRE_TOOL (HIMMEL-1792).
#   a. the REAL table entry (test-claude-openrouter-pwsh.sh / pwsh) against
#      this host's actual pwsh availability: RUNS where pwsh exists (the point
#      of the ticket — the suite must not be a never-run), loud [SKIP] with the
#      capability reason where it does not. Host-conditional by design: the
#      runner's contract IS per-host capability.
#   b. env override with a guaranteed-absent tool: the skip branch asserted
#      deterministically on EVERY host, including ones that have pwsh.
#   c. --list reflects the same disposition in the plan.
# --------------------------------------------------------------------------
echo "== Case 13: capability-conditional suites (SUITE_REQUIRE_TOOL) =="

# Same scripts/ layer as mk_cond_sandbox, and for the same reason: the built-in
# SUITE_REQUIRE_TOOL entry is repo-root-relative (HIMMEL-2260).
mk_cap_sandbox() {  # $1 = sandbox dir; test-pass.sh + the pwsh-suite stub
  mkdir -p "$1/scripts"
  cat > "$1/scripts/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
  cat > "$1/scripts/test-claude-openrouter-pwsh.sh" <<'SHEOF'
#!/usr/bin/env bash
touch "$(dirname "$0")/cap-ran.sentinel"
exit 0
SHEOF
  chmod +x "$1/scripts/test-pass.sh" "$1/scripts/test-claude-openrouter-pwsh.sh"
}

# 13a — the real table entry; both branches must stay loud and attributed.
sb13a=$(mktemp -d "${TMPDIR:-/tmp}/rst-case13a.XXXXXX") || { fail "13a: mktemp failed"; sb13a=""; }
if [ -n "$sb13a" ]; then
mk_cap_sandbox "$sb13a"
sentinel13a="$sb13a/scripts/cap-ran.sentinel"
out13a=$(bash "$RUNNER" "$sb13a/scripts" 2>&1); rc13a=$?
if command -v pwsh >/dev/null 2>&1; then
  if [ "$rc13a" -eq 0 ] && [ -f "$sentinel13a" ] && ! grepq "$out13a" -F '[SKIP]'; then
    pass "13a: pwsh present -> capability suite RUNS (not SKIP_LIST dead weight)"
  else
    fail "13a: pwsh present -> expected the suite to run; rc=$rc13a sentinel=$([ -f "$sentinel13a" ] && echo yes || echo no); out: $out13a"
  fi
else
  if [ "$rc13a" -eq 0 ] && [ ! -f "$sentinel13a" ] && grepq "$out13a" "capability: pwsh not on PATH"; then
    pass "13a: pwsh absent -> capability suite SKIPped loudly with reason"
  else
    fail "13a: pwsh absent -> expected loud capability skip; rc=$rc13a sentinel=$([ -f "$sentinel13a" ] && echo yes || echo no); out: $out13a"
  fi
fi
rm -rf "$sb13a"
fi

# 13b — deterministic skip branch: a tool that cannot exist, injected via the
# env override the runner exposes for exactly this.
sb13b=$(mktemp -d "${TMPDIR:-/tmp}/rst-case13b.XXXXXX") || { fail "13b: mktemp failed"; sb13b=""; }
if [ -n "$sb13b" ]; then
mk_cap_sandbox "$sb13b"
sentinel13b="$sb13b/scripts/cap-ran.sentinel"
out13b=$(SUITE_REQUIRE_TOOL="test-claude-openrouter-pwsh.sh  himmel-no-such-tool-1792  # deterministic absent-tool stub" \
  bash "$RUNNER" "$sb13b/scripts" 2>&1); rc13b=$?
if [ "$rc13b" -eq 0 ] && [ ! -f "$sentinel13b" ] && grepq "$out13b" "capability: himmel-no-such-tool-1792 not on PATH"; then
  pass "13b: absent tool -> capability suite SKIPped loudly, not executed"
else
  fail "13b: expected loud capability skip; rc=$rc13b sentinel=$([ -f "$sentinel13b" ] && echo yes || echo no); out: $out13b"
fi

# 13c — --list shows the capability skip in the plan (inspection without run).
out13c=$(SUITE_REQUIRE_TOOL="test-claude-openrouter-pwsh.sh  himmel-no-such-tool-1792  # deterministic absent-tool stub" \
  bash "$RUNNER" --list "$sb13b/scripts" 2>&1); rc13c=$?
if [ "$rc13c" -eq 0 ] && grepq "$out13c" "capability:"; then
  pass "13c: --list shows the capability skip in the plan"
else
  fail "13c: --list expected a capability [SKIP] plan line; rc=$rc13c out: $out13c"
fi
rm -rf "$sb13b"
fi

# --------------------------------------------------------------------------
# Case 14 — tier suites / SUITE_TIER + SUITE_TIER_MODE (HIMMEL-2120).
#   The production SUITE_TIER table now carries three extended entries (Task
#   6), but every case here still drives the filter through the SUITE_TIER
#   env override — the same seam SUITE_REQUIRE_TOOL already exposes for its
#   own self-test — so the mechanism is exercised without touching production.
#   Precedence under test: SKIP_LIST -> tier -> SUITE_CONDITIONAL ->
#   SUITE_REQUIRE_TOOL (r2 F12).
# --------------------------------------------------------------------------
echo "== Case 14: tier suites (SUITE_TIER / SUITE_TIER_MODE) =="

mk_tier_sandbox() {  # $1 = sandbox dir; an unlisted suite + one extended-tier suite
  mkdir -p "$1"
  cat > "$1/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
touch "$(dirname "$0")/pass-ran.sentinel"
exit 0
SHEOF
  cat > "$1/test-tier-extended.sh" <<'SHEOF'
#!/usr/bin/env bash
touch "$(dirname "$0")/tier-ran.sentinel"
exit 0
SHEOF
  chmod +x "$1/test-pass.sh" "$1/test-tier-extended.sh"
}
TIER_FIXTURE='test-tier-extended.sh  extended  # fixture: HIMMEL-2120 tier test'

# 14a — mode unset: byte-identical to no filter, both suites run. `env -u`
# (same idiom as Case 11's SUITE_TIMEOUT isolation) so a SUITE_TIER_MODE
# inherited from the launching shell (e.g. a run under SUITE_TIER_MODE=fast)
# can't masquerade as "unset" and break this case.
sb14a=$(mktemp -d "${TMPDIR:-/tmp}/himmel-tier-14a.XXXXXX") || { fail "14a: mktemp failed"; sb14a=""; }
if [ -n "$sb14a" ]; then
mk_tier_sandbox "$sb14a"
out14a=$(SUITE_TIER="$TIER_FIXTURE" env -u SUITE_TIER_MODE bash "$RUNNER" "$sb14a" 2>&1); rc14a=$?
if [ "$rc14a" -eq 0 ] && [ -f "$sb14a/pass-ran.sentinel" ] && [ -f "$sb14a/tier-ran.sentinel" ]; then
  pass "14a: mode unset -> extended-listed suite runs (filter inert)"
else
  fail "14a: expected both suites to run; rc=$rc14a out: $out14a"
fi
rm -rf "$sb14a"
fi

# 14b — mode=all: same as unset, both run.
sb14b=$(mktemp -d "${TMPDIR:-/tmp}/himmel-tier-14b.XXXXXX") || { fail "14b: mktemp failed"; sb14b=""; }
if [ -n "$sb14b" ]; then
mk_tier_sandbox "$sb14b"
out14b=$(SUITE_TIER="$TIER_FIXTURE" SUITE_TIER_MODE=all bash "$RUNNER" "$sb14b" 2>&1); rc14b=$?
if [ "$rc14b" -eq 0 ] && [ -f "$sb14b/pass-ran.sentinel" ] && [ -f "$sb14b/tier-ran.sentinel" ]; then
  pass "14b: mode=all -> extended-listed suite runs"
else
  fail "14b: expected both suites to run; rc=$rc14b out: $out14b"
fi
rm -rf "$sb14b"
fi

# 14c — mode=fast: extended-listed suite SKIPped loudly; the unlisted suite
# still runs (also covers "unlisted suite runs in fast" from the brief).
sb14c=$(mktemp -d "${TMPDIR:-/tmp}/himmel-tier-14c.XXXXXX") || { fail "14c: mktemp failed"; sb14c=""; }
if [ -n "$sb14c" ]; then
mk_tier_sandbox "$sb14c"
out14c=$(SUITE_TIER="$TIER_FIXTURE" SUITE_TIER_MODE=fast bash "$RUNNER" "$sb14c" 2>&1); rc14c=$?
if [ "$rc14c" -eq 0 ] && [ -f "$sb14c/pass-ran.sentinel" ] && [ ! -f "$sb14c/tier-ran.sentinel" ] \
   && grepq "$out14c" "tier: extended (SUITE_TIER_MODE=fast)"; then
  pass "14c: mode=fast -> extended-listed suite SKIPped loudly, unlisted suite runs"
else
  fail "14c: expected loud tier skip + unlisted run; rc=$rc14c pass-ran=$([ -f "$sb14c/pass-ran.sentinel" ] && echo yes || echo no) tier-ran=$([ -f "$sb14c/tier-ran.sentinel" ] && echo yes || echo no); out: $out14c"
fi
rm -rf "$sb14c"
fi

# 14d — mode=extended: runs ONLY the extended-listed suite; the unlisted
# suite is SKIPped.
sb14d=$(mktemp -d "${TMPDIR:-/tmp}/himmel-tier-14d.XXXXXX") || { fail "14d: mktemp failed"; sb14d=""; }
if [ -n "$sb14d" ]; then
mk_tier_sandbox "$sb14d"
out14d=$(SUITE_TIER="$TIER_FIXTURE" SUITE_TIER_MODE=extended bash "$RUNNER" "$sb14d" 2>&1); rc14d=$?
if [ "$rc14d" -eq 0 ] && [ ! -f "$sb14d/pass-ran.sentinel" ] && [ -f "$sb14d/tier-ran.sentinel" ] \
   && grepq "$out14d" "tier: not extended-listed"; then
  pass "14d: mode=extended -> runs only the extended-listed suite"
else
  fail "14d: expected extended-only run; rc=$rc14d pass-ran=$([ -f "$sb14d/pass-ran.sentinel" ] && echo yes || echo no) tier-ran=$([ -f "$sb14d/tier-ran.sentinel" ] && echo yes || echo no); out: $out14d"
fi
rm -rf "$sb14d"
fi

# 14e — invalid SUITE_TIER_MODE: loud error, exit 2.
sb14e=$(mktemp -d "${TMPDIR:-/tmp}/himmel-tier-14e.XXXXXX") || { fail "14e: mktemp failed"; sb14e=""; }
if [ -n "$sb14e" ]; then
mk_tier_sandbox "$sb14e"
out14e=$(SUITE_TIER_MODE=bogus bash "$RUNNER" "$sb14e" 2>&1); rc14e=$?
if [ "$rc14e" -eq 2 ] && grepq "$out14e" "SUITE_TIER_MODE"; then
  pass "14e: invalid SUITE_TIER_MODE -> exit 2 with a loud error"
else
  fail "14e: expected exit 2 + error mentioning SUITE_TIER_MODE; rc=$rc14e out: $out14e"
fi
rm -rf "$sb14e"
fi

# 14f — composition (r2 F12): a suite both extended-listed AND SKIP_LISTed
# never runs, even in mode=all where the tier table alone (with no mode
# narrowing anything) would otherwise let it run — isolates that SKIP_LIST
# wins independent of SUITE_TIER_MODE. The sandbox's unlisted test-pass.sh
# still runs under mode=all, so ran>0 and rc stays 0.
sb14f=$(mktemp -d "${TMPDIR:-/tmp}/himmel-tier-14f.XXXXXX") || { fail "14f: mktemp failed"; sb14f=""; }
if [ -n "$sb14f" ]; then
mk_tier_sandbox "$sb14f"
out14f=$(SUITE_TIER="$TIER_FIXTURE" SUITE_TIER_MODE=all \
  bash "$RUNNER" "$sb14f" --skip-extra test-tier-extended.sh 2>&1); rc14f=$?
if [ "$rc14f" -eq 0 ] && [ -f "$sb14f/pass-ran.sentinel" ] && [ ! -f "$sb14f/tier-ran.sentinel" ] \
   && grepq "$out14f" "skipped via --skip-extra"; then
  pass "14f: SKIP_LIST wins over an extended-tier listing (never runs)"
else
  fail "14f: expected SKIP_LIST to win over tier; rc=$rc14f tier-ran=$([ -f "$sb14f/tier-ran.sentinel" ] && echo yes || echo no); out: $out14f"
fi
rm -rf "$sb14f"
fi

# 14g — composition (r2 F12): an extended-listed suite whose required tool is
# absent still loud-skips ON THE TOOL in extended mode — proves tier is
# checked BEFORE SUITE_REQUIRE_TOOL (the suite clears the tier gate, then
# hits the capability gate), not that tier alone decided it. A second
# extended-listed, tool-satisfied suite keeps ran>0 in mode=extended (where
# the sandbox's unlisted test-pass.sh is itself tier-skipped), so a passing
# run here is evidence of the composition, not an all-skipped sandbox.
sb14g=$(mktemp -d "${TMPDIR:-/tmp}/himmel-tier-14g.XXXXXX") || { fail "14g: mktemp failed"; sb14g=""; }
if [ -n "$sb14g" ]; then
mk_tier_sandbox "$sb14g"
cat > "$sb14g/test-tier-extended-ok.sh" <<'SHEOF'
#!/usr/bin/env bash
touch "$(dirname "$0")/tier-ok-ran.sentinel"
exit 0
SHEOF
chmod +x "$sb14g/test-tier-extended-ok.sh"
tier14g="$TIER_FIXTURE
test-tier-extended-ok.sh  extended  # fixture: HIMMEL-2120 tier test (tool-satisfied twin)"
out14g=$(SUITE_TIER="$tier14g" SUITE_TIER_MODE=extended \
  SUITE_REQUIRE_TOOL='test-tier-extended.sh  himmel-no-such-tool-2120  # deterministic absent-tool stub' \
  bash "$RUNNER" "$sb14g" 2>&1); rc14g=$?
if [ "$rc14g" -eq 0 ] && [ ! -f "$sb14g/tier-ran.sentinel" ] && [ -f "$sb14g/tier-ok-ran.sentinel" ] \
   && grepq "$out14g" "capability: himmel-no-such-tool-2120 not on PATH"; then
  pass "14g: extended-listed suite with a missing required tool loud-skips on the tool"
else
  fail "14g: expected a capability skip for the extended-listed suite; rc=$rc14g tier-ran=$([ -f "$sb14g/tier-ran.sentinel" ] && echo yes || echo no); out: $out14g"
fi
rm -rf "$sb14g"
fi

# 14h — subtree scan (r2 codex-1): the production SUITE_TIER table lists
# repo-root-relative paths ("scripts/handover/..."), but a subtree scan (e.g.
# `run-shell-tests.sh scripts/handover`) strips the scan root, so tier_lookup
# receives just the bare filename. An exact-only match would silently miss
# every listed suite here (verified against production: SUITE_TIER_MODE=fast
# on a plain full scan ran all three extended-listed suites instead of
# skipping them) and fail OPEN to the fast tier. Reproduce that shape with a
# fixture: the suite lives under a subdirectory, the table lists it with that
# subdirectory prefix, and the scan root IS the subdirectory.
sb14h=$(mktemp -d "${TMPDIR:-/tmp}/himmel-tier-14h.XXXXXX") || { fail "14h: mktemp failed"; sb14h=""; }
if [ -n "$sb14h" ]; then
mkdir -p "$sb14h/sub"; mk_tier_sandbox "$sb14h/sub"
tier14h='sub/test-tier-extended.sh  extended  # fixture: HIMMEL-2120 subtree-scan tier test'
out14h=$(SUITE_TIER="$tier14h" SUITE_TIER_MODE=fast bash "$RUNNER" "$sb14h/sub" 2>&1); rc14h=$?
if [ "$rc14h" -eq 0 ] && [ -f "$sb14h/sub/pass-ran.sentinel" ] && [ ! -f "$sb14h/sub/tier-ran.sentinel" ] \
   && grepq "$out14h" "tier: extended (SUITE_TIER_MODE=fast)"; then
  pass "14h: subtree scan still classifies an extended-listed suite (relpath vs repo-root-relative table path)"
else
  fail "14h: expected subtree-scan tier classification to hold; rc=$rc14h pass-ran=$([ -f "$sb14h/sub/pass-ran.sentinel" ] && echo yes || echo no) tier-ran=$([ -f "$sb14h/sub/tier-ran.sentinel" ] && echo yes || echo no); out: $out14h"
fi
rm -rf "$sb14h"
fi

# --------------------------------------------------------------------------
# Case 15 — docs-only fast lane (HIMMEL-2166).
#   a. docs-only diff (every changed path *.md or under docs/) -> every suite
#      [SKIP]ped, ran=0 reported as a genuine pass (exit 0), not the
#      HIMMEL-1128 false-green refusal.
#   b. mixed diff (one non-docs path among several docs paths) -> the fast
#      lane does NOT fire; suites run as normal (--changed-since alone does
#      not skip anything here, since neither fixture suite is SUITE_CONDITIONAL
#      or SUITE_TIER-listed).
#   c. empty diff (changed_set has no paths at all) -> not treated as
#      docs-only; suites run as normal.
# Same fake-`git` idiom as Case 12: only the runner's changed-set calls hit it.
# --------------------------------------------------------------------------
echo "== Case 15: docs-only fast lane (--changed-since) =="

mk_docs_sandbox() {  # $1 = sandbox dir; two plain suites, no tier/conditional listing
  mkdir -p "$1"
  cat > "$1/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
touch "$(dirname "$0")/pass-ran.sentinel"
exit 0
SHEOF
  cat > "$1/test-pass2.sh" <<'SHEOF'
#!/usr/bin/env bash
touch "$(dirname "$0")/pass2-ran.sentinel"
exit 0
SHEOF
  chmod +x "$1/test-pass.sh" "$1/test-pass2.sh"
}

fakebin15=$(mktemp -d "${TMPDIR:-/tmp}/rst-case15-fakebin.XXXXXX") || { fail "15: mktemp failed (fake git fixture)"; fakebin15=""; }
if [ -n "$fakebin15" ]; then
cat > "$fakebin15/git" <<'SHEOF'
#!/usr/bin/env bash
case "$1" in
  rev-parse)
    _ref=
    for _a in "$@"; do _ref="$_a"; done
    case "$_ref" in
      -*) exit 1 ;;
      *) printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n'; exit 0 ;;
    esac
    ;;
  diff)
    [ -f "${GIT_FAKE_DIFF:-}" ] && cat "${GIT_FAKE_DIFF:-}"
    ;;
  ls-files)
    [ -f "${GIT_FAKE_UNTRACKED:-}" ] && cat "${GIT_FAKE_UNTRACKED:-}"
    ;;
esac
exit 0
SHEOF
chmod +x "$fakebin15/git"

# 15a — docs-only diff: BOTH suites [SKIP]ped, exit 0, ran=0 reported as a pass.
sb15a=$(mktemp -d "${TMPDIR:-/tmp}/rst-case15a.XXXXXX") || { fail "15a: mktemp failed"; sb15a=""; }
if [ -n "$sb15a" ]; then
mk_docs_sandbox "$sb15a"
diff15a="$sb15a/diff.txt"; printf 'docs/foo.md\nREADME.md\n' > "$diff15a"
out15a=$(GIT_FAKE_DIFF="$diff15a" PATH="$fakebin15:$PATH" bash "$RUNNER" "$sb15a" --changed-since HEAD 2>&1); rc15a=$?
if [ "$rc15a" -eq 0 ] && [ ! -f "$sb15a/pass-ran.sentinel" ] && [ ! -f "$sb15a/pass2-ran.sentinel" ] \
   && grepq "$out15a" -F "docs-only diff (no code path changed)" \
   && grepq "$out15a" -F "docs-only diff — 0 shell suites needed"; then
  pass "15a: docs-only diff -> every suite SKIPped, exit 0 (not the false-green refusal)"
else
  fail "15a: expected docs-only skip-all + exit 0; rc=$rc15a pass-ran=$([ -f "$sb15a/pass-ran.sentinel" ] && echo yes || echo no) pass2-ran=$([ -f "$sb15a/pass2-ran.sentinel" ] && echo yes || echo no); out: $out15a"
fi
rm -rf "$sb15a"
fi

# 15b — mixed diff: one non-docs path among docs paths -> fast lane inert,
# both suites run normally.
sb15b=$(mktemp -d "${TMPDIR:-/tmp}/rst-case15b.XXXXXX") || { fail "15b: mktemp failed"; sb15b=""; }
if [ -n "$sb15b" ]; then
mk_docs_sandbox "$sb15b"
diff15b="$sb15b/diff.txt"; printf 'docs/foo.md\nscripts/ci/run-shell-tests.sh\n' > "$diff15b"
out15b=$(GIT_FAKE_DIFF="$diff15b" PATH="$fakebin15:$PATH" bash "$RUNNER" "$sb15b" --changed-since HEAD 2>&1); rc15b=$?
if [ "$rc15b" -eq 0 ] && [ -f "$sb15b/pass-ran.sentinel" ] && [ -f "$sb15b/pass2-ran.sentinel" ] \
   && ! grepq "$out15b" -F "docs-only"; then
  pass "15b: mixed diff -> fast lane inert, both suites run"
else
  fail "15b: expected both suites to run (fast lane inert); rc=$rc15b pass-ran=$([ -f "$sb15b/pass-ran.sentinel" ] && echo yes || echo no) pass2-ran=$([ -f "$sb15b/pass2-ran.sentinel" ] && echo yes || echo no); out: $out15b"
fi
rm -rf "$sb15b"
fi

# 15c — empty diff (no tracked or untracked paths at all): NOT docs-only —
# nothing to base that claim on — so both suites run as normal.
sb15c=$(mktemp -d "${TMPDIR:-/tmp}/rst-case15c.XXXXXX") || { fail "15c: mktemp failed"; sb15c=""; }
if [ -n "$sb15c" ]; then
mk_docs_sandbox "$sb15c"
diff15c="$sb15c/diff.txt"; : > "$diff15c"
out15c=$(GIT_FAKE_DIFF="$diff15c" PATH="$fakebin15:$PATH" bash "$RUNNER" "$sb15c" --changed-since HEAD 2>&1); rc15c=$?
if [ "$rc15c" -eq 0 ] && [ -f "$sb15c/pass-ran.sentinel" ] && [ -f "$sb15c/pass2-ran.sentinel" ] \
   && ! grepq "$out15c" -F "docs-only"; then
  pass "15c: empty diff -> not treated as docs-only, both suites run"
else
  fail "15c: expected both suites to run (empty diff is not docs-only); rc=$rc15c pass-ran=$([ -f "$sb15c/pass-ran.sentinel" ] && echo yes || echo no) pass2-ran=$([ -f "$sb15c/pass2-ran.sentinel" ] && echo yes || echo no); out: $out15c"
fi
rm -rf "$sb15c"
fi

rm -rf "$fakebin15"
fi


# --------------------------------------------------------------------------
# Case 2267 — _suite_timeout_for's HIMMEL-2267 timeout-table arms
# (scripts/test-propagate-public.sh, scripts/ci/test-suite-concurrency.sh, and
# until HIMMEL-2895 this file's own 1200s arm) were new/revised on that branch
# and had no assertion. Each arm uses a dual "path|*/path" pattern because the
# real caller passes a scan-root-prefixed path (see the comment above
# tier_lookup): a pattern that fails to match doesn't error, it silently
# falls through to the 600s default and the suite gets killed mid-run same
# as before -- worth a regression test on both forms.
#
# No established harness in this file sources the runner's internals in
# isolation (Case 11 exercises _suite_timeout_for only indirectly, through a
# full sandboxed run), so this pulls the function body verbatim out of
# run-shell-tests.sh and sources it in a subshell -- the pragmatic fallback,
# and much cheaper than a real suite run per assertion.
# --------------------------------------------------------------------------
echo "== Case 2267: _suite_timeout_for path-specific timeouts =="
fn2267=$(awk '/^_suite_timeout_for\(\) \{/{f=1} f{print} f && /^}/{exit}' "$RUNNER")
if [ -z "$fn2267" ]; then
  fail "2267: could not extract _suite_timeout_for() from $RUNNER"
else
  check_timeout_2267() {  # $1=suite path as passed to _suite_timeout_for; $2=expected timeout
    local got
    # shellcheck disable=SC2034 # SUITE_TIMEOUT/SUITE_TIMEOUT_EXPLICIT are read by the eval-defined _suite_timeout_for, invisible to static analysis
    got=$(eval "$fn2267"; SUITE_TIMEOUT=600; SUITE_TIMEOUT_EXPLICIT=''; _suite_timeout_for "$1")
    if [ "$got" = "$2" ]; then
      pass "2267: _suite_timeout_for '$1' -> ${2}s"
    else
      fail "2267: _suite_timeout_for '$1' expected ${2}s got '$got'"
    fi
  }
  check_timeout_2267 "scripts/test-propagate-public.sh" "2700"
  check_timeout_2267 "/repo/scripts/test-propagate-public.sh" "2700"
  check_timeout_2267 "scripts/ci/test-suite-concurrency.sh" "1500"
  check_timeout_2267 "/repo/scripts/ci/test-suite-concurrency.sh" "1500"

  # HIMMEL-2895. The third HIMMEL-2267 arm was this file's own 1200s budget,
  # sized to a 712s measurement of the pre-split 3086-line suite. The split
  # left six suites whose slowest is 114s, so every one of them falls under
  # the 600s default with ~5x headroom -- and the arm is GONE rather than
  # replaced by six smaller ones, because every entry in this table RAISES a
  # budget (the lowest is 650) and an arm BELOW the default would tighten the
  # cap and manufacture the exact false CAP EXCEEDED the table exists to
  # delete. Asserted rather than merely deleted so that re-adding one is a
  # deliberate act with a measurement behind it.
  for p2267 in test-run-shell-tests \
               test-run-shell-tests-timing \
               test-run-shell-tests-discovery \
               test-run-shell-tests-rotation \
               test-run-shell-tests-rotation-guards \
               test-run-shell-tests-rotation-cursor; do
    check_timeout_2267 "scripts/ci/$p2267.sh" "600"
    check_timeout_2267 "/repo/scripts/ci/$p2267.sh" "600"
  done

  # A path in no arm at all still gets the default -- the control that keeps
  # the six assertions above from passing merely because the case fell
  # through for the wrong reason.
  check_timeout_2267 "scripts/ci/test-not-in-any-arm-2895.sh" "600"
fi

# --------------------------------------------------------------------------
# Case 19 — --pr <N> / SUITE_REPORT_PR (HIMMEL-2383): the runner posts its
# own SUMMARY block as a PR comment via a GH_CMD-stubbed `gh`, opt-in only,
# best-effort (a post failure never changes the run's own exit code), and
# never fires under --list.
# --------------------------------------------------------------------------
echo "== Case 19: --pr / SUITE_REPORT_PR after-report posting =="
sb19=$(mktemp -d "${TMPDIR:-/tmp}/rst-case19.XXXXXX") || { fail "19: mktemp failed"; sb19=""; }
if [ -n "$sb19" ]; then
cat > "$sb19/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
chmod +x "$sb19/test-pass.sh"

mk_gh19() {  # mk_gh19 <path> <exit-code>
  cat > "$1" <<GHEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$sb19/gh.log"
exit $2
GHEOF
  chmod +x "$1"
}

# 19a: --pr 77 posts, the argv carries both the PR number and the literal
# SUMMARY block (passed via --body, so it lands in the stub's "\$*" too),
# and the run's own exit code (0, all-pass) is unaffected.
gh19a="$sb19/gh-19a"
mk_gh19 "$gh19a" 0
rm -f "$sb19/gh.log"
out19a=$(GH_CMD="$gh19a" bash "$RUNNER" "$sb19" --pr 77 2>&1)
rc19a=$?
gh19a_log=$(cat "$sb19/gh.log" 2>/dev/null)
if [ "$rc19a" -eq 0 ] && grepq "$gh19a_log" -F 'pr comment 77' \
   && grepq "$gh19a_log" -F '== Summary ==' \
   && grepq "$gh19a_log" -F 'PASS:' \
   && grepq "$gh19a_log" -F "scope: $sb19"; then
  pass "19a: --pr 77 posts the SUMMARY block (incl. scope: <scan-root>), run exit unaffected"
else
  fail "19a: --pr 77 -> rc=$rc19a gh.log='$gh19a_log' output: $out19a"
fi

# 19b: no --pr, no env -> gh is never invoked (never default-on).
gh19b="$sb19/gh-19b"
mk_gh19 "$gh19b" 0
rm -f "$sb19/gh.log"
out19b=$(GH_CMD="$gh19b" bash "$RUNNER" "$sb19" 2>&1)
rc19b=$?
if [ "$rc19b" -eq 0 ] && [ ! -s "$sb19/gh.log" ]; then
  pass "19b: no --pr/no env -> gh never invoked"
else
  fail "19b: expected gh untouched; rc=$rc19b gh.log='$(cat "$sb19/gh.log" 2>/dev/null)' output: $out19b"
fi

# 19c: SUITE_REPORT_PR env alone (no --pr flag) also posts.
gh19c="$sb19/gh-19c"
mk_gh19 "$gh19c" 0
rm -f "$sb19/gh.log"
out19c=$(GH_CMD="$gh19c" SUITE_REPORT_PR=88 bash "$RUNNER" "$sb19" 2>&1)
rc19c=$?
if [ "$rc19c" -eq 0 ] && grepq "$(cat "$sb19/gh.log" 2>/dev/null)" -F 'pr comment 88'; then
  pass "19c: SUITE_REPORT_PR=88 env alone posts"
else
  fail "19c: expected a post to PR 88; rc=$rc19c gh.log='$(cat "$sb19/gh.log" 2>/dev/null)' output: $out19c"
fi

# 19d: gh pr comment fails -> best-effort, run's own exit code (0) unaffected,
# a WARN is printed.
gh19d="$sb19/gh-19d"
mk_gh19 "$gh19d" 1
rm -f "$sb19/gh.log"
out19d=$(GH_CMD="$gh19d" bash "$RUNNER" "$sb19" --pr 99 2>&1)
rc19d=$?
if [ "$rc19d" -eq 0 ] && grepq "$out19d" -F 'WARN' && grepq "$out19d" -F '99'; then
  pass "19d: gh post failure is best-effort — WARN printed, run exit unaffected"
else
  fail "19d: gh post failure -> rc=$rc19d output: $out19d"
fi

# 19e: --list never posts, even with --pr set.
gh19e="$sb19/gh-19e"
mk_gh19 "$gh19e" 0
rm -f "$sb19/gh.log"
out19e=$(GH_CMD="$gh19e" bash "$RUNNER" "$sb19" --list --pr 100 2>&1)
rc19e=$?
if [ "$rc19e" -eq 0 ] && [ ! -s "$sb19/gh.log" ]; then
  pass "19e: --list never posts even with --pr set"
else
  fail "19e: expected gh untouched under --list; rc=$rc19e gh.log='$(cat "$sb19/gh.log" 2>/dev/null)' output: $out19e"
fi

# 19f: --pr with an option-looking value refuses instead of consuming it
# (HIMMEL-2383 CR finding codex-2, round 6) — `--pr --list` used to eat
# "--list" as the PR number, silently dropping the flag and later handing
# the literal string "--list" to `gh pr comment`.
gh19f="$sb19/gh-19f"
mk_gh19 "$gh19f" 0
rm -f "$sb19/gh.log"
out19f=$(GH_CMD="$gh19f" bash "$RUNNER" "$sb19" --pr --list 2>&1)
rc19f=$?
if [ "$rc19f" -eq 1 ] && [ ! -s "$sb19/gh.log" ] && grepq "$out19f" -F 'requires a PR number'; then
  pass "19f: --pr --list refuses instead of consuming the flag"
else
  fail "19f: --pr --list -> rc=$rc19f gh.log='$(cat "$sb19/gh.log" 2>/dev/null)' output: $out19f"
fi

# 19g: SUITE_REPORT_PR gets the SAME validation as --pr (HIMMEL-2383 CR
# finding codex-2, round 7) — the --pr flag validates inline, but
# SUITE_REPORT_PR sets report_pr's default before that loop runs and used
# to bypass it entirely.
gh19g="$sb19/gh-19g"
mk_gh19 "$gh19g" 0
rm -f "$sb19/gh.log"
out19g=$(GH_CMD="$gh19g" SUITE_REPORT_PR='not-a-number' bash "$RUNNER" "$sb19" 2>&1)
rc19g=$?
if [ "$rc19g" -eq 1 ] && [ ! -s "$sb19/gh.log" ] && grepq "$out19g" -F 'must be a PR number'; then
  pass "19g: a malformed SUITE_REPORT_PR refuses instead of being silently used"
else
  fail "19g: SUITE_REPORT_PR='not-a-number' -> rc=$rc19g gh.log='$(cat "$sb19/gh.log" 2>/dev/null)' output: $out19g"
fi

# 19h (HIMMEL-2383 round-13 CR finding codex-2): --changed-since alongside
# --pr posts a CHANGED-SINCE marker line — base-status.sh must not read a
# conditionally-filtered run as full scope coverage. Real git (this test
# runs inside the worktree, a real repo) resolves "HEAD" fine; the fixture
# suite isn't a registered conditional suite so it still runs either way —
# only the posted marker line is under test here.
gh19h="$sb19/gh-19h"
mk_gh19 "$gh19h" 0
rm -f "$sb19/gh.log"
out19h=$(GH_CMD="$gh19h" bash "$RUNNER" "$sb19" --changed-since HEAD --pr 77 2>&1)
rc19h=$?
gh19h_log=$(cat "$sb19/gh.log" 2>/dev/null)
if [ "$rc19h" -eq 0 ] && grepq "$gh19h_log" -F 'CHANGED-SINCE: HEAD'; then
  pass "19h: --changed-since + --pr posts a CHANGED-SINCE marker line"
else
  fail "19h: --changed-since + --pr -> rc=$rc19h gh.log='$gh19h_log' output: $out19h"
fi

rm -rf "$sb19"
fi


# --------------------------------------------------------------------------
# Case 22 (HIMMEL-2872) — --shard <i>/<n> partitions the run list.
#
# The shard split is what lets CI's shell-unit job fan out across a runner
# matrix, so the property that has to hold is EXACTNESS, not "roughly even":
# the union of shards 1..n must equal the unsharded run list and the shards
# must be pairwise disjoint. Anything weaker silently drops suites off the
# gate — the HIMMEL-1128 false-green class, reached through the parallelism
# instead of through discovery.
#
# The split is taken AFTER SKIP_LIST/--skip-extra/tier/conditional/capability
# filtering (22g pins that), so a host that skips a suite does not leave a
# hole in one shard's share; and a shard that ends up running NOTHING is a
# refusal, not a pass (22e) — except under the docs-only fast lane, where zero
# is the whole corpus's honest answer (22f).
# --------------------------------------------------------------------------
echo "== Case 22 (HIMMEL-2872): --shard partitions the run list =="

mk_shard_sandbox() {  # $1 = dir, $2 = count — test-s1.sh .. test-s<count>.sh
  mkdir -p "$1"
  local _i
  for _i in $(seq 1 "$2"); do
    cat > "$1/test-s${_i}.sh" <<'SHEOF'
#!/usr/bin/env bash
touch "${0%.sh}.sentinel"
exit 0
SHEOF
    chmod +x "$1/test-s${_i}.sh"
  done
}

# run_lines <output> — just the [RUN ] suite paths, one per line.
run_lines() { grep -F '[RUN ] ' <<< "$1" | sed 's/^\[RUN \] //'; }

# 22a — the union of --list --shard i/3 equals plain --list, pairwise disjoint.
#
# An unchecked mktemp -d here leaves the sandbox variable empty, and every
# fixture write below then resolves against that empty path — the filesystem
# root — instead of an isolated sandbox; fail (not a silent skip) is used so
# a failed allocation reddens the suite rather than passing quietly.
sb22a=$(mktemp -d "${TMPDIR:-/tmp}/rst-case22a.XXXXXX") || { fail "22a: mktemp failed"; sb22a=""; }
if [ -n "$sb22a" ]; then
mk_shard_sandbox "$sb22a" 7
full22a=$(run_lines "$(bash "$RUNNER" --list "$sb22a" 2>&1)")
s122a=$(run_lines "$(bash "$RUNNER" --list --shard 1/3 "$sb22a" 2>&1)")
s222a=$(run_lines "$(bash "$RUNNER" --list --shard 2/3 "$sb22a" 2>&1)")
s322a=$(run_lines "$(bash "$RUNNER" --list --shard 3/3 "$sb22a" 2>&1)")
union22a=$(printf '%s\n%s\n%s\n' "$s122a" "$s222a" "$s322a" | grep -v '^$' | sort)
dupes22a=$(printf '%s\n%s\n%s\n' "$s122a" "$s222a" "$s322a" | grep -v '^$' | sort | uniq -d)
if [ "$union22a" = "$(sort <<< "$full22a")" ] && [ -z "$dupes22a" ] \
   && [ -n "$s122a" ] && [ -n "$s222a" ] && [ -n "$s322a" ]; then
  pass "22a: shards 1..3 union to the full run list, pairwise disjoint, none empty"
else
  fail "22a: partition broken; full='$full22a' s1='$s122a' s2='$s222a' s3='$s322a' dupes='$dupes22a'"
fi

# 22b — deterministic: the same shard planned twice is byte-identical.
again22b=$(run_lines "$(bash "$RUNNER" --list --shard 2/3 "$sb22a" 2>&1)")
if [ "$s222a" = "$again22b" ]; then
  pass "22b: --list --shard 2/3 is deterministic across invocations"
else
  fail "22b: shard 2/3 differed between runs; first='$s222a' second='$again22b'"
fi

# 22c — --shard 1/1 is inert: the same plan as no --shard at all.
one22c=$(run_lines "$(bash "$RUNNER" --list --shard 1/1 "$sb22a" 2>&1)")
if [ "$one22c" = "$full22a" ]; then
  pass "22c: --shard 1/1 plans exactly the unsharded run list"
else
  fail "22c: --shard 1/1 diverged from the full plan; full='$full22a' got='$one22c'"
fi
rm -rf "$sb22a"
fi

# 22d — malformed values are REFUSED at rc 2 (the runner's "bad configuration
# value" code, the same one an invalid SUITE_TIER_MODE takes), never silently
# ignored: a typo'd shard spec that fell through to a full run would multiply
# the CI bill by n and hide the misconfiguration behind a green. The three
# oversized specs at the end are the RED control for the digit-length bound:
# bash arithmetic wraps silently on 64-bit overflow (rc=0, no diagnostic), so
# without that bound '1/18446744073709551618' converts to a valid-looking
# '1/2' and quietly runs a partition nobody asked for.
sb22d=$(mktemp -d "${TMPDIR:-/tmp}/rst-case22d.XXXXXX") || { fail "22d: mktemp failed"; sb22d=""; }
if [ -n "$sb22d" ]; then
mk_shard_sandbox "$sb22d" 3
for spec22d in '0/3' '4/3' 'abc' '1/0' '1/2/3' '/3' '1/' '-1/3' '1/-3' 'x/y' '' '3' \
               '1/18446744073709551618' '1/99999999999999999999' '99999999999999999999/3'; do
  out22d=$(bash "$RUNNER" --list --shard "$spec22d" "$sb22d" 2>&1); rc22d=$?
  if [ "$rc22d" -eq 2 ] && grepq "$out22d" -F -- '--shard'; then
    pass "22d: --shard '$spec22d' -> refused rc 2"
  else
    fail "22d: --shard '$spec22d' -> expected rc 2 with a --shard message, got rc=$rc22d; out: $out22d"
  fi
done
# ...and a missing argument entirely.
out22d2=$(bash "$RUNNER" --list "$sb22d" --shard 2>&1); rc22d2=$?
if [ "$rc22d2" -eq 2 ] && grepq "$out22d2" -F -- '--shard'; then
  pass "22d: --shard with no argument -> refused rc 2"
else
  fail "22d: --shard with no argument -> expected rc 2, got rc=$rc22d2; out: $out22d2"
fi
rm -rf "$sb22d"
fi

# 22e — a shard that is assigned NOTHING is a refusal, not a pass. This is the
# n > run-list-length case, which is the shape a mis-sized CI matrix takes.
sb22e=$(mktemp -d "${TMPDIR:-/tmp}/rst-case22e.XXXXXX") || { fail "22e: mktemp failed"; sb22e=""; }
if [ -n "$sb22e" ]; then
mk_shard_sandbox "$sb22e" 2
out22e=$(bash "$RUNNER" --shard 3/3 "$sb22e" 2>&1); rc22e=$?
if [ "$rc22e" -eq 1 ] && grepq "$out22e" -F 'shard 3/3 ran 0 suites'; then
  pass "22e: an empty shard refuses (exit 1) and names itself"
else
  fail "22e: expected exit 1 naming shard 3/3; rc=$rc22e out: $out22e"
fi
# The control: the two shards that DO get a suite still pass.
out22e1=$(bash "$RUNNER" --shard 1/3 "$sb22e" 2>&1); rc22e1=$?
out22e2=$(bash "$RUNNER" --shard 2/3 "$sb22e" 2>&1); rc22e2=$?
if [ "$rc22e1" -eq 0 ] && [ "$rc22e2" -eq 0 ]; then
  pass "22e: the non-empty shards of the same run still pass"
else
  fail "22e: expected shards 1/3 and 2/3 to pass; rc1=$rc22e1 rc2=$rc22e2; out1: $out22e1 out2: $out22e2"
fi
rm -rf "$sb22e"
fi

# 22f — the docs-only fast lane still reports a genuine pass PER SHARD. Every
# shard legitimately runs zero suites there, so 22e's refusal must not fire.
#
# This case builds its OWN fake `git` rather than reaching for Case 15's
# $fakebin15: that fixture is torn down at the end of Case 15, so a borrowed
# PATH entry here contributes NOTHING, `command -v git` resolves to the real
# system git, and the runner diffs the ACTUAL worktree instead of
# $GIT_FAKE_DIFF — a "docs-only" case that quietly stops being docs-only the
# moment the checkout has an uncommitted change. Fixtures stay local to the
# case that reads them, exactly as this file's header says.
sb22f=$(mktemp -d "${TMPDIR:-/tmp}/rst-case22f.XXXXXX") || { fail "22f: mktemp failed"; sb22f=""; }
fakebin22f=$(mktemp -d "${TMPDIR:-/tmp}/rst-case22f-fakebin.XXXXXX") || { fail "22f: mktemp failed (fake git fixture)"; fakebin22f=""; }
if [ -n "$sb22f" ] && [ -n "$fakebin22f" ]; then
mk_docs_sandbox "$sb22f"
cat > "$fakebin22f/git" <<'SHEOF'
#!/usr/bin/env bash
case "$1" in
  rev-parse)
    _ref=
    for _a in "$@"; do _ref="$_a"; done
    case "$_ref" in
      -*) exit 1 ;;
      *) printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n'; exit 0 ;;
    esac
    ;;
  diff)
    [ -f "${GIT_FAKE_DIFF:-}" ] && cat "${GIT_FAKE_DIFF:-}"
    ;;
  ls-files)
    [ -f "${GIT_FAKE_UNTRACKED:-}" ] && cat "${GIT_FAKE_UNTRACKED:-}"
    ;;
esac
exit 0
SHEOF
chmod +x "$fakebin22f/git"
diff22f="$sb22f/diff.txt"; printf 'docs/foo.md\nREADME.md\n' > "$diff22f"
ok22f=1
for i22f in 1 2 3; do
  out22f=$(GIT_FAKE_DIFF="$diff22f" PATH="$fakebin22f:$PATH" \
    bash "$RUNNER" "$sb22f" --changed-since HEAD --shard "$i22f/3" 2>&1); rc22f=$?
  if [ "$rc22f" -ne 0 ] || ! grepq "$out22f" -F "docs-only diff — 0 shell suites needed"; then
    ok22f=0
    fail "22f: shard $i22f/3 on a docs-only diff -> expected the fast-lane pass; rc=$rc22f out: $out22f"
  fi
done
[ "$ok22f" -eq 1 ] && pass "22f: every shard reports the docs-only fast-lane pass, not the empty-shard refusal"
rm -rf "$sb22f" "$fakebin22f"
fi

# 22g — the split is taken AFTER the skip filters, not over raw discovery.
# Five run-eligible suites (s2..s6) across 2 shards must land 3/2. The
# discriminator is deliberate: a PRE-filter split of s1..s6 gives shard 1
# {s1,s3,s5} -> {s3,s5} once s1 is skipped away, while the POST-filter split
# this ticket specifies gives shard 1 {s2,s4,s6}.
sb22g=$(mktemp -d "${TMPDIR:-/tmp}/rst-case22g.XXXXXX") || { fail "22g: mktemp failed"; sb22g=""; }
if [ -n "$sb22g" ]; then
mk_shard_sandbox "$sb22g" 6
g122g=$(run_lines "$(bash "$RUNNER" --list --skip-extra test-s1.sh --shard 1/2 "$sb22g" 2>&1)")
g222g=$(run_lines "$(bash "$RUNNER" --list --skip-extra test-s1.sh --shard 2/2 "$sb22g" 2>&1)")
want1_22g=$(printf '%s/test-s2.sh\n%s/test-s4.sh\n%s/test-s6.sh' "$sb22g" "$sb22g" "$sb22g")
want2_22g=$(printf '%s/test-s3.sh\n%s/test-s5.sh' "$sb22g" "$sb22g")
if [ "$g122g" = "$want1_22g" ] && [ "$g222g" = "$want2_22g" ]; then
  pass "22g: the shard split is over the filtered run list, not raw discovery"
else
  fail "22g: expected shard1={s2,s4,s6} shard2={s3,s5} (post-filter); got shard1='$g122g' shard2='$g222g'"
fi
# The skipped suite is still REPORTED by every shard — a shard's log must not
# look like the suite does not exist.
skip22g=$(bash "$RUNNER" --list --skip-extra test-s1.sh --shard 2/2 "$sb22g" 2>&1)
if grepq "$skip22g" -F 'test-s1.sh' && grepq "$skip22g" -F '[SKIP]'; then
  pass "22g: a skipped suite is still reported on a shard that was not assigned it"
else
  fail "22g: expected a [SKIP] line for test-s1.sh on shard 2/2; out: $skip22g"
fi
rm -rf "$sb22g"
fi

# 22h — EXECUTION, not just planning: a shard runs only its own suites, and a
# failure inside one shard reddens that shard alone.
sb22h=$(mktemp -d "${TMPDIR:-/tmp}/rst-case22h.XXXXXX") || { fail "22h: mktemp failed"; sb22h=""; }
if [ -n "$sb22h" ]; then
mk_shard_sandbox "$sb22h" 4
cat > "$sb22h/test-s2.sh" <<'SHEOF'
#!/usr/bin/env bash
touch "${0%.sh}.sentinel"
exit 1
SHEOF
chmod +x "$sb22h/test-s2.sh"
# Sorted run list is s1,s2,s3,s4 -> shard 1/2 = {s1,s3}, shard 2/2 = {s2,s4}.
out22h1=$(bash "$RUNNER" --shard 1/2 "$sb22h" 2>&1); rc22h1=$?
ran22h1=$([ -f "$sb22h/test-s2.sentinel" ] && echo yes || echo no)
rm -f "$sb22h"/*.sentinel
out22h2=$(bash "$RUNNER" --shard 2/2 "$sb22h" 2>&1); rc22h2=$?
if [ "$rc22h1" -eq 0 ] && [ "$ran22h1" = no ] && [ "$rc22h2" -eq 1 ] \
   && [ -f "$sb22h/test-s2.sentinel" ] && [ ! -f "$sb22h/test-s1.sentinel" ]; then
  pass "22h: each shard executes only its own suites; a red suite reddens its shard alone"
else
  fail "22h: expected shard1 green without running s2, shard2 red running s2; rc1=$rc22h1 s2-in-shard1=$ran22h1 rc2=$rc22h2; out1: $out22h1 out2: $out22h2"
fi
rm -rf "$sb22h"
fi



# Case 22-dur (HIMMEL-2894) — --shard assignment is a duration-aware bin-pack.
#
# Round-robin (HIMMEL-2872's v1) balances by construction only when every
# suite costs about the same. It does not: run 34408076490 put the corpus's
# two heaviest suites (389s + 330s) on the same shard by modulo luck, so the
# slowest shard took 18m23s against a 6.5m floor. The assignment is now a
# greedy longest-first bin-pack over a committed duration ledger.
#
# What must NOT change is 22a/22g's exactness: the union of the shards is
# still the unsharded run list and the shards are still pairwise disjoint.
# Balance is an optimisation; exactness is the gate. So the ledger is
# advisory in every direction — missing, empty or malformed falls back to
# round-robin with a notice (22k) rather than failing the run, and a suite
# the ledger has never heard of is assigned a default, never dropped (22j).
#
# The ledger is keyed by the suite path exactly as the runner PRINTS it,
# which is also exactly what the regeneration command harvests from a job
# log — so the keys cannot drift from the spelling they are matched against.
# $SUITE_DURATIONS overrides the committed ledger; these cases use it to
# supply fixtures and to point at paths that do not exist.
# --------------------------------------------------------------------------
echo "== Case 22-dur (HIMMEL-2894): --shard assigns by a duration bin-pack =="

# 22i — the discriminator. s1 and s3 are the two heaviest suites and share a
# parity, so `i % 2` puts BOTH on shard 1 — the exact 18-minute shape the
# measured run took. A longest-first bin-pack must separate them.
sb22i=$(mktemp -d "${TMPDIR:-/tmp}/rst-case22i.XXXXXX") || { fail "22i: mktemp failed"; sb22i=""; }
if [ -n "$sb22i" ]; then
mk_shard_sandbox "$sb22i" 6
led22i="$sb22i/durations.tsv"
{ printf '# suite\tseconds\n'
  printf '%s/test-s1.sh\t100\n' "$sb22i"
  printf '%s/test-s2.sh\t1\n'   "$sb22i"
  printf '%s/test-s3.sh\t90\n'  "$sb22i"
  printf '%s/test-s4.sh\t1\n'   "$sb22i"
  printf '%s/test-s5.sh\t1\n'   "$sb22i"
  printf '%s/test-s6.sh\t1\n'   "$sb22i"; } > "$led22i"
a22i=$(run_lines "$(SUITE_DURATIONS="$led22i" bash "$RUNNER" --list --shard 1/2 "$sb22i" 2>&1)")
b22i=$(run_lines "$(SUITE_DURATIONS="$led22i" bash "$RUNNER" --list --shard 2/2 "$sb22i" 2>&1)")
# "Together" is the failure: whichever shard holds s1 must not also hold s3.
same22i=0
if grepq "$a22i" -Fx "$sb22i/test-s1.sh" && grepq "$a22i" -Fx "$sb22i/test-s3.sh"; then same22i=1; fi
if grepq "$b22i" -Fx "$sb22i/test-s1.sh" && grepq "$b22i" -Fx "$sb22i/test-s3.sh"; then same22i=1; fi
if [ "$same22i" -eq 0 ] && [ -n "$a22i" ] && [ -n "$b22i" ]; then
  pass "22i: the two heaviest suites land on different shards (round-robin collides them)"
else
  fail "22i: expected the heaviest two split across shards; shard1='$a22i' shard2='$b22i'"
fi

# ...and the balance that split buys, stated as the property that motivated it:
# the slower shard's predicted seconds must beat round-robin's 191s (s1+s3+s5).
sum22i() {  # $1 = newline-separated suite paths -> their summed ledger seconds
  local _t=0 _p _s
  while IFS= read -r _p; do
    [ -n "$_p" ] || continue
    _s=$(awk -F'\t' -v k="$_p" '$1 == k { print $2 + 0; exit }' "$led22i")
    _t=$(( _t + ${_s:-0} ))
  done <<< "$1"
  printf '%s\n' "$_t"
}
ta22i=$(sum22i "$a22i"); tb22i=$(sum22i "$b22i")
slow22i=$ta22i; [ "$tb22i" -gt "$slow22i" ] && slow22i=$tb22i
if [ "$slow22i" -lt 191 ]; then
  pass "22i: slowest shard ${slow22i}s beats round-robin's 191s on the same ledger"
else
  fail "22i: slowest shard ${slow22i}s did not beat round-robin's 191s (shard1=${ta22i}s shard2=${tb22i}s)"
fi
rm -rf "$sb22i"
fi

# 22j — a suite the ledger has never heard of is still assigned to EXACTLY one
# shard. A lookup miss that dropped the suite would take it off the gate while
# every shard reported green — HIMMEL-1128's false-green class reached through
# the ledger. This ledger covers s1..s3 only; s4..s6 are misses.
sb22j=$(mktemp -d "${TMPDIR:-/tmp}/rst-case22j.XXXXXX") || { fail "22j: mktemp failed"; sb22j=""; }
if [ -n "$sb22j" ]; then
mk_shard_sandbox "$sb22j" 6
led22j="$sb22j/durations.tsv"
{ printf '# suite\tseconds\n'
  printf '%s/test-s1.sh\t50\n' "$sb22j"
  printf '%s/test-s2.sh\t40\n' "$sb22j"
  printf '%s/test-s3.sh\t30\n' "$sb22j"; } > "$led22j"
full22j=$(run_lines "$(SUITE_DURATIONS="$led22j" bash "$RUNNER" --list "$sb22j" 2>&1)")
all22j=""
for i22j in 1 2 3; do
  all22j="${all22j}$(run_lines "$(SUITE_DURATIONS="$led22j" bash "$RUNNER" --list --shard "$i22j/3" "$sb22j" 2>&1)")
"
done
union22j=$(printf '%s' "$all22j" | grep -v '^$' | sort)
dupes22j=$(printf '%s' "$all22j" | grep -v '^$' | sort | uniq -d)
missing22j=""
for n22j in 4 5 6; do
  grepq "$union22j" -Fx "$sb22j/test-s${n22j}.sh" || missing22j="${missing22j}s${n22j} "
done
if [ "$union22j" = "$(sort <<< "$full22j")" ] && [ -z "$dupes22j" ] && [ -z "$missing22j" ]; then
  pass "22j: suites absent from the ledger are each assigned to exactly one shard"
else
  fail "22j: ledger-miss suites lost or duplicated; missing='$missing22j' dupes='$dupes22j' union='$union22j' full='$full22j'"
fi
rm -rf "$sb22j"
fi

# 22k — the ledger is ADVISORY. Missing, empty and malformed all land on the
# HIMMEL-2872 round-robin partition — byte-identical to what the runner planned
# before this ticket — by two different routes that must be indistinguishable
# from the outside. A MISSING ledger is the runner's one fallback: shell
# builtins decide it off a committed file, so every shard reaches the same
# verdict and says so once on stderr. A ledger that is present but carries no
# parseable row is not a fallback at all — it packs, every suite takes the
# median of nothing (floored to 1s), and a pack with all durations equal
# degenerates exactly to `i % n`, which is 22a/22h's property. Either way a
# missing optimisation must never fail a run or silently change the corpus.
sb22k=$(mktemp -d "${TMPDIR:-/tmp}/rst-case22k.XXXXXX") || { fail "22k: mktemp failed"; sb22k=""; }
if [ -n "$sb22k" ]; then
mk_shard_sandbox "$sb22k" 6
# The pre-HIMMEL-2894 partition for 6 suites over 2 shards, spelled out.
rr1_22k=$(printf '%s/test-s1.sh\n%s/test-s3.sh\n%s/test-s5.sh' "$sb22k" "$sb22k" "$sb22k")
rr2_22k=$(printf '%s/test-s2.sh\n%s/test-s4.sh\n%s/test-s6.sh' "$sb22k" "$sb22k" "$sb22k")
empty22k="$sb22k/empty.tsv";  : > "$empty22k"
bad22k="$sb22k/bad.tsv";      printf 'not a ledger at all\nstill not\n<<<merge conflict\n' > "$bad22k"
miss22k="$sb22k/does-not-exist.tsv"
for led22k in "$miss22k" "$empty22k" "$bad22k"; do
  o1_22k=$(SUITE_DURATIONS="$led22k" bash "$RUNNER" --list --shard 1/2 "$sb22k" 2>&1); rc1_22k=$?
  o2_22k=$(SUITE_DURATIONS="$led22k" bash "$RUNNER" --list --shard 2/2 "$sb22k" 2>&1)
  if [ "$rc1_22k" -eq 0 ] \
     && [ "$(run_lines "$o1_22k")" = "$rr1_22k" ] \
     && [ "$(run_lines "$o2_22k")" = "$rr2_22k" ]; then
    pass "22k: unusable ledger ($(basename "$led22k")) -> the round-robin partition, exactly"
  else
    fail "22k: unusable ledger ($(basename "$led22k")) diverged; rc=$rc1_22k shard1='$(run_lines "$o1_22k")' shard2='$(run_lines "$o2_22k")' out1: $o1_22k"
  fi
done
# Only the MISSING ledger is the fallback, and only it announces itself. A
# present-but-junk ledger reaches the same partition through the packer, so it
# has nothing to announce — asserting the absence keeps the two routes honest
# about which one actually ran.
o1miss_22k=$(SUITE_DURATIONS="$miss22k" bash "$RUNNER" --list --shard 1/2 "$sb22k" 2>&1)
o1bad_22k=$(SUITE_DURATIONS="$bad22k" bash "$RUNNER" --list --shard 1/2 "$sb22k" 2>&1)
if grepq "$o1miss_22k" -F 'falling back to round-robin' \
   && ! grepq "$o1bad_22k" -F 'falling back to round-robin'; then
  pass "22k: the missing ledger announces the fallback; a junk one does not"
else
  fail "22k: fallback notice misplaced; miss: $o1miss_22k --- bad: $o1bad_22k"
fi
# ...but it does not pack SILENTLY either. A committed ledger that parses zero
# rows still yields the right corpus, so nothing fails — which is exactly how a
# broken one would go unnoticed. One notice keeps it visible in the shard log.
o1empty_22k=$(SUITE_DURATIONS="$empty22k" bash "$RUNNER" --list --shard 1/2 "$sb22k" 2>&1)
if grepq "$o1bad_22k" -F 'parsed 0 rows' \
   && grepq "$o1empty_22k" -F 'parsed 0 rows' \
   && ! grepq "$o1miss_22k" -F 'parsed 0 rows'; then
  pass "22k: a present ledger parsing 0 rows says so once; a missing one does not (it has its own notice)"
else
  fail "22k: 0-row notice misplaced; bad: $o1bad_22k --- empty: $o1empty_22k --- miss: $o1miss_22k"
fi
rm -rf "$sb22k"
fi

# 22l — 22a/22b's exactness and determinism properties, RE-ASSERTED under the
# bin-pack with a real ledger in play. 22a runs without one; this is the same
# contract on the path CI actually takes. The 389/330 pair is the measured
# corpus's own shape, scaled down to a 7-suite sandbox.
sb22l=$(mktemp -d "${TMPDIR:-/tmp}/rst-case22l.XXXXXX") || { fail "22l: mktemp failed"; sb22l=""; }
if [ -n "$sb22l" ]; then
mk_shard_sandbox "$sb22l" 7
led22l="$sb22l/durations.tsv"
{ printf '# suite\tseconds\n'
  printf '%s/test-s1.sh\t389\n' "$sb22l"
  printf '%s/test-s2.sh\t330\n' "$sb22l"
  printf '%s/test-s3.sh\t12\n'  "$sb22l"
  printf '%s/test-s4.sh\t7\n'   "$sb22l"
  printf '%s/test-s5.sh\t3\n'   "$sb22l"; } > "$led22l"
full22l=$(run_lines "$(SUITE_DURATIONS="$led22l" bash "$RUNNER" --list "$sb22l" 2>&1)")
s122l=$(run_lines "$(SUITE_DURATIONS="$led22l" bash "$RUNNER" --list --shard 1/3 "$sb22l" 2>&1)")
s222l=$(run_lines "$(SUITE_DURATIONS="$led22l" bash "$RUNNER" --list --shard 2/3 "$sb22l" 2>&1)")
s322l=$(run_lines "$(SUITE_DURATIONS="$led22l" bash "$RUNNER" --list --shard 3/3 "$sb22l" 2>&1)")
union22l=$(printf '%s\n%s\n%s\n' "$s122l" "$s222l" "$s322l" | grep -v '^$' | sort)
dupes22l=$(printf '%s\n%s\n%s\n' "$s122l" "$s222l" "$s322l" | grep -v '^$' | sort | uniq -d)
if [ "$union22l" = "$(sort <<< "$full22l")" ] && [ -z "$dupes22l" ] \
   && [ -n "$s122l" ] && [ -n "$s222l" ] && [ -n "$s322l" ]; then
  pass "22l: under a ledger, shards 1..3 still union to the full run list, pairwise disjoint"
else
  fail "22l: bin-pack partition broken; full='$full22l' s1='$s122l' s2='$s222l' s3='$s322l' dupes='$dupes22l'"
fi
again22l=$(run_lines "$(SUITE_DURATIONS="$led22l" bash "$RUNNER" --list --shard 2/3 "$sb22l" 2>&1)")
if [ "$s222l" = "$again22l" ]; then
  pass "22l: the bin-pack is deterministic across invocations"
else
  fail "22l: shard 2/3 differed between runs; first='$s222l' second='$again22l'"
fi
# The heaviest suite is the whole of its shard: 389 > 330 + 12 + 7 + 3 + the
# two ledger misses, so longest-first can never add a second suite to it. That
# is the ticket's floor, expressed as a property rather than a wall clock.
own22l=""
for sh22l in "$s122l" "$s222l" "$s322l"; do
  if grepq "$sh22l" -Fx "$sb22l/test-s1.sh"; then own22l="$sh22l"; fi
done
if [ "$own22l" = "$sb22l/test-s1.sh" ]; then
  pass "22l: the 389s suite is the whole of its shard — the floor the ticket names"
else
  fail "22l: expected the 389s suite alone on its shard; got '$own22l'"
fi
rm -rf "$sb22l"
fi


# 22m–22p — the ONE guard, from four directions. The runner asks two questions
# (is the ledger there? did the pack come out right?), and everything a tool
# can do to the pack — die outright, exit early, emit half its output — has to
# surface at the second one. These four cases each kill exactly ONE tool in the
# join|sort|pack|verify chain and assert the same thing: rc != 0, an empty
# assignment, and the single refusal message. Never a silent re-partition,
# which is the HIMMEL-1128 false-green class this guard exists for.
#
# Each stub is keyed on a token unique to its target's own argv, so every other
# sort and awk in the runner still execs the real tool:
#   22m  sort -k1,1r   the pack sort            22o  awk 'load['   the packer
#   22n  awk '%012d'   the join (and median)    22p  awk -v me=    the verify
#
# The unusable-LEDGER fallback (22k) is the opposite case and stays a fallback:
# it is decided off a committed file by shell builtins, so every shard reaches
# the same verdict and the round-robin partition it falls back to is exact
# across the whole matrix. A tool dying is local to one runner, and a shard
# recovering alone would run a partition none of its siblings shares.
#
# The single quotes in both writers are the point: those lines are the STUB's
# source, so its own "$@" and "$_a" must survive into the file unexpanded.
# shellcheck disable=SC2016
rst_tool_stub() {  # $1 = dir to create in, $2 = tool name, $3 = argv token, $4 = the real tool
  mkdir -p "$1"
  { printf '#!/usr/bin/env bash\n'
    printf 'for _a in "$@"; do\n'
    printf '  if printf %s "$_a" | grep -qF -- %s; then exit 1; fi\n' "'%s'" "'$3'"
    printf 'done\n'
    printf 'exec %s "$@"\n' "$4"; } > "$1/$2"
  chmod +x "$1/$2"
}

# One sandbox for all four. s1 (100s) against s3 (90s) plus four 1s suites
# means the bin-pack puts s1 ALONE on shard 1, where round-robin would give it
# s1, s3 and s5 — so "the guard did not fire and we silently fell back" and
# "the guard did not fire and we packed correctly" cannot be confused.
sb22m=$(mktemp -d "${TMPDIR:-/tmp}/rst-case22m.XXXXXX") || { fail "22m: mktemp failed"; sb22m=""; }
real_sort_22m=$(command -v sort)
real_awk_22m=$(command -v awk)
if [ -n "$sb22m" ] && [ -n "$real_sort_22m" ] && [ -n "$real_awk_22m" ]; then
mk_shard_sandbox "$sb22m" 6
led22m="$sb22m/durations.tsv"
{ printf '# suite\tseconds\n'
  printf '%s/test-s1.sh\t100\n' "$sb22m"
  printf '%s/test-s2.sh\t1\n'   "$sb22m"
  printf '%s/test-s3.sh\t90\n'  "$sb22m"
  printf '%s/test-s4.sh\t1\n'   "$sb22m"
  printf '%s/test-s5.sh\t1\n'   "$sb22m"
  printf '%s/test-s6.sh\t1\n'   "$sb22m"; } > "$led22m"

rst_tool_stub "$sb22m/stub-m" sort '-k1,1r'  "$real_sort_22m"
rst_tool_stub "$sb22m/stub-n" awk  '%012d'   "$real_awk_22m"
rst_tool_stub "$sb22m/stub-o" awk  'load['   "$real_awk_22m"
rst_tool_stub "$sb22m/stub-p" awk  'me='     "$real_awk_22m"

for case22m in "m:the pack sort" "n:the join and its median" "o:the packer" "p:the verify"; do
  id22m="22${case22m%%:*}"
  what22m="${case22m#*:}"
  o22m=$(PATH="$sb22m/stub-${case22m%%:*}:$PATH" SUITE_DURATIONS="$led22m" \
    bash "$RUNNER" --list --shard 1/2 "$sb22m" 2>&1); rc22m=$?
  if [ "$rc22m" -ne 0 ] \
     && [ -z "$(run_lines "$o22m")" ] \
     && grepq "$o22m" -F 'refusing to report green'; then
    pass "$id22m: killing $what22m refuses — no suite is silently dropped or re-partitioned"
  else
    fail "$id22m: killing $what22m did not refuse; rc=$rc22m shard1='$(run_lines "$o22m")' out: $o22m"
  fi
done

# The non-vacuity control: the SAME sandbox and ledger, no stub on PATH. If
# this ever stopped bin-packing, all four cases above would pass for the wrong
# reason. s1 alone on shard 1 is the bin-pack answer; round-robin's would be
# s1, s3, s5.
o22mc=$(SUITE_DURATIONS="$led22m" bash "$RUNNER" --list --shard 1/2 "$sb22m" 2>&1); rc22mc=$?
if [ "$rc22mc" -eq 0 ] && [ "$(run_lines "$o22mc")" = "$sb22m/test-s1.sh" ]; then
  pass "22m-p: control — the same ledger and sandbox bin-pack normally with every tool working"
else
  fail "22m-p: control did not bin-pack; rc=$rc22mc shard1='$(run_lines "$o22mc")' out: $o22mc"
fi
rm -rf "$sb22m"
fi

# 22q-22r (HIMMEL-2930) — the ONE guard's other two directions. 22m-p each
# kill a tool outright, so the plan comes out short and check 2 (completeness)
# already catches it. These two let the join finish and emit a COMPLETE plan —
# every eligible suite placed exactly once — so check 2 alone would pass them
# silently; only folding the pipeline's own exit status and the bytes it
# actually consumed into the same guard catches them. Same s1(100)/s3(90)
# sandbox as 22m-p: the bin-pack answer is s1 ALONE on its shard, so anything
# that starves s3 of its real duration (giving it the median instead) still
# looks complete but is a DIFFERENT partition from what every sibling shard
# would reach off the whole ledger — codex-1's exact false-green shape.
sb22q=$(mktemp -d "${TMPDIR:-/tmp}/rst-case22q.XXXXXX") || { fail "22q: mktemp failed"; sb22q=""; }
real_awk_22q=$(command -v awk)
if [ -n "$sb22q" ] && [ -n "$real_awk_22q" ]; then
mk_shard_sandbox "$sb22q" 6
led22q="$sb22q/durations.tsv"
{ printf '# suite\tseconds\n'
  printf '%s/test-s1.sh\t100\n' "$sb22q"
  printf '%s/test-s2.sh\t1\n'   "$sb22q"
  printf '%s/test-s3.sh\t90\n'  "$sb22q"
  printf '%s/test-s4.sh\t1\n'   "$sb22q"
  printf '%s/test-s5.sh\t1\n'   "$sb22q"
  printf '%s/test-s6.sh\t1\n'   "$sb22q"; } > "$led22q"

# Keyed on the join awk's own '%012d' format string (22n's token), so sort and
# the packer/verify awks still exec the real tool. It hands the join a 2-line
# PREFIX of the ledger instead of the whole file — an ordinary, non-crashing
# clean short read, not a tool dying.
# The single quotes here are the point, same as rst_tool_stub above: this is
# the STUB's source, so its own "$@"/"$_ledger" must survive unexpanded.
mkdir -p "$sb22q/stub-q"
# shellcheck disable=SC2016
{ printf '#!/usr/bin/env bash\n'
  printf 'for _a in "$@"; do\n'
  printf '  if grep -qF -- %s <<< "$_a"; then\n' "'%012d'"
  printf '    _ledger="${@: -1}"\n'
  printf '    _short=$(mktemp "${TMPDIR:-/tmp}/rst-case22q-short.XXXXXX")\n'
  printf '    head -n 2 "$_ledger" > "$_short"\n'
  printf '    set -- "${@:1:$(($#-1))}" "$_short"\n'
  printf '    exec %s "$@"\n' "$real_awk_22q"
  printf '  fi\n'
  printf 'done\n'
  printf 'exec %s "$@"\n' "$real_awk_22q"; } > "$sb22q/stub-q/awk"
chmod +x "$sb22q/stub-q/awk"

o22q=$(PATH="$sb22q/stub-q:$PATH" SUITE_DURATIONS="$led22q" \
  bash "$RUNNER" --list --shard 1/2 "$sb22q" 2>&1); rc22q=$?
if [ "$rc22q" -ne 0 ] \
   && [ -z "$(run_lines "$o22q")" ] \
   && grepq "$o22q" -F 'refusing to report green' \
   && grepq "$o22q" -F 'ledger bytes'; then
  pass "22q: a clean short read (rc=0, still a complete plan) is caught by bytes consumed, not completeness"
else
  fail "22q: short read not refused; rc=$rc22q shard1='$(run_lines "$o22q")' out: $o22q"
fi
rm -rf "$sb22q"
fi

# 22r — the same join finishes normally (real awk, real output) but the
# STUB itself exits non-zero once its END block has already printed. pipefail
# is what surfaces this; completeness never sees it because the plan the join
# emitted was whole.
sb22r=$(mktemp -d "${TMPDIR:-/tmp}/rst-case22r.XXXXXX") || { fail "22r: mktemp failed"; sb22r=""; }
real_awk_22r=$(command -v awk)
if [ -n "$sb22r" ] && [ -n "$real_awk_22r" ]; then
mk_shard_sandbox "$sb22r" 6
led22r="$sb22r/durations.tsv"
{ printf '# suite\tseconds\n'
  printf '%s/test-s1.sh\t100\n' "$sb22r"
  printf '%s/test-s2.sh\t1\n'   "$sb22r"
  printf '%s/test-s3.sh\t90\n'  "$sb22r"
  printf '%s/test-s4.sh\t1\n'   "$sb22r"
  printf '%s/test-s5.sh\t1\n'   "$sb22r"
  printf '%s/test-s6.sh\t1\n'   "$sb22r"; } > "$led22r"

mkdir -p "$sb22r/stub-r"
# shellcheck disable=SC2016
{ printf '#!/usr/bin/env bash\n'
  printf 'for _a in "$@"; do\n'
  printf '  if grep -qF -- %s <<< "$_a"; then\n' "'%012d'"
  printf '    %s "$@"\n' "$real_awk_22r"
  printf '    exit 7\n'
  printf '  fi\n'
  printf 'done\n'
  printf 'exec %s "$@"\n' "$real_awk_22r"; } > "$sb22r/stub-r/awk"
chmod +x "$sb22r/stub-r/awk"

o22r=$(PATH="$sb22r/stub-r:$PATH" SUITE_DURATIONS="$led22r" \
  bash "$RUNNER" --list --shard 1/2 "$sb22r" 2>&1); rc22r=$?
if [ "$rc22r" -ne 0 ] \
   && [ -z "$(run_lines "$o22r")" ] \
   && grepq "$o22r" -F 'refusing to report green' \
   && grepq "$o22r" -F 'pipeline exited'; then
  pass "22r: a join that exits 7 after printing a complete plan is refused via the pipeline exit status"
else
  fail "22r: exit-after-print not refused; rc=$rc22r shard1='$(run_lines "$o22r")' out: $o22r"
fi
rm -rf "$sb22r"
fi

# 22s — the two new checks above change NOTHING about the normal path: the
# same ledger and sandbox as 22l, no stub, byte-identical plan for two fixed
# shard indices across repeated invocations. 22l's determinism property,
# re-asserted with the bytes/rc bookkeeping now in the loop.
sb22s=$(mktemp -d "${TMPDIR:-/tmp}/rst-case22s.XXXXXX") || { fail "22s: mktemp failed"; sb22s=""; }
if [ -n "$sb22s" ]; then
mk_shard_sandbox "$sb22s" 7
led22s="$sb22s/durations.tsv"
{ printf '# suite\tseconds\n'
  printf '%s/test-s1.sh\t389\n' "$sb22s"
  printf '%s/test-s2.sh\t330\n' "$sb22s"
  printf '%s/test-s3.sh\t12\n'  "$sb22s"
  printf '%s/test-s4.sh\t7\n'   "$sb22s"
  printf '%s/test-s5.sh\t3\n'   "$sb22s"; } > "$led22s"
s122s_1=$(run_lines "$(SUITE_DURATIONS="$led22s" bash "$RUNNER" --list --shard 1/3 "$sb22s" 2>&1)")
s122s_2=$(run_lines "$(SUITE_DURATIONS="$led22s" bash "$RUNNER" --list --shard 1/3 "$sb22s" 2>&1)")
s222s_1=$(run_lines "$(SUITE_DURATIONS="$led22s" bash "$RUNNER" --list --shard 2/3 "$sb22s" 2>&1)")
s222s_2=$(run_lines "$(SUITE_DURATIONS="$led22s" bash "$RUNNER" --list --shard 2/3 "$sb22s" 2>&1)")
if [ "$s122s_1" = "$s122s_2" ] && [ "$s222s_1" = "$s222s_2" ] \
   && [ -n "$s122s_1" ] && [ -n "$s222s_1" ]; then
  pass "22s: shard 1/3 and 2/3 are byte-identical across repeated invocations under the new checks"
else
  fail "22s: plan moved under the new checks; s1a='$s122s_1' s1b='$s122s_2' s2a='$s222s_1' s2b='$s222s_2'"
fi
rm -rf "$sb22s"
fi

# 22t (codex-2) — a ledger row naming a suite that no longer exists is still
# ignored for ASSIGNMENT (it matches no eligible suite) but its duration
# still enters the median unknown suites inherit, exactly as
# docs/internals/testing.md states. Eligible: s1 (ledger 100s), s2/s3
# (unknown -> median). Ledger also carries a row for test-s4.sh, which this
# sandbox never creates — the deleted suite. Parsed durations are {100, 1};
# sorted [1,100], median = vals[int((2+1)/2)] = vals[1] = 1. s2/s3 each
# therefore weigh 1s, so longest-first packs s1 ALONE on its shard. Had the
# deleted row been filtered out of the median (codex-2's bug) only {100}
# would parse, median would be 100, and s2 or s3 would weigh as much as s1 —
# pairing s1 with one of them instead. The placement is the number's proxy:
# there is no other way to read a median out of --list.
sb22t=$(mktemp -d "${TMPDIR:-/tmp}/rst-case22t.XXXXXX") || { fail "22t: mktemp failed"; sb22t=""; }
if [ -n "$sb22t" ]; then
mk_shard_sandbox "$sb22t" 3
led22t="$sb22t/durations.tsv"
{ printf '# suite\tseconds\n'
  printf '%s/test-s1.sh\t100\n' "$sb22t"
  printf '%s/test-s4.sh\t1\n'   "$sb22t"; } > "$led22t"
full22t=$(run_lines "$(SUITE_DURATIONS="$led22t" bash "$RUNNER" --list "$sb22t" 2>&1)")
all22t=""
for i22t in 1 2; do
  all22t="${all22t}$(run_lines "$(SUITE_DURATIONS="$led22t" bash "$RUNNER" --list --shard "$i22t/2" "$sb22t" 2>&1)")
"
done
union22t=$(printf '%s' "$all22t" | grep -v '^$' | sort)
dupes22t=$(printf '%s' "$all22t" | grep -v '^$' | sort | uniq -d)
if [ "$union22t" = "$(sort <<< "$full22t")" ] && [ -z "$dupes22t" ]; then
  pass "22t: a deleted-suite ledger row does not drop or duplicate any suite"
else
  fail "22t: deleted-suite row broke the partition; union='$union22t' full='$full22t' dupes='$dupes22t'"
fi
own22t=""
for i22t in 1 2; do
  sh22t=$(run_lines "$(SUITE_DURATIONS="$led22t" bash "$RUNNER" --list --shard "$i22t/2" "$sb22t" 2>&1)")
  if grepq "$sh22t" -Fx "$sb22t/test-s1.sh"; then own22t="$sh22t"; fi
done
if [ "$own22t" = "$sb22t/test-s1.sh" ]; then
  pass "22t: s1 is alone on its shard — the deleted row's 1s entered the median (1s), not the 100s a filtered row would leave"
else
  fail "22t: expected s1 alone (median=1s from the deleted row); got '$own22t'"
fi
rm -rf "$sb22t"
fi

# 22u (codex-2) — a ledger whose LAST line has no trailing newline is still a
# complete, whole file; the join's own +1-per-record byte accounting must not
# charge that missing byte to the record it never had and refuse a clean read.
sb22u=$(mktemp -d "${TMPDIR:-/tmp}/rst-case22u.XXXXXX") || { fail "22u: mktemp failed"; sb22u=""; }
if [ -n "$sb22u" ]; then
mk_shard_sandbox "$sb22u" 3
led22u="$sb22u/durations.tsv"
{ printf '# suite\tseconds\n'
  printf '%s/test-s1.sh\t100\n' "$sb22u"
  printf '%s/test-s2.sh\t1\n'   "$sb22u"
  printf '%s/test-s3.sh\t1' "$sb22u"; } > "$led22u"
if [ -n "$(tail -c 1 "$led22u")" ]; then
  o22u=$(SUITE_DURATIONS="$led22u" bash "$RUNNER" --list --shard 1/2 "$sb22u" 2>&1); rc22u=$?
  if [ "$rc22u" -eq 0 ] \
     && [ -n "$(run_lines "$o22u")" ] \
     && ! grepq "$o22u" -F 'refusing to report green'; then
    pass "22u: a ledger without a final trailing newline is not spuriously refused"
  else
    fail "22u: no-trailing-newline ledger wrongly refused; rc=$rc22u out: $o22u"
  fi
else
  fail "22u: sandbox setup did not produce a no-trailing-newline ledger"
fi
rm -rf "$sb22u"
fi

# 22v (codex-1) — BSD/macOS wc right-pads a single -c count with leading
# spaces; GNU coreutils never does. A stub standing in for that padding must
# not desync the bytes-consumed comparison from a whole, matching read.
sb22v=$(mktemp -d "${TMPDIR:-/tmp}/rst-case22v.XXXXXX") || { fail "22v: mktemp failed"; sb22v=""; }
real_wc_22v=$(command -v wc)
if [ -n "$sb22v" ] && [ -n "$real_wc_22v" ]; then
mk_shard_sandbox "$sb22v" 3
led22v="$sb22v/durations.tsv"
{ printf '# suite\tseconds\n'
  printf '%s/test-s1.sh\t100\n' "$sb22v"
  printf '%s/test-s2.sh\t1\n'   "$sb22v"
  printf '%s/test-s3.sh\t1\n'   "$sb22v"; } > "$led22v"

mkdir -p "$sb22v/stub-v"
# shellcheck disable=SC2016
{ printf '#!/usr/bin/env bash\n'
  printf 'if [ "$1" = "-c" ] && [ "$#" -eq 1 ]; then\n'
  printf '  n=$(%s -c)\n' "$real_wc_22v"
  printf '  printf "%%8s\\n" "$n"\n'
  printf '  exit 0\n'
  printf 'fi\n'
  printf 'exec %s "$@"\n' "$real_wc_22v"; } > "$sb22v/stub-v/wc"
chmod +x "$sb22v/stub-v/wc"

o22v=$(PATH="$sb22v/stub-v:$PATH" SUITE_DURATIONS="$led22v" \
  bash "$RUNNER" --list --shard 1/2 "$sb22v" 2>&1); rc22v=$?
if [ "$rc22v" -eq 0 ] \
   && [ -n "$(run_lines "$o22v")" ] \
   && ! grepq "$o22v" -F 'refusing to report green'; then
  pass "22v: a padded wc -c count (BSD/macOS-style) does not desync the bytes check"
else
  fail "22v: padded wc -c wrongly refused; rc=$rc22v out: $o22v"
fi
rm -rf "$sb22v"
fi

rst_tally
