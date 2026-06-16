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
    if printf '%s' "$haystack" | grep -q -- "$needle"; then
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

mkdir -p "$HANDOVER_REPO/handovers/yotam"

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

echo "first content" > "$HANDOVER_REPO/handovers/yotam/notes.md"
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
# exists on a feature branch (handovers/yotam/notes.md was added on
# handover/HIMMEL-140-... and main has no commits touching that path).
mkdir -p "$HANDOVER_REPO/handovers/yotam"

echo "more content" > "$HANDOVER_REPO/handovers/yotam/notes.md"
out=$(run_auto_commit "HIMMEL-140 add more notes" 2>&1)
printf '%s\n' "$out" | awk '{print "  > "$0}'
# Slug differs because message text differs; assert branch name pattern
assert_contains "reuses prefix on second invocation" "handover/HIMMEL-140-" "$out"

# Re-run with EXACT same message → branch should already exist; checkout
# path is taken.
echo "exact same message" > "$HANDOVER_REPO/handovers/yotam/notes.md"
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
# exists on a feature branch (handovers/yotam/notes.md was added on
# handover/HIMMEL-140-... and main has no commits touching that path).
mkdir -p "$HANDOVER_REPO/handovers/yotam"
echo "untagged content" > "$HANDOVER_REPO/handovers/yotam/freeform.md"
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
# exists on a feature branch (handovers/yotam/notes.md was added on
# handover/HIMMEL-140-... and main has no commits touching that path).
mkdir -p "$HANDOVER_REPO/handovers/yotam"
before_branch=$(git -C "$HANDOVER_REPO" rev-parse --abbrev-ref HEAD)
echo "direct content" > "$HANDOVER_REPO/handovers/yotam/direct.md"
out=$(
    cd "$HIMMEL_FAKE"
    # shellcheck disable=SC2031  # subshell-scoped export is intentional
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
# exists on a feature branch (handovers/yotam/notes.md was added on
# handover/HIMMEL-140-... and main has no commits touching that path).
mkdir -p "$HANDOVER_REPO/handovers/yotam"
echo "nopush content" > "$HANDOVER_REPO/handovers/yotam/nopush.md"
out=$(run_auto_commit --no-push "HIMMEL-999 nopush check" 2>&1)
printf '%s\n' "$out" | awk '{print "  > "$0}'
if printf '%s' "$out" | grep -q "auto-commit: pushed."; then
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
# exists on a feature branch (handovers/yotam/notes.md was added on
# handover/HIMMEL-140-... and main has no commits touching that path).
mkdir -p "$HANDOVER_REPO/handovers/yotam"
sha_before=$(git -C "$HANDOVER_REPO" rev-parse HEAD)
echo "dryrun content" > "$HANDOVER_REPO/handovers/yotam/dryrun.md"
out=$(run_auto_commit --dry-run "HIMMEL-998 dry run" 2>&1)
printf '%s\n' "$out" | awk '{print "  > "$0}'
sha_after=$(git -C "$HANDOVER_REPO" rev-parse HEAD)
assert_eq "--dry-run leaves HEAD untouched" "$sha_before" "$sha_after"
assert_contains "--dry-run announces target branch" \
    "handover/HIMMEL-998-dry-run" "$out"

# Clean up dryrun.md so it doesn't bleed into later tests.
rm -f "$HANDOVER_REPO/handovers/yotam/dryrun.md"

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
    mkdir -p handovers/yotam
    echo "from worker" > handovers/yotam/worker.md
    git -c user.email=t@test.com -c user.name=test add handovers/yotam/worker.md
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
mkdir -p "$HANDOVER_REPO/handovers/yotam"
echo "from primary" > "$HANDOVER_REPO/handovers/yotam/cross-machine-add.md"

out=$(run_auto_commit "HIMMEL-777 cross machine" 2>&1)
printf '%s\n' "$out" | awk '{print "  > "$0}'
assert_contains "fetches + tracks origin branch" \
    "handover/HIMMEL-777-cross-machine" "$out"
assert_branch_exists "tracking branch exists locally" \
    "$HANDOVER_REPO" "handover/HIMMEL-777-cross-machine"

# The primary clone's tip should now contain BOTH the worker's seed file
# AND the local cross-machine-add.md — proving the local commit landed
# on top of the worker's commit, not on a fresh branch off main.
if git -C "$HANDOVER_REPO" log --oneline handover/HIMMEL-777-cross-machine -- handovers/yotam/worker.md 2>/dev/null | grep -q "."; then
    echo "  PASS: tracked branch contains worker seed commit"
    PASS=$((PASS+1))
else
    echo "  FAIL: tracked branch missing worker seed commit (suggests fetch+track didn't happen)"
    FAIL=$((FAIL+1))
fi

# Summary --------------------------------------------------------------

echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
