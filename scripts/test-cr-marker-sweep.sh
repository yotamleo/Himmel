#!/usr/bin/env bash
# Hermetic test for the cr-pending marker sweep in clean-garden.sh (HIMMEL-295).
#
# Tests only the sweep classification rules, not the full prune-worktree flow.
# Uses a temp git repo with fake markers and a stub `gh` binary so no network
# calls are made. Follows the pattern of scripts/hooks/test-*.sh.
#
# Classification rules under test:
#   A. Branch still exists locally       → KEEP   (no gh call needed)
#   B. Branch gone, open PR exists (gh)  → KEEP   (noted, not deleted)
#   C. Branch gone, no open PR (gh)      → SWEEP
#   D. Branch gone, gh unavailable       → SWEEP  (local-only fallback)
#   F. Branch gone, gh present but FAILS → KEEP   (unknown PR state ≠ no PR)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEAN_GARDEN="$SCRIPT_DIR/clean-garden.sh"

PASS=0
FAIL=0
TMP_ROOT=""

# shellcheck disable=SC2317
cleanup() {
    if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
        rm -rf "$TMP_ROOT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }

# ── shared setup ─────────────────────────────────────────────────────────────

TMP_ROOT=$(mktemp -d)
# TMP_ROOT_UNIX stays as the POSIX path — needed for PATH prepend in Git Bash.
# TMP_ROOT may be converted to a Windows-style path for git commands on Windows.
TMP_ROOT_UNIX="$TMP_ROOT"
if command -v cygpath >/dev/null 2>&1; then
    TMP_ROOT=$(cygpath -m "$TMP_ROOT")
fi

REPO="$TMP_ROOT/repo"
git init -q --initial-branch=main "$REPO" 2>/dev/null || {
    git init -q "$REPO"
    git -C "$REPO" symbolic-ref HEAD refs/heads/main || true
}
git -C "$REPO" -c user.email=t@test.com -c user.name=t commit -q --allow-empty -m "init"
git -C "$REPO" branch -m main 2>/dev/null || true
# Forge seam (HIMMEL-326): clean-garden resolves the forge from origin; a github
# origin selects the github backend (bare `gh` via the stub on PATH).
git -C "$REPO" remote add origin https://github.com/owner/repo.git

COMMON_DIR=$(git -C "$REPO" rev-parse --git-common-dir)
case "$COMMON_DIR" in /*|?:/*|?:\\*) ;; *) COMMON_DIR="$REPO/$COMMON_DIR" ;; esac
CR_DIR="${COMMON_DIR}/cr-pending"
mkdir -p "$CR_DIR"

# Helper: write a fake marker file (branch name may include '/').
write_marker() {
    local branch="$1"
    local marker="${CR_DIR}/${branch}"
    mkdir -p "$(dirname "$marker")"
    printf '2026-06-12T00:00:00+00:00 | deadbeef\n' > "$marker"
}

# Helper: stub gh binary that returns configurable open-PR counts.
# Writes a script to $TMP_ROOT_UNIX/bin/gh and returns the UNIX-path bin dir
# so callers can prepend it to PATH correctly in Git Bash.
make_stub_gh() {
    # Use TMP_ROOT_UNIX (POSIX path) — Windows-style paths don't work as
    # PATH entries in Git Bash even with a leading forward slash.
    local stub_dir="$TMP_ROOT_UNIX/bin"
    mkdir -p "$stub_dir"
    # $1 = branch name, $2 = open count for that branch (others → 0)
    local branch="${1:-__none__}"
    local count="${2:-0}"
    cat > "$stub_dir/gh" <<STUB
#!/usr/bin/env bash
# Stub gh for the forge github backend. Open-PR query (forge_pr_find_open) uses
# \`--jq '.[0].number // ""'\`, so it emits a PR NUMBER when an open PR exists
# for branch '$branch' (count $count) or empty otherwise. Merged query
# (forge_pr_has_merged) uses \`--jq length\`, so it emits a count.
args="\$*"
if echo "\$args" | grep -q "auth status"; then
    exit 0
fi
if echo "\$args" | grep -q "repo view"; then
    echo "owner/repo"
    exit 0
fi
if echo "\$args" | grep -q -- "--state open"; then
    # forge_pr_find_open → PR number (open exists) or empty (none).
    if echo "\$args" | grep -q -- "--head $branch" && [ "$count" -gt 0 ]; then
        echo "42"
    fi
    exit 0
fi
if echo "\$args" | grep -q -- "--state merged"; then
    # forge_pr_has_merged → count.
    echo "0"
    exit 0
fi
exit 0
STUB
    chmod +x "$stub_dir/gh"
    echo "$stub_dir"
}

run_sweep_only() {
    local stub_bin_dir="$1"
    # Run clean-garden --prune-only in the repo; PATH prepend provides stub gh.
    # We capture output and exit code; the prune phase finds zero non-primary
    # worktrees (repo has no extra worktrees) so only the sweep runs.
    (
        # shellcheck disable=SC2030  # PATH override scoped to this subshell on purpose
        export PATH="${stub_bin_dir}:${PATH}"
        cd "$REPO" || exit 1
        bash "$CLEAN_GARDEN" --prune-only 2>&1
    )
}

# ── Test A: branch still exists locally → KEEP ───────────────────────────────

echo "TEST A: branch exists locally -> marker kept"
git -C "$REPO" checkout -q -b feat/alive
git -C "$REPO" checkout -q main
write_marker "feat/alive"

STUB_BIN=$(make_stub_gh "__none__" 0)
out=$(run_sweep_only "$STUB_BIN")

if [ -f "${CR_DIR}/feat/alive" ]; then
    pass "A: marker kept (branch exists locally)"
else
    fail "A: marker was swept but branch still exists" "out: $out"
fi
case "$out" in
    *"kept (branch exists)"*) pass "A: sweep summary mentions kept-branch count" ;;
    *) fail "A: expected 'kept (branch exists)' in output" "out: $out" ;;
esac

# ── Test B: branch gone, open PR → KEEP ──────────────────────────────────────

echo "TEST B: branch gone locally, open PR -> marker kept"
write_marker "feat/open-pr"
# Do NOT create the local branch — it's "gone".

STUB_BIN=$(make_stub_gh "feat/open-pr" 1)
out=$(run_sweep_only "$STUB_BIN")

if [ -f "${CR_DIR}/feat/open-pr" ]; then
    pass "B: marker kept (open PR)"
else
    fail "B: marker was swept despite open PR" "out: $out"
fi
case "$out" in
    *"open PR"*) pass "B: sweep noted open-PR branch" ;;
    *) fail "B: expected 'open PR' note in output" "out: $out" ;;
esac

# ── Test C: branch gone, no open PR → SWEEP ──────────────────────────────────

echo "TEST C: branch gone, no open PR -> marker swept"
write_marker "fix/stale-merged"
# Branch does not exist locally; stub gh returns 0 open PRs.

STUB_BIN=$(make_stub_gh "__none__" 0)
out=$(run_sweep_only "$STUB_BIN")

if [ -f "${CR_DIR}/fix/stale-merged" ]; then
    fail "C: stale marker not swept" "out: $out"
else
    pass "C: stale marker swept (no open PR)"
fi
case "$out" in
    *"swept"*) pass "C: sweep summary mentions swept count" ;;
    *) fail "C: expected 'swept' in output" "out: $out" ;;
esac

# ── Test D: gh unavailable → SWEEP based on local branch only ────────────────

echo "TEST D: gh unavailable, branch gone -> marker swept (local-only fallback)"
write_marker "chore/no-gh-branch"
# No local branch. An empty PATH-prepend dir does NOT hide a real gh later on
# PATH, so simulate unavailability the way clean-garden detects it: a stub gh
# whose `auth status` fails -> HAVE_GH=0 -> local-only fallback.
NOAUTH_BIN="$TMP_ROOT_UNIX/noauthbin"
mkdir -p "$NOAUTH_BIN"
printf '#!/usr/bin/env bash\nexit 1\n' > "$NOAUTH_BIN/gh"
chmod +x "$NOAUTH_BIN/gh"

out=$(run_sweep_only "$NOAUTH_BIN")

if [ -f "${CR_DIR}/chore/no-gh-branch" ]; then
    fail "D: marker not swept when gh unavailable and branch gone" "out: $out"
else
    pass "D: marker swept (gh unavailable, branch gone)"
fi

# ── Test E: dry-run does not delete markers ───────────────────────────────────

echo "TEST E: --dry-run does not delete markers"
write_marker "fix/dry-run-test"

STUB_BIN=$(make_stub_gh "__none__" 0)
dry_out=$(
    # shellcheck disable=SC2031  # subshell-scoped PATH override, intentional
    export PATH="${STUB_BIN}:${PATH}"
    cd "$REPO" || exit 1
    bash "$CLEAN_GARDEN" --prune-only --dry-run 2>&1
)

if [ -f "${CR_DIR}/fix/dry-run-test" ]; then
    pass "E: dry-run preserved marker"
else
    fail "E: dry-run deleted marker (must not mutate)" "out: $dry_out"
fi
case "$dry_out" in
    *"DRY"*"sweep"*|*"would sweep"*) pass "E: dry-run announced sweep intent" ;;
    *) fail "E: expected dry-run sweep message" "out: $dry_out" ;;
esac

# ── Test F: gh present but query fails → KEEP (unknown ≠ no PR) ──────────────

echo "TEST F: gh query fails -> marker kept (PR state unknown)"
write_marker "fix/gh-flaky"
# Stub gh that succeeds for auth/repo detection but FAILS pr-list queries.
FLAKY_BIN="$TMP_ROOT_UNIX/flakybin"
mkdir -p "$FLAKY_BIN"
cat > "$FLAKY_BIN/gh" <<'STUB'
#!/usr/bin/env bash
args="$*"
if echo "$args" | grep -q "auth status"; then exit 0; fi
if echo "$args" | grep -q "repo view"; then echo "owner/repo"; exit 0; fi
if echo "$args" | grep -q "pr list"; then
    if echo "$args" | grep -q -- "--state merged"; then echo "[]"; exit 0; fi
    echo "gh: connection timed out" >&2
    exit 1
fi
exit 0
STUB
chmod +x "$FLAKY_BIN/gh"

out=$(run_sweep_only "$FLAKY_BIN")

if [ -f "${CR_DIR}/fix/gh-flaky" ]; then
    pass "F: marker kept when gh query fails"
else
    fail "F: marker swept on gh failure (unknown PR state must keep)" "out: $out"
fi
case "$out" in
    *"PR state unknown"*) pass "F: warn message names unknown PR state" ;;
    *) fail "F: expected 'PR state unknown' warning" "out: $out" ;;
esac

# ── Summary ──────────────────────────────────────────────────────────────────

echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
