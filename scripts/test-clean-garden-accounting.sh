#!/usr/bin/env bash
# Hermetic coverage for clean-garden full accounting (HIMMEL-1410): every kept
# worktree gets a what+why row, squash-merged tips are compared to the recorded
# PR head, and remote-only branches are classified from one cached PR listing.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEAN_GARDEN="$SCRIPT_DIR/clean-garden.sh"

PASS=0
FAIL=0
TMP_ROOT=""

# shellcheck disable=SC2317,SC2329  # invoked indirectly by the EXIT trap
cleanup() {
    if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
        rm -rf "$TMP_ROOT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/himmel-clean-accounting.XXXXXX")
TMP_ROOT_UNIX="$TMP_ROOT"
if command -v cygpath >/dev/null 2>&1; then
    TMP_ROOT=$(cygpath -m "$TMP_ROOT")
fi
REPO="$TMP_ROOT/repo"
git init -q --initial-branch=main "$REPO" 2>/dev/null || {
    git init -q "$REPO"
    git -C "$REPO" symbolic-ref HEAD refs/heads/main || true
}
git -C "$REPO" config user.email t@test.com
git -C "$REPO" config user.name t
printf 'base\n' > "$REPO/README"
git -C "$REPO" add README
git -C "$REPO" commit -q -m "base"
git -C "$REPO" branch -m main 2>/dev/null || true
git -C "$REPO" remote add origin https://github.com/owner/repo.git
git -C "$REPO" remote add puborigin https://github.com/public/repo.git
MAIN_SHA=$(git -C "$REPO" rev-parse main)
git -C "$REPO" update-ref refs/remotes/origin/main "$MAIN_SHA"
git -C "$REPO" update-ref refs/remotes/puborigin/main "$MAIN_SHA"

mk_wt_commit() {
    local name="$1" branch="$2" wt
    wt="$TMP_ROOT/$name"
    git -C "$REPO" worktree add -q "$wt" -b "$branch" >/dev/null 2>&1
    printf '%s\n' "$branch" > "$wt/${name}.txt"
    git -C "$wt" add "${name}.txt"
    git -C "$wt" commit -q -m "$branch"
    printf '%s\n' "$wt"
}

WT_OPEN=$(mk_wt_commit wt-open feat/open)
OPEN_SHA=$(git -C "$WT_OPEN" rev-parse HEAD)
WT_MERGED=$(mk_wt_commit wt-merged feat/merged-clean)
MERGED_SHA=$(git -C "$WT_MERGED" rev-parse HEAD)
WT_POST=$(mk_wt_commit wt-post feat/post-merge)
POST_MERGED_SHA=$(git -C "$WT_POST" rev-parse HEAD)
printf 'after merge\n' >> "$WT_POST/wt-post.txt"
git -C "$WT_POST" commit -q -am "post merge work"
WT_PARKED=$(mk_wt_commit wt-parked feat/parked)
PARKED_SHA=$(git -C "$WT_PARKED" rev-parse HEAD)
printf 'untracked work\n' > "$WT_PARKED/notes.txt"
mk_wt_commit wt-none feat/no-pr >/dev/null
WT_DETACHED="$TMP_ROOT/wt-detached"
git -C "$REPO" worktree add -q --detach "$WT_DETACHED" main >/dev/null 2>&1
printf 'detached work\n' > "$WT_DETACHED/detached.txt"
git -C "$WT_DETACHED" add detached.txt
git -C "$WT_DETACHED" commit -q -m "detached work"
DETACHED_SHA=$(git -C "$WT_DETACHED" rev-parse HEAD)

# Remote-only tips. commit-tree avoids creating local branches/worktrees for
# these fixtures while still producing real commits for merge-base checks.
TREE=$(git -C "$REPO" rev-parse "main^{tree}")
REMOTE_MERGED=$(printf 'remote merged\n' | git -C "$REPO" commit-tree "$TREE" -p "$MAIN_SHA")
REMOTE_OLD=$(printf 'remote old\n' | git -C "$REPO" commit-tree "$TREE" -p "$MAIN_SHA")
REMOTE_NEW=$(printf 'remote new\n' | git -C "$REPO" commit-tree "$TREE" -p "$REMOTE_OLD")
REMOTE_CLOSED=$(printf 'remote closed\n' | git -C "$REPO" commit-tree "$TREE" -p "$MAIN_SHA")
REMOTE_NONE=$(printf 'remote none\n' | git -C "$REPO" commit-tree "$TREE" -p "$MAIN_SHA")
REMOTE_OPEN=$(printf 'remote open\n' | git -C "$REPO" commit-tree "$TREE" -p "$MAIN_SHA")
REMOTE_PUBLIC=$(printf 'remote public\n' | git -C "$REPO" commit-tree "$TREE" -p "$MAIN_SHA")
git -C "$REPO" update-ref refs/remotes/origin/chore/merged-clean "$REMOTE_MERGED"
git -C "$REPO" update-ref refs/remotes/origin/chore/post-merge "$REMOTE_NEW"
git -C "$REPO" update-ref refs/remotes/origin/chore/closed "$REMOTE_CLOSED"
git -C "$REPO" update-ref refs/remotes/origin/chore/no-pr "$REMOTE_NONE"
git -C "$REPO" update-ref refs/remotes/origin/chore/open "$REMOTE_OPEN"
git -C "$REPO" update-ref refs/remotes/puborigin/chore/public-no-pr "$REMOTE_PUBLIC"

GH_ROWS_ORIGIN="$TMP_ROOT_UNIX/origin.tsv"
GH_ROWS_PUBLIC="$TMP_ROOT_UNIX/public.tsv"
GH_CALLS="$TMP_ROOT_UNIX/gh-calls"
{
    printf 'owner/repo\tfeat/open\topen\t%s\n' "$OPEN_SHA"
    printf 'owner/repo\tfeat/merged-clean\tmerged\t%s\n' "$MERGED_SHA"
    printf 'owner/repo\tfeat/post-merge\tmerged\t%s\n' "$POST_MERGED_SHA"
    printf 'owner/repo\tfeat/parked\tmerged\t%s\n' "$PARKED_SHA"
    printf 'owner/repo\tchore/merged-clean\tmerged\t%s\n' "$REMOTE_MERGED"
    printf 'owner/repo\tchore/post-merge\tmerged\t%s\n' "$REMOTE_OLD"
    printf 'owner/repo\tchore/closed\tclosed\t%s\n' "$REMOTE_CLOSED"
    printf 'owner/repo\tchore/open\topen\t%s\n' "$REMOTE_OPEN"
} > "$GH_ROWS_ORIGIN"
: > "$GH_ROWS_PUBLIC"
: > "$GH_CALLS"

STUB_DIR="$TMP_ROOT_UNIX/bin"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
args="$*"
if echo "$args" | grep -q "auth status"; then exit 0; fi
if echo "$args" | grep -q "repo view"; then echo "owner/repo"; exit 0; fi
if echo "$args" | grep -q "api --paginate repos/owner/repo/pulls"; then
    printf 'origin\n' >> "$GH_CALLS"
    cat "$GH_ROWS_ORIGIN"
    exit 0
fi
if echo "$args" | grep -q "api --paginate repos/public/repo/pulls"; then
    printf 'puborigin\n' >> "$GH_CALLS"
    cat "$GH_ROWS_PUBLIC"
    exit 0
fi
if echo "$args" | grep -q -- "--state open"; then exit 0; fi
exit 0
STUB
chmod +x "$STUB_DIR/gh"

run_clean() {
    (
        export PATH="${STUB_DIR}:${PATH}"
        export GH_ROWS_ORIGIN GH_ROWS_PUBLIC GH_CALLS
        cd "$REPO" || exit 1
        bash "$CLEAN_GARDEN" --prune-only "$@" 2>&1
    )
}

assert_line() {
    local name="$1" output="$2" first="$3" second="${4:-}"
    if printf '%s\n' "$output" | grep -F "$first" | grep -Fq "$second"; then
        pass "$name"
    else
        fail "$name" "$output"
    fi
}

echo "RUN A: origin accounting"
out=$(run_clean)

if [ ! -d "$WT_MERGED" ]; then
    pass "exact merged PR head is pruned"
else
    fail "exact merged PR head was kept" "$out"
fi
if [ -d "$WT_POST" ]; then
    pass "post-merge branch tip is kept"
else
    fail "post-merge branch tip was wrongly pruned" "$out"
fi

assert_line "open worktree is ACTIVE" "$out" "branch=feat/open pr=open" "verdict=ACTIVE"
assert_line "post-merge worktree is UNKNOWN" "$out" "branch=feat/post-merge pr=merged" "verdict=UNKNOWN"
assert_line "post-merge why names tip mismatch" "$out" "branch=feat/post-merge" "why=branch tip differs from merged PR head"
assert_line "dirty merged worktree is PARKED-WIP" "$out" "branch=feat/parked pr=merged" "untracked=1"
assert_line "dirty merged worktree verdict" "$out" "branch=feat/parked pr=merged" "verdict=PARKED-WIP"
assert_line "no-PR worktree is explicit UNKNOWN" "$out" "branch=feat/no-pr pr=none" "verdict=UNKNOWN"
assert_line "detached worktree is accounted" "$out" "branch=(detached:${DETACHED_SHA:0:12})" "verdict=UNKNOWN"

keep_count=$(printf '%s\n' "$out" | grep -c '^KEEP clean-garden:')
if [ "$keep_count" -eq 6 ]; then
    pass "every one of 6 kept worktrees has one accounting row"
else
    fail "expected 6 kept-worktree rows, got $keep_count" "$out"
fi

assert_line "remote merged head is MERGED-CLEAN" "$out" "remote=origin branch=chore/merged-clean" "category=MERGED-CLEAN"
assert_line "remote post-merge tip is TIP-DIFFERS" "$out" "remote=origin branch=chore/post-merge" "category=TIP-DIFFERS"
assert_line "remote closed PR is CLOSED-UNMERGED" "$out" "remote=origin branch=chore/closed" "category=CLOSED-UNMERGED"
assert_line "remote branch without PR is NO-PR" "$out" "remote=origin branch=chore/no-pr" "category=NO-PR"
if printf '%s\n' "$out" | grep -Fq "remote=origin branch=chore/open"; then
    fail "open-PR remote branch should not be an orphan row" "$out"
else
    pass "open-PR remote branch is excluded from orphan rows"
fi
assert_line "loud summary counts risk classes" "$out" "ALERT clean-garden: attention required" "TIP-DIFFERS, 1 NO-PR"

origin_calls=$(grep -c '^origin$' "$GH_CALLS")
if [ "$origin_calls" -eq 1 ]; then
    pass "origin PRs fetched once for the whole run"
else
    fail "expected one origin PR API call, got $origin_calls" "$out"
fi
if printf '%s\n' "$out" | grep -Fq "remote=puborigin"; then
    fail "puborigin was reported without the opt-in flag" "$out"
else
    pass "puborigin is disabled by default"
fi

echo "RUN B: puborigin opt-in"
pub_out=$(run_clean --include-puborigin)
assert_line "puborigin opt-in reports remote orphan" "$pub_out" "remote=puborigin branch=chore/public-no-pr" "category=NO-PR"
pub_calls=$(grep -c '^puborigin$' "$GH_CALLS")
if [ "$pub_calls" -eq 1 ]; then
    pass "puborigin PRs fetched once when requested"
else
    fail "expected one puborigin PR API call, got $pub_calls" "$pub_out"
fi

echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
