#!/usr/bin/env bash
# Hermetic test for scripts/ci/check-commit-range.sh (HIMMEL-594). Builds throw-
# away git repos with known-good/bad commits and asserts the gate's verdict.
set -uo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone. (HIMMEL-1430.)
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

REPO_ROOT="$(git rev-parse --show-toplevel)"
CR="$REPO_ROOT/scripts/ci/check-commit-range.sh"
# shellcheck source=scripts/lib/fixture-tempdir.sh
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/fixture-tempdir.sh"
[ -f "$CR" ] || { echo "FAIL: $CR not found"; exit 1; }
failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

# mkrepo <dir> <commit-msg...> — init a repo with a base commit then the given
# extra commits; echoes the base SHA via a file (avoids subshell var loss).
mkrepo() {
    local d="$1"; shift
    (
        fixture_enter_git_init_dir "$d" || exit 1
        git init -q
        git config user.email t@e
        git config user.name t
        git commit -q --allow-empty -m "chore: base"
        git rev-parse HEAD > .base
        local m
        for m in "$@"; do git commit -q --allow-empty -m "$m"; done
    )
}

run_cr() { # <repo-dir> -> runs strict check-commit-range against <base>..HEAD
    local d="$1" base
    base="$(cat "$d/.base")"
    ( cd "$d" && TICKET_ID_REQUIRED=1 JIRA_PROJECT_KEY=HIMMEL \
        TICKET_ID_TRUSTED_AUTHOR="${TICKET_ID_TRUSTED_AUTHOR:-}" bash "$CR" "$base" 2>&1 )
}

# --- one bad (non-conventional) commit -> rc1 + surfaces it ---
t="$(fixture_mktemp_dir)" || exit 1
mkrepo "$t" "feat(x): HIMMEL-1 good commit" "broken commit no type"
out="$(run_cr "$t")"; rc=$?
if [ "$rc" -eq 1 ]; then pass "non-conventional -> rc1"; else fail "expected rc1, got $rc: $out"; fi
if grepq "$out" 'broken commit no type'; then pass "surfaces offending subject"; else fail "no offending subject: $out"; fi
rm -rf "$t"

# --- all-clean ticketed range -> rc0 ---
t="$(fixture_mktemp_dir)" || exit 1
mkrepo "$t" "fix(api): HIMMEL-2 ok" "chore: HIMMEL-3 tidy"
out="$(run_cr "$t")"; rc=$?
if [ "$rc" -eq 0 ]; then pass "clean range -> rc0"; else fail "expected rc0, got $rc: $out"; fi
rm -rf "$t"

# --- a REAL merge commit in the range is skipped (HIMMEL-1483 CR1) ---
# The hook's merge exemption is live-MERGE_HEAD only, so the range gate must
# skip historical merges structurally (--no-merges; parent count >= 2).
t="$(fixture_mktemp_dir)" || exit 1
mkrepo "$t" "fix(api): HIMMEL-2 ok"
git -C "$t" checkout -q -b side
git -C "$t" commit -q --allow-empty -m "feat(y): HIMMEL-4 side work"
git -C "$t" checkout -q -
git -C "$t" merge -q --no-ff --no-edit side
out="$(run_cr "$t")"; rc=$?
if [ "$rc" -eq 0 ]; then pass "range containing a real merge commit -> rc0"; else fail "expected rc0, got $rc: $out"; fi
rm -rf "$t"

# --- ...but a merge-SHAPED message with ONE parent is still validated ---
# Parent count is the unfakeable signal: a hand-typed "Merge branch ..." subject
# on an ordinary commit gets no skip and fails the gate (anti-spoof, r2 intent).
t="$(fixture_mktemp_dir)" || exit 1
mkrepo "$t" "Merge branch 'fake' into main"
out="$(run_cr "$t")"; rc=$?
if [ "$rc" -eq 1 ]; then pass "merge-shaped single-parent commit still fails"; else fail "expected rc1, got $rc: $out"; fi
rm -rf "$t"

# --- malformed HIMMEL- ticket -> rc1 + named ---
t="$(fixture_mktemp_dir)" || exit 1
mkrepo "$t" "feat(x): HIMMEL-abc malformed ticket"
out="$(run_cr "$t")"; rc=$?
if [ "$rc" -eq 1 ]; then pass "malformed ticket -> rc1"; else fail "expected rc1, got $rc: $out"; fi
if grepq "$out" -i 'malformed'; then pass "names malformed ticket"; else fail "no malformed msg: $out"; fi
rm -rf "$t"

# --- conventional but ticketless commit -> rc1 ---
t="$(fixture_mktemp_dir)" || exit 1
mkrepo "$t" "chore: ticket omitted"
out="$(run_cr "$t")"; rc=$?
if [ "$rc" -eq 1 ]; then pass "ticketless strict commit -> rc1"; else fail "expected rc1, got $rc: $out"; fi
rm -rf "$t"

# --- spoofed dependabot commit metadata is not enough without a trusted PR author ---
t="$(fixture_mktemp_dir)" || exit 1
mkrepo "$t"
git -C "$t" -c user.name='dependabot[bot]' -c user.email='bot@example.invalid' \
  commit -q --allow-empty -m "chore: bump dependency"
out="$(run_cr "$t")"; rc=$?
if [ "$rc" -eq 1 ]; then pass "bot metadata without trusted author -> rc1"; else fail "expected rc1, got $rc: $out"; fi
rm -rf "$t"

# --- trusted bot PR author still needs bot-authored commit metadata ---
t="$(fixture_mktemp_dir)" || exit 1
mkrepo "$t" "chore: bump dependency"
out="$(TICKET_ID_TRUSTED_AUTHOR='dependabot[bot]' run_cr "$t")"; rc=$?
if [ "$rc" -eq 1 ]; then pass "trusted bot with human commit author -> rc1"; else fail "expected rc1, got $rc: $out"; fi
rm -rf "$t"

# --- trusted bot PR author plus bot commit metadata is exempt ---
t="$(fixture_mktemp_dir)" || exit 1
mkrepo "$t"
git -C "$t" -c user.name='dependabot[bot]' -c user.email='bot@example.invalid' \
  commit -q --allow-empty -m "chore: bump dependency"
out="$(TICKET_ID_TRUSTED_AUTHOR='dependabot[bot]' run_cr "$t")"; rc=$?
if [ "$rc" -eq 0 ]; then pass "trusted bot and bot commit author -> rc0"; else fail "expected rc0, got $rc: $out"; fi
rm -rf "$t"

# --- unresolvable base ref -> rc2 (cannot evaluate the range) ---
t="$(fixture_mktemp_dir)" || exit 1
mkrepo "$t" "chore: x"
out="$( cd "$t" && bash "$CR" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" 2>&1 )"; rc=$?
if [ "$rc" -eq 2 ]; then pass "unresolvable base -> rc2"; else fail "expected rc2, got $rc: $out"; fi
rm -rf "$t"

# --- empty range (base == HEAD) -> rc0 + 'nothing to lint' ---
t="$(fixture_mktemp_dir)" || exit 1
mkrepo "$t"   # base commit only; HEAD == base
out="$( cd "$t" && bash "$CR" HEAD 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ]; then pass "empty range -> rc0"; else fail "expected rc0, got $rc: $out"; fi
if grepq "$out" -i 'nothing to lint'; then pass "empty range reports nothing to lint"; else fail "no nothing-to-lint msg: $out"; fi
rm -rf "$t"

# --- --merge-ref (HIMMEL-3413): CI checks out refs/pull/N/merge, a merge of the
# CURRENT base tip and the PR head, but pull_request.base.sha is the tip when
# the PR was OPENED. Linting <stale base>..merge-ref lints every commit main
# gained since (a bot's ticketless bump). --merge-ref lints from the merge
# commit's first parent instead.
# mkmergeref <dir> <main-msg> <pr-msg...> — base commit; PR branch cut there
# with <pr-msg...>; main then gains <main-msg>; HEAD = a merge of main tip +
# PR head (detached, as actions/checkout leaves it). .base = the STALE base.
mkmergeref() {
    local d="$1" main_msg="$2"; shift 2
    (
        fixture_enter_git_init_dir "$d" || exit 1
        git init -q -b main
        git config user.email t@e
        git config user.name t
        git commit -q --allow-empty -m "chore: base"
        git rev-parse HEAD > .base
        git checkout -q -b pr
        local m
        for m in "$@"; do git commit -q --allow-empty -m "$m"; done
        git checkout -q main
        git commit -q --allow-empty -m "$main_msg"
        git checkout -q --detach main
        git merge -q --no-ff -m "Merge pr into main" pr
    )
}
run_cr_mr() { # <repo-dir> -> the CI-shaped call: --merge-ref <stale base.sha>
    local d="$1" base
    base="$(cat "$d/.base")"
    ( cd "$d" && TICKET_ID_REQUIRED=1 JIRA_PROJECT_KEY=HIMMEL \
        TICKET_ID_TRUSTED_AUTHOR="${TICKET_ID_TRUSTED_AUTHOR:-}" bash "$CR" --merge-ref "$base" 2>&1 )
}

# main's ticketless bump landed after the PR was opened; the PR's own commit is clean
t="$(fixture_mktemp_dir)" || exit 1
mkmergeref "$t" "build(deps): bump the group across 6 directories" "fix(api): HIMMEL-5 pr commit"
out="$(run_cr_mr "$t")"; rc=$?
if [ "$rc" -eq 0 ]; then pass "merge-ref: main's post-open commit is not linted -> rc0"; else fail "expected rc0, got $rc: $out"; fi
if grepq "$out" 'build(deps)' -F; then fail "merge-ref: main's commit was named: $out"; else pass "merge-ref: main's commit not named"; fi
rm -rf "$t"

# control: the SAME fixture without --merge-ref still lints the stale range (the bug)
t="$(fixture_mktemp_dir)" || exit 1
mkmergeref "$t" "build(deps): bump the group across 6 directories" "fix(api): HIMMEL-5 pr commit"
out="$(run_cr "$t")"; rc=$?
if [ "$rc" -eq 1 ]; then pass "control: stale base without --merge-ref -> rc1 (the HIMMEL-3413 shape)"; else fail "expected rc1, got $rc: $out"; fi
rm -rf "$t"

# control: a non-conforming commit ON the PR branch still fails under --merge-ref
t="$(fixture_mktemp_dir)" || exit 1
mkmergeref "$t" "fix(x): HIMMEL-6 main commit" "fix(api): HIMMEL-5 good" "broken pr commit no type"
out="$(run_cr_mr "$t")"; rc=$?
if [ "$rc" -eq 1 ]; then pass "merge-ref: bad PR commit -> rc1"; else fail "expected rc1, got $rc: $out"; fi
if grepq "$out" 'broken pr commit no type' -F; then pass "merge-ref: names the PR's bad commit"; else fail "no PR subject: $out"; fi
rm -rf "$t"

# control: the FIRST of several PR commits is still linted (nothing skipped)
t="$(fixture_mktemp_dir)" || exit 1
mkmergeref "$t" "fix(x): HIMMEL-6 main commit" "broken first pr commit" "fix(api): HIMMEL-5 good"
out="$(run_cr_mr "$t")"; rc=$?
if [ "$rc" -eq 1 ]; then pass "merge-ref: first PR commit still linted -> rc1"; else fail "expected rc1, got $rc: $out"; fi
rm -rf "$t"

# fallback: HEAD is not a merge (checkout of the PR head) -> the given base is used
t="$(fixture_mktemp_dir)" || exit 1
mkrepo "$t" "fix(api): HIMMEL-2 ok" "broken commit no type"
out="$(run_cr_mr "$t")"; rc=$?
if [ "$rc" -eq 1 ]; then pass "merge-ref on a non-merge HEAD falls back to the given base -> rc1"; else fail "expected rc1, got $rc: $out"; fi
rm -rf "$t"

echo
if [ "$failures" -eq 0 ]; then echo "ALL PASS"; else echo "$failures FAILED"; exit 1; fi
