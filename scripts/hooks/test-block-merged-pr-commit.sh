#!/usr/bin/env bash
# Smoke test for scripts/hooks/block-merged-pr-commit.sh.
#
# Usage: bash scripts/hooks/test-block-merged-pr-commit.sh
#
# Exit codes:
#   0 — all cases passed
#   1 — at least one case failed
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HOOK_DIR/block-merged-pr-commit.sh"
[ -x "$HOOK" ] || chmod +x "$HOOK" 2>/dev/null || true

FAILED=0
PASSED=0

assert_rc() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label (rc=$actual)"
        PASSED=$((PASSED + 1))
    else
        echo "FAIL $label — expected rc=$expected, got rc=$actual"
        FAILED=$((FAILED + 1))
    fi
}

assert_stderr_contains() {
    local label="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF "$needle"; then
        echo "PASS $label (stderr contains '$needle')"
        PASSED=$((PASSED + 1))
    else
        echo "FAIL $label — stderr did not contain '$needle'"
        echo "  Actual stderr: $haystack"
        FAILED=$((FAILED + 1))
    fi
}

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

# Create a stub GH_CMD script that the hook (via branch-shipped.sh) calls.
STUB_DIR="$SANDBOX/stubs"
mkdir -p "$STUB_DIR"

# Stub that reports 1 merged PR (branch IS merged).
GH_MERGED="$STUB_DIR/gh-merged"
cat > "$GH_MERGED" <<'EOF'
#!/usr/bin/env bash
echo "1"
EOF
chmod +x "$GH_MERGED"

# Stub that reports 0 merged PRs (branch is clean, NOT merged).
GH_CLEAN="$STUB_DIR/gh-clean"
cat > "$GH_CLEAN" <<'EOF'
#!/usr/bin/env bash
echo "0"
EOF
chmod +x "$GH_CLEAN"

# Stub that exits non-zero (forge error).
GH_ERROR="$STUB_DIR/gh-error"
cat > "$GH_ERROR" <<'EOF'
#!/usr/bin/env bash
echo "forge error" >&2
exit 1
EOF
chmod +x "$GH_ERROR"

# Stub that sleeps (forge hang).
GH_HANG="$STUB_DIR/gh-hang"
cat > "$GH_HANG" <<'EOF'
#!/usr/bin/env bash
sleep 30
echo "0"
EOF
chmod +x "$GH_HANG"

# Helper: create a temp git repo on the given branch.
mkrepo() {
    local path="$1" branch="$2"
    mkdir -p "$path"
    git -C "$path" init -q
    git -C "$path" symbolic-ref HEAD "refs/heads/$branch"
    git -C "$path" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "init"
}

# Create a test repo on a feature branch.
TESTREPO="$SANDBOX/testrepo"
mkrepo "$TESTREPO" "feat/my-feature"

# Create another repo on main (to use as a separate cwd).
MAINREPO="$SANDBOX/mainrepo"
mkrepo "$MAINREPO" "main"

# Helper: run the hook with a JSON payload on stdin.
# Usage: run_hook <json> [env overrides as KEY=VAL ...]
run_hook() {
    local json="$1"; shift
    printf '%s' "$json" | env "$@" bash "$HOOK" 2>/dev/null
    echo "$?"
}

# Run hook and capture both rc and stderr.
run_hook_stderr() {
    local json="$1"; shift
    local stderr_out
    stderr_out=$(printf '%s' "$json" | env "$@" bash "$HOOK" 2>&1 >/dev/null)
    local rc=$?
    printf '%s|%s' "$rc" "$stderr_out"
}

# Build a hook JSON payload.
hook_json() {
    local cmd="$1" cwd="$2"
    # Escape backslashes and double-quotes in cmd and cwd for JSON.
    local cmd_esc cwd_esc
    cmd_esc=$(printf '%s' "$cmd" | sed 's/\\/\\\\/g; s/"/\\"/g')
    cwd_esc=$(printf '%s' "$cwd" | sed 's/\\/\\\\/g; s/"/\\"/g')
    printf '{"tool_input":{"command":"%s"},"cwd":"%s"}' "$cmd_esc" "$cwd_esc"
}

# ─── Test cases ──────────────────────────────────────────────────────────────

echo "=== block-merged-pr-commit smoke tests ==="

# T1: non-commit command (git status) → exit 0
assert_rc "T1 non-commit git-status" 0 "$(run_hook "$(hook_json 'git status' "$TESTREPO")" \
    FORGE=github GH_CMD="$GH_MERGED")"

# T2: git commit-graph write → exit 0 (prefix exclusion)
assert_rc "T2 commit-graph write" 0 "$(run_hook "$(hook_json 'git commit-graph write' "$TESTREPO")" \
    FORGE=github GH_CMD="$GH_MERGED")"

# T3: git commit --dry-run -m x → exit 0
assert_rc "T3 commit --dry-run" 0 "$(run_hook "$(hook_json 'git commit --dry-run -m x' "$TESTREPO")" \
    FORGE=github GH_CMD="$GH_MERGED")"

# T4: merged-branch `git commit -m x` (cwd = merged repo) → exit 2
T4_RESULT=$(run_hook_stderr "$(hook_json 'git commit -m x' "$TESTREPO")" \
    FORGE=github GH_CMD="$GH_MERGED")
T4_RC="${T4_RESULT%%|*}"
T4_STDERR="${T4_RESULT#*|}"
assert_rc "T4 merged-branch commit blocks" 2 "$T4_RC"
assert_stderr_contains "T4 stderr names branch" "feat/my-feature" "$T4_STDERR"
assert_stderr_contains "T4 stderr mentions /worktree" "/worktree" "$T4_STDERR"

# T5: clean-branch commit (stub count 0) → exit 0
assert_rc "T5 clean-branch commit allows" 0 "$(run_hook "$(hook_json 'git commit -m x' "$TESTREPO")" \
    FORGE=github GH_CMD="$GH_CLEAN")"

# T6: MERGED_PR_COMMIT_OK=1 + merged-branch commit → exit 0
assert_rc "T6 bypass env var" 0 "$(run_hook "$(hook_json 'git commit -m x' "$TESTREPO")" \
    FORGE=github GH_CMD="$GH_MERGED" MERGED_PR_COMMIT_OK=1)"

# T7: forge-error stub + merged-looking branch → exit 0 (fail-open) + warn on stderr
T7_RESULT=$(run_hook_stderr "$(hook_json 'git commit -m x' "$TESTREPO")" \
    FORGE=github GH_CMD="$GH_ERROR")
T7_RC="${T7_RESULT%%|*}"
T7_STDERR="${T7_RESULT#*|}"
assert_rc "T7 forge-error fail-open" 0 "$T7_RC"
assert_stderr_contains "T7 forge-error warn" "forge unreachable" "$T7_STDERR"

# T8: `git -C <dir> commit -m x` resolves branch from <dir> (point -C at the
# temp repo; .cwd elsewhere) → exit 2
T8_RESULT=$(run_hook_stderr "$(hook_json "git -C $TESTREPO commit -m x" "$MAINREPO")" \
    FORGE=github GH_CMD="$GH_MERGED")
T8_RC="${T8_RESULT%%|*}"
T8_STDERR="${T8_RESULT#*|}"
assert_rc "T8 git -C dir resolves dir" 2 "$T8_RC"
assert_stderr_contains "T8 git -C stderr names branch" "feat/my-feature" "$T8_STDERR"

# T9: .cwd-only resolution (no -C, cwd = temp repo) → exit 2
T9_RESULT=$(run_hook_stderr "$(hook_json 'git commit -m x' "$TESTREPO")" \
    FORGE=github GH_CMD="$GH_MERGED")
T9_RC="${T9_RESULT%%|*}"
assert_rc "T9 cwd-only resolution" 2 "$T9_RC"

# T10: cd $EVIL_REPO && git commit — false-block vector.
#
# The defect: `set -- $seg` in the cd-tracking loop expands $EVIL_REPO to a
# real path BEFORE _is_literal runs.  The check then sees an expanded literal
# path, treats it as a confident cd target, resolves that repo's MERGED branch,
# and exits 2 — a false-block.
#
# This test EXPORTS EVIL_REPO pointing at a git repo whose branch the stub
# reports as merged.  The cwd is MAINREPO (clean/unrelated).  The command is
# the literal string "cd $EVIL_REPO && git commit -m x" — exactly as Claude
# might emit it.  The hook must see the raw '$' and treat the target as
# UNKNOWN → fail-open (exit 0).
#
# Pre-fix: this test returns rc=2 (false-block).
# Post-fix: this test returns rc=0 (fail-open).
T10_REPO="$SANDBOX/t10-evil-repo"
mkrepo "$T10_REPO" "feat/evil-branch"
# shellcheck disable=SC2016  # literal $EVIL_REPO string in JSON is intentional
assert_rc "T10 dollar-VAR cd fails open (not false-block)" 0 \
    "$(run_hook "$(hook_json 'cd $EVIL_REPO && git commit -m x' "$MAINREPO")" \
        FORGE=github GH_CMD="$GH_MERGED" EVIL_REPO="$T10_REPO")"

# T11: stub-hang forge with small BRANCH_SHIPPED_TIMEOUT → exit 0, bounded
# Skip if neither `timeout` nor `gtimeout` exists (lesson from Task 1).
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
    T11_START=$(date +%s)
    T11_RC=$(run_hook "$(hook_json 'git commit -m x' "$TESTREPO")" \
        FORGE=github GH_CMD="$GH_HANG" BRANCH_SHIPPED_TIMEOUT=2)
    T11_END=$(date +%s)
    T11_ELAPSED=$((T11_END - T11_START))
    assert_rc "T11 hang guard exits 0" 0 "$T11_RC"
    if [ "$T11_ELAPSED" -lt 10 ]; then
        echo "PASS T11 hang bounded (${T11_ELAPSED}s < 10s)"
        PASSED=$((PASSED + 1))
    else
        echo "FAIL T11 hang not bounded (${T11_ELAPSED}s >= 10s)"
        FAILED=$((FAILED + 1))
    fi
else
    echo "SKIP T11 hang-guard (no timeout/gtimeout available)"
    PASSED=$((PASSED + 1))
fi

# T12: compound command with literal cd before commit → dir resolved correctly.
# This proves that fixing the $VAR expansion bug did NOT break literal cd paths.
# A literal absolute path must still update current_dir and trigger a block when
# that dir's branch is merged.
T12_REPO="$SANDBOX/t12repo"
mkrepo "$T12_REPO" "feat/t12-branch"
T12_RESULT=$(run_hook_stderr "$(hook_json "cd $T12_REPO && git commit -m x" "$MAINREPO")" \
    FORGE=github GH_CMD="$GH_MERGED")
T12_RC="${T12_RESULT%%|*}"
T12_STDERR="${T12_RESULT#*|}"
assert_rc "T12 literal cd resolves dir" 2 "$T12_RC"
assert_stderr_contains "T12 literal cd stderr names branch" "feat/t12-branch" "$T12_STDERR"

# T13: glob expansion false-block regression.
#
# Bug (pre-fix): `set -- $segment` without noglob expands `/path*` to real
# filesystem paths. If a segment is `git -C /tmp/evil* commit -m x` and the
# glob matches a real git repo whose branch the stub reports MERGED, the hook
# exits 2 (false-block) instead of 0 (fail-open).
#
# Fix: wrap `set -- $segment` with `set -f` / `set +f` (noglob). After the
# fix, `/path*` is kept as a literal token; _is_literal rejects it (contains
# `*`) → dir UNKNOWN → fail-open (exit 0).
#
# Setup: create a temp git repo named `evilrepo` (the glob `evilrep*` would
# match it on the filesystem). Run the hook with cwd = that parent dir and
# command = `git -C evilrep* commit -m x`. GH stub reports MERGED for any
# branch, so without noglob the glob expands → false-block (exit 2).
# With noglob the `*` stays literal → _is_literal returns false → exit 0.
T13_BASE="$SANDBOX/t13"
mkdir -p "$T13_BASE"
mkrepo "$T13_BASE/evilrepo" "feat/evil-merged"
# Use a glob that matches the dir on disk but must stay literal in the hook.
# shellcheck disable=SC2016  # intentional literal glob in the command string
assert_rc "T13 glob in -C arg fails open (noglob fix)" 0 \
    "$(run_hook "$(hook_json 'git -C evilrep* commit -m x' "$T13_BASE")" \
        FORGE=github GH_CMD="$GH_MERGED")"

# T14: non-literal $VAR in -C arg → exit 0 (already covered by non-literal
# branch, but explicit for the CR finding that requested it).
# shellcheck disable=SC2016  # intentional literal $VAR string
assert_rc "T14 dollar-VAR in -C arg fails open" 0 \
    "$(run_hook "$(hook_json 'git -C $VAR commit -m x' "$MAINREPO")" \
        FORGE=github GH_CMD="$GH_MERGED")"

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASSED passed, $FAILED failed"
if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
