#!/usr/bin/env bash
# Smoke test for scripts/hooks/check-no-force-push.sh (HIMMEL-136).
#
# Covers:
#   1. New remote branch (remote_sha all-zero) -> exit 0 (not a force).
#   2. Branch deletion (local_sha all-zero) -> exit 0.
#   3. Fast-forward push -> exit 0.
#   4. Force-push to non-main -> warn + exit 0.
#   5. Force-push to main -> exit 1 + helpful stderr.
#   6. SKIP_FORCE_PUSH_GATE=1 silences non-main warnings but does NOT
#      bypass main refuse.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/check-no-force-push.sh"

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
assert_rc() {
    local n="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$n"; else fail "$n" "want=$want got=$got"; fi
}
assert_contains() {
    local n="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then pass "$n"; else fail "$n" "missing: $needle"; fi
}

TMP_ROOT=$(mktemp -d); if command -v cygpath >/dev/null 2>&1; then TMP_ROOT=$(cygpath -m "$TMP_ROOT"); fi

# tmp repo with 3 commits on main + 1 diverging commit on feat/x.
REPO="$TMP_ROOT/repo"
git init -q --initial-branch=main "$REPO" 2>/dev/null || git init -q "$REPO"
(
    cd "$REPO" || exit 99
    git -c user.email=t@test.com -c user.name=test commit -q --allow-empty -m "c1"
    git branch -m main 2>/dev/null || true
    git -c user.email=t@test.com -c user.name=test commit -q --allow-empty -m "c2"
    git -c user.email=t@test.com -c user.name=test commit -q --allow-empty -m "c3"
    git checkout -q -b feat/x
    git -c user.email=t@test.com -c user.name=test commit -q --allow-empty -m "c4-divergent"
)
SHA_C2=$(git -C "$REPO" rev-parse main~1)
SHA_C3=$(git -C "$REPO" rev-parse main)
SHA_C4=$(git -C "$REPO" rev-parse feat/x)
Z=0000000000000000000000000000000000000000

run() {
    (
        # shellcheck disable=SC2164
        cd "$REPO" || exit 99
        printf '%s\n' "$1" | bash "$HOOK" 2>&1
    )
}

# Test 1: new remote branch (remote_sha = z40) ------------------------
echo "TEST: new remote branch -> exit 0"
rc=0
out=$(run "refs/heads/feat/x $SHA_C4 refs/heads/feat/x $Z") || rc=$?
assert_rc "new-branch rc=0" "0" "$rc"

# Test 2: branch deletion (local_sha = z40) ---------------------------
echo "TEST: branch deletion -> exit 0"
rc=0
out=$(run "(delete) $Z refs/heads/feat/x $SHA_C4") || rc=$?
assert_rc "delete rc=0" "0" "$rc"

# Test 3: fast-forward ------------------------------------------------
echo "TEST: fast-forward push -> exit 0"
# local at c3, remote at c2 → ancestor → FF.
rc=0
out=$(run "refs/heads/main $SHA_C3 refs/heads/main $SHA_C2") || rc=$?
# Wait — this would actually be a force-push-to-main test if not FF.
# c2 is an ancestor of c3, so this is FF. But it's a push to main.
# Force-push check passes (FF), but conceptually no-push-to-main would
# block. That hook isn't this hook's job. Verify rc=0.
assert_rc "ff-push rc=0" "0" "$rc"

# Test 4: force-push to non-main -> warn + exit 0 ---------------------
echo "TEST: force-push to non-main -> warn + exit 0"
# local at c4-divergent (feat/x), remote at c3 (main tip) → c3 NOT
# ancestor of c4. Non-main ref.
rc=0
out=$(run "refs/heads/feat/x $SHA_C4 refs/heads/feat/x $SHA_C3") || rc=$?
# Wait c4 IS descendant of c3 (feat/x branched off main after c3). So
# c3 IS ancestor of c4. Need a truly divergent case.
# Make a SECOND branch that diverges from c2.
git -C "$REPO" checkout -q -b feat/y "$SHA_C2"
git -C "$REPO" -c user.email=t@test.com -c user.name=test commit -q --allow-empty -m "c-divergent-from-c2"
SHA_DIVERGENT=$(git -C "$REPO" rev-parse feat/y)
# Now push local feat/y (at SHA_DIVERGENT) to remote whose tip is c3.
# c3 is NOT ancestor of SHA_DIVERGENT.
rc=0
out=$(run "refs/heads/feat/y $SHA_DIVERGENT refs/heads/feat/y $SHA_C3") || rc=$?
assert_rc "non-main force rc=0" "0" "$rc"
assert_contains "warns about force" "force-push detected" "$out"

# Test 5: force-push to main -> exit 1 --------------------------------
echo "TEST: force-push to main -> exit 1"
rc=0
out=$(run "refs/heads/main $SHA_DIVERGENT refs/heads/main $SHA_C3") || rc=$?
assert_rc "force-main rc=1" "1" "$rc"
assert_contains "stderr explains force-main" "Force-push to 'main' is not allowed" "$out"

# Test 6: SKIP_FORCE_PUSH_GATE=1 silences non-main, NOT main ----------
echo "TEST: SKIP_FORCE_PUSH_GATE=1 silences non-main"
rc=0
out=$(SKIP_FORCE_PUSH_GATE=1 run "refs/heads/feat/y $SHA_DIVERGENT refs/heads/feat/y $SHA_C3") || rc=$?
assert_rc "skip non-main rc=0" "0" "$rc"

echo "TEST: SKIP_FORCE_PUSH_GATE=1 does NOT bypass main"
rc=0
out=$(SKIP_FORCE_PUSH_GATE=1 run "refs/heads/main $SHA_DIVERGENT refs/heads/main $SHA_C3") || rc=$?
assert_rc "skip-main still refused rc=1" "1" "$rc"

echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
