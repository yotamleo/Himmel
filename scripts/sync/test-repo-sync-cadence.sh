#!/usr/bin/env bash
# Tests for scripts/sync/repo-sync-runner.sh + repo-sync-cadence.sh (HIMMEL-2115).
#
# The runner is pure bash operating on real (throwaway) git repos, so its
# fixture suite runs on EVERY platform, no schtasks fakery needed. The
# cadence arm/status/disarm layer's malformed-input/platform-detect checks
# also run everywhere; its schtasks create/dedup/dry-run/live-execution
# suite is Windows-only, mirroring scripts/graphify/test-ggs-cadence.sh.
#
# NEVER touches real repos — every fixture lives under a throwaway TMP_ROOT.
# Every runner invocation below overrides HIMMEL_FLOW_RUNS_LEDGER to a
# scratch path: the runner writes a flow-run-ledger row unconditionally, and
# an un-overridden run pages the live HimmelFlowRunError alert (do the same
# for any ad hoc manual/repro invocation of repo-sync-runner.sh outside this
# suite).
set -euo pipefail

grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$SCRIPT_DIR/repo-sync-runner.sh"
CADENCE="$SCRIPT_DIR/repo-sync-cadence.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
TMP_ROOT=""

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
    local name="$1" needle="$2" haystack="$3"
    if grepq "$haystack" -F -- "$needle"; then pass "$name"; else fail "$name" "missing: $needle"; fi
}
assert_not_contains() {
    local name="$1" needle="$2" haystack="$3"
    if grepq "$haystack" -F -- "$needle"; then fail "$name" "unexpected: $needle"; else pass "$name"; fi
}
assert_rc() {
    local name="$1" want="$2" got="$3"
    if [ "$got" = "$want" ]; then pass "$name"; else fail "$name" "expected rc=$want, got rc=$got"; fi
}
summary() {
    echo
    echo "===================================="
    echo "test summary: $PASS passed, $FAIL failed"
    echo "===================================="
    [ "$FAIL" -gt 0 ] && exit 1 || exit 0
}

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/repo-sync-cadence-test.XXXXXX")
if command -v cygpath >/dev/null 2>&1; then TMP_ROOT=$(cygpath -m "$TMP_ROOT"); fi

REAL_BASH="$(command -v bash)"

export HOME="$TMP_ROOT/home"
mkdir -p "$HOME"

# Hermetic + fast fixture git config (HIMMEL-1589) + a fixed commit identity
# so `git commit` never blocks on a missing user.name/user.email.
# shellcheck source=../lib/git-test-env.sh
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/git-test-env.sh"
git_test_env_pin_perf
export GIT_AUTHOR_NAME="repo-sync-test" GIT_AUTHOR_EMAIL="repo-sync-test@example.invalid"
export GIT_COMMITTER_NAME="repo-sync-test" GIT_COMMITTER_EMAIL="repo-sync-test@example.invalid"

# ============================================================================
# Source hygiene — no hardcoded absolute home paths (CLAUDE.md).
# ============================================================================
echo "TEST: source carries no hardcoded operator home path"
for f in "$RUNNER" "$CADENCE"; do
    if grep -qE 'C:\\Users\\[A-Za-z0-9_]+|/c/Users/[A-Za-z0-9_]+|/home/[A-Za-z0-9_]+/Documents' "$f"; then
        fail "no hardcoded absolute home paths in $(basename "$f")"
    else
        pass "no hardcoded absolute home paths in $(basename "$f")"
    fi
done

# ============================================================================
# Runner fixture suite — pure bash + real throwaway git repos, every platform.
# ============================================================================

FIXROOT="$TMP_ROOT/fixtures"
mkdir -p "$FIXROOT"

# mk_remote <name> — a bare "remote" repo with one commit on its default
# branch (main), plus a `feature` branch (used by the non-default-branch
# fixture). Echoes its absolute path.
mk_remote() {
    local name="$1" dir work
    dir="$FIXROOT/$name-remote.git"
    work="$FIXROOT/.seed-$name"
    mkdir -p "$work"
    git -C "$work" init -q -b main
    echo "seed" > "$work/README.md"
    git -C "$work" add README.md
    git -C "$work" commit -q -m "seed"
    git -C "$work" branch feature
    git init -q --bare "$dir"
    # `git init --bare` defaults HEAD to refs/heads/master regardless of what
    # branch name we seed the content on -- and since "master" is never
    # pushed below, the bare repo's HEAD points at a ref that never exists,
    # so a later `git clone` cannot resolve what to check out and silently
    # leaves the working tree EMPTY (fetches main/feature as remote-tracking
    # branches fine, checks out nothing). Point HEAD at main explicitly.
    git -C "$dir" symbolic-ref HEAD refs/heads/main
    git -C "$work" remote add origin "$dir"
    git -C "$work" push -q origin main feature
    rm -rf "$work"
    printf '%s' "$dir"
}

# mk_clone <remote-dir> <name> — a normal (non-bare) clone of <remote-dir>
# under $FIXROOT/<name>, checked out on the default branch. Echoes its path.
mk_clone() {
    local remote="$1" name="$2" dir
    dir="$FIXROOT/$name"
    git clone -q "$remote" "$dir" >/dev/null 2>&1
    printf '%s' "$dir"
}

# advance_remote <remote-dir> <clone-used-to-push> — commits one new file on
# main via a throwaway clone and pushes it, so the ORIGINAL clone under test
# is now behind and (if clean + on main) fast-forwardable.
advance_remote() {
    local remote="$1" pusher="$FIXROOT/.pusher-$$"
    git clone -q "$remote" "$pusher" >/dev/null 2>&1
    echo "advance-$RANDOM" >> "$pusher/README.md"
    git -C "$pusher" commit -q -am "advance main"
    git -C "$pusher" push -q origin main
    rm -rf "$pusher"
}

run_runner() {
    env HOME="$HOME" HIMMEL_FLOW_RUNS_LEDGER="$LEDGER" "$REAL_BASH" "$RUNNER" "$@"
}

# ============================================================================
# Flag-parsing hygiene — a missing value is a usage error, not a raw shell
# failure (a bare `shift 2` with only one arg left errors under set -e).
# ============================================================================
echo "TEST: runner flags with no value -> rc 2 usage error, not a raw shell failure"
LEDGER="$TMP_ROOT/ledger-flag-test.jsonl"
rc=0; out=$(run_runner --github-root 2>&1) || rc=$?
assert_rc "--github-root (missing value) -> rc 2" 2 "$rc"
assert_contains "--github-root (missing value) message" "--github-root requires a value" "$out"
assert_not_contains "not a raw bash shift error" "shift count" "$out"

echo "TEST: --wt-stale-days rejects a pathologically large value (codex-2, HIMMEL-2116 pr-check round-2 panel)"
rc=0; out=$(run_runner --wt-stale-days 12345678901234567890 --documents-root "$TMP_ROOT" 2>&1) || rc=$?
assert_rc "--wt-stale-days (huge value) -> rc 2" 2 "$rc"
assert_contains "--wt-stale-days (huge value) message" "unreasonably large" "$out"

# --- fixture: clean-ff ------------------------------------------------------
echo "TEST: fixture clean-ff — clean worktree, on default branch, ff pull succeeds"
REMOTE=$(mk_remote clean-ff)
REPO=$(mk_clone "$REMOTE" clean-ff)
advance_remote "$REMOTE"
LEDGER="$TMP_ROOT/ledger-clean-ff.jsonl"
GH_ROOT="$TMP_ROOT/empty-github-clean-ff"; mkdir -p "$GH_ROOT"
RESULTS="$TMP_ROOT/results-clean-ff.jsonl"
DOCS_ROOT="$FIXROOT-docs-clean-ff"; mkdir -p "$DOCS_ROOT"; mv "$REPO" "$DOCS_ROOT/repo"
rc=0
out=$(run_runner --github-root "$GH_ROOT" --documents-root "$DOCS_ROOT" --results-file "$RESULTS" --task-name t 2>&1) || rc=$?
assert_rc "clean-ff -> runner rc 0" 0 "$rc"
results=$(cat "$RESULTS" 2>/dev/null || echo "")
assert_contains "clean-ff row action=pulled" '"action":"pulled"' "$results"
assert_contains "clean-ff row ok=true" '"ok":true' "$results"
if grep -q "advance-" "$DOCS_ROOT/repo/README.md"; then
    pass "clean-ff actually fast-forwarded the working copy"
else
    fail "clean-ff actually fast-forwarded the working copy"
fi
ledger=$(cat "$LEDGER" 2>/dev/null || echo "")
assert_contains "clean-ff ledger start row" '"ev":"start","flow":"repo-sync"' "$ledger"
assert_contains "clean-ff ledger end outcome=complete" '"outcome":"complete"' "$ledger"
assert_contains "clean-ff ledger end exit_code:0" '"exit_code":0' "$ledger"

# --- fixture: dirty-skip -----------------------------------------------------
echo "TEST: fixture dirty-skip — dirty worktree is fetch-only, never pulled"
REMOTE=$(mk_remote dirty-skip)
REPO=$(mk_clone "$REMOTE" dirty-skip)
advance_remote "$REMOTE"
echo "local edit" >> "$REPO/README.md"
LEDGER="$TMP_ROOT/ledger-dirty.jsonl"
GH_ROOT="$TMP_ROOT/empty-github-dirty"; mkdir -p "$GH_ROOT"
RESULTS="$TMP_ROOT/results-dirty.jsonl"
DOCS_ROOT="$FIXROOT-docs-dirty"; mkdir -p "$DOCS_ROOT"; mv "$REPO" "$DOCS_ROOT/repo"
rc=0
out=$(run_runner --github-root "$GH_ROOT" --documents-root "$DOCS_ROOT" --results-file "$RESULTS" 2>&1) || rc=$?
assert_rc "dirty-skip -> runner rc 0 (benign skip, not a failure)" 0 "$rc"
results=$(cat "$RESULTS" 2>/dev/null || echo "")
assert_contains "dirty-skip row action=fetch-only" '"action":"fetch-only"' "$results"
assert_contains "dirty-skip row reason mentions dirty" "dirty" "$results"
if grep -q "advance-" "$DOCS_ROOT/repo/README.md"; then
    fail "dirty-skip did NOT pull (worktree stayed as-is)" "README.md carries the remote's advance"
else
    pass "dirty-skip did NOT pull (worktree stayed as-is)"
fi

# --- fixture: diverged-alert -------------------------------------------------
echo "TEST: fixture diverged-alert — local + remote diverged -> failure row, runner rc 1"
REMOTE=$(mk_remote diverged)
REPO=$(mk_clone "$REMOTE" diverged)
advance_remote "$REMOTE"
echo "local-only commit" >> "$REPO/README.md"
git -C "$REPO" commit -q -am "local-only, diverges from the advanced remote"
LEDGER="$TMP_ROOT/ledger-diverged.jsonl"
GH_ROOT="$TMP_ROOT/empty-github-diverged"; mkdir -p "$GH_ROOT"
RESULTS="$TMP_ROOT/results-diverged.jsonl"
DOCS_ROOT="$FIXROOT-docs-diverged"; mkdir -p "$DOCS_ROOT"; mv "$REPO" "$DOCS_ROOT/repo"
rc=0
out=$(run_runner --github-root "$GH_ROOT" --documents-root "$DOCS_ROOT" --results-file "$RESULTS" 2>&1) || rc=$?
assert_rc "diverged -> runner rc 1 (real failure)" 1 "$rc"
results=$(cat "$RESULTS" 2>/dev/null || echo "")
assert_contains "diverged row action=failed" '"action":"failed"' "$results"
assert_contains "diverged row ok=false" '"ok":false' "$results"
assert_contains "diverged row reason mentions diverged" "diverged" "$results"
ledger=$(cat "$LEDGER" 2>/dev/null || echo "")
assert_contains "diverged ledger end outcome=error" '"outcome":"error"' "$ledger"
assert_contains "diverged ledger end exit_code:1" '"exit_code":1' "$ledger"

# --- fixture: non-default-branch --------------------------------------------
echo "TEST: fixture non-default-branch — checked out on a non-default branch is fetch-only, branch untouched"
REMOTE=$(mk_remote non-default)
REPO=$(mk_clone "$REMOTE" non-default)
git -C "$REPO" checkout -q feature
advance_remote "$REMOTE"
LEDGER="$TMP_ROOT/ledger-nondef.jsonl"
GH_ROOT="$TMP_ROOT/empty-github-nondef"; mkdir -p "$GH_ROOT"
RESULTS="$TMP_ROOT/results-nondef.jsonl"
DOCS_ROOT="$FIXROOT-docs-nondef"; mkdir -p "$DOCS_ROOT"; mv "$REPO" "$DOCS_ROOT/repo"
rc=0
out=$(run_runner --github-root "$GH_ROOT" --documents-root "$DOCS_ROOT" --results-file "$RESULTS" 2>&1) || rc=$?
assert_rc "non-default-branch -> runner rc 0" 0 "$rc"
results=$(cat "$RESULTS" 2>/dev/null || echo "")
assert_contains "non-default-branch row action=fetch-only" '"action":"fetch-only"' "$results"
assert_contains "non-default-branch row reason mentions branch" "not the default branch" "$results"
branch_after=$(git -C "$DOCS_ROOT/repo" symbolic-ref --short HEAD)
assert_rc "non-default-branch: checked-out branch never switched" "feature" "$branch_after"

# --- fixture: single-writer --------------------------------------------------
echo "TEST: fixture single-writer — marker forces fetch-only even when otherwise pullable"
REMOTE=$(mk_remote single-writer)
REPO=$(mk_clone "$REMOTE" single-writer)
advance_remote "$REMOTE"
: > "$REPO/.single-writer"
LEDGER="$TMP_ROOT/ledger-sw.jsonl"
GH_ROOT="$TMP_ROOT/empty-github-sw"; mkdir -p "$GH_ROOT"
RESULTS="$TMP_ROOT/results-sw.jsonl"
DOCS_ROOT="$FIXROOT-docs-sw"; mkdir -p "$DOCS_ROOT"; mv "$REPO" "$DOCS_ROOT/repo"
rc=0
out=$(run_runner --github-root "$GH_ROOT" --documents-root "$DOCS_ROOT" --results-file "$RESULTS" 2>&1) || rc=$?
assert_rc "single-writer -> runner rc 0" 0 "$rc"
results=$(cat "$RESULTS" 2>/dev/null || echo "")
assert_contains "single-writer row action=fetch-only" '"action":"fetch-only"' "$results"
assert_contains "single-writer row reason=single-writer marker" "single-writer marker" "$results"
if grep -q "advance-" "$DOCS_ROOT/repo/README.md"; then
    fail "single-writer did NOT pull despite being otherwise eligible"
else
    pass "single-writer did NOT pull despite being otherwise eligible"
fi

# --- fixture: status-check-failure ------------------------------------------
echo "TEST: fixture status-check-failure — a broken \`git status\` is a real failure, not silently treated as clean"
REMOTE=$(mk_remote status-fail)
REPO=$(mk_clone "$REMOTE" status-fail)
LEDGER="$TMP_ROOT/ledger-status-fail.jsonl"
GH_ROOT="$TMP_ROOT/empty-github-status-fail"; mkdir -p "$GH_ROOT"
RESULTS="$TMP_ROOT/results-status-fail.jsonl"
DOCS_ROOT="$FIXROOT-docs-status-fail"; mkdir -p "$DOCS_ROOT"; mv "$REPO" "$DOCS_ROOT/repo"
# A `git status` wrapper stub is used instead of real repo corruption: every
# corruption attempted (bad index bytes, index-as-directory) also broke `git
# fetch` in the same repo (fetch validates the index too), which would have
# exercised the ALREADY-tested fetch-failure path instead of this one. The
# stub isolates exactly the status call classify_repo makes, leaving fetch/
# symbolic-ref/ls-remote untouched (delegated to the real git).
FAKE_GIT_DIR="$TMP_ROOT/fakegit-status-fail"
mkdir -p "$FAKE_GIT_DIR"
REAL_GIT_BIN="$(command -v git)"
cat >"$FAKE_GIT_DIR/git" <<FAKE
#!$REAL_BASH
REAL_GIT="$REAL_GIT_BIN"
FAKE
cat >>"$FAKE_GIT_DIR/git" <<'FAKE'
for a in "$@"; do
    if [ "$a" = "status" ]; then
        echo "fatal: simulated corruption for classify_repo status test" >&2
        exit 128
    fi
done
exec "$REAL_GIT" "$@"
FAKE
chmod +x "$FAKE_GIT_DIR/git"
# PATH is colon-separated, so a Windows mixed-form path (TMP_ROOT was
# cygpath -m'd above) breaks on its own drive-letter colon (`C:/...` splits
# into the bogus entries `C` and `/...`) — convert back to POSIX form before
# prepending it to PATH.
FAKE_GIT_DIR_POSIX="$FAKE_GIT_DIR"
if command -v cygpath >/dev/null 2>&1; then FAKE_GIT_DIR_POSIX=$(cygpath -u "$FAKE_GIT_DIR"); fi
rc=0
out=$(env HOME="$HOME" HIMMEL_FLOW_RUNS_LEDGER="$LEDGER" PATH="$FAKE_GIT_DIR_POSIX:$PATH" "$REAL_BASH" "$RUNNER" --github-root "$GH_ROOT" --documents-root "$DOCS_ROOT" --results-file "$RESULTS" 2>&1) || rc=$?
assert_rc "status-check-failure -> runner rc 1 (real failure, not a benign skip)" 1 "$rc"
results=$(cat "$RESULTS" 2>/dev/null || echo "")
assert_contains "status-check-failure row action=failed" '"action":"failed"' "$results"
assert_contains "status-check-failure row ok=false" '"ok":false' "$results"
assert_contains "status-check-failure row reason mentions cleanliness" "could not verify worktree cleanliness" "$results"

# --- fixture: ls-remote-failure ----------------------------------------------
echo "TEST: fixture ls-remote-failure — a broken \`git ls-remote\` (post-fetch) doesn't crash the runner, and is a real failure (not silently benign) per the SKIP+ALERT contract"
REMOTE=$(mk_remote ls-remote-fail)
REPO=$(mk_clone "$REMOTE" ls-remote-fail)
LEDGER="$TMP_ROOT/ledger-ls-remote-fail.jsonl"
GH_ROOT="$TMP_ROOT/empty-github-ls-remote-fail"; mkdir -p "$GH_ROOT"
RESULTS="$TMP_ROOT/results-ls-remote-fail.jsonl"
DOCS_ROOT="$FIXROOT-docs-ls-remote-fail"; mkdir -p "$DOCS_ROOT"; mv "$REPO" "$DOCS_ROOT/repo"
FAKE_GIT_DIR2="$TMP_ROOT/fakegit-ls-remote-fail"
mkdir -p "$FAKE_GIT_DIR2"
REAL_GIT_BIN2="$(command -v git)"
cat >"$FAKE_GIT_DIR2/git" <<FAKE
#!$REAL_BASH
REAL_GIT="$REAL_GIT_BIN2"
FAKE
cat >>"$FAKE_GIT_DIR2/git" <<'FAKE'
for a in "$@"; do
    if [ "$a" = "ls-remote" ]; then
        echo "fatal: simulated ls-remote failure for classify_repo test" >&2
        exit 128
    fi
done
exec "$REAL_GIT" "$@"
FAKE
chmod +x "$FAKE_GIT_DIR2/git"
FAKE_GIT_DIR2_POSIX="$FAKE_GIT_DIR2"
if command -v cygpath >/dev/null 2>&1; then FAKE_GIT_DIR2_POSIX=$(cygpath -u "$FAKE_GIT_DIR2"); fi
rc=0
out=$(env HOME="$HOME" HIMMEL_FLOW_RUNS_LEDGER="$LEDGER" PATH="$FAKE_GIT_DIR2_POSIX:$PATH" "$REAL_BASH" "$RUNNER" --github-root "$GH_ROOT" --documents-root "$DOCS_ROOT" --results-file "$RESULTS" 2>&1) || rc=$?
assert_rc "ls-remote-failure -> runner rc 1 (real failure, not a crash and not benign)" 1 "$rc"
results=$(cat "$RESULTS" 2>/dev/null || echo "")
assert_contains "ls-remote-failure row action=failed" '"action":"failed"' "$results"
assert_contains "ls-remote-failure row ok=false" '"ok":false' "$results"
assert_contains "ls-remote-failure row reason mentions ls-remote" "ls-remote failed" "$results"

# --- fixture: ls-remote-no-symref --------------------------------------------
echo "TEST: fixture ls-remote-no-symref — ls-remote SUCCEEDS but exposes no HEAD symref line: benign fetch-only, distinct from a genuine ls-remote failure"
REMOTE=$(mk_remote ls-remote-no-symref)
REPO=$(mk_clone "$REMOTE" ls-remote-no-symref)
LEDGER="$TMP_ROOT/ledger-ls-remote-no-symref.jsonl"
GH_ROOT="$TMP_ROOT/empty-github-ls-remote-no-symref"; mkdir -p "$GH_ROOT"
RESULTS="$TMP_ROOT/results-ls-remote-no-symref.jsonl"
DOCS_ROOT="$FIXROOT-docs-ls-remote-no-symref"; mkdir -p "$DOCS_ROOT"; mv "$REPO" "$DOCS_ROOT/repo"
FAKE_GIT_DIR3="$TMP_ROOT/fakegit-ls-remote-no-symref"
mkdir -p "$FAKE_GIT_DIR3"
REAL_GIT_BIN3="$(command -v git)"
cat >"$FAKE_GIT_DIR3/git" <<FAKE
#!$REAL_BASH
REAL_GIT="$REAL_GIT_BIN3"
FAKE
cat >>"$FAKE_GIT_DIR3/git" <<'FAKE'
for a in "$@"; do
    if [ "$a" = "ls-remote" ]; then
        # Succeeds (rc 0) but prints no "ref: refs/heads/X\tHEAD" line --
        # a remote that doesn't expose HEAD as a symref, distinct from a
        # command failure.
        echo "0000000000000000000000000000000000000000\tHEAD"
        exit 0
    fi
done
exec "$REAL_GIT" "$@"
FAKE
chmod +x "$FAKE_GIT_DIR3/git"
FAKE_GIT_DIR3_POSIX="$FAKE_GIT_DIR3"
if command -v cygpath >/dev/null 2>&1; then FAKE_GIT_DIR3_POSIX=$(cygpath -u "$FAKE_GIT_DIR3"); fi
rc=0
out=$(env HOME="$HOME" HIMMEL_FLOW_RUNS_LEDGER="$LEDGER" PATH="$FAKE_GIT_DIR3_POSIX:$PATH" "$REAL_BASH" "$RUNNER" --github-root "$GH_ROOT" --documents-root "$DOCS_ROOT" --results-file "$RESULTS" 2>&1) || rc=$?
assert_rc "ls-remote-no-symref -> runner rc 0 (benign, ls-remote itself succeeded)" 0 "$rc"
results=$(cat "$RESULTS" 2>/dev/null || echo "")
assert_contains "ls-remote-no-symref row action=fetch-only" '"action":"fetch-only"' "$results"
assert_contains "ls-remote-no-symref row reason mentions undeterminable default branch" "could not determine the remote's default branch" "$results"

# --- exclusions: bare repos + .claude/worktrees -----------------------------
echo "TEST: exclusions — bare repos and .claude/worktrees paths never appear in results"
GH_ROOT="$TMP_ROOT/excl-github"
mkdir -p "$GH_ROOT"
git init -q --bare "$GH_ROOT/a-bare-repo.git"
REMOTE=$(mk_remote excl)
NORMAL_REPO="$GH_ROOT/normal-repo"
git clone -q "$REMOTE" "$NORMAL_REPO" >/dev/null 2>&1
mkdir -p "$NORMAL_REPO/.claude/worktrees/some-feature"
git init -q -b feat "$NORMAL_REPO/.claude/worktrees/some-feature" >/dev/null 2>&1
DOCS_ROOT="$TMP_ROOT/excl-docs"; mkdir -p "$DOCS_ROOT"
LEDGER="$TMP_ROOT/ledger-excl.jsonl"
RESULTS="$TMP_ROOT/results-excl.jsonl"
rc=0
out=$(run_runner --github-root "$GH_ROOT" --documents-root "$DOCS_ROOT" --results-file "$RESULTS" 2>&1) || rc=$?
results=$(cat "$RESULTS" 2>/dev/null || echo "")
assert_not_contains "bare repo never rowed" "a-bare-repo" "$results"
assert_not_contains ".claude/worktrees never rowed" "worktrees" "$results"
assert_contains "normal sibling repo still rowed" "normal-repo" "$results"

# --- enumeration depth: documents-root stops at depth 2 ---------------------
echo "TEST: enumeration — documents-root scans to depth 2, not deeper"
DOCS_ROOT="$TMP_ROOT/depth-docs"
mkdir -p "$DOCS_ROOT"
REMOTE=$(mk_remote depth)
git clone -q "$REMOTE" "$DOCS_ROOT/depth1-repo" >/dev/null 2>&1
mkdir -p "$DOCS_ROOT/sub"
git clone -q "$REMOTE" "$DOCS_ROOT/sub/depth2-repo" >/dev/null 2>&1
mkdir -p "$DOCS_ROOT/sub/deeper"
git clone -q "$REMOTE" "$DOCS_ROOT/sub/deeper/depth3-repo" >/dev/null 2>&1
GH_ROOT="$TMP_ROOT/depth-empty-github"; mkdir -p "$GH_ROOT"
LEDGER="$TMP_ROOT/ledger-depth.jsonl"
RESULTS="$TMP_ROOT/results-depth.jsonl"
rc=0
out=$(run_runner --github-root "$GH_ROOT" --documents-root "$DOCS_ROOT" --results-file "$RESULTS" 2>&1) || rc=$?
results=$(cat "$RESULTS" 2>/dev/null || echo "")
assert_contains "depth1 repo found" "depth1-repo" "$results"
assert_contains "depth2 repo found" "depth2-repo" "$results"
assert_not_contains "depth3 repo NOT found (beyond depth-2 scan)" "depth3-repo" "$results"

# --- enumeration: github-root is excluded from the documents-root scan -----
echo "TEST: enumeration — github-root subtree is not double-scanned when nested under documents-root"
DOCS_ROOT="$TMP_ROOT/nested-docs"
mkdir -p "$DOCS_ROOT"
GH_ROOT="$DOCS_ROOT/github"
mkdir -p "$GH_ROOT"
REMOTE=$(mk_remote nested)
git clone -q "$REMOTE" "$GH_ROOT/nested-repo" >/dev/null 2>&1
LEDGER="$TMP_ROOT/ledger-nested.jsonl"
RESULTS="$TMP_ROOT/results-nested.jsonl"
rc=0
out=$(run_runner --github-root "$GH_ROOT" --documents-root "$DOCS_ROOT" --results-file "$RESULTS" 2>&1) || rc=$?
results=$(cat "$RESULTS" 2>/dev/null || echo "")
count=$(grep -c "nested-repo" <<< "$results" || true)
assert_rc "nested-repo appears exactly once (no double count)" "1" "$count"

# --- enumeration: a failing `find` WARNs but does not abort the run --------
echo "TEST: enumeration — a failing 'find' WARNs but does not abort the runner (codex-1, HIMMEL-2115 pr-check round-9 panel: a bare set -e assignment must not silently crash mid-scan on a permission-denied subtree)"
DOCS_ROOT="$TMP_ROOT/findfail-docs"; mkdir -p "$DOCS_ROOT"
REMOTE=$(mk_remote findfail)
git clone -q "$REMOTE" "$DOCS_ROOT/repo" >/dev/null 2>&1
GH_ROOT="$TMP_ROOT/findfail-empty-github"; mkdir -p "$GH_ROOT"
LEDGER="$TMP_ROOT/ledger-findfail.jsonl"
RESULTS="$TMP_ROOT/results-findfail.jsonl"
REAL_FIND_BIN="$(command -v find)"
FAKE_FIND_DIR="$TMP_ROOT/fakefind"
mkdir -p "$FAKE_FIND_DIR"
cat >"$FAKE_FIND_DIR/find" <<FAKE
#!$REAL_BASH
REAL_FIND="$REAL_FIND_BIN"
FAKE
cat >>"$FAKE_FIND_DIR/find" <<'FAKE'
"$REAL_FIND" "$@"
echo "find: simulated permission-denied injection" >&2
exit 1
FAKE
chmod +x "$FAKE_FIND_DIR/find"
FAKE_FIND_DIR_POSIX="$FAKE_FIND_DIR"
if command -v cygpath >/dev/null 2>&1; then FAKE_FIND_DIR_POSIX=$(cygpath -u "$FAKE_FIND_DIR"); fi
rc=0
out=$(env HOME="$HOME" HIMMEL_FLOW_RUNS_LEDGER="$LEDGER" PATH="$FAKE_FIND_DIR_POSIX:$PATH" "$REAL_BASH" "$RUNNER" --github-root "$GH_ROOT" --documents-root "$DOCS_ROOT" --results-file "$RESULTS" 2>&1) || rc=$?
assert_rc "runner completes (does not abort) but reports outcome=error via exit code 1 (codex-1, HIMMEL-2115 pr-check round-10 panel: a WARN alone never reached the run's outcome)" 1 "$rc"
assert_contains "failing find WARNs instead of silently discarding" "WARN repo-sync-runner: 'find' failed" "$out"
assert_contains "the run's note surfaces the directory-scan failure (reaches the flow-run-ledger note, not just stderr)" "directory scans failed" "$out"
results=$(cat "$RESULTS" 2>/dev/null || echo "")
assert_contains "repo under the still-listed directory is still found and rowed despite the find WARN" "repo" "$results"

# --- results-file rotation: a failed mv must NOT truncate the old file -----
echo "TEST: results-file rotation — a failed mv (rotation) leaves the previous run's results intact instead of truncating them (HIMMEL-2115 round-7 codex-2)"
GH_ROOT="$TMP_ROOT/rotate-empty-github"; mkdir -p "$GH_ROOT"
DOCS_ROOT="$TMP_ROOT/rotate-empty-docs"; mkdir -p "$DOCS_ROOT"
LEDGER="$TMP_ROOT/ledger-rotate.jsonl"
RESULTS="$TMP_ROOT/results-rotate.jsonl"
echo '{"sentinel":"previous-run-data"}' > "$RESULTS"
FAKE_MV_DIR="$TMP_ROOT/fakemv-rotate"
mkdir -p "$FAKE_MV_DIR"
cat >"$FAKE_MV_DIR/mv" <<FAKE
#!$REAL_BASH
echo "fake mv: simulated rotation failure" >&2
exit 1
FAKE
chmod +x "$FAKE_MV_DIR/mv"
FAKE_MV_DIR_POSIX="$FAKE_MV_DIR"
if command -v cygpath >/dev/null 2>&1; then FAKE_MV_DIR_POSIX=$(cygpath -u "$FAKE_MV_DIR"); fi
rc=0
out=$(env HOME="$HOME" HIMMEL_FLOW_RUNS_LEDGER="$LEDGER" PATH="$FAKE_MV_DIR_POSIX:$PATH" "$REAL_BASH" "$RUNNER" --github-root "$GH_ROOT" --documents-root "$DOCS_ROOT" --results-file "$RESULTS" 2>&1) || rc=$?
assert_rc "rotation failure -> runner completes but reports outcome=error via exit code 1 (codex-2, HIMMEL-2115 pr-check round-10 panel: a WARN alone never reached the run's outcome)" 1 "$rc"
results=$(cat "$RESULTS" 2>/dev/null || echo "")
assert_contains "old results NOT wiped by a failed rotation" "previous-run-data" "$results"
assert_contains "rotation failure emits a stderr WARN (results file now mixes stale+fresh rows)" "WARN rotation of" "$out"
assert_contains "the run's note surfaces the rotation failure" "results-file rotation failed" "$out"

# ============================================================================
# Stale-wt cleanup pass (HIMMEL-2116, follow-up to HIMMEL-2115) — runs on
# every platform, same fixture style as the sync tests above.
# ============================================================================

# mk_wt <remote-dir> <parent-name> <wt-folder> <branch> — a normal clone of
# <remote-dir> (the "parent" repo, kept OUTSIDE any scanned root) plus a
# linked worktree checked out on a new branch at <wt-folder> (the actual
# scan target). Echoes "<parent-dir> <wt-dir>".
mk_wt() {
    local remote="$1" parent_name="$2" wt_dir="$3" branch="$4" parent
    parent="$FIXROOT/.parent-$parent_name"
    git clone -q "$remote" "$parent" >/dev/null 2>&1
    git -C "$parent" worktree add -q "$wt_dir" -b "$branch" >/dev/null 2>&1
    printf '%s %s' "$parent" "$wt_dir"
}

echo "TEST: fixture wt-deleted — clean, fully pushed, stale -> deleted + parent worktree pruned"
REMOTE=$(mk_remote wt-deleted)
DOCS_ROOT="$FIXROOT-docs-wt-deleted"; mkdir -p "$DOCS_ROOT"
WT="$DOCS_ROOT/wt-deleted"
read -r PARENT _ <<< "$(mk_wt "$REMOTE" wt-deleted "$WT" wt-deleted-branch)"
git -C "$WT" push -q -u origin wt-deleted-branch
touch -d '20 days ago' "$WT"
GH_ROOT="$TMP_ROOT/empty-github-wt-deleted"; mkdir -p "$GH_ROOT"
LEDGER="$TMP_ROOT/ledger-wt-deleted.jsonl"
RESULTS="$TMP_ROOT/results-wt-deleted.jsonl"
rc=0
out=$(run_runner --github-root "$GH_ROOT" --documents-root "$DOCS_ROOT" --results-file "$RESULTS" --wt-stale-days 1 2>&1) || rc=$?
assert_rc "wt-deleted -> runner rc 0" 0 "$rc"
results=$(cat "$RESULTS" 2>/dev/null || echo "")
assert_contains "wt-deleted row kind=wt-cleanup" '"kind":"wt-cleanup"' "$results"
assert_contains "wt-deleted row action=deleted" '"action":"deleted"' "$results"
if [ -d "$WT" ]; then fail "wt-deleted folder actually removed from disk"; else pass "wt-deleted folder actually removed from disk"; fi
if [ -d "$PARENT/.git/worktrees/wt-deleted" ]; then
    fail "parent's worktree registry pruned (git worktree prune ran)" "admin dir still present"
else
    pass "parent's worktree registry pruned (git worktree prune ran)"
fi
ledger=$(cat "$LEDGER" 2>/dev/null || echo "")
assert_contains "wt-deleted ledger note counts the deletion" "wt-cleanup: 1 deleted" "$ledger"

echo "TEST: fixture wt-dirty — uncommitted changes -> ALERT, not deleted"
REMOTE=$(mk_remote wt-dirty)
DOCS_ROOT="$FIXROOT-docs-wt-dirty"; mkdir -p "$DOCS_ROOT"
WT="$DOCS_ROOT/wt-dirty"
read -r PARENT _ <<< "$(mk_wt "$REMOTE" wt-dirty "$WT" wt-dirty-branch)"
git -C "$WT" push -q -u origin wt-dirty-branch
echo "uncommitted edit" >> "$WT/README.md"
touch -d '20 days ago' "$WT"
GH_ROOT="$TMP_ROOT/empty-github-wt-dirty"; mkdir -p "$GH_ROOT"
LEDGER="$TMP_ROOT/ledger-wt-dirty.jsonl"
RESULTS="$TMP_ROOT/results-wt-dirty.jsonl"
rc=0
out=$(run_runner --github-root "$GH_ROOT" --documents-root "$DOCS_ROOT" --results-file "$RESULTS" --wt-stale-days 1 2>&1) || rc=$?
assert_rc "wt-dirty -> runner rc 1 (alert folds into the run's outcome)" 1 "$rc"
results=$(cat "$RESULTS" 2>/dev/null || echo "")
assert_contains "wt-dirty row action=alert" '"action":"alert"' "$results"
assert_contains "wt-dirty row reason mentions dirty" "dirty" "$results"
if [ -d "$WT" ]; then pass "wt-dirty folder NOT deleted"; else fail "wt-dirty folder NOT deleted" "folder was removed despite being dirty"; fi

echo "TEST: fixture wt-unpushed — committed but unpushed commits -> ALERT, not deleted"
REMOTE=$(mk_remote wt-unpushed)
DOCS_ROOT="$FIXROOT-docs-wt-unpushed"; mkdir -p "$DOCS_ROOT"
WT="$DOCS_ROOT/wt-unpushed"
read -r PARENT _ <<< "$(mk_wt "$REMOTE" wt-unpushed "$WT" wt-unpushed-branch)"
git -C "$WT" push -q -u origin wt-unpushed-branch
echo "local-only commit" >> "$WT/README.md"
git -C "$WT" commit -q -am "not pushed"
touch -d '20 days ago' "$WT"
GH_ROOT="$TMP_ROOT/empty-github-wt-unpushed"; mkdir -p "$GH_ROOT"
LEDGER="$TMP_ROOT/ledger-wt-unpushed.jsonl"
RESULTS="$TMP_ROOT/results-wt-unpushed.jsonl"
rc=0
out=$(run_runner --github-root "$GH_ROOT" --documents-root "$DOCS_ROOT" --results-file "$RESULTS" --wt-stale-days 1 2>&1) || rc=$?
assert_rc "wt-unpushed -> runner rc 1" 1 "$rc"
results=$(cat "$RESULTS" 2>/dev/null || echo "")
assert_contains "wt-unpushed row action=alert" '"action":"alert"' "$results"
assert_contains "wt-unpushed row reason mentions unpushed" "unpushed commit" "$results"
if [ -d "$WT" ]; then pass "wt-unpushed folder NOT deleted"; else fail "wt-unpushed folder NOT deleted" "folder was removed despite unpushed commits"; fi

echo "TEST: fixture wt-unique-branch — no upstream configured -> ALERT (unique branch), not deleted"
REMOTE=$(mk_remote wt-unique)
DOCS_ROOT="$FIXROOT-docs-wt-unique"; mkdir -p "$DOCS_ROOT"
WT="$DOCS_ROOT/wt-unique"
read -r PARENT _ <<< "$(mk_wt "$REMOTE" wt-unique "$WT" wt-unique-branch)"
touch -d '20 days ago' "$WT"
GH_ROOT="$TMP_ROOT/empty-github-wt-unique"; mkdir -p "$GH_ROOT"
LEDGER="$TMP_ROOT/ledger-wt-unique.jsonl"
RESULTS="$TMP_ROOT/results-wt-unique.jsonl"
rc=0
out=$(run_runner --github-root "$GH_ROOT" --documents-root "$DOCS_ROOT" --results-file "$RESULTS" --wt-stale-days 1 2>&1) || rc=$?
assert_rc "wt-unique-branch -> runner rc 1" 1 "$rc"
results=$(cat "$RESULTS" 2>/dev/null || echo "")
assert_contains "wt-unique-branch row action=alert" '"action":"alert"' "$results"
assert_contains "wt-unique-branch row reason mentions unique branch" "unique branch" "$results"
if [ -d "$WT" ]; then pass "wt-unique-branch folder NOT deleted"; else fail "wt-unique-branch folder NOT deleted" "folder was removed despite no upstream"; fi

echo "TEST: fixture wt-fresh — clean + fully pushed but NOT yet stale -> skipped, not deleted"
REMOTE=$(mk_remote wt-fresh)
DOCS_ROOT="$FIXROOT-docs-wt-fresh"; mkdir -p "$DOCS_ROOT"
WT="$DOCS_ROOT/wt-fresh"
read -r PARENT _ <<< "$(mk_wt "$REMOTE" wt-fresh "$WT" wt-fresh-branch)"
git -C "$WT" push -q -u origin wt-fresh-branch
GH_ROOT="$TMP_ROOT/empty-github-wt-fresh"; mkdir -p "$GH_ROOT"
LEDGER="$TMP_ROOT/ledger-wt-fresh.jsonl"
RESULTS="$TMP_ROOT/results-wt-fresh.jsonl"
rc=0
out=$(run_runner --github-root "$GH_ROOT" --documents-root "$DOCS_ROOT" --results-file "$RESULTS" --wt-stale-days 14 2>&1) || rc=$?
assert_rc "wt-fresh -> runner rc 0 (skip is benign, not an alert)" 0 "$rc"
results=$(cat "$RESULTS" 2>/dev/null || echo "")
assert_contains "wt-fresh row action=skip" '"action":"skip"' "$results"
assert_contains "wt-fresh row reason mentions not yet stale" "not yet stale" "$results"
if [ -d "$WT" ]; then pass "wt-fresh folder NOT deleted"; else fail "wt-fresh folder NOT deleted" "folder was removed despite being fresh"; fi

echo "TEST: fixture wt-standalone-named — clean+stale+pushed but a STANDALONE clone (not a linked worktree) named wt-* -> ALERT, never auto-deleted by name alone (codex-1, HIMMEL-2116 pr-check panel)"
REMOTE=$(mk_remote wt-standalone)
DOCS_ROOT="$FIXROOT-docs-wt-standalone"; mkdir -p "$DOCS_ROOT"
WT="$DOCS_ROOT/wt-standalone"
git clone -q "$REMOTE" "$WT" >/dev/null 2>&1
touch -d '20 days ago' "$WT"
GH_ROOT="$TMP_ROOT/empty-github-wt-standalone"; mkdir -p "$GH_ROOT"
LEDGER="$TMP_ROOT/ledger-wt-standalone.jsonl"
RESULTS="$TMP_ROOT/results-wt-standalone.jsonl"
rc=0
out=$(run_runner --github-root "$GH_ROOT" --documents-root "$DOCS_ROOT" --results-file "$RESULTS" --wt-stale-days 1 2>&1) || rc=$?
assert_rc "wt-standalone-named -> runner rc 1 (alert, not clean)" 1 "$rc"
results=$(cat "$RESULTS" 2>/dev/null || echo "")
assert_contains "wt-standalone-named row action=alert" '"action":"alert"' "$results"
assert_contains "wt-standalone-named row reason mentions standalone" "STANDALONE" "$results"
if [ -d "$WT" ]; then pass "wt-standalone-named folder NOT deleted"; else fail "wt-standalone-named folder NOT deleted" "an ordinary repo named wt-* was deleted by name coincidence"; fi

echo "TEST: fixture wt-ignored-file — clean per tracked status but an ignored file present -> ALERT (dirty), not deleted (codex-2, HIMMEL-2116 pr-check panel)"
REMOTE=$(mk_remote wt-ignored)
DOCS_ROOT="$FIXROOT-docs-wt-ignored"; mkdir -p "$DOCS_ROOT"
WT="$DOCS_ROOT/wt-ignored"
read -r PARENT _ <<< "$(mk_wt "$REMOTE" wt-ignored "$WT" wt-ignored-branch)"
git -C "$WT" push -q -u origin wt-ignored-branch
echo "*.local" > "$WT/.gitignore"
git -C "$WT" add .gitignore
git -C "$WT" commit -q -m "add gitignore"
git -C "$WT" push -q origin wt-ignored-branch
echo "local secret" > "$WT/secret.local"
touch -d '20 days ago' "$WT"
GH_ROOT="$TMP_ROOT/empty-github-wt-ignored"; mkdir -p "$GH_ROOT"
LEDGER="$TMP_ROOT/ledger-wt-ignored.jsonl"
RESULTS="$TMP_ROOT/results-wt-ignored.jsonl"
rc=0
out=$(run_runner --github-root "$GH_ROOT" --documents-root "$DOCS_ROOT" --results-file "$RESULTS" --wt-stale-days 1 2>&1) || rc=$?
assert_rc "wt-ignored-file -> runner rc 1 (alert, not clean)" 1 "$rc"
results=$(cat "$RESULTS" 2>/dev/null || echo "")
assert_contains "wt-ignored-file row action=alert" '"action":"alert"' "$results"
assert_contains "wt-ignored-file row reason mentions dirty" "dirty" "$results"
if [ -f "$WT/secret.local" ]; then pass "wt-ignored-file: ignored file NOT destroyed"; else fail "wt-ignored-file: ignored file NOT destroyed" "folder (and the ignored file in it) was deleted"; fi

echo "TEST: fixture wt-remote-deleted — upstream branch pushed then DELETED from the remote without an intervening fetch -> ALERT (stale @{u} refreshed via fetch --prune), not deleted (codex-1, HIMMEL-2116 pr-check round-3 panel)"
REMOTE=$(mk_remote wt-remote-deleted)
DOCS_ROOT="$FIXROOT-docs-wt-remote-deleted"; mkdir -p "$DOCS_ROOT"
WT="$DOCS_ROOT/wt-remote-deleted"
read -r PARENT _ <<< "$(mk_wt "$REMOTE" wt-remote-deleted "$WT" wt-remote-deleted-branch)"
git -C "$WT" push -q -u origin wt-remote-deleted-branch
# Delete the branch from the remote via a THROWAWAY clone -- $WT's own local
# remote-tracking ref (refs/remotes/origin/wt-remote-deleted-branch) is left
# stale (still showing the branch as present, ahead=0) until something
# fetches --prune from inside $WT itself, which is exactly what
# classify_wt_candidate must now do before trusting "fully pushed".
DELETER="$FIXROOT/.deleter-wt-remote-deleted"
git clone -q "$REMOTE" "$DELETER" >/dev/null 2>&1
git -C "$DELETER" push -q origin --delete wt-remote-deleted-branch
rm -rf "$DELETER"
touch -d '20 days ago' "$WT"
GH_ROOT="$TMP_ROOT/empty-github-wt-remote-deleted"; mkdir -p "$GH_ROOT"
LEDGER="$TMP_ROOT/ledger-wt-remote-deleted.jsonl"
RESULTS="$TMP_ROOT/results-wt-remote-deleted.jsonl"
rc=0
out=$(run_runner --github-root "$GH_ROOT" --documents-root "$DOCS_ROOT" --results-file "$RESULTS" --wt-stale-days 1 2>&1) || rc=$?
assert_rc "wt-remote-deleted -> runner rc 1 (alert, not clean)" 1 "$rc"
results=$(cat "$RESULTS" 2>/dev/null || echo "")
assert_contains "wt-remote-deleted row action=alert" '"action":"alert"' "$results"
if [ -d "$WT" ]; then pass "wt-remote-deleted folder NOT deleted"; else fail "wt-remote-deleted folder NOT deleted" "commits with no surviving remote copy were deleted"; fi

echo "TEST: fixture wt-locked — clean+stale+pushed but explicitly \`git worktree lock\`ed -> ALERT, never auto-deleted regardless of other gates (codex-3, HIMMEL-2116 pr-check round-4 panel)"
REMOTE=$(mk_remote wt-locked)
DOCS_ROOT="$FIXROOT-docs-wt-locked"; mkdir -p "$DOCS_ROOT"
WT="$DOCS_ROOT/wt-locked"
read -r PARENT _ <<< "$(mk_wt "$REMOTE" wt-locked "$WT" wt-locked-branch)"
git -C "$WT" push -q -u origin wt-locked-branch
git -C "$PARENT" worktree lock "$WT" --reason "held for pr-check fixture"
touch -d '20 days ago' "$WT"
GH_ROOT="$TMP_ROOT/empty-github-wt-locked"; mkdir -p "$GH_ROOT"
LEDGER="$TMP_ROOT/ledger-wt-locked.jsonl"
RESULTS="$TMP_ROOT/results-wt-locked.jsonl"
rc=0
out=$(run_runner --github-root "$GH_ROOT" --documents-root "$DOCS_ROOT" --results-file "$RESULTS" --wt-stale-days 1 2>&1) || rc=$?
assert_rc "wt-locked -> runner rc 1 (alert, not clean)" 1 "$rc"
results=$(cat "$RESULTS" 2>/dev/null || echo "")
assert_contains "wt-locked row action=alert" '"action":"alert"' "$results"
assert_contains "wt-locked row reason mentions locked" "locked" "$results"
if [ -d "$WT" ]; then pass "wt-locked folder NOT deleted"; else fail "wt-locked folder NOT deleted" "an explicitly locked worktree was removed"; fi

echo "TEST: fixture wt-showuntracked-no — status.showUntrackedFiles=no locally configured, an untracked file present -> ALERT (dirty), not deleted (codex-1, HIMMEL-2116 pr-check round-4 panel)"
REMOTE=$(mk_remote wt-showuntracked)
DOCS_ROOT="$FIXROOT-docs-wt-showuntracked"; mkdir -p "$DOCS_ROOT"
WT="$DOCS_ROOT/wt-showuntracked"
read -r PARENT _ <<< "$(mk_wt "$REMOTE" wt-showuntracked "$WT" wt-showuntracked-branch)"
git -C "$WT" push -q -u origin wt-showuntracked-branch
git -C "$WT" config status.showUntrackedFiles no
echo "untracked" > "$WT/untracked-file.txt"
touch -d '20 days ago' "$WT"
GH_ROOT="$TMP_ROOT/empty-github-wt-showuntracked"; mkdir -p "$GH_ROOT"
LEDGER="$TMP_ROOT/ledger-wt-showuntracked.jsonl"
RESULTS="$TMP_ROOT/results-wt-showuntracked.jsonl"
rc=0
out=$(run_runner --github-root "$GH_ROOT" --documents-root "$DOCS_ROOT" --results-file "$RESULTS" --wt-stale-days 1 2>&1) || rc=$?
assert_rc "wt-showuntracked-no -> runner rc 1 (alert, not clean)" 1 "$rc"
results=$(cat "$RESULTS" 2>/dev/null || echo "")
assert_contains "wt-showuntracked-no row action=alert" '"action":"alert"' "$results"
assert_contains "wt-showuntracked-no row reason mentions dirty" "dirty" "$results"
if [ -f "$WT/untracked-file.txt" ]; then pass "wt-showuntracked-no: untracked file NOT destroyed"; else fail "wt-showuntracked-no: untracked file NOT destroyed" "folder (and the untracked file in it) was deleted despite local config hiding it from plain status"; fi

echo "TEST: fixture wt-other-remote-deleted — upstream tracks a DIFFERENT remote than \$REMOTE (origin); THAT remote's branch is deleted -> refreshing only \$REMOTE never catches it (HIMMEL-2208: must resolve @{u}'s own remote and fetch --prune THAT remote)"
REMOTE=$(mk_remote wt-other-origin)
OTHER_REMOTE=$(mk_remote wt-other-second)
DOCS_ROOT="$FIXROOT-docs-wt-other-remote"; mkdir -p "$DOCS_ROOT"
WT="$DOCS_ROOT/wt-other-remote"
read -r PARENT _ <<< "$(mk_wt "$REMOTE" wt-other-remote "$WT" wt-other-remote-branch)"
git -C "$WT" push -q -u origin wt-other-remote-branch
git -C "$WT" remote add other "$OTHER_REMOTE"
git -C "$WT" push -q other wt-other-remote-branch
git -C "$WT" branch --set-upstream-to=other/wt-other-remote-branch wt-other-remote-branch
# Delete the branch from the OTHER remote (never $REMOTE/origin) via a
# throwaway clone -- $WT's local other/wt-other-remote-branch tracking ref is
# left stale (still showing ahead=0) until something fetches --prune THAT
# remote specifically from inside $WT.
DELETER="$FIXROOT/.deleter-wt-other-remote"
git clone -q "$OTHER_REMOTE" "$DELETER" >/dev/null 2>&1
git -C "$DELETER" push -q origin --delete wt-other-remote-branch
rm -rf "$DELETER"
touch -d '20 days ago' "$WT"
GH_ROOT="$TMP_ROOT/empty-github-wt-other-remote"; mkdir -p "$GH_ROOT"
LEDGER="$TMP_ROOT/ledger-wt-other-remote.jsonl"
RESULTS="$TMP_ROOT/results-wt-other-remote.jsonl"
rc=0
out=$(run_runner --github-root "$GH_ROOT" --documents-root "$DOCS_ROOT" --results-file "$RESULTS" --wt-stale-days 1 2>&1) || rc=$?
assert_rc "wt-other-remote-deleted -> runner rc 1 (alert, not clean)" 1 "$rc"
results=$(cat "$RESULTS" 2>/dev/null || echo "")
assert_contains "wt-other-remote-deleted row action=alert" '"action":"alert"' "$results"
if [ -d "$WT" ]; then pass "wt-other-remote-deleted folder NOT deleted"; else fail "wt-other-remote-deleted folder NOT deleted" "branch deleted on the tracked (non-\$REMOTE) remote was wrongly treated as fully pushed"; fi

echo "TEST: fixture wt-local-upstream — upstream is a LOCAL branch (branch.<name>.remote='.'), never pushed to any remote -> ALERT, not deleted (HIMMEL-2208 edge case: %(upstream:remotename) returns the literal '.', not empty, so a bare -z check does not catch it)"
REMOTE=$(mk_remote wt-local-upstream)
DOCS_ROOT="$FIXROOT-docs-wt-local-upstream"; mkdir -p "$DOCS_ROOT"
WT="$DOCS_ROOT/wt-local-upstream"
read -r PARENT _ <<< "$(mk_wt "$REMOTE" wt-local-upstream "$WT" wt-local-upstream-branch)"
# Deliberately never pushed to origin -- point the branch's upstream at
# ANOTHER LOCAL branch instead, so branch.<name>.remote is "." not a remote.
git -C "$WT" branch other-local
git -C "$WT" branch --set-upstream-to=other-local wt-local-upstream-branch
touch -d '20 days ago' "$WT"
GH_ROOT="$TMP_ROOT/empty-github-wt-local-upstream"; mkdir -p "$GH_ROOT"
LEDGER="$TMP_ROOT/ledger-wt-local-upstream.jsonl"
RESULTS="$TMP_ROOT/results-wt-local-upstream.jsonl"
rc=0
out=$(run_runner --github-root "$GH_ROOT" --documents-root "$DOCS_ROOT" --results-file "$RESULTS" --wt-stale-days 1 2>&1) || rc=$?
assert_rc "wt-local-upstream -> runner rc 1 (alert, not clean)" 1 "$rc"
results=$(cat "$RESULTS" 2>/dev/null || echo "")
assert_contains "wt-local-upstream row action=alert" '"action":"alert"' "$results"
assert_contains "wt-local-upstream row reason mentions local-only upstream" "local-only upstream" "$results"
if [ -d "$WT" ]; then pass "wt-local-upstream folder NOT deleted"; else fail "wt-local-upstream folder NOT deleted" "a branch tracking a LOCAL branch (never pushed anywhere) was wrongly treated as fully pushed"; fi

echo "TEST: fixture wt-bare-parent — clean, fully pushed, stale, linked worktree whose PARENT is itself a BARE repo -> deleted + prune runs on the bare parent directly (HIMMEL-2207 bare-repo-parent prune gap)"
REMOTE=$(mk_remote wt-bare-parent)
DOCS_ROOT="$FIXROOT-docs-wt-bare-parent"; mkdir -p "$DOCS_ROOT"
WT="$DOCS_ROOT/wt-bare-parent"
BARE_PARENT="$FIXROOT/.bare-parent-wt-bare-parent"
# `git clone --bare` does NOT configure remote.origin.fetch's refs/remotes/*
# mapping (it mirrors refs/heads/* directly instead) -- a worktree off THAT
# kind of bare repo can never resolve @{u} at all, which would fail this
# fixture for an unrelated reason. `git init --bare` + `remote add` sets up
# the standard fetch refspec, matching a real bare-repo-as-worktree-parent
# setup (e.g. `git clone --bare` used deliberately AS a remote target is rare;
# the common case -- and what this fixture needs -- is a bare repo used the
# way `git worktree add` documents, with a normal remote configured on it).
git init -q --bare "$BARE_PARENT"
git -C "$BARE_PARENT" remote add origin "$REMOTE"
git -C "$BARE_PARENT" fetch -q origin
git -C "$BARE_PARENT" worktree add -q "$WT" -b wt-bare-parent-branch origin/main >/dev/null 2>&1
git -C "$WT" push -q -u origin wt-bare-parent-branch
touch -d '20 days ago' "$WT"
GH_ROOT="$TMP_ROOT/empty-github-wt-bare-parent"; mkdir -p "$GH_ROOT"
LEDGER="$TMP_ROOT/ledger-wt-bare-parent.jsonl"
RESULTS="$TMP_ROOT/results-wt-bare-parent.jsonl"
rc=0
out=$(run_runner --github-root "$GH_ROOT" --documents-root "$DOCS_ROOT" --results-file "$RESULTS" --wt-stale-days 1 2>&1) || rc=$?
assert_rc "wt-bare-parent -> runner rc 0" 0 "$rc"
results=$(cat "$RESULTS" 2>/dev/null || echo "")
assert_contains "wt-bare-parent row action=deleted" '"action":"deleted"' "$results"
if [ -d "$WT" ]; then fail "wt-bare-parent folder actually removed from disk"; else pass "wt-bare-parent folder actually removed from disk"; fi
if [ -d "$BARE_PARENT/worktrees/wt-bare-parent" ]; then
    fail "bare parent's worktree registry pruned (git worktree prune ran on the bare repo itself)" "admin dir still present at $BARE_PARENT/worktrees/wt-bare-parent"
else
    pass "bare parent's worktree registry pruned (git worktree prune ran on the bare repo itself)"
fi

echo "TEST: _wt_reverify_deletable helper (HIMMEL-2207 TOCTOU re-check before delete) — clean+pushed repo passes, a tracked/ignored change or a new unpushed commit appearing after classification fails"
FN_FILE="$TMP_ROOT/wt-reverify-deletable-fn.sh"
sed -n '/^_wt_reverify_deletable() {/,/^}/p' "$RUNNER" > "$FN_FILE"
if [ -s "$FN_FILE" ]; then
    pass "_wt_reverify_deletable extracted from $RUNNER"
else
    fail "_wt_reverify_deletable extracted from $RUNNER" "sed found no match -- function renamed or removed?"
fi
REVERIFY_REMOTE=$(mk_remote reverify-deletable)
REVERIFY_REPO="$FIXROOT/.reverify-clean"
git clone -q "$REVERIFY_REMOTE" "$REVERIFY_REPO" >/dev/null 2>&1
printf '*.local\n' > "$REVERIFY_REPO/.gitignore"
git -C "$REVERIFY_REPO" add .gitignore
git -C "$REVERIFY_REPO" commit -q -m gitignore
git -C "$REVERIFY_REPO" push -q origin main

rc=0
# shellcheck disable=SC2016
"$REAL_BASH" -c '. "$1"; _wt_reverify_deletable "$2"' _ "$FN_FILE" "$REVERIFY_REPO" || rc=$?
assert_rc "_wt_reverify_deletable: clean + fully pushed -> rc 0 (still safe to delete)" 0 "$rc"

echo "tracked edit after classification" >> "$REVERIFY_REPO/README.md"
rc=0
# shellcheck disable=SC2016
"$REAL_BASH" -c '. "$1"; _wt_reverify_deletable "$2"' _ "$FN_FILE" "$REVERIFY_REPO" || rc=$?
assert_rc "_wt_reverify_deletable: tracked edit appeared -> rc 1 (blocks the delete)" 1 "$rc"
git -C "$REVERIFY_REPO" checkout -q -- README.md

echo "leftover" > "$REVERIFY_REPO/secret.local"
rc=0
# shellcheck disable=SC2016
"$REAL_BASH" -c '. "$1"; _wt_reverify_deletable "$2"' _ "$FN_FILE" "$REVERIFY_REPO" || rc=$?
assert_rc "_wt_reverify_deletable: ignored file appeared -> rc 1 (same --ignored discipline as classify_wt_candidate)" 1 "$rc"
rm -f "$REVERIFY_REPO/secret.local"

echo "TEST: fixture _wt_reverify_deletable — a NEW commit appeared after classification (worktree is clean again, but now unpushed) -> rc 1, blocks the delete (codex-1, HIMMEL-2208 pr-check round-2 panel: re-checking cleanliness alone is not enough)"
echo "new local-only work" >> "$REVERIFY_REPO/README.md"
git -C "$REVERIFY_REPO" commit -q -am "unpushed commit made after classification"
rc=0
# shellcheck disable=SC2016
"$REAL_BASH" -c '. "$1"; _wt_reverify_deletable "$2"' _ "$FN_FILE" "$REVERIFY_REPO" || rc=$?
assert_rc "_wt_reverify_deletable: new unpushed commit appeared -> rc 1 (blocks the delete despite a clean working tree)" 1 "$rc"

NOT_A_REPO="$FIXROOT/.reverify-not-a-repo"
mkdir -p "$NOT_A_REPO"
rc=0
# shellcheck disable=SC2016
"$REAL_BASH" -c '. "$1"; _wt_reverify_deletable "$2"' _ "$FN_FILE" "$NOT_A_REPO" || rc=$?
assert_rc "_wt_reverify_deletable: git status itself fails (not a repo) -> rc 1, fail CLOSED not clean (codex-1, HIMMEL-2208 pr-check panel)" 1 "$rc"

# ============================================================================
# Cadence pure / platform-detect suite — runs on EVERY platform.
# ============================================================================

echo "TEST: malformed --time rejected before the platform gate"
rc=0; out=$(env HOME="$HOME" "$REAL_BASH" "$CADENCE" arm --time 23:5 2>&1) || rc=$?
assert_rc "malformed --time -> rc 1 (all platforms)" 1 "$rc"

echo "TEST: --time with no value -> rc 1, not a raw bash shift error"
rc=0; out=$(env HOME="$HOME" "$REAL_BASH" "$CADENCE" arm --time 2>&1) || rc=$?
assert_rc "arm --time (missing value) -> rc 1" 1 "$rc"
assert_contains "arm --time (missing value) message" "--time requires a value" "$out"
assert_not_contains "not a raw bash shift error" "shift count" "$out"

echo "TEST: non-Windows platform refused Windows-only"
rc=0; out=$(env HOME="$HOME" OSTYPE=linux-gnu "$REAL_BASH" "$CADENCE" arm 2>&1) || rc=$?
assert_rc "POSIX platform -> rc 2" 2 "$rc"
assert_contains "POSIX platform message" "Windows-only" "$out"

echo "TEST: usage errors"
rc=0; out=$(env HOME="$HOME" "$REAL_BASH" "$CADENCE" 2>&1) || rc=$?
assert_rc "no subcommand -> rc 1" 1 "$rc"
rc=0; out=$(env HOME="$HOME" "$REAL_BASH" "$CADENCE" frobnicate 2>&1) || rc=$?
assert_rc "unknown subcommand -> rc 1" 1 "$rc"

echo "TEST: --time/--github-root/--documents-root/--force are arm-only -> rc 1 on status/disarm"
rc=0; out=$(env HOME="$HOME" "$REAL_BASH" "$CADENCE" status --time 09:00 2>&1) || rc=$?
assert_rc "status --time -> rc 1" 1 "$rc"
rc=0; out=$(env HOME="$HOME" "$REAL_BASH" "$CADENCE" disarm --github-root /tmp/x 2>&1) || rc=$?
assert_rc "disarm --github-root -> rc 1" 1 "$rc"
rc=0; out=$(env HOME="$HOME" "$REAL_BASH" "$CADENCE" status --force 2>&1) || rc=$?
assert_rc "status --force -> rc 1 (codex-4, HIMMEL-2115 pr-check round-9 panel)" 1 "$rc"
rc=0; out=$(env HOME="$HOME" "$REAL_BASH" "$CADENCE" disarm --force 2>&1) || rc=$?
assert_rc "disarm --force -> rc 1" 1 "$rc"
rc=0; out=$(env HOME="$HOME" "$REAL_BASH" "$CADENCE" status --wt-stale-days 7 2>&1) || rc=$?
assert_rc "status --wt-stale-days -> rc 1" 1 "$rc"

# ============================================================================
# schtasks + live-execution suite — Windows-only.
# ============================================================================

case "${OSTYPE:-$(uname -s 2>/dev/null || echo unknown)}" in
    msys*|cygwin*|win32*|MINGW*) : ;;
    *)
        echo "SKIP: schtasks + live-execution suite (Windows-only — needs cygpath/schtasks/cmd.exe)"
        summary
        ;;
esac

STATE="$TMP_ROOT/state"
mkdir -p "$STATE/tasks"

FAKE_SCHTASKS="$TMP_ROOT/schtasks-fake.sh"
cat >"$FAKE_SCHTASKS" <<FAKE
#!$REAL_BASH
STATE="$STATE"
FAKE
cat >>"$FAKE_SCHTASKS" <<'FAKE'
printf '%s\n' "$*" >> "$STATE/calls.log"
tn=""; mode=""; xmlpath=""
args=("$@")
i=0
while [ $i -lt ${#args[@]} ]; do
    case "${args[$i]}" in
        /create|/delete|/query) mode="${args[$i]}" ;;
        /tn) i=$((i+1)); tn="${args[$i]}" ;;
        /xml) i=$((i+1)); xmlpath="${args[$i]}" ;;
    esac
    i=$((i+1))
done
case "$mode" in
    /create)
        if [ -n "$xmlpath" ]; then
            xml_posix=$(cygpath -u "$xmlpath" 2>/dev/null || echo "$xmlpath")
            cat "$xml_posix" > "$STATE/tasks/$tn"
        else
            printf '%s\n' "$*" > "$STATE/tasks/$tn"
        fi
        echo "SUCCESS: The scheduled task \"$tn\" has successfully been created."
        ;;
    /delete)
        echo "$tn" >> "$STATE/deleted.log"
        if [ -f "$STATE/tasks/$tn" ]; then rm -f "$STATE/tasks/$tn"; fi
        echo "SUCCESS: The scheduled task \"$tn\" was successfully deleted."
        ;;
    /query)
        if [ -f "$STATE/tasks/$tn" ]; then
            printf 'TaskName:      \\%s\nNext Run Time: 7/10/2026 9:00:00 AM\n' "$tn"
            exit 0
        fi
        echo "ERROR: The system cannot find the file specified." >&2
        exit 1
        ;;
    *) exit 1 ;;
esac
FAKE
chmod +x "$FAKE_SCHTASKS"

FAKE_PWSH="$TMP_ROOT/bin/fake-pwsh.sh"
mkdir -p "$TMP_ROOT/bin"
cat >"$FAKE_PWSH" <<FAKE
#!$REAL_BASH
case "\$*" in
    *HKLM:*|*HKCU:*) echo "ABSENT"; exit 0 ;;
    *) echo "fake-pwsh: unrecognized probe command" >&2; exit 1 ;;
esac
FAKE
chmod +x "$FAKE_PWSH"

FAKE_WSCRIPT="$TMP_ROOT/wscript-fake.exe"
printf '#!/bin/sh\nexit 0\n' > "$FAKE_WSCRIPT"
chmod +x "$FAKE_WSCRIPT"
export CADENCE_WSCRIPT_BIN="$FAKE_WSCRIPT"
export CADENCE_WSH_POWERSHELL="$FAKE_PWSH"

CADENCE_BAT_DIR="$TMP_ROOT/bats"
OBS_REGISTRY="$STATE/observability.json"

REMOTE=$(mk_remote windows-arm)
CADENCE_GH_ROOT="$TMP_ROOT/cadence-github"; mkdir -p "$CADENCE_GH_ROOT"
CADENCE_DOCS_ROOT="$TMP_ROOT/cadence-docs"; mkdir -p "$CADENCE_DOCS_ROOT"

reset_state() {
    rm -rf "$STATE"
    mkdir -p "$STATE/tasks"
    rm -rf "$CADENCE_BAT_DIR"
}

run_rsc() {
    env RSC_SCHTASKS="$FAKE_SCHTASKS" RSC_BAT_DIR="$CADENCE_BAT_DIR" \
        RSC_HIMMEL_ROOT="$REPO_ROOT" HOME="$HOME" HIMMEL_OBSERVABILITY_CONFIG="$OBS_REGISTRY" \
        "$REAL_BASH" "$CADENCE" "$@"
}

echo "TEST: arm creates task via /create /tn ... /xml, emits runner .bat + vbs, registers observability"
reset_state
out=$(run_rsc arm --github-root "$CADENCE_GH_ROOT" --documents-root "$CADENCE_DOCS_ROOT")
assert_contains "arm banner" "REPO-SYNC CADENCE ARMED" "$out"
if [ -f "$STATE/tasks/HIMMEL-RepoSync" ]; then pass "task created under HIMMEL-RepoSync"; else fail "task created under HIMMEL-RepoSync"; fi
BAT="$CADENCE_BAT_DIR/repo-sync.bat"
VBS="$CADENCE_BAT_DIR/repo-sync.vbs"
if [ -f "$BAT" ]; then pass "runner .bat published"; else fail "runner .bat published"; fi
if [ -f "$VBS" ]; then pass "runner .vbs shim published"; else fail "runner .vbs shim published"; fi
bat_content=$(cat "$BAT" 2>/dev/null || echo "")
fmt_ver=$(grep -n 'CADENCE_RUNNER_FORMAT_VERSION=' "$REPO_ROOT/scripts/lib/cadence-format.sh" | head -1 | grep -o '[0-9]\+')
assert_contains "bat stamps the format version" "himmel-cadence-runner-format: $fmt_ver" "$bat_content"
assert_contains "bat is rc-preserving (propagates ERRORLEVEL, not exit /b 0)" 'exit /b %PAYLOAD_RC%' "$bat_content"
assert_contains "bat calls repo-sync-runner.sh" "repo-sync-runner.sh" "$bat_content"
assert_not_contains "bat does NOT itself call flow-run-ledger (the runner owns the ledger)" "flow-run-ledger.sh" "$bat_content"
if [ -f "$OBS_REGISTRY" ] && grep -q '"repo-sync"' "$OBS_REGISTRY" && grep -q 'HIMMEL-RepoSync' "$OBS_REGISTRY"; then
    pass "arm self-registers the repo-sync flow + HIMMEL-RepoSync task in the observability registry"
else
    fail "arm self-registers in the observability registry" "registry: $(cat "$OBS_REGISTRY" 2>/dev/null || echo MISSING)"
fi

echo "TEST: a nonexistent --github-root WARNs but still arms (a typo must not be silently swallowed)"
reset_state
MISSING_GH_ROOT="$TMP_ROOT/nonexistent-github-root"
rc=0
out=$(run_rsc arm --github-root "$MISSING_GH_ROOT" --documents-root "$CADENCE_DOCS_ROOT" 2>&1) || rc=$?
assert_rc "arm with missing --github-root still succeeds -> rc 0" 0 "$rc"
assert_contains "arm WARNs about the missing --github-root" "WARN repo-sync-cadence: --github-root is not a directory" "$out"

echo "TEST: --dry-run makes no schtasks /create or /delete calls, publishes nothing"
reset_state
out=$(run_rsc arm --github-root "$CADENCE_GH_ROOT" --documents-root "$CADENCE_DOCS_ROOT" --dry-run)
assert_contains "dry-run banner" "dry-run complete" "$out"
if [ -f "$STATE/calls.log" ] && grep -qE '/(create|delete)\b' "$STATE/calls.log"; then
    fail "dry-run made no schtasks /create or /delete calls"
else
    pass "dry-run made no schtasks /create or /delete calls"
fi
if [ -f "$BAT" ]; then fail "dry-run published no .bat"; else pass "dry-run published no .bat"; fi

echo "TEST: dedup guard refuses a second arm without --force; --force replaces"
reset_state
run_rsc arm --github-root "$CADENCE_GH_ROOT" --documents-root "$CADENCE_DOCS_ROOT" >/dev/null
rc=0; out=$(run_rsc arm --github-root "$CADENCE_GH_ROOT" --documents-root "$CADENCE_DOCS_ROOT" 2>&1) || rc=$?
assert_rc "second arm without --force -> rc 3" 3 "$rc"
rc=0; out=$(run_rsc arm --github-root "$CADENCE_GH_ROOT" --documents-root "$CADENCE_DOCS_ROOT" --force 2>&1) || rc=$?
assert_rc "arm --force -> rc 0" 0 "$rc"

echo "TEST: arm --force restores the prior .bat/.vbs when schtasks /create fails after publish (codex-2, HIMMEL-2115 pr-check round-7 panel)"
reset_state
run_rsc arm --github-root "$CADENCE_GH_ROOT" --documents-root "$CADENCE_DOCS_ROOT" >/dev/null
bat_before=$(cat "$BAT" 2>/dev/null || echo "")
vbs_before=$(cat "$VBS" 2>/dev/null || echo "")
FAKE_SCHTASKS_FAIL="$TMP_ROOT/schtasks-fake-fail.sh"
cat >"$FAKE_SCHTASKS_FAIL" <<FAKE
#!$REAL_BASH
case "\$*" in
    *"/create"*) echo "ERROR: simulated schtasks /create failure" >&2; exit 1 ;;
    *) exec "$FAKE_SCHTASKS" "\$@" ;;
esac
FAKE
chmod +x "$FAKE_SCHTASKS_FAIL"
# A DIFFERENT --documents-root than the first arm call, so the new (would-be)
# .bat content genuinely differs from the pre-failure content — otherwise the
# "restored" assertion below would pass even without the fix, since a
# byte-identical re-publish looks the same either way.
DOCS_ROOT2="$TMP_ROOT/cadence-docs-2"; mkdir -p "$DOCS_ROOT2"
rc=0
out=$(env RSC_SCHTASKS="$FAKE_SCHTASKS_FAIL" RSC_BAT_DIR="$CADENCE_BAT_DIR" \
    RSC_HIMMEL_ROOT="$REPO_ROOT" HOME="$HOME" HIMMEL_OBSERVABILITY_CONFIG="$OBS_REGISTRY" \
    "$REAL_BASH" "$CADENCE" arm --github-root "$CADENCE_GH_ROOT" --documents-root "$DOCS_ROOT2" --force 2>&1) || rc=$?
assert_rc "arm --force with failing schtasks /create -> rc 4" 4 "$rc"
assert_contains "failure message mentions restore" "restored the prior" "$out"
bat_after=$(cat "$BAT" 2>/dev/null || echo "")
vbs_after=$(cat "$VBS" 2>/dev/null || echo "")
if [ "$bat_after" = "$bat_before" ]; then pass "bat restored to pre-failure content"; else fail "bat restored to pre-failure content" "content changed despite reported failure"; fi
if [ "$vbs_after" = "$vbs_before" ]; then pass "vbs restored to pre-failure content"; else fail "vbs restored to pre-failure content" "content changed despite reported failure"; fi

echo "TEST: arm --force restores the prior .vbs too when only the .bat publish (not the schtasks call) fails, after .vbs already published (codex-3, HIMMEL-2115 pr-check round-8 panel)"
reset_state
run_rsc arm --github-root "$CADENCE_GH_ROOT" --documents-root "$CADENCE_DOCS_ROOT" >/dev/null
bat_before2=$(cat "$BAT" 2>/dev/null || echo "")
vbs_before2=$(cat "$VBS" 2>/dev/null || echo "")
REAL_MV_BIN="$(command -v mv)"
FAKE_MV_DIR="$TMP_ROOT/fakemv-batpublish"
mkdir -p "$FAKE_MV_DIR"
cat >"$FAKE_MV_DIR/mv" <<FAKE
#!$REAL_BASH
REAL_MV="$REAL_MV_BIN"
FAKE
cat >>"$FAKE_MV_DIR/mv" <<'FAKE'
case "$*" in
    *repo-sync.bat*)
        echo "fake mv: simulated .bat publish failure" >&2
        exit 1
        ;;
    *) exec "$REAL_MV" "$@" ;;
esac
FAKE
chmod +x "$FAKE_MV_DIR/mv"
FAKE_MV_DIR_POSIX="$FAKE_MV_DIR"
if command -v cygpath >/dev/null 2>&1; then FAKE_MV_DIR_POSIX=$(cygpath -u "$FAKE_MV_DIR"); fi
DOCS_ROOT4="$TMP_ROOT/cadence-docs-4"; mkdir -p "$DOCS_ROOT4"
rc=0
out=$(env PATH="$FAKE_MV_DIR_POSIX:$PATH" RSC_SCHTASKS="$FAKE_SCHTASKS" RSC_BAT_DIR="$CADENCE_BAT_DIR" \
    RSC_HIMMEL_ROOT="$REPO_ROOT" HOME="$HOME" HIMMEL_OBSERVABILITY_CONFIG="$OBS_REGISTRY" \
    "$REAL_BASH" "$CADENCE" arm --github-root "$CADENCE_GH_ROOT" --documents-root "$DOCS_ROOT4" --force 2>&1) || rc=$?
assert_rc "arm --force with failing .bat publish -> rc 4" 4 "$rc"
assert_contains "failure message mentions publish failure" "failed to publish runner to" "$out"
bat_after2=$(cat "$BAT" 2>/dev/null || echo "")
vbs_after2=$(cat "$VBS" 2>/dev/null || echo "")
if [ "$bat_after2" = "$bat_before2" ]; then pass "bat unchanged (its own mv failed)"; else fail "bat unchanged (its own mv failed)"; fi
if [ "$vbs_after2" = "$vbs_before2" ]; then pass "vbs restored to pre-failure content (not left on new content)"; else fail "vbs restored to pre-failure content (not left on new content)" "vbs was left on the new, never-registered content"; fi

echo "TEST: status reports armed + disarm removes the task, runner files, and observability registration"
reset_state
run_rsc arm --github-root "$CADENCE_GH_ROOT" --documents-root "$CADENCE_DOCS_ROOT" >/dev/null
out=$(run_rsc status)
assert_contains "status shows ARMED" "ARMED" "$out"
out=$(run_rsc disarm)
assert_contains "disarm confirms" "cadence disarmed" "$out"
if [ -f "$STATE/tasks/HIMMEL-RepoSync" ]; then fail "disarm removed the task"; else pass "disarm removed the task"; fi
if [ -f "$BAT" ] || [ -f "$VBS" ]; then fail "disarm removed the runner files"; else pass "disarm removed the runner files"; fi
if grep -q '"repo-sync"' "$OBS_REGISTRY" 2>/dev/null; then
    fail "disarm unregisters the repo-sync flow" "registry still carries it: $(cat "$OBS_REGISTRY")"
else
    pass "disarm unregisters the repo-sync flow"
fi
out=$(run_rsc disarm)
assert_contains "disarm is idempotent" "nothing armed" "$out"

echo "TEST: live execution — the generated .bat actually runs repo-sync-runner.sh against real fixtures"
reset_state
LIVE_GH="$TMP_ROOT/live-github"; mkdir -p "$LIVE_GH"
LIVE_DOCS="$TMP_ROOT/live-docs"; mkdir -p "$LIVE_DOCS"
REMOTE=$(mk_remote live)
git clone -q "$REMOTE" "$LIVE_DOCS/clean-repo" >/dev/null 2>&1
advance_remote "$REMOTE"
run_rsc arm --github-root "$LIVE_GH" --documents-root "$LIVE_DOCS" >/dev/null
rc=0
env HOME="$HOME" HIMMEL_FLOW_RUNS_LEDGER="$STATE/live-ledger.jsonl" "$BAT" >/dev/null 2>&1 || rc=$?
assert_rc "live .bat run -> rc 0 (one repo, cleanly pulled)" 0 "$rc"
if grep -q "advance-" "$LIVE_DOCS/clean-repo/README.md"; then
    pass "live .bat run actually fast-forwarded the fixture repo"
else
    fail "live .bat run actually fast-forwarded the fixture repo"
fi
log_content=$(cat "$CADENCE_BAT_DIR/repo-sync.log" 2>/dev/null || echo "")
assert_contains "live run log stamps the rc" "repo-sync exit rc=0" "$log_content"

summary
