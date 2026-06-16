#!/usr/bin/env bash
# Smoke test for scripts/lib/user-slug.sh (HIMMEL-145).
#
# Covers:
#   1. $USER_SLUG set -> resolver returns its value.
#   2. $USER_SLUG unset + git config user.name set -> slugified return.
#   3. $USER_SLUG unset + git config slugifies special chars to dashes.
#   4. $USER_SLUG unset + git config missing -> rc=2, helpful stderr.
#   5. user_slug_verify prints the source on stderr + value on stdout.
#   6. Empty USER_SLUG falls through to git config (treated as unset).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/lib/user-slug.sh"

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
assert_eq() {
    local n="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$n"; else fail "$n" "want='$want' got='$got'"; fi
}
assert_contains() {
    local n="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then pass "$n"; else fail "$n" "missing: $needle"; fi
}

TMP_ROOT=$(mktemp -d)
if command -v cygpath >/dev/null 2>&1; then TMP_ROOT=$(cygpath -m "$TMP_ROOT"); fi

# Isolate from the operator's global git config so the "git config
# missing" test case can actually observe an absent user.name. HOME
# override redirects ~/.gitconfig lookup to a tmp dir we control.
ISOLATED_HOME="$TMP_ROOT/home"
mkdir -p "$ISOLATED_HOME"
export HOME="$ISOLATED_HOME"
# Also clear GIT_CONFIG_GLOBAL for git 2.32+ which has its own override.
unset GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM 2>/dev/null || true

# Each test runs in an isolated tmp repo so git config doesn't pollute
# globally.
REPO="$TMP_ROOT/repo"
git init -q "$REPO"
( cd "$REPO" && git config user.email "test@test.com" )

resolve() {
    (
        # shellcheck disable=SC2030,SC2031,SC2164
        cd "$REPO" || exit 99
        # Source the lib + call user_slug. Subshell isolates per-test
        # USER_SLUG / git config state.
        # shellcheck source=lib/user-slug.sh
        # shellcheck disable=SC1090,SC1091
        . "$LIB"
        user_slug
    )
}

# Test 1: USER_SLUG set ----------------------------------------------
echo "TEST: USER_SLUG env var set -> resolver returns it"
( cd "$REPO" && { git config --unset user.name 2>/dev/null || true; } )
out=$(USER_SLUG=alice resolve 2>/dev/null) && rc=0 || rc=$?
assert_eq "rc=0 with env" "0" "$rc"
assert_eq "value matches env" "alice" "$out"

# Test 2: git config user.name fallback ------------------------------
echo "TEST: USER_SLUG unset + git config set -> slugified return"
( cd "$REPO" && git config user.name "Bob Marley" )
out=$(USER_SLUG='' resolve 2>/dev/null) && rc=0 || rc=$?
assert_eq "rc=0 from git config" "0" "$rc"
assert_eq "slugified Bob Marley -> bob-marley" "bob-marley" "$out"

# Test 3: special-char slugification ---------------------------------
echo "TEST: special chars slugify to dashes"
( cd "$REPO" && git config user.name "Carol O'Brien-Smith (test)" )
out=$(USER_SLUG='' resolve 2>/dev/null) && rc=0 || rc=$?
assert_eq "rc=0" "0" "$rc"
assert_eq "complex name slug" "carol-o-brien-smith-test" "$out"

# Test 4: nothing -> rc=2 + helpful stderr ---------------------------
echo "TEST: env unset + git config missing -> rc=2"
( cd "$REPO" && { git config --unset user.name 2>/dev/null || true; } )
# shellcheck disable=SC2030,SC2031
out=$(USER_SLUG='' bash -c "set -uo pipefail; cd '$REPO'; . '$LIB'; user_slug_verify" 2>&1) && rc=0 || rc=$?
assert_eq "rc=2" "2" "$rc"
assert_contains "stderr explains" "cannot resolve" "$out"
assert_contains "stderr suggests USER_SLUG"   "USER_SLUG"     "$out"
assert_contains "stderr suggests git config"  "git config"    "$out"

# Test 5: verify prints source --------------------------------------
echo "TEST: user_slug_verify prints source on stderr"
( cd "$REPO" && git config user.name "Dora The Explorer" )
out=$(USER_SLUG='' bash -c "set -uo pipefail; cd '$REPO'; . '$LIB'; user_slug_verify" 2>&1) && rc=0 || rc=$?
assert_eq "verify rc=0" "0" "$rc"
assert_contains "verify mentions git config source" "git config user.name" "$out"
assert_contains "verify reports slug" "dora-the-explorer" "$out"

out=$(USER_SLUG=elena bash -c "set -uo pipefail; cd '$REPO'; . '$LIB'; user_slug_verify" 2>&1) && rc=0 || rc=$?
assert_eq "verify env rc=0" "0" "$rc"
assert_contains "verify mentions env source" "\$USER_SLUG env" "$out"
assert_contains "verify reports env value"   "elena"            "$out"

# Test 6: empty USER_SLUG falls through to git config ---------------
echo "TEST: empty USER_SLUG falls through"
( cd "$REPO" && git config user.name "Fred" )
out=$(USER_SLUG='' resolve 2>/dev/null) && rc=0 || rc=$?
assert_eq "empty env rc=0" "0" "$rc"
assert_eq "empty env -> git" "fred" "$out"

echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
