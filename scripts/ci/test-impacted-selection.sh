#!/usr/bin/env bash
# selector: tree-scan
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
#   IS11 a PR that only ADDS an unreferenced file selects the `# selector:
#        tree-scan` suite (HIMMEL-5114); an unmarked suite is not selected
#   IS12 a PR that deletes a file selects it
#   IS13 a PR that renames a file selects it
#   IS14 a PR that only modifies an existing file does not select it
#   IS15 lint: a suite that walks the real tree without the marker is flagged
#   IS18 an allowlisted suite's narrow-regex walk still fails; wide-only is exempt
#   IS19 a missing / unflagged / marked / reasonless allowlist entry fails
#   IS20 a lowercase or quote-split uninstall caller selects the callers suite
#   IS21 a template root file edit selects test-vault-git.sh (HIMMEL-5132)
#   IS22 a suite naming a changed script by its stem, without .sh, is selected
#        (HIMMEL-5160)
#   IS15b a planted unmarked tree-walking suite is flagged by the real walk list
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
printf '#!/usr/bin/env bash\n# selector: tree-scan\nexit 0\n' > "$SB/scripts/test-tree.sh"
printf '# doc\n' > "$SB/docs/note.md"
mkdir -p "$SB/templates/luna-second-brain/scripts"
printf '# tpl\n' > "$SB/templates/luna-second-brain/scripts/setup.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SB/templates/luna-second-brain/scripts/test-vault-git.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SB/scripts/test-uninstall-real-home-callers.sh"
printf '# hook\n' > "$SB/scripts/tools/guard-thing.sh"
printf '#!/usr/bin/env bash\nguard_rc guard-thing "x"\nexit 0\n' > "$SB/scripts/test-guard-stem.sh"
printf '# ignore\n' > "$SB/templates/luna-second-brain/.gitignore"
printf '# readme\n' > "$SB/templates/luna-second-brain/README.md"
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
# HIMMEL-5114: a diff that adds / deletes / renames a file no suite names.
g checkout -q -B added "$BASE"
printf '# new\n' > "$SB/scripts/tools/brand-new.sh"
g add -A; g commit -q -m "add an unreferenced file"
H_ADD=$(g rev-parse HEAD)
g checkout -q -B deleted "$BASE"
g rm -q "$SB/scripts/tools/foo.sh"
g commit -q -m "delete a file"
H_DEL=$(g rev-parse HEAD)
g checkout -q -B renamed "$BASE"
g mv "$SB/scripts/tools/foo.sh" "$SB/scripts/tools/foo2.sh"
g commit -q -m "rename a file"
H_REN=$(g rev-parse HEAD)
# HIMMEL-5122: a typechange (regular file -> symlink) and a template-script edit.
g checkout -q -B typed "$BASE"
rm -f "$SB/scripts/tools/foo.sh"
ln -s ../test-bar.sh "$SB/scripts/tools/foo.sh"
g commit -q -am "typechange a file"
H_TYP=$(g rev-parse HEAD)
g checkout -q -B tpl "$BASE"
printf '# edit\n' >> "$SB/templates/luna-second-brain/scripts/setup.sh"
g commit -q -am "edit a template script"
H_TPL=$(g rev-parse HEAD)
# HIMMEL-5132: uninstall callers the case-sensitive, quote-blind rule missed,
# and template root files test-vault-git.sh copies.
g checkout -q -B lcps "$BASE"
# The fence variable is assembled from parts so this file's own text never
# matches test-uninstall-real-home-callers.sh's scan (the suite does the same).
UN_A=HIMMEL; UN_B=_UNINSTALL_; UN_C=REAL_HOME
UN_LOWER=$(printf '%s%s%s' "$UN_A" "$UN_B" "$UN_C" | tr '[:upper:]' '[:lower:]')
# shellcheck disable=SC2016  # the planted text keeps a literal $env:
printf '$env:%s = 1\n' "$UN_LOWER" > "$SB/scripts/tools/caller.ps1"
g add -A; g commit -q -m "lowercase ps1 caller"
H_LCPS=$(g rev-parse HEAD)
g checkout -q -B qsplit "$BASE"
printf 'export %s""%s%s=1\n' "$UN_A" "$UN_B" "$UN_C" > "$SB/scripts/tools/split.sh"
g add -A; g commit -q -m "quote-split caller"
H_QSPLIT=$(g rev-parse HEAD)
g checkout -q -B contsplit "$BASE"
printf 'export %s%s\\\n%s=1\n' "$UN_A" "$UN_B" "$UN_C" > "$SB/scripts/tools/cont.sh"
g add -A; g commit -q -m "continuation-split caller"
H_CONT=$(g rev-parse HEAD)
H_STEM=$(branch stem scripts/tools/guard-thing.sh '# edit')
H_TPLGI=$(branch tplgi templates/luna-second-brain/.gitignore '# edit')
H_TPLRM=$(branch tplrm templates/luna-second-brain/README.md '# edit')
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

# --- IS11 -------------------------------------------------------------------
out=$(sel "$BASE" "$H_ADD"); rc=$?
if [ "$rc" -eq 0 ] && grepq "$out" -x 'mode impacted' \
   && grepq "$out" -x 'suite scripts/test-tree.sh' \
   && ! grepq "$out" -x 'suite scripts/test-bar.sh'; then
  pass "IS11: an added file selects the tree-scan suite, not an unmarked one"
else fail "IS11: rc=$rc out: $out"; fi

# --- IS12 -------------------------------------------------------------------
out=$(sel "$BASE" "$H_DEL"); rc=$?
if [ "$rc" -eq 0 ] && grepq "$out" -x 'suite scripts/test-tree.sh'; then
  pass "IS12: a deleted file selects the tree-scan suite"
else fail "IS12: rc=$rc out: $out"; fi

# --- IS13 -------------------------------------------------------------------
out=$(sel "$BASE" "$H_REN"); rc=$?
if [ "$rc" -eq 0 ] && grepq "$out" -x 'suite scripts/test-tree.sh'; then
  pass "IS13: a renamed file selects the tree-scan suite"
else fail "IS13: rc=$rc out: $out"; fi

# --- IS14 -------------------------------------------------------------------
out=$(sel "$BASE" "$H_CODE"); rc=$?
if [ "$rc" -eq 0 ] && grepq "$out" -x 'mode impacted' \
   && ! grepq "$out" -x 'suite scripts/test-tree.sh'; then
  pass "IS14: a content-only edit does not select the tree-scan suite"
else fail "IS14: rc=$rc out: $out"; fi

# --- IS16 -------------------------------------------------------------------
out=$(sel "$BASE" "$H_TYP"); rc=$?
if [ "$rc" -eq 0 ] && grepq "$out" -x 'suite scripts/test-tree.sh'; then
  pass "IS16: a typechange selects the tree-scan suite"
else fail "IS16: rc=$rc out: $out"; fi

# --- IS17 -------------------------------------------------------------------
out=$(sel "$BASE" "$H_TPL"); rc=$?
if [ "$rc" -eq 0 ] && grepq "$out" -x 'mode impacted' \
   && grepq "$out" -x 'suite templates/luna-second-brain/scripts/test-vault-git.sh' \
   && ! grepq "$out" -x 'suite scripts/test-bar.sh'; then
  pass "IS17: a template script edit selects test-vault-git.sh"
else fail "IS17: rc=$rc out: $out"; fi

# --- IS20 / IS21 ------------------------------------------------------------
for pair in "lowercase .ps1 caller:$H_LCPS" "quote-split name:$H_QSPLIT" "continuation-split name:$H_CONT"; do
  out=$(sel "$BASE" "${pair##*:}"); rc=$?
  if [ "$rc" -eq 0 ] && grepq "$out" -x 'suite scripts/test-uninstall-real-home-callers.sh'; then
    pass "IS20: a ${pair%%:*} selects the uninstall callers suite"
  else fail "IS20: ${pair%%:*}: rc=$rc out: $out"; fi
done
for pair in ".gitignore:$H_TPLGI" "README.md:$H_TPLRM"; do
  out=$(sel "$BASE" "${pair##*:}"); rc=$?
  if [ "$rc" -eq 0 ] && grepq "$out" -x 'suite templates/luna-second-brain/scripts/test-vault-git.sh'; then
    pass "IS21: a template ${pair%%:*} edit selects test-vault-git.sh"
  else fail "IS21: ${pair%%:*}: rc=$rc out: $out"; fi
done

# --- IS22 (HIMMEL-5160) -----------------------------------------------------
# A suite that names a changed script by its stem, without .sh, is selected.
out=$(sel "$BASE" "$H_STEM"); rc=$?
if [ "$rc" -eq 0 ] && grepq "$out" -x 'suite scripts/test-guard-stem.sh'; then
  pass "IS22: a suite naming a changed script without .sh is selected"
else fail "IS22: rc=$rc out: $out"; fi

# --- IS15 / IS18 / IS19 -----------------------------------------------------
# Lint: a suite that enumerates the REAL repo tree (git ls-files / ls-tree /
# find rooted at a repo or root variable) must carry the marker, or an added
# file it never names breaks it while the selector skips it. A tripwire, not a
# parser: it reads uncommented walk lines naming a *repo* / *root* variable or
# `repo,`.
#
# HIMMEL-5122: the widened regex also reaches suites that walk a FIXTURE root,
# so an allowlist table (`<suite>|<reason>`) exempts a suite -- but ONLY for hits
# the widened regex adds beyond main's narrow regex ($REPO / $REPO_ROOT /
# $SRC_ROOT). A narrow hit in an allowlisted suite still fails (IS18), and an
# entry that is missing, no longer flagged, marked, or reasonless fails (IS19),
# so the table cannot go stale or hide a walk main already caught.
IS15_NARROW='\$\{?(REPO|REPO_ROOT|SRC_ROOT)\}?|, *repo\b'
IS15_WIDE='\$\{?[A-Za-z_]*(repo|root)[A-Za-z_0-9]*\}?|, *repo\b'

# is15_walks <file> <grep -E flag> <regex>: the uncommented walk lines it hits.
is15_walks() {
  grep -vE '^[[:space:]]*#' "$1" \
    | grep -E '(ls-files|ls-tree|find )' \
    | grep -vE 'ls-files -s|--error-unmatch' \
    | grep "$2" "$3" || true
}

# is15_scan <root> <allow-table>; suite paths on stdin; prints the offenders.
is15_scan() {
  local root=$1 allow=$2 ts out=""
  while IFS= read -r ts; do
    [ -n "$ts" ] || continue
    if [ ! -r "$root/$ts" ]; then out="$out $ts(unreadable)"; continue; fi
    grep -qx '# selector: tree-scan' "$root/$ts" && continue
    # A hit main's narrow regex already caught is never exempt.
    if [ -n "$(is15_walks "$root/$ts" -E "$IS15_NARROW")" ]; then out="$out $ts"; continue; fi
    [ -n "$(is15_walks "$root/$ts" -iE "$IS15_WIDE")" ] || continue
    case " $(printf '%s\n' "$allow" | cut -d'|' -f1 | tr '\n' ' ') " in
      *" $ts "*) continue ;;
    esac
    out="$out $ts"
  done
  # Every allowlist entry must exist, be unmarked, still be flagged by the
  # widened regex, and carry its own reason.
  local p reason
  while IFS='|' read -r p reason; do
    [ -n "$p" ] || continue
    if [ ! -r "$root/$p" ]; then out="$out $p(stale:missing)"; continue; fi
    if grep -qx '# selector: tree-scan' "$root/$p"; then out="$out $p(stale:marked)"; continue; fi
    if [ -z "$reason" ]; then out="$out $p(no-reason)"; continue; fi
    if [ -z "$(is15_walks "$root/$p" -iE "$IS15_WIDE")" ]; then out="$out $p(stale:not-flagged)"; fi
  done <<< "$allow"
  printf '%s' "$out"
}

# real tree, left unmarked on purpose, one reason per entry.
IS15_ALLOW='scripts/test-adopt.sh|real tree, cost-excluded (HIMMEL-5123 follow-up if a selector-miss row names it)
scripts/himmelctl/test/test-versioned-layout.sh|real tree, cost-excluded (HIMMEL-5123 follow-up if a selector-miss row names it)
scripts/hooks/test-gitattributes-no-driver.sh|real tree, selected by the changed-suite name match, runs 0.01 s (not cost-excluded)
scripts/test-uninstall-real-home-callers.sh|real tree, selected by the content_rules ERE in impacted-suites.sh (case- and quote/continuation-split tolerant, HIMMEL-5132)
scripts/cr/test-pr-check-run.sh|real tree, selected by the scripts/*.sh scan_roots row
scripts/test-check-plugin-drift.sh|real tree, selected by the *package.json scan_roots row
scripts/cr/test-pr-check-rounds.sh|fixture root, not the repo tree
scripts/handover/console-kit/test-go.sh|fixture root, not the repo tree
scripts/handover/console/test-console.sh|fixture root, not the repo tree
scripts/handover/test-breadcrumb.sh|fixture root, not the repo tree
scripts/handover/test-queue-lock.sh|fixture root, not the repo tree
scripts/lanes/bench/scorecard/test-agg-burn.sh|fixture root, not the repo tree
scripts/luna/test-graphmap-cadence.sh|fixture root, not the repo tree
scripts/luna/test-qmd-cadence.sh|fixture root, not the repo tree
scripts/release/test-tarball-vs-clone.sh|fixture root, not the repo tree
scripts/test-tmp-reap.sh|fixture root, not the repo tree
scripts/test-uninstall.sh|fixture root, not the repo tree'

# is15_suites <root>: the real walk list (every tracked suite under these trees).
is15_suites() {
  git -C "$1" ls-files -- 'scripts/**/test-*.sh' 'scripts/test-*.sh' \
    'templates/**/test-*.sh' 'marketplace/**/test-*.sh'
}

unmarked=""
if ! suite_list=$(is15_suites "$SRC_ROOT") || [ -z "$suite_list" ]; then
  unmarked=" (git ls-files failed or listed no suites)"
  suite_list=""
fi
unmarked="$unmarked$(is15_scan "$SRC_ROOT" "$IS15_ALLOW" <<< "$suite_list")"
if [ -z "$unmarked" ]; then
  pass "IS15: every suite that walks the real tree carries '# selector: tree-scan'"
else fail "IS15: tree-walking suite(s) without the marker:$unmarked"; fi

# Sandbox rows: the scan itself, on planted suites.
S15="$(fixture_mktemp_dir)" || exit 1
mkdir -p "$S15/scripts"
# shellcheck disable=SC2016  # the planted lines must keep a literal $REPO / $root
printf '%s\n' '#!/usr/bin/env bash' 'git -C "$REPO" ls-files' > "$S15/scripts/test-narrow.sh"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' 'find "$root" -name x' > "$S15/scripts/test-wide.sh"
printf '%s\n' '#!/usr/bin/env bash' 'echo nothing' > "$S15/scripts/test-quiet.sh"

o=$(is15_scan "$S15" 'scripts/test-narrow.sh|planted' <<< 'scripts/test-narrow.sh')
case "$o" in
  *scripts/test-narrow.sh*) pass "IS18: a narrow-regex walk in an allowlisted suite still fails" ;;
  *) fail "IS18: allowlist hid a walk main's narrow regex catches: [$o]" ;;
esac

o=$(is15_scan "$S15" 'scripts/test-wide.sh|fixture root' <<< 'scripts/test-wide.sh')
if [ -z "$o" ]; then pass "IS18: a wide-only walk in an allowlisted suite is exempt"
else fail "IS18: wide-only allowlisted walk flagged: [$o]"; fi

o=$(is15_scan "$S15" 'scripts/test-gone.sh|stale
scripts/test-quiet.sh|no longer flagged
scripts/test-wide.sh|' <<< 'scripts/test-wide.sh')
case "$o" in
  *scripts/test-gone.sh*scripts/test-quiet.sh*scripts/test-wide.sh*)
    pass "IS19: a missing, unflagged or reasonless allowlist entry fails" ;;
  *) fail "IS19: stale allowlist entries not all caught: [$o]" ;;
esac
# IS19: a MARKED entry is stale (M8 from j2279b: the stale:marked check dropped).
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' '# selector: tree-scan' 'find "$root" -name x' > "$S15/scripts/test-marked.sh"
o=$(is15_scan "$S15" 'scripts/test-marked.sh|marked but allowlisted' <<< 'scripts/test-marked.sh')
case "$o" in
  *'scripts/test-marked.sh(stale:marked)'*) pass "IS19: a marked allowlist entry is stale" ;;
  *) fail "IS19: marked allowlist entry not caught: [$o]" ;;
esac
rm -rf "$S15"

# IS15b: the real walk list flags a planted unmarked suite end to end.
P15="$(fixture_mktemp_dir)" || exit 1
# shellcheck disable=SC2016  # the planted lines keep a literal $REPO
(
  cd "$P15" && git init -q && git config user.email t@e && git config user.name t \
    && mkdir -p scripts \
    && printf '%s\n' '#!/usr/bin/env bash' 'git -C "$REPO" ls-files' > scripts/test-planted.sh \
    && printf '%s\n' '#!/usr/bin/env bash' '# selector: tree-scan' 'git -C "$REPO" ls-files' > scripts/test-planted-marked.sh \
    && git add -A && git commit -q -m planted
) || exit 1
o=$(is15_scan "$P15" '' <<< "$(is15_suites "$P15")")
case "$o" in
  *scripts/test-planted.sh*) pass "IS15b: a planted unmarked tree-walking suite is flagged" ;;
  *) fail "IS15b: planted suite not flagged: [$o]" ;;
esac
case "$o" in
  *test-planted-marked.sh*) fail "IS15b: a marked planted suite was flagged: [$o]" ;;
  *) pass "IS15b: a marked planted suite is not flagged" ;;
esac
rm -rf "$P15"

rst_tally
