#!/usr/bin/env bash
# Hermetic test for upgrade.sh's _resolve_python (HIMMEL-522). Proves the engine
# picks a WORKING python and SKIPS the Microsoft Store stub (`python3` on PATH
# but emits no stdout / exits nonzero) that breaks the engine on stock Windows.
#
# It extracts the REAL _resolve_python from upgrade.sh (no logic duplication),
# then exercises it against shimmed PATHs. bash 3.2-safe; fully hermetic (own
# temp dir + temp PATH; touches no real vault/template).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
UPGRADE="$HERE/upgrade.sh"
FAILED=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1 — $2"; FAILED=$((FAILED + 1)); }

# --- extract the real function (guarded so a broken extraction can't pass) ---
FN="$(sed -n '/^_resolve_python()/,/^}/p' "$UPGRADE")"
case "$FN" in
    *"_resolve_python()"*"for c in python3 python py"*) : ;;
    *) echo "FAIL extraction — _resolve_python not captured from $UPGRADE"; exit 1 ;;
esac
eval "$FN"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A Store-stub shape: on PATH, emits NOTHING, exits 49.
mk_stub() { printf '#!/bin/sh\nexit 49\n' > "$1"; chmod +x "$1"; }
# A working interpreter shim: answers `-c 'print(1)'` with `1`.
mk_real() { printf '#!/bin/sh\necho 1\n' > "$1"; chmod +x "$1"; }
# A nastier stub: exits 0 but prints noise (the Store stub emits a "not found"
# line on some builds) -- proves the gate is on stdout=="1", NOT exit status.
mk_noise() { printf '#!/bin/sh\necho "Python was not found"\nexit 0\n' > "$1"; chmod +x "$1"; }

# --- positive: stub python3 + working python -> picks python ---
P="$TMP/pos"; mkdir -p "$P"
mk_stub "$P/python3"
mk_real "$P/python"
got="$(PATH="$P:$PATH" _resolve_python || true)"
if [ "$got" = "python" ]; then
    pass "resolver skips the python3 stub and selects python"
else
    fail "resolver positive" "expected 'python', got '$got'"
fi

# --- negative: all three names shadowed by stubs -> no interpreter (rc != 0) ---
N="$TMP/neg"; mkdir -p "$N"
mk_stub "$N/python3"; mk_stub "$N/python"; mk_stub "$N/py"
# Shadow the three names (first on PATH wins for `command -v`), keep the rest of
# PATH so the shell + coreutils still work.
PATH="$N:$PATH" _resolve_python >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ]; then
    pass "resolver returns nonzero when no working python is reachable"
else
    fail "resolver negative" "expected nonzero rc, got 0"
fi

# --- happy path: a working python3 first -> selected as python3 (Linux/macOS;
#     locks loop ORDER + gate polarity so a reorder/inversion regression fails) ---
H="$TMP/happy"; mkdir -p "$H"
mk_real "$H/python3"
got="$(PATH="$H:$PATH" _resolve_python || true)"
if [ "$got" = "python3" ]; then
    pass "resolver picks a working python3 first (canonical Linux/macOS path)"
else
    fail "resolver happy path" "expected 'python3', got '$got'"
fi

# --- py fallthrough: stub python3 + stub python + working py -> picks py
#     (the named Windows launcher scenario) ---
Y="$TMP/pyonly"; mkdir -p "$Y"
mk_stub "$Y/python3"; mk_stub "$Y/python"; mk_real "$Y/py"
got="$(PATH="$Y:$PATH" _resolve_python || true)"
if [ "$got" = "py" ]; then
    pass "resolver falls through to the py launcher when python3/python are stubs"
else
    fail "resolver py fallthrough" "expected 'py', got '$got'"
fi

# --- noise stub exits 0: gate is stdout=='1', not exit status -> still skipped ---
Z="$TMP/noise"; mkdir -p "$Z"
mk_noise "$Z/python3"; mk_real "$Z/python"
got="$(PATH="$Z:$PATH" _resolve_python || true)"
if [ "$got" = "python" ]; then
    pass "resolver rejects an exit-0 stub that prints non-'1' noise"
else
    fail "resolver noise-stub gate" "expected 'python', got '$got'"
fi

echo ""
if [ "$FAILED" -eq 0 ]; then echo "All _resolve_python tests passed."; else echo "$FAILED test(s) failed."; exit 1; fi
