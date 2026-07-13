#!/usr/bin/env bash
# Hermetic test for clean-garden's de-registered worktree husk sweep
# (HIMMEL-970). Temp git repos + direct .claude/worktrees children.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEAN_GARDEN="$SCRIPT_DIR/clean-garden.sh"

PASS=0
FAIL=0
TMP_ROOT=""
TMP_ROOT_UNIX=""

# shellcheck disable=SC2317,SC2329  # invoked indirectly via `trap cleanup EXIT`
cleanup() {
    if [ -n "$TMP_ROOT_UNIX" ] && [ -d "$TMP_ROOT_UNIX" ]; then
        rm -rf "$TMP_ROOT_UNIX" 2>/dev/null || true
    fi
}
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }

TMP_ROOT=$(mktemp -d)
TMP_ROOT_UNIX="$TMP_ROOT"
if command -v cygpath >/dev/null 2>&1; then
    TMP_ROOT=$(cygpath -m "$TMP_ROOT")
fi

make_repo() {
    local name="$1" repo
    repo="$TMP_ROOT/$name"
    git init -q --initial-branch=main "$repo" 2>/dev/null || {
        git init -q "$repo"
        git -C "$repo" symbolic-ref HEAD refs/heads/main || true
    }
    git -C "$repo" config user.email t@test.com
    git -C "$repo" config user.name t
    printf 'base\n' > "$repo/README"
    git -C "$repo" add README
    git -C "$repo" commit -q -m "base"
    git -C "$repo" branch -m main 2>/dev/null || true
    printf '%s\n' "$repo"
}

# Age a husk RECURSIVELY: the sweep's freshness gate treats ANY entry modified
# in the last 24h as in-flight, so fixtures must age the dir and its contents.
touch_old() {
    local entry
    while IFS= read -r entry; do
        touch -d '2 days ago' "$entry" 2>/dev/null || touch -t 202001010000 "$entry"
    done < <(find "$1" -print 2>/dev/null)
}

run_clean() {
    local repo="$1"; shift
    (
        cd "$repo" || exit 1
        bash "$CLEAN_GARDEN" --prune-only "$@" 2>&1
    )
}

echo "RUN A: old de-registered husk is swept"
REPO_A=$(make_repo repo-a)
HUSK_A="$REPO_A/.claude/worktrees/feat+old-husk"
mkdir -p "$HUSK_A"
printf 'stray\n' > "$HUSK_A/file.txt"
touch_old "$HUSK_A"
out_a=$(run_clean "$REPO_A") || fail "run_clean exited nonzero (repo-a)" "$out_a"
if [ ! -d "$HUSK_A" ]; then
    pass "old husk swept"
else
    fail "old husk still exists" "$out_a"
fi
case "$out_a" in
    *"clean-garden: stray-sweep — 1 swept, 0 failed ("*" reclaimed)"*) pass "old husk summary counts sweep and size" ;;
    *) fail "expected stray-sweep summary for old husk" "$out_a" ;;
esac

echo "RUN B: fresh de-registered husk is skipped"
REPO_B=$(make_repo repo-b)
HUSK_B="$REPO_B/.claude/worktrees/feat+fresh-husk"
mkdir -p "$HUSK_B"
printf 'fresh\n' > "$HUSK_B/file.txt"
out_b=$(run_clean "$REPO_B") || fail "run_clean exited nonzero (repo-b)" "$out_b"
if [ -d "$HUSK_B" ]; then
    pass "fresh husk kept"
else
    fail "fresh husk was swept" "$out_b"
fi
case "$out_b" in
    *"stray-sweep"*) fail "fresh-only run printed stray-sweep summary" "$out_b" ;;
    *) pass "fresh-only run stays quiet" ;;
esac

echo "RUN C: registered worktree under .claude/worktrees is never swept"
REPO_C=$(make_repo repo-c)
mkdir -p "$REPO_C/.claude/worktrees"
WT_C="$REPO_C/.claude/worktrees/feat+registered"
git -C "$REPO_C" worktree add -q "$WT_C" -b feat/registered >/dev/null 2>&1
touch_old "$WT_C"
out_c=$(run_clean "$REPO_C") || fail "run_clean exited nonzero (repo-c)" "$out_c"
if [ -d "$WT_C" ] && git -C "$REPO_C" worktree list --porcelain | grep -Fq "worktree $WT_C"; then
    pass "registered worktree kept"
else
    fail "registered worktree was swept or de-registered" "$out_c"
fi
case "$out_c" in
    *"stray-sweep"*) fail "registered-only run printed stray-sweep summary" "$out_c" ;;
    *) pass "registered-only run stays quiet" ;;
esac

echo "RUN D: dry-run reports would-sweep and removes nothing"
REPO_D=$(make_repo repo-d)
HUSK_D="$REPO_D/.claude/worktrees/feat+dry-husk"
mkdir -p "$HUSK_D"
printf 'dry\n' > "$HUSK_D/file.txt"
touch_old "$HUSK_D"
out_d=$(run_clean "$REPO_D" --dry-run) || fail "run_clean exited nonzero (repo-d)" "$out_d"
# Match by dir basename, not the full $HUSK_D: on Windows the harness path is
# cygpath-mixed (C:/...) while clean-garden prints the POSIX form (/tmp/...).
case "$out_d" in
    *"DRY clean-garden: would sweep stray husk "*"/feat+dry-husk"*) pass "dry-run reports would-sweep" ;;
    *) fail "dry-run did not report would-sweep" "$out_d" ;;
esac
if [ -d "$HUSK_D" ]; then
    pass "dry-run removes nothing"
else
    fail "dry-run removed husk" "$out_d"
fi
case "$out_d" in
    *"clean-garden: stray-sweep — 1 swept, 0 failed ("*" reclaimed)"*) pass "dry-run summary counts would-sweep" ;;
    *) fail "dry-run summary missing" "$out_d" ;;
esac

echo "RUN E: no husks stays quiet"
REPO_E=$(make_repo repo-e)
out_e=$(run_clean "$REPO_E") || fail "run_clean exited nonzero (repo-e)" "$out_e"
case "$out_e" in
    *"stray-sweep"*) fail "no-husk run printed stray-sweep summary" "$out_e" ;;
    *) pass "no-husk run has no stray-sweep summary" ;;
esac

echo "RUN F: old husk dir with a FRESH nested file is skipped (in-flight)"
REPO_F=$(make_repo repo-f)
HUSK_F="$REPO_F/.claude/worktrees/feat+deep-fresh"
mkdir -p "$HUSK_F/nested"
printf 'old\n' > "$HUSK_F/old.txt"
touch_old "$HUSK_F"
printf 'live\n' > "$HUSK_F/nested/live.txt"   # fresh nested write, top dir aged below
touch -d '2 days ago' "$HUSK_F" 2>/dev/null || touch -t 202001010000 "$HUSK_F"
out_f=$(run_clean "$REPO_F") || fail "run_clean exited nonzero (repo-f)" "$out_f"
if [ -d "$HUSK_F" ]; then
    pass "old-dir/fresh-content husk kept"
else
    fail "old-dir/fresh-content husk was swept (freshness gate not recursive)" "$out_f"
fi

echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
