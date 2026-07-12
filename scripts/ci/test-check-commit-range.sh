#!/usr/bin/env bash
# Hermetic test for scripts/ci/check-commit-range.sh (HIMMEL-594). Builds throw-
# away git repos with known-good/bad commits and asserts the gate's verdict.
set -uo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel)"
CR="$REPO_ROOT/scripts/ci/check-commit-range.sh"
[ -f "$CR" ] || { echo "FAIL: $CR not found"; exit 1; }
failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

# mkrepo <dir> <commit-msg...> — init a repo with a base commit then the given
# extra commits; echoes the base SHA via a file (avoids subshell var loss).
mkrepo() {
    local d="$1"; shift
    git init -q "$d"
    git -C "$d" config user.email t@e
    git -C "$d" config user.name t
    git -C "$d" commit -q --allow-empty -m "chore: base"
    git -C "$d" rev-parse HEAD > "$d/.base"
    local m
    for m in "$@"; do git -C "$d" commit -q --allow-empty -m "$m"; done
}

run_cr() { # <repo-dir> -> runs check-commit-range against <base>..HEAD
    local d="$1" base
    base="$(cat "$d/.base")"
    ( cd "$d" && bash "$CR" "$base" 2>&1 )
}

# --- one bad (non-conventional) commit -> rc1 + surfaces it ---
t="$(mktemp -d)"
mkrepo "$t" "feat(x): HIMMEL-1 good commit" "broken commit no type"
out="$(run_cr "$t")"; rc=$?
if [ "$rc" -eq 1 ]; then pass "non-conventional -> rc1"; else fail "expected rc1, got $rc: $out"; fi
if printf '%s' "$out" | grep -q 'broken commit no type'; then pass "surfaces offending subject"; else fail "no offending subject: $out"; fi
rm -rf "$t"

# --- all-clean range -> rc0 ---
t="$(mktemp -d)"
mkrepo "$t" "fix(api): HIMMEL-2 ok" "chore: tidy"
out="$(run_cr "$t")"; rc=$?
if [ "$rc" -eq 0 ]; then pass "clean range -> rc0"; else fail "expected rc0, got $rc: $out"; fi
rm -rf "$t"

# --- malformed HIMMEL- ticket -> rc1 + named ---
t="$(mktemp -d)"
mkrepo "$t" "feat(x): HIMMEL-abc malformed ticket"
out="$(run_cr "$t")"; rc=$?
if [ "$rc" -eq 1 ]; then pass "malformed ticket -> rc1"; else fail "expected rc1, got $rc: $out"; fi
if printf '%s' "$out" | grep -qi 'malformed'; then pass "names malformed ticket"; else fail "no malformed msg: $out"; fi
rm -rf "$t"

# --- unresolvable base ref -> rc2 (cannot evaluate the range) ---
t="$(mktemp -d)"
mkrepo "$t" "chore: x"
out="$( cd "$t" && bash "$CR" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" 2>&1 )"; rc=$?
if [ "$rc" -eq 2 ]; then pass "unresolvable base -> rc2"; else fail "expected rc2, got $rc: $out"; fi
rm -rf "$t"

# --- empty range (base == HEAD) -> rc0 + 'nothing to lint' ---
t="$(mktemp -d)"
mkrepo "$t"   # base commit only; HEAD == base
out="$( cd "$t" && bash "$CR" HEAD 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ]; then pass "empty range -> rc0"; else fail "expected rc0, got $rc: $out"; fi
if printf '%s' "$out" | grep -qi 'nothing to lint'; then pass "empty range reports nothing to lint"; else fail "no nothing-to-lint msg: $out"; fi
rm -rf "$t"

echo
if [ "$failures" -eq 0 ]; then echo "ALL PASS"; else echo "$failures FAILED"; exit 1; fi
