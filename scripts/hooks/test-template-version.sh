#!/usr/bin/env bash
# Smoke test for scripts/hooks/check-template-version.sh (HIMMEL-524).
#
# Builds throwaway git repos, exercises each rc case, asserts exact rc.
# Usage: bash scripts/hooks/test-template-version.sh
#
# Exit 0 if all cases pass, 1 otherwise.
#
# shellcheck disable=SC2034  # SCRIPT/ORIGIN/R/MP used inside eval'd test bodies
# shellcheck disable=SC2016  # single-quoted test body strings intentionally contain $
# shellcheck disable=SC2317  # fixture fns called indirectly via eval inside run_test
# shellcheck disable=SC2329  # same as SC2317 (alias in newer shellcheck versions)
set -uo pipefail

# ---------------------------------------------------------------------------
# Shared fixture helpers
# ---------------------------------------------------------------------------

HOOKS="$(cd "$(dirname "$0")" && pwd)"
# Run the script IN PLACE from the real tree (mirrors test-doc-guard.sh): it
# resolves guardrails/lib.sh via its own SCRIPT_DIR; only the GIT REPO is a
# tempdir, so `cd "$R"` is all that's needed.
SCRIPT="$HOOKS/check-template-version.sh"
MP="templates/luna-second-brain/marketplace/.claude-plugin/marketplace.json"
# upgrade.sh's classify() is the single source of truth owned_class() copies
# its case arms from verbatim (see check-template-version.sh header) — run
# from the real repo tree (not a fixture repo), same as SCRIPT.
UPGRADE_SH="$HOOKS/../../templates/luna-second-brain/scripts/upgrade.sh"

# shellcheck source=../lib/fixture-tempdir.sh
# shellcheck disable=SC1091
. "$HOOKS/../lib/fixture-tempdir.sh"

# mk_market <path> <version> — write a minimal valid marketplace.json.
mk_market() { mkdir -p "$(dirname "$1")"; printf '{"name":"luna-brain","metadata":{"version":"%s"},"plugins":[]}\n' "$2" > "$1"; }

# extract_case_arms <file> <fn> — print just the `pattern) body ;;` lines of
# a shell function's `case "$1" in ... esac` block (trimmed, comment/wrapper
# lines excluded), so a diff between two copies ignores cosmetic reflow.
extract_case_arms() {
  awk -v fn="$2" '
    $0 == fn"() {" { infn=1 }
    infn && /^}/ { exit }
    infn && /esac/ { exit }
    infn && index($0, "case \"$1\" in") { incase=1; next }
    infn && incase && $0 !~ /^[[:space:]]*#/ && $0 !~ /^[[:space:]]*$/ { print }
  ' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# setup_repo: temp git repo WITH the .himmel-dev marker. Explicit mktemp
# template (not a bare `mktemp -d`): BSD mktemp on macOS requires one for -d.
setup_repo() {
  R=$(fixture_mktemp_dir) || return 1; git -C "$R" init -q
  git -C "$R" config user.email t@t; git -C "$R" config user.name t
  : > "$R/.himmel-dev"
}
setup_repo_no_marker() { setup_repo || return 1; rm -f "$R/.himmel-dev"; }

# setup_repo_with_origin: seeds marketplace.json on main + a bare origin for
# pre-push base resolution (mirrors test-doc-guard.sh's setup_repo_with_origin).
setup_repo_with_origin() {
  setup_repo || return 1
  mk_market "$R/$MP" 0.1.0
  git -C "$R" add "$MP"; git -C "$R" commit -qm "seed market"
  ORIGIN=$(fixture_mktemp_dir) || return 1; git -C "$ORIGIN" init -q --bare
  git -C "$R" remote add origin "$ORIGIN"
  git -C "$R" branch -M main
  git -C "$R" push -q origin main
}

expect_rc() { local want=$1; shift; local rc=0; "$@" || rc=$?; [ "$rc" -eq "$want" ]; }

# ---------------------------------------------------------------------------
# run_test harness (modeled on test-doc-guard.sh pass/fail accounting)
# ---------------------------------------------------------------------------

_failures=0

run_test() {
  local name="$1" body="$2"
  local rc=0 errfile
  errfile=$(mktemp)
  # Run each test body in a subshell so cd/R don't leak between cases.
  ( eval "$body" ) 2>"$errfile" || rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '  PASS  %s\n' "$name"
  else
    printf '  FAIL  %s (subshell rc=%s)\n' "$name" "$rc"
    sed 's/^/        /' "$errfile"
    _failures=$((_failures + 1))
  fi
  rm -f "$errfile"
}

# ---------------------------------------------------------------------------
# Test cases — assert EXACT rc with expect_rc.
# ---------------------------------------------------------------------------

# Required contract: template file + no bump -> fail.
run_test "blocks owned content (docs/) without bump (rc=1)" '
  setup_repo && cd "$R" || exit 1; mk_market "$MP" 0.1.0; git add "$MP"; git commit -qm seed;
  mkdir -p templates/luna-second-brain/docs; : > templates/luna-second-brain/docs/foo.md;
  git add templates/luna-second-brain/docs/foo.md;
  expect_rc 1 bash "$SCRIPT"
'

# Required contract: template file + bump -> pass.
run_test "passes owned content WITH version bump (rc=0)" '
  setup_repo && cd "$R" || exit 1; mk_market "$MP" 0.1.0; git add "$MP"; git commit -qm seed;
  mkdir -p templates/luna-second-brain/docs; : > templates/luna-second-brain/docs/foo.md;
  mk_market "$MP" 0.2.0; git add templates/luna-second-brain/docs/foo.md "$MP";
  expect_rc 0 bash "$SCRIPT"
'

# Required contract: skip-class file alone -> pass (skipexists plugin asset, HIMMEL-525).
run_test "skipexists plugin asset alone passes (rc=0)" '
  setup_repo && cd "$R" || exit 1; mk_market "$MP" 0.1.0; git add "$MP"; git commit -qm seed;
  mkdir -p templates/luna-second-brain/.obsidian/plugins/foo;
  : > templates/luna-second-brain/.obsidian/plugins/foo/main.js;
  git add templates/luna-second-brain/.obsidian/plugins/foo/main.js;
  expect_rc 0 bash "$SCRIPT"
'

# Required contract: skip-class catch-all (user content) alone -> pass.
run_test "user-content (skip catch-all) alone passes (rc=0)" '
  setup_repo && cd "$R" || exit 1; mk_market "$MP" 0.1.0; git add "$MP"; git commit -qm seed;
  : > templates/luna-second-brain/Some-User-Note.md;
  git add templates/luna-second-brain/Some-User-Note.md;
  expect_rc 0 bash "$SCRIPT"
'

# Required contract: non-template change -> pass.
run_test "non-template change passes (rc=0)" '
  setup_repo && cd "$R" || exit 1; mk_market "$MP" 0.1.0; git add "$MP"; git commit -qm seed;
  : > README-ROOT.md; git add README-ROOT.md;
  expect_rc 0 bash "$SCRIPT"
'

# Deletion of a single owned file, staged, without a bump -> fail. The gate is
# diff-driven, not working-tree-driven, so a deletion must be caught the same
# as an addition/modification (HIMMEL-524 CR round 3).
run_test "blocks staged deletion of owned content without bump (rc=1)" '
  setup_repo && cd "$R" || exit 1; mk_market "$MP" 0.1.0; git add "$MP"; git commit -qm seed;
  mkdir -p templates/luna-second-brain/docs; : > templates/luna-second-brain/docs/foo.md;
  git add templates/luna-second-brain/docs/foo.md; git commit -qm "add doc";
  git rm -q templates/luna-second-brain/docs/foo.md;
  expect_rc 1 bash "$SCRIPT"
'

# Deletion of the ENTIRE template dir (including marketplace.json itself),
# without a bump -> fail. The pre-fix early "$TEMPLATE_ROOT absent -> exit 0"
# working-tree check would have bypassed this entirely (the bug this closes).
run_test "blocks deletion of the ENTIRE template dir without bump (rc=1)" '
  setup_repo && cd "$R" || exit 1; mk_market "$MP" 0.1.0; git add "$MP"; git commit -qm seed;
  mkdir -p templates/luna-second-brain/docs; : > templates/luna-second-brain/docs/foo.md;
  git add templates/luna-second-brain/docs/foo.md; git commit -qm "add doc";
  git rm -rq templates/luna-second-brain;
  expect_rc 1 bash "$SCRIPT"
'

# Structural: no-op without .himmel-dev marker.
run_test "no-op without .himmel-dev marker (rc=0)" '
  setup_repo_no_marker && cd "$R" || exit 1; mk_market "$MP" 0.1.0; git add "$MP"; git commit -qm seed;
  mkdir -p templates/luna-second-brain/docs; : > templates/luna-second-brain/docs/foo.md; git add templates/luna-second-brain/docs/foo.md;
  expect_rc 0 bash "$SCRIPT"
'

# Structural: bypass seam.
run_test "TEMPLATE_VERSION_OK=1 bypasses (rc=0)" '
  setup_repo && cd "$R" || exit 1; mk_market "$MP" 0.1.0; git add "$MP"; git commit -qm seed;
  mkdir -p templates/luna-second-brain/docs; : > templates/luna-second-brain/docs/foo.md; git add templates/luna-second-brain/docs/foo.md;
  expect_rc 0 env TEMPLATE_VERSION_OK=1 bash "$SCRIPT"
'

# Structural: force-err seam.
run_test "TEMPLATE_VERSION_FORCE_ERR=1 exits 2" '
  setup_repo && cd "$R" || exit 1; expect_rc 2 env TEMPLATE_VERSION_FORCE_ERR=1 bash "$SCRIPT"
'

# marketplace.json itself is owned: a description change without a bump -> fail.
run_test "marketplace.json description change without bump fails (rc=1)" '
  setup_repo && cd "$R" || exit 1; mk_market "$MP" 0.1.0; git add "$MP"; git commit -qm seed;
  printf "%s\n" "{\"name\":\"luna-brain\",\"metadata\":{\"description\":\"x\",\"version\":\"0.1.0\"},\"plugins\":[]}" > "$MP";
  git add "$MP";
  expect_rc 1 bash "$SCRIPT"
'

# A pure version bump alone (no other content) passes.
run_test "pure version bump alone passes (rc=0)" '
  setup_repo && cd "$R" || exit 1; mk_market "$MP" 0.1.0; git add "$MP"; git commit -qm seed;
  mk_market "$MP" 0.2.0; git add "$MP";
  expect_rc 0 bash "$SCRIPT"
'

# threeway class (_CLAUDE.md) without bump -> fail.
run_test "_CLAUDE.md (threeway) change without bump fails (rc=1)" '
  setup_repo && cd "$R" || exit 1; mk_market "$MP" 0.1.0; git add "$MP"; git commit -qm seed;
  : > templates/luna-second-brain/_CLAUDE.md; git add templates/luna-second-brain/_CLAUDE.md;
  expect_rc 1 bash "$SCRIPT"
'

# jsonmerge class (community-plugins.json) without bump -> fail.
run_test "community-plugins.json (jsonmerge) change without bump fails (rc=1)" '
  setup_repo && cd "$R" || exit 1; mk_market "$MP" 0.1.0; git add "$MP"; git commit -qm seed;
  mkdir -p templates/luna-second-brain/.obsidian; : > templates/luna-second-brain/.obsidian/community-plugins.json;
  git add templates/luna-second-brain/.obsidian/community-plugins.json;
  expect_rc 1 bash "$SCRIPT"
'

# pre-push: bump in a later commit of the range -> pass.
run_test "pre-push passes when version bumped in a later commit (rc=0)" '
  setup_repo_with_origin && cd "$R" || exit 1; git checkout -qb feat/x;
  mkdir -p templates/luna-second-brain/docs; : > templates/luna-second-brain/docs/foo.md;
  git add .; git commit -qm "content";
  mk_market "$MP" 0.2.0; git add "$MP"; git commit -qm "bump";
  expect_rc 0 env TEMPLATE_VERSION_NO_FETCH=1 bash "$SCRIPT" --pre-push
'

# pre-push: range never bumps -> fail.
run_test "pre-push blocks when range never bumps (rc=1)" '
  setup_repo_with_origin && cd "$R" || exit 1; git checkout -qb feat/y;
  mkdir -p templates/luna-second-brain/docs; : > templates/luna-second-brain/docs/foo.md;
  git add .; git commit -qm "content";
  expect_rc 1 env TEMPLATE_VERSION_NO_FETCH=1 bash "$SCRIPT" --pre-push
'

# pre-push: main bumps AFTER the branch split, branch itself never bumps ->
# must still fail. prev_v has to compare at the MERGE-BASE, not the current
# main tip, or the main-side bump falsely clears the branch (HIMMEL-524 CR).
run_test "pre-push blocks when main bumps after split but branch never bumps (rc=1)" '
  setup_repo_with_origin && cd "$R" || exit 1; git checkout -qb feat/z;
  mkdir -p templates/luna-second-brain/docs; : > templates/luna-second-brain/docs/foo.md;
  git add .; git commit -qm "content";
  git checkout -q main; mk_market "$MP" 0.2.0; git add "$MP"; git commit -qm "main bump";
  git push -q origin main; git checkout -q feat/z;
  expect_rc 1 env TEMPLATE_VERSION_NO_FETCH=1 bash "$SCRIPT" --pre-push
'

# Renaming an owned file OUT of the template dir without a bump -> fail.
# name-only diff honors rename detection by default, which would report only
# the destination (untracked, non-owned) path and never classify the deleted
# source -- --no-renames forces delete+add so both sides surface. Explicitly
# set diff.renames=true so the fixture proves the flag matters rather than
# happening to pass under an unconfigured default (HIMMEL-524 CR round 4).
run_test "blocks rename of owned file OUT of template dir without bump (rc=1)" '
  setup_repo && cd "$R" || exit 1; git config diff.renames true;
  mk_market "$MP" 0.1.0; git add "$MP"; git commit -qm seed;
  mkdir -p templates/luna-second-brain/docs;
  printf "same content on both sides of the rename, long enough to be detected\n" > templates/luna-second-brain/docs/foo.md;
  git add templates/luna-second-brain/docs/foo.md; git commit -qm "add doc";
  git mv templates/luna-second-brain/docs/foo.md moved-foo.md;
  expect_rc 1 bash "$SCRIPT"
'

# Source parity: owned_class() must stay case-arm-identical to upgrade.sh's
# classify() (the single source of truth these arms are copied from
# verbatim, per the header comment) -- an upstream classify() edit that isn't
# mirrored here should break THIS test, not silently under/over-fire the gate.
run_test "owned_class() case arms match upgrade.sh classify() (source parity)" '
  a=$(extract_case_arms "$SCRIPT" owned_class);
  b=$(extract_case_arms "$UPGRADE_SH" classify);
  [ -n "$a" ] && [ "$a" = "$b" ]
'

# extract_case_arms must skip comment-only and blank lines INSIDE the case
# block -- a comment added to one copy but not the other must not false-fail
# the parity test above. Synthetic fixtures (not the real source files), so
# this is independent of whether the two real functions currently carry
# comments (HIMMEL-524 CR round 5).
run_test "extract_case_arms filters comments/blanks inside the case block" '
  f1=$(mktemp -t tv-test-arms1.XXXXXX);
  f2=$(mktemp -t tv-test-arms2.XXXXXX);
  printf "foo() {\n    case \"\$1\" in\n        # a comment only one copy has\n        a) echo x ;;\n\n        b) echo y ;;\n    esac\n}\n" > "$f1";
  printf "bar() {\n    case \"\$1\" in\n        a) echo x ;;\n        b) echo y ;;\n    esac\n}\n" > "$f2";
  a=$(extract_case_arms "$f1" foo);
  b=$(extract_case_arms "$f2" bar);
  [ -n "$a" ] && [ "$a" = "$b" ]
'

# pre-push: a FAILED fetch (network blip etc.) without NO_FETCH must fail
# closed, not silently fall back to a stale local origin/$db that could carry
# an upstream bump the branch never earned (HIMMEL-524 CR round 5).
run_test "pre-push fails closed when fetch fails without NO_FETCH (rc=2)" '
  setup_repo_with_origin && cd "$R" || exit 1; git checkout -qb feat/fetchfail;
  git remote set-url origin "$R/does-not-exist";
  expect_rc 2 bash "$SCRIPT" --pre-push
'

# pre-commit: a diff that git genuinely CANNOT compute must fail closed, not
# fall through as an empty touched set (which would exit 0). Corrupt the
# index so `git diff --cached` itself fails (HIMMEL-524 CR round 5).
run_test "pre-commit fails closed when the staged diff cannot be computed (rc=2)" '
  setup_repo && cd "$R" || exit 1; mk_market "$MP" 0.1.0; git add "$MP"; git commit -qm seed;
  mkdir -p templates/luna-second-brain/docs; : > templates/luna-second-brain/docs/foo.md;
  git add templates/luna-second-brain/docs/foo.md;
  printf "garbage-not-an-index" > .git/index;
  expect_rc 2 bash "$SCRIPT"
'

# pre-push: same contract for the range diff -- corrupt HEAD'"'"'s commit
# object so `git diff $base...HEAD` itself fails, must fail closed (HIMMEL-524
# CR round 5).
run_test "pre-push fails closed when the range diff cannot be computed (rc=2)" '
  setup_repo_with_origin && cd "$R" || exit 1; git checkout -qb feat/corrupt;
  mkdir -p templates/luna-second-brain/docs; : > templates/luna-second-brain/docs/foo.md;
  git add .; git commit -qm "content";
  head_sha=$(git rev-parse HEAD);
  rm -f ".git/objects/${head_sha:0:2}/${head_sha:2}";
  expect_rc 2 env TEMPLATE_VERSION_NO_FETCH=1 bash "$SCRIPT" --pre-push
'

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

if [ "$_failures" -eq 0 ]; then
  echo "OK: all cases passed"
  exit 0
else
  echo "FAIL: $_failures case(s) failed"
  exit 1
fi
