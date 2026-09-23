#!/usr/bin/env bash
# shellcheck disable=SC2016  # fixture suite bodies are single-quoted on purpose: their $vars must stay literal
# scripts/ci/test-run-shell-tests-impacted.sh — the run-shell-tests.sh
# --impacted <base>..<head> cases (HIMMEL-2821): the one-shot runner for the
# list scripts/cr/impacted-suites.sh prints.
#
# The runner cds to its own checkout and shells out to THAT checkout's
# impacted-suites.sh, so each case runs a COPY of the runner inside a throwaway
# git repo shaped like PR #2261: uninstall-plugins.sh changed, and the suite
# that drives it (test-uninstall.sh) is one directory away from it.
#
#   24a  the impacted suite RUNS, the unrelated one is [SKIP]ped "impacted:"
#   24b  a suite outside the scan root is NOTEd, not silently dropped
#   24c  an impacted suite that FAILS makes the run rc 1 (no swallowed verdict)
#   24d  a range that does not resolve is REFUSED rc 2 and runs nothing —
#        never read as "nothing impacted"
#   24e  a docs-only range is a clean rc 0 that says "0 impacted", runs nothing
#   24f  --list plans only the impacted suite and runs nothing
#   24g  --impacted with no value is REFUSED rc 2
#
# Platform guard: bash-only, like every suite in this family, and no .ps1
# twin — it runs under Git Bash on Windows as well as Linux.
#
# Usage: bash scripts/ci/test-run-shell-tests-impacted.sh
#
# Exit codes: 0 — all cases passed; 1 — at least one failed.
set -uo pipefail

# shellcheck source=run-shell-tests-fixture.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/run-shell-tests-fixture.sh"
# shellcheck source=../lib/fixture-tempdir.sh
# shellcheck disable=SC1091
. "$RST_FIXTURE_DIR/../lib/fixture-tempdir.sh"

SRC_ROOT="$(cd "$RST_FIXTURE_DIR/../.." && pwd)"
IS_SRC="$SRC_ROOT/scripts/cr/impacted-suites.sh"
if [ ! -f "$IS_SRC" ]; then
  fail "impacted-suites.sh not found at $IS_SRC"
  rst_tally
fi

SB="$(fixture_mktemp_dir)" || exit 1
trap 'rm -rf "$SB" "$SUITE_LOCK_SANDBOX"' EXIT

# --- sandbox repo ---------------------------------------------------------
# The helper requires an EMPTY directory, so the repo is initialised first.
(
  fixture_enter_git_init_dir "$SB" || exit 1
  git init -q
  git config user.email t@e
  git config user.name t
) || exit 1
# The runner's own sourced libraries come along; nothing else of himmel does.
mkdir -p "$SB/scripts/ci" "$SB/scripts/lib" "$SB/scripts/cr" \
         "$SB/scripts/machine-setup" "$SB/tests" "$SB/docs"
cp "$RUNNER" "$SB/scripts/ci/run-shell-tests.sh"
cp "$IS_SRC" "$SB/scripts/cr/impacted-suites.sh"
# impacted-suites.sh sources its anchor hand-off first (HIMMEL-3495).
cp "$SRC_ROOT/scripts/cr/anchor-handoff.sh" "$SB/scripts/cr/anchor-handoff.sh"
for lib in proc-tree.sh git-test-env.sh override-env.sh runtime-preflight.sh; do
  cp "$SRC_ROOT/scripts/lib/$lib" "$SB/scripts/lib/$lib"
done

IMP_LOG="$SB/ran.log"
export IMP_LOG
# A suite appends its own name, then exits with $IMP_FAIL when it is the one
# being failed. The names are what the cases read back.
mksuite() {
  printf '#!/usr/bin/env bash\n%s\necho %s >> "$IMP_LOG"\n%s\n' "${3:-:}" "$2" "${4:-exit 0}" > "$SB/$1"
}
printf '# uninstall-plugins\n' > "$SB/scripts/machine-setup/uninstall-plugins.sh"
mksuite scripts/test-uninstall.sh uninstall '# drives machine-setup/uninstall-plugins.sh' \
  '[ "${IMP_FAIL:-0}" = 1 ] && exit 1; exit 0'
mksuite scripts/test-unrelated.sh unrelated '# drives nothing that changed'
mksuite tests/test-outside.sh outside '# also drives uninstall-plugins.sh'
printf '# doc\n' > "$SB/docs/note.md"
git -C "$SB" add -A
git -C "$SB" commit -q -m "chore: base"
BASE=$(git -C "$SB" rev-parse HEAD)
printf '# changed\n' >> "$SB/scripts/machine-setup/uninstall-plugins.sh"
git -C "$SB" commit -q -am "fix: uninstall-plugins"
CODE_RANGE="$BASE..$(git -C "$SB" rev-parse HEAD)"
printf '# changed\n' >> "$SB/docs/note.md"
git -C "$SB" commit -q -am "docs: note"
DOCS_RANGE="$(git -C "$SB" rev-parse HEAD~1)..$(git -C "$SB" rev-parse HEAD)"

IMPRUN="$SB/scripts/ci/run-shell-tests.sh"
: > "$IMP_LOG"

# --- 24a. the far-away suite runs; the unrelated one is skipped ------------
out=$(bash "$IMPRUN" --impacted "$CODE_RANGE" 2>&1); rc=$?
ran=$(cat "$IMP_LOG")
if [ "$rc" -eq 0 ] && [ "$ran" = "uninstall" ]; then
  pass "24a: --impacted runs test-uninstall.sh and nothing else (rc 0)"
else
  fail "24a: rc=$rc ran='$ran' output: $out"
fi
if grepq "$out" '\[SKIP\].*test-unrelated\.sh.*impacted:'; then
  pass "24a: the unrelated suite is [SKIP]ped with an 'impacted:' reason"
else
  fail "24a: no impacted-skip line for test-unrelated.sh: $out"
fi

# --- 24b. a suite outside the scan root is named, not dropped --------------
if grepq "$out" 'NOTE: impacted suite tests/test-outside\.sh is outside scan root'; then
  pass "24b: an impacted suite outside the scan root is NOTEd"
else
  fail "24b: no outside-scan-root NOTE: $out"
fi

# --- 24c. an impacted suite that fails fails the run ------------------------
: > "$IMP_LOG"
out=$(IMP_FAIL=1 bash "$IMPRUN" --impacted "$CODE_RANGE" 2>&1); rc=$?
ran=$(cat "$IMP_LOG")
if [ "$rc" -eq 1 ] && [ "$ran" = "uninstall" ]; then
  pass "24c: a failing impacted suite RAN and fails the run -> rc 1"
else
  fail "24c: rc=$rc ran='$ran' output: $out"
fi

# --- 24d. an unresolvable range is refused, never "nothing impacted" --------
: > "$IMP_LOG"
out=$(bash "$IMPRUN" --impacted nope..alsonope 2>&1); rc=$?
ran=$(cat "$IMP_LOG")
if [ "$rc" -eq 2 ] && [ -z "$ran" ]; then
  pass "24d: unresolvable range -> rc 2, no suite ran"
else
  fail "24d: rc=$rc ran='$ran' output: $out"
fi

# --- 24e. docs-only range: a clean, stated zero ----------------------------
out=$(bash "$IMPRUN" --impacted "$DOCS_RANGE" 2>&1); rc=$?
ran=$(cat "$IMP_LOG")
if [ "$rc" -eq 0 ] && [ -z "$ran" ] && grepq "$out" '0 impacted shell suites'; then
  pass "24e: docs-only range -> rc 0, '0 impacted', nothing ran"
else
  fail "24e: rc=$rc ran='$ran' output: $out"
fi

# --- 24f. --list plans only the impacted suite, runs nothing ----------------
out=$(bash "$IMPRUN" --list --impacted "$CODE_RANGE" 2>&1); rc=$?
ran=$(cat "$IMP_LOG")
if [ "$rc" -eq 0 ] && [ -z "$ran" ] && grepq "$out" 'test-uninstall\.sh' \
   && grepq "$out" '\[SKIP\].*test-unrelated\.sh'; then
  pass "24f: --list --impacted plans the impacted suite and runs nothing"
else
  fail "24f: rc=$rc ran='$ran' output: $out"
fi

# --- 24g. a missing value is refused ---------------------------------------
out=$(bash "$IMPRUN" --impacted 2>&1); rc=$?
if [ "$rc" -eq 2 ]; then pass "24g: --impacted with no value -> rc 2"; else fail "24g: rc=$rc output: $out"; fi

rst_tally
