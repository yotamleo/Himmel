#!/usr/bin/env bash
# scripts/ci/test-run-shell-tests-discovery.sh — the run-shell-tests.sh cases
# about the SCAN ROOT and the environment the run measured, rather than about
# the suites themselves (HIMMEL-2895, split out of test-run-shell-tests.sh).
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
#       collision check for SUITE_REQUIRE_TOOL; Case 12c (in
#       test-run-shell-tests.sh) covers SUITE_CONDITIONAL. 18k/18l target the
#       sibling HIMMEL-2508 discovery bug on that same symlinked root:
#       pre-fix, `find` never descends into a symlinked scan root at all, so
#       discovery returns EMPTY and the runner exits 1 before 18h's verdict
#       comparison is ever reached; 18k asserts the suites under the link
#       actually EXECUTED, 18l asserts --list plans them identically through
#       the link path as through the physical root. 18m is a no-regression
#       PIN rather than a red-first case: it proves the fix's `-H`
#       (dereference the scan-root ARGUMENT only) never widened into `-L`
#       (follow every symlink `find` walks past), by planting a symlink one
#       level below a physical, non-linked scan root and asserting the suite
#       behind it is NOT discovered, alongside a real sibling suite that IS.
#       18m-R (HIMMEL-2544) is that pin's RED control: it runs the same
#       fixture against a scratch `-L` mutant of the runner through the
#       RED-control contract, so the `-H` vs `-L` distinction 18m claims is
#       EXECUTED, not just asserted in prose.
#   21. A run that measured its own ENVIRONMENT, not the tests (HIMMEL-2517):
#       a scan root deleted or replaced mid-run aborts, and a run whose
#       failures are overwhelmingly rc=127 reports CONTAMINATED rather than
#       posting a fabricated tally.
#
# These two are cheap (~4s together); they are their own file for SIZE, not
# for speed — they were 941 lines of the pre-split file. The rest of the
# family is test-run-shell-tests.sh (the core cases), -timing.sh (16, 20) and
# the three -rotation*.sh suites; shared fixtures are in
# run-shell-tests-fixture.sh.
#
# Platform guard: bash-only, like every suite in this family, and no .ps1
# twin — it runs under Git Bash on Windows as well as Linux.
#
# Usage: bash scripts/ci/test-run-shell-tests-discovery.sh
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


rst_tally
