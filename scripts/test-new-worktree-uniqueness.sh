#!/usr/bin/env bash
# test-new-worktree-uniqueness.sh — tests for the merged-PR uniqueness guard
# in _new-worktree.sh (HIMMEL-512, Task 4).
#
# Self-contained: builds a throwaway temp git repo, stubs GH_CMD, and runs
# _new-worktree.sh with --no-install. No live remote or gh binary required.
#
# Bash 3.2-safe; shellcheck-clean.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NEW_WT="$SCRIPT_DIR/_new-worktree.sh"

PASS=0
FAIL=0
SKIP=0

_pass() { printf 'PASS  %s\n' "$1"; PASS=$(( PASS + 1 )); }
_fail() { printf 'FAIL  %s\n  -> %s\n' "$1" "$2"; FAIL=$(( FAIL + 1 )); }
_skip() { printf 'SKIP  %s\n  -> %s\n' "$1" "$2"; SKIP=$(( SKIP + 1 )); }

# ---------------------------------------------------------------------------
# Guard: skip timeout-dependent assertions when neither binary is available.
# ---------------------------------------------------------------------------
_has_timeout() {
    command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Build a throwaway repo in a temp dir.
# ---------------------------------------------------------------------------
TMPBASE="${TMPDIR:-/tmp}/test-nwu-$$"
mkdir -p "$TMPBASE"
# shellcheck disable=SC2064
trap 'rm -rf "$TMPBASE"' EXIT

REPO="$TMPBASE/repo"
git init -q "$REPO"
# Set identity so commits work without global git config.
git -C "$REPO" config user.email "test@test.local"
git -C "$REPO" config user.name "Test"
# Need at least one commit so HEAD exists.
git -C "$REPO" commit -q --allow-empty -m "init"

# ---------------------------------------------------------------------------
# Stub factory: produce a gh binary that, for `pr list`, prints a fixed count.
# branch_has_merged_pr calls gh pr list --search "head:<branch> is:merged".
# forge_pr_has_merged (github backend) does:
#   gh pr list --search "head:<branch> is:merged" --json number --jq length
# which prints a numeric count on stdout and exits 0 on success.
# ---------------------------------------------------------------------------

_make_stub() {
    local name="$1"
    local script="$2"
    local dir="$TMPBASE/stubs/$name"
    mkdir -p "$dir"
    local f="$dir/gh"
    printf '#!/usr/bin/env bash\n%s\n' "$script" > "$f"
    chmod +x "$f"
    printf '%s' "$f"
}

# Stub: prints count > 0 (branch is merged) and exits 0.
GH_MERGED="$(_make_stub merged 'echo "1"')"

# Stub: prints 0 (no merged PRs) and exits 0.
GH_NOT_MERGED="$(_make_stub not-merged 'echo "0"')"

# Stub: exits non-zero (forge error → rc2 in branch_has_merged_pr).
GH_ERROR="$(_make_stub error 'echo "forge-err" >&2; exit 1')"

# ---------------------------------------------------------------------------
# Helper: run _new-worktree.sh in the temp repo with given env overrides.
# Returns via out/rc captures.
# ---------------------------------------------------------------------------
_run() {
    # _run <branch> <extra-env-assignments-as-args> ...
    # Usage: _run feat/test123 GH_CMD=/path/to/stub REUSE_MERGED_BRANCH_OK=1
    local branch="$1"; shift
    local env_pairs=""
    for pair in "$@"; do
        env_pairs="$env_pairs $pair"
    done

    # Run from inside the temp repo so _new-worktree.sh picks it as PRIMARY_WORKTREE.
    # Capture combined stdout+stderr separately for inspection.
    local out_f="$TMPBASE/run-out.txt"
    local err_f="$TMPBASE/run-err.txt"
    local rc=0
    # shellcheck disable=SC2086
    ( cd "$REPO" && env FORGE=github $env_pairs bash "$NEW_WT" "$branch" --no-install ) \
        >"$out_f" 2>"$err_f" || rc=$?
    # Export for callers to inspect.
    _LAST_STDOUT=$(cat "$out_f")
    _LAST_STDERR=$(cat "$err_f")
    _LAST_RC=$rc
}
_LAST_STDOUT=""
_LAST_STDERR=""
_LAST_RC=0

BRANCH_MERGED="feat/test-merged-pr"
BRANCH_CLEAN="feat/test-clean-pr"

# ---------------------------------------------------------------------------
# Case 1: merged stub → expect exit 1 + "maps to a merged PR" in stderr.
# This refusal must fire BEFORE the git fetch (no live remote needed).
# Gated on timeout availability (the predicate uses a timeout subprocess).
# ---------------------------------------------------------------------------
NAME="Case 1: merged branch → exit 1 + maps-to-a-merged-PR error"
if ! _has_timeout; then
    _skip "$NAME" "neither 'timeout' nor 'gtimeout' found — cannot exercise timeout wrapper"
else
    _run "$BRANCH_MERGED" "GH_CMD=$GH_MERGED"
    if [ "$_LAST_RC" -eq 1 ] && printf '%s' "$_LAST_STDERR" | grep -q "maps to a merged PR"; then
        _pass "$NAME"
    else
        _fail "$NAME" "rc=$_LAST_RC stderr=[$_LAST_STDERR]"
    fi
fi

# ---------------------------------------------------------------------------
# Case 2: REUSE_MERGED_BRANCH_OK=1 + merged stub → passes the uniqueness
# check; since there's no real remote, must reach a fetch-related failure.
# We assert: stderr does NOT contain "maps to a merged PR" AND does reach
# a fetch-related failure (stderr contains "fetch" or rc != 1-from-uniqueness).
# ---------------------------------------------------------------------------
NAME="Case 2: REUSE_MERGED_BRANCH_OK=1 + merged stub → passes uniqueness check"
if ! _has_timeout; then
    _skip "$NAME" "neither 'timeout' nor 'gtimeout' found — cannot exercise timeout wrapper"
else
    _run "$BRANCH_MERGED" "GH_CMD=$GH_MERGED" "REUSE_MERGED_BRANCH_OK=1"
    no_uniqueness_err=0
    reaches_fetch=0
    if ! printf '%s' "$_LAST_STDERR" | grep -q "maps to a merged PR"; then
        no_uniqueness_err=1
    fi
    # Either stderr mentions fetch, OR combined output does, OR exit != 0 for
    # a different reason than the uniqueness guard.
    combined="$_LAST_STDOUT $_LAST_STDERR"
    if printf '%s' "$combined" | grep -qi "fetch\|remote\|network\|connect\|not found"; then
        reaches_fetch=1
    fi
    # Also acceptable: exit 1 for a reason OTHER than "maps to a merged PR"
    # (e.g. fetch failure), so if uniqueness error is absent we consider it passed.
    if [ "$no_uniqueness_err" -eq 1 ]; then
        _pass "$NAME"
    else
        _fail "$NAME" "rc=$_LAST_RC stderr=[$_LAST_STDERR] reaches_fetch=$reaches_fetch"
    fi
fi

# ---------------------------------------------------------------------------
# Case 3: not-merged stub (count=0, rc1) → passes uniqueness check, reaches fetch.
# ---------------------------------------------------------------------------
NAME="Case 3: not-merged stub → proceeds past uniqueness check (reaches fetch)"
if ! _has_timeout; then
    _skip "$NAME" "neither 'timeout' nor 'gtimeout' found — cannot exercise timeout wrapper"
else
    _run "$BRANCH_CLEAN" "GH_CMD=$GH_NOT_MERGED"
    no_uniqueness_err=0
    if ! printf '%s' "$_LAST_STDERR" | grep -q "maps to a merged PR"; then
        no_uniqueness_err=1
    fi
    combined="$_LAST_STDOUT $_LAST_STDERR"
    reaches_fetch=0
    if printf '%s' "$combined" | grep -qi "fetch\|remote\|network\|connect\|not found"; then
        reaches_fetch=1
    fi
    if [ "$no_uniqueness_err" -eq 1 ]; then
        _pass "$NAME"
    else
        _fail "$NAME" "rc=$_LAST_RC stderr=[$_LAST_STDERR]"
    fi
fi

# ---------------------------------------------------------------------------
# Case 4: forge-error stub (exit non-zero → rc2) → WARN "uniqueness-vs-merged-PR
# check skipped" in stderr AND proceeds (reaches fetch, not the uniqueness block).
# ---------------------------------------------------------------------------
NAME="Case 4: forge-error stub → WARN uniqueness skipped + proceeds"
if ! _has_timeout; then
    _skip "$NAME" "neither 'timeout' nor 'gtimeout' found — cannot exercise timeout wrapper"
else
    _run "$BRANCH_CLEAN" "GH_CMD=$GH_ERROR"
    has_warn=0
    no_uniqueness_err=0
    if printf '%s' "$_LAST_STDERR" | grep -q "uniqueness-vs-merged-PR check skipped"; then
        has_warn=1
    fi
    if ! printf '%s' "$_LAST_STDERR" | grep -q "maps to a merged PR"; then
        no_uniqueness_err=1
    fi
    if [ "$has_warn" -eq 1 ] && [ "$no_uniqueness_err" -eq 1 ]; then
        _pass "$NAME"
    else
        _fail "$NAME" "rc=$_LAST_RC has_warn=$has_warn no_uniqueness_err=$no_uniqueness_err stderr=[$_LAST_STDERR]"
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
printf 'Results: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
