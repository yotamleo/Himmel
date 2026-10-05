#!/usr/bin/env bash
# scripts/release/test-check-version-tag.sh - suite for check-version-tag.sh
# (HIMMEL-4417): VERSION must equal the X.Y.Z base of the highest v* tag.
# Platform guard: Linux/macOS bash 3.2+ (git only).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/check-version-tag.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/check-version-tag-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
fails=0
check()    { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); fi; }
contains() { if grep -q -F -e "$3" <<< "$2"; then echo "ok - $1"; else echo "FAIL - $1: output does not contain [$3]"; fails=$((fails+1)); fi; }

# mkrepo <name> <VERSION content> <tag>... - a throwaway repo with VERSION and tags
mkrepo() {
    local d="$tmp/$1" v="$2"; shift 2
    mkdir -p "$d"
    git -C "$d" init -q
    git -C "$d" config user.email t@t; git -C "$d" config user.name t
    git -C "$d" config commit.gpgsign false; git -C "$d" config tag.gpgsign false
    printf '%s\n' "$v" > "$d/VERSION"
    git -C "$d" add VERSION; git -C "$d" commit -q -m init
    local t; for t in "$@"; do git -C "$d" tag "$t"; done
}

mkrepo match 1.0.2 v1.0.1-pre.4 v1.0.2-pre.1
rc=0; out=$(bash "$SCRIPT" --root "$tmp/match" 2>&1) || rc=$?
check "match: rc 0" "$rc" "0"

mkrepo stale 1.0.0 v1.0.1-pre.4 v1.0.2-pre.1
rc=0; out=$(bash "$SCRIPT" --root "$tmp/stale" 2>&1) || rc=$?
check "stale VERSION: rc 1" "$rc" "1"
contains "stale VERSION: names both" "$out" "VERSION is 1.0.0 but the latest tag v1.0.2-pre.1 is at 1.0.2"

# a bare release tag sorts BEFORE its own -pre tags under git's version sort; the base compare must not care
mkrepo bare 1.0.2 v1.0.2-pre.1 v1.0.2
rc=0; out=$(bash "$SCRIPT" --root "$tmp/bare" 2>&1) || rc=$?
check "bare + pre tags: rc 0" "$rc" "0"

mkrepo tenth 1.0.10 v1.0.9 v1.0.10-pre.1
rc=0; out=$(bash "$SCRIPT" --root "$tmp/tenth" 2>&1) || rc=$?
check "numeric (not lexical) tag order: rc 0" "$rc" "0"

mkrepo notags 1.0.0
rc=0; out=$(bash "$SCRIPT" --root "$tmp/notags" 2>&1) || rc=$?
check "no tags: rc 0 (cannot check)" "$rc" "0"
contains "no tags: says SKIP" "$out" "SKIP"

mkrepo badver "1.0.2-pre.1" v1.0.2-pre.1
rc=0; out=$(bash "$SCRIPT" --root "$tmp/badver" 2>&1) || rc=$?
check "VERSION not bare X.Y.Z: rc 1" "$rc" "1"

# the live repo: the enforcement CI actually runs
if [ -n "$(git -C "$HERE" tag --list 'v[0-9]*' | head -1)" ]; then
    rc=0; out=$(bash "$SCRIPT" --root "$HERE/../.." 2>&1) || rc=$?
    check "live repo: VERSION matches the latest tag ($out)" "$rc" "0"
else
    echo "ok - live repo: no tags in this checkout, skipped"
fi

[ "$fails" -eq 0 ] && echo "ALL PASS" && exit 0
echo "$fails FAILED"; exit 1
