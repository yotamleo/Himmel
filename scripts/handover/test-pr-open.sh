#!/usr/bin/env bash
# Smoke test for scripts/handover/pr-open.sh + pr-merge.sh (HIMMEL-141).
#
# Strategy: gh CLI is not invoked against real GitHub. Tests inject
# GH_CMD=<fake> where <fake> is a shell function that records args and
# returns canned JSON. This validates pr-open + pr-merge's branching
# logic + body construction without burning a real PR.
#
# Covers:
#   1. pr-open --dry-run on a handover/<TICKET>-<slug> branch produces
#      a body with the three required sections (Summary, Files changed,
#      Ticket) + the ticket link.
#   2. pr-open refuses (rc=3) when HEAD is not on handover/*.
#   3. pr-open routes to `gh pr create` when no PR exists.
#   4. pr-open routes to `gh pr edit` when a PR already exists.
#   5. pr-open exits 0 (best-effort) when gh pr create fails.
#   6. pr-merge --dry-run prints the squash --admin --delete-branch invocation.
#   7. pr-merge exits 0 when no PR is found for the branch.
#   8. pr-merge suppresses the worktree-held branch-delete cosmetic error.
#   9. HANDOVER_PR_AUTO=0 short-circuits pr-open (exit 0, no gh calls).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PR_OPEN="$SCRIPT_DIR/pr-open.sh"
PR_MERGE="$SCRIPT_DIR/pr-merge.sh"

PASS=0
FAIL=0
TMP_ROOT=""

# shellcheck disable=SC2329,SC2317  # invoked via trap; body reachable through it
cleanup() {
    if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
        rm -rf "$TMP_ROOT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }

assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        pass "$name"
    else
        fail "$name" "needle '$needle' missing from haystack"
    fi
}

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass "$name"
    else
        fail "$name" "expected='$expected' actual='$actual'"
    fi
}

# Setup ----------------------------------------------------------------

TMP_ROOT=$(mktemp -d)
if command -v cygpath >/dev/null 2>&1; then
    TMP_ROOT=$(cygpath -m "$TMP_ROOT")
fi
echo "test: TMP_ROOT=$TMP_ROOT"
SLUG="dpz$$"

# Fake gh CLI ---------------------------------------------------------
# Behavior is controlled by env vars set inside each test:
#   FAKE_GH_PR_LIST     — value printed when `pr list` is invoked
#   FAKE_GH_FAIL        — set to a verb (create|edit|merge) to make
#                         that subcommand exit 1
#   FAKE_GH_MERGE_OUT   — stdout for `pr merge` when failing
FAKE_GH="$TMP_ROOT/gh-fake.sh"
cat >"$FAKE_GH" <<'FAKEGH'
#!/usr/bin/env bash
# Records each invocation to $FAKE_GH_LOG and emits canned responses.
echo "gh $*" >: > "$FAKE_GH_LOG"
case "$1" in
    pr)
        case "$2" in
            list)
                printf '%s\n' "${FAKE_GH_PR_LIST:-}"
                exit 0
                ;;
            create)
                if [ "${FAKE_GH_FAIL:-}" = "create" ]; then
                    echo "fake gh: pr create failure (FAKE_GH_FAIL=create)" >&2
                    exit 1
                fi
                echo "https://github.com/test/test/pull/42"
                exit 0
                ;;
            edit)
                if [ "${FAKE_GH_FAIL:-}" = "edit" ]; then
                    echo "fake gh: pr edit failure" >&2
                    exit 1
                fi
                exit 0
                ;;
            merge)
                if [ "${FAKE_GH_FAIL:-}" = "merge" ]; then
                    printf '%s\n' "${FAKE_GH_MERGE_OUT:-fake merge failure}" >&2
                    exit 1
                fi
                exit 0
                ;;
        esac
        ;;
esac
exit 0
FAKEGH
chmod +x "$FAKE_GH"

# Set up a working git repo on a handover branch.
REPO="$TMP_ROOT/repo"
# Force `main` as the default branch — git defaults to `master` on older
# installs, which breaks --base main in later tests.
git init -q --initial-branch=main "$REPO" 2>/dev/null || git init -q "$REPO"
(
    cd "$REPO"
    # Ensure HEAD is on main, regardless of git's default-branch config.
    git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
    git -c user.email=t@test.com -c user.name=test commit -q --allow-empty -m "init"
    git branch -m main 2>/dev/null || true
    git checkout -q -b handover/HIMMEL-141-pr-finisher
    mkdir -p handovers/$SLUG
    echo "content" > handovers/$SLUG/state.md
    git -c user.email=t@test.com -c user.name=test add handovers/$SLUG/state.md
    git -c user.email=t@test.com -c user.name=test commit -q -m "handover: HIMMEL-141 seed"
    # Forge seam (HIMMEL-326): pr-open/pr-merge resolve the forge from origin.
    # A github origin makes forge_detect pick the github backend, which
    # reproduces the exact `gh` call shapes the stub + asserts below expect.
    git remote add origin https://github.com/test/test.git
)

export FAKE_GH_LOG="$TMP_ROOT/gh.log"
: > "$FAKE_GH_LOG"

# Test 1: dry-run produces required sections ---------------------------

echo "TEST: pr-open --dry-run body has Summary + Files changed + Ticket"
out=$(
    cd "$REPO"
    GH_CMD="$FAKE_GH" FAKE_GH_PR_LIST="" bash "$PR_OPEN" --dry-run --base main 2>&1
)
assert_contains "body has ## Summary"        "## Summary"        "$out"
assert_contains "body has ## Files changed"  "## Files changed"  "$out"
assert_contains "body has ## Ticket"         "## Ticket"         "$out"
assert_contains "body has HIMMEL-141 link"   "HIMMEL-141"        "$out"
assert_contains "dry-run announces create"   "would create a PR on github" "$out"

# Test 2: refuses non-handover branch ---------------------------------

echo "TEST: pr-open refuses non-handover branch"
git -C "$REPO" checkout -q main
rc=0
out=$(
    cd "$REPO"
    GH_CMD="$FAKE_GH" bash "$PR_OPEN" 2>&1
) || rc=$?
git -C "$REPO" checkout -q handover/HIMMEL-141-pr-finisher
assert_eq        "rc=3 on non-handover branch" "3" "$rc"
assert_contains  "stderr mentions handover/*"  "handover/* branch" "$out"

# Test 3: routes to pr create when no PR exists -----------------------

echo "TEST: pr-open routes to gh pr create when no PR exists"
: > "$FAKE_GH_LOG"
out=$(
    cd "$REPO"
    GH_CMD="$FAKE_GH" FAKE_GH_PR_LIST="" bash "$PR_OPEN" --base main 2>&1
)
log=$(cat "$FAKE_GH_LOG")
assert_contains "log has 'gh pr create'" "pr create" "$log"
assert_contains "log has '--head handover/HIMMEL-141-pr-finisher'" \
    "head handover/HIMMEL-141-pr-finisher" "$log"
assert_contains "log has '--base main'" "base main" "$log"

# Test 4: routes to pr edit when PR exists ----------------------------

echo "TEST: pr-open routes to gh pr edit when PR exists"
: > "$FAKE_GH_LOG"
out=$(
    cd "$REPO"
    GH_CMD="$FAKE_GH" FAKE_GH_PR_LIST="42" bash "$PR_OPEN" --base main 2>&1
)
log=$(cat "$FAKE_GH_LOG")
assert_contains "log has 'gh pr edit 42'" "pr edit 42" "$log"

# Test 5: best-effort when pr create fails ----------------------------

echo "TEST: pr-open exits 0 when gh pr create fails"
: > "$FAKE_GH_LOG"
rc=0
out=$(
    cd "$REPO"
    GH_CMD="$FAKE_GH" FAKE_GH_PR_LIST="" FAKE_GH_FAIL="create" \
        bash "$PR_OPEN" --base main 2>&1
) || rc=$?
assert_eq       "rc=0 (best-effort)" "0" "$rc"
assert_contains "stderr explains best-effort" "best-effort" "$out"

# Test 6: pr-merge --dry-run prints the plain squash-merge intent ------
# HIMMEL-224 dropped --admin from the default/dry-run; HIMMEL-326 made the
# message forge-aware. The dry-run now states intent, not a literal command.

echo "TEST: pr-merge --dry-run prints the plain squash-merge intent"
out=$(
    cd "$REPO"
    GH_CMD="$FAKE_GH" FAKE_GH_PR_LIST="42" bash "$PR_MERGE" --dry-run 2>&1
)
assert_contains "dry-run mentions squash-merge"     "squash-merge"  "$out"
assert_contains "dry-run names the PR"              "#42"           "$out"
assert_contains "dry-run names the forge"           "github"        "$out"

# Test 7: pr-merge exits 0 when no PR found ---------------------------

echo "TEST: pr-merge exits 0 when no open PR found"
rc=0
out=$(
    cd "$REPO"
    GH_CMD="$FAKE_GH" FAKE_GH_PR_LIST="" bash "$PR_MERGE" 2>&1
) || rc=$?
assert_eq       "rc=0 (nothing to merge)"      "0" "$rc"
assert_contains "stdout 'nothing to merge'"    "nothing to merge" "$out"

# Test 8: pr-merge suppresses worktree branch-delete error ------------

echo "TEST: pr-merge suppresses worktree-held branch-delete cosmetic error"
rc=0
out=$(
    cd "$REPO"
    GH_CMD="$FAKE_GH" FAKE_GH_PR_LIST="42" FAKE_GH_FAIL="merge" \
        FAKE_GH_MERGE_OUT="failed to run git: fatal: 'main' is already used by worktree at '/tmp/x'" \
        bash "$PR_MERGE" 2>&1
) || rc=$?
assert_eq       "rc=0 (cosmetic ignored)" "0" "$rc"
assert_contains "stdout mentions cosmetic-fail" "cosmetic-fail" "$out"

# Test 9: HANDOVER_PR_AUTO=0 short-circuits ---------------------------

echo "TEST: HANDOVER_PR_AUTO=0 short-circuits pr-open"
: > "$FAKE_GH_LOG"
rc=0
out=$(
    cd "$REPO"
    HANDOVER_PR_AUTO=0 GH_CMD="$FAKE_GH" bash "$PR_OPEN" 2>&1
) || rc=$?
log=$(cat "$FAKE_GH_LOG")
assert_eq       "rc=0 short-circuit" "0" "$rc"
assert_contains "stdout mentions skip" "skipping" "$out"
assert_eq       "no gh calls made" "" "$log"

# Summary ---------------------------------------------------------------

echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
