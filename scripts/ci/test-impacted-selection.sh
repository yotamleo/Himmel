#!/usr/bin/env bash
# scripts/ci/test-impacted-selection.sh — scripts/ci/impacted-selection.sh
# (HIMMEL-3897): the BASE-sourced full-vs-impacted verdict every PR shell-unit
# shard and the aggregator print as their manifest header.
#
# Each case runs a COPY of the script inside a throwaway git repo whose
# refs/remotes/origin/main plays the default branch:
#
#   IS1  a PR touching a trust path          -> mode full, reason trust-path
#   IS2  a PR touching a plain script        -> mode impacted, its suite selected
#   IS3  a docs-only PR                      -> mode impacted, NO suite line
#   IS4  a base that predates the selector   -> mode full (base-predates-selector)
#   IS5  a base not on origin/main (H1)      -> mode full (base-off-default)
#   IS6  no base (push / schedule / non-main) -> mode full (no-base)
#   IS7  the selector line is the BASE blob of impacted-suites.sh
#   IS8  the selector runs from the BASE: a head that guts impacted-suites.sh
#        (outside this fixture's trust list) still gets the base's selection
#   IS9  an unresolvable head is rc 2, never a verdict
#
# Platform guard: bash-only, no .ps1 twin; git + tar, Linux CI is the caller.
#
# Usage: bash scripts/ci/test-impacted-selection.sh
# Exit codes: 0 — all cases passed; 1 — at least one failed.
set -uo pipefail

# shellcheck source=run-shell-tests-fixture.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/run-shell-tests-fixture.sh"
# shellcheck source=../lib/fixture-tempdir.sh
# shellcheck disable=SC1091
. "$RST_FIXTURE_DIR/../lib/fixture-tempdir.sh"

SRC_ROOT="$(cd "$RST_FIXTURE_DIR/../.." && pwd)"
SEL_SRC="$SRC_ROOT/scripts/ci/impacted-selection.sh"
if [ ! -f "$SEL_SRC" ]; then
  fail "impacted-selection.sh not found at $SEL_SRC"
  rst_tally
fi

SB="$(fixture_mktemp_dir)" || exit 1
trap 'rm -rf "$SB" "$SUITE_LOCK_SANDBOX"' EXIT
(
  fixture_enter_git_init_dir "$SB" || exit 1
  git init -q
  git config user.email t@e
  git config user.name t
) || exit 1
g() { git -C "$SB" "$@"; }

mkdir -p "$SB/scripts/ci" "$SB/scripts/cr" "$SB/scripts/tools" "$SB/docs"
# Commit P: the repo BEFORE the selector existed (IS4's base).
printf '# tool\n' > "$SB/scripts/tools/foo.sh"
printf '#!/usr/bin/env bash\n# drives tools/foo.sh\nexit 0\n' > "$SB/scripts/test-foo.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SB/scripts/test-bar.sh"
printf '# doc\n' > "$SB/docs/note.md"
g add -A; g commit -q -m "chore: pre-selector"
PRE=$(g rev-parse HEAD)

# Commit B: the selector lands. The trust list is deliberately narrow so IS8
# can change the selector WITHOUT tripping it.
cp "$SEL_SRC" "$SB/scripts/ci/impacted-selection.sh"
cp "$SRC_ROOT/scripts/cr/impacted-suites.sh" "$SB/scripts/cr/impacted-suites.sh"
cp "$SRC_ROOT/scripts/cr/anchor-handoff.sh" "$SB/scripts/cr/anchor-handoff.sh"
printf '# fixture trust list\n\n^scripts/ci/\n' > "$SB/scripts/ci/ci-trust-paths.txt"
g add -A; g commit -q -m "chore: selector"
BASE=$(g rev-parse HEAD)
g update-ref refs/remotes/origin/main "$BASE"
SEL="$SB/scripts/ci/impacted-selection.sh"

# branch <name> <file> <line> — one commit on a branch off BASE; prints its sha.
branch() {
  g checkout -q -B "$1" "$BASE"
  printf '%s\n' "$3" >> "$SB/$2"
  g commit -q -am "change $2"
  g rev-parse HEAD
}
H_TRUST=$(branch trust scripts/ci/ci-trust-paths.txt '# edit')
H_CODE=$(branch code scripts/tools/foo.sh '# edit')
H_DOCS=$(branch docs docs/note.md '# edit')
g checkout -q -B gut "$BASE"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SB/scripts/cr/impacted-suites.sh"
printf '# edit\n' >> "$SB/scripts/tools/foo.sh"
g commit -q -am "gut the selector"
H_GUT=$(g rev-parse HEAD)
# OFF: a branch that is NOT on origin/main, used as a PR base (H1).
OFF=$(branch off docs/note.md '# unmerged')
g checkout -q -B onoff "$OFF"
printf '# edit\n' >> "$SB/scripts/tools/foo.sh"
g commit -q -am "code on off"
H_ONOFF=$(g rev-parse HEAD)
g checkout -q "$BASE" 2>/dev/null

sel() { (cd "$SB" && bash "$SEL" "$@" 2>&1); }

# --- IS1 --------------------------------------------------------------------
out=$(sel "$BASE" "$H_TRUST"); rc=$?
if [ "$rc" -eq 0 ] && grepq "$out" -x 'mode full' \
   && grepq "$out" -x 'reason trust-path: scripts/ci/ci-trust-paths.txt' \
   && ! grepq "$out" '^suite '; then
  pass "IS1: a trust-path PR gets the FULL sweep"
else fail "IS1: rc=$rc out: $out"; fi

# --- IS2 --------------------------------------------------------------------
out=$(sel "$BASE" "$H_CODE"); rc=$?
if [ "$rc" -eq 0 ] && grepq "$out" -x 'mode impacted' \
   && grepq "$out" -x 'suite scripts/test-foo.sh' \
   && ! grepq "$out" -x 'suite scripts/test-bar.sh' \
   && grepq "$out" -x 'changed scripts/tools/foo.sh' \
   && grepq "$out" -x "base $BASE" && grepq "$out" -x "head $H_CODE"; then
  pass "IS2: a plain-script PR is impacted and selects only its suite"
else fail "IS2: rc=$rc out: $out"; fi

# --- IS3 --------------------------------------------------------------------
out=$(sel "$BASE" "$H_DOCS"); rc=$?
if [ "$rc" -eq 0 ] && grepq "$out" -x 'mode impacted' && ! grepq "$out" '^suite '; then
  pass "IS3: a docs-only PR is impacted with an empty selection"
else fail "IS3: rc=$rc out: $out"; fi

# --- IS4 --------------------------------------------------------------------
out=$(sel "$PRE" "$H_CODE"); rc=$?
if [ "$rc" -eq 0 ] && grepq "$out" -x 'mode full' && grepq "$out" -x 'reason base-predates-selector'; then
  pass "IS4: a base without the selector -> full"
else fail "IS4: rc=$rc out: $out"; fi

# --- IS5 --------------------------------------------------------------------
out=$(sel "$OFF" "$H_ONOFF"); rc=$?
if [ "$rc" -eq 0 ] && grepq "$out" -x 'mode full' && grepq "$out" '^reason base-off-default: '; then
  pass "IS5: a base that is not on origin/main -> full (H1)"
else fail "IS5: rc=$rc out: $out"; fi

# --- IS6 --------------------------------------------------------------------
out=$(sel '' "$H_CODE"); rc=$?
if [ "$rc" -eq 0 ] && grepq "$out" -x 'mode full' && grepq "$out" '^reason no-base' \
   && grepq "$out" -x 'base -'; then
  pass "IS6: no base -> full"
else fail "IS6: rc=$rc out: $out"; fi

# --- IS7 --------------------------------------------------------------------
blob=$(g rev-parse "$BASE:scripts/cr/impacted-suites.sh")
out=$(sel "$BASE" "$H_CODE")
if grepq "$out" -x "selector $blob"; then
  pass "IS7: the selector line is the base blob of impacted-suites.sh"
else fail "IS7: want selector $blob, out: $out"; fi

# --- IS8 --------------------------------------------------------------------
out=$(sel "$BASE" "$H_GUT"); rc=$?
if [ "$rc" -eq 0 ] && grepq "$out" -x 'mode impacted' && grepq "$out" -x 'suite scripts/test-foo.sh'; then
  pass "IS8: a gutted head selector is ignored; the BASE copy selects"
else fail "IS8: rc=$rc out: $out"; fi

# --- IS9 --------------------------------------------------------------------
out=$(sel "$BASE" nope-not-a-ref); rc=$?
if [ "$rc" -eq 2 ] && ! grepq "$out" '^mode '; then
  pass "IS9: an unresolvable head is rc 2 with no verdict"
else fail "IS9: rc=$rc out: $out"; fi

# --- IS10 -------------------------------------------------------------------
# HIMMEL-4997: git C-quotes a name holding a double quote, backslash or tab, so
# the anchored trust match missed it and the PR stayed on the impacted path.
n=0
for name in 'scripts/ci/we"ird.sh' 'scripts/ci/back\slash.sh' $'scripts/ci/ta\tb.sh'; do
  n=$((n + 1))
  g checkout -q -B "quoted$n" "$BASE"
  printf '# x\n' > "$SB/$name"
  g add -A; g commit -q -m "quoted trust name $n"
  hq=$(g rev-parse HEAD)
  out=$(sel "$BASE" "$hq"); rc=$?
  if [ "$rc" -eq 0 ] && grepq "$out" -x 'mode full' && grepq "$out" '^reason trust-path: scripts/ci/'; then
    pass "IS10.$n: a trust-path name git would C-quote still forces the FULL sweep"
  else fail "IS10.$n: rc=$rc out: $out"; fi
done
g checkout -q "$BASE" 2>/dev/null

rst_tally
