#!/usr/bin/env bash
# Unit test for scripts/console/sweep-cr-threads.sh (HIMMEL-2320). Exit 0 if
# all pass. GH_CMD stub seam (matches scripts/lib/test-forge.sh); no network.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SWEEP="$SCRIPT_DIR/sweep-cr-threads.sh"

_fail=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s: %s\n' "$1" "$2"; _fail=$((_fail+1)); }

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/sweep-cr-threads.XXXXXX") || { echo "cannot create temporary directory" >&2; exit 1; }
if command -v cygpath >/dev/null 2>&1; then
    TMP_ROOT=$(cygpath -m "$TMP_ROOT") || { echo "cannot convert temporary-directory path" >&2; exit 1; }
fi
# shellcheck disable=SC2329,SC2317  # invoked via the EXIT trap
cleanup() { rm -rf "$TMP_ROOT" 2>/dev/null || true; }
trap cleanup EXIT

# ── stub 1: clean sweep, PRs 101 (0 unresolved) and 102 (2 unresolved) ──────
GH_STUB1="$TMP_ROOT/gh-stub-clean.sh"
cat > "$GH_STUB1" <<'STUB'
#!/usr/bin/env bash
case "$* " in
    *"repo view"*nameWithOwner*) echo "owner/repo" ;;
    *"pr list"*"state open"*)    printf '101\n102\n' ;;
    *"number=101"*) echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":3,"nodes":[{"isResolved":true},{"isResolved":true},{"isResolved":true}]}}}}}' ;;
    *"number=102"*) echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":2,"nodes":[{"isResolved":false},{"isResolved":false}]}}}}}' ;;
    *) echo "stub: unhandled gh args: $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$GH_STUB1"

echo "TEST: clean sweep — counts both PRs, exits 0"
out=$(GH_CMD="$GH_STUB1" "$SWEEP" 2>"$TMP_ROOT/err1")
rc=$?
m101=$(printf '%s\n' "$out" | grep -F "PR 101: 3 threads, 0 unresolved")
m102=$(printf '%s\n' "$out" | grep -F "PR 102: 2 threads, 2 unresolved")
if [ "$rc" -eq 0 ] && [ -n "$m101" ] && [ -n "$m102" ]; then
    pass "clean sweep counts + rc 0"
else
    fail "clean sweep" "rc=$rc out='$out' err='$(cat "$TMP_ROOT/err1")'"
fi

# ── stub 2: the HIMMEL-2320 wrong-slug shape — GraphQL errors + null PR ─────
# This is the exact regression: a query against the wrong repo returns a
# NOT_FOUND error and a null pullRequest, NOT a zero thread count.
GH_STUB2="$TMP_ROOT/gh-stub-wrongslug.sh"
cat > "$GH_STUB2" <<'STUB'
#!/usr/bin/env bash
case "$* " in
    *"repo view"*nameWithOwner*) echo "owner/repo" ;;
    *"pr list"*"state open"*)    printf '201\n' ;;
    *"number=201"*) echo '{"data":{"repository":{"pullRequest":null}},"errors":[{"type":"NOT_FOUND","message":"Could not resolve to a PullRequest with the number of 201."}]}' ;;
    *) echo "stub: unhandled gh args: $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$GH_STUB2"

echo "TEST: wrong-slug NOT_FOUND shape never renders as a clean zero"
out=$(GH_CMD="$GH_STUB2" "$SWEEP" 2>"$TMP_ROOT/err2")
rc=$?
err=$(cat "$TMP_ROOT/err2")
m_fake=$(printf '%s\n' "$out" | grep -F "PR 201:")
m_qerr=$(printf '%s\n' "$err" | grep -F "QUERY-ERROR PR 201")
if [ "$rc" -ne 0 ] && [ -z "$m_fake" ] && [ -n "$m_qerr" ]; then
    pass "NOT_FOUND -> QUERY-ERROR + nonzero exit, no fake PR line"
else
    fail "NOT_FOUND shape" "rc=$rc out='$out' err='$err'"
fi

# ── stub 3: raw gh api graphql command failure (network/auth) ──────────────
GH_STUB3="$TMP_ROOT/gh-stub-cmdfail.sh"
cat > "$GH_STUB3" <<'STUB'
#!/usr/bin/env bash
case "$* " in
    *"repo view"*nameWithOwner*) echo "owner/repo" ;;
    *"pr list"*"state open"*)    printf '301\n' ;;
    *"number=301"*) echo "gh: connection failed" >&2; exit 1 ;;
    *) echo "stub: unhandled gh args: $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$GH_STUB3"

echo "TEST: a raw gh api graphql failure is also a QUERY-ERROR, not a swallowed zero"
out=$(GH_CMD="$GH_STUB3" "$SWEEP" 2>"$TMP_ROOT/err3")
rc=$?
err=$(cat "$TMP_ROOT/err3")
m_qerr=$(printf '%s\n' "$err" | grep -F "QUERY-ERROR PR 301")
if [ "$rc" -ne 0 ] && [ -n "$m_qerr" ]; then
    pass "gh command failure -> QUERY-ERROR + nonzero exit"
else
    fail "gh command failure" "rc=$rc out='$out' err='$err'"
fi

# ── stub 4: explicit PR numbers as args, bypassing `pr list` ───────────────
GH_STUB4="$TMP_ROOT/gh-stub-args.sh"
cat > "$GH_STUB4" <<'STUB'
#!/usr/bin/env bash
case "$* " in
    *"repo view"*nameWithOwner*) echo "owner/repo" ;;
    *"pr list"*) echo "stub: pr list should not be called when PR numbers are given as args" >&2; exit 98 ;;
    *"number=401"*) echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":0,"nodes":[]}}}}}' ;;
    *) echo "stub: unhandled gh args: $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$GH_STUB4"

echo "TEST: explicit PR numbers skip 'gh pr list'"
out=$(GH_CMD="$GH_STUB4" "$SWEEP" 401 2>"$TMP_ROOT/err4")
rc=$?
m401=$(printf '%s\n' "$out" | grep -F "PR 401: 0 threads, 0 unresolved")
if [ "$rc" -eq 0 ] && [ -n "$m401" ]; then
    pass "explicit PR arg"
else
    fail "explicit PR arg" "rc=$rc out='$out' err='$(cat "$TMP_ROOT/err4")'"
fi

# ── stub 5: repo slug resolution itself fails -> abort before any PR query ──
GH_STUB5="$TMP_ROOT/gh-stub-noslug.sh"
cat > "$GH_STUB5" <<'STUB'
#!/usr/bin/env bash
case "$* " in
    *"repo view"*nameWithOwner*) echo "not gh's repo" >&2; exit 1 ;;
    *) echo "stub: unhandled gh args: $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$GH_STUB5"

echo "TEST: unresolvable repo slug aborts fail-closed"
rc=0
out=$(GH_CMD="$GH_STUB5" "$SWEEP" 2>"$TMP_ROOT/err5") || rc=$?
if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
    pass "unresolvable slug aborts"
else
    fail "unresolvable slug" "rc=$rc out='$out'"
fi

if [ "$_fail" -eq 0 ]; then echo "OK"; exit 0; else echo "FAIL: $_fail"; exit 1; fi
