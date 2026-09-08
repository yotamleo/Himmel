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

# HIMMEL-2582: with HERMES_HOME unset, the derived root used to be
# ${LOCALAPPDATA:-$HOME/AppData/Local}/hermes — a WINDOWS path — on EVERY host,
# so the resolver failed on any POSIX box that had not exported HERMES_HOME.
# That is what made the bridge's triage fail open with "hermes interpreter not
# found" on the Linux station (2026-09-05). On POSIX hermes lives at ~/.hermes;
# the Windows default belongs under the LOCALAPPDATA branch only.
echo "== HERMES_HOME UNSET on a POSIX layout defaults to \$HOME/.hermes =="
tmp="$(mktemp -d "${TMPDIR:-/tmp}/hermes-py-test.XXXXXX")" || { echo "FAIL: mktemp"; exit 1; }
make_fake_py "$tmp/home/.hermes/hermes-agent/venv/bin/python"
out="$( base_env; HOME="$tmp/home" resolve_hermes_py )"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "$tmp/home/.hermes/hermes-agent/venv/bin/python" ]; then
    pass "unset HERMES_HOME -> '$out'"
else
    fail "unset HERMES_HOME -> rc=$rc out='$out' (want \$HOME/.hermes/hermes-agent/venv/bin/python)"
fi
rm -rf "$tmp"

# The POSIX default must not COST the Windows one: when LOCALAPPDATA is set
# (the marker of a Windows host) that branch still wins, so a Git-Bash operator
# with hermes under %LOCALAPPDATA%/hermes keeps resolving exactly as before.
echo "== LOCALAPPDATA still wins when set (Windows host, HERMES_HOME unset) =="
tmp="$(mktemp -d "${TMPDIR:-/tmp}/hermes-py-test.XXXXXX")" || { echo "FAIL: mktemp"; exit 1; }
make_fake_py "$tmp/appdata/hermes/hermes-agent/venv/Scripts/python.exe"
make_fake_py "$tmp/home/.hermes/hermes-agent/venv/bin/python"
out="$( base_env; HOME="$tmp/home" LOCALAPPDATA="$tmp/appdata" resolve_hermes_py )"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "$tmp/appdata/hermes/hermes-agent/venv/Scripts/python.exe" ]; then
    pass "LOCALAPPDATA wins -> '$out'"
else
    fail "LOCALAPPDATA wins -> rc=$rc out='$out' (want the %LOCALAPPDATA%/hermes tree)"
fi
rm -rf "$tmp"

# An explicit HERMES_HOME still beats both defaults — that override is what the
# station drop-in used as its recovery, and it must keep working.
echo "== explicit HERMES_HOME still beats the POSIX default =="
tmp="$(mktemp -d "${TMPDIR:-/tmp}/hermes-py-test.XXXXXX")" || { echo "FAIL: mktemp"; exit 1; }
make_fake_py "$tmp/explicit/hermes-agent/venv/bin/python"
make_fake_py "$tmp/home/.hermes/hermes-agent/venv/bin/python"
out="$( base_env; HOME="$tmp/home" HERMES_HOME="$tmp/explicit" resolve_hermes_py )"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "$tmp/explicit/hermes-agent/venv/bin/python" ]; then
    pass "explicit HERMES_HOME -> '$out'"
else
    fail "explicit HERMES_HOME -> rc=$rc out='$out'"
fi
rm -rf "$tmp"

echo
if [ "$failures" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$failures FAILURE(S)"; exit 1; fi
