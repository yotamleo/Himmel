#!/usr/bin/env bash
# Smoke test for scripts/lib/resolve-hermes-py.sh (HIMMEL-613).
# Usage: bash scripts/lib/test-resolve-hermes-py.sh
# Exit 0 if all cases pass, 1 otherwise. Hermetic — no hermes runtime needed.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
LIB="$REPO_ROOT/scripts/lib/resolve-hermes-py.sh"

[ -f "$LIB" ] || { echo "FAIL: $LIB not found"; exit 1; }
# shellcheck source=/dev/null
. "$LIB"

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

# A fake executable python (content irrelevant — resolver only checks -x).
make_fake_py() {  # $1 = full path to create
    mkdir -p "$(dirname "$1")"
    printf '#!/bin/sh\necho fake\n' > "$1"
    chmod +x "$1"
}

# Isolate from the real environment for every case.
base_env() { unset HERMES_PY HERMES_HOME LOCALAPPDATA; }

echo "== HERMES_PY wins when executable =="
tmp="$(mktemp -d)"; make_fake_py "$tmp/py/python"
out="$( base_env; HERMES_PY="$tmp/py/python" resolve_hermes_py )"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "$tmp/py/python" ]; then pass "HERMES_PY -> '$out'"; else fail "HERMES_PY -> rc=$rc out='$out'"; fi
rm -rf "$tmp"

echo "== stale HERMES_PY does NOT shadow a fresh venv probe (move/rebuild safe) =="
tmp="$(mktemp -d)"
make_fake_py "$tmp/install/hermes-agent/venv/bin/python"   # rebuilt venv (POSIX layout)
out="$( base_env; HERMES_PY="$tmp/gone/python" HERMES_HOME="$tmp/install" resolve_hermes_py )"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "$tmp/install/hermes-agent/venv/bin/python" ]; then
    pass "stale HERMES_PY fell through to probe -> '$out'"
else
    fail "stale HERMES_PY -> rc=$rc out='$out' (want the probed venv python)"
fi
rm -rf "$tmp"

echo "== probe via HERMES_HOME (Windows Scripts/ layout) =="
tmp="$(mktemp -d)"
make_fake_py "$tmp/install/hermes-agent/venv/Scripts/python.exe"
out="$( base_env; HERMES_HOME="$tmp/install" resolve_hermes_py )"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "$tmp/install/hermes-agent/venv/Scripts/python.exe" ]; then
    pass "HERMES_HOME Scripts/ -> '$out'"
else
    fail "HERMES_HOME Scripts/ -> rc=$rc out='$out'"
fi
rm -rf "$tmp"

echo "== explicit CHECKOUT_DIR arg is probed =="
tmp="$(mktemp -d)"
make_fake_py "$tmp/co/venv/bin/python"
out="$( base_env && resolve_hermes_py "$tmp/co" )"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "$tmp/co/venv/bin/python" ]; then pass "arg dir -> '$out'"; else fail "arg dir -> rc=$rc out='$out'"; fi
rm -rf "$tmp"

echo "== HERMES_HOME pointing straight at the checkout (venv/ at root) =="
tmp="$(mktemp -d)"
make_fake_py "$tmp/direct/venv/bin/python"
out="$( base_env; HERMES_HOME="$tmp/direct" resolve_hermes_py )"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "$tmp/direct/venv/bin/python" ]; then pass "direct checkout -> '$out'"; else fail "direct checkout -> rc=$rc out='$out'"; fi
rm -rf "$tmp"

echo "== no interpreter anywhere -> rc1, empty =="
tmp="$(mktemp -d)"
out="$( base_env; HERMES_HOME="$tmp/nope" resolve_hermes_py )"; rc=$?
if [ "$rc" -eq 1 ] && [ -z "$out" ]; then pass "none -> rc1 empty"; else fail "none -> rc=$rc out='$out'"; fi
rm -rf "$tmp"

echo
if [ "$failures" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$failures FAILURE(S)"; exit 1; fi
