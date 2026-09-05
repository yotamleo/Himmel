#!/usr/bin/env bash
# Smoke test for scripts/gen-changelog.sh.
#
# Builds throwaway git repos, exercises the generator, asserts correct output.
# Usage: bash scripts/hooks/test-gen-changelog.sh
#
# Exit 0 if all cases pass, 1 otherwise.
#
# shellcheck disable=SC2034  # GEN/R used inside eval'd test body strings, not directly
# shellcheck disable=SC2016  # single-quoted test body strings intentionally contain $
# shellcheck disable=SC2317  # fixture fns called indirectly via eval inside run_test
# shellcheck disable=SC2329  # same as SC2317 (alias in newer shellcheck versions)
set -uo pipefail

HOOKS="$(cd "$(dirname "$0")" && pwd)"
GEN="$(cd "$HOOKS/.." && pwd)/gen-changelog.sh"
# shellcheck source=../lib/fixture-tempdir.sh
# shellcheck disable=SC1091
. "$HOOKS/../lib/fixture-tempdir.sh"

# ---------------------------------------------------------------------------
# Fixture: temp git repo with a few conventional commits
# ---------------------------------------------------------------------------

setup_commits() {
  R=$(fixture_mktemp_dir) || return 1
  git -C "$R" init -q
  git -C "$R" config user.email t@t
  git -C "$R" config user.name t
  git -C "$R" commit -q --allow-empty -m "chore: initial scaffold"
  git -C "$R" commit -q --allow-empty -m "feat: baseline feature"
  git -C "$R" commit -q --allow-empty -m "fix: baseline bug fix"
}

# Fixture: version-tag grouping (HIMMEL-2250). v0.1.0 is a real version tag;
# recovered-stash mimics the non-version tags this repo actually carries
# (recovery stashes etc.) and must NOT get a section of its own.
setup_tagged_commits() {
  R=$(fixture_mktemp_dir) || return 1
  git -C "$R" init -q
  git -C "$R" config user.email t@t
  git -C "$R" config user.name t
  git -C "$R" commit -q --allow-empty -m "chore: scaffold"
  git -C "$R" commit -q --allow-empty -m "feat: old feature"
  git -C "$R" tag v0.1.0
  git -C "$R" commit -q --allow-empty -m "fix: post-release fix"
  git -C "$R" tag recovered-stash
  git -C "$R" commit -q --allow-empty -m "feat: newest thing"
}

# Fixture: Finding-2 repro (HIMMEL-2250 CR) — a backfilled ANNOTATED tag on an
# OLDER commit gets a newer creatordate than a lightweight tag on a NEWER
# commit; `--sort=-creatordate` would order it first and compute the
# `<prev>..<tag>` ranges against the wrong predecessor.
setup_backfilled_tag_commits() {
  R=$(fixture_mktemp_dir) || return 1
  git -C "$R" init -q
  git -C "$R" config user.email t@t
  git -C "$R" config user.name t
  GIT_AUTHOR_DATE="2020-01-01T00:00:00" GIT_COMMITTER_DATE="2020-01-01T00:00:00" \
    git -C "$R" commit -q --allow-empty -m "feat: ancient feature"
  GIT_AUTHOR_DATE="2020-06-01T00:00:00" GIT_COMMITTER_DATE="2020-06-01T00:00:00" \
    git -C "$R" commit -q --allow-empty -m "feat: middle feature"
  git -C "$R" tag v0.2.0
  git -C "$R" tag -a v0.1.0 HEAD~1 -m "backfilled v0.1.0"
}

# ---------------------------------------------------------------------------
# run_test harness (modeled on test-doc-guard.sh)
# ---------------------------------------------------------------------------

_failures=0

run_test() {
  local name="$1" body="$2"
  local rc=0
  ( eval "$body" ) 2>/dev/null || rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '  PASS  %s\n' "$name"
  else
    printf '  FAIL  %s (subshell rc=%s)\n' "$name" "$rc"
    _failures=$((_failures + 1))
  fi
}

# ---------------------------------------------------------------------------
# Step 1: Test cases (3 total)
# ---------------------------------------------------------------------------

run_test "idempotent on immediate re-run" '
  setup_commits && cd "$R" || exit 1;
  bash "$GEN"; cp CHANGELOG.md a; bash "$GEN"; diff -q a CHANGELOG.md
'

run_test "non-conventional commit lands under Other" '
  setup_commits && cd "$R" || exit 1; git commit -q --allow-empty -m "random no-type subject";
  bash "$GEN"; grep -q "### Other" CHANGELOG.md && grep -q "random no-type subject" CHANGELOG.md
'

run_test "feat lands under Added" '
  setup_commits && cd "$R" || exit 1; git commit -q --allow-empty -m "feat: shiny thing";
  bash "$GEN"; awk "/### Added/{f=1} f&&/shiny thing/{print; exit}" CHANGELOG.md | grep -q "shiny thing"
'

run_test "output is end-of-file-fixer clean (single trailing newline)" '
  setup_commits && cd "$R" || exit 1; bash "$GEN";
  # last two bytes must contain exactly ONE newline — a trailing blank line
  # (two newlines) is what end-of-file-fixer would rewrite on every commit.
  [ "$(tail -c2 CHANGELOG.md | wc -l | tr -d " ")" -eq 1 ]
'

# ---------------------------------------------------------------------------
# Step 2: HIMMEL-2250 — version-tag grouping + --check staleness mode
# ---------------------------------------------------------------------------

run_test "tagless output unchanged (single Unreleased, no version headings)" '
  setup_commits && cd "$R" || exit 1; bash "$GEN";
  [ "$(grep -c "^## \[Unreleased\]" CHANGELOG.md)" -eq 1 ] &&
  [ "$(grep -c "^## \[v" CHANGELOG.md)" -eq 0 ]
'

run_test "version-tag grouping matches verified reference output" '
  setup_tagged_commits && cd "$R" || exit 1;
  bash "$GEN" &&
  d=$(git log -1 --format=%ad --date=short v0.1.0) &&
  printf "%s\n" \
    "<!-- generated by scripts/gen-changelog.sh; do not hand-edit -->" \
    "# Changelog" "" "## [Unreleased]" "" "### Added" "- newest thing" "" \
    "### Fixed" "- post-release fix" "" "## [v0.1.0] - $d" "" "### Added" \
    "- old feature" "" "### Changed" "- chore: scaffold" > expected.txt &&
  diff -q expected.txt CHANGELOG.md
'

run_test "non-version tag creates no changelog section" '
  setup_tagged_commits && cd "$R" || exit 1; bash "$GEN";
  ! grep -q "recovered-stash" CHANGELOG.md
'

run_test "idempotent with tags present" '
  setup_tagged_commits && cd "$R" || exit 1;
  bash "$GEN"; cp CHANGELOG.md a; bash "$GEN"; diff -q a CHANGELOG.md
'

run_test "--check exits 0 when current, 1 when stale, writes nothing" '
  setup_commits && cd "$R" || exit 1;
  bash "$GEN" &&
  cp CHANGELOG.md orig.txt &&
  bash "$GEN" --check > check1.txt &&
  grep -q "^OK gen-changelog: CHANGELOG.md is current$" check1.txt &&
  diff -q orig.txt CHANGELOG.md &&
  git commit -q --allow-empty -m "feat: another feature" &&
  { bash "$GEN" --check > check2.txt; [ "$?" -eq 1 ]; } &&
  grep -q "^STALE gen-changelog: CHANGELOG.md is 1 entr(ies) behind" check2.txt &&
  diff -q orig.txt CHANGELOG.md
'

# ---------------------------------------------------------------------------
# Step 3: CR-round regression cases (HIMMEL-2250 findings 1, 2, 4)
# ---------------------------------------------------------------------------

run_test "--check reports the true entry count when a new commit opens a new section" '
  setup_commits && cd "$R" || exit 1;
  bash "$GEN" &&
  git commit -q --allow-empty -m "weird non-conventional subject" &&
  { bash "$GEN" --check > check.txt; [ "$?" -eq 1 ]; } &&
  grep -q "^STALE gen-changelog: CHANGELOG.md is 1 entr(ies) behind" check.txt
'

run_test "ancestry ordering handles a backfilled annotated tag" '
  setup_backfilled_tag_commits && cd "$R" || exit 1;
  bash "$GEN" &&
  d1=$(git log -1 --format=%ad --date=short v0.1.0) &&
  d2=$(git log -1 --format=%ad --date=short v0.2.0) &&
  printf "%s\n" \
    "<!-- generated by scripts/gen-changelog.sh; do not hand-edit -->" \
    "# Changelog" "" "## [Unreleased]" "" "## [v0.2.0] - $d2" "" \
    "### Added" "- middle feature" "" "## [v0.1.0] - $d1" "" \
    "### Added" "- ancient feature" > expected.txt &&
  diff -q expected.txt CHANGELOG.md
'

run_test "--check on missing CHANGELOG.md reports missing, not 0 entries behind" '
  setup_commits && cd "$R" || exit 1;
  [ ! -f CHANGELOG.md ] &&
  { bash "$GEN" --check > check.txt; [ "$?" -eq 1 ]; } &&
  grep -q "^STALE gen-changelog: CHANGELOG.md is missing" check.txt &&
  [ ! -f CHANGELOG.md ]
'

# ---------------------------------------------------------------------------
# Step 4: CR finding 2 -- version-tag glob accepted non-version tags
# ---------------------------------------------------------------------------

run_test "glob-matching but non-version tag (v1-backup) creates no changelog section" '
  setup_commits && cd "$R" || exit 1; git tag v1-backup;
  bash "$GEN"; ! grep -qF "[v1-backup]" CHANGELOG.md
'

run_test "too-few-components tag (v1.2) creates no changelog section" '
  setup_commits && cd "$R" || exit 1; git tag v1.2;
  bash "$GEN"; ! grep -qF "[v1.2]" CHANGELOG.md
'

run_test "pre-release tag (v0.1.0-rc.1) DOES get a changelog section" '
  setup_commits && cd "$R" || exit 1; git tag v0.1.0-rc.1;
  bash "$GEN"; grep -qF "[v0.1.0-rc.1]" CHANGELOG.md
'

# ---------------------------------------------------------------------------
# Step 5: CR round 3 -- misleading-zero drift message + same-commit tag
# tie-break (HIMMEL-2250 findings 1, 2)
# ---------------------------------------------------------------------------

run_test "tag-only drift (no new commits) reports true staleness, not a misleading zero count" '
  setup_commits && cd "$R" || exit 1;
  bash "$GEN" &&
  git tag v0.1.0 &&
  { bash "$GEN" --check > check.txt; [ "$?" -eq 1 ]; } &&
  ! grep -q "0 entr(ies) behind" check.txt &&
  grep -q "^STALE gen-changelog: CHANGELOG.md structure changed with no new entries" check.txt
'

run_test "same-commit tags: release sorts before pre-release on an ancestry tie" '
  setup_commits && cd "$R" || exit 1;
  git tag v0.1.0-rc.1 && git tag v0.1.0 &&
  bash "$GEN" &&
  grep -oE "^## \[[^]]*\]" CHANGELOG.md > order.txt &&
  printf "%s\n" "## [Unreleased]" "## [v0.1.0]" "## [v0.1.0-rc.1]" > expected_order.txt &&
  diff -q expected_order.txt order.txt
'

# ---------------------------------------------------------------------------
# Step 6: HIMMEL-2363 -- a version tag on a side branch (not an ancestor of
# HEAD) outranks the real latest release by raw `git rev-list --count`,
# corrupting release ranges: already-released commits reappear under
# `## [Unreleased]` AND under their real release section.
# ---------------------------------------------------------------------------

# Fixture: v1.0.0 is a real release on the main line (ancestor of HEAD,
# fewer reachable commits). v0.9.0 sits on a side branch off the root commit
# with MORE reachable commits than v1.0.0, and is NOT an ancestor of HEAD --
# the exact shape that corrupts ordering under a plain count sort.
setup_side_branch_tag_commits() {
  R=$(fixture_mktemp_dir) || return 1
  git -C "$R" init -q
  git -C "$R" config user.email t@t
  git -C "$R" config user.name t
  git -C "$R" commit -q --allow-empty -m "chore: root"
  git -C "$R" commit -q --allow-empty -m "feat: main 1"
  git -C "$R" commit -q --allow-empty -m "feat: main 2"
  git -C "$R" tag v1.0.0
  local mainbr
  mainbr=$(git -C "$R" branch --show-current)
  git -C "$R" checkout -q -b side HEAD~2
  git -C "$R" commit -q --allow-empty -m "feat: side 1"
  git -C "$R" commit -q --allow-empty -m "feat: side 2"
  git -C "$R" commit -q --allow-empty -m "feat: side 3"
  git -C "$R" commit -q --allow-empty -m "feat: side 4"
  git -C "$R" tag v0.9.0
  git -C "$R" checkout -q "$mainbr"
  git -C "$R" commit -q --allow-empty -m "feat: main 3 unreleased"
}

run_test "non-ancestor version tag (side branch) does not outrank the real latest release" '
  setup_side_branch_tag_commits && cd "$R" || exit 1;
  bash "$GEN" 2>stderr.txt;
  order=$(grep -oE "^## \[v[^]]*\]" CHANGELOG.md) &&
  [ "$order" = "## [v1.0.0]" ] &&
  grep -q "v0.9.0.*not an ancestor of HEAD" stderr.txt
'

run_test "no commit line appears in two changelog sections (release-range corruption)" '
  setup_side_branch_tag_commits && cd "$R" || exit 1;
  bash "$GEN" 2>/dev/null;
  [ "$(grep -c "main 1\$" CHANGELOG.md)" -eq 1 ] &&
  [ "$(grep -c "main 2\$" CHANGELOG.md)" -eq 1 ]
'

# This row shells out to a real pwsh for PowerShell/Bash parity; pwsh is not
# provisioned on every host (e.g. this Linux station, by design). Gate on
# tool presence, not OS -- a host that DOES have pwsh should still run it.
if command -v pwsh >/dev/null 2>&1; then
run_test "gen-changelog.sh and gen-changelog.ps1 agree on CORRECT section membership (parity)" '
  setup_side_branch_tag_commits && cd "$R" || exit 1;
  PS1GEN="$HOOKS/../gen-changelog.ps1";
  bash "$GEN" >/dev/null 2>/dev/null && cp CHANGELOG.md sh.md &&
  pwsh -NoProfile -File "$PS1GEN" >/dev/null 2>/dev/null && cp CHANGELOG.md ps1.md &&
  diff -q sh.md ps1.md &&
  [ "$(grep -c "main 1\$" sh.md)" -eq 1 ] &&
  [ "$(grep -c "main 2\$" sh.md)" -eq 1 ]
'
else
  echo "SKIP: gen-changelog.sh/.ps1 parity (CORRECT section membership) -- pwsh not installed on this host"
fi

# Fixture: a version tag ref pointing at an object that does not exist --
# forces `git merge-base --is-ancestor` to fail with a real git error
# (exit >1: "fatal: Not a valid commit name"), not "not an ancestor" (exit 1).
setup_broken_tag_ref() {
  R=$(fixture_mktemp_dir) || return 1
  git -C "$R" init -q
  git -C "$R" config user.email t@t
  git -C "$R" config user.name t
  git -C "$R" commit -q --allow-empty -m "chore: root"
  echo "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" > "$R/.git/refs/tags/v9.9.9"
}

run_test "HIMMEL-2363: gen-changelog.sh fails generation (not silent-drop) on a real merge-base error" '
  setup_broken_tag_ref && cd "$R" || exit 1;
  bash "$GEN" >out.txt 2>stderr.txt;
  rc=$?;
  [ "$rc" -ne 0 ] && grep -q "ERROR.*v9.9.9" stderr.txt
'

# Same pwsh-presence gate as the parity row above -- this row also shells
# out to a real pwsh, and this host does not have one installed.
if command -v pwsh >/dev/null 2>&1; then
run_test "HIMMEL-2363: gen-changelog.ps1 fails generation (not silent-drop) on a real merge-base error (parity)" '
  setup_broken_tag_ref && cd "$R" || exit 1;
  PS1GEN="$HOOKS/../gen-changelog.ps1";
  pwsh -NoProfile -File "$PS1GEN" >out.txt 2>stderr.txt;
  rc=$?;
  [ "$rc" -ne 0 ] && grep -q "ERROR.*v9.9.9" stderr.txt
'
else
  echo "SKIP: HIMMEL-2363 gen-changelog.ps1 merge-base-error parity -- pwsh not installed on this host"
fi


# Fixture: a repo carrying a version tag, plus a `git` shim on PATH that stalls
# on the `--is-ancestor` call. The stall is what makes the interrupt
# DETERMINISTIC -- without it the script finishes long before any signal could
# arrive, and the case below would pass while proving nothing.
setup_slow_merge_base() {
  R=$(fixture_mktemp_dir) || return 1
  git -C "$R" init -q
  git -C "$R" config user.email t@t
  git -C "$R" config user.name t
  git -C "$R" commit -q --allow-empty -m "chore: root"
  git -C "$R" tag v1.0.0
  mkdir -p "$R/shim" "$R/tmp"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'for a in "$@"; do [ "$a" = "--is-ancestor" ] && sleep 3; done\n'
    printf 'exec %s "$@"\n' "$(command -v git)"
  } > "$R/shim/git"
  chmod +x "$R/shim/git"
}

# HIMMEL-2376 (private-repo #2077): the merge-base sentinel from HIMMEL-2363 had
# no signal trap, so an interrupted run left `gen-changelog-mb-err.*` behind in
# TMPDIR. The wait-for-sentinel loop below is a NEGATIVE CONTROL, not politeness:
# it FAILS the case when the sentinel never appears, so a run that never reached
# the ancestry filter cannot pass this test by accident.
run_test "HIMMEL-2376: an interrupted run leaves no merge-base sentinel behind" '
  setup_slow_merge_base && cd "$R" || exit 1;
  export TMPDIR="$R/tmp";
  PATH="$R/shim:$PATH" bash "$GEN" >/dev/null 2>&1 &
  pid=$!;
  found=0;
  for _ in $(seq 1 60); do
    if ls "$TMPDIR"/gen-changelog-mb-err.* >/dev/null 2>&1; then found=1; break; fi;
    sleep 0.1;
  done;
  if [ "$found" -ne 1 ]; then kill "$pid" 2>/dev/null; exit 1; fi;
  kill -TERM "$pid" 2>/dev/null;
  wait "$pid" 2>/dev/null;
  ! ls "$TMPDIR"/gen-changelog-mb-err.* >/dev/null 2>&1
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
