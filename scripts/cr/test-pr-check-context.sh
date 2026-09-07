#!/usr/bin/env bash
# Smoke test for scripts/cr/pr-check-context.sh (HIMMEL-2226, HIMMEL-2335).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/pr-check-context.sh"

fail=0
check() { [ "$1" = "$2" ] || { echo "FAIL: $3 - got '$1' want '$2'"; fail=1; }; }

tmp="$(mktemp -d -t pr-check-context.XXXXXX)"; trap 'rm -rf "$tmp"' EXIT

# HIMMEL-2518: every mutation control in this file goes through the RED-control
# contract helper rather than a hand-rolled inequality. The helper asserts the
# mutant RAN, PRODUCED a value, and produced the SPECIFIC wrong value predicted
# - the three properties a `!=` check cannot establish, and the reason T7's
# control below was proved vacuous in PR #2135. RED_CONTROL_TMPDIR keeps its
# stderr captures inside $tmp, so the EXIT trap above already cleans them.
# shellcheck disable=SC2034  # read by the sourced red-control.sh; the repo's
# shell-lint runs shellcheck WITHOUT -x, so it cannot follow the source below.
RED_CONTROL_TMPDIR="$tmp"
# shellcheck source=scripts/lib/red-control.sh
# shellcheck disable=SC1091
. "$DIR/../lib/red-control.sh"

# HIMMEL-2335: the script now requires HIMMEL_REPO (the trust anchor) to be
# set, and every fixture repo below is a throwaway tmp dir unrelated to any
# real himmel checkout -- so without a deliberate, TEST-OWNED anchor every
# invocation would resolve the adopter lane against whatever HIMMEL_REPO
# happens to be set to in the AMBIENT environment this suite runs under,
# making the suite non-hermetic. Anchor every T1-T12 invocation at THIS
# worktree's own root instead: none of the fixture repos below are
# git-worktrees of it, so they all resolve to the adopter lane against this
# anchor -- himmel_dir = this anchor -- which is exactly the value those
# tests already asserted before HIMMEL-2335 (this script's own on-disk
# location, unconditionally). The himmel-lane/delegation scenarios further
# down set their OWN HIMMEL_REPO per-fixture and do not rely on this export.
HIMMEL_ROOT_FOR_TEST="$(cd "$DIR/.." && cd .. && pwd)"
export HIMMEL_REPO="$HIMMEL_ROOT_FOR_TEST"

# get_kv <output> <key> - extract the value of "pr-check-context: key=value"
# from the script's stdout, one line per key (used to assert each key
# appears exactly once further down).
get_kv() { printf '%s\n' "$1" | sed -n "s/^pr-check-context: $2=//p"; }

# literal_replace <in> <out> <old> <new> - replace an EXACT, single-occurrence
# literal (not a regex - \Q..\E) so a wrong file or code that has since moved
# fails LOUDLY (nonzero rc) instead of silently mutating nothing or the wrong
# line, same posture as T23f's structural search below. Defined this early
# (not next to its first use) because T17 below is the first caller.
literal_replace() {
  local old="$3" new="$4"
  OLD="$old" NEW="$new" perl -0777 -pe '
    my $o = $ENV{OLD}; my $n = $ENV{NEW};
    my $c = () = /\Q$o\E/g;
    die "literal_replace: expected exactly 1 match, found $c\n" unless $c == 1;
    s/\Q$o\E/$n/;
  ' "$1" > "$2" 2>"$tmp/literal_replace.err"
}

# --- T1-T7: fixture repo on branch t1, default branch main ------------------
repo="$tmp/repo"
mkdir -p "$repo"
(
  cd "$repo" || exit 1
  git init -q -b main .
  git config user.email t@t
  git config user.name t
  git config commit.gpgsign false
  git commit -q --allow-empty -m init
  git checkout -q -b t1
  git commit -q --allow-empty -m second
)
head_sha="$(cd "$repo" && git rev-parse HEAD)"
# git_dir: the RAW value `git rev-parse --git-common-dir` prints from $repo's
# own cwd (often relative, e.g. ".git") - matches what the script itself
# computes and prints in the marker=... line, so use this for STRING
# comparisons against stdout. git_dir_abs is the same directory resolved to
# an absolute path - use this for actual filesystem existence checks below,
# since those run from the test script's cwd, not $repo's.
git_dir="$(cd "$repo" && git rev-parse --git-common-dir)"
git_dir_abs="$(cd "$repo" && cd "$(git rev-parse --git-common-dir)" && pwd)"

out1="$(cd "$repo" && bash "$SCRIPT")"
rc1=$?
check "$rc1" "0" "T1 rc"

# T1a. Every documented key appears exactly once, with the right value.
for key in himmel_dir repo branch head base marker lane anchor_lane delegated; do
  count="$(printf '%s\n' "$out1" | grep -c "^pr-check-context: $key=")"
  check "$count" "1" "T1a $key appears exactly once"
done
check "$(get_kv "$out1" himmel_dir)" "$(cd "$DIR/.." && cd .. && pwd)" "T1 himmel_dir resolves to this checkout"
# HIMMEL-2335: the fixture repo is not a worktree of HIMMEL_ROOT_FOR_TEST, so
# it resolves the adopter lane against that anchor -- no delegation.
check "$(get_kv "$out1" anchor_lane)" "adopter" "T1 anchor_lane=adopter (fixture is not a worktree of the test anchor)"
check "$(get_kv "$out1" delegated)" "no" "T1 delegated=no (adopter lane never delegates)"
check "$(get_kv "$out1" repo)" "$repo" "T1 repo"
check "$(get_kv "$out1" branch)" "t1" "T1 branch"
check "$(get_kv "$out1" base)" "main" "T1 base"
check "$(get_kv "$out1" lane)" "" "T1 lane is empty - no marker exists yet"

# T2. head is the FULL SHA and matches `git rev-parse HEAD` in the fixture.
head_out="$(get_kv "$out1" head)"
check "$head_out" "$head_sha" "T2 head matches git rev-parse HEAD"
check "${#head_out}" "40" "T2 head is a full 40-char SHA"

# T3. marker points under the SHARED git-common-dir and is branch-scoped.
check "$(get_kv "$out1" marker)" "$git_dir/cr-pending/t1" "T3 marker path"

# T4. BOTH verdict files exist and are EMPTY afterwards - including when they
# held stale content beforehand (assert the stale content is gone).
prior_file="$git_dir_abs/cr-prior-blocking/t1"
aggregate_file="$git_dir_abs/cr-aggregate-verdicts/t1"
[ -f "$prior_file" ] || { echo "FAIL: T4 prior-blocking file missing"; fail=1; }
[ -f "$aggregate_file" ] || { echo "FAIL: T4 aggregate file missing"; fail=1; }
check "$(wc -c <"$prior_file" | tr -d ' ')" "0" "T4 prior-blocking file empty"
check "$(wc -c <"$aggregate_file" | tr -d ' ')" "0" "T4 aggregate file empty"

# T4b. Stale pre-existing content is actually truncated, not just "happened
# to already be empty".
printf 'VERDICT [stale-1] = agreed\n' > "$prior_file"
printf 'VERDICT [stale-2] = agreed\n' > "$aggregate_file"
check "$(wc -c <"$prior_file" | tr -d ' ')" "27" "T4b stale content seeded (sanity)"
(cd "$repo" && bash "$SCRIPT") >/dev/null
check "$?" "0" "T4b rerun rc"
check "$(wc -c <"$prior_file" | tr -d ' ')" "0" "T4b stale prior-blocking content truncated"
check "$(wc -c <"$aggregate_file" | tr -d ' ')" "0" "T4b stale aggregate content truncated"
if grep -q 'stale' "$prior_file" "$aggregate_file" 2>/dev/null; then
  echo "FAIL: T4b stale content still present after truncation"
  fail=1
fi

# --- T5: base resolves correctly for a fixture whose default branch is
# master, not main. -----------------------------------------------------
repo_m="$tmp/repo-master"
mkdir -p "$repo_m"
(
  cd "$repo_m" || exit 1
  git init -q -b master .
  git config user.email t@t
  git config user.name t
  git config commit.gpgsign false
  git commit -q --allow-empty -m init
  git checkout -q -b feature/x
  git commit -q --allow-empty -m second
)
out5="$(cd "$repo_m" && bash "$SCRIPT")"
check "$?" "0" "T5 rc"
check "$(get_kv "$out5" base)" "master" "T5 base=master (not main)"

# T6. A branch name containing '/' (real himmel branches look like
# fix/himmel-2226-guardrail-ux) resolves correctly in both marker and the
# verdict-file paths.
git_dir_m="$(cd "$repo_m" && git rev-parse --git-common-dir)"
git_dir_m_abs="$(cd "$repo_m" && cd "$(git rev-parse --git-common-dir)" && pwd)"
check "$(get_kv "$out5" branch)" "feature/x" "T6 branch with slash"
check "$(get_kv "$out5" marker)" "$git_dir_m/cr-pending/feature/x" "T6 marker with slash-branch"
[ -f "$git_dir_m_abs/cr-prior-blocking/feature/x" ] || { echo "FAIL: T6 prior-blocking file missing for slash-branch"; fail=1; }
[ -f "$git_dir_m_abs/cr-aggregate-verdicts/feature/x" ] || { echo "FAIL: T6 aggregate file missing for slash-branch"; fail=1; }

# --- T7: run from a LINKED WORKTREE of the fixture repo - marker and the
# verdict files still resolve under the SHARED git-common-dir, not a
# per-worktree one. -------------------------------------------------------
wt="$tmp/repo-worktree"
(cd "$repo" && git worktree add -q -b t7-wt "$wt" main) || { echo "FAIL: T7 could not add worktree"; fail=1; }
out7="$(cd "$wt" && bash "$SCRIPT")"
check "$?" "0" "T7 rc"
check "$(get_kv "$out7" branch)" "t7-wt" "T7 branch (worktree)"
check "$(get_kv "$out7" repo)" "$(cd "$wt" && pwd)" "T7 repo is the worktree path"
wt_git_dir_abs="$(cd "$wt" && cd "$(git rev-parse --git-common-dir)" && pwd)"
main_git_dir_abs="$(cd "$repo" && cd "$(git rev-parse --git-common-dir)" && pwd)"
check "$wt_git_dir_abs" "$main_git_dir_abs" "T7 worktree git-common-dir == main repo's (sanity on the fixture)"
marker7="$(get_kv "$out7" marker)"
# Direct string comparison against the expected shared-path marker, NOT the
# `cd "$(dirname "$marker7")/.." && pwd` round-trip this replaced: dirname
# "$marker7" names cr-pending/, a directory pr-check-context.sh only REPORTS
# and never creates (the pre-push hook creates it later when it actually
# writes the marker) - `cd`-ing into a directory that legitimately does not
# exist yet fails outright on bash 5.3 (`cd nonexistent/..` -> "No such file
# or directory", rc=1), so that form failed unconditionally regardless of
# whether the marker path itself was correct. `git rev-parse --git-common-dir`
# prints an ABSOLUTE path when run from a linked worktree (unlike the
# relative ".git" it prints from a main checkout - see the git_dir/git_dir_abs
# comment near the top of this file), so pr-check-context.sh's own marker=
# value from $wt is already the fully-resolved shared path - compare it
# directly instead of re-deriving it through the filesystem.
check "$marker7" "$main_git_dir_abs/cr-pending/t7-wt" "T7 marker resolves under the SHARED git-common-dir, not a per-worktree one"
[ -f "$main_git_dir_abs/cr-prior-blocking/t7-wt" ] || { echo "FAIL: T7 prior-blocking file not under shared git-common-dir"; fail=1; }
[ -f "$main_git_dir_abs/cr-aggregate-verdicts/t7-wt" ] || { echo "FAIL: T7 aggregate file not under shared git-common-dir"; fail=1; }
[ ! -d "$wt/.git/cr-prior-blocking" ] || { echo "FAIL: T7 wrote a PER-WORKTREE cr-prior-blocking dir instead of the shared one"; fail=1; }

# T7 RED: prove the marker assertion above is not vacuous - mutate a scratch
# copy of pr-check-context.sh so ONLY the marker's own construction resolves
# through --git-dir (the PER-WORKTREE gitdir) at that point, leaving the
# shared $git_dir variable itself (still used elsewhere - cap_file etc.) on
# --git-common-dir, rerun T7's exact worktree fixture against the mutant, and
# confirm the same assertion would go RED.
#
# This replaces an earlier version of this control that instead swapped the
# $git_dir ASSIGNMENT to --git-dir. That mutant, run directly from this
# suite's scratch $tmp, has its own HIMMEL_ROOT resolved from $0's own path
# (see pr-check-context.sh's SCRIPT_DIR/HIMMEL_ROOT lines near its top) -
# which does not point at a real himmel checkout from $tmp, so the mutant
# failed closed (exit 2) before ever reaching the marker= printf. `get_kv` on
# that empty stdout returned "", and the control "passed" only because
# '' != '<expected shared path>' - proving the assertion is sensitive to
# SOMETHING, never that it actually catches a per-worktree marker (CR round 1
# [codex-1]: "a mutant that crashes or emits no marker yields an empty value
# and incorrectly passes the RED control via the inequality branch").
#
# Fix: build the mutant AS a fake-himmel anchor's own
# scripts/cr/pr-check-context.sh - critic-panel.sh (only needs to exist) plus
# real copies of write-verdicts.sh/ledger-append.sh/guardrails/lib.sh (same
# shape build_fake_himmel below uses, inlined here since that helper is not
# yet defined at this point in the file) - so the mutant has a genuine
# HIMMEL_ROOT, runs to completion, and actually emits a marker.
mutant_t7_anchor="$tmp/fake-himmel-t7-red"
mkdir -p "$mutant_t7_anchor/scripts/cr" "$mutant_t7_anchor/scripts/guardrails"
: > "$mutant_t7_anchor/scripts/cr/critic-panel.sh"
cp "$DIR/ledger-append.sh" "$mutant_t7_anchor/scripts/cr/ledger-append.sh"
cp "$DIR/write-verdicts.sh" "$mutant_t7_anchor/scripts/cr/write-verdicts.sh"
cp "$DIR/../guardrails/lib.sh" "$mutant_t7_anchor/scripts/guardrails/lib.sh"
mutant_t7="$mutant_t7_anchor/scripts/cr/pr-check-context.sh"
# shellcheck disable=SC2016  # literal match against pr-check-context.sh's own
# source text (unexpanded $vars) - not a shell expansion.
literal_replace "$SCRIPT" "$mutant_t7" \
  'git_dir=$(git rev-parse --git-common-dir)
marker="$git_dir/cr-pending/$branch"' \
  'git_dir=$(git rev-parse --git-common-dir)
marker="$(git rev-parse --git-dir)/cr-pending/$branch"'
rc_lr_t7=$?
if [ "$rc_lr_t7" -ne 0 ]; then
  echo "FAIL: T7 RED - could not build the per-worktree-marker mutant - $(cat "$tmp/literal_replace.err" 2>/dev/null)"
  fail=1
else
  red_control_run --cwd "$wt" -- bash "$mutant_t7"
  # The expected per-worktree marker, computed fresh via --git-dir from $wt
  # itself - not hardcoded, since the on-disk worktree-admin-dir name is a
  # git-internal detail this test should not need to know.
  wt_per_worktree_git_dir_abs="$(cd "$wt" && cd "$(git rev-parse --git-dir)" && pwd)"
  red_control_assert --label "T7" \
    --observed     "$(get_kv "$RED_CONTROL_OUT" marker)" \
    --expect-wrong "$wt_per_worktree_git_dir_abs/cr-pending/t7-wt" \
    --correct      "$main_git_dir_abs/cr-pending/t7-wt" \
    --note "the marker built via --git-dir (per-worktree) resolves under the PER-WORKTREE gitdir instead of the shared one - the assertion above would have caught this" \
    || fail=1
fi

# --- T8: fail-closed - point at a tree with no scripts/cr/critic-panel.sh --
fakehimmel="$tmp/fake-himmel"
mkdir -p "$fakehimmel/scripts/cr" "$fakehimmel/scripts/guardrails"
cp "$DIR/pr-check-context.sh" "$fakehimmel/scripts/cr/pr-check-context.sh"
# no critic-panel.sh under $fakehimmel/scripts/cr - critic-panel.sh itself is
# absent, so HIMMEL_ROOT resolution must fail closed before ever touching
# guardrails/lib.sh or write-verdicts.sh.
out8="$(cd "$repo" && bash "$fakehimmel/scripts/cr/pr-check-context.sh" 2>"$tmp/err8.txt")"
rc8=$?
check "$rc8" "2" "T8 rc (fail-closed, no critic-panel.sh)"
check "$out8" "" "T8 no stdout on the fail-closed path"
grep -q 'critic-panel.sh' "$tmp/err8.txt" || { echo "FAIL: T8 missing critic-panel.sh diagnostic"; fail=1; }

# --- T9-T11: lane= reads the marker's 3rd field (HIMMEL-2226 round 2) -------
# The lane read used to be a step-2 awk fence substituting the marker path as
# a literal ('<marker>') - a repo-controlled branch name embedded in that
# path can break out of the single quote. It now happens inside this script
# against a real shell variable, so the marker path never becomes fence text.
# git_dir_abs, not the raw marker= line: these writes happen from the test
# script's own cwd, not $repo's, so a relative marker path would resolve
# against the wrong directory (see the git_dir/git_dir_abs note above).
marker_t1_abs="$git_dir_abs/cr-pending/t1"
mkdir -p "$(dirname "$marker_t1_abs")"

# T9. marker present, lane = full.
printf '2026-01-01T00:00:00Z | deadbeef | full | origin | refs/heads/t1 | https://example.invalid/x.git | cafebabe\n' > "$marker_t1_abs"
out9="$(cd "$repo" && bash "$SCRIPT")"
check "$?" "0" "T9 rc"
check "$(get_kv "$out9" lane)" "full" "T9 lane=full read off the marker's 3rd field"

# T10. Same marker, lane = docs-audit.
printf '2026-01-01T00:00:00Z | deadbeef | docs-audit | origin | refs/heads/t1 | https://example.invalid/x.git | cafebabe\n' > "$marker_t1_abs"
out10="$(cd "$repo" && bash "$SCRIPT")"
check "$?" "0" "T10 rc"
check "$(get_kv "$out10" lane)" "docs-audit" "T10 lane=docs-audit read off the marker's 3rd field"

# T11. Marker removed again - lane reports empty, not an error (the runbooks
# stop at "nothing to do" before the lane matters, so this is not a new
# failure mode - see the script's comment above its lane read).
rm -f "$marker_t1_abs"
out11="$(cd "$repo" && bash "$SCRIPT")"
check "$?" "0" "T11 rc"
check "$(get_kv "$out11" lane)" "" "T11 lane is empty when the marker does not exist"

# --- T12: a branch name carrying a shell metacharacter is REFUSED (exit 3)
# before anything is printed or any side effect runs (HIMMEL-2226). This is the
# root guard for the substituted-literal injection: every /pr-check fence pastes
# the branch in as literal text (--branch '<branch>'), so a repo-controlled
# branch with an apostrophe would break out. git refuses to CREATE a branch
# whose name contains most shell metacharacters via `git checkout -b`, but a
# name may still legally carry an apostrophe, so use that as the fixture. ------
repo_i="$tmp/repo-inject"
mkdir -p "$repo_i"
# git forbids a SPACE in a ref name but legally permits an apostrophe (and $,
# backtick, quotes) - a name with an apostrophe is the canonical break-out of a
# `--branch '<branch>'` substituted literal, and the exact case HIMMEL-2226
# names. No space is needed to inject; the guard refuses on the apostrophe.
inject_branch="x'y"
(
  cd "$repo_i" || exit 1
  git init -q -b main .
  git config user.email t@t
  git config user.name t
  git config commit.gpgsign false
  git commit -q --allow-empty -m init
  git checkout -q -b "$inject_branch"
  git commit -q --allow-empty -m second
) 2>/dev/null
# Skip loudly rather than pass vacuously if this git rejects the fixture name.
created_branch="$(cd "$repo_i" && git branch --show-current)"
if [ "$created_branch" = "$inject_branch" ]; then
  out12="$(cd "$repo_i" && bash "$SCRIPT" 2>"$tmp/err12.txt")"
  rc12=$?
  check "$rc12" "3" "T12 rc (fail-closed, unsafe branch name)"
  check "$out12" "" "T12 no stdout on the refusal path"
  grep -q 'safe alphabet' "$tmp/err12.txt" || { echo "FAIL: T12 missing unsafe-branch diagnostic"; fail=1; }
  # Refused BEFORE any side effect: neither verdict-scratch dir may have been
  # created for this branch (the truncations run only after the guard passes).
  gd_i="$(cd "$repo_i" && cd "$(git rev-parse --git-common-dir)" && pwd)"
  [ ! -e "$gd_i/cr-prior-blocking/$inject_branch" ] || { echo "FAIL: T12 side effect ran - prior-blocking scratch written for a refused branch"; fail=1; }
  # Negative control: prove the rc assertion is real by confirming a SAFE branch
  # on the same fixture is NOT refused (exit 0), so T12 cannot pass vacuously.
  (cd "$repo_i" && git checkout -q -b safe/slug 2>/dev/null)
  out12b="$(cd "$repo_i" && bash "$SCRIPT" 2>/dev/null)"
  check "$?" "0" "T12 negative control - a safe branch name is accepted (exit 0)"
  check "$(get_kv "$out12b" branch)" "safe/slug" "T12 negative control - safe branch resolved"
else
  echo "SKIP: T12 - git did not accept the hostile branch name '$inject_branch' (got '$created_branch')"
fi

# --- T13-T17: HIMMEL-2335 anchor + delegation ------------------------------
# A "fake himmel" fixture: a real git repo carrying real copies of the
# scripts pr-check-context.sh actually needs at runtime (critic-panel.sh only
# needs to EXIST; guardrails/lib.sh, write-verdicts.sh and ledger-append.sh
# must actually WORK, so they are copied from this checkout, fresh, every
# run -- same pattern T8 above already uses for pr-check-context.sh itself).
build_fake_himmel() {
  local d="$1"
  mkdir -p "$d/scripts/cr" "$d/scripts/guardrails"
  : > "$d/scripts/cr/critic-panel.sh"
  cp "$DIR/pr-check-context.sh" "$d/scripts/cr/pr-check-context.sh"
  cp "$DIR/ledger-append.sh" "$d/scripts/cr/ledger-append.sh"
  cp "$DIR/write-verdicts.sh" "$d/scripts/cr/write-verdicts.sh"
  cp "$DIR/../guardrails/lib.sh" "$d/scripts/guardrails/lib.sh"
  (
    cd "$d" || exit 1
    git init -q -b main .
    git config user.email t@t
    git config user.name t
    git config commit.gpgsign false
    git add -A
    git commit -q -m init
  )
}

anchor13="$tmp/fake-himmel"
build_fake_himmel "$anchor13"
ledger13="$anchor13/.git/cr-critic-scores.jsonl"

# T13. himmel lane, diff TOUCHES scripts/cr/ -> delegation happens:
# delegated=yes, exactly one ledger `delegation` row naming anchor + delegate
# + head. The worktree's branch commit modifies critic-panel.sh itself (a
# real scripts/cr/ file), which is what the merge-base..HEAD diff must catch.
wt13="$tmp/fake-himmel-wt-touch"
(cd "$anchor13" && git worktree add -q -b t13-touch "$wt13" main) || { echo "FAIL: T13 could not add worktree"; fail=1; }
(
  cd "$wt13" || exit 1
  printf '# t13 touch\n' >> scripts/cr/critic-panel.sh
  git add -A
  git commit -q -m "touch scripts/cr"
)
head13="$(cd "$wt13" && git rev-parse HEAD)"
out13="$(cd "$wt13" && HIMMEL_REPO="$anchor13" bash "$anchor13/scripts/cr/pr-check-context.sh")"
rc13=$?
check "$rc13" "0" "T13 rc"
check "$(get_kv "$out13" anchor_lane)" "himmel" "T13 anchor_lane=himmel"
check "$(get_kv "$out13" delegated)" "yes" "T13 delegated=yes (diff touches scripts/cr/)"
# Compare against git's OWN reported spelling of $wt13, not the raw shell
# variable: on Windows, `git rev-parse --show-toplevel` returns a
# Windows-style path (C:/Users/...) while $wt13 (built from $tmp, an MSYS
# POSIX-style mktemp path) stays POSIX-style (/tmp/...) -- same directory,
# different spelling, so a raw-variable comparison here would be a spurious
# platform-specific failure, not a real assertion failure (same posture T7
# above already takes with wt_git_dir_abs / main_git_dir_abs).
wt13_toplevel="$(cd "$wt13" && git rev-parse --show-toplevel)"
check "$(get_kv "$out13" himmel_dir)" "$wt13_toplevel" "T13 himmel_dir is the branch/worktree, not the anchor"
check "$(get_kv "$out13" head)" "$head13" "T13 head matches the worktree HEAD (the delegate resolved its own context)"
[ -f "$ledger13" ] || { echo "FAIL: T13 no ledger written at $ledger13"; fail=1; }
check "$(grep -c '"kind":"delegation"' "$ledger13" 2>/dev/null)" "1" "T13 exactly one delegation row"
check "$(grep -c "\"kind\":\"delegation\".*\"head\":\"$head13\"" "$ledger13" 2>/dev/null)" "1" "T13 delegation row names the delegate head"
# Match on basenames, not full paths: git-for-windows' MSYS layer can
# mangle an absolute Windows path (C:/Users/...) embedded mid-string in a
# single --detail argument that crosses a bash-exec/node subprocess boundary
# (observed directly: the drive-letter prefix gets corrupted while the
# trailing path segment survives byte-for-byte) -- a platform quirk, not a
# defect in what pr-check-context.sh constructs. The basename is immune to
# it and is sufficient to prove BOTH the anchor and the delegate are named.
check "$(L="$ledger13" node -e 'const o=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).find(r=>r.kind==="delegation");console.log(o.detail.includes(process.argv[1])&&o.detail.includes(process.argv[2]))' "$(basename "$anchor13")" "$(basename "$wt13_toplevel")")" "true" "T13 delegation detail names both the anchor and the delegate (by basename, MSYS-mangling-proof)"

# T14. himmel lane, diff does NOT touch scripts/cr/ -> the anchor's own path
# runs: delegated=no, ZERO delegation rows. Positive control for this "zero"
# lives in T13 above (the SAME grep instrument returns 1 there on a known
# touching diff), so a T14 pass is not vacuous.
wt14="$tmp/fake-himmel-wt-notouch"
(cd "$anchor13" && git worktree add -q -b t14-notouch "$wt14" main) || { echo "FAIL: T14 could not add worktree"; fail=1; }
(
  cd "$wt14" || exit 1
  printf 'unrelated\n' > README.md
  git add -A
  git commit -q -m "unrelated change"
)
out14="$(cd "$wt14" && HIMMEL_REPO="$anchor13" bash "$anchor13/scripts/cr/pr-check-context.sh")"
rc14=$?
check "$rc14" "0" "T14 rc"
check "$(get_kv "$out14" anchor_lane)" "himmel" "T14 anchor_lane=himmel"
check "$(get_kv "$out14" delegated)" "no" "T14 delegated=no (diff does not touch scripts/cr/)"
wt14_toplevel="$(cd "$wt14" && git rev-parse --show-toplevel)"
check "$(get_kv "$out14" himmel_dir)" "$wt14_toplevel" "T14 himmel_dir is still the branch/worktree (himmel lane, just no delegation needed)"
check "$(grep -c '"kind":"delegation"' "$ledger13" 2>/dev/null)" "1" "T14 still exactly one delegation row total (T13's, none added)"

# T15. adopter lane NEVER delegates, even with a diff that itself touches a
# path named scripts/cr/ -- the lane check short-circuits before the diff is
# ever inspected. A totally unrelated repo, anchored at fake-himmel13.
repo15="$tmp/adopter-repo"
mkdir -p "$repo15/scripts/cr"
(
  cd "$repo15" || exit 1
  git init -q -b main .
  git config user.email t@t
  git config user.name t
  git config commit.gpgsign false
  git commit -q --allow-empty -m init
  git checkout -q -b t15-adopter
  printf 'x\n' > scripts/cr/whatever.sh
  git add -A
  git commit -q -m "adopter's own scripts/cr change"
)
out15="$(cd "$repo15" && HIMMEL_REPO="$anchor13" bash "$anchor13/scripts/cr/pr-check-context.sh")"
rc15=$?
check "$rc15" "0" "T15 rc"
check "$(get_kv "$out15" anchor_lane)" "adopter" "T15 anchor_lane=adopter (unrelated repo)"
check "$(get_kv "$out15" delegated)" "no" "T15 delegated=no (adopter lane never delegates)"
check "$(get_kv "$out15" himmel_dir)" "$anchor13" "T15 himmel_dir is the anchor, never the reviewed repo"
check "$(grep -c '"kind":"delegation"' "$ledger13" 2>/dev/null)" "1" "T15 still exactly one delegation row total (adopter lane added none)"

# T16. HIMMEL_REPO set-but-EMPTY -> exit 2 with the named message.
out16="$(cd "$wt13" && HIMMEL_REPO="" bash "$anchor13/scripts/cr/pr-check-context.sh" 2>"$tmp/t16.err")"
rc16=$?
check "$rc16" "2" "T16 rc (fail-closed, empty HIMMEL_REPO)"
check "$out16" "" "T16 no stdout on the fail-closed path"
grep -q 'HIMMEL_REPO is unset or empty' "$tmp/t16.err" || { echo "FAIL: T16 missing the named empty-anchor diagnostic"; fail=1; }

# T17. HIMMEL-2378 CR round 1 [codex-1]: PR_CHECK_ANCHOR_DELEGATED preset to
# a bare anchor path (the round-4 "verified-handshake" shape) no longer
# verifies AT ALL - the legacy acceptance was removed (see the header
# comment "Identity handshake, not a boolean" and the `*)` arm of the
# case). This pins the CONVERGENCE the removal costs, so nobody re-adds the
# legacy arm later without seeing what it costs: a bare-path value fails to
# verify -> this run (himmel lane, diff touching scripts/cr/, own script
# present) re-delegates ITSELF -> the fresh hop mints the new shape and its
# own delegate verifies that -> exactly ONE extra ledger row, delegated=yes
# still ends up true, himmel_dir still ends up the branch - converged,
# logged, never infinite. NOTE: this used to preset a bare `1` before
# HIMMEL-2335 round 4 closed that unsafe-boolean shape; it was changed to
# the real anchor path to test round 4's (now-removed) legacy acceptance
# instead. The bare-`1`/spoofed-guard shape is covered by the T20 case.
before17="$(grep -c '"kind":"delegation"' "$ledger13" 2>/dev/null || echo 0)"
out17="$(cd "$wt13" && HIMMEL_REPO="$anchor13" PR_CHECK_ANCHOR_DELEGATED="$anchor13" bash "$anchor13/scripts/cr/pr-check-context.sh")"
rc17=$?
after17="$(grep -c '"kind":"delegation"' "$ledger13" 2>/dev/null || echo 0)"
check "$rc17" "0" "T17 rc"
check "$(get_kv "$out17" delegated)" "yes" "T17 delegated=yes - converges via the fresh hop's own genuine delegation, not the legacy shape (which no longer verifies at all)"
check "$(get_kv "$out17" anchor_lane)" "himmel" "T17 anchor_lane=himmel"
check "$(get_kv "$out17" himmel_dir)" "$wt13_toplevel" "T17 himmel_dir is the branch (the converged, genuinely-logged delegation)"
check "$after17" "$((before17 + 1))" "T17 EXACTLY ONE additional delegation row - the cost of the removed legacy acceptance converging through one extra hop, pinned so a future revert of codex-1 is caught here"

# T17 RED: reinstate the legacy acceptance (the exact shape codex-1 removed)
# and rerun the SAME preset - the bare anchor path must go back to verifying
# IMMEDIATELY (zero additional rows), proving T17's "+1 row" assertion above
# is real evidence that the legacy arm is gone, not a coincidence of some
# other code path.
mutant_legacy="$tmp/pr-check-context.mutant-legacy.sh"
# shellcheck disable=SC2016  # literal match against pr-check-context.sh's own
# source text (unexpanded $vars) - not a shell expansion.
literal_replace "$SCRIPT" "$mutant_legacy" \
  '        # still logged, never unlogged, never infinite.
        ;;' \
  '        # still logged, never unlogged, never infinite.
        if [ -d "$guard_val" ] && [ -d "$anchor" ]; then
            ! [ "$guard_val" -ef "$anchor" ] || verified_delegate=yes
        elif [ "$guard_val" = "$anchor" ]; then
            verified_delegate=yes
        fi
        ;;'
rc_lr1=$?
if [ "$rc_lr1" -ne 0 ]; then
  echo "FAIL: T17 could not build the legacy-reinstated mutant - $(cat "$tmp/literal_replace.err" 2>/dev/null)"
  fail=1
fi
# This is a pure INSERTION (the matched comment+;; pair is kept, 5 lines of
# legacy-accept logic are added before the ;;), so diff reports it as an
# "a" (append) hunk with 5 "> " lines and ZERO "< " lines - not a
# replacement like the other mutants' sanity checks above.
check "$(diff "$SCRIPT" "$mutant_legacy" | grep -c '^> ')" "5" "T17 sanity - the legacy-reinstated mutant differs from the real script by exactly 5 inserted lines (the round-4 legacy-accept body, re-added before the matched comment+;; pair)"
cp "$mutant_legacy" "$anchor13/scripts/cr/pr-check-context.sh"
rows_before17r="$(grep -c '"kind":"delegation"' "$ledger13" 2>/dev/null || echo 0)"
red_control_run --cwd "$wt13" \
  --env HIMMEL_REPO="$anchor13" \
  --env PR_CHECK_ANCHOR_DELEGATED="$anchor13" \
  -- bash "$anchor13/scripts/cr/pr-check-context.sh"
rows_after17r="$(grep -c '"kind":"delegation"' "$ledger13" 2>/dev/null || echo 0)"
red_control_assert --label "T17" \
  --observed     "delegated=$(get_kv "$RED_CONTROL_OUT" delegated) rows_added=$((rows_after17r - rows_before17r))" \
  --expect-wrong "delegated=yes rows_added=0" \
  --correct      "delegated=yes rows_added=1" \
  --note "with the legacy arm reinstated the bare anchor path verifies IMMEDIATELY again, proving T17's +1-row pin above only holds because codex-1 actually removed that arm" \
  || fail=1
cp "$SCRIPT" "$anchor13/scripts/cr/pr-check-context.sh"

# --- T18: HIMMEL-2335 round 2 - bootstrap defect. The ANCHOR's own
# ledger-append.sh does not support the "delegation" kind yet (the real
# scenario: the primary checkout is OLDER than this branch, which is what
# ADDS the "delegation" kind - so ANY branch that both introduces a new
# ledger kind and delegates hits this, and it is not a contrived fixture).
# The ledger write therefore fails, but that must NOT abort the whole gate
# (exit 2) any more - it must decline to delegate, warn loudly, and let the
# anchor's own (trusted, conservative) code produce the context normally.
anchor18="$tmp/fake-himmel-bootstrap"
build_fake_himmel "$anchor18"
# Overwrite the anchor's ledger-append.sh with a stub mirroring the REAL
# refusal a pre-HIMMEL-2335 ledger-append.sh gives for an unknown kind (see
# the literal message in scripts/cr/ledger-append.sh's own case statement) -
# the exact bootstrap symptom this fix exists for.
cat > "$anchor18/scripts/cr/ledger-append.sh" <<'STUB'
#!/usr/bin/env bash
echo "ledger-append.sh: kind must be finding|avail|usage|amend|attempt" >&2
exit 2
STUB
ledger18="$anchor18/.git/cr-critic-scores.jsonl"

wt18="$tmp/fake-himmel-bootstrap-wt"
(cd "$anchor18" && git worktree add -q -b t18-touch "$wt18" main) || { echo "FAIL: T18 could not add worktree"; fail=1; }
(
  cd "$wt18" || exit 1
  printf '# t18 touch\n' >> scripts/cr/critic-panel.sh
  git add -A
  git commit -q -m "touch scripts/cr"
)
head18="$(cd "$wt18" && git rev-parse HEAD)"
wt18_toplevel="$(cd "$wt18" && git rev-parse --show-toplevel)"
out18="$(cd "$wt18" && HIMMEL_REPO="$anchor18" bash "$anchor18/scripts/cr/pr-check-context.sh" 2>"$tmp/t18.err")"
rc18=$?
check "$rc18" "0" "T18 rc (warn-and-continue, NOT abort, when the anchor's ledger-append.sh cannot log a delegation)"
check "$(get_kv "$out18" delegated)" "no" "T18 delegated=no (declined to delegate rather than delegate unlogged)"
check "$(get_kv "$out18" anchor_lane)" "himmel" "T18 anchor_lane=himmel"
for key in himmel_dir repo branch head base marker lane anchor_lane delegated; do
  count="$(printf '%s\n' "$out18" | grep -c "^pr-check-context: $key=")"
  check "$count" "1" "T18 $key still appears exactly once (full context block still printed on stdout)"
done
check "$(get_kv "$out18" head)" "$head18" "T18 head matches the worktree HEAD (ran the anchor's own path, not a delegate)"
grep -qi 'WARNING' "$tmp/t18.err" || { echo "FAIL: T18 missing the WARNING diagnostic on stderr"; fail=1; }

# T19. HIMMEL-2335 round 3 - on the soft-decline path himmel_dir must be the
# ANCHOR, not the branch/worktree: every later /pr-check fence substitutes
# himmel_dir to locate the scripts/cr/ it runs, so leaving it pointed at the
# branch would mean the branch's own (unlogged, un-self-reviewed) scripts/cr/
# executes anyway - exactly what the WARNING above claims did NOT happen.
# Negative control: T14 above (himmel lane, diff does NOT touch scripts/cr/)
# already asserts himmel_dir is still the BRANCH path on that fixture, so
# this assertion cannot pass no matter what himmel_dir is - it is only
# satisfied when the soft-decline path specifically falls back to the anchor.
check "$(get_kv "$out18" himmel_dir)" "$anchor18" "T19 himmel_dir falls back to the ANCHOR on the soft-decline path (branch's scripts/cr/ must not execute unlogged)"

# T18 zero-rows assertion: the failed ledger write must not have left ANY
# delegation row behind (the file may not even exist).
rows18="$(grep -c '"kind":"delegation"' "$ledger18" 2>/dev/null || echo 0)"
check "$rows18" "0" "T18 zero delegation rows written (declined delegation is not logged as one)"

# Positive control for the assertion above: prove the SAME counting
# instrument (grep -c '"kind":"delegation"' on a cr-critic-scores.jsonl-shaped
# file) returns non-zero on a known-match input, so "0 rows" above is
# evidence of nothing having been written, not a broken/miswired counter.
pos_control="$tmp/t18-positive-control.jsonl"
printf '{"kind":"delegation","branch":"positive-control","head":"deadbeef"}\n' > "$pos_control"
check "$(grep -c '"kind":"delegation"' "$pos_control" 2>/dev/null)" "1" "T18 positive control - the delegation-row counter detects a known match"

# --- T20-T21: HIMMEL-2335 round 4 (CR panel [codex-2]) - the recursion guard
# is an anchor-identity HANDSHAKE, not a bare boolean. Before this fix, the
# precondition to even attempt delegation was `[ -z "$PR_CHECK_ANCHOR_DELEGATED" ]`
# - so ANY pre-existing non-empty value (a stray export, a leftover from an
# earlier run, a hostile launching shell) skipped the whole delegation IF
# block AND, via the separate `[ -z ... ] || delegated=yes` line at the
# bottom, still printed delegated=yes - all while himmel_dir stayed the
# BRANCH (unconditional, set during lane detection before delegation is even
# considered) and ZERO ledger rows were written. That is precisely the
# trusted-anchor invariant bypassed with no ledger record, while the output
# asserts the opposite.
# T20 reuses wt13/anchor13 (still on the himmel lane, still touching
# scripts/cr/, per T13 above) and presets PR_CHECK_ANCHOR_DELEGATED=1 - a
# foreign/bare value - to simulate exactly that pollution.
rows_before20="$(grep -c '"kind":"delegation"' "$ledger13" 2>/dev/null || echo 0)"
out20="$(cd "$wt13" && HIMMEL_REPO="$anchor13" PR_CHECK_ANCHOR_DELEGATED=1 bash "$anchor13/scripts/cr/pr-check-context.sh" 2>"$tmp/t20.err")"
rc20=$?
rows_after20="$(grep -c '"kind":"delegation"' "$ledger13" 2>/dev/null || echo 0)"
rows_added20=$((rows_after20 - rows_before20))
check "$rc20" "0" "T20 rc"
d20="$(get_kv "$out20" delegated)"
hd20="$(get_kv "$out20" himmel_dir)"
# The core assertion: the EXACT dangerous combination the finding describes
# (branch himmel_dir + delegated=yes + ZERO new ledger rows) must NEVER
# occur, no matter which of the two safe paths (real delegation vs.
# soft-decline) this run actually takes.
if [ "$hd20" = "$wt13_toplevel" ] && [ "$d20" = "yes" ] && [ "$rows_added20" -eq 0 ]; then
  echo "FAIL: T20 the exact vulnerable combination occurred - branch himmel_dir + delegated=yes + zero ledger rows"
  fail=1
else
  echo "T20 confirmed: the vulnerable combination (branch himmel_dir + delegated=yes + 0 rows) did not occur (himmel_dir=$hd20 delegated=$d20 rows_added=$rows_added20)"
fi
# Every OTHER outcome for this run must be one of the two safe, logged
# paths: a real delegation (delegated=yes, exactly one new ledger row,
# himmel_dir the branch) or a soft-decline (delegated=no, himmel_dir the
# anchor, WARNING on stderr) - never anything else.
if [ "$d20" = "yes" ]; then
  check "$rows_added20" "1" "T20 delegated=yes path wrote exactly one new ledger row (real, logged delegation - the spoofed value was ignored, not treated as a match)"
  check "$hd20" "$wt13_toplevel" "T20 delegated=yes path's himmel_dir is the branch (consistent with a genuine delegation)"
elif [ "$d20" = "no" ]; then
  check "$hd20" "$anchor13" "T20 delegated=no path's himmel_dir fell back to the anchor (soft-decline)"
  grep -qi 'WARNING' "$tmp/t20.err" || { echo "FAIL: T20 delegated=no path missing the WARNING diagnostic on stderr"; fail=1; }
else
  echo "FAIL: T20 delegated= printed neither yes nor no ('$d20')"; fail=1
fi

# T21. HIMMEL-2378 CR round 1 [codex-1]: repeat of T17's exact preset (bare
# anchor path, still refused) on a LATER invocation, to prove the refusal is
# consistent across repeated presentations, not a one-off - each bare-path
# presentation converges through its OWN fresh extra hop and adds its OWN
# new row (T17's mint/consume from its own hop is long since spent). This
# also still serves T20's original negative-control role: T28 elsewhere
# proves delegated=yes CAN legitimately happen (genuine NEW-format
# capability), so T20's delegated=no there is not vacuous either.
rows_before21="$(grep -c '"kind":"delegation"' "$ledger13" 2>/dev/null || echo 0)"
out21="$(cd "$wt13" && HIMMEL_REPO="$anchor13" PR_CHECK_ANCHOR_DELEGATED="$anchor13" bash "$anchor13/scripts/cr/pr-check-context.sh")"
rc21=$?
rows_after21="$(grep -c '"kind":"delegation"' "$ledger13" 2>/dev/null || echo 0)"
check "$rc21" "0" "T21 rc"
check "$(get_kv "$out21" delegated)" "yes" "T21 delegated=yes - converges via its OWN fresh hop, same as T17 (the legacy shape still does not verify)"
check "$(get_kv "$out21" anchor_lane)" "himmel" "T21 anchor_lane=himmel"
check "$rows_after21" "$((rows_before21 + 1))" "T21 exactly one ADDITIONAL new row (a second, independent convergence, not a re-use of T17's)"

# --- T22: HIMMEL-2335 round 5 (CR panel [codex-1]) - a FAILED merge-base
# (not just an unrelated diff) must ALSO fall back to himmel_dir=ANCHOR, the
# same fallback T19 above proved for the soft-decline (failed ledger write)
# path. Before this fix, the merge-base-failure branch set touches_cr=0 and
# fell straight through the `if [ "$touches_cr" -gt 0 ]` block WITHOUT ever
# reaching the `himmel_dir="$anchor"` line - so himmel_dir stayed the BRANCH,
# and every later /pr-check fence would run the branch's own scripts/cr/
# UNLOGGED, on a diff this run admits it could not even compute. Fixture:
# an orphan branch in the SAME repo as main (git checkout --orphan) - no
# common ancestor, so `git merge-base HEAD main` genuinely fails (rc!=0),
# not merely a diff that happens to be empty.
anchor22="$tmp/fake-himmel-mb"
build_fake_himmel "$anchor22"
wt22="$tmp/fake-himmel-mb-wt"
(cd "$anchor22" && git worktree add -q -b t22-touch "$wt22" main) || { echo "FAIL: T22 could not add worktree"; fail=1; }
(
  cd "$wt22" || exit 1
  git checkout -q --orphan t22-orphan
  printf '# t22 orphan touch\n' >> scripts/cr/critic-panel.sh
  git add -A
  git commit -q -m "orphan: touch scripts/cr, no common ancestor with main"
)
# Sanity: merge-base against main genuinely fails on this fixture (proves the
# fixture forces the failure branch, not some other path).
if (cd "$wt22" && git merge-base HEAD main >/dev/null 2>&1); then
  echo "FAIL: T22 fixture is broken - merge-base HEAD main unexpectedly succeeded"
  fail=1
fi
out22="$(cd "$wt22" && HIMMEL_REPO="$anchor22" bash "$anchor22/scripts/cr/pr-check-context.sh" 2>"$tmp/t22.err")"
rc22=$?
check "$rc22" "0" "T22 rc"
check "$(get_kv "$out22" anchor_lane)" "himmel" "T22 anchor_lane=himmel"
check "$(get_kv "$out22" delegated)" "no" "T22 delegated=no (merge-base could not be computed, so never delegate on an unknown diff)"
# The core assertion: himmel_dir falls back to the ANCHOR on a merge-base
# FAILURE, not just on a known-non-touching diff. T14 above is the negative
# control - its diff DOES resolve cleanly and does NOT touch scripts/cr/, and
# it asserts himmel_dir stays the BRANCH there; this assertion cannot pass no
# matter what himmel_dir is unless the merge-base-failure path specifically
# now sets it to the anchor.
check "$(get_kv "$out22" himmel_dir)" "$anchor22" "T22 himmel_dir falls back to the ANCHOR when merge-base cannot be computed (see T14 negative control above for the branch-stays case)"
for key in himmel_dir repo branch head base marker lane anchor_lane delegated; do
  count="$(printf '%s\n' "$out22" | grep -c "^pr-check-context: $key=")"
  check "$count" "1" "T22 $key still appears exactly once (full context block still printed on stdout)"
done
grep -q 'could not compute merge-base' "$tmp/t22.err" || { echo "FAIL: T22 missing the merge-base-failure diagnostic on stderr"; fail=1; }

# --- T23: HIMMEL-2335 round 6 - single end-of-decision assertion. Three
# separate CR findings (soft-decline/T18-19, spoofed guard/T20, merge-base
# failure/T22) were each patched independently in their own branch of the
# delegation `if`. This consolidates them: the diff state is now TRI-STATE
# (cr_diff_state=no|yes|unknown) and exactly ONE assertion at the end of the
# decision - not three scattered `himmel_dir="$anchor"` patches - is what
# guarantees the branch's own scripts/cr/ never runs unlogged. T23a-e below
# drive every branch of that assertion through the fixtures/outputs already
# built above (same tmp dir, sequential script, still in scope) rather than
# rebuilding them, to show the SAME single check now covers all five cases.
echo "--- T23: single end-of-decision assertion, all branches ---"

# T23a. cr_diff_state=no -> himmel_dir stays BRANCH. This is exactly T14's
# fixture and assertion above - kept intact there, referenced (not
# duplicated) here.
check "$(get_kv "$out14" himmel_dir)" "$wt14_toplevel" "T23a cr_diff_state=no -> himmel_dir BRANCH (T14's fixture)"

# T23b. cr_diff_state=yes + verified delegation -> himmel_dir BRANCH,
# delegated=yes, exactly one ledger row. T13's fixture/outputs.
check "$(get_kv "$out13" himmel_dir)" "$wt13_toplevel" "T23b yes+verified -> himmel_dir BRANCH (T13's fixture)"
check "$(get_kv "$out13" delegated)" "yes" "T23b yes+verified -> delegated=yes (T13's fixture)"
# "exactly one ledger row" for this case is T13's own check above (line 300)
# at the point right after T13 ran - NOT re-asserted here, since T20 below
# (a DIFFERENT yes+verified delegation, on the spoofed-guard fixture that
# falls through to a real logged delegation) legitimately adds a second row
# to this same $ledger13 file before T23 runs.

# T23c. cr_diff_state=yes + ledger write failed -> himmel_dir ANCHOR,
# delegated=no, WARNING on stderr. T18/T19's fixture/outputs.
check "$(get_kv "$out18" himmel_dir)" "$anchor18" "T23c yes+ledger-fail -> himmel_dir ANCHOR (T18/T19's fixture)"
check "$(get_kv "$out18" delegated)" "no" "T23c yes+ledger-fail -> delegated=no (T18's fixture)"
grep -qi WARNING "$tmp/t18.err" || { echo "FAIL: T23c missing WARNING on stderr (T18's fixture)"; fail=1; }

# T23d. cr_diff_state=yes + spoofed guard (PR_CHECK_ANCHOR_DELEGATED=1) ->
# never the vulnerable combination (BRANCH + delegated=yes + zero new ledger
# rows). T20's fixture/outputs (hd20/d20/rows_added20 computed above).
if [ "$hd20" = "$wt13_toplevel" ] && [ "$d20" = "yes" ] && [ "$rows_added20" -eq 0 ]; then
  echo "FAIL: T23d the vulnerable spoofed-guard combination occurred (T20's fixture)"
  fail=1
else
  echo "T23d confirmed: spoofed guard never produced BRANCH+delegated=yes+0-rows (T20's fixture)"
fi

# T23e. unknown (merge-base fails) -> himmel_dir ANCHOR. T22's fixture/outputs.
check "$(get_kv "$out22" himmel_dir)" "$anchor22" "T23e unknown -> himmel_dir ANCHOR (T22's fixture)"

# T23f. Anti-vacuity: prove the final assertion is actually load-bearing, not
# a no-op that happens to agree with the other five checks above. Build a
# MUTANT copy of the real script with ONLY the final assertion's forcing
# assignment (`himmel_dir="$anchor"` inside the `if [ "$himmel_dir_is_anchor"
# = no ] && ...` block) neutered into a no-op comment - everything else,
# including the WARNING echo right before it, is untouched - then rerun the
# T18 ledger-write-failure fixture (himmel_dir starts at the BRANCH,
# cr_diff_state=yes, delegation NOT verified, ledger NOT written - exactly
# the case the brief calls out) against the mutant. Locate the assignment by
# searching WITHIN the final assertion's own if-block (bounded by its
# distinctive `himmel_dir_is_anchor" = no` condition and the next `fi`), not
# by line number or a bare text match, since the script has a SECOND,
# unrelated himmel_dir="$anchor" line (the adopter-lane assignment) that
# must NOT be touched - neutering that one instead would prove nothing.
mutant="$tmp/pr-check-context.mutant.sh"
# 'cr_diff_state" != no' (not 'himmel_dir_is_anchor" = no'): the latter also
# matches the EARLIER, unrelated outer-delegation-block guard
# (`[ "$anchor_lane" = "himmel" ] && [ "$himmel_dir_is_anchor" = no ]`), so
# head -1 on that pattern would grab the wrong if-block (one with no
# himmel_dir="$anchor" line inside it any more, post-fix) and this whole
# block would silently no-op. 'cr_diff_state" != no' appears exactly once in
# the file, only in the final assertion's own condition.
start_line="$(grep -n 'cr_diff_state" != no' "$SCRIPT" | head -1 | cut -d: -f1)"
if [ -n "$start_line" ]; then
  end_line="$(awk -v s="$start_line" 'NR>=s && /^fi$/ { print NR; exit }' "$SCRIPT")"
  assign_line="$(awk -v s="$start_line" -v e="$end_line" 'NR>=s && NR<=e && /himmel_dir="\$anchor"/ { print NR; exit }' "$SCRIPT")"
else
  assign_line=""
fi
if [ -n "$assign_line" ]; then
  sed "${assign_line}s/.*/    : # T23f mutant: neutered/" "$SCRIPT" > "$mutant"
else
  # No such line found (e.g. the assertion does not exist yet, pre-fix) -
  # write an unmodified copy so the sanity check below fails LOUDLY (0
  # neutered lines) instead of this block silently skipping T23f.
  cp "$SCRIPT" "$mutant"
fi
neutered_count="$(diff "$SCRIPT" "$mutant" | grep -c '^< ')"
check "$neutered_count" "1" "T23f sanity - the mutant differs from the real script by exactly ONE neutered line (the final assertion's forcing assignment, found structurally, not the adopter-lane one)"
# Install the mutant AS anchor18's own scripts/cr/pr-check-context.sh (not a
# bare copy elsewhere): the script self-locates HIMMEL_ROOT from `dirname
# "$0"`, so running it from outside a scripts/cr/ layout would abort at the
# critic-panel.sh check before ever reaching the assertion; and re-anchoring
# at a FRESH directory would flip anchor_lane to adopter (wt18 is a worktree
# of anchor18 specifically, matched by git-common-dir), which would force
# himmel_dir to the anchor unconditionally and prove nothing about the
# mutation. Nothing later in this suite still depends on anchor18's own
# pr-check-context.sh being unmodified, so overwriting it in place is safe.
cp "$mutant" "$anchor18/scripts/cr/pr-check-context.sh"
out23f="$(cd "$wt18" && HIMMEL_REPO="$anchor18" bash "$anchor18/scripts/cr/pr-check-context.sh" 2>/dev/null)"
mutant_himmel_dir="$(get_kv "$out23f" himmel_dir)"
if [ "$mutant_himmel_dir" = "$wt18_toplevel" ]; then
  echo "T23f confirmed: WITHOUT the final assertion's forcing assignment, himmel_dir wrongly stays BRANCH ($mutant_himmel_dir) on the T18 ledger-write-failure fixture - proving the real script's assertion (not some other path) is what forces ANCHOR in T18/T23c above"
else
  echo "FAIL: T23f the mutant (assertion neutered) produced himmel_dir=$mutant_himmel_dir, expected BRANCH ($wt18_toplevel) to prove the assertion is load-bearing rather than a no-op"
  fail=1
fi

# --- T24: HIMMEL-2335 CR [codex-3] - an UNREADABLE diff (git diff itself
# fails), NOT a merge-base failure, must ALSO fall back to himmel_dir=ANCHOR.
# Distinct from T22 above (merge-base fails): here merge-base SUCCEEDS
# (asserted below, both before AND after the corruption) and it is
# specifically `git diff --name-only <mb>..HEAD` that cannot be read. Before
# this fix, a failed `git diff` printed nothing to stdout, `grep -c` on that
# empty stdout still returned 0 matches (its own exit status - and git diff's
# - was never checked), so cr_diff_state was misclassified "no", "proven
# clean" - the ONE state that lets the branch's own scripts/cr/ execute
# unlogged. Fixture: corrupt the loose tree object HEAD's commit points at
# (captured, then the object file removed) - `git merge-base` only walks
# commit objects (parent pointers), so it is unaffected, while
# `git diff --name-only` must read both endpoints' trees to compute the
# changed-path list and fails.
anchor24="$tmp/fake-himmel-diff-unreadable"
build_fake_himmel "$anchor24"
wt24="$tmp/fake-himmel-diff-unreadable-wt"
(cd "$anchor24" && git worktree add -q -b t24-touch "$wt24" main) || { echo "FAIL: T24 could not add worktree"; fail=1; }
(
  cd "$wt24" || exit 1
  printf '# t24 touch\n' >> scripts/cr/critic-panel.sh
  git add -A
  git commit -q -m "touch scripts/cr for diff-corruption fixture"
)
tree24="$(cd "$wt24" && git rev-parse "HEAD^{tree}")"
anchor24_git_dir="$(cd "$anchor24" && git rev-parse --path-format=absolute --git-common-dir)"
tree24_obj="$anchor24_git_dir/objects/${tree24:0:2}/${tree24:2}"
if [ ! -f "$tree24_obj" ]; then
  echo "FAIL: T24 fixture broken - could not locate loose tree object $tree24_obj to corrupt (repacked?)"
  fail=1
fi
# Sanity: merge-base against main genuinely SUCCEEDS on this fixture BEFORE
# corruption.
if ! (cd "$wt24" && git merge-base HEAD main >/dev/null 2>&1); then
  echo "FAIL: T24 fixture is broken - merge-base HEAD main unexpectedly failed before corruption"
  fail=1
fi
rm -f "$tree24_obj"
# Sanity: with the tree object gone, `git diff --name-only` on this fixture
# now genuinely fails, while merge-base still succeeds (same repo, same HEAD)
# - proves the corruption forces the DIFF-read failure specifically, not a
# merge-base failure like T22's fixture.
if (cd "$wt24" && git diff --name-only "$(git merge-base HEAD main)"..HEAD >/dev/null 2>&1); then
  echo "FAIL: T24 fixture is broken - git diff --name-only unexpectedly succeeded after tree corruption"
  fail=1
fi
if ! (cd "$wt24" && git merge-base HEAD main >/dev/null 2>&1); then
  echo "FAIL: T24 fixture is broken - merge-base HEAD main unexpectedly failed AFTER tree corruption (should be unaffected - it never reads tree objects)"
  fail=1
fi
out24="$(cd "$wt24" && HIMMEL_REPO="$anchor24" bash "$anchor24/scripts/cr/pr-check-context.sh" 2>"$tmp/t24.err")"
rc24=$?
check "$rc24" "0" "T24 rc"
check "$(get_kv "$out24" anchor_lane)" "himmel" "T24 anchor_lane=himmel"
check "$(get_kv "$out24" delegated)" "no" "T24 delegated=no (diff unreadable -> unknown -> never delegate)"
check "$(get_kv "$out24" himmel_dir)" "$anchor24" "T24 himmel_dir falls back to the ANCHOR when the diff itself cannot be read (distinct failure from T22's merge-base failure - see T14 negative control above for the branch-stays case)"
# Prove the DIFF-failure branch was taken, not the merge-base one (T22's
# path) - the two diagnostics are mutually exclusive and this fixture must
# hit only the former, from stderr, so this test cannot pass via T22's path.
grep -q 'could not compute git diff --name-only' "$tmp/t24.err" || { echo "FAIL: T24 missing the diff-read-failure diagnostic on stderr"; fail=1; }
if grep -q 'could not compute merge-base' "$tmp/t24.err"; then
  echo "FAIL: T24 wrongly took the merge-base-failure branch instead of the diff-read-failure branch"
  fail=1
fi
for key in himmel_dir repo branch head base marker lane anchor_lane delegated; do
  count="$(printf '%s\n' "$out24" | grep -c "^pr-check-context: $key=")"
  check "$count" "1" "T24 $key still appears exactly once (full context block still printed on stdout)"
done

# --- T25: HIMMEL-2335 grep-q-pipe-under-pipefail red-before-green ----------
# Reproduces the SIGPIPE misclassification directly: when `git diff
# --name-only <mb>..HEAD` output exceeds the ~64 KiB pipe buffer, a
# `producer | grep -q pattern` guard under `set -o pipefail` can report the
# PIPELINE as non-zero even though the pattern DID match - grep exits at the
# first match and closes its end of the pipe, the producer (printf) is still
# mid-write and takes SIGPIPE, and pipefail propagates that as failure. That
# flips cr_diff_state from "yes" to "no" on a large diff that genuinely
# touches scripts/cr/ - and cr_diff_state=no is the ONE state that lets the
# final end-of-decision assertion (~line 452) leave himmel_dir pointed at the
# BRANCH without delegation ever being attempted or logged: the branch's own
# (possibly attacker-controlled) scripts/cr/ would then execute on every
# later /pr-check fence, unreviewed.
#
# Fixture: a real worktree of a fake-himmel anchor (same shape as T13) whose
# branch commit touches scripts/cr/critic-panel.sh, PLUS ~300 long-path blob
# entries added via git plumbing (hash-object/mktree/commit-tree/update-ref)
# so `git diff --name-only` exceeds 64 KiB. The extra paths are never
# materialized on the actual filesystem or checked out - only committed as
# tree/blob objects - so this sidesteps Windows' ~260-char MAX_PATH, which a
# real checkout of 250-char-plus filenames under a worktree path would hit
# well before the byte budget did.
anchor25="$anchor13"
wt25="$tmp/fake-himmel-wt-large"
(cd "$anchor25" && git worktree add -q -b t25-large "$wt25" main) || { echo "FAIL: T25 could not add worktree"; fail=1; }
(
  cd "$wt25" || exit 1
  printf '# t25 touch\n' >> scripts/cr/critic-panel.sh
  git add -A
  git commit -q -m "touch scripts/cr for T25"
  blob="$(git hash-object -w --stdin < /dev/null)"
  {
    git ls-tree HEAD
    for i in $(seq 1 300); do
      long_name="zzz_filler_$(printf '%03d' "$i")_$(printf 'x%.0s' $(seq 1 230))"
      printf '100644 blob %s\t%s\n' "$blob" "$long_name"
    done
  } | git mktree > "$tmp/t25-tree.txt"
  new_tree="$(cat "$tmp/t25-tree.txt")"
  new_commit="$(git commit-tree "$new_tree" -p HEAD -m "T25 large diff, never checked out")"
  git update-ref refs/heads/t25-large "$new_commit"
)
head25="$(cd "$wt25" && git rev-parse HEAD)"
diff_bytes="$(cd "$wt25" && git diff --name-only main...HEAD | wc -c)"
if [ "$diff_bytes" -le 65536 ]; then
  echo "FAIL: T25 fixture diff is only $diff_bytes bytes - need >65536 (64 KiB) to exercise the SIGPIPE window; the fixture itself is broken, not the assertion below"
  fail=1
else
  echo "T25 fixture sanity: diff is $diff_bytes bytes (>64 KiB), and genuinely touches scripts/cr/critic-panel.sh"
fi

out25="$(cd "$wt25" && HIMMEL_REPO="$anchor25" bash "$anchor25/scripts/cr/pr-check-context.sh" 2>"$tmp/t25.err")"
rc25=$?
check "$rc25" "0" "T25 rc"
wt25_toplevel="$(cd "$wt25" && git rev-parse --show-toplevel)"
d25="$(get_kv "$out25" delegated)"
hd25="$(get_kv "$out25" himmel_dir)"
# The vulnerable combination (same shape as T20/T23d's guard above): himmel_dir
# left at the BRANCH while delegated=no, on a diff that genuinely touches
# scripts/cr/. This is the exact misclassification the fix closes - assert it
# NEVER occurs.
if [ "$hd25" = "$wt25_toplevel" ] && [ "$d25" = "no" ]; then
  echo "FAIL: T25 the vulnerable combination occurred - himmel_dir stayed the BRANCH ($hd25) with delegated=no on a >64 KiB diff that genuinely touches scripts/cr/ - this is the grep-q-pipe-under-pipefail misclassification (cr_diff_state was flipped no when it should be yes)"
  fail=1
else
  echo "T25 confirmed: on a >64 KiB scripts/cr/-touching diff, himmel_dir did not stay BRANCH+delegated=no (himmel_dir=$hd25 delegated=$d25)"
fi
check "$(get_kv "$out25" anchor_lane)" "himmel" "T25 anchor_lane=himmel"
check "$(get_kv "$out25" head)" "$head25" "T25 head matches the worktree HEAD (the >64 KiB-diff commit, never the small pre-plumbing commit)"

# --- T26-T30: HIMMEL-2378 - the delegation capability is bound to (branch,
# head), not merely to the anchor's path, is one-time, AND (fixed after
# review: the capability file itself must be BRANCH-SCOPED, same reasoning
# as cr-prior-blocking/<branch> and cr-aggregate-verdicts/<branch> in
# write-verdicts.sh - "round 1b" there) safe under the concurrent /pr-check
# runs on independent branches this repo actually supports (overnight-shift).
# T20/T21 above proved round 4's fix (anchor-path equality) closes the
# BARE-BOOLEAN gap; T26-T29 prove the NARROWER temporal/identity gap round 4
# left open - a value that DOES equal the resolved anchor (the shape a
# genuine delegation now actually hands off,
# "$anchor|$branch|$head|$nonce") but was minted for a DIFFERENT branch or
# head, or has already been consumed, must still be rejected. T30 proves the
# concurrency property specifically: two concurrent mints for DIFFERENT
# branches must not collide. T26/T28/T29's fixtures preset
# PR_CHECK_ANCHOR_DELEGATED directly (same technique T17/T20/T21 already
# use) rather than driving a real delegation end to end, so the scenario is
# deterministic and isolated from $ledger13/$wt13 above; T30 does the same
# for its "concurrent mint" steps (direct writes, not two real overlapping
# processes - not needed to prove the file-collision property, and two
# genuinely racing background processes would make this suite flaky).
anchor26="$tmp/fake-himmel-cap"
build_fake_himmel "$anchor26"
git_dir26="$(cd "$anchor26" && git rev-parse --path-format=absolute --git-common-dir)"
ledger26="$anchor26/.git/cr-critic-scores.jsonl"

# write_cap <path> <branch> <head> <nonce> - mkdir -p the parent (a nested
# branch like fix/t26-cap needs cr-delegation/fix/ to exist first, exactly
# like the real mint site's own mkdir -p) then write the 3-field content a
# genuine mint would write. Used to preset fixtures directly, same posture
# as T17/T20/T21 presetting PR_CHECK_ANCHOR_DELEGATED directly.
write_cap() {
  mkdir -p "$(dirname "$1")" && printf '%s|%s|%s\n' "$2" "$3" "$4" > "$1"
}

# wt26: branch fix/t26-cap - deliberately NESTED (not flat) so T26's own
# real fresh-delegation below exercises the production mkdir -p for a
# nested branch, the same shape write-verdicts.sh already handles for
# cr-prior-blocking/<branch>. Two commits (headA26 then headB26), both
# touching scripts/cr/critic-panel.sh so cr_diff_state=yes throughout - a
# REJECTED handshake here must fall through to a fresh, logged delegation,
# never a silent bypass.
wt26="$tmp/fake-himmel-cap-wt"
(cd "$anchor26" && git worktree add -q -b fix/t26-cap "$wt26" main) || { echo "FAIL: T26-30 could not add wt26"; fail=1; }
(cd "$wt26" && printf '# t26 touch 1\n' >> scripts/cr/critic-panel.sh && git add -A && git commit -q -m "t26 touch 1")
headA26="$(cd "$wt26" && git rev-parse HEAD)"
(cd "$wt26" && printf '# t26 touch 2\n' >> scripts/cr/critic-panel.sh && git add -A && git commit -q -m "t26 touch 2")
headB26="$(cd "$wt26" && git rev-parse HEAD)"
wt26_toplevel="$(cd "$wt26" && git rev-parse --show-toplevel)"
cap_fix_t26cap="$git_dir26/cr-delegation/fix/t26-cap/$headB26"

# wt26b: a SECOND branch pointing at the SAME commit as headA26 (no new
# commit) - "same head, different branch", the other half of the binding,
# isolated from wt26's "same branch, different head" above.
(cd "$anchor26" && git branch -q t26-cap-b "$headA26")
wt26b="$tmp/fake-himmel-cap-wtb"
(cd "$anchor26" && git worktree add -q "$wt26b" t26-cap-b) || { echo "FAIL: T26-30 could not add wt26b"; fail=1; }
wt26b_toplevel="$(cd "$wt26b" && git rev-parse --show-toplevel)"
cap_t26capb="$git_dir26/cr-delegation/t26-cap-b/$headA26"

# wt28: branch t28-cap, diff does NOT touch scripts/cr/ (cr_diff_state=no) -
# used for T28/T29 so a REJECTED handshake there is NOT eligible for a fresh
# real delegation either, isolating the one-time/nonce assertion from any
# interaction with the normal delegation flow.
wt28="$tmp/fake-himmel-cap-wt28"
(cd "$anchor26" && git worktree add -q -b t28-cap "$wt28" main) || { echo "FAIL: T26-30 could not add wt28"; fail=1; }
(cd "$wt28" && printf 'unrelated\n' > README.md && git add -A && git commit -q -m "t28 unrelated")
head28="$(cd "$wt28" && git rev-parse HEAD)"
wt28_toplevel="$(cd "$wt28" && git rev-parse --show-toplevel)"
cap_t28cap="$git_dir26/cr-delegation/t28-cap/$head28"

# Three mutants of the FIXED script, each removing exactly one binding this
# fix adds, to prove each is load-bearing rather than the assertions below
# passing regardless of whether the check exists.
#
# mutant_nohead: neuter BOTH places this fix compares the incoming head to
# this run's own $head (the env-carried g_head at the outer `if`, and the
# file-recorded cf_head at the inner `if`) - reducing the capability to
# anchor+branch+nonce, no head-binding, which is what "just add a nonce"
# without binding it to the run would still leave.
mutant_nohead1="$tmp/pr-check-context.mutant-nohead-1.sh"
mutant_nohead="$tmp/pr-check-context.mutant-nohead.sh"
# shellcheck disable=SC2016  # literal match against pr-check-context.sh's own
# source text (unexpanded $vars) - not a shell expansion we want here.
literal_replace "$SCRIPT" "$mutant_nohead1" \
  '           && [ "$g_head" = "$head" ] && [ -f "$cap_file" ]; then' \
  '           && [ -f "$cap_file" ]; then'
rc_lr1=$?
# shellcheck disable=SC2016  # same as above - literal source text.
literal_replace "$mutant_nohead1" "$mutant_nohead" \
  '               && [ "$cf_branch" = "$branch" ] && [ "$cf_head" = "$head" ]; then' \
  '               && [ "$cf_branch" = "$branch" ]; then'
rc_lr2=$?
if [ "$rc_lr1" -ne 0 ] || [ "$rc_lr2" -ne 0 ]; then
  echo "FAIL: T26 could not build the no-head-binding mutant - $(cat "$tmp/literal_replace.err" 2>/dev/null)"
  fail=1
fi
check "$(diff "$SCRIPT" "$mutant_nohead" | grep -c '^< ')" "2" "T26 sanity - the no-head mutant differs from the real script by exactly 2 neutered lines (the env-side and file-side head checks)"

# mutant_nobranch: same technique, neutering the two branch comparisons
# instead of the two head comparisons above.
mutant_nobranch1="$tmp/pr-check-context.mutant-nobranch-1.sh"
mutant_nobranch="$tmp/pr-check-context.mutant-nobranch.sh"
# shellcheck disable=SC2016,SC1003  # literal match against pr-check-context.sh's
# own source text (unexpanded $vars and the trailing line-continuation
# backslash the real script's own line ends with) - not a shell expansion.
literal_replace "$SCRIPT" "$mutant_nobranch1" \
  '        if [ "$anchor_ok" = yes ] && [ "$g_branch" = "$branch" ] \' \
  '        if [ "$anchor_ok" = yes ] \'
rc_lr1=$?
# shellcheck disable=SC2016  # same as above - literal source text.
literal_replace "$mutant_nobranch1" "$mutant_nobranch" \
  '               && [ "$cf_branch" = "$branch" ] && [ "$cf_head" = "$head" ]; then' \
  '               && [ "$cf_head" = "$head" ]; then'
rc_lr2=$?
if [ "$rc_lr1" -ne 0 ] || [ "$rc_lr2" -ne 0 ]; then
  echo "FAIL: T27 could not build the no-branch-binding mutant - $(cat "$tmp/literal_replace.err" 2>/dev/null)"
  fail=1
fi
check "$(diff "$SCRIPT" "$mutant_nobranch" | grep -c '^< ')" "2" "T27 sanity - the no-branch mutant differs from the real script by exactly 2 neutered lines (the env-side and file-side branch checks)"

# mutant_noconsume: neuter the one-time consumption entirely - collapses the
# checked `if rm -f ...; then verified_delegate=yes; fi` (CR round 1
# [codex-3]) back to an unconditional accept that never touches the file.
mutant_noconsume="$tmp/pr-check-context.mutant-noconsume.sh"
# shellcheck disable=SC2016  # literal match against pr-check-context.sh's own
# source text (unexpanded $cap_file) - not a shell expansion.
literal_replace "$SCRIPT" "$mutant_noconsume" \
  '                if rm "$cap_file" 2>/dev/null; then
                    verified_delegate=yes
                fi' \
  '                verified_delegate=yes # T29 mutant: consumption neutered'
rc_lr1=$?
if [ "$rc_lr1" -ne 0 ]; then
  echo "FAIL: T29 could not build the no-consume mutant - $(cat "$tmp/literal_replace.err" 2>/dev/null)"
  fail=1
fi
check "$(diff "$SCRIPT" "$mutant_noconsume" | grep -c '^< ')" "3" "T29 sanity - the no-consume mutant differs from the real script by exactly 3 neutered lines (the checked if/rm/fi collapsed to an unconditional accept)"

# mutant_unscoped: revert the capability file back to the single SHARED path
# (pre-review-fix shape) - used only by T30 below to reproduce the
# concurrency defect a branch-scoped file closes.
mutant_unscoped="$tmp/pr-check-context.mutant-unscoped.sh"
# shellcheck disable=SC2016  # literal match against pr-check-context.sh's own
# source text (unexpanded $vars) - not a shell expansion.
literal_replace "$SCRIPT" "$mutant_unscoped" \
  'cap_file="$git_dir/cr-delegation/$branch/$head"' \
  'cap_file="$git_dir/cr-delegation-capability"'
rc_lr1=$?
if [ "$rc_lr1" -ne 0 ]; then
  echo "FAIL: T30 could not build the unscoped-capability-file mutant - $(cat "$tmp/literal_replace.err" 2>/dev/null)"
  fail=1
fi
check "$(diff "$SCRIPT" "$mutant_unscoped" | grep -c '^< ')" "1" "T30 sanity - the unscoped mutant differs from the real script by exactly 1 neutered line (branch-scoping reverted)"

# mutant_ledger_first: HIMMEL-2378 CR round 1 [codex-2] - bypass the
# capability-write gate entirely (`if true; then` instead of the real
# `mkdir -p ... && printf ... > "$cap_file"` condition), so the
# ledger-append call and exec attempt run UNCONDITIONALLY, exactly
# reproducing the pre-review-fix ordering's observable effect: a
# `delegation` row gets logged (and ledger_written=yes gets set) even when
# the capability file was never actually written - used only by T32 below.
mutant_ledger_first="$tmp/pr-check-context.mutant-ledger-first.sh"
# shellcheck disable=SC2016  # literal match against pr-check-context.sh's own
# source text (unexpanded $vars) - not a shell expansion.
literal_replace "$SCRIPT" "$mutant_ledger_first" \
  '        if mkdir -p "$(dirname "$cap_file")" 2>/dev/null \
           && printf '"'"'%s|%s|%s\n'"'"' "$branch" "$head" "$cap_nonce" > "$cap_file"; then' \
  '        if true; then'
rc_lr1=$?
if [ "$rc_lr1" -ne 0 ]; then
  echo "FAIL: T32 could not build the ledger-first mutant - $(cat "$tmp/literal_replace.err" 2>/dev/null)"
  fail=1
fi
check "$(diff "$SCRIPT" "$mutant_ledger_first" | grep -c '^< ')" "2" "T32 sanity - the ledger-first mutant differs from the real script by exactly 2 neutered lines (the write-gate condition collapsed to \`true\`)"

# T26. Stale HEAD rejected: a capability CONTENT claiming headA26 (nonce
# n1, unconsumed), written into wt26's OWN real per-(branch,head) slot
# (cap_fix_t26cap, now scoped by CR round 3 [codex-1] to
# cr-delegation/fix/t26-cap/<headB26> - wt26's actual current head) -
# same "right slot, wrong content" isolation technique T27 below already
# uses for the branch field, applied here to the head field so this test
# is not trivially satisfied by path-scoping alone (see T33 for that).
n1="cap-nonce-t26-stale-head"
write_cap "$cap_fix_t26cap" "fix/t26-cap" "$headA26" "$n1"
rows_before26="$(grep -c '"kind":"delegation"' "$ledger26" 2>/dev/null || echo 0)"
out26="$(cd "$wt26" && HIMMEL_REPO="$anchor26" PR_CHECK_ANCHOR_DELEGATED="$anchor26|fix/t26-cap|$headA26|$n1" bash "$anchor26/scripts/cr/pr-check-context.sh" 2>"$tmp/t26.err")"
rc26=$?
rows_after26="$(grep -c '"kind":"delegation"' "$ledger26" 2>/dev/null || echo 0)"
rows_added26=$((rows_after26 - rows_before26))
check "$rc26" "0" "T26 rc"
d26="$(get_kv "$out26" delegated)"
hd26="$(get_kv "$out26" himmel_dir)"
# The vulnerable combination the ticket describes - branch himmel_dir +
# delegated=yes + zero new ledger rows, i.e. the stale value silently
# accepted - must NEVER occur on the real (fixed) script.
if [ "$hd26" = "$wt26_toplevel" ] && [ "$d26" = "yes" ] && [ "$rows_added26" -eq 0 ]; then
  echo "FAIL: T26 the vulnerable combination occurred - stale-head capability was silently accepted (branch himmel_dir + delegated=yes + zero new ledger rows)"
  fail=1
fi
# Stronger than the disjunctive T20-style check above: this fixture's
# ledger-append.sh is a good copy, so rejection MUST fall through to a
# fresh, logged delegation (not a soft-decline) - assert that specific,
# deterministic outcome.
check "$d26" "yes" "T26 rejection falls through to a FRESH delegation (delegated=yes, the stale nonce was ignored, not treated as a match)"
check "$rows_added26" "1" "T26 that fresh delegation wrote exactly one new (correctly logged) ledger row"
check "$hd26" "$wt26_toplevel" "T26 himmel_dir is the branch (consistent with the fresh, genuine delegation)"
check "$(get_kv "$out26" head)" "$headB26" "T26 head matches the worktree's actual (advanced) HEAD - confirms the replayed capability really was stale relative to it, not merely a different-looking string"

# T26 RED: rewrite the SAME stale capability (still headA26/n1, unconsumed)
# and rerun against mutant_nohead - without head-binding this must reproduce
# exactly the vulnerable combination T26 above proved never occurs on the
# real script.
write_cap "$cap_fix_t26cap" "fix/t26-cap" "$headA26" "$n1"
cp "$mutant_nohead" "$anchor26/scripts/cr/pr-check-context.sh"
rows_before26r="$(grep -c '"kind":"delegation"' "$ledger26" 2>/dev/null || echo 0)"
red_control_run --cwd "$wt26" \
  --env HIMMEL_REPO="$anchor26" \
  --env PR_CHECK_ANCHOR_DELEGATED="$anchor26|fix/t26-cap|$headA26|$n1" \
  -- bash "$anchor26/scripts/cr/pr-check-context.sh"
rows_after26r="$(grep -c '"kind":"delegation"' "$ledger26" 2>/dev/null || echo 0)"
red_control_assert --label "T26" \
  --observed     "himmel_dir=$(get_kv "$RED_CONTROL_OUT" himmel_dir) delegated=$(get_kv "$RED_CONTROL_OUT" delegated) rows_added=$((rows_after26r - rows_before26r))" \
  --expect-wrong "himmel_dir=$wt26_toplevel delegated=yes rows_added=0" \
  --correct      "himmel_dir=$wt26_toplevel delegated=yes rows_added=1" \
  --note "without head-binding the stale-head capability IS silently accepted - the vulnerable combination T26 above proves never occurs on the real script" \
  || fail=1
cp "$SCRIPT" "$anchor26/scripts/cr/pr-check-context.sh"

# T27. Stale BRANCH rejected: a capability claiming branch fix/t26-cap at
# headA26 (nonce n2), written into wt26b's OWN branch-scoped slot
# (cap_t26capb) - i.e. a file that exists at exactly the path the real
# script will look at (SAME head too, headA26 == wt26b's actual head), but
# whose recorded/claimed branch does not match wt26b's actual branch
# (t26-cap-b). This isolates the g_branch/cf_branch FIELD checks from the
# file-PATH scoping itself (a capability minted for a genuinely different
# branch would usually land in a genuinely different, non-existent slot -
# see T30 below for that path-level property; this fixture instead proves
# the field checks catch a mismatch even when the file happens to sit in
# the right slot, e.g. a stale copy/rename).
n2="cap-nonce-t27-stale-branch"
write_cap "$cap_t26capb" "fix/t26-cap" "$headA26" "$n2"
rows_before27="$(grep -c '"kind":"delegation"' "$ledger26" 2>/dev/null || echo 0)"
out27="$(cd "$wt26b" && HIMMEL_REPO="$anchor26" PR_CHECK_ANCHOR_DELEGATED="$anchor26|fix/t26-cap|$headA26|$n2" bash "$anchor26/scripts/cr/pr-check-context.sh" 2>"$tmp/t27.err")"
rc27=$?
rows_after27="$(grep -c '"kind":"delegation"' "$ledger26" 2>/dev/null || echo 0)"
rows_added27=$((rows_after27 - rows_before27))
check "$rc27" "0" "T27 rc"
d27="$(get_kv "$out27" delegated)"
hd27="$(get_kv "$out27" himmel_dir)"
if [ "$hd27" = "$wt26b_toplevel" ] && [ "$d27" = "yes" ] && [ "$rows_added27" -eq 0 ]; then
  echo "FAIL: T27 the vulnerable combination occurred - stale-branch capability was silently accepted"
  fail=1
fi
check "$d27" "yes" "T27 rejection falls through to a FRESH delegation (delegated=yes, the stale-branch nonce was ignored, not treated as a match)"
check "$rows_added27" "1" "T27 that fresh delegation wrote exactly one new (correctly logged) ledger row"
check "$hd27" "$wt26b_toplevel" "T27 himmel_dir is the branch (consistent with the fresh, genuine delegation)"

# T27 RED: same capability, still unconsumed, against mutant_nobranch.
write_cap "$cap_t26capb" "fix/t26-cap" "$headA26" "$n2"
cp "$mutant_nobranch" "$anchor26/scripts/cr/pr-check-context.sh"
rows_before27r="$(grep -c '"kind":"delegation"' "$ledger26" 2>/dev/null || echo 0)"
red_control_run --cwd "$wt26b" \
  --env HIMMEL_REPO="$anchor26" \
  --env PR_CHECK_ANCHOR_DELEGATED="$anchor26|fix/t26-cap|$headA26|$n2" \
  -- bash "$anchor26/scripts/cr/pr-check-context.sh"
rows_after27r="$(grep -c '"kind":"delegation"' "$ledger26" 2>/dev/null || echo 0)"
red_control_assert --label "T27" \
  --observed     "himmel_dir=$(get_kv "$RED_CONTROL_OUT" himmel_dir) delegated=$(get_kv "$RED_CONTROL_OUT" delegated) rows_added=$((rows_after27r - rows_before27r))" \
  --expect-wrong "himmel_dir=$wt26b_toplevel delegated=yes rows_added=0" \
  --correct      "himmel_dir=$wt26b_toplevel delegated=yes rows_added=1" \
  --note "without branch-binding the stale-branch capability IS silently accepted - proving the two neutered branch checks are what T27 above relies on" \
  || fail=1
cp "$SCRIPT" "$anchor26/scripts/cr/pr-check-context.sh"

# T28. Genuine capability accepted - full round trip on the real script:
# fresh mint (branch/head/nonce all matching this run) verifies, and the
# capability file is CONSUMED (truncated) by that verification. wt28's diff
# does not touch scripts/cr (cr_diff_state=no), which is deliberate - it
# proves delegated=yes here comes from the handshake alone, not from cr_diff_state,
# and it is what makes T29's replay assertion below unambiguous (see there).
n4="cap-nonce-t28-genuine"
write_cap "$cap_t28cap" "t28-cap" "$head28" "$n4"
rows_before28="$(grep -c '"kind":"delegation"' "$ledger26" 2>/dev/null || echo 0)"
out28="$(cd "$wt28" && HIMMEL_REPO="$anchor26" PR_CHECK_ANCHOR_DELEGATED="$anchor26|t28-cap|$head28|$n4" bash "$anchor26/scripts/cr/pr-check-context.sh" 2>"$tmp/t28.err")"
rc28=$?
rows_after28="$(grep -c '"kind":"delegation"' "$ledger26" 2>/dev/null || echo 0)"
check "$rc28" "0" "T28 rc"
check "$(get_kv "$out28" delegated)" "yes" "T28 a genuine capability (matching anchor/branch/head/nonce) is accepted"
check "$(get_kv "$out28" anchor_lane)" "himmel" "T28 anchor_lane=himmel"
check "$(get_kv "$out28" himmel_dir)" "$wt28_toplevel" "T28 himmel_dir is the branch on a verified handshake, even though this diff does not touch scripts/cr (delegated is decided by the handshake, not by cr_diff_state)"
check "$rows_after28" "$rows_before28" "T28 a verified handshake does not itself attempt a NEW delegation (recursion guard, same contract as T21 for the legacy shape)"
cap_after28="$(cat "$cap_t28cap" 2>/dev/null)"
check "$cap_after28" "" "T28 the capability file is truncated (consumed) immediately after a verified use"
# HIMMEL-2378 CR round 3 [codex-2]: emptiness alone does not prove UNLINK
# happened - a truncating `: >` would look identical via `cat`. Assert
# non-existence too; this is the assertion that would actually catch a
# regression from the atomic unlink (CR round 2) back to truncation. See
# the RED demonstration right after T28's other assertions below.
if [ -e "$cap_t28cap" ]; then
  echo "FAIL: T28 the capability file still EXISTS after a verified use (expected unlinked - a truncating regression would pass the emptiness check above but fail this one)"
  fail=1
fi

# T28 RED (CR round 3 [codex-2]): mutant_truncate reverts the atomic unlink
# back to `: >` truncation - proving the NEW non-existence assertion above
# catches exactly the regression it was added for, while the OLD emptiness
# assertion (T28's "truncated (consumed)" check) keeps passing regardless -
# which is the whole point: emptiness alone cannot tell unlink from
# truncate, existence can.
mutant_truncate="$tmp/pr-check-context.mutant-truncate.sh"
# shellcheck disable=SC2016  # literal match against pr-check-context.sh's own
# source text (unexpanded $cap_file) - not a shell expansion.
literal_replace "$SCRIPT" "$mutant_truncate" \
  '                if rm "$cap_file" 2>/dev/null; then' \
  '                if : > "$cap_file"; then'
rc_lr1=$?
if [ "$rc_lr1" -ne 0 ]; then
  echo "FAIL: T28 could not build the truncate-regression mutant - $(cat "$tmp/literal_replace.err" 2>/dev/null)"
  fail=1
fi
check "$(diff "$SCRIPT" "$mutant_truncate" | grep -c '^< ')" "1" "T28 sanity - the truncate mutant differs from the real script by exactly 1 changed line (unlink reverted to truncation)"
n4b="cap-nonce-t28-truncate-red"
write_cap "$cap_t28cap" "t28-cap" "$head28" "$n4b"
cp "$mutant_truncate" "$anchor26/scripts/cr/pr-check-context.sh"
red_control_run --cwd "$wt28" \
  --env HIMMEL_REPO="$anchor26" \
  --env PR_CHECK_ANCHOR_DELEGATED="$anchor26|t28-cap|$head28|$n4b" \
  -- bash "$anchor26/scripts/cr/pr-check-context.sh"
# HIMMEL-2518 finding: this control's verdict used to be a bare
# `[ -e "$cap_t28cap" ]` - a FILE-EXISTENCE test, which a mutant that crashed
# before consuming anything satisfies exactly as well as one that truncated.
# The adjacent sanity `check` on delegated= would have gone red, but the
# "T28 RED confirmed" line itself printed either way, which is the shape this
# ticket exists to remove. All three observations (the mutant's own
# delegated=, the file's survival, its emptiness) are now ONE asserted tuple,
# so the verdict cannot be reached unless the mutant genuinely ran.
cap_exists28t=no
[ -e "$cap_t28cap" ] && cap_exists28t=yes
red_control_assert --label "T28" \
  --observed     "delegated=$(get_kv "$RED_CONTROL_OUT" delegated) cap_exists=$cap_exists28t cap_content='$(cat "$cap_t28cap" 2>/dev/null)'" \
  --expect-wrong "delegated=yes cap_exists=yes cap_content=''" \
  --correct      "delegated=yes cap_exists=no cap_content=''" \
  --note "with truncation instead of unlink the capability file still EXISTS after consumption (empty, but present) - the NEW non-existence assertion catches the regression the old emptiness check could not, and the emptiness check still passes under it" \
  || fail=1
cp "$SCRIPT" "$anchor26/scripts/cr/pr-check-context.sh"

# T29. One-time: replaying the SAME (now-consumed) capability is rejected.
# wt28's diff does not touch scripts/cr (cr_diff_state=no - see T28), so a
# rejected handshake here falls through to the ordinary "no delegation
# needed" path (delegated=no, himmel_dir stays the branch, no new ledger
# row) rather than a fresh re-delegation - isolating this assertion from any
# interaction with the normal delegation flow, unlike T26/T27 above.
rows_before29="$(grep -c '"kind":"delegation"' "$ledger26" 2>/dev/null || echo 0)"
out29="$(cd "$wt28" && HIMMEL_REPO="$anchor26" PR_CHECK_ANCHOR_DELEGATED="$anchor26|t28-cap|$head28|$n4" bash "$anchor26/scripts/cr/pr-check-context.sh" 2>"$tmp/t29.err")"
rc29=$?
rows_after29="$(grep -c '"kind":"delegation"' "$ledger26" 2>/dev/null || echo 0)"
check "$rc29" "0" "T29 rc"
check "$(get_kv "$out29" delegated)" "no" "T29 a consumed capability is REJECTED on replay (one-time)"
check "$(get_kv "$out29" himmel_dir)" "$wt28_toplevel" "T29 himmel_dir still stays the branch (cr_diff_state=no permits that regardless of the handshake) - proves the rejection is really about the consumed nonce, not a side effect of falling back to the anchor"
check "$rows_after29" "$rows_before29" "T29 no new ledger row on replay (cr_diff_state=no means delegation is never attempted either way)"

# T29 RED: mutant_noconsume must accept the SAME capability TWICE.
n5="cap-nonce-t29-red"
write_cap "$cap_t28cap" "t28-cap" "$head28" "$n5"
cp "$mutant_noconsume" "$anchor26/scripts/cr/pr-check-context.sh"
red_control_run --cwd "$wt28" \
  --env HIMMEL_REPO="$anchor26" \
  --env PR_CHECK_ANCHOR_DELEGATED="$anchor26|t28-cap|$head28|$n5" \
  -- bash "$anchor26/scripts/cr/pr-check-context.sh"
check "$RED_CONTROL_RC" "0" "T29 RED sanity - the no-consume mutant RAN on the first use"
check "$(get_kv "$RED_CONTROL_OUT" delegated)" "yes" "T29 RED sanity - the no-consume mutant still accepts the FIRST use"
red_control_run --cwd "$wt28" \
  --env HIMMEL_REPO="$anchor26" \
  --env PR_CHECK_ANCHOR_DELEGATED="$anchor26|t28-cap|$head28|$n5" \
  -- bash "$anchor26/scripts/cr/pr-check-context.sh"
red_control_assert --label "T29" \
  --observed     "delegated=$(get_kv "$RED_CONTROL_OUT" delegated)" \
  --expect-wrong "delegated=yes" \
  --correct      "delegated=no" \
  --note "without consumption the SAME capability verifies a SECOND time too - proving the truncation line T29 above relies on is load-bearing" \
  || fail=1
cp "$SCRIPT" "$anchor26/scripts/cr/pr-check-context.sh"

# T30. Concurrency: the capability file must be BRANCH-SCOPED, not one
# shared file across the anchor's whole git-common-dir. himmel runs
# concurrent /pr-check on independent branches by design (overnight-shift
# treats per-ticket branches as independent products), so two anchors
# minting for DIFFERENT branches at close to the same time must not collide
# on one file. Simulates the interleaving directly (two sequential mints,
# not two genuinely racing background processes - proves the same
# file-collision property without a flaky real race): mint "A" for wt26's
# own branch (fix/t26-cap, its current actual head headB26), then mint "B"
# for a DIFFERENT branch (t28-cap/head28) - simulating a concurrent,
# unrelated anchor delegating a different ticket branch - THEN present A's
# original capability and require it still verify.
nA30="cap-nonce-t30-a"
nB30="cap-nonce-t30-b"
write_cap "$cap_fix_t26cap" "fix/t26-cap" "$headB26" "$nA30"   # mint A
write_cap "$cap_t28cap" "t28-cap" "$head28" "$nB30"            # mint B (different file - see T30 assertion below)
rows_before30="$(grep -c '"kind":"delegation"' "$ledger26" 2>/dev/null || echo 0)"
out30="$(cd "$wt26" && HIMMEL_REPO="$anchor26" PR_CHECK_ANCHOR_DELEGATED="$anchor26|fix/t26-cap|$headB26|$nA30" bash "$anchor26/scripts/cr/pr-check-context.sh" 2>"$tmp/t30.err")"
rc30=$?
rows_after30="$(grep -c '"kind":"delegation"' "$ledger26" 2>/dev/null || echo 0)"
rows_added30=$((rows_after30 - rows_before30))
check "$rc30" "0" "T30 rc"
check "$(get_kv "$out30" delegated)" "yes" "T30 delegate A's OWN (still-genuine) capability verifies, unaffected by mint B for a different branch"
check "$(get_kv "$out30" himmel_dir)" "$wt26_toplevel" "T30 himmel_dir is the branch (genuine verified handshake, not a fresh re-delegation)"
check "$rows_added30" "0" "T30 NO spurious extra ledger row - branch-scoping means mint B never touched mint A's file, so the recursion guard held on the FIRST try"
cap_a_after30="$(cat "$cap_fix_t26cap" 2>/dev/null)"
check "$cap_a_after30" "" "T30 mint A's own file is truncated (consumed) by its own verified use"
# HIMMEL-2378 CR round 3 [codex-2]: same non-existence assertion as T28's -
# see the RED demonstration after T28's assertions above for why emptiness
# alone is insufficient.
if [ -e "$cap_fix_t26cap" ]; then
  echo "FAIL: T30 mint A's own file still EXISTS after its verified use (expected unlinked)"
  fail=1
fi
cap_b_after30="$(cat "$cap_t28cap" 2>/dev/null)"
check "$cap_b_after30" "t28-cap|$head28|$nB30" "T30 mint B's file is UNTOUCHED by delegate A's run - proves the two mints live in separate files, not one shared slot"

# T30 RED: same two-mint sequence, but through mutant_unscoped (both the
# anchor-role invocation AND wt26's own copy, so the whole exec chain stays
# internally consistent about where the capability file lives) - reproduces
# the exact defect flagged in review: mint B overwrites mint A's slot in the
# single shared file, delegate A's genuine capability fails to verify
# (fail-SAFE - never wrongly accepted), but since cr_diff_state=yes and the
# recursion guard never got to fire, it delegates AGAIN, spending a SECOND,
# spurious `delegation` ledger row on the same (branch, head) T30 above
# already logged once for.
nA30r="cap-nonce-t30-a-red"
nB30r="cap-nonce-t30-b-red"
cap_unscoped="$git_dir26/cr-delegation-capability"
write_cap "$cap_unscoped" "fix/t26-cap" "$headB26" "$nA30r"   # mint A (shared slot)
write_cap "$cap_unscoped" "t28-cap" "$head28" "$nB30r"        # mint B OVERWRITES the SAME shared slot
cp "$mutant_unscoped" "$anchor26/scripts/cr/pr-check-context.sh"
cp "$mutant_unscoped" "$wt26/scripts/cr/pr-check-context.sh"
rows_before30r="$(grep -c '"kind":"delegation"' "$ledger26" 2>/dev/null || echo 0)"
red_control_run --cwd "$wt26" \
  --env HIMMEL_REPO="$anchor26" \
  --env PR_CHECK_ANCHOR_DELEGATED="$anchor26|fix/t26-cap|$headB26|$nA30r" \
  -- bash "$anchor26/scripts/cr/pr-check-context.sh"
rows_after30r="$(grep -c '"kind":"delegation"' "$ledger26" 2>/dev/null || echo 0)"
# HIMMEL-2518: the predicted wrong value is EXACTLY one spurious row, not the
# old `-ge 1` - an inequality would equally accept a mutant that delegated in
# a loop, which is a different defect from the collision this control claims.
red_control_assert --label "T30" \
  --observed     "delegated=$(get_kv "$RED_CONTROL_OUT" delegated) rows_added=$((rows_after30r - rows_before30r))" \
  --expect-wrong "delegated=yes rows_added=1" \
  --correct      "delegated=yes rows_added=0" \
  --note "without branch-scoping mint B's overwrite invalidates delegate A's genuine capability (fail-safe - never wrongly accepted) but forces a spurious extra delegation-ledger row on the SAME (branch, head) T30 above logged only once for" \
  || fail=1
cp "$SCRIPT" "$anchor26/scripts/cr/pr-check-context.sh"
cp "$SCRIPT" "$wt26/scripts/cr/pr-check-context.sh"

# mutant_no_head_scope: HIMMEL-2378 CR round 3 [codex-1] - revert JUST the
# head component (branch-scoping alone, the round-2 shape) - used only by
# T33 below to reproduce the same-branch-different-head collision codex-1
# flags, distinct from mutant_unscoped above (which drops branch too).
mutant_no_head_scope="$tmp/pr-check-context.mutant-no-head-scope.sh"
# shellcheck disable=SC2016  # literal match against pr-check-context.sh's own
# source text (unexpanded $vars) - not a shell expansion.
literal_replace "$SCRIPT" "$mutant_no_head_scope" \
  'cap_file="$git_dir/cr-delegation/$branch/$head"' \
  'cap_file="$git_dir/cr-delegation/$branch"'
rc_lr1=$?
if [ "$rc_lr1" -ne 0 ]; then
  echo "FAIL: T33 could not build the no-head-scope mutant - $(cat "$tmp/literal_replace.err" 2>/dev/null)"
  fail=1
fi
check "$(diff "$SCRIPT" "$mutant_no_head_scope" | grep -c '^< ')" "1" "T33 sanity - the no-head-scope mutant differs from the real script by exactly 1 changed line (head dropped from the path)"

# T33. HIMMEL-2378 CR round 3 [codex-1]: the capability slot must be scoped
# by (branch, head), not branch alone - mirrors T30's cross-branch
# concurrency proof, one level down: TWO overlapping checks on the SAME
# branch (fix/t26-cap) at DIFFERENT heads must not collide on one slot.
# "mint A" is wt26's own genuine, real slot (branch fix/t26-cap, its actual
# current head headB26); "mint B" simulates a second, concurrent check on
# the SAME branch at a DIFFERENT head - fabricated (never a real commit;
# only used as a path/content component, exactly like T30's "mint B" for a
# different branch, which never actually ran anything as that branch
# either) - then delegate A's ORIGINAL capability must still verify.
nA33="cap-nonce-t33-a"
nB33="cap-nonce-t33-b"
fake_head33="0000000000000000000000000000000000a33f"
cap_fix_t26cap_fakehead="$git_dir26/cr-delegation/fix/t26-cap/$fake_head33"
write_cap "$cap_fix_t26cap" "fix/t26-cap" "$headB26" "$nA33"
write_cap "$cap_fix_t26cap_fakehead" "fix/t26-cap" "$fake_head33" "$nB33"
rows_before33="$(grep -c '"kind":"delegation"' "$ledger26" 2>/dev/null || echo 0)"
out33="$(cd "$wt26" && HIMMEL_REPO="$anchor26" PR_CHECK_ANCHOR_DELEGATED="$anchor26|fix/t26-cap|$headB26|$nA33" bash "$anchor26/scripts/cr/pr-check-context.sh" 2>"$tmp/t33.err")"
rc33=$?
rows_after33="$(grep -c '"kind":"delegation"' "$ledger26" 2>/dev/null || echo 0)"
check "$rc33" "0" "T33 rc"
check "$(get_kv "$out33" delegated)" "yes" "T33 delegate A's OWN (still-genuine) capability verifies, unaffected by mint B for a different head on the SAME branch"
check "$(get_kv "$out33" himmel_dir)" "$wt26_toplevel" "T33 himmel_dir is the branch (genuine verified handshake, not a fresh re-delegation)"
check "$((rows_after33 - rows_before33))" "0" "T33 NO spurious extra ledger row - head-scoping means mint B never touched mint A's file, so the recursion guard held on the FIRST try"
if [ -e "$cap_fix_t26cap" ]; then
  echo "FAIL: T33 mint A's own file still EXISTS after its verified use (expected unlinked)"
  fail=1
fi
cap_b_after33="$(cat "$cap_fix_t26cap_fakehead" 2>/dev/null)"
check "$cap_b_after33" "fix/t26-cap|$fake_head33|$nB33" "T33 mint B's file is UNTOUCHED by delegate A's run - proves the two heads on the same branch live in separate files, not one shared slot"

# T33 RED: same two-mint sequence, but through mutant_no_head_scope (both
# the anchor-role invocation AND wt26's own copy, so the whole exec chain
# stays internally consistent about where the capability file lives, same
# posture as T30's RED block) - reproduces the exact defect: mint B
# overwrites mint A's slot, delegate A's genuine capability fails to verify
# (fail-safe, never wrongly accepted), but since cr_diff_state=yes and the
# recursion guard never got to fire, it delegates AGAIN, spending a
# spurious second `delegation` ledger row.
# A FRESH worktree/branch, never used elsewhere in this suite: reusing
# wt26/fix-t26-cap here would collide with the REAL per-head DIRECTORY that
# name already has under cr-delegation (created by T26/T30's genuine,
# head-nested writes) - this mutant computes cap_file WITHOUT the head
# segment, so it needs that path to still be free to use as a plain FILE.
wt33r="$tmp/fake-himmel-cap-wt33red"
(cd "$anchor26" && git worktree add -q -b t33-red-branch "$wt33r" main) || { echo "FAIL: T33 could not add wt33r"; fail=1; }
(cd "$wt33r" && printf '# t33 touch\n' >> scripts/cr/critic-panel.sh && git add -A && git commit -q -m "t33 touch")
head33r_real="$(cd "$wt33r" && git rev-parse HEAD)"
nA33r="cap-nonce-t33-a-red"
nB33r="cap-nonce-t33-b-red"
cap_branch_only_33="$git_dir26/cr-delegation/t33-red-branch"
write_cap "$cap_branch_only_33" "t33-red-branch" "$head33r_real" "$nA33r"
write_cap "$cap_branch_only_33" "t33-red-branch" "$fake_head33" "$nB33r"
cp "$mutant_no_head_scope" "$anchor26/scripts/cr/pr-check-context.sh"
cp "$mutant_no_head_scope" "$wt33r/scripts/cr/pr-check-context.sh"
rows_before33r="$(grep -c '"kind":"delegation"' "$ledger26" 2>/dev/null || echo 0)"
red_control_run --cwd "$wt33r" \
  --env HIMMEL_REPO="$anchor26" \
  --env PR_CHECK_ANCHOR_DELEGATED="$anchor26|t33-red-branch|$head33r_real|$nA33r" \
  -- bash "$anchor26/scripts/cr/pr-check-context.sh"
rows_after33r="$(grep -c '"kind":"delegation"' "$ledger26" 2>/dev/null || echo 0)"
# HIMMEL-2518: delegated= was previously only INTERPOLATED into the message,
# never asserted, and the row count was an `-ge 1` inequality. Both are now
# part of the specific predicted value.
red_control_assert --label "T33" \
  --observed     "delegated=$(get_kv "$RED_CONTROL_OUT" delegated) rows_added=$((rows_after33r - rows_before33r))" \
  --expect-wrong "delegated=yes rows_added=1" \
  --correct      "delegated=yes rows_added=0" \
  --note "without head-scoping mint B's overwrite invalidates delegate A's genuine capability (fail-safe) but forces a spurious extra delegation-ledger row on the SAME (branch, head) T33 above logged only once for" \
  || fail=1
cp "$SCRIPT" "$anchor26/scripts/cr/pr-check-context.sh"
cp "$SCRIPT" "$wt33r/scripts/cr/pr-check-context.sh"

# T32. HIMMEL-2378 CR round 1 [codex-2]: mint the capability file BEFORE
# logging the ledger row. Fixture: a fresh anchor/worktree whose
# git-common-dir has a PLAIN FILE sitting at the exact path the mint code
# needs to `mkdir -p` (cr-delegation/<branch>'s own parent, cr-delegation
# itself for a flat branch name) - `mkdir -p` deterministically fails with
# "Not a directory" against a blocking file, no chmod/permission-bit game
# needed (Windows/Git Bash does not reliably enforce those - verified
# empirically, not assumed).
anchor32="$tmp/fake-himmel-unwritable"
build_fake_himmel "$anchor32"
git_dir32="$(cd "$anchor32" && git rev-parse --path-format=absolute --git-common-dir)"
: > "$git_dir32/cr-delegation"
wt32="$tmp/fake-himmel-unwritable-wt"
(cd "$anchor32" && git worktree add -q -b t32-blocked "$wt32" main) || { echo "FAIL: T32 could not add wt32"; fail=1; }
(cd "$wt32" && printf '# t32 touch\n' >> scripts/cr/critic-panel.sh && git add -A && git commit -q -m "t32 touch")
wt32_toplevel="$(cd "$wt32" && git rev-parse --show-toplevel)"
ledger32="$anchor32/.git/cr-critic-scores.jsonl"

rows_before32="$(grep -c '"kind":"delegation"' "$ledger32" 2>/dev/null || echo 0)"
out32="$(cd "$wt32" && HIMMEL_REPO="$anchor32" bash "$anchor32/scripts/cr/pr-check-context.sh" 2>"$tmp/t32.err")"
rc32=$?
rows_after32="$(grep -c '"kind":"delegation"' "$ledger32" 2>/dev/null || echo 0)"
check "$rc32" "0" "T32 rc"
check "$((rows_after32 - rows_before32))" "0" "T32 ZERO new delegation rows when the capability file could not be written"
check "$(get_kv "$out32" delegated)" "no" "T32 delegated=no - declined, not a false claim"
hd32="$(get_kv "$out32" himmel_dir)"
check "$hd32" "$anchor32" "T32 himmel_dir falls back to the ANCHOR (a delegation that never happened must not leave the branch's own scripts/cr/ running)"
if [ "$hd32" = "$wt32_toplevel" ]; then
  echo "FAIL: T32 negative control - himmel_dir wrongly stayed the BRANCH ($wt32_toplevel)"
  fail=1
fi
grep -qi 'could not write the delegation capability file' "$tmp/t32.err" || { echo "FAIL: T32 missing the capability-write-failure diagnostic on stderr"; fail=1; }

# T32 RED: same blocked fixture, against mutant_ledger_first (the
# write-gate bypassed, ledger-append + exec run unconditionally) - must
# reproduce a FALSE delegation record: at least one new ledger row despite
# the capability never having been written.
cp "$mutant_ledger_first" "$anchor32/scripts/cr/pr-check-context.sh"
rows_before32r="$(grep -c '"kind":"delegation"' "$ledger32" 2>/dev/null || echo 0)"
red_control_run --cwd "$wt32" \
  --env HIMMEL_REPO="$anchor32" \
  -- bash "$anchor32/scripts/cr/pr-check-context.sh"
rows_after32r="$(grep -c '"kind":"delegation"' "$ledger32" 2>/dev/null || echo 0)"
# HIMMEL-2518: was `-ge 1` on the row count alone. delegated= is now asserted
# alongside it, and asserting it is what corrected this control's own stated
# prediction: the migration first predicted delegated=yes, and the contract
# rejected that as `wrong-mutation` rather than accepting it on the row count.
# The mutant's real shape is delegated=NO with a row logged anyway - it skips
# the write gate, appends the ledger row, then still declines - which is a
# sharper statement of the defect than "it delegated": the ledger records a
# delegation that never happened AND that the run itself does not claim.
red_control_assert --label "T32" \
  --observed     "delegated=$(get_kv "$RED_CONTROL_OUT" delegated) rows_added=$((rows_after32r - rows_before32r))" \
  --expect-wrong "delegated=no rows_added=1" \
  --correct      "delegated=no rows_added=0" \
  --note "without the write-before-log ordering a FALSE delegation-ledger row is recorded even though the capability file was never written and the run itself declines - proving the reordering T32 above relies on is load-bearing" \
  || fail=1
cp "$SCRIPT" "$anchor32/scripts/cr/pr-check-context.sh"

# T17/T20/T21 (round 4's own tests, far above) are re-affirmed here as still
# green. T20's fixture (PR_CHECK_ANCHOR_DELEGATED=1) still lands in the same
# `*)` case arm as before and is still refused - unaffected by codex-1
# (it was never accepted there to begin with). T17/T21's fixtures
# (PR_CHECK_ANCHOR_DELEGATED=$anchor13, the legacy bare-path shape) also
# still land in that `*)` arm, but codex-1 changed what happens there: no
# longer accepted, only refused-then-converged - see T17/T21's own updated
# assertions above for that.
check "$rc20" "0" "T26-30 re-affirm: T20 rc still 0"
check "$rc21" "0" "T26-30 re-affirm: T21 rc still 0"

# --- Negative-control check: perturb T3's expectation to confirm the
# assertion genuinely fails, then restore. This is asserted directly (not by
# re-running check(), which only logs) so a broken assertion cannot pass
# silently. ------------------------------------------------------------------
wrong_marker="$git_dir/cr-pending/WRONG-BRANCH"
real_marker="$(get_kv "$out1" marker)"
if [ "$real_marker" = "$wrong_marker" ]; then
  echo "FAIL: negative control - marker assertion cannot distinguish a wrong value"
  fail=1
else
  echo "negative control confirmed: marker '$real_marker' != deliberately wrong '$wrong_marker'"
fi

[ "$fail" -eq 0 ] && echo "PASS test-pr-check-context" || exit 1
