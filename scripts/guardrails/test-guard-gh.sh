#!/usr/bin/env bash
# Smoke test for scripts/guardrails/guard-gh.sh.
# Builds throwaway repos, invokes the dispatcher with verb+state+flags,
# asserts rc and stderr signal-words.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
GUARD="$REPO_ROOT/scripts/guardrails/guard-gh.sh"

if [ ! -f "$GUARD" ]; then
    echo "FAIL: $GUARD not found"
    exit 1
fi

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

setup_repo() {
    # $1 = branch
    local dir
    dir="$(mktemp -d)"
    git -C "$dir" init -q -b main
    git -C "$dir" config user.email t@t
    git -C "$dir" config user.name t
    git -C "$dir" commit --allow-empty -q -m "init"
    if [ "$1" != "main" ]; then
        git -C "$dir" checkout -q -b "$1"
    fi
    printf '%s' "$dir"
}

run_in() {
    # $1 = dir; rest = args to guard
    local dir="$1"; shift
    (cd "$dir" && bash "$GUARD" "$@") 2>&1
    return $?
}

echo "== pr-create on main → refuse rc=2 =="
d=$(setup_repo main)
out=$(run_in "$d" pr-create); rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qi "refus.*main"; then
    pass "main refused"
else
    fail "expected rc=2 + 'refus*main' got rc=$rc out=$out"
fi
rm -rf "$d"

echo "== pr-create on clean feat → proceed rc=0 =="
d=$(setup_repo feat/x)
git -C "$d" commit --allow-empty -q -m "feat"
out=$(run_in "$d" pr-create); rc=$?
if [ "$rc" -eq 0 ]; then pass "clean feat proceed"; else fail "expected rc=0 got rc=$rc out=$out"; fi
rm -rf "$d"

echo "== pr-create on dirty feat → warn rc=1 =="
d=$(setup_repo feat/x)
git -C "$d" commit --allow-empty -q -m "feat"
echo dirty > "$d/file.txt"
out=$(run_in "$d" pr-create); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qi "dirty"; then pass "dirty warns"; else fail "expected rc=1 + dirty got rc=$rc out=$out"; fi
rm -rf "$d"

echo "== pr-create on dirty feat with --allow-dirty → proceed rc=0 =="
d=$(setup_repo feat/x)
git -C "$d" commit --allow-empty -q -m "feat"
echo dirty > "$d/file.txt"
out=$(run_in "$d" pr-create --allow-dirty); rc=$?
if [ "$rc" -eq 0 ]; then pass "--allow-dirty proceeds"; else fail "expected rc=0 got rc=$rc out=$out"; fi
rm -rf "$d"

echo "== pr-create on merged branch → refuse rc=2 =="
d=$(setup_repo feat/x)
git -C "$d" commit --allow-empty -q -m "feat"
git -C "$d" checkout -q main
git -C "$d" merge --no-ff -q feat/x -m "merge"
git -C "$d" checkout -q feat/x
out=$(run_in "$d" pr-create); rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qi "merg"; then pass "merged refused"; else fail "expected rc=2 + 'merg' got rc=$rc out=$out"; fi
rm -rf "$d"

echo "== pr-create on merged branch with --allow-merged-base → proceed rc=0 =="
d=$(setup_repo feat/x)
git -C "$d" commit --allow-empty -q -m "feat"
git -C "$d" checkout -q main
git -C "$d" merge --no-ff -q feat/x -m "merge"
git -C "$d" checkout -q feat/x
out=$(run_in "$d" pr-create --allow-merged-base); rc=$?
if [ "$rc" -eq 0 ]; then pass "--allow-merged-base proceeds"; else fail "expected rc=0 got rc=$rc out=$out"; fi
rm -rf "$d"

echo "== pr-merge --admin → refuse rc=2 =="
d=$(setup_repo feat/x)
out=$(run_in "$d" pr-merge --admin 99); rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qi "admin"; then pass "admin refused"; else fail "expected rc=2 + 'admin' got rc=$rc out=$out"; fi
rm -rf "$d"

echo "== pr-merge --admin with GH_ADMIN_MERGE_OK=1 → proceed rc=0 =="
d=$(setup_repo feat/x)
out=$(cd "$d" && GH_ADMIN_MERGE_OK=1 bash "$GUARD" pr-merge --admin 99 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "GH_ADMIN_MERGE_OK bypasses"; else fail "expected rc=0 got rc=$rc out=$out"; fi
rm -rf "$d"

echo "== pr-merge without --admin → proceed rc=0 =="
d=$(setup_repo feat/x)
out=$(run_in "$d" pr-merge 99 --squash); rc=$?
if [ "$rc" -eq 0 ]; then pass "non-admin merge proceeds"; else fail "expected rc=0 got rc=$rc out=$out"; fi
rm -rf "$d"

echo "== unknown verb → rc=2 with stderr =="
d=$(setup_repo feat/x)
out=$(run_in "$d" pr-bogus); rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qi "unknown"; then pass "unknown verb rejected"; else fail "expected rc=2 + unknown got rc=$rc out=$out"; fi
rm -rf "$d"

echo "== pr-create --allow-dirty --title foo → cleaned argv excludes --allow-dirty =="
d=$(setup_repo feat/x)
git -C "$d" commit --allow-empty -q -m "feat"
echo dirty > "$d/file.txt"
out=$(cd "$d" && bash "$GUARD" pr-create --allow-dirty --title foo 2>/dev/null); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^--title$' && printf '%s' "$out" | grep -q '^foo$' && ! printf '%s' "$out" | grep -q '^--allow-dirty$'; then
    pass "cleaned argv on stdout"
else
    fail "expected stdout to have --title + foo but no --allow-dirty; got rc=$rc out=$out"
fi
rm -rf "$d"

echo "== pr-create --allow-merged-base --title foo → cleaned argv excludes --allow-merged-base =="
d=$(setup_repo feat/x)
git -C "$d" commit --allow-empty -q -m "feat"
git -C "$d" checkout -q main
git -C "$d" merge --no-ff -q feat/x -m "merge"
git -C "$d" checkout -q feat/x
out=$(cd "$d" && bash "$GUARD" pr-create --allow-merged-base --title foo 2>/dev/null); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^--title$' && ! printf '%s' "$out" | grep -q '^--allow-merged-base$'; then
    pass "--allow-merged-base stripped"
else
    fail "expected --title in stdout, no --allow-merged-base; got rc=$rc out=$out"
fi
rm -rf "$d"

echo "== pr-create rc=1 warn path → cleaned argv still on stdout =="
d=$(setup_repo feat/x)
git -C "$d" commit --allow-empty -q -m "feat"
echo dirty > "$d/file.txt"
stdout=$(cd "$d" && bash "$GUARD" pr-create --title foo 2>/dev/null); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$stdout" | grep -q '^--title$' && printf '%s' "$stdout" | grep -q '^foo$'; then
    pass "rc=1 emits forward argv"
else
    fail "expected rc=1 + --title/foo in stdout; got rc=$rc stdout=$stdout"
fi
rm -rf "$d"

echo "== pr-create refusal ordering: merged+dirty → refuse with merged message =="
d=$(setup_repo feat/x)
git -C "$d" commit --allow-empty -q -m "feat"
git -C "$d" checkout -q main
git -C "$d" merge --no-ff -q feat/x -m "merge"
git -C "$d" checkout -q feat/x
echo dirty > "$d/file.txt"
out=$(run_in "$d" pr-create); rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qi "merg" && ! printf '%s' "$out" | grep -qi "warn"; then
    pass "merged precedes dirty"
else
    fail "expected rc=2 + 'merg' (not WARN); got rc=$rc out=$out"
fi
rm -rf "$d"

echo "== pr-push behind origin/main → warn rc=1 =="
origin=$(mktemp -d); git -C "$origin" init -q --bare -b main
work=$(mktemp -d); git clone -q "$origin" "$work"
git -C "$work" config user.email t@t; git -C "$work" config user.name t
git -C "$work" commit --allow-empty -q -m "base"
git -C "$work" push -q origin main
git -C "$work" checkout -q -b feat/z
git -C "$work" checkout -q main
git -C "$work" commit --allow-empty -q -m "advance"
git -C "$work" push -q origin main
git -C "$work" checkout -q feat/z
git -C "$work" fetch -q origin
out=$(run_in "$work" pr-push); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qi "behind"; then
    pass "behind warns"
else
    fail "expected rc=1 + 'behind' got rc=$rc out=$out"
fi
# --allow-stale bypass
out=$(run_in "$work" pr-push --allow-stale); rc=$?
if [ "$rc" -eq 0 ]; then pass "--allow-stale proceeds"; else fail "expected rc=0 got rc=$rc"; fi
# --allow-stale stripped from cleaned argv
stdout=$(cd "$work" && bash "$GUARD" pr-push --allow-stale --foo bar 2>/dev/null); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$stdout" | grep -q '^--foo$' && ! printf '%s' "$stdout" | grep -q '^--allow-stale$'; then
    pass "--allow-stale stripped"
else
    fail "expected --foo in stdout, no --allow-stale; got rc=$rc stdout=$stdout"
fi
rm -rf "$work" "$origin"

echo "== pr-push up-to-date → rc=0 =="
origin=$(mktemp -d); git -C "$origin" init -q --bare -b main
work=$(mktemp -d); git clone -q "$origin" "$work"
git -C "$work" config user.email t@t; git -C "$work" config user.name t
git -C "$work" commit --allow-empty -q -m "base"
git -C "$work" push -q origin main
git -C "$work" checkout -q -b feat/z
out=$(run_in "$work" pr-push); rc=$?
if [ "$rc" -eq 0 ]; then pass "up-to-date proceeds"; else fail "expected rc=0 got rc=$rc out=$out"; fi
rm -rf "$work" "$origin"

echo "== pr-merge --admin (allowed) → cleaned argv keeps --admin =="
d=$(setup_repo feat/x)
stdout=$(cd "$d" && GH_ADMIN_MERGE_OK=1 bash "$GUARD" pr-merge --admin 99 --squash 2>/dev/null); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$stdout" | grep -q '^--admin$' && printf '%s' "$stdout" | grep -q '^99$' && printf '%s' "$stdout" | grep -q '^--squash$'; then
    pass "--admin forwarded (not stripped)"
else
    fail "expected --admin + 99 + --squash in stdout; got rc=$rc stdout=$stdout"
fi
rm -rf "$d"

echo "== guard-gh outside git repo → fail-closed refuse rc=2 =="
ngd=$(mktemp -d)
out=$(cd "$ngd" && bash "$GUARD" pr-create --title foo 2>&1); rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qi "rc=2"; then
    pass "non-git refused fail-closed"
else
    fail "expected rc=2 + 'rc=2' diagnostic; got rc=$rc out=$out"
fi
rm -rf "$ngd"

echo "== refuse paths emit nothing on stdout =="
d=$(setup_repo main)
stdout=$(cd "$d" && bash "$GUARD" pr-create --title foo 2>/dev/null); rc=$?
if [ "$rc" -eq 2 ] && [ -z "$stdout" ]; then
    pass "refuse stdout empty"
else
    fail "expected rc=2 + empty stdout; got rc=$rc stdout=$stdout"
fi
rm -rf "$d"

if [ "$failures" -eq 0 ]; then
    echo "OK: all cases passed"
    exit 0
else
    echo "FAIL: $failures case(s) failed"
    exit 1
fi
