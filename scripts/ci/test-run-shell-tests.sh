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
#   14. SUITE_TIER / SUITE_TIER_MODE (HIMMEL-2120): fast/extended/all filter
#       plus its exit-2 invalid-mode case and its composition with SKIP_LIST
#       and SUITE_REQUIRE_TOOL.
#   15. Docs-only fast lane (HIMMEL-2166): --changed-since + an all-docs diff
#       skips the whole corpus (ran=0 reported as a pass); a mixed or empty
#       diff leaves the fast lane inert.
#   16. CAP EXCEEDED vs genuine rc=124 (HIMMEL-2233): a watchdog-killed suite
#       renders distinctly from a real assertion failure, keyed on `capped`
#       not on the exit code; the Disposition order block appears only when
#       fail>0.
#   17. Resume rotation (HIMMEL-2243): a truncated run writes a cursor naming
#       the first unrun suite; the next run resumes there and wraps, covering
#       every suite without re-running the same front section forever; a
#       completed run clears the cursor; a stale cursor falls back loudly;
#       SUITE_ROTATE=0 disables it; --list never rotates or writes a cursor;
#       HOME unset does not crash the runner (17g) and does not synthesise a
#       shared root-level cursor path either -- rotation disables outright
#       instead (17h, FIX 4); a run whose plan is NARROWED (--skip-extra,
#       17i; SUITE_TIER_MODE=fast, 17j) leaves an existing cursor untouched
#       rather than clearing it on the strength of a partial plan (FIX 8); a
#       symlinked cursor path is refused outright, read or write, rather than
#       followed through to overwrite whatever it targets (17k, FIX 9); two
#       scan roots that collide under the lock's lossy slug ("a/b" vs a
#       literal "a__b") still get distinct cursor files (17l), and completing
#       one root's run never clears or overwrites the other root's cursor
#       (17m, CodeRabbit Major finding on the cursor-key encoding).
#
#   18. SKIP_LIST scan-root invariance (HIMMEL-2260): a directory-qualified
#       entry skips its suite identically under a full scan, a scoped scan of
#       its own directory, a trailing-slash spelling of that root and --list --
#       byte-identical [SKIP] lines -- with controls proving the skip stays
#       selective, matches on a "/" boundary rather than a substring, does not
#       reach a same-basename suite in another directory, holds under a
#       SYMLINKED scan root (where `find` drops the "scripts/" component), and
#       matches a '*' table entry literally rather than as a glob (probed
#       through SUITE_TIER, which really uses the shared predicate), does the
#       same for a caller-supplied --skip-extra entry, and keeps --skip-extra
#       SCAN-ROOT-relative rather than suffix-matched. 18j does the same
#       collision check for SUITE_REQUIRE_TOOL; Case 12c covers
#       SUITE_CONDITIONAL. 18k/18l target the sibling HIMMEL-2508 discovery
#       bug on that same symlinked root: pre-fix, `find` never descends into
#       a symlinked scan root at all, so discovery returns EMPTY and the
#       runner exits 1 before 18h's verdict comparison is ever reached; 18k
#       asserts the suites under the link actually EXECUTED, 18l asserts
#       --list plans them identically through the link path as through the
#       physical root. 18m is a no-regression PIN rather than a red-first
#       case: it proves the fix's `-H` (dereference the scan-root ARGUMENT
#       only) never widened into `-L` (follow every symlink `find` walks
#       past), by planting a symlink one level below a physical, non-linked
#       scan root and asserting the suite behind it is NOT discovered,
#       alongside a real sibling suite that IS. 18m-R (HIMMEL-2544) is that
#       pin's RED control: it runs the same fixture against a scratch `-L`
#       mutant of the runner through the RED-control contract, so the
#       `-H` vs `-L` distinction 18m claims is EXECUTED, not just asserted
#       in prose.
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
# Same reasoning for the rotation cursor (HIMMEL-2243): no case here may write
# the real $HOME/.himmel cursor. Case 17 overrides this per sub-case with its
# own cursor path to exercise rotation itself.
#
# Sharing ONE path across every case other than Case 17 is safe only because
# none of them ever truncates: SUITE_RUN_BUDGET is set nowhere outside Case
# 17, so the runner never reaches the write branch that would use this path.
# Any FUTURE case that sets a truncating budget must pass its own
# SUITE_ROTATE_STATE, exactly as every Case 17 sub-case does — otherwise it
# inherits this shared sandbox path and its cursor write collides with
# whatever else happens to share it.
export SUITE_ROTATE_STATE="$SUITE_LOCK_SANDBOX/rotate.cursor"
trap 'rm -rf "$SUITE_LOCK_SANDBOX"' EXIT

# HIMMEL-2518/HIMMEL-2544: Case 18m-R's mutation control goes through the
# RED-control contract helper rather than a hand-rolled inequality — the helper
# asserts the mutant RAN, PRODUCED a value, and produced the SPECIFIC wrong
# value predicted, the three properties a `!=` check cannot establish.
# RED_CONTROL_TMPDIR keeps its stderr captures inside $SUITE_LOCK_SANDBOX, so
# the EXIT trap above already cleans them.
# shellcheck disable=SC2034  # read by red-control.sh, which the repo's lint
# runs shellcheck WITHOUT -x and therefore cannot see.
RED_CONTROL_TMPDIR="$SUITE_LOCK_SANDBOX"
# shellcheck source=../lib/red-control.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/../lib/red-control.sh"

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
#
# This sandbox's fixture path (scripts/handover/test-arm-resume-identity.sh)
# happens to match a production SUITE_TIER_DEFAULT entry, and tier_lookup's
# fix (r2 codex-1) now makes that match land on a subtree scan like this
# one's. `env -u SUITE_TIER_MODE` throughout keeps that fixture from being
# tier-skipped under an inherited SUITE_TIER_MODE=fast/extended, the same
# inheritance hole Case 14a closes.
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
sentinel12a="$sb12a/scripts/prop-ran.sentinel"
out12a=$(bash "$RUNNER" "$sb12a/scripts" 2>&1); rc12a=$?
if [ "$rc12a" -eq 0 ] && [ -f "$sentinel12a" ]; then
  pass "12a: flag absent -> conditional suite runs"
else
  fail "12a: flag absent expected run (rc=0, sentinel); rc=$rc12a sentinel=$([ -f "$sentinel12a" ] && echo yes || echo no); out: $out12a"
fi
rm -rf "$sb12a"

# 12b — flag + matching change (a propagation path): conditional suite RUNS.
sb12b=$(mktemp -d); mk_cond_sandbox "$sb12b"
sentinel12b="$sb12b/scripts/prop-ran.sentinel"
diff12b="$sb12b/diff.txt"; printf 'scripts/propagate-public.sh\n' > "$diff12b"
out12b=$(GIT_FAKE_DIFF="$diff12b" PATH="$fakebin12:$PATH" bash "$RUNNER" "$sb12b/scripts" --changed-since HEAD 2>&1); rc12b=$?
if [ "$rc12b" -eq 0 ] && [ -f "$sentinel12b" ] && ! grepq "$out12b" "conditional: no changed path matches"; then
  pass "12b: flag + matching change -> conditional suite runs"
else
  fail "12b: expected run on matching change; rc=$rc12b sentinel=$([ -f "$sentinel12b" ] && echo yes || echo no); out: $out12b"
fi
rm -rf "$sb12b"

# 12c — flag + NO matching change: conditional suite SKIPped with the reason.
# A real path that does NOT match the propagation ERE.
sb12c=$(mktemp -d); mk_cond_sandbox "$sb12c"
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

# 12d — bad ref: fail-open (REAL git, no fake). NOTE printed, every suite runs.
sb12d=$(mktemp -d); mk_cond_sandbox "$sb12d"
sentinel12d="$sb12d/scripts/prop-ran.sentinel"
out12d=$(bash "$RUNNER" "$sb12d/scripts" --changed-since definitely-not-a-ref-xyz-1589 2>&1); rc12d=$?
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
sentinel12e="$sb12e/scripts/prop-ran.sentinel"
out12e=$(PATH="$fakebin12:$PATH" bash "$RUNNER" "$sb12e/scripts" --changed-since --exit-code 2>&1); rc12e=$?
if [ "$rc12e" -eq 0 ] && [ -f "$sentinel12e" ] && grepq "$out12e" "running every suite"; then
  pass "12e: option-shaped --changed-since value -> fail-open runs every suite (NOTE printed)"
else
  fail "12e: expected fail-open run-all for option-shaped value; rc=$rc12e sentinel=$([ -f "$sentinel12e" ] && echo yes || echo no); out: $out12e"
fi
rm -rf "$sb12e"

rm -rf "$fakebin12"

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
sb13a=$(mktemp -d); mk_cap_sandbox "$sb13a"
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

# 13b — deterministic skip branch: a tool that cannot exist, injected via the
# env override the runner exposes for exactly this.
sb13b=$(mktemp -d); mk_cap_sandbox "$sb13b"
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
sb14a=$(mktemp -d "${TMPDIR:-/tmp}/himmel-tier-14a.XXXXXX"); mk_tier_sandbox "$sb14a"
out14a=$(SUITE_TIER="$TIER_FIXTURE" env -u SUITE_TIER_MODE bash "$RUNNER" "$sb14a" 2>&1); rc14a=$?
if [ "$rc14a" -eq 0 ] && [ -f "$sb14a/pass-ran.sentinel" ] && [ -f "$sb14a/tier-ran.sentinel" ]; then
  pass "14a: mode unset -> extended-listed suite runs (filter inert)"
else
  fail "14a: expected both suites to run; rc=$rc14a out: $out14a"
fi
rm -rf "$sb14a"

# 14b — mode=all: same as unset, both run.
sb14b=$(mktemp -d "${TMPDIR:-/tmp}/himmel-tier-14b.XXXXXX"); mk_tier_sandbox "$sb14b"
out14b=$(SUITE_TIER="$TIER_FIXTURE" SUITE_TIER_MODE=all bash "$RUNNER" "$sb14b" 2>&1); rc14b=$?
if [ "$rc14b" -eq 0 ] && [ -f "$sb14b/pass-ran.sentinel" ] && [ -f "$sb14b/tier-ran.sentinel" ]; then
  pass "14b: mode=all -> extended-listed suite runs"
else
  fail "14b: expected both suites to run; rc=$rc14b out: $out14b"
fi
rm -rf "$sb14b"

# 14c — mode=fast: extended-listed suite SKIPped loudly; the unlisted suite
# still runs (also covers "unlisted suite runs in fast" from the brief).
sb14c=$(mktemp -d "${TMPDIR:-/tmp}/himmel-tier-14c.XXXXXX"); mk_tier_sandbox "$sb14c"
out14c=$(SUITE_TIER="$TIER_FIXTURE" SUITE_TIER_MODE=fast bash "$RUNNER" "$sb14c" 2>&1); rc14c=$?
if [ "$rc14c" -eq 0 ] && [ -f "$sb14c/pass-ran.sentinel" ] && [ ! -f "$sb14c/tier-ran.sentinel" ] \
   && grepq "$out14c" "tier: extended (SUITE_TIER_MODE=fast)"; then
  pass "14c: mode=fast -> extended-listed suite SKIPped loudly, unlisted suite runs"
else
  fail "14c: expected loud tier skip + unlisted run; rc=$rc14c pass-ran=$([ -f "$sb14c/pass-ran.sentinel" ] && echo yes || echo no) tier-ran=$([ -f "$sb14c/tier-ran.sentinel" ] && echo yes || echo no); out: $out14c"
fi
rm -rf "$sb14c"

# 14d — mode=extended: runs ONLY the extended-listed suite; the unlisted
# suite is SKIPped.
sb14d=$(mktemp -d "${TMPDIR:-/tmp}/himmel-tier-14d.XXXXXX"); mk_tier_sandbox "$sb14d"
out14d=$(SUITE_TIER="$TIER_FIXTURE" SUITE_TIER_MODE=extended bash "$RUNNER" "$sb14d" 2>&1); rc14d=$?
if [ "$rc14d" -eq 0 ] && [ ! -f "$sb14d/pass-ran.sentinel" ] && [ -f "$sb14d/tier-ran.sentinel" ] \
   && grepq "$out14d" "tier: not extended-listed"; then
  pass "14d: mode=extended -> runs only the extended-listed suite"
else
  fail "14d: expected extended-only run; rc=$rc14d pass-ran=$([ -f "$sb14d/pass-ran.sentinel" ] && echo yes || echo no) tier-ran=$([ -f "$sb14d/tier-ran.sentinel" ] && echo yes || echo no); out: $out14d"
fi
rm -rf "$sb14d"

# 14e — invalid SUITE_TIER_MODE: loud error, exit 2.
sb14e=$(mktemp -d "${TMPDIR:-/tmp}/himmel-tier-14e.XXXXXX"); mk_tier_sandbox "$sb14e"
out14e=$(SUITE_TIER_MODE=bogus bash "$RUNNER" "$sb14e" 2>&1); rc14e=$?
if [ "$rc14e" -eq 2 ] && grepq "$out14e" "SUITE_TIER_MODE"; then
  pass "14e: invalid SUITE_TIER_MODE -> exit 2 with a loud error"
else
  fail "14e: expected exit 2 + error mentioning SUITE_TIER_MODE; rc=$rc14e out: $out14e"
fi
rm -rf "$sb14e"

# 14f — composition (r2 F12): a suite both extended-listed AND SKIP_LISTed
# never runs, even in mode=all where the tier table alone (with no mode
# narrowing anything) would otherwise let it run — isolates that SKIP_LIST
# wins independent of SUITE_TIER_MODE. The sandbox's unlisted test-pass.sh
# still runs under mode=all, so ran>0 and rc stays 0.
sb14f=$(mktemp -d "${TMPDIR:-/tmp}/himmel-tier-14f.XXXXXX"); mk_tier_sandbox "$sb14f"
out14f=$(SUITE_TIER="$TIER_FIXTURE" SUITE_TIER_MODE=all \
  bash "$RUNNER" "$sb14f" --skip-extra test-tier-extended.sh 2>&1); rc14f=$?
if [ "$rc14f" -eq 0 ] && [ -f "$sb14f/pass-ran.sentinel" ] && [ ! -f "$sb14f/tier-ran.sentinel" ] \
   && grepq "$out14f" "skipped via --skip-extra"; then
  pass "14f: SKIP_LIST wins over an extended-tier listing (never runs)"
else
  fail "14f: expected SKIP_LIST to win over tier; rc=$rc14f tier-ran=$([ -f "$sb14f/tier-ran.sentinel" ] && echo yes || echo no); out: $out14f"
fi
rm -rf "$sb14f"

# 14g — composition (r2 F12): an extended-listed suite whose required tool is
# absent still loud-skips ON THE TOOL in extended mode — proves tier is
# checked BEFORE SUITE_REQUIRE_TOOL (the suite clears the tier gate, then
# hits the capability gate), not that tier alone decided it. A second
# extended-listed, tool-satisfied suite keeps ran>0 in mode=extended (where
# the sandbox's unlisted test-pass.sh is itself tier-skipped), so a passing
# run here is evidence of the composition, not an all-skipped sandbox.
sb14g=$(mktemp -d "${TMPDIR:-/tmp}/himmel-tier-14g.XXXXXX"); mk_tier_sandbox "$sb14g"
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

# 14h — subtree scan (r2 codex-1): the production SUITE_TIER table lists
# repo-root-relative paths ("scripts/handover/..."), but a subtree scan (e.g.
# `run-shell-tests.sh scripts/handover`) strips the scan root, so tier_lookup
# receives just the bare filename. An exact-only match would silently miss
# every listed suite here (verified against production: SUITE_TIER_MODE=fast
# on a plain full scan ran all three extended-listed suites instead of
# skipping them) and fail OPEN to the fast tier. Reproduce that shape with a
# fixture: the suite lives under a subdirectory, the table lists it with that
# subdirectory prefix, and the scan root IS the subdirectory.
sb14h=$(mktemp -d "${TMPDIR:-/tmp}/himmel-tier-14h.XXXXXX")
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

fakebin15=$(mktemp -d)
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
sb15a=$(mktemp -d); mk_docs_sandbox "$sb15a"
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

# 15b — mixed diff: one non-docs path among docs paths -> fast lane inert,
# both suites run normally.
sb15b=$(mktemp -d); mk_docs_sandbox "$sb15b"
diff15b="$sb15b/diff.txt"; printf 'docs/foo.md\nscripts/ci/run-shell-tests.sh\n' > "$diff15b"
out15b=$(GIT_FAKE_DIFF="$diff15b" PATH="$fakebin15:$PATH" bash "$RUNNER" "$sb15b" --changed-since HEAD 2>&1); rc15b=$?
if [ "$rc15b" -eq 0 ] && [ -f "$sb15b/pass-ran.sentinel" ] && [ -f "$sb15b/pass2-ran.sentinel" ] \
   && ! grepq "$out15b" -F "docs-only"; then
  pass "15b: mixed diff -> fast lane inert, both suites run"
else
  fail "15b: expected both suites to run (fast lane inert); rc=$rc15b pass-ran=$([ -f "$sb15b/pass-ran.sentinel" ] && echo yes || echo no) pass2-ran=$([ -f "$sb15b/pass2-ran.sentinel" ] && echo yes || echo no); out: $out15b"
fi
rm -rf "$sb15b"

# 15c — empty diff (no tracked or untracked paths at all): NOT docs-only —
# nothing to base that claim on — so both suites run as normal.
sb15c=$(mktemp -d); mk_docs_sandbox "$sb15c"
diff15c="$sb15c/diff.txt"; : > "$diff15c"
out15c=$(GIT_FAKE_DIFF="$diff15c" PATH="$fakebin15:$PATH" bash "$RUNNER" "$sb15c" --changed-since HEAD 2>&1); rc15c=$?
if [ "$rc15c" -eq 0 ] && [ -f "$sb15c/pass-ran.sentinel" ] && [ -f "$sb15c/pass2-ran.sentinel" ] \
   && ! grepq "$out15c" -F "docs-only"; then
  pass "15c: empty diff -> not treated as docs-only, both suites run"
else
  fail "15c: expected both suites to run (empty diff is not docs-only); rc=$rc15c pass-ran=$([ -f "$sb15c/pass-ran.sentinel" ] && echo yes || echo no) pass2-ran=$([ -f "$sb15c/pass2-ran.sentinel" ] && echo yes || echo no); out: $out15c"
fi
rm -rf "$sb15c"

rm -rf "$fakebin15"

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
# Case 17 -- resume rotation (HIMMEL-2243)
#
# Six fake suites, each appending its own basename to a shared order log
# before exiting 0. A PASSED suite prints nothing of its own to the runner's
# stdout, so the order log — not stdout — is how ORDER is asserted.
#
# Asymmetric sleeps, not a uniform 2s each: the budget is checked BETWEEN
# suites, but the runner also spends real, unbounded-by-this-fixture time
# BEFORE the first check (git_test_env_pin_perf shells out to git, plus the
# runtime preflight and the lock acquire) — on a loaded box that setup alone
# can eat a small budget, truncating before test-a.sh ever runs and making the
# whole case flaky through no fault of the rotation logic. So test-a.sh sleeps
# 25s and everything else sleeps 1s, with a 15s budget for the truncating
# sub-cases: setup has 5x margin to finish inside 15s (it costs low
# single-digit seconds even loaded), and once test-a.sh itself is running, 25s
# guarantees the budget is spent before the check ahead of test-b.sh. Neither
# inequality is close, so which suite gets truncated is deterministic by
# construction rather than a race against setup cost.
# --------------------------------------------------------------------------
echo "== Case 17: resume rotation =="
sb17=$(mktemp -d "${TMPDIR:-/tmp}/himmel-suite-rotate.XXXXXX")
order17="$sb17/order.log"
cursor17="$sb17/rotate.cursor"
: > "$order17"
for c in a b c d e f; do
  dur=1
  [ "$c" = "a" ] && dur=25
  cat > "$sb17/test-$c.sh" <<SHEOF
#!/usr/bin/env bash
sleep $dur
echo test-$c.sh >> "$order17"
exit 0
SHEOF
  chmod +x "$sb17/test-$c.sh"
done

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

# --------------------------------------------------------------------------
# Case 18 (HIMMEL-2260) — SKIP_LIST verdicts are invariant under the scan root
#
# SKIP_LIST entries used to be matched against the SCAN-ROOT-RELATIVE path, so
# every directory-qualified entry went inert the moment the scan root moved
# into its own directory: a scoped `scripts/handover` run discovered the suite
# as "test-arm-resume.sh", matched nothing, and RAN a suite the ledger says can
# never run here. Measured live on 2026-08-30 (HIMMEL-2254): that scoped run
# hit CAP EXCEEDED at 604s and red-washed the leg's scoped evidence, while the
# full-scan ledger claimed the suite never runs. Both observations were true —
# which is the bug.
#
# 18b is the regression proper: it FAILS on the pre-fix runner. 18a is its
# full-scan twin, so the pair asserts PARITY (byte-identical [SKIP] lines)
# rather than merely "it skips somewhere". 18c/18d/18e are the controls that
# keep that parity from being vacuous — a matcher that skipped everything, or
# one that matched on a bare substring, would satisfy 18a+18b on its own.
#
# The fixture deliberately names a REAL production SKIP_LIST entry
# ("handover/test-arm-resume.sh"): SKIP_LIST has no env seam, so naming one of
# its entries is the only way to exercise the production table — exactly what
# Case 11 does for the slow-suite table.
# --------------------------------------------------------------------------
echo "== Case 18 (HIMMEL-2260): SKIP_LIST parity across scan roots =="
# Templated mktemp, not a bare `mktemp -d`: BSD/macOS mktemp requires a
# template. The failure capture is not ceremony here — an unguarded failure
# leaves $sb18 EMPTY, and every path below then resolves to "/scripts/..."
# at the filesystem root. The body is guarded rather than re-indented, so
# the diff stays readable; the closing `fi` is tagged at the case end.
sb18=$(mktemp -d "${TMPDIR:-/tmp}/cr-2260-skiplist.XXXXXX") || {
  fail "2260/18: could not create the Case 18 sandbox (mktemp -d failed)"
  sb18=""
}
if [ -n "$sb18" ]; then
mkdir -p "$sb18/scripts/handover" "$sb18/scripts/xhandover" "$sb18/scripts/nested"

# Matches the production SKIP_LIST entry "handover/test-arm-resume.sh".
cat > "$sb18/scripts/handover/test-arm-resume.sh" <<EOF
#!/usr/bin/env bash
: > "$sb18/ran-skiplisted"
exit 0
EOF
# Control 1: same directory, NOT listed -> must RUN under every scan root.
cat > "$sb18/scripts/handover/test-2260-control.sh" <<EOF
#!/usr/bin/env bash
: > "$sb18/ran-control"
exit 0
EOF
# Control 2 (boundary): "xhandover/" contains the entry's "handover/" as a
# substring but not as a path component, so a sloppy substring matcher would
# skip this suite and a "/"-boundary matcher must run it.
cat > "$sb18/scripts/xhandover/test-arm-resume.sh" <<EOF
#!/usr/bin/env bash
: > "$sb18/ran-boundary"
exit 0
EOF
# Control 3 (basename collision, codex-1): shares its BASENAME with the
# SKIP_LIST entry scripts/test-adopt.sh but lives one directory deeper. It
# must RUN — an entry is matched by its whole repo-relative path, never by
# basename, or a listed suite silently drags unrelated namesakes down with it.
cat > "$sb18/scripts/nested/test-adopt.sh" <<EOF
#!/usr/bin/env bash
: > "$sb18/ran-namesake"
exit 0
EOF
chmod +x "$sb18/scripts/handover"/*.sh "$sb18/scripts/xhandover"/*.sh "$sb18/scripts/nested"/*.sh

# probe18 <scan-root> — runs the runner over that root and republishes the
# sentinels as ran18_{skiplisted,control,boundary} alongside out18/rc18.
# `env -u SUITE_TIER_MODE` for the same reason Case 11 does it: an inherited
# fast/extended mode would filter this sandbox's fixtures on a different axis
# than the one under test.
probe18() {
  rm -f "$sb18/ran-skiplisted" "$sb18/ran-control" "$sb18/ran-boundary" "$sb18/ran-namesake"
  out18=$(env -u SUITE_TIER_MODE bash "$RUNNER" "$1" 2>&1); rc18=$?
  ran18_skiplisted=no; [ -e "$sb18/ran-skiplisted" ] && ran18_skiplisted=yes
  ran18_control=no;    [ -e "$sb18/ran-control" ]    && ran18_control=yes
  ran18_boundary=no;   [ -e "$sb18/ran-boundary" ]   && ran18_boundary=yes
  ran18_namesake=no;   [ -e "$sb18/ran-namesake" ]   && ran18_namesake=yes
  skipline18=$(grep -F '[SKIP]' <<< "$out18" | grep -F 'handover/test-arm-resume.sh')
  return 0
}

# 18a — full scan (the shape SKIP_LIST was written for).
echo "== Case 18a: full scan skips the listed suite =="
probe18 "$sb18/scripts"
out18a=$out18; rc18a=$rc18; skipline18a=$skipline18
if [ "$rc18a" -eq 0 ]; then
  pass "2260/18a: full scan -> exit 0"
else
  fail "2260/18a: expected exit 0 got $rc18a; output: $out18a"
fi
if [ "$ran18_skiplisted" = no ]; then
  pass "2260/18a: full scan — SKIP_LISTed suite did not execute"
else
  fail "2260/18a: sentinel present — the SKIP_LISTed suite ran under a full scan; output: $out18a"
fi
if grepq "$skipline18a" -F "$sb18/scripts/handover/test-arm-resume.sh" \
   && grepq "$skipline18a" -F 'no VM e2e coverage'; then
  pass "2260/18a: full scan — loud [SKIP] line names the suite AND carries its ledger reason"
else
  fail "2260/18a: expected a [SKIP] line naming the suite with its reason, got: '$skipline18a'"
fi
if [ "$ran18_control" = yes ] && [ "$ran18_boundary" = yes ]; then
  pass "2260/18a: full scan — both controls ran (the skip is selective, not a blanket)"
else
  fail "2260/18a: controls did not run (control=$ran18_control boundary=$ran18_boundary); output: $out18a"
fi

# 18b — the regression: the SAME entry under a scoped root. Pre-fix, this ran.
echo "== Case 18b: scoped scan skips the same suite identically (the regression) =="
probe18 "$sb18/scripts/handover"
out18b=$out18; rc18b=$rc18; skipline18b=$skipline18
if [ "$rc18b" -eq 0 ]; then
  pass "2260/18b: scoped scan -> exit 0"
else
  fail "2260/18b: expected exit 0 got $rc18b; output: $out18b"
fi
if [ "$ran18_skiplisted" = no ]; then
  pass "2260/18b: scoped scan — SKIP_LISTed suite did not execute (this is the assertion that FAILS on the pre-fix runner)"
else
  fail "2260/18b: sentinel present — a scoped scan RAN the SKIP_LISTed suite; the scan-root-relative match went inert. Output: $out18b"
fi
if [ -n "$skipline18a" ] && [ "$skipline18b" = "$skipline18a" ]; then
  pass "2260/18b: scoped and full scans emit a BYTE-IDENTICAL [SKIP] line (parity, reason included)"
else
  fail "2260/18b: scoped/full [SKIP] lines differ.
  full:   '$skipline18a'
  scoped: '$skipline18b'"
fi
if [ "$ran18_control" = yes ]; then
  pass "2260/18b: scoped scan — the unlisted control still ran"
else
  fail "2260/18b: the unlisted control did not run under the scoped root; output: $out18b"
fi

# 18c — boundary control under the scoped root that CONTAINS the near-miss.
echo "== Case 18c: a path-component near-miss is not skipped =="
probe18 "$sb18/scripts/xhandover"
if [ "$ran18_boundary" = yes ] && [ -z "$skipline18" ]; then
  pass "2260/18c: 'xhandover/test-arm-resume.sh' RAN — the entry matches on a '/' boundary, not a substring"
else
  fail "2260/18c: the near-miss suite was skipped (ran=$ran18_boundary skipline='$skipline18'); output: $out18"
fi

# 18d — scan-root SPELLING invariance: a trailing slash is the same root.
# Case 6 asserts this for --skip-extra; this is its SKIP_LIST twin, since the
# two now share one matching predicate.
echo "== Case 18d: trailing-slash scoped root gives the same verdict =="
probe18 "$sb18/scripts/handover/"
if [ "$ran18_skiplisted" = no ] && [ "$skipline18" = "$skipline18a" ]; then
  pass "2260/18d: trailing-slash scoped root — identical [SKIP] verdict"
else
  fail "2260/18d: trailing-slash root diverged (ran=$ran18_skiplisted line='$skipline18'); output: $out18"
fi

# 18e — --list agrees with execution. --list is the plan a coordinator reads
# to decide what a scoped run will cover; a plan that disagrees with the run
# is the same false-evidence class from a different direction.
echo "== Case 18e: --list reports the same scoped skip =="
out18e=$(env -u SUITE_TIER_MODE bash "$RUNNER" --list "$sb18/scripts/handover" 2>&1); rc18e=$?
if [ "$rc18e" -eq 0 ] \
   && grepq "$out18e" -F "[SKIP] $sb18/scripts/handover/test-arm-resume.sh" \
   && grepq "$out18e" -F "[RUN ] $sb18/scripts/handover/test-2260-control.sh"; then
  pass "2260/18e: --list over the scoped root plans the skip and the control identically"
else
  fail "2260/18e: --list plan disagrees (rc=$rc18e); output: $out18e"
fi

# 18h — a scan root reached through a SYMLINK gives the same verdict (the CR
# round-2 finding). A symlinked root makes `find` report the suite WITHOUT the
# "scripts/" component the entry carries, so an entry matched against the
# spelling the caller typed would miss and the listed suite would RUN. The
# runner resolves the scan root once (scan_resolved) precisely so the verdict
# cannot depend on which name reaches the same directory.
#
# Symlink creation is not universally available (unprivileged Windows), so this
# case SKIPS ITSELF loudly rather than failing where it cannot be exercised — a
# host that cannot make the link cannot exhibit the bug either.
#
# The guard tests -L, NOT -d, and that distinction is the whole case: MSYS `ln
# -s` without winsymlinks silently COPIES the directory instead of linking it,
# and a -d guard accepts that copy. The copy is a genuinely different path, so
# the runner correctly RUNS the suite there — which then reads as this case
# failing when nothing is wrong. (Observed exactly that on the first run of
# this case.) Only a real symlink reaches the same directory under a second
# name, which is the condition under test.
echo "== Case 18h: a symlinked scan root gives the same verdict =="
ln -s "$sb18/scripts/handover" "$sb18/link-handover" 2>/dev/null || true
if [ -L "$sb18/link-handover" ]; then
  probe18 "$sb18/link-handover"
  if [ "$ran18_skiplisted" = no ] && [ -n "$skipline18" ]; then
    pass "2260/18h: symlinked scan root — SKIP_LISTed suite still did not execute"
  else
    fail "2260/18h: symlinked scan root ran the SKIP_LISTed suite (ran=$ran18_skiplisted line='$skipline18'); output: $out18"
  fi
  if [ "$ran18_control" = yes ]; then
    pass "2260/18h: symlinked scan root — the unlisted control still ran"
  else
    fail "2260/18h: the unlisted control did not run under the symlinked root; output: $out18"
  fi
else
  # Drop a non-symlink stand-in (the MSYS copy case) so it cannot be discovered
  # as a stray fixture by any later scan of this sandbox.
  [ -e "$sb18/link-handover" ] && rm -rf "$sb18/link-handover"
  echo "  SKIP  2260/18h: cannot create a real symlink on this host — the spelling under test is unreachable here, so this assertion did NOT run"
fi

# 18k — HIMMEL-2508: the symlinked root must be DISCOVERED in the first
# place, which is a strictly earlier failure than the [SKIP]-verdict parity
# 18h checks. GNU `find "$scan" ... -print` reports a symlinked scan root as
# the link itself and does NOT descend into it (unlike `find -H`/`-L`), so
# discovery over $sb18/link-handover returns EMPTY pre-fix and the runner
# dies at its own "no test suites discovered under scan root" guard (exit 1)
# before any SKIP_LIST logic runs at all. 18h's assertions would already
# catch that collapse indirectly (the control's sentinel goes missing too),
# but only as a side effect of a check aimed at something else; this case
# names the discovery failure directly, reusing the same $sb18/link-handover
# fixture and probe18 helper 18h already set up (no symlink is re-created —
# if 18h could not make a real one, neither can this).
echo "== Case 18k: a symlinked scan root discovers and runs its suites (HIMMEL-2508) =="
if [ -L "$sb18/link-handover" ]; then
  probe18 "$sb18/link-handover"
  if [ "$rc18" -eq 0 ]; then
    pass "2508/18k: symlinked scan root -> exit 0"
  else
    fail "2508/18k: expected exit 0 got $rc18; output: $out18"
  fi
  if [ "$ran18_control" = yes ]; then
    pass "2508/18k: symlinked scan root — the unlisted control suite actually EXECUTED (discovery found it)"
  else
    fail "2508/18k: control sentinel absent — the symlinked root discovered nothing to run; output: $out18"
  fi
  if ! grepq "$out18" -F 'no test suites discovered'; then
    pass "2508/18k: symlinked scan root — runner never hit the empty-discovery guard"
  else
    fail "2508/18k: runner reported no suites discovered under the symlinked root; output: $out18"
  fi
else
  echo "  SKIP  2508/18k: cannot create a real symlink on this host — the spelling under test is unreachable here, so this assertion did NOT run"
fi

# 18l — HIMMEL-2508: --list must plan the symlinked root the same way it
# plans the physical one. --list runs the identical discovery `find` a real
# run does, so pre-fix it fails the same way (empty plan, exit 1) — a
# coordinator that plans with --list and then executes would see two
# different lies about the same scan root rather than one. This compares
# against 18e's plan (over $sb18/scripts/handover) with each output's own
# scan-root prefix stripped, so the assertion is genuine parity — the same
# two suites, [SKIP]/[RUN] preserved — not merely "the link path appeared
# somewhere in the output".
echo "== Case 18l: --list over a symlinked scan root plans the same suites as the physical root (HIMMEL-2508) =="
if [ -L "$sb18/link-handover" ]; then
  out18l=$(env -u SUITE_TIER_MODE bash "$RUNNER" --list "$sb18/link-handover" 2>&1); rc18l=$?
  # shellcheck disable=SC2001  # ${var//pattern/} can't take $sb18's own "/"s
  # as literal pattern text without per-slash backslash-escaping the
  # expansion; sed reads more plainly here than that would.
  plan18e=$(sed "s#$sb18/scripts/handover/##g" <<< "$out18e" | grep -E '^\[(SKIP|RUN )\]')
  # shellcheck disable=SC2001  # see above
  plan18l=$(sed "s#$sb18/link-handover/##g" <<< "$out18l" | grep -E '^\[(SKIP|RUN )\]')
  if [ "$rc18l" -eq 0 ] \
     && grepq "$out18l" -F "[SKIP] $sb18/link-handover/test-arm-resume.sh" \
     && grepq "$out18l" -F "[RUN ] $sb18/link-handover/test-2260-control.sh" \
     && [ "$plan18l" = "$plan18e" ]; then
    pass "2508/18l: --list over the symlinked root plans the same suites, through the link path, as --list over the physical root"
  else
    fail "2508/18l: --list plan over the symlinked root disagrees with the physical-root plan (rc=$rc18l).
  physical: '$plan18e'
  symlink:  '$plan18l'
  output: $out18l"
  fi
else
  echo "  SKIP  2508/18l: cannot create a real symlink on this host — the spelling under test is unreachable here, so this assertion did NOT run"
fi

# 18m — HIMMEL-2508 negative pin: `-H` dereferences the scan-root ARGUMENT
# only; a symlink encountered further down the tree during the walk must
# still NOT be followed. Without this row, nothing here distinguishes the
# narrow `-H` this fix shipped from a `-L`, which would also fix the reported
# bug but additionally follow every symlink `find` walks past -- letting the
# runner descend into arbitrary link targets and re-run suites through a
# second path. This plants the symlink one level BELOW a physical,
# non-symlinked scan root, alongside a real (non-symlinked) sibling suite in
# the same directory that must still be discovered -- so the row cannot pass
# vacuously by discovering nothing at all. This is a no-regression PIN, not a
# red-first case: plain pre-fix `find` never follows symlinks either, so this
# assertion holds on both the pre-fix and the fixed runner.
#
# Both halves below are already guarded against vacuity in their own right --
# the full-scan half requires rc=0 AND the positive control to have executed
# before its negative assertion counts, and the --list half requires rc=0 AND
# the plan to name the positive control before the absence of the linked suite
# counts. What NEITHER of them did until HIMMEL-2544 was EXECUTE the `-H` vs
# `-L` claim this comment makes: nothing here ever ran a `-L` runner, so the
# comment was the only evidence that the pin can tell the two apart. 18m-R
# below closes that: it builds a scratch `-L` mutant of the runner and asserts,
# through the RED-control contract, that the very same fixture DOES follow the
# interior symlink under `-L`. A literal migration of the two halves above to
# the contract helper would be wrong -- the helper FAILS an assert whose
# observed value equals the correct one, and a no-regression pin's observed
# value is by construction the correct one; a mutation control needs a mutant.
echo "== Case 18m: a symlink INSIDE the tree is not followed -- -H is not -L (HIMMEL-2508) =="
mkdir -p "$sb18/scripts/inner" "$sb18/link-target"
cat > "$sb18/scripts/inner/test-2508-real.sh" <<EOF
#!/usr/bin/env bash
: > "$sb18/ran-2508-real"
exit 0
EOF
cat > "$sb18/link-target/test-2508-linked.sh" <<EOF
#!/usr/bin/env bash
: > "$sb18/ran-2508-linked"
exit 0
EOF
chmod +x "$sb18/scripts/inner/test-2508-real.sh" "$sb18/link-target/test-2508-linked.sh"
ln -s "$sb18/link-target" "$sb18/scripts/inner/linked-suite" 2>/dev/null || true
if [ -L "$sb18/scripts/inner/linked-suite" ]; then
  rm -f "$sb18/ran-2508-real" "$sb18/ran-2508-linked"
  out18m=$(env -u SUITE_TIER_MODE bash "$RUNNER" "$sb18/scripts" 2>&1); rc18m=$?
  if [ "$rc18m" -eq 0 ]; then
    pass "2508/18m: full scan with an interior symlink present -> exit 0"
  else
    fail "2508/18m: expected exit 0 got $rc18m; output: $out18m"
  fi
  if [ -e "$sb18/ran-2508-real" ]; then
    pass "2508/18m: the real, non-symlinked sibling suite ran (the row is not vacuous)"
  else
    fail "2508/18m: the positive control did not run -- the fixture discovered nothing; output: $out18m"
  fi
  if [ ! -e "$sb18/ran-2508-linked" ]; then
    pass "2508/18m: the suite reached only through an INTERIOR symlink did NOT run -- -H does not widen to -L"
  else
    fail "2508/18m: the interior-symlink suite ran -- discovery followed a symlink below the scan root; output: $out18m"
  fi
  # This is a negative assertion (absence of the linked suite from the plan),
  # which a failed or degenerate --list run would satisfy for free -- an
  # empty plan also lacks 'test-2508-linked.sh'. Require the run to exit 0
  # AND name the positive control (test-2508-real.sh) before the absence of
  # the linked suite is allowed to count as anything.
  out18m_list=$(env -u SUITE_TIER_MODE bash "$RUNNER" --list "$sb18/scripts" 2>&1); rc18m_list=$?
  if [ "$rc18m_list" -ne 0 ]; then
    fail "2508/18m: --list exited $rc18m_list -- a failed plan proves nothing about what it omits; output: $out18m_list"
  elif ! grepq "$out18m_list" -F 'test-2508-real.sh'; then
    fail "2508/18m: --list did not name the positive control -- degenerate/empty plan, the negative assertion below would pass vacuously; output: $out18m_list"
  elif ! grepq "$out18m_list" -F 'test-2508-linked.sh'; then
    pass "2508/18m: --list agrees -- the real sibling IS planned and the interior-symlinked suite is not"
  else
    fail "2508/18m: --list named the interior-symlinked suite; output: $out18m_list"
  fi

  # 18m-R (HIMMEL-2544) — the RED control that makes 18m's `-H` vs `-L` claim
  # EXECUTABLE. 18m asserts the interior-symlinked suite is not discovered;
  # only this row shows that assertion can tell `-H` from `-L` at all. Build a
  # scratch copy of the runner with `-H` swapped for `-L` (HIMMEL-2503: the
  # mutant NEVER lives in the real tree, and no trap here consumes a repointed
  # path — the scratch root is pinned once and removed explicitly below), run
  # the SAME fixture through it, and require the predicted wrong value.
  #
  # The mutant is laid out as <scratch>/scripts/ci/run-shell-tests.sh with
  # scripts/lib alongside it, because the runner resolves REPO_ROOT from
  # ${BASH_SOURCE[0]}/../.. and sources proc-tree.sh / git-test-env.sh from
  # there; a bare mktemp copy would die at that source line and register as
  # the contract's `crashed` mode rather than exercising the mutation.
  mut18r_root=$(mktemp -d "${TMPDIR:-/tmp}/rst-18m-red.XXXXXX") || mut18r_root=""
  if [ -z "$mut18r_root" ]; then
    fail "2508/18m-R: mktemp failed -- could not build the -L mutant scratch root"
  else
    mut18r_repo="$(cd "$(dirname "$RUNNER")/.." && cd .. && pwd)"
    mkdir -p "$mut18r_root/scripts/ci"
    ln -s "$mut18r_repo/scripts/lib" "$mut18r_root/scripts/lib" 2>/dev/null || true
    mut18r="$mut18r_root/scripts/ci/run-shell-tests.sh"
    # The mutation anchor, matched LITERALLY (awk index(), not a regex): the
    # discovery `find` invocation in scripts/ci/run-shell-tests.sh. This
    # couples 18m-R to that line — if the runner's find invocation is
    # respelled, the guard below fails LOUDLY with the observed counts rather
    # than silently producing an unmutated copy that "proves" the pin.
    # shellcheck disable=SC2016  # literal source text of the runner, not an
    # expansion to perform here.
    mut18r_old='find -H "$scan"'
    # shellcheck disable=SC2016  # see above
    mut18r_new='find -L "$scan"'
    RC_OLD="$mut18r_old" RC_NEW="$mut18r_new" awk '
      BEGIN { o = ENVIRON["RC_OLD"]; n = ENVIRON["RC_NEW"] }
      {
        out = ""; line = $0
        while ((p = index(line, o)) > 0) {
          out = out substr(line, 1, p - 1) n
          line = substr(line, p + length(o))
        }
        print out line
      }
    ' "$RUNNER" > "$mut18r"
    mut18r_pre=$(grep -oF "$mut18r_old" "$RUNNER" | wc -l | tr -d ' ')
    mut18r_post_old=$(grep -oF "$mut18r_old" "$mut18r" | wc -l | tr -d ' ')
    mut18r_post_new=$(grep -oF "$mut18r_new" "$mut18r" | wc -l | tr -d ' ')
    mut18r_difflines=$(diff "$RUNNER" "$mut18r" | grep -c '^[<>]')
    if [ "$mut18r_pre" != "1" ] || [ "$mut18r_post_old" != "0" ] \
       || [ "$mut18r_post_new" != "1" ] || [ "$mut18r_difflines" != "2" ]; then
      fail "2508/18m-R: mutation anchor '$mut18r_old' did not match EXACTLY once in $RUNNER -- occurrences before=$mut18r_pre, after: old=$mut18r_post_old new=$mut18r_post_new, changed diff lines=$mut18r_difflines (want 1/0/1/2). A stale anchor would leave the mutant unmutated and this control would pass vacuously."
    else
      rm -f "$sb18/ran-2508-real" "$sb18/ran-2508-linked"
      red_control_run --cwd "$sb18" -- env -u SUITE_TIER_MODE bash "$mut18r" "$sb18/scripts"
      ran18r_real=not-ran;   [ -e "$sb18/ran-2508-real" ]   && ran18r_real=ran
      ran18r_linked=not-ran; [ -e "$sb18/ran-2508-linked" ] && ran18r_linked=ran
      if red_control_assert --label "2508/18m-R" \
        --expect-rc 0 \
        --observed     "real=$ran18r_real linked=$ran18r_linked" \
        --expect-wrong "real=ran linked=ran" \
        --correct      "real=ran linked=not-ran" \
        --note "a -L runner descends through the INTERIOR symlink and runs the suite behind it, so 18m's negative assertion above really does distinguish the narrow -H the fix shipped from -L -- a claim 18m previously made only in prose"; then
        pass "2508/18m-R: the -L mutant follows the interior symlink -- 18m's -H-is-not-L claim is executed, not asserted"
      else
        fail "2508/18m-R: the RED control did not confirm (see the FAIL line above) -- 18m cannot be shown to distinguish -H from -L"
      fi
      rm -f "$sb18/ran-2508-real" "$sb18/ran-2508-linked"
    fi
    rm -rf "$mut18r_root"
  fi

  rm -f "$sb18/scripts/inner/linked-suite"
else
  [ -e "$sb18/scripts/inner/linked-suite" ] && rm -rf "$sb18/scripts/inner/linked-suite"
  echo "  SKIP  2508/18m: cannot create a real symlink on this host — the spelling under test is unreachable here, so this assertion did NOT run"
fi
rm -rf "$sb18/scripts/inner" "$sb18/link-target"

# 18g — basename over-reach (the codex-1 panel finding on this PR). The entry
# is scripts/test-adopt.sh; a namesake one directory deeper must still RUN.
# Without this, a boundary-anchored suffix match on an UNDER-qualified entry
# would skip every nested suite sharing the basename — the same false-evidence
# class as the bug this ticket fixes, pointing the other way.
echo "== Case 18g: a same-basename suite in another directory is not skipped =="
probe18 "$sb18/scripts"
if [ "$ran18_namesake" = yes ]; then
  pass "2260/18g: 'scripts/nested/test-adopt.sh' RAN — entries match the whole path, not the basename"
else
  fail "2260/18g: the namesake suite was skipped by the scripts/test-adopt.sh entry; output: $out18"
fi

# 18i — --skip-extra keeps its SCAN-ROOT-RELATIVE semantics (CR round 3). The
# table matcher is suffix-tolerant on purpose; --skip-extra must NOT be, or a
# caller who scoped a run precisely silently loses unrelated nested suites.
# Under the full sandbox root the control's relpath is
# "handover/test-2260-control.sh", so a bare "test-2260-control.sh" names
# nothing at this root and must skip nothing.
echo "== Case 18i: --skip-extra is scan-root-relative, not suffix-matched =="
rm -f "$sb18/ran-skiplisted" "$sb18/ran-control" "$sb18/ran-boundary" "$sb18/ran-namesake"
out18i=$(env -u SUITE_TIER_MODE bash "$RUNNER" "$sb18/scripts" --skip-extra test-2260-control.sh 2>&1)
rc18i=$?
if [ "$rc18i" -eq 0 ] && [ -e "$sb18/ran-control" ] \
   && ! grepq "$out18i" -F 'skipped via --skip-extra'; then
  pass "2260/18i: --skip-extra 'test-2260-control.sh' matched nothing at this scan root — the nested suite still ran"
else
  fail "2260/18i: --skip-extra suffix-matched a nested suite (rc=$rc18i); output: $out18i"
fi
# And it still matches when the relpath IS the entry (the documented use).
rm -f "$sb18/ran-control"
out18i2=$(env -u SUITE_TIER_MODE bash "$RUNNER" "$sb18/scripts/handover" --skip-extra test-2260-control.sh 2>&1)
if [ ! -e "$sb18/ran-control" ] && grepq "$out18i2" -F 'skipped via --skip-extra'; then
  pass "2260/18i: --skip-extra still skips the suite whose scan-root-relative path IS the entry"
else
  fail "2260/18i: --skip-extra failed to skip its own scan-root-relative entry; output: $out18i2"
fi

# 18j — the capability table matches whole paths too (HIMMEL-2260, CR). Uses
# the SUITE_REQUIRE_TOOL env seam with a guaranteed-absent tool so the skip
# branch is deterministic on EVERY host — the production entry's tool (pwsh)
# exists on some hosts and not others, which would make this vacuous where it
# is present. The entry names the top-level suite; the nested namesake must
# still run.
echo "== Case 18j: a capability entry does not reach a same-basename suite elsewhere =="
mkdir -p "$sb18/scripts/nested"
cat > "$sb18/scripts/test-cap-collide.sh" <<EOF
#!/usr/bin/env bash
: > "$sb18/ran-cap-top"
exit 0
EOF
cat > "$sb18/scripts/nested/test-cap-collide.sh" <<EOF
#!/usr/bin/env bash
: > "$sb18/ran-cap-nested"
exit 0
EOF
chmod +x "$sb18/scripts/test-cap-collide.sh" "$sb18/scripts/nested/test-cap-collide.sh"
rm -f "$sb18/ran-cap-top" "$sb18/ran-cap-nested"
out18j=$(SUITE_REQUIRE_TOOL='scripts/test-cap-collide.sh  himmel-absent-tool-2260  # collision probe' \
         env -u SUITE_TIER_MODE bash "$RUNNER" "$sb18/scripts" 2>&1)
rc18j=$?
if [ "$rc18j" -eq 0 ] && [ ! -e "$sb18/ran-cap-top" ] && [ -e "$sb18/ran-cap-nested" ]; then
  pass "2260/18j: the capability entry skipped only its own suite; the nested namesake ran"
else
  fail "2260/18j: capability entry over-reached or under-reached (rc=$rc18j top=$([ -e "$sb18/ran-cap-top" ] && echo ran || echo skipped) nested=$([ -e "$sb18/ran-cap-nested" ] && echo ran || echo skipped)); output: $out18j"
fi
rm -f "$sb18/scripts/test-cap-collide.sh" "$sb18/scripts/nested/test-cap-collide.sh"

# 18f — glob-safety of the SHARED PREDICATE, exercised through a table that
# actually uses it. suite_entry_matches matches entries inside `case` patterns,
# where an UNQUOTED expansion would be glob-expanded and a '*' entry would
# wildcard the whole corpus away — reported as a clean green run.
#
# This must go through SUITE_TIER, not --skip-extra. --skip-extra is compared
# with a literal `[ "$_path" = "$relneedle" ]` and does not touch the predicate
# at all (CR round 3), so asserting glob-safety through it would pass no matter
# how the predicate behaved — vacuous with respect to the property named. That
# was this case's own bug, caught in CR round 4. SUITE_TIER is env-overridable
# AND routes through suite_entry_matches, so it is a real probe: under
# SUITE_TIER_MODE=fast a tier-listed suite is skipped, so if '*' expanded,
# EVERY suite would be skipped and the all-skipped root would fail the run.
echo "== Case 18f: a glob in a suite table is matched literally, not expanded =="
rm -f "$sb18/ran-skiplisted" "$sb18/ran-control" "$sb18/ran-boundary"
out18f=$(SUITE_TIER='*  extended  # glob probe' SUITE_TIER_MODE=fast \
         bash "$RUNNER" "$sb18/scripts/handover" 2>&1)
rc18f=$?
if [ "$rc18f" -eq 0 ] && [ -e "$sb18/ran-control" ] \
   && ! grepq "$out18f" -F 'tier: extended'; then
  pass "2260/18f: a '*' SUITE_TIER entry matched nothing — suite_entry_matches compares literally"
else
  fail "2260/18f: a '*' table entry behaved as a wildcard through suite_entry_matches (rc=$rc18f); output: $out18f"
fi

# 18f2 — the same literalness for --skip-extra, which now has its OWN exact
# comparison. Separate assertion because it exercises separate code.
echo "== Case 18f2: a glob in --skip-extra is matched literally =="
rm -f "$sb18/ran-skiplisted" "$sb18/ran-control" "$sb18/ran-boundary"
out18f2=$(env -u SUITE_TIER_MODE bash "$RUNNER" "$sb18/scripts/handover" --skip-extra '*' 2>&1)
rc18f2=$?
if [ "$rc18f2" -eq 0 ] \
   && [ -e "$sb18/ran-control" ] \
   && ! grepq "$out18f2" -F 'skipped via --skip-extra'; then
  pass "2260/18f2: --skip-extra '*' skipped nothing — the entry is compared literally"
else
  fail "2260/18f2: --skip-extra '*' behaved as a wildcard (rc=$rc18f2); output: $out18f2"
fi

rm -rf "$sb18"
fi   # end: Case 18 sandbox guard

# --------------------------------------------------------------------------
# Case 2267 — _suite_timeout_for's three HIMMEL-2267 timeout-table arms
# (scripts/test-propagate-public.sh, scripts/ci/test-run-shell-tests.sh,
# scripts/ci/test-suite-concurrency.sh) are new/revised on this branch and
# had no assertion. Each arm uses a dual "path|*/path" pattern because the
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
  check_timeout_2267 "scripts/ci/test-run-shell-tests.sh" "1200"
  check_timeout_2267 "/repo/scripts/ci/test-run-shell-tests.sh" "1200"
  check_timeout_2267 "scripts/ci/test-suite-concurrency.sh" "1500"
  check_timeout_2267 "/repo/scripts/ci/test-suite-concurrency.sh" "1500"
fi

# --------------------------------------------------------------------------
# Case 19 — --pr <N> / SUITE_REPORT_PR (HIMMEL-2383): the runner posts its
# own SUMMARY block as a PR comment via a GH_CMD-stubbed `gh`, opt-in only,
# best-effort (a post failure never changes the run's own exit code), and
# never fires under --list.
# --------------------------------------------------------------------------
echo "== Case 19: --pr / SUITE_REPORT_PR after-report posting =="
sb19=$(mktemp -d "${TMPDIR:-/tmp}/rst-case19.XXXXXX")
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

# --------------------------------------------------------------------------
# Case 21 — a run that measured its own environment, not the tests
# (HIMMEL-2517). Two independent signatures, each with its own control:
#
#   21a  the scan root is DELETED mid-run  -> ABORTED, exit 3, no Summary at
#        all and no --pr post. This is the filed incident: merge-on-green
#        pruned the worktree a full-tree after-report was executing inside, so
#        every remaining `bash "$suite"` exited 127 and the run rendered
#        PASS 6 / SKIP 19 / FAIL 422. Only `gh` failing for the same reason
#        kept that artifact off a merged, green PR.
#   21b  >=90% of the suites that RAN at rc=127, over a floor of 10 such
#        failures            -> CONTAMINATED, exit 4, no post.
#        The second, independent signature: it does not depend on the root
#        still being missing when the run ends, so it also covers a root that
#        was replaced, or a PATH/mount that collapsed mid-run.
#   21c  five suites, ALL rc=127 -> ratio met, floor missed, so an ordinary
#        red run that still posts. Without the floor, a suite whose fixture is
#        genuinely missing a binary would be reclassified as contamination.
#   21d  as many failures as 21b but at ordinary rc=1 -> also an ordinary red
#        run that still posts. This is what keeps the predicate anchored on
#        rc=127 rather than on "a lot of red".
#   21e  the root is REMOVED AND RECREATED at the same path -> ABORTED,
#        exit 3, "replaced" not "vanished". Round-1 CR finding codex-2: an
#        existence test passes for a different checkout sitting at the same
#        pathname, which is what `git worktree add` leaves behind.
#   21f  12 rc=127 failures alongside 30 passes -> an ordinary red run that
#        still posts. Round-1 CR finding codex-1: measured against FAILURES
#        this is 100% and would be suppressed, silencing a real regression;
#        measured against the whole run it is 28% and is reported.
#
# Every sub-case drives the SAME GH_CMD stub Case 19 uses, because "did not
# post" is the assertion that matters — printing a wrong tally locally is a
# nuisance, publishing one to a merged PR is the bug.
# --------------------------------------------------------------------------
echo "== Case 21: vanished scan root / rc=127 contamination =="

mk_gh21() {  # mk_gh21 <stub-path> <log-path>
  cat > "$1" <<GHEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$2"
exit 0
GHEOF
  chmod +x "$1"
}

# --- 21a: scan root deleted mid-run ---------------------------------------
# The deletion is REAL, not simulated: the first suite the runner executes
# removes the scan root out from under it, which is precisely what
# `git worktree remove` did in the incident. The sandbox is a fresh
# `mktemp -d` and nothing else — never a worktree, never a checkout.
# A failed mktemp leaves the variable EMPTY, and every path below is built
# on it — the fixtures would then be written to, and deleted from, the
# filesystem root (round-2 CR finding codex-3). Capture the failure here,
# where it is one line, rather than discovering it as a stray '/test-*.sh'.
sb21a=$(mktemp -d "${TMPDIR:-/tmp}/rst-case21a.XXXXXX")
if [ -z "$sb21a" ] || [ ! -d "$sb21a" ]; then
  fail "21a: mktemp -d produced no sandbox — refusing to build fixture paths on an empty root"
  exit 1
fi
gh21a="$sb21a.gh"
gh21a_log="$sb21a.gh.log"
mk_gh21 "$gh21a" "$gh21a_log"
rm -f "$gh21a_log"

# Sorted first, so it runs before the suites it strands. It pins the SHAPE of
# the path it is about to delete before deleting anything (HIMMEL-2518: a
# control must never aim a recursive delete at a variable it merely trusts),
# and steps out of the tree first so its own cwd is not the thing it removes.
cat > "$sb21a/test-01-nuke.sh" <<NUKEEOF
#!/usr/bin/env bash
set -uo pipefail
target='$sb21a'
case "\$target" in
  */rst-case21a.??????) ;;
  *) echo "refusing to delete an unexpected path: \$target" >&2; exit 1 ;;
esac
cd / || exit 1
rm -rf "\$target"
exit 0
NUKEEOF
for n in 02 03 04; do
  cat > "$sb21a/test-$n-victim.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
  chmod +x "$sb21a/test-$n-victim.sh"
done
chmod +x "$sb21a/test-01-nuke.sh"

out21a=$(GH_CMD="$gh21a" bash "$RUNNER" "$sb21a" --pr 2517 2>&1)
rc21a=$?

if [ "$rc21a" -eq 3 ]; then
  pass "21a: a vanished scan root aborts with exit 3"
else
  fail "21a: expected exit 3, got $rc21a; output: $out21a"
fi
if grepq "$out21a" -F 'ABORTED: scan root vanished'; then
  pass "21a: says ABORTED: scan root vanished"
else
  fail "21a: expected 'ABORTED: scan root vanished'; output: $out21a"
fi
# The whole point: no tally is rendered at all, so there is nothing for a
# reader (or base-status.sh) to mistake for a test result.
if grepq "$out21a" -F '== Summary =='; then
  fail "21a: a Summary was rendered for a run whose tree had vanished; output: $out21a"
else
  pass "21a: no Summary block is rendered"
fi
if [ -s "$gh21a_log" ]; then
  fail "21a: the after-report was POSTED despite the vanished root; gh.log='$(cat "$gh21a_log" 2>/dev/null)'"
else
  pass "21a: --pr 2517 given, but nothing was posted"
fi
# Proves the sub-case exercised what it claims: the root really is gone, so
# the abort above is the runner detecting a real deletion, not a stat quirk.
if [ -d "$sb21a" ]; then
  fail "21a: the nuke suite did not actually remove the scan root — the case tested nothing"
else
  pass "21a: the scan root really was deleted mid-run"
fi
rm -f "$gh21a" "$gh21a_log"

# --- 21b: rc=127 storm ------------------------------------------------------
# Twelve suites, each ending on a command that does not exist: 12/12 = 100%
# of failures at rc=127, over the floor. The scan root is INTACT throughout,
# so 21a's guard cannot be what fires here — this is the independent signature.
# A failed mktemp leaves the variable EMPTY, and every path below is built
# on it — the fixtures would then be written to, and deleted from, the
# filesystem root (round-2 CR finding codex-3). Capture the failure here,
# where it is one line, rather than discovering it as a stray '/test-*.sh'.
sb21b=$(mktemp -d "${TMPDIR:-/tmp}/rst-case21b.XXXXXX")
if [ -z "$sb21b" ] || [ ! -d "$sb21b" ]; then
  fail "21b: mktemp -d produced no sandbox — refusing to build fixture paths on an empty root"
  exit 1
fi
gh21b="$sb21b/gh"
gh21b_log="$sb21b/gh.log"
mk_gh21 "$gh21b" "$gh21b_log"
rm -f "$gh21b_log"
n=1
while [ "$n" -le 12 ]; do
  cat > "$sb21b/test-127-$n.sh" <<'SHEOF'
#!/usr/bin/env bash
himmel_2517_no_such_command_anywhere
SHEOF
  chmod +x "$sb21b/test-127-$n.sh"
  n=$((n + 1))
done

out21b=$(GH_CMD="$gh21b" bash "$RUNNER" "$sb21b" --pr 2517 2>&1)
rc21b=$?

if [ "$rc21b" -eq 4 ]; then
  pass "21b: an all-rc=127 failure set exits 4"
else
  fail "21b: expected exit 4, got $rc21b; output: $out21b"
fi
if grepq "$out21b" -F 'CONTAMINATED: 12 of the 12 suites that ran exited rc=127'; then
  pass "21b: names the exact rc=127 share of the whole run"
else
  fail "21b: expected 'CONTAMINATED: 12 of the 12 suites that ran exited rc=127'; output: $out21b"
fi
if [ -s "$gh21b_log" ]; then
  fail "21b: the contaminated SUMMARY was POSTED; gh.log='$(cat "$gh21b_log" 2>/dev/null)'"
else
  pass "21b: --pr 2517 given, but nothing was posted"
fi
rm -rf "$sb21b"

# --- 21c: CONTROL — the same shape, below the floor -------------------------
# The floor is the ONLY thing that may separate this from 21b, so the case has
# to meet the ratio and miss the floor — otherwise it proves nothing about
# either (round-3 CR finding codex-1: an earlier shape put a passing suite
# alongside three failures, which misses the 90%-of-`ran` ratio too, so removing
# the floor entirely would not have turned it red). Five suites, all rc=127:
# 5/5 = 100% clears the ratio, and 5 rc=127 failures sits under the floor of 10. It
# must stay an ordinary red run and must still post — without the floor, every
# small run with one missing-binary fixture would be called contaminated and go
# unreported.
# A failed mktemp leaves the variable EMPTY, and every path below is built
# on it — the fixtures would then be written to, and deleted from, the
# filesystem root (round-2 CR finding codex-3). Capture the failure here,
# where it is one line, rather than discovering it as a stray '/test-*.sh'.
sb21c=$(mktemp -d "${TMPDIR:-/tmp}/rst-case21c.XXXXXX")
if [ -z "$sb21c" ] || [ ! -d "$sb21c" ]; then
  fail "21c: mktemp -d produced no sandbox — refusing to build fixture paths on an empty root"
  exit 1
fi
gh21c="$sb21c/gh"
gh21c_log="$sb21c/gh.log"
mk_gh21 "$gh21c" "$gh21c_log"
rm -f "$gh21c_log"
n=1
while [ "$n" -le 5 ]; do
  cat > "$sb21c/test-127-$n.sh" <<'SHEOF'
#!/usr/bin/env bash
himmel_2517_no_such_command_anywhere
SHEOF
  chmod +x "$sb21c/test-127-$n.sh"
  n=$((n + 1))
done

out21c=$(GH_CMD="$gh21c" bash "$RUNNER" "$sb21c" --pr 2517 2>&1)
rc21c=$?

if [ "$rc21c" -eq 1 ] && ! grepq "$out21c" -F 'CONTAMINATED'; then
  pass "21c: five rc=127 failures — ratio met, floor missed — stay an ordinary red run (exit 1)"
else
  fail "21c: expected exit 1 with no CONTAMINATED, got $rc21c; output: $out21c"
fi
# Proves the control really produced the shape it claims: FIVE suites ran and
# every one of them exited 127, so the ratio half is genuinely satisfied and the
# floor is the only thing holding CONTAMINATED back. A control whose suites
# failed some other way, or which missed the ratio too, would pass this case
# while testing nothing about the floor.
if grepq "$out21c" -F ' FAIL: 5' && grepq "$out21c" -F ' PASS: 0' && grepq "$out21c" -F '(rc=127'; then
  pass "21c: the control really produced 5 rc=127 failures and nothing else"
else
  fail "21c: expected 5 failures, 0 passes, all at rc=127; output: $out21c"
fi
if grepq "$(cat "$gh21c_log" 2>/dev/null)" -F 'pr comment 2517'; then
  pass "21c: an ordinary red run still posts its after-report"
else
  fail "21c: expected a post to PR 2517; gh.log='$(cat "$gh21c_log" 2>/dev/null)'"
fi
rm -rf "$sb21c"

# --- 21d: CONTROL — as much red as 21b, but at rc=1 -------------------------
# Twelve failures, over the floor, none of them rc=127. This is what a genuine
# mass regression looks like, and it must still be reported and posted.
# A failed mktemp leaves the variable EMPTY, and every path below is built
# on it — the fixtures would then be written to, and deleted from, the
# filesystem root (round-2 CR finding codex-3). Capture the failure here,
# where it is one line, rather than discovering it as a stray '/test-*.sh'.
sb21d=$(mktemp -d "${TMPDIR:-/tmp}/rst-case21d.XXXXXX")
if [ -z "$sb21d" ] || [ ! -d "$sb21d" ]; then
  fail "21d: mktemp -d produced no sandbox — refusing to build fixture paths on an empty root"
  exit 1
fi
gh21d="$sb21d/gh"
gh21d_log="$sb21d/gh.log"
mk_gh21 "$gh21d" "$gh21d_log"
rm -f "$gh21d_log"
n=1
while [ "$n" -le 12 ]; do
  cat > "$sb21d/test-red-$n.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 1
SHEOF
  chmod +x "$sb21d/test-red-$n.sh"
  n=$((n + 1))
done

out21d=$(GH_CMD="$gh21d" bash "$RUNNER" "$sb21d" --pr 2517 2>&1)
rc21d=$?

if [ "$rc21d" -eq 1 ] && ! grepq "$out21d" -F 'CONTAMINATED'; then
  pass "21d: twelve ordinary rc=1 failures are not contamination (exit 1)"
else
  fail "21d: expected exit 1 with no CONTAMINATED, got $rc21d; output: $out21d"
fi
if grepq "$out21d" -F ' FAIL: 12'; then
  pass "21d: the control really produced 12 failures (over the floor)"
else
  fail "21d: expected ' FAIL: 12'; output: $out21d"
fi
if grepq "$(cat "$gh21d_log" 2>/dev/null)" -F 'pr comment 2517'; then
  pass "21d: a genuine mass regression still posts its after-report"
else
  fail "21d: expected a post to PR 2517; gh.log='$(cat "$gh21d_log" 2>/dev/null)'"
fi
rm -rf "$sb21d"

# --- 21e: the scan root is REPLACED, not merely removed ---------------------
# Round-1 CR finding codex-2: an existence test passes for a tree that was
# pruned and RECREATED at the same pathname — which is precisely what
# `git worktree add` does, and what merge-on-green's own gutted-tree recovery
# recipe tells an operator to run. The run would then publish, against the head
# it started with, a tally measured across two different checkouts. The guard
# pins the root's inode at start, so identity is what it re-checks.
# A failed mktemp leaves the variable EMPTY, and every path below is built
# on it — the fixtures would then be written to, and deleted from, the
# filesystem root (round-2 CR finding codex-3). Capture the failure here,
# where it is one line, rather than discovering it as a stray '/test-*.sh'.
sb21e=$(mktemp -d "${TMPDIR:-/tmp}/rst-case21e.XXXXXX")
if [ -z "$sb21e" ] || [ ! -d "$sb21e" ]; then
  fail "21e: mktemp -d produced no sandbox — refusing to build fixture paths on an empty root"
  exit 1
fi
gh21e="$sb21e.gh"
gh21e_log="$sb21e.gh.log"
mk_gh21 "$gh21e" "$gh21e_log"
rm -f "$gh21e_log"

# Same shape-pin discipline as 21a before any recursive delete.
cat > "$sb21e/test-01-swap.sh" <<SWAPEOF
#!/usr/bin/env bash
set -uo pipefail
target='$sb21e'
case "\$target" in
  */rst-case21e.??????) ;;
  *) echo "refusing to delete an unexpected path: \$target" >&2; exit 1 ;;
esac
cd / || exit 1
rm -rf "\$target"
mkdir -p "\$target" || exit 1
exit 0
SWAPEOF
cat > "$sb21e/test-02-victim.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
chmod +x "$sb21e/test-01-swap.sh" "$sb21e/test-02-victim.sh"

out21e=$(GH_CMD="$gh21e" bash "$RUNNER" "$sb21e" --pr 2517 2>&1)
rc21e=$?

if [ "$rc21e" -eq 3 ] && grepq "$out21e" -F 'ABORTED: scan root replaced'; then
  pass "21e: a same-path recreation aborts with exit 3 and says 'replaced', not 'vanished'"
else
  fail "21e: expected exit 3 with 'ABORTED: scan root replaced', got $rc21e; output: $out21e"
fi
if grepq "$out21e" -F '== Summary =='; then
  fail "21e: a Summary was rendered for a run whose tree was swapped; output: $out21e"
else
  pass "21e: no Summary block is rendered"
fi
if [ -s "$gh21e_log" ]; then
  fail "21e: the after-report was POSTED despite the swapped root; gh.log='$(cat "$gh21e_log" 2>/dev/null)'"
else
  pass "21e: --pr 2517 given, but nothing was posted"
fi
# The control's own precondition: a directory really is present at the path, so
# the abort above came from the IDENTITY check and not from the existence test
# 21a already covers. Without this the case would pass just as well if the swap
# suite had merely deleted the tree.
if [ -d "$sb21e" ]; then
  pass "21e: a directory really does exist at the path (the existence test would have passed)"
else
  fail "21e: the swap suite left no directory behind — this case degenerated into 21a and proves nothing"
fi
rm -rf "$sb21e"
rm -f "$gh21e" "$gh21e_log"

# --- 21f: CONTROL — a broad but PARTIAL rc=127 regression -------------------
# The case round-1 CR finding codex-1 named: delete a shared helper that a dozen
# suites call, and 12 of 12 FAILURES are rc=127 while the rest of the run is
# fine. Measured against failures that reads as contamination and the report is
# withheld from the PR — silencing a real, diff-caused regression, the exact
# loss HIMMEL-2383 exists to prevent. Measured against the whole run (12 of 42,
# 28%) it is what it is: an ordinary red run that must still be posted.
# A failed mktemp leaves the variable EMPTY, and every path below is built
# on it — the fixtures would then be written to, and deleted from, the
# filesystem root (round-2 CR finding codex-3). Capture the failure here,
# where it is one line, rather than discovering it as a stray '/test-*.sh'.
sb21f=$(mktemp -d "${TMPDIR:-/tmp}/rst-case21f.XXXXXX")
if [ -z "$sb21f" ] || [ ! -d "$sb21f" ]; then
  fail "21f: mktemp -d produced no sandbox — refusing to build fixture paths on an empty root"
  exit 1
fi
gh21f="$sb21f/gh"
gh21f_log="$sb21f/gh.log"
mk_gh21 "$gh21f" "$gh21f_log"
rm -f "$gh21f_log"
n=1
while [ "$n" -le 12 ]; do
  cat > "$sb21f/test-127-$n.sh" <<'SHEOF'
#!/usr/bin/env bash
himmel_2517_no_such_command_anywhere
SHEOF
  chmod +x "$sb21f/test-127-$n.sh"
  n=$((n + 1))
done
n=1
while [ "$n" -le 30 ]; do
  cat > "$sb21f/test-ok-$n.sh" <<'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
  chmod +x "$sb21f/test-ok-$n.sh"
  n=$((n + 1))
done

out21f=$(GH_CMD="$gh21f" bash "$RUNNER" "$sb21f" --pr 2517 2>&1)
rc21f=$?

if [ "$rc21f" -eq 1 ] && ! grepq "$out21f" -F 'CONTAMINATED'; then
  pass "21f: a broad-but-partial rc=127 regression stays an ordinary red run (exit 1)"
else
  fail "21f: expected exit 1 with no CONTAMINATED, got $rc21f; output: $out21f"
fi
# Proves the control produced the shape codex-1 described — 12 failures, ALL of
# them rc=127, i.e. 100% of the failure set. Over the old failure-based
# denominator this is exactly the input that fired.
if grepq "$out21f" -F ' FAIL: 12' && grepq "$out21f" -F ' PASS: 30'; then
  pass "21f: the control really produced 12 rc=127 failures alongside 30 passes"
else
  fail "21f: expected ' FAIL: 12' and ' PASS: 30'; output: $out21f"
fi
if grepq "$(cat "$gh21f_log" 2>/dev/null)" -F 'pr comment 2517'; then
  pass "21f: a real regression's after-report still reaches the PR"
else
  fail "21f: expected a post to PR 2517; gh.log='$(cat "$gh21f_log" 2>/dev/null)'"
fi
rm -rf "$sb21f"

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
