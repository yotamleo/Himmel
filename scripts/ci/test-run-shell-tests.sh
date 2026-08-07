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

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone. (HIMMEL-1430.)
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

RUNNER="$(cd "$(dirname "$0")" && pwd)/run-shell-tests.sh"

if [ ! -f "$RUNNER" ]; then
  echo "FAIL: runner not found at $RUNNER"
  exit 1
fi

# Point every invocation below at a throwaway lock (HIMMEL-1338). Without
# this, the cases here would contend for the real machine-wide lock with any
# full-suite run happening elsewhere on the box and refuse with rc 2 — a red
# suite that says nothing about the behaviour under test. Lock ACQUISITION is
# covered on purpose in test-suite-concurrency.sh, against its own sandbox.
SUITE_LOCK_SANDBOX=$(mktemp -d)
export SUITE_LOCK_DIR="$SUITE_LOCK_SANDBOX/suite.lock"
trap 'rm -rf "$SUITE_LOCK_SANDBOX"' EXIT

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
if grepq "$out3" -F '[SKIP]'; then
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

if grepq "$out6" -F '[SKIP]'; then
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
# Case 11 — known slow suites get path-specific budgets unless the operator
# supplies an explicit global SUITE_TIMEOUT (HIMMEL-1542). A sleep stub records
# the watchdog delay without waiting for it; the suite exits before the stub's
# real sleep completes, so the runner cancels the watchdog normally.
# --------------------------------------------------------------------------
echo "== Case 11: known slow suite budget and explicit override =="
sb11=$(mktemp -d -t himmel-suite-budget.XXXXXX)
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
  env -u SUITE_TIMEOUT bash "$RUNNER" "$sb11/scripts" >/dev/null 2>&1
rc11a=$?
if [ "$rc11a" -eq 0 ] && [ "$(cat "$sb11/default-timeout.log" 2>/dev/null)" = "1800" ]; then
  pass "known slow suite receives its 1800s path-specific budget"
else
  fail "known slow suite budget: rc=$rc11a recorded=$(cat "$sb11/default-timeout.log" 2>/dev/null) (want rc=0, 1800)"
fi

SLEEP_LOG="$sb11/explicit-timeout.log" PATH="$sb11/bin:$PATH" SUITE_TIMEOUT=7 \
  bash "$RUNNER" "$sb11/scripts" >/dev/null 2>&1
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
    bash "$RUNNER" "$sb11/scripts" >/dev/null 2>&1
  rc11c=$?
  if [ "$rc11c" -eq 0 ] && [ "$(cat "$log11" 2>/dev/null)" = "1800" ]; then
    pass "malformed SUITE_TIMEOUT='$bad' falls back to the path-specific budget"
  else
    fail "malformed SUITE_TIMEOUT='$bad': rc=$rc11c recorded=$(cat "$log11" 2>/dev/null) (want rc=0, 1800)"
  fi
done
rm -rf "$sb11"

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

mk_cond_sandbox() {  # $1 = sandbox dir; lays down test-pass.sh + the prop stub
  mkdir -p "$1"
  cat > "$1/test-pass.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
  cat > "$1/test-propagate-public.sh" <<'SHEOF'
#!/usr/bin/env bash
touch "$(dirname "$0")/prop-ran.sentinel"
exit 0
SHEOF
  chmod +x "$1/test-pass.sh" "$1/test-propagate-public.sh"
}

# Fake `git`: emits a controlled `diff --name-only` (contents of $GIT_FAKE_DIFF)
# and an empty untracked set, so the runner's changed_set is deterministic
# regardless of the real worktree's dirty state. Exits 0 for both so the
# runner's fail-open `&&` chain resolves to "filter active".
fakebin12=$(mktemp -d)
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
sb12a=$(mktemp -d); mk_cond_sandbox "$sb12a"
sentinel12a="$sb12a/prop-ran.sentinel"
out12a=$(bash "$RUNNER" "$sb12a" 2>&1); rc12a=$?
if [ "$rc12a" -eq 0 ] && [ -f "$sentinel12a" ]; then
  pass "12a: flag absent -> conditional suite runs"
else
  fail "12a: flag absent expected run (rc=0, sentinel); rc=$rc12a sentinel=$([ -f "$sentinel12a" ] && echo yes || echo no); out: $out12a"
fi
rm -rf "$sb12a"

# 12b — flag + matching change (a propagation path): conditional suite RUNS.
sb12b=$(mktemp -d); mk_cond_sandbox "$sb12b"
sentinel12b="$sb12b/prop-ran.sentinel"
diff12b="$sb12b/diff.txt"; printf 'scripts/propagate-public.sh\n' > "$diff12b"
out12b=$(GIT_FAKE_DIFF="$diff12b" PATH="$fakebin12:$PATH" bash "$RUNNER" "$sb12b" --changed-since HEAD 2>&1); rc12b=$?
if [ "$rc12b" -eq 0 ] && [ -f "$sentinel12b" ] && ! grepq "$out12b" "conditional: no changed path matches"; then
  pass "12b: flag + matching change -> conditional suite runs"
else
  fail "12b: expected run on matching change; rc=$rc12b sentinel=$([ -f "$sentinel12b" ] && echo yes || echo no); out: $out12b"
fi
rm -rf "$sb12b"

# 12c — flag + NO matching change: conditional suite SKIPped with the reason.
# A real path that does NOT match the propagation ERE.
sb12c=$(mktemp -d); mk_cond_sandbox "$sb12c"
sentinel12c="$sb12c/prop-ran.sentinel"
diff12c="$sb12c/diff.txt"; printf 'scripts/ci/run-shell-tests.sh\n' > "$diff12c"
out12c=$(GIT_FAKE_DIFF="$diff12c" PATH="$fakebin12:$PATH" bash "$RUNNER" "$sb12c" --changed-since HEAD 2>&1); rc12c=$?
if [ "$rc12c" -eq 0 ] && [ ! -f "$sentinel12c" ] && grepq "$out12c" "conditional: no changed path matches"; then
  pass "12c: flag + no matching change -> conditional suite SKIPped with reason"
else
  fail "12c: expected SKIP with reason; rc=$rc12c sentinel=$([ -f "$sentinel12c" ] && echo yes || echo no); out: $out12c"
fi
rm -rf "$sb12c"

# 12d — bad ref: fail-open (REAL git, no fake). NOTE printed, every suite runs.
sb12d=$(mktemp -d); mk_cond_sandbox "$sb12d"
sentinel12d="$sb12d/prop-ran.sentinel"
out12d=$(bash "$RUNNER" "$sb12d" --changed-since definitely-not-a-ref-xyz-1589 2>&1); rc12d=$?
if [ "$rc12d" -eq 0 ] && [ -f "$sentinel12d" ] && grepq "$out12d" "running every suite"; then
  pass "12d: bad ref -> fail-open runs every suite (NOTE printed)"
else
  fail "12d: expected fail-open run-all; rc=$rc12d sentinel=$([ -f "$sentinel12d" ] && echo yes || echo no); out: $out12d"
fi
rm -rf "$sb12d"

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
sb12e=$(mktemp -d); mk_cond_sandbox "$sb12e"
sentinel12e="$sb12e/prop-ran.sentinel"
out12e=$(PATH="$fakebin12:$PATH" bash "$RUNNER" "$sb12e" --changed-since --exit-code 2>&1); rc12e=$?
if [ "$rc12e" -eq 0 ] && [ -f "$sentinel12e" ] && grepq "$out12e" "running every suite"; then
  pass "12e: option-shaped --changed-since value -> fail-open runs every suite (NOTE printed)"
else
  fail "12e: expected fail-open run-all for option-shaped value; rc=$rc12e sentinel=$([ -f "$sentinel12e" ] && echo yes || echo no); out: $out12e"
fi
rm -rf "$sb12e"

rm -rf "$fakebin12"

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
