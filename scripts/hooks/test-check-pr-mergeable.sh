#!/usr/bin/env bash
# Smoke test for scripts/hooks/check-pr-mergeable.sh (HIMMEL-136).
#
# Covers:
#   1. main branch -> exit 0 (no gate).
#   2. gh missing -> exit 0 (best-effort).
#   3. No PR -> exit 0.
#   4. PR MERGEABLE -> exit 0.
#   5. PR CONFLICTING -> exit 1 + helpful stderr.
#   6. SKIP_PR_MERGEABLE=1 short-circuits even on CONFLICTING.
#   7. Stdin drained (pipe with multi-line input does not deadlock).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/check-pr-mergeable.sh"

PASS=0; FAIL=0; TMP_ROOT=""
# shellcheck disable=SC2329,SC2317
cleanup() {
    if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
        rm -rf "$TMP_ROOT" 2>/dev/null || true
    fi
}
trap cleanup EXIT
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }
assert_contains() {
    local n="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then pass "$n"; else fail "$n" "missing: $needle"; fi
}
assert_rc() {
    local n="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$n"; else fail "$n" "want=$want got=$got"; fi
}

TMP_ROOT=$(mktemp -d); if command -v cygpath >/dev/null 2>&1; then TMP_ROOT=$(cygpath -m "$TMP_ROOT"); fi

# Fake gh: behavior driven by FAKE_GH_* env.
#
# HIMMEL-1232: forge_pr_mergeable (github) now reads only base+head refs from gh
# and computes the conflict LOCALLY via `git merge-tree`. So the fake emits
# "<base> <headoid>" (a synchronous field read), and the test drives a clean vs
# conflicting verdict by pointing FAKE_GH_HEAD at a real clean / conflicting
# commit in the repo below — not by returning a mocked mergeable string.
FAKE_GH="$TMP_ROOT/gh-fake.sh"
cat >"$FAKE_GH" <<'FAKE'
#!/usr/bin/env bash
case "$1 $2" in
    "auth status")
        [ "${FAKE_GH_AUTH:-ok}" = "ok" ] && exit 0 || exit 1
        ;;
    "pr view")
        if [ "${FAKE_GH_NO_PR:-0}" = "1" ]; then
            # gh pr view exits non-zero with no stdout when no PR exists; the
            # forge backend's `|| return 0` turns that into an empty verdict.
            exit 1
        fi
        # forge_pr_mergeable calls `gh pr view <branch> --json
        # baseRefName,headRefOid --jq ...`, so gh emits "<base> <headoid>".
        printf '%s %s\n' "${FAKE_GH_BASE:-main}" "${FAKE_GH_HEAD:?FAKE_GH_HEAD unset}"
        exit 0
        ;;
esac
exit 0
FAKE
chmod +x "$FAKE_GH"

# tmp repo on a non-main branch, with real clean + conflicting branches so
# `git merge-tree` produces a genuine verdict.
REPO="$TMP_ROOT/repo"
git init -q --initial-branch=main "$REPO" 2>/dev/null || git init -q "$REPO"
(
    cd "$REPO" || exit 99
    git config user.email t@test.com; git config user.name test
    printf 'a\nb\nc\n' > f; git add f; git commit -q -m "init"
    git branch -m main 2>/dev/null || true
    # clean branch: adds an unrelated file — no overlap with main.
    git checkout -q -b feat/clean
    echo x > g; git add g; git commit -q -m clean
    # conflict branch off init changes line 2; main then changes the same line.
    git checkout -q -b feat/conflict main
    printf 'a\nTHEIRS\nc\n' > f; git add f; git commit -q -m theirs
    git checkout -q main
    printf 'a\nOURS\nc\n' > f; git add f; git commit -q -m ours
    # feat/test is the branch under test (the hook reads its NAME); its own
    # content is irrelevant — the fake injects the head commit to check.
    git checkout -q -b feat/test main
    # Forge seam (HIMMEL-326): the hook resolves the forge from origin; a github
    # origin selects the github backend (gh pr view via the GH_CMD stub).
    git remote add origin https://github.com/test/test.git
)
CLEAN_OID=$(git -C "$REPO" rev-parse feat/clean)
CONFLICT_OID=$(git -C "$REPO" rev-parse feat/conflict)

# The forge github backend invokes "${GH_CMD}" by its absolute path (no PATH
# lookup, no word-split), so GH_CMD must be a single executable — point it at
# the +x fake directly (HIMMEL-326; was `bash $FAKE_GH` before the seam).
# shellcheck disable=SC2120
run() {
    (
        # shellcheck disable=SC2030,SC2031,SC2164
        cd "$REPO" || exit 99
        # shellcheck disable=SC2030,SC2031
        export GH_CMD="$FAKE_GH"
        printf 'refs/heads/feat/test sha refs/heads/feat/test sha\n' | bash "$HOOK" "$@"
    )
}

# Test 1: main branch -> exit 0 ---------------------------------------
echo "TEST: main branch exits 0"
( cd "$REPO" || exit 99; git checkout -q main )
rc=0
out=$( cd "$REPO" || exit 99; printf '' | bash "$HOOK" 2>&1 ) || rc=$?
assert_rc "main rc=0" "0" "$rc"
( cd "$REPO" || exit 99; git checkout -q feat/test )

# Test 1b: master branch -> exit 0 (HIMMEL-297) -----------------------
echo "TEST: master branch exits 0 (HIMMEL-297 — master is a protected default too)"
( cd "$REPO" || exit 99; git checkout -q -b master )
rc=0
out=$( cd "$REPO" || exit 99; printf '' | bash "$HOOK" 2>&1 ) || rc=$?
assert_rc "master rc=0" "0" "$rc"
( cd "$REPO" || exit 99; git checkout -q feat/test; git branch -D master 2>/dev/null || true )

# Test 2: gh missing -> exit 0 ----------------------------------------
echo "TEST: gh missing -> best-effort exit 0"
rc=0
out=$(
    cd "$REPO" || exit 99
    # Set GH_CMD to a non-existent binary to simulate "gh missing".
    GH_CMD="/no/such/gh-binary" bash "$HOOK" </dev/null 2>&1
) || rc=$?
assert_rc "gh-missing rc=0" "0" "$rc"
assert_contains "stderr explains best-effort" "best-effort" "$out"

# Test 3: no PR -> exit 0 ---------------------------------------------
echo "TEST: no PR found -> exit 0"
rc=0
# shellcheck disable=SC2030,SC2031
out=$(export FAKE_GH_NO_PR=1; run 2>&1) || rc=$?
assert_rc "no-pr rc=0" "0" "$rc"

# Test 4: clean branch -> MERGEABLE -> exit 0 -------------------------
echo "TEST: clean branch (merge-tree MERGEABLE) -> exit 0"
rc=0
# shellcheck disable=SC2030,SC2031
out=$(export FAKE_GH_HEAD="$CLEAN_OID"; run 2>&1) || rc=$?
assert_rc "mergeable rc=0" "0" "$rc"

# Test 5: conflicting branch -> CONFLICTING -> exit 1 -----------------
echo "TEST: conflicting branch (merge-tree CONFLICTING) -> exit 1 + helpful stderr"
rc=0
# shellcheck disable=SC2030,SC2031
out=$(export FAKE_GH_HEAD="$CONFLICT_OID"; run 2>&1) || rc=$?
assert_rc "conflicting rc=1" "1" "$rc"
assert_contains "stderr mentions CONFLICTING" "CONFLICTING state" "$out"
assert_contains "stderr suggests inspect"     "gh pr view"        "$out"
assert_contains "stderr names bypass var"     "SKIP_PR_MERGEABLE"  "$out"

# Test 6: SKIP_PR_MERGEABLE=1 short-circuits --------------------------
echo "TEST: SKIP_PR_MERGEABLE=1 short-circuits even on a conflicting branch"
rc=0
# shellcheck disable=SC2030,SC2031
out=$(export SKIP_PR_MERGEABLE=1 FAKE_GH_HEAD="$CONFLICT_OID"; run 2>&1) || rc=$?
assert_rc "skip rc=0" "0" "$rc"
assert_contains "stderr explains skip" "SKIP_PR_MERGEABLE=1" "$out"

# Test 7: stdin drained -----------------------------------------------
echo "TEST: multi-line stdin drained without deadlock"
rc=0
out=$(
    # shellcheck disable=SC2030,SC2031,SC2164
    cd "$REPO" || exit 99
    # shellcheck disable=SC2030,SC2031
    export GH_CMD="$FAKE_GH" FAKE_GH_HEAD="$CLEAN_OID"
    printf 'a b c d\ne f g h\n' | bash "$HOOK" 2>&1
) || rc=$?
assert_rc "multi-line stdin rc=0" "0" "$rc"

echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
