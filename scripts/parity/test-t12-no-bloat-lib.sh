#!/usr/bin/env bash
# Control for scripts/parity/t12-no-bloat-lib.sh's t12_verdict() (HIMMEL-2581).
#
# Proves the T12 net-growth threshold is non-vacuous in BOTH directions,
# against synthetic add/del pairs -- no real git diff needed, so this
# exercises the arithmetic directly rather than merely inferring it from
# test-ws5-invariants.sh passing on our own diff:
#   - a genuine bloat addition (add=10 del=0, net +10) still FAILS;
#   - a net-zero rewording (add=2 del=2 -- the exact PR #2101/HIMMEL-2413
#     and HIMMEL-2581 shape the OLD per-side cap wrongly failed) PASSES;
#   - a net-shrink (add=1 del=9 -- a pure deletion) PASSES;
#   - the <=1 net-growth boundary itself is exact (net=1 passes, net=2 fails).
#
# Assertions use `case` glob matching, NOT `printf | grep -q` (HIMMEL-1430,
# fix-class grep-q-pipe-under-pipefail): this file sets `set -uo pipefail`,
# so a pipeline's exit status is its LAST stage, and a `grep -q` early-exit
# match can SIGPIPE the producer, turning a successful match into a failed
# pipeline. Not live today at this file's ~60-char single-line `$out` (it
# fits the pipe buffer, so `printf` always finishes before `grep -q` could
# SIGPIPE it) -- but a test file silently inverting its own assertions later,
# when someone lengthens the message, is exactly the wrong place to leave
# that latent. `case` has no pipeline status to invert. Each pattern below
# requires BOTH the `PASS`/`FAIL T12 no-bloat` prefix AND the exact,
# terminator-anchored `add=/del=/net=` substring (the trailing space or `--`
# after each numeric value stops e.g. `net=1` from matching inside `net=10`).
#
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
# Pure git-free shell (command substitution, `$(( ))`, `case` glob matching);
# no .ps1 twin needed -- the only consumer is this shell test suite, which is
# itself gitbash-only.
#
# Usage: bash scripts/parity/test-t12-no-bloat-lib.sh
# Exit 0 if all cases pass, 1 otherwise.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$SCRIPT_DIR/t12-no-bloat-lib.sh"

if [ ! -f "$LIB" ]; then
    echo "FAIL: $LIB not found"
    exit 1
fi

# shellcheck source=/dev/null
. "$LIB"

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

echo "== t12_verdict: genuine bloat still FAILS =="
out="$(t12_verdict 10 0 2>&1)"; rc=$?
matched=0
case "$out" in
    "FAIL T12 no-bloat"*"add=10 del=0 net=10"" --"*) matched=1 ;;
esac
if [ "$rc" -eq 1 ] && [ "$matched" -eq 1 ]; then
    pass "add=10 del=0 (net +10) -> FAIL, rc=1, names add/del/net"
else
    fail "add=10 del=0 -> expected FAIL rc=1 naming net=10, got rc=$rc: $out"
fi

echo "== t12_verdict: net-zero rewording PASSES (the PR #2101/HIMMEL-2413 and HIMMEL-2581 shape the old per-side cap wrongly failed) =="
out="$(t12_verdict 2 2)"; rc=$?
matched=0
case "$out" in
    "PASS T12 no-bloat"*"add=2 del=2 net=0"" ("*) matched=1 ;;
esac
if [ "$rc" -eq 0 ] && [ "$matched" -eq 1 ]; then
    pass "add=2 del=2 (net 0) -> PASS, rc=0, names add/del/net"
else
    fail "add=2 del=2 -> expected PASS rc=0 naming net=0, got rc=$rc: $out"
fi

echo "== t12_verdict: net shrink PASSES (a pure deletion is not bloat) =="
out="$(t12_verdict 1 9)"; rc=$?
matched=0
case "$out" in
    "PASS T12 no-bloat"*"add=1 del=9 net=-8"" ("*) matched=1 ;;
esac
if [ "$rc" -eq 0 ] && [ "$matched" -eq 1 ]; then
    pass "add=1 del=9 (net -8) -> PASS, rc=0, names add/del/net"
else
    fail "add=1 del=9 -> expected PASS rc=0 naming net=-8, got rc=$rc: $out"
fi

echo "== t12_verdict: net growth of exactly 1 -- the allowed boundary -- still PASSES =="
out="$(t12_verdict 1 0)"; rc=$?
matched=0
case "$out" in
    "PASS T12 no-bloat"*"add=1 del=0 net=1"" ("*) matched=1 ;;
esac
if [ "$rc" -eq 0 ] && [ "$matched" -eq 1 ]; then
    pass "add=1 del=0 (net +1) -> PASS, rc=0"
else
    fail "add=1 del=0 -> expected PASS naming net=1, got rc=$rc: $out"
fi

echo "== t12_verdict: net growth of exactly 2 -- one past the boundary -- still FAILS =="
out="$(t12_verdict 3 1 2>&1)"; rc=$?
matched=0
case "$out" in
    "FAIL T12 no-bloat"*"add=3 del=1 net=2"" --"*) matched=1 ;;
esac
if [ "$rc" -eq 1 ] && [ "$matched" -eq 1 ]; then
    pass "add=3 del=1 (net +2) -> FAIL, rc=1, names net"
else
    fail "add=3 del=1 -> expected FAIL naming net=2, got rc=$rc: $out"
fi

echo
if [ "$failures" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$failures FAILURE(S)"; exit 1; fi
