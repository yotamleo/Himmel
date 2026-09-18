#!/usr/bin/env bash
# Control for T13(b) of scripts/parity/test-ws5-invariants.sh (HIMMEL-3147).
#
# T13(b) greps the lines a diff ADDS for loop/service/timer markers. Code that
# is merely MOVED (a refactor extracting a function, e.g. the HIMMEL-1575
# startup watchdog hoisted into a shared helper) reads as freshly added at its
# new home and re-fired the gate -- the same class as HIMMEL-3090 (renames) and
# HIMMEL-3151 (test fixtures). The rule under test: an added marker line does
# not count when an identical line (compared trimmed) is REMOVED elsewhere in
# the SAME full-tree diff, one removal cancelling one addition.
#
# End-to-end against real fixture repos: each case commits a base and a feature
# commit into a throwaway git repo carrying a COPY of the real ws5 script, then
# runs it with --base main. Every case also asserts the script's exit status, so
# a fixture that breaks some OTHER section cannot fake a T13(b) verdict:
#   1. a marker line MOVED between two files            -> PASS  (the fix)
#   1b. the same move, re-indented                      -> PASS  (trim)
#   2. a brand-new marker line                          -> FAIL  (still gated)
#   3. added marker while a DIFFERENT marker is removed -> FAIL  (not neutral)
#   4. one removal, two additions (move + duplicate)    -> FAIL  (one-for-one)
#
# Assertions use `case` glob matching, not `printf | grep -q` (HIMMEL-1430).
#
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
# Pure git + shell against a temp repo; no .ps1 twin needed -- the only
# consumer is this shell test suite, which is itself gitbash-only.
#
# Usage: bash scripts/parity/test-t13b-relocation.sh
# Exit 0 if all cases pass, 1 otherwise.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/t13b-reloc.XXXXXX")" || { echo "FAIL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP_ROOT"' EXIT

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

L1='const t = setInterval(tick, 1000);'
L2='const u = setInterval(other, 2000);'

# run_case <name> <expect PASS|FAIL> <base a.ts> <base b.ts> <head a.ts> <head b.ts>
# File contents are passed as printf format strings (\n = newline).
run_case() {
    local name="$1" expect="$2" base_a="$3" base_b="$4" head_a="$5" head_b="$6"
    local dir="$TMP_ROOT/$name"
    mkdir -p "$dir/scripts/parity" "$dir/scripts/lib" "$dir/docs/internals" "$dir/src"
    cp "$REPO/scripts/parity/test-ws5-invariants.sh" "$REPO/scripts/parity/t12-no-bloat-lib.sh" "$dir/scripts/parity/"
    cp "$REPO/scripts/lib/platform-guard.sh" "$dir/scripts/lib/"
    printf '| gemini | deferred |\n' > "$dir/docs/internals/lane-parity.md"
    printf '# fixture\n' > "$dir/CLAUDE.md"
    # shellcheck disable=SC2059
    printf "$base_a" > "$dir/src/a.ts"
    # shellcheck disable=SC2059
    printf "$base_b" > "$dir/src/b.ts"
    local g=(git -C "$dir" -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c core.hooksPath=/dev/null)
    "${g[@]}" init -q -b main >/dev/null 2>&1 || { fail "$name: fixture git init failed"; return; }
    "${g[@]}" add -A >/dev/null 2>&1
    "${g[@]}" commit -q -m base >/dev/null 2>&1 || { fail "$name: fixture base commit failed"; return; }
    "${g[@]}" checkout -q -b feat >/dev/null 2>&1
    # shellcheck disable=SC2059
    printf "$head_a" > "$dir/src/a.ts"
    # shellcheck disable=SC2059
    printf "$head_b" > "$dir/src/b.ts"
    "${g[@]}" add -A >/dev/null 2>&1
    "${g[@]}" commit -q -m feat >/dev/null 2>&1 || { fail "$name: fixture feat commit failed"; return; }

    local out rc
    out="$(bash "$dir/scripts/parity/test-ws5-invariants.sh" --base main 2>&1)"; rc=$?
    local ok=0
    if [ "$expect" = "PASS" ]; then
        case "$out" in *"PASS T13 no-always-on"*) [ "$rc" -eq 0 ] && ok=1 ;; esac
    else
        case "$out" in *"FAIL T13(b)"*) [ "$rc" -eq 1 ] && ok=1 ;; esac
    fi
    if [ "$ok" -eq 1 ]; then
        pass "$name -> $expect (rc=$rc)"
    else
        fail "$name -> expected $expect, got rc=$rc: $(printf '%s' "$out" | grep -E 'T13|FAIL' | tr '\n' '|')"
    fi
}

echo "== T13(b): relocated marker lines are neutral =="
run_case move PASS \
    "export const x = 1;\n$L1\n" "export const y = 2;\n" \
    "export const x = 1;\n" "export const y = 2;\n$L1\n"
run_case move-reindented PASS \
    "export const x = 1;\n$L1\n" "export const y = 2;\n" \
    "export const x = 1;\n" "export const y = 2;\n    $L1  \n"

echo "== T13(b): genuinely new marker code still FAILS =="
run_case brand-new FAIL \
    "export const x = 1;\n" "export const y = 2;\n" \
    "export const x = 1;\n" "export const y = 2;\n$L1\n"
run_case different-line FAIL \
    "export const x = 1;\n$L1\n" "export const y = 2;\n" \
    "export const x = 1;\n" "export const y = 2;\n$L2\n"
run_case move-and-duplicate FAIL \
    "export const x = 1;\n$L1\n" "export const y = 2;\n" \
    "export const x = 1;\n" "export const y = 2;\n$L1\n$L1\n"

if [ "$failures" -ne 0 ]; then
    echo "FAIL: $failures case(s) failed"
    exit 1
fi
echo "PASS: T13(b) relocation control (5 cases)"
exit 0
