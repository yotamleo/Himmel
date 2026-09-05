#!/usr/bin/env bash
# Smoke test for scripts/lib/resolve-powershell.sh (HIMMEL-2126).
# Usage: bash scripts/lib/test-resolve-powershell.sh
# Exit 0 if all cases pass, 1 otherwise.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
LIB="$REPO_ROOT/scripts/lib/resolve-powershell.sh"

[ -f "$LIB" ] || { echo "FAIL: $LIB not found"; exit 1; }
# shellcheck source=/dev/null
. "$LIB"

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

# A curated stub dir carrying only what each case needs, so a real pwsh or
# powershell.exe already on THIS host's PATH cannot leak into a case that
# means to test its absence.
make_fake() {
    # $1 = dir, $2 = basename
    local dir="$1" name="$2"
    mkdir -p "$dir"
    printf '#!/bin/sh\necho fake\n' > "$dir/$name"
    chmod +x "$dir/$name"
}

echo "== resolve_powershell: pwsh present -> picks it, no warning =="
tmp="$(mktemp -d)"; make_fake "$tmp/bin" pwsh
out="$(PATH="$tmp/bin" resolve_powershell 2>"$tmp/stderr.log")"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "$tmp/bin/pwsh" ] && [ ! -s "$tmp/stderr.log" ]; then
    pass "pwsh present -> '$out', silent"
else
    fail "pwsh present -> rc=$rc out='$out' stderr='$(cat "$tmp/stderr.log" 2>/dev/null)'"
fi
rm -rf "$tmp"

echo "== resolve_powershell: no pwsh, powershell.exe present -> loud fallback =="
tmp="$(mktemp -d)"; make_fake "$tmp/bin" powershell.exe
out="$(PATH="$tmp/bin" resolve_powershell 2>"$tmp/stderr.log")"; rc=$?
warn="$(cat "$tmp/stderr.log" 2>/dev/null)"
if [ "$rc" -eq 0 ] && [ "$out" = "$tmp/bin/powershell.exe" ] && printf '%s' "$warn" | grep -q 'HIMMEL-2126'; then
    pass "powershell.exe fallback -> '$out', warned (HIMMEL-2126)"
else
    fail "powershell.exe fallback -> rc=$rc out='$out' stderr='$warn'"
fi
rm -rf "$tmp"

echo "== resolve_powershell: no pwsh, bare powershell present -> loud fallback =="
tmp="$(mktemp -d)"; make_fake "$tmp/bin" powershell
out="$(PATH="$tmp/bin" resolve_powershell 2>"$tmp/stderr.log")"; rc=$?
warn="$(cat "$tmp/stderr.log" 2>/dev/null)"
if [ "$rc" -eq 0 ] && [ "$out" = "$tmp/bin/powershell" ] && printf '%s' "$warn" | grep -q 'HIMMEL-2126'; then
    pass "powershell fallback -> '$out', warned (HIMMEL-2126)"
else
    fail "powershell fallback -> rc=$rc out='$out' stderr='$warn'"
fi
rm -rf "$tmp"

echo "== resolve_powershell: pwsh absent, pwsh.exe present -> resolves pwsh.exe, no warning =="
# On Git Bash, `command -v pwsh` already resolves a bare pwsh.exe on PATH (PATHEXT-style),
# and may print either basename — both are valid working paths (same ambiguity
# test-resolve-node.sh documents for node/node.exe). Only macOS/Linux need the literal .exe.
tmp="$(mktemp -d)"; make_fake "$tmp/bin" pwsh.exe
out="$(PATH="$tmp/bin" resolve_powershell 2>"$tmp/stderr.log")"; rc=$?
if [ "$rc" -eq 0 ] && { [ "$out" = "$tmp/bin/pwsh.exe" ] || [ "$out" = "$tmp/bin/pwsh" ]; } && [ ! -s "$tmp/stderr.log" ]; then
    pass "pwsh.exe present -> '$out', silent"
else
    fail "pwsh.exe present -> rc=$rc out='$out' stderr='$(cat "$tmp/stderr.log" 2>/dev/null)'"
fi
rm -rf "$tmp"

echo "== resolve_powershell: neither on PATH -> rc1, empty, no warning =="
tmp="$(mktemp -d)"; mkdir -p "$tmp/empty"
out="$(PATH="$tmp/empty" resolve_powershell 2>"$tmp/stderr.log")"; rc=$?
if [ "$rc" -eq 1 ] && [ -z "$out" ] && [ ! -s "$tmp/stderr.log" ]; then
    pass "nothing on PATH -> rc1 empty, no warning"
else
    fail "nothing on PATH -> rc=$rc out='$out' stderr='$(cat "$tmp/stderr.log" 2>/dev/null)'"
fi
rm -rf "$tmp"

echo "== resolve_powershell: pwsh takes priority over a present powershell.exe =="
tmp="$(mktemp -d)"; make_fake "$tmp/pwsh-dir" pwsh; make_fake "$tmp/ps51-dir" powershell.exe
out="$(PATH="$tmp/pwsh-dir:$tmp/ps51-dir" resolve_powershell 2>"$tmp/stderr.log")"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "$tmp/pwsh-dir/pwsh" ] && [ ! -s "$tmp/stderr.log" ]; then
    pass "pwsh wins over powershell.exe -> '$out', silent"
else
    fail "pwsh priority -> rc=$rc out='$out' stderr='$(cat "$tmp/stderr.log" 2>/dev/null)'"
fi
rm -rf "$tmp"

echo
if [ "$failures" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$failures FAILURE(S)"; exit 1; fi
