#!/usr/bin/env bash
# Smoke test for scripts/handover/auto-commit.sh (HIMMEL-140).
#
# Covers:
#   1. Branch creation from ticket-tagged message
#   2. Idempotent reuse on second mutation with the same ticket
#   3. Untagged message falls back to handover/session-YYYY-MM-DD
#   4. HANDOVER_DIRECT_MAIN=1 keeps v1 commit-on-current-branch behavior
#   5. --no-push skips the push step
#   6. --dry-run touches nothing
#   7. Push lands the branch on the bare origin
#
# Self-contained — uses tmp git repos + bare-origin. No network.
set -euo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone. (HIMMEL-1430.)
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_UNDER_TEST="$SCRIPT_DIR/auto-commit.sh"

if [ ! -x "$SCRIPT_UNDER_TEST" ] && [ ! -f "$SCRIPT_UNDER_TEST" ]; then
    echo "ERR test: $SCRIPT_UNDER_TEST not found" >&2
    exit 2
fi

PASS=0
FAIL=0
TMP_ROOT=""

# shellcheck disable=SC2329,SC2317  # invoked via trap; body is reachable through it
cleanup() {
    if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
        rm -rf "$TMP_ROOT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: $name"
        PASS=$((PASS+1))
    else
        echo "  FAIL: $name"
        echo "    expected: $expected"
        echo "    actual:   $actual"
        FAIL=$((FAIL+1))
    fi
}

assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    if grepq "$haystack" -- "$needle"; then
        echo "  PASS: $name"
        PASS=$((PASS+1))
    else
        echo "  FAIL: $name"
        echo "    needle missing: $needle"
        echo "    haystack: $haystack"
        FAIL=$((FAIL+1))
    fi
}

assert_branch_exists() {
    local name="$1" repo="$2" branch="$3"
    if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
        echo "  PASS: $name"
        PASS=$((PASS+1))
    else
        echo "  FAIL: $name (branch $branch missing in $repo)"
        FAIL=$((FAIL+1))
    fi
}

assert_remote_branch_exists() {
    local name="$1" origin="$2" branch="$3"
    if git -C "$origin" show-ref --verify --quiet "refs/heads/$branch"; then
        echo "  PASS: $name"
        PASS=$((PASS+1))
    else
        echo "  FAIL: $name (branch $branch missing on origin)"
        FAIL=$((FAIL+1))
    fi
}

# Setup ----------------------------------------------------------------

TMP_ROOT=$(mktemp -d)
# On Git Bash / MSYS, `mktemp -d` returns `/tmp/tmp.X` but `git rev-parse
# --show-toplevel` resolves to the real Windows path (C:/Users/.../Temp).
# Normalise to a single style so the pathspec lines git uses for staging
# don't mismatch. cygpath -m gives mixed (C:/...) which both git AND
# realpath -m accept.
if command -v cygpath >/dev/null 2>&1; then
    TMP_ROOT=$(cygpath -m "$TMP_ROOT")
fi
echo "test: TMP_ROOT=$TMP_ROOT"
SLUG="dpz$$"

HIMMEL_FAKE="$TMP_ROOT/himmel"
HANDOVER_ORIGIN="$TMP_ROOT/handover-origin.git"
HANDOVER_REPO="$TMP_ROOT/handover"

mkdir -p "$HIMMEL_FAKE"
(
    cd "$HIMMEL_FAKE"
    git init -q
    git -c user.email=t@test.com -c user.name=test commit -q --allow-empty -m "init himmel"
)

git init -q --bare "$HANDOVER_ORIGIN"

(
    cd "$TMP_ROOT"
    git clone -q "$HANDOVER_ORIGIN" handover
    cd handover
    git -c user.email=t@test.com -c user.name=test commit -q --allow-empty -m "init handover"
    git -c user.email=t@test.com -c user.name=test push -q origin main 2>/dev/null \
      || git -c user.email=t@test.com -c user.name=test push -q origin HEAD:main
    # Ensure local branch is named main (origin default detection varies)
    git branch -m main 2>/dev/null || true
)

mkdir -p "$HANDOVER_REPO/handovers/$SLUG"

# Helper to invoke auto-commit.sh inside HIMMEL_FAKE with HANDOVER_DIR
# pointing at the handover-repo's handovers/ root.
run_auto_commit() {
    (
        cd "$HIMMEL_FAKE"
        # shellcheck disable=SC2030  # subshell-scoped export is intentional
        export HANDOVER_DIR="$HANDOVER_REPO/handovers"
        # Pass through any env overrides set in the caller.
        env GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=t@test.com \
            GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=t@test.com \
            bash "$SCRIPT_UNDER_TEST" "$@"
    )
}

# Test 1: branch creation from ticket-tagged message -------------------

echo "TEST: branch creation from ticket-tagged message"

echo "first content" > "$HANDOVER_REPO/handovers/$SLUG/notes.md"
out=$(run_auto_commit "HIMMEL-140 add notes" 2>&1)
printf '%s\n' "$out" | awk '{print "  > "$0}'
assert_contains "creates handover/HIMMEL-140 branch" \
    "handover/HIMMEL-140-add-notes" "$out"
assert_branch_exists "branch exists locally" "$HANDOVER_REPO" "handover/HIMMEL-140-add-notes"
assert_remote_branch_exists "branch pushed to origin" "$HANDOVER_ORIGIN" "handover/HIMMEL-140-add-notes"

# Test 2: idempotent reuse on second mutation, same ticket -------------

echo "TEST: idempotent reuse"

# Switch handover repo to main so the second mutation has to re-derive
# the branch from scratch.
git -C "$HANDOVER_REPO" checkout -q main 2>/dev/null \
  || git -C "$HANDOVER_REPO" checkout -q master 2>/dev/null \
  || true
# Recreate the handovers tree — checkout main strips any tree that only
# exists on a feature branch (handovers/$SLUG/notes.md was added on
# handover/HIMMEL-140-... and main has no commits touching that path).
mkdir -p "$HANDOVER_REPO/handovers/$SLUG"

echo "more content" > "$HANDOVER_REPO/handovers/$SLUG/notes.md"
out=$(run_auto_commit "HIMMEL-140 add more notes" 2>&1)
printf '%s\n' "$out" | awk '{print "  > "$0}'
# Slug differs because message text differs; assert branch name pattern
assert_contains "reuses prefix on second invocation" "handover/HIMMEL-140-" "$out"

# Re-run with EXACT same message → branch should already exist; checkout
# path is taken.
echo "exact same message" > "$HANDOVER_REPO/handovers/$SLUG/notes.md"
out=$(run_auto_commit "HIMMEL-140 add more notes" 2>&1)
printf '%s\n' "$out" | awk '{print "  > "$0}'
assert_contains "exact-msg re-run reuses same branch" "handover/HIMMEL-140-add-more-notes" "$out"

# Test 3: untagged message falls back to session-YYYY-MM-DD ------------

echo "TEST: untagged message session fallback"

today=$(date -u +%Y-%m-%d)
git -C "$HANDOVER_REPO" checkout -q main 2>/dev/null \
  || git -C "$HANDOVER_REPO" checkout -q master 2>/dev/null \
  || true
# Recreate the handovers tree — checkout main strips any tree that only
# exists on a feature branch (handovers/$SLUG/notes.md was added on
# handover/HIMMEL-140-... and main has no commits touching that path).
mkdir -p "$HANDOVER_REPO/handovers/$SLUG"
echo "untagged content" > "$HANDOVER_REPO/handovers/$SLUG/freeform.md"
out=$(run_auto_commit "freeform thought" 2>&1)
printf '%s\n' "$out" | awk '{print "  > "$0}'
assert_contains "session fallback branch" "handover/session-$today" "$out"
assert_branch_exists "session branch exists locally" "$HANDOVER_REPO" "handover/session-$today"

# Test 4: HANDOVER_DIRECT_MAIN=1 keeps v1 behavior ---------------------

echo "TEST: HANDOVER_DIRECT_MAIN=1"

git -C "$HANDOVER_REPO" checkout -q main 2>/dev/null \
  || git -C "$HANDOVER_REPO" checkout -q master 2>/dev/null \
  || true
# Recreate the handovers tree — checkout main strips any tree that only
# exists on a feature branch (handovers/$SLUG/notes.md was added on
# handover/HIMMEL-140-... and main has no commits touching that path).
mkdir -p "$HANDOVER_REPO/handovers/$SLUG"
before_branch=$(git -C "$HANDOVER_REPO" rev-parse --abbrev-ref HEAD)
echo "direct content" > "$HANDOVER_REPO/handovers/$SLUG/direct.md"
out=$(
    cd "$HIMMEL_FAKE"
    # shellcheck disable=SC2030,SC2031  # subshell-scoped export is intentional
    export HANDOVER_DIR="$HANDOVER_REPO/handovers"
    env GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=t@test.com \
        GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=t@test.com \
        HANDOVER_DIRECT_MAIN=1 \
        bash "$SCRIPT_UNDER_TEST" --no-push "HIMMEL-140 direct test" 2>&1
)
printf '%s\n' "$out" | awk '{print "  > "$0}'
after_branch=$(git -C "$HANDOVER_REPO" rev-parse --abbrev-ref HEAD)
assert_eq "direct-main preserves current branch" "$before_branch" "$after_branch"
assert_contains "no branch creation log" "committed" "$out"

# Test 5: --no-push skips push ----------------------------------------

echo "TEST: --no-push skips push"

git -C "$HANDOVER_REPO" checkout -q main 2>/dev/null \
  || git -C "$HANDOVER_REPO" checkout -q master 2>/dev/null \
  || true
# Recreate the handovers tree — checkout main strips any tree that only
# exists on a feature branch (handovers/$SLUG/notes.md was added on
# handover/HIMMEL-140-... and main has no commits touching that path).
mkdir -p "$HANDOVER_REPO/handovers/$SLUG"
echo "nopush content" > "$HANDOVER_REPO/handovers/$SLUG/nopush.md"
out=$(run_auto_commit --no-push "HIMMEL-999 nopush check" 2>&1)
printf '%s\n' "$out" | awk '{print "  > "$0}'
if grepq "$out" "auto-commit: pushed."; then
    echo "  FAIL: --no-push pushed anyway"
    FAIL=$((FAIL+1))
else
    echo "  PASS: --no-push did not push"
    PASS=$((PASS+1))
fi
# Verify the branch did not appear on origin.
if git -C "$HANDOVER_ORIGIN" show-ref --verify --quiet "refs/heads/handover/HIMMEL-999-nopush-check"; then
    echo "  FAIL: --no-push leaked branch to origin"
    FAIL=$((FAIL+1))
else
    echo "  PASS: --no-push branch absent from origin"
    PASS=$((PASS+1))
fi

# Test 6: --dry-run touches nothing -----------------------------------

echo "TEST: --dry-run touches nothing"

git -C "$HANDOVER_REPO" checkout -q main 2>/dev/null \
  || git -C "$HANDOVER_REPO" checkout -q master 2>/dev/null \
  || true
# Recreate the handovers tree — checkout main strips any tree that only
# exists on a feature branch (handovers/$SLUG/notes.md was added on
# handover/HIMMEL-140-... and main has no commits touching that path).
mkdir -p "$HANDOVER_REPO/handovers/$SLUG"
sha_before=$(git -C "$HANDOVER_REPO" rev-parse HEAD)
echo "dryrun content" > "$HANDOVER_REPO/handovers/$SLUG/dryrun.md"
out=$(run_auto_commit --dry-run "HIMMEL-998 dry run" 2>&1)
printf '%s\n' "$out" | awk '{print "  > "$0}'
sha_after=$(git -C "$HANDOVER_REPO" rev-parse HEAD)
assert_eq "--dry-run leaves HEAD untouched" "$sha_before" "$sha_after"
assert_contains "--dry-run announces target branch" \
    "handover/HIMMEL-998-dry-run" "$out"

# Clean up dryrun.md so it doesn't bleed into later tests.
rm -f "$HANDOVER_REPO/handovers/$SLUG/dryrun.md"

# Test 7: cross-machine resume — origin has a branch the local clone hasn't fetched.
# Simulates: machine A pushed `handover/HIMMEL-777-cross-machine` directly to
# origin; machine B starts from a stale clone that never saw the branch. The
# checkout path must `git fetch` before `--track origin/<branch>`.

echo "TEST: cross-machine resume — origin has unfetched branch"

WORKER_REPO="$TMP_ROOT/worker"
git clone -q "$HANDOVER_ORIGIN" "$WORKER_REPO"
(
    cd "$WORKER_REPO"
    git checkout -q -b handover/HIMMEL-777-cross-machine
    mkdir -p handovers/$SLUG
    echo "from worker" > handovers/$SLUG/worker.md
    git -c user.email=t@test.com -c user.name=test add handovers/$SLUG/worker.md
    git -c user.email=t@test.com -c user.name=test commit -q -m "handover: HIMMEL-777 worker seed"
    git -c user.email=t@test.com -c user.name=test push -q -u origin handover/HIMMEL-777-cross-machine
)

# Back to the primary clone — verify the branch is unknown locally even
# though origin has it. We must not pre-fetch; the script's own fetch is
# the thing under test.
if git -C "$HANDOVER_REPO" rev-parse --verify --quiet "refs/remotes/origin/handover/HIMMEL-777-cross-machine" >/dev/null 2>&1; then
    echo "  WARN: precondition failed — origin/<branch> already fetched; test result will be less meaningful"
fi

git -C "$HANDOVER_REPO" checkout -q main 2>/dev/null \
  || git -C "$HANDOVER_REPO" checkout -q master 2>/dev/null \
  || true
mkdir -p "$HANDOVER_REPO/handovers/$SLUG"
echo "from primary" > "$HANDOVER_REPO/handovers/$SLUG/cross-machine-add.md"

out=$(run_auto_commit "HIMMEL-777 cross machine" 2>&1)
printf '%s\n' "$out" | awk '{print "  > "$0}'
assert_contains "fetches + tracks origin branch" \
    "handover/HIMMEL-777-cross-machine" "$out"
assert_branch_exists "tracking branch exists locally" \
    "$HANDOVER_REPO" "handover/HIMMEL-777-cross-machine"

# The primary clone's tip should now contain BOTH the worker's seed file
# AND the local cross-machine-add.md — proving the local commit landed
# on top of the worker's commit, not on a fresh branch off main.
if git -C "$HANDOVER_REPO" log --oneline handover/HIMMEL-777-cross-machine -- handovers/$SLUG/worker.md 2>/dev/null | grep -q "."; then
    echo "  PASS: tracked branch contains worker seed commit"
    PASS=$((PASS+1))
else
    echo "  FAIL: tracked branch missing worker seed commit (suggests fetch+track didn't happen)"
    FAIL=$((FAIL+1))
fi

# HIMMEL-571: single-writer marker → commit on default branch, never branch,
# refuse if parked. Runs in its OWN fresh repo + bare origin so the marker
# never contaminates the shared HANDOVER_REPO cases above and the
# "no handover/* ref" assertion is meaningful.

echo "TEST: HIMMEL-571 single-writer marker"

assert_rc() {
    local name="$1" exp="$2" act="$3"
    if [ "$exp" = "$act" ]; then
        echo "  PASS: $name"
        PASS=$((PASS+1))
    else
        echo "  FAIL: $name (expected rc $exp, got $act)"
        FAIL=$((FAIL+1))
    fi
}

SW_ORIGIN="$TMP_ROOT/sw-origin.git"
SW_REPO="$TMP_ROOT/sw"
git init -q --bare "$SW_ORIGIN"
(
    cd "$TMP_ROOT"
    git clone -q "$SW_ORIGIN" sw
    cd sw
    git -c user.email=t@test.com -c user.name=test commit -q --allow-empty -m "init sw"
    git -c user.email=t@test.com -c user.name=test push -q origin main 2>/dev/null \
      || git -c user.email=t@test.com -c user.name=test push -q origin HEAD:main
    git branch -m main 2>/dev/null || true
    # Establish origin/HEAD so _default_branch resolves to 'main'. NOT --auto
    # (fails against a local bare origin).
    git remote set-head origin main 2>/dev/null || true
)

# Drive auto-commit with HANDOVER_DIR pointing at the single-writer repo.
run_sw_auto_commit() {
    (
        cd "$HIMMEL_FAKE"
        # shellcheck disable=SC2030,SC2031  # subshell-scoped export is intentional
        export HANDOVER_DIR="$SW_REPO/handovers"
        env GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=t@test.com \
            GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=t@test.com \
            bash "$SCRIPT_UNDER_TEST" "$@"
    )
}

# Per-case hygiene: start from a clean main, optionally create the feature
# branch off main, (re)create the marker (clean -fdq strips untracked files),
# and ensure the handovers dir exists.
sw_prepare() {
    local branch="$1"
    git -C "$SW_REPO" checkout -q main
    git -C "$SW_REPO" checkout -q -- . 2>/dev/null || true
    git -C "$SW_REPO" clean -fdq
    if [ "$branch" != "main" ]; then
        git -C "$SW_REPO" checkout -q -B "$branch"
    fi
    : > "$SW_REPO/.single-writer"
    mkdir -p "$SW_REPO/handovers/$SLUG"
}

# T-sw1: happy path — marker + on main + md change → commit on main, no branch.
sw_prepare main
echo "sw happy" > "$SW_REPO/handovers/$SLUG/sw1.md"
rc=0; out=$(run_sw_auto_commit --no-push "HIMMEL-571 happy" 2>&1) || rc=$?
printf '%s\n' "$out" | awk '{print "  > "$0}'
assert_rc "sw1: happy path exits 0" "0" "$rc"
assert_eq "sw1: lands on main" "main" "$(git -C "$SW_REPO" rev-parse --abbrev-ref HEAD)"
sw1_handover_refs=$(git -C "$SW_REPO" for-each-ref --format='%(refname)' refs/heads/handover 2>/dev/null)
if [ -z "$sw1_handover_refs" ]; then
    echo "  PASS: sw1: no handover/* branch created"; PASS=$((PASS+1))
else
    echo "  FAIL: sw1: handover branch created: $sw1_handover_refs"; FAIL=$((FAIL+1))
fi
assert_contains "sw1: commit subject is a handover commit" "handover:" "$(git -C "$SW_REPO" log -1 --pretty=%s)"

# T-sw2: guard refuses — marker + parked on handover branch + md change → exit 7.
sw_prepare handover/HIMMEL-571-x
echo "sw parked" > "$SW_REPO/handovers/$SLUG/sw2.md"
sw2_before=$(git -C "$SW_REPO" rev-parse HEAD)
rc=0; out=$(run_sw_auto_commit --no-push "HIMMEL-571 parked" 2>&1) || rc=$?
printf '%s\n' "$out" | awk '{print "  > "$0}'
assert_rc "sw2: parked refuses with exit 7" "7" "$rc"
assert_contains "sw2: error names the checkout fix" "checkout" "$out"
assert_eq "sw2: no commit created (HEAD unchanged)" "$sw2_before" "$(git -C "$SW_REPO" rev-parse HEAD)"

# T-sw3: no-op stays no-op — marker + parked + NO md change → exit 0, not 7.
sw_prepare handover/HIMMEL-571-x
sw3_before=$(git -C "$SW_REPO" rev-parse HEAD)
rc=0; out=$(run_sw_auto_commit --no-push "HIMMEL-571 noop" 2>&1) || rc=$?
printf '%s\n' "$out" | awk '{print "  > "$0}'
assert_rc "sw3: no-op on parked repo exits 0" "0" "$rc"
assert_contains "sw3: reports nothing to do" "nothing to do" "$out"
assert_eq "sw3: HEAD unchanged" "$sw3_before" "$(git -C "$SW_REPO" rev-parse HEAD)"

# T-sw4: escape hatch — HANDOVER_DIRECT_MAIN=1 on a parked branch commits there
# (no exit 7), proving the guard is marker-scoped.
sw_prepare handover/HIMMEL-571-x
echo "sw escape" > "$SW_REPO/handovers/$SLUG/sw4.md"
sw4_before=$(git -C "$SW_REPO" rev-parse HEAD)
rc=0
out=$(
    cd "$HIMMEL_FAKE"
    # shellcheck disable=SC2030,SC2031  # subshell-scoped export is intentional
    export HANDOVER_DIR="$SW_REPO/handovers"
    env GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=t@test.com \
        GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=t@test.com \
        HANDOVER_DIRECT_MAIN=1 \
        bash "$SCRIPT_UNDER_TEST" --no-push "HIMMEL-571 escape" 2>&1
) || rc=$?
printf '%s\n' "$out" | awk '{print "  > "$0}'
assert_rc "sw4: escape hatch exits 0 (not 7)" "0" "$rc"
assert_eq "sw4: stays on the feature branch" "handover/HIMMEL-571-x" "$(git -C "$SW_REPO" rev-parse --abbrev-ref HEAD)"
if [ "$sw4_before" != "$(git -C "$SW_REPO" rev-parse HEAD)" ]; then
    echo "  PASS: sw4: commit landed on the feature branch"; PASS=$((PASS+1))
else
    echo "  FAIL: sw4: no commit landed"; FAIL=$((FAIL+1))
fi

# T-sw5: dry-run happy — marker + on main → plan names .single-writer, no commit.
sw_prepare main
echo "sw dry happy" > "$SW_REPO/handovers/$SLUG/sw5.md"
sw5_before=$(git -C "$SW_REPO" rev-parse HEAD)
rc=0; out=$(run_sw_auto_commit --dry-run --no-push "HIMMEL-571 dry happy" 2>&1) || rc=$?
printf '%s\n' "$out" | awk '{print "  > "$0}'
assert_rc "sw5: dry-run happy exits 0" "0" "$rc"
assert_contains "sw5: dry-run names .single-writer trigger" ".single-writer" "$out"
if grepq "$out" "HANDOVER_DIRECT_MAIN"; then
    echo "  FAIL: sw5: dry-run mislabels trigger as HANDOVER_DIRECT_MAIN"; FAIL=$((FAIL+1))
else
    echo "  PASS: sw5: dry-run does not mislabel the trigger"; PASS=$((PASS+1))
fi
assert_eq "sw5: dry-run leaves HEAD untouched" "$sw5_before" "$(git -C "$SW_REPO" rev-parse HEAD)"

# T-sw6: dry-run parked — marker + parked → plan reveals the refusal, no commit.
sw_prepare handover/HIMMEL-571-x
echo "sw dry parked" > "$SW_REPO/handovers/$SLUG/sw6.md"
sw6_before=$(git -C "$SW_REPO" rev-parse HEAD)
rc=0; out=$(run_sw_auto_commit --dry-run --no-push "HIMMEL-571 dry parked" 2>&1) || rc=$?
printf '%s\n' "$out" | awk '{print "  > "$0}'
assert_rc "sw6: dry-run parked exits 0" "0" "$rc"
assert_contains "sw6: dry-run reveals the refusal" "would REFUSE (exit 7)" "$out"
assert_eq "sw6: dry-run leaves HEAD untouched" "$sw6_before" "$(git -C "$SW_REPO" rev-parse HEAD)"

# T-sw7: fail-open — marker + parked but origin/HEAD UNRESOLVABLE → must NOT
# refuse (and must NOT abort with git's 128 under pipefail); commits on the
# current branch with a WARN. This is the documented fail-open; without the
# `|| true` guard in _default_branch the script would abort (exit 128).
# Run LAST: it deletes origin/HEAD on the shared SW_REPO.
sw_prepare handover/HIMMEL-571-x
git -C "$SW_REPO" remote set-head origin -d >/dev/null 2>&1 \
  || git -C "$SW_REPO" update-ref -d refs/remotes/origin/HEAD 2>/dev/null || true
echo "sw failopen" > "$SW_REPO/handovers/$SLUG/sw7.md"
sw7_before=$(git -C "$SW_REPO" rev-parse HEAD)
rc=0; out=$(run_sw_auto_commit --no-push "HIMMEL-571 failopen" 2>&1) || rc=$?
printf '%s\n' "$out" | awk '{print "  > "$0}'
assert_rc "sw7: fail-open does not refuse or abort (exit 0)" "0" "$rc"
assert_eq "sw7: fail-open commits on the current branch" "handover/HIMMEL-571-x" "$(git -C "$SW_REPO" rev-parse --abbrev-ref HEAD)"
if [ "$sw7_before" != "$(git -C "$SW_REPO" rev-parse HEAD)" ]; then
    echo "  PASS: sw7: commit landed (fail-open)"; PASS=$((PASS+1))
else
    echo "  FAIL: sw7: no commit landed"; FAIL=$((FAIL+1))
fi
assert_contains "sw7: warns about unresolvable origin/HEAD" "could not resolve origin/HEAD" "$out"

# HIMMEL-1830/1831: leg-split guard (exit 8). Own fresh repo + bare origin,
# same shape as the single-writer block above, to keep these cases isolated.

echo "TEST: HIMMEL-1830/1831 leg-split guard"

LS_ORIGIN="$TMP_ROOT/ls-origin.git"
LS_REPO="$TMP_ROOT/ls"
git init -q --bare "$LS_ORIGIN"
(
    cd "$TMP_ROOT"
    git clone -q "$LS_ORIGIN" ls
    cd ls
    git -c user.email=t@test.com -c user.name=test commit -q --allow-empty -m "init ls"
    git -c user.email=t@test.com -c user.name=test push -q origin main 2>/dev/null \
      || git -c user.email=t@test.com -c user.name=test push -q origin HEAD:main
    git branch -m main 2>/dev/null || true
)
mkdir -p "$LS_REPO/handovers/$SLUG"

run_ls_auto_commit() {
    (
        cd "$HIMMEL_FAKE"
        # shellcheck disable=SC2030,SC2031  # subshell-scoped export is intentional
        export HANDOVER_DIR="$LS_REPO/handovers"
        env GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=t@test.com \
            GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=t@test.com \
            "$@"
    )
}

ls_prepare() {
    git -C "$LS_REPO" checkout -q main
    git -C "$LS_REPO" reset -q --hard HEAD
    git -C "$LS_REPO" clean -fdq
    mkdir -p "$LS_REPO/handovers/$SLUG"
}

# T-ls1: two never-committed files, same stem -> refuse (exit 8), nothing committed.
ls_prepare
echo "state" > "$LS_REPO/handovers/$SLUG/HIMMEL-654-dispatch-session-25.md"
echo "orders" > "$LS_REPO/handovers/$SLUG/HIMMEL-654-dispatch-session-26.md"
ls1_before=$(git -C "$LS_REPO" rev-parse HEAD)
rc=0; out=$(run_ls_auto_commit bash "$SCRIPT_UNDER_TEST" --no-push "HIMMEL-654 leg split" 2>&1) || rc=$?
printf '%s\n' "$out" | awk '{print "  > "$0}'
assert_rc "ls1: two never-committed siblings refuses with exit 8" "8" "$rc"
assert_contains "ls1: names both files" "session-25.md" "$out"
assert_contains "ls1: names both files (2)" "session-26.md" "$out"
assert_eq "ls1: no commit created (HEAD unchanged)" "$ls1_before" "$(git -C "$LS_REPO" rev-parse HEAD)"

# T-ls2: the SAME two files, but the guard is overridden -> commits normally.
ls2_before=$(git -C "$LS_REPO" rev-parse HEAD)
rc=0; out=$(run_ls_auto_commit env HANDOVER_LEG_SPLIT_OK=1 bash "$SCRIPT_UNDER_TEST" --no-push "HIMMEL-654 leg split override" 2>&1) || rc=$?
printf '%s\n' "$out" | awk '{print "  > "$0}'
assert_rc "ls2: HANDOVER_LEG_SPLIT_OK=1 overrides, commits (exit 0)" "0" "$rc"
if [ "$ls2_before" != "$(git -C "$LS_REPO" rev-parse HEAD)" ]; then
    echo "  PASS: ls2: commit landed"; PASS=$((PASS+1))
else
    echo "  FAIL: ls2: no commit landed"; FAIL=$((FAIL+1))
fi

# T-ls3: one BRAND NEW file whose sibling was already committed in a prior
# leg (the normal 95-legs-out-of-96 shape) -> commits fine, no refusal.
ls_prepare
echo "leg n-1, already closed" > "$LS_REPO/handovers/$SLUG/foo-1.md"
run_ls_auto_commit bash "$SCRIPT_UNDER_TEST" --no-push "HIMMEL-654 leg n-1" >/dev/null 2>&1
echo "leg n" > "$LS_REPO/handovers/$SLUG/foo-2.md"
rc=0; out=$(run_ls_auto_commit bash "$SCRIPT_UNDER_TEST" --no-push "HIMMEL-654 leg n" 2>&1) || rc=$?
printf '%s\n' "$out" | awk '{print "  > "$0}'
assert_rc "ls3: sibling with commit history never trips the guard" "0" "$rc"

# T-ls4: two DIFFERENT series (different stems) landing in one commit —
# a rename / parallel-branch shape — must NOT trip the guard.
ls_prepare
echo "series A" > "$LS_REPO/handovers/$SLUG/series-a-2.md"
echo "series B" > "$LS_REPO/handovers/$SLUG/series-b-2.md"
rc=0; out=$(run_ls_auto_commit bash "$SCRIPT_UNDER_TEST" --no-push "HIMMEL-654 two series" 2>&1) || rc=$?
printf '%s\n' "$out" | awk '{print "  > "$0}'
assert_rc "ls4: two different series in one commit does not trip the guard" "0" "$rc"

# T-ls5: --dry-run reveals the refusal but leaves HEAD untouched.
ls_prepare
echo "state" > "$LS_REPO/handovers/$SLUG/HIMMEL-999-x-5.md"
echo "orders" > "$LS_REPO/handovers/$SLUG/HIMMEL-999-x-6.md"
ls5_before=$(git -C "$LS_REPO" rev-parse HEAD)
rc=0; out=$(run_ls_auto_commit bash "$SCRIPT_UNDER_TEST" --dry-run --no-push "HIMMEL-999 dry split" 2>&1) || rc=$?
printf '%s\n' "$out" | awk '{print "  > "$0}'
assert_rc "ls5: dry-run exits 0" "0" "$rc"
assert_contains "ls5: dry-run reveals the refusal" "would REFUSE (exit 8)" "$out"
assert_eq "ls5: dry-run leaves HEAD untouched" "$ls5_before" "$(git -C "$LS_REPO" rev-parse HEAD)"

# T-ls6: retry path — one file is already staged from a failed commit, then a
# second file appears. The post-stage index guard must still see and refuse both.
ls_prepare
ls6_first="$LS_REPO/handovers/$SLUG/retry-session-25.md"
echo "state from failed commit" > "$ls6_first"
git -C "$LS_REPO" add -- "$ls6_first"
echo "orders from retry" > "$LS_REPO/handovers/$SLUG/retry-session-26.md"
ls6_before=$(git -C "$LS_REPO" rev-parse HEAD)
rc=0; out=$(run_ls_auto_commit bash "$SCRIPT_UNDER_TEST" --no-push "HIMMEL-654 staged retry" 2>&1) || rc=$?
printf '%s\n' "$out" | awk '{print "  > "$0}'
assert_rc "ls6: staged retry refuses with exit 8" "8" "$rc"
assert_contains "ls6: staged retry names first file" "retry-session-25.md" "$out"
assert_contains "ls6: staged retry names second file" "retry-session-26.md" "$out"
assert_eq "ls6: staged retry creates no commit" "$ls6_before" "$(git -C "$LS_REPO" rev-parse HEAD)"

# T-ls7: supported unnumbered leg-1 spelling and numbered leg 2 are one series.
ls_prepare
echo "leg one" > "$LS_REPO/handovers/$SLUG/unnumbered-series.md"
echo "leg two" > "$LS_REPO/handovers/$SLUG/unnumbered-series-2.md"
rc=0; out=$(run_ls_auto_commit bash "$SCRIPT_UNDER_TEST" --no-push "HIMMEL-654 unnumbered leg one" 2>&1) || rc=$?
printf '%s\n' "$out" | awk '{print "  > "$0}'
assert_rc "ls7: unnumbered leg 1 plus leg 2 refuses" "8" "$rc"
assert_contains "ls7: names unnumbered leg 1" "unnumbered-series.md" "$out"
assert_contains "ls7: names numbered leg 2" "unnumbered-series-2.md" "$out"

# T-ls8: identical basenames/stems in different ticket directories are
# unrelated series and must not collide.
ls_prepare
mkdir -p "$LS_REPO/handovers/$SLUG/ticket-a" "$LS_REPO/handovers/$SLUG/ticket-b"
echo "ticket A" > "$LS_REPO/handovers/$SLUG/ticket-a/next-session-2.md"
echo "ticket B" > "$LS_REPO/handovers/$SLUG/ticket-b/next-session-3.md"
rc=0; out=$(run_ls_auto_commit bash "$SCRIPT_UNDER_TEST" --no-push "HIMMEL-654 separate dirs" 2>&1) || rc=$?
printf '%s\n' "$out" | awk '{print "  > "$0}'
assert_rc "ls8: same stem in separate parent dirs commits" "0" "$rc"

# T-ls9: a legal newline in the parent path stays one NUL-delimited path and
# does not bypass either the *.md pre-check or the staged-additions guard.
ls_prepare
ls9_dir="$LS_REPO/handovers/$SLUG/"$'line\nbreak'
mkdir -p "$ls9_dir"
echo "state" > "$ls9_dir/newline-session-7.md"
echo "orders" > "$ls9_dir/newline-session-8.md"
rc=0; out=$(run_ls_auto_commit bash "$SCRIPT_UNDER_TEST" --no-push "HIMMEL-654 newline path" 2>&1) || rc=$?
printf '%s\n' "$out" | awk '{print "  > "$0}'
assert_rc "ls9: newline parent path refuses with exit 8" "8" "$rc"
assert_contains "ls9: names first newline-path file" "newline-session-7.md" "$out"
assert_contains "ls9: names second newline-path file" "newline-session-8.md" "$out"

# T-ls10 (HIMMEL-1839): a staged addition pair OUTSIDE $rel_root that collides
# on the widened stem rule (foo.md + foo-2.md) must NOT trip the guard — the
# staged-additions queries must be scoped to $rel_root, not the whole repo.
# One legit in-root file gets the run past the earlier *.md pre-check.
ls_prepare
echo "unrelated vault note" > "$LS_REPO/foo.md"
echo "unrelated vault note, later" > "$LS_REPO/foo-2.md"
git -C "$LS_REPO" add -- foo.md foo-2.md
echo "real leg" > "$LS_REPO/handovers/$SLUG/HIMMEL-1839-real-leg.md"
ls10_before=$(git -C "$LS_REPO" rev-parse HEAD)
rc=0; out=$(run_ls_auto_commit bash "$SCRIPT_UNDER_TEST" --no-push "HIMMEL-1839 out-of-root collision" 2>&1) || rc=$?
printf '%s\n' "$out" | awk '{print "  > "$0}'
assert_rc "ls10: out-of-root stem collision does not trip the guard" "0" "$rc"
if [ "$ls10_before" != "$(git -C "$LS_REPO" rev-parse HEAD)" ]; then
    echo "  PASS: ls10: commit landed"; PASS=$((PASS+1))
else
    echo "  FAIL: ls10: no commit landed"; FAIL=$((FAIL+1))
fi

# T-ls11: same out-of-root colliding pair present, but this time the IN-ROOT
# pair also collides — the guard must still fire for the in-root pair, proving
# the $rel_root scoping narrowed the query rather than disabling the guard.
ls_prepare
echo "unrelated vault note" > "$LS_REPO/bar.md"
echo "unrelated vault note, later" > "$LS_REPO/bar-2.md"
git -C "$LS_REPO" add -- bar.md bar-2.md
echo "state" > "$LS_REPO/handovers/$SLUG/HIMMEL-1839-inroot-25.md"
echo "orders" > "$LS_REPO/handovers/$SLUG/HIMMEL-1839-inroot-26.md"
ls11_before=$(git -C "$LS_REPO" rev-parse HEAD)
rc=0; out=$(run_ls_auto_commit bash "$SCRIPT_UNDER_TEST" --no-push "HIMMEL-1839 in-root still fires" 2>&1) || rc=$?
printf '%s\n' "$out" | awk '{print "  > "$0}'
assert_rc "ls11: in-root collision still refuses with exit 8" "8" "$rc"
assert_contains "ls11: names first in-root file" "inroot-25.md" "$out"
assert_contains "ls11: names second in-root file" "inroot-26.md" "$out"
assert_eq "ls11: no commit created (HEAD unchanged)" "$ls11_before" "$(git -C "$LS_REPO" rev-parse HEAD)"

# T-ls12 (CR finding, codex-1 Important): two bare ticket-ID filenames
# ("HIMMEL-1830.md" + "HIMMEL-1831.md") must NOT collide. A bare all-caps
# stem ("HIMMEL") looks like nothing but a JIRA project key, so both parse
# as stem="HIMMEL" (the ticket's own number gets mistaken for a leg number)
# unless the guard specifically excludes that shape -- two unrelated
# tickets' one-off notes would otherwise false-refuse a commit with no
# actual split.
ls_prepare
echo "note for 1830" > "$LS_REPO/handovers/$SLUG/HIMMEL-1830.md"
echo "note for 1831" > "$LS_REPO/handovers/$SLUG/HIMMEL-1831.md"
ls12_before=$(git -C "$LS_REPO" rev-parse HEAD)
rc=0; out=$(run_ls_auto_commit bash "$SCRIPT_UNDER_TEST" --no-push "HIMMEL-1830 and HIMMEL-1831 notes" 2>&1) || rc=$?
printf '%s\n' "$out" | awk '{print "  > "$0}'
assert_rc "ls12: bare ticket-ID filenames do not trip the guard" "0" "$rc"
if [ "$ls12_before" != "$(git -C "$LS_REPO" rev-parse HEAD)" ]; then
    echo "  PASS: ls12: commit landed"; PASS=$((PASS+1))
else
    echo "  FAIL: ls12: no commit landed"; FAIL=$((FAIL+1))
fi

# T-ls13 (CR finding, codex-1 Important): the guard's own documented minimal
# example -- two never-committed lowercase bare-stem siblings ("foo-25.md" +
# "foo-26.md") -- must still trip the guard. A blanket "stem needs a hyphen"
# fix would have silently stopped catching this; only all-caps bare stems
# (ticket-key shaped) are excluded, not every single-token stem.
ls_prepare
echo "leg 25" > "$LS_REPO/handovers/$SLUG/foo-25.md"
echo "leg 26" > "$LS_REPO/handovers/$SLUG/foo-26.md"
ls13_before=$(git -C "$LS_REPO" rev-parse HEAD)
rc=0; out=$(run_ls_auto_commit bash "$SCRIPT_UNDER_TEST" --no-push "foo split leg" 2>&1) || rc=$?
printf '%s\n' "$out" | awk '{print "  > "$0}'
assert_rc "ls13: lowercase bare-stem siblings still refuse with exit 8" "8" "$rc"
assert_contains "ls13: names first bare-stem file" "foo-25.md" "$out"
assert_contains "ls13: names second bare-stem file" "foo-26.md" "$out"
assert_eq "ls13: no commit created (HEAD unchanged)" "$ls13_before" "$(git -C "$LS_REPO" rev-parse HEAD)"

# T-ls14: the guard's other documented minimal example -- the unnumbered
# leg-1 spelling ("foo.md") plus a never-committed leg 2 ("foo-2.md") --
# must also still trip the guard.
ls_prepare
echo "leg 1" > "$LS_REPO/handovers/$SLUG/foo.md"
echo "leg 2" > "$LS_REPO/handovers/$SLUG/foo-2.md"
ls14_before=$(git -C "$LS_REPO" rev-parse HEAD)
rc=0; out=$(run_ls_auto_commit bash "$SCRIPT_UNDER_TEST" --no-push "foo unnumbered split leg" 2>&1) || rc=$?
printf '%s\n' "$out" | awk '{print "  > "$0}'
assert_rc "ls14: unnumbered leg-1 plus leg-2 bare stem still refuses" "8" "$rc"
assert_eq "ls14: no commit created (HEAD unchanged)" "$ls14_before" "$(git -C "$LS_REPO" rev-parse HEAD)"

# Summary --------------------------------------------------------------

echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
