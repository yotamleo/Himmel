#!/usr/bin/env bash
# Suite for scripts/docs/check-llms-links.sh (HIMMEL-2832).
#
# Every case builds a throwaway git repo and points the script at it through
# CLAUDE_PROJECT_DIR, which is how repo_root() resolves ROOT. That makes each
# invariant testable in isolation — including the two that cannot be exercised
# against the real tree without committing a violation: an untracked link and a
# link into a PRIVATE_PATHS carve-out.
#
# The carve-out lists are supplied by a stub scripts/lib/public-clone-paths.sh
# inside the fixture repo, so the suite asserts the PUBLIC-PROJECTION behaviour
# rather than whichever tokens the real lib happens to carry today. Its absence
# is a case too: that is the public clone, where tracked-ness is the whole test.
#
# Platform guard (gitbash-only): pure POSIX bash 3.2+ plus git/mktemp, so it
# runs unchanged under Git Bash on Windows. No .ps1 twin needed.
#
# Usage: bash scripts/docs/test-check-llms-links.sh
# Exit:  0 = every case passed, 1 = at least one failed (all are reported).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/check-llms-links.sh"

# shellcheck source=scripts/lib/fixture-tempdir.sh
# shellcheck disable=SC1091
. "$HERE/../lib/fixture-tempdir.sh"

pass=0
fail=0

ok() { pass=$((pass + 1)); }
bad() { echo "FAIL: $*" >&2; fail=$((fail + 1)); }

# setup_repo — a git repo with one tracked doc to link at, and nothing else.
# R is set for the caller. Everything the cases add on top is theirs.
setup_repo() {
  R=$(fixture_mktemp_dir) || return 1
  git -C "$R" init -q
  git -C "$R" config user.email t@t
  git -C "$R" config user.name t
  mkdir -p "$R/docs/setup"
  echo 'real' > "$R/docs/configuration.md"
  echo 'real' > "$R/docs/setup/updating.md"
  git -C "$R" add docs/configuration.md docs/setup/updating.md
  git -C "$R" commit -q -m init
}

# run_check <relative-doc> — the script under test, against the fixture repo.
# Output goes to $OUT, rc to $RC; neither is printed unless a case reports.
# HIMMEL_PUBLIC_REMOTE is pinned to a fixture value so the private-repo-name
# class compares against a known public name rather than whatever the operator
# happens to export; a fixture repo has no origin at all unless a case adds one.
run_check() {
  RC=0
  OUT=$(CLAUDE_PROJECT_DIR="$R" HIMMEL_PUBLIC_REMOTE=fixture-org/Himmel \
    bash "$SCRIPT" "$1" 2>&1) || RC=$?
}

# expect <want-rc> <case-name> — assert rc, and on mismatch show what ran.
expect() {
  if [ "$RC" -eq "$1" ]; then
    ok
  else
    bad "$2: expected rc=$1, got rc=$RC"
    printf '%s\n' "$OUT" | sed 's/^/    /' >&2
  fi
}

# expect_says <substring> <case-name> — assert the report names the reason, not
# merely that it failed. A check that fails for the wrong reason is not a check.
expect_says() {
  case "$OUT" in
    *"$1"*) ok ;;
    *)
      bad "$2: output does not mention '$1'"
      printf '%s\n' "$OUT" | sed 's/^/    /' >&2
      ;;
  esac
}

# expect_silent_about <substring> <case-name> — the complement of expect_says,
# for the one class whose report must NOT quote what it found.
expect_silent_about() {
  case "$OUT" in
    *"$1"*)
      bad "$2: output should not mention '$1'"
      printf '%s\n' "$OUT" | sed 's/^/    /' >&2
      ;;
    *) ok ;;
  esac
}

# stub_carve_outs — a fixture public-clone-paths.sh, so the PRIVATE_PATHS and
# DETECTOR_DROP branches are exercised against known tokens.
stub_carve_outs() {
  mkdir -p "$R/scripts/lib"
  cat > "$R/scripts/lib/public-clone-paths.sh" <<'STUB'
PRIVATE_PATHS="docs/secret-runbook.md handovers"
DETECTOR_DROP="docs/specs/"
STUB
}

# --------------------------------------------------------------- green paths

setup_repo || exit 1
printf 'himmel router\n\n- [config](docs/configuration.md)\n' > "$R/llms.txt"
run_check llms.txt
expect 0 "green: a tracked link and a doc inside budget"
expect_says "budget 3/60 lines" "green: budget is reported for llms.txt"

# The budget belongs to llms.txt alone — the other two invariants are about the
# public projection and apply to any doc, which is what makes the script
# reusable on docs/setup/*.md.
setup_repo || exit 1
i=0
: > "$R/docs/setup/install.md"
while [ "$i" -lt 200 ]; do
  echo "line $i with several ordinary words in it" >> "$R/docs/setup/install.md"
  i=$((i + 1))
done
run_check docs/setup/install.md
expect 0 "budget: skipped for a non-llms.txt basename"
expect_says "budget n/a (not llms.txt)" "budget: says it skipped"

# Document-relative resolution. Every link in docs/setup/*.md starts with ../,
# and resolving those against the repo root instead of the document would report
# every one of them as untracked.
setup_repo || exit 1
printf '[cfg](../configuration.md) and [upd](updating.md)\n' > "$R/docs/setup/migrating.md"
run_check docs/setup/migrating.md
expect 0 "links: resolve relative to the DOCUMENT, not the repo root"

# An anchor names a heading, not a file: the file has to exist, the anchor does
# not — this script cannot verify a heading and must not pretend to.
setup_repo || exit 1
printf '[channels](docs/setup/updating.md#release-channels)\n' > "$R/llms.txt"
run_check llms.txt
expect 0 "links: an anchor fragment is stripped before the existence test"

# Absolute URLs are outside the public projection this script reasons about.
setup_repo || exit 1
printf '[gh](https://example.invalid/x) [m](mailto:a@b.invalid) [a](#top)\n' > "$R/llms.txt"
run_check llms.txt
expect 0 "links: absolute URLs, mailto and bare anchors are skipped"

# ------------------------------------------------------------- budget (red)

setup_repo || exit 1
i=0
: > "$R/llms.txt"
while [ "$i" -lt 61 ]; do
  echo "x" >> "$R/llms.txt"
  i=$((i + 1))
done
run_check llms.txt
expect 1 "RED budget: 61 lines exceeds the 60-line cap"
expect_says "budget: 61 lines exceeds 60" "RED budget: names the line overrun"

# The word cap is the one that bites: the pre-rewrite llms.txt passed a naive
# line count while carrying ~600 words about a single subsystem.
setup_repo || exit 1
: > "$R/llms.txt"
i=0
while [ "$i" -lt 51 ]; do
  echo "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi" >> "$R/llms.txt"
  i=$((i + 1))
done
run_check llms.txt
expect 1 "RED budget: 700 words exceeded while inside the line cap"
expect_says "words exceeds 700" "RED budget: names the word overrun"

# ---------------------------------------------------------- forbidden (red)

setup_repo || exit 1
printf 'see handovers/yotamleo/notes.md\n' > "$R/llms.txt"
run_check llms.txt
expect 1 "RED forbidden: a handovers/ state path"
expect_says "forbidden (handover state path)" "RED forbidden: names the handover class"

setup_repo || exit 1
printf '[enf](docs/internals/enforcement.md)\n' > "$R/llms.txt"
run_check llms.txt
expect 1 "RED forbidden: a docs/internals/ link"
expect_says "forbidden (internal docs link)" "RED forbidden: names the internals class"

# The same forbidden link as a docs/setup/*.md spells it. The class is decided
# on the RESOLVED path for exactly this reason — a literal scan for
# `](docs/internals/` never sees the `../` form, which is the only form the two
# guides this script also runs on can even write.
setup_repo || exit 1
printf '[gotchas](../internals/environment-gotchas.md)\n' > "$R/docs/setup/install.md"
run_check docs/setup/install.md
expect 1 "RED forbidden: a ../internals/ link from docs/setup/"
expect_says "forbidden (internal docs link)" "RED forbidden: names the class after resolution"

# The private repo's name. It is derived from origin at runtime rather than
# spelled in the checker, because the checker ships publicly too — so the
# fixture supplies its own origin and its own public name to compare against.
setup_repo || exit 1
git -C "$R" remote add origin https://github.com/fixture-org/widget-private.git
printf 'clone widget-private, then run the installer\n' > "$R/llms.txt"
run_check llms.txt
expect 1 "RED forbidden: the private remote's repo name appears in the doc"
expect_says "forbidden (private repo name)" "RED forbidden: names the private-repo class"
expect_silent_about "widget-private" "RED forbidden: the report does not repeat the leak"

# GitHub folds repo-name case, so the class does too.
setup_repo || exit 1
git -C "$R" remote add origin https://github.com/fixture-org/Widget-Private.git
printf 'clone widget-private, then run the installer\n' > "$R/llms.txt"
run_check llms.txt
expect 1 "RED forbidden: the private name matches case-insensitively"

# In the public clone origin IS the public remote: there is no private name to
# leak, and the class must not fire on the public repo's own name.
setup_repo || exit 1
git -C "$R" remote add origin https://github.com/fixture-org/Himmel.git
printf 'himmel is a harness for Claude Code\n' > "$R/llms.txt"
run_check llms.txt
expect 0 "forbidden: the class is skipped when origin already is the public remote"

# No origin at all — a bare clone, a fresh init — is not a violation either.
setup_repo || exit 1
printf 'himmel is a harness for Claude Code\n' > "$R/llms.txt"
run_check llms.txt
expect 0 "forbidden: no origin remote means no private name to check"

setup_repo || exit 1
printf 'clone it to /home/fixture/code/himmel\n' > "$R/llms.txt"
run_check llms.txt
expect 1 "RED forbidden: an absolute operator-personal home path"
expect_says "forbidden (absolute home path)" "RED forbidden: names the home-path class"

# The same class, spelled the two other ways a station writes it.
setup_repo || exit 1
printf 'macOS: /Users/fixture/himmel and Windows: C:\\Users\\fixture\\himmel\n' > "$R/llms.txt"
run_check llms.txt
expect 1 "RED forbidden: /Users/ and C:\\Users\\ home paths"

# ---------------------------------------------------------------- links (red)

setup_repo || exit 1
printf '[ghost](docs/never-written.md)\n' > "$R/llms.txt"
run_check llms.txt
expect 1 "RED link: target is not tracked at HEAD"
expect_says "is not tracked at HEAD" "RED link: names untracked-ness"

# A `..` with nothing left to pop escapes the repo root. Clamping it there is
# the dangerous failure, not a harmless one: this link folds to
# docs/configuration.md, which IS tracked, so a silently clamped resolution
# certifies a link that 404s for every reader.
setup_repo || exit 1
printf '[cfg](../../docs/configuration.md)\n' > "$R/llms.txt"
run_check llms.txt
expect 1 "RED link: traversal above the repository root is not clamped into a pass"
expect_says "traverses above the repository root" "RED link: names the traversal"

# The same shape from a nested document, where one ../ is legitimate and the
# second is not.
setup_repo || exit 1
printf '[cfg](../../../configuration.md)\n' > "$R/docs/setup/migrating.md"
run_check docs/setup/migrating.md
expect 1 "RED link: traversal above root from a nested document"

# On-disk existence is NOT the test. This file exists in the working tree and
# would pass a naive [ -f ] check while 404ing for every public reader.
setup_repo || exit 1
echo 'untracked' > "$R/docs/scratch.md"
printf '[scratch](docs/scratch.md)\n' > "$R/llms.txt"
run_check llms.txt
expect 1 "RED link: exists on disk but is untracked — existence is not the test"

# The carve-out case that motivated the whole check: a file tracked PRIVATELY
# and listed in PRIVATE_PATHS passes both existence and tracked-ness, and is
# still a 404 in the public repo.
setup_repo || exit 1
stub_carve_outs
echo 'private' > "$R/docs/secret-runbook.md"
git -C "$R" add docs/secret-runbook.md scripts/lib/public-clone-paths.sh
git -C "$R" commit -q -m private
printf '[runbook](docs/secret-runbook.md)\n' > "$R/llms.txt"
run_check llms.txt
expect 1 "RED link: tracked, but carved out by PRIVATE_PATHS"
expect_says "targets a PRIVATE_PATHS entry" "RED link: names the PRIVATE_PATHS carve-out"

setup_repo || exit 1
stub_carve_outs
mkdir -p "$R/docs/specs"
echo 'spec' > "$R/docs/specs/plan.md"
git -C "$R" add docs/specs/plan.md scripts/lib/public-clone-paths.sh
git -C "$R" commit -q -m specs
printf '[plan](docs/specs/plan.md)\n' > "$R/llms.txt"
run_check llms.txt
expect 1 "RED link: tracked, but dropped by DETECTOR_DROP"
expect_says "targets a DETECTOR_DROP path" "RED link: names the DETECTOR_DROP drop"

# PRIVATE_PATHS membership is ANCHORED, the same way propagate-public.sh
# anchors it. Unanchored prefix matching would let the token `handovers` claim
# docs/handovers-explained.md, which is a perfectly public file.
setup_repo || exit 1
stub_carve_outs
echo 'public' > "$R/docs/handovers-explained.md"
git -C "$R" add docs/handovers-explained.md scripts/lib/public-clone-paths.sh
git -C "$R" commit -q -m anchor
printf '[hx](docs/handovers-explained.md)\n' > "$R/llms.txt"
run_check llms.txt
expect 0 "carve-outs: membership is anchored, not a bare prefix match"

# --------------------------------------------------------- fail-soft carve-out

# In the PUBLIC clone the carve-out lib is absent by construction — and so is
# everything it carves out — so tracked-ness IS the whole test there. The script
# must say which source it used rather than silently weakening.
setup_repo || exit 1
printf '[config](docs/configuration.md)\n' > "$R/llms.txt"
run_check llms.txt
expect 0 "carve-outs: absent lib degrades to tracked-ness alone"
expect_says "carve-outs from none (public clone" "carve-outs: says the lib was absent"

setup_repo || exit 1
stub_carve_outs
git -C "$R" add scripts/lib/public-clone-paths.sh
git -C "$R" commit -q -m lib
printf '[config](docs/configuration.md)\n' > "$R/llms.txt"
run_check llms.txt
expect_says "carve-outs from scripts/lib/public-clone-paths.sh" "carve-outs: names the lib when present"

# ------------------------------------------------------------------- misuse

setup_repo || exit 1
run_check does-not-exist.txt
expect 1 "misuse: a missing target file is an error, not a pass"
expect_says "no such file" "misuse: names the missing file"

# ---------------------------------------------------------------- all reds

# Every violation is printed, not just the first — a check that stops at the
# first failure costs a full round trip per finding.
setup_repo || exit 1
printf 'handovers/x.md\n[ghost](docs/never-written.md)\n' > "$R/llms.txt"
run_check llms.txt
expect 1 "reporting: multiple violations in one file"
expect_says "forbidden (handover state path)" "reporting: first violation printed"
expect_says "is not tracked at HEAD" "reporting: second violation printed too"

echo "test-check-llms-links: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
