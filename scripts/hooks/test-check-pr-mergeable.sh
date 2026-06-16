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
FAKE_GH="$TMP_ROOT/gh-fake.sh"
cat >"$FAKE_GH" <<'FAKE'
#!/usr/bin/env bash
case "$1 $2" in
    "auth status")
        [ "${FAKE_GH_AUTH:-ok}" = "ok" ] && exit 0 || exit 1
        ;;
    "pr view")
        if [ "${FAKE_GH_NO_PR:-0}" = "1" ]; then
            echo "null"; exit 1
        fi
        # Emit a JSON object compatible with the script's grep-based parser.
        mergeable="${FAKE_GH_MERGEABLE:-MERGEABLE}"
        printf '{"m":"%s","u":"https://test/pull/42","n":42}\n' "$mergeable"
        exit 0
        ;;
esac
exit 0
FAKE
chmod +x "$FAKE_GH"

# tmp repo on a non-main branch
REPO="$TMP_ROOT/repo"
git init -q --initial-branch=main "$REPO" 2>/dev/null || git init -q "$REPO"
(
    cd "$REPO" || exit 99
    git -c user.email=t@test.com -c user.name=test commit -q --allow-empty -m "init"
    git branch -m main 2>/dev/null || true
    git checkout -q -b feat/test
)

# Hook accepts GH_CMD env override (HIMMEL-136 refactor). Pass the fake
# directly via GH_CMD — avoids Git Bash PATH-lookup quirks where a
# bare `gh` script without `.exe` extension fails to override the real
# gh binary in PATH.
# shellcheck disable=SC2120
run() {
    (
        # shellcheck disable=SC2030,SC2031,SC2164
        cd "$REPO" || exit 99
        # shellcheck disable=SC2030,SC2031
        export GH_CMD="bash $FAKE_GH"
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

# Test 4: MERGEABLE -> exit 0 -----------------------------------------
echo "TEST: PR MERGEABLE -> exit 0"
rc=0
# shellcheck disable=SC2030,SC2031
out=$(export FAKE_GH_MERGEABLE=MERGEABLE; run 2>&1) || rc=$?
assert_rc "mergeable rc=0" "0" "$rc"

# Test 5: CONFLICTING -> exit 1 ---------------------------------------
echo "TEST: PR CONFLICTING -> exit 1 + helpful stderr"
rc=0
# shellcheck disable=SC2030,SC2031
out=$(export FAKE_GH_MERGEABLE=CONFLICTING; run 2>&1) || rc=$?
assert_rc "conflicting rc=1" "1" "$rc"
assert_contains "stderr mentions CONFLICTING" "CONFLICTING state" "$out"
assert_contains "stderr suggests inspect"     "gh pr view"        "$out"
assert_contains "stderr names bypass var"     "SKIP_PR_MERGEABLE"  "$out"

# Test 6: SKIP_PR_MERGEABLE=1 short-circuits --------------------------
echo "TEST: SKIP_PR_MERGEABLE=1 short-circuits even on CONFLICTING"
rc=0
# shellcheck disable=SC2030,SC2031
out=$(export SKIP_PR_MERGEABLE=1 FAKE_GH_MERGEABLE=CONFLICTING; run 2>&1) || rc=$?
assert_rc "skip rc=0" "0" "$rc"
assert_contains "stderr explains skip" "SKIP_PR_MERGEABLE=1" "$out"

# Test 7: stdin drained -----------------------------------------------
echo "TEST: multi-line stdin drained without deadlock"
rc=0
out=$(
    # shellcheck disable=SC2030,SC2031,SC2164
    cd "$REPO" || exit 99
    # shellcheck disable=SC2030,SC2031
    export GH_CMD="bash $FAKE_GH"
    printf 'a b c d\ne f g h\n' | bash "$HOOK" 2>&1
) || rc=$?
assert_rc "multi-line stdin rc=0" "0" "$rc"

echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
