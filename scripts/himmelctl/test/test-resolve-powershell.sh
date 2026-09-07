#!/usr/bin/env bash
# test-resolve-powershell.sh — hermetic tests for
# scripts/himmelctl/lib/helpers.js's resolvePowershell() (HIMMEL-2126:
# ALWAYS prefer pwsh; Windows PowerShell 5.1 is a loud, named fallback only,
# never silent). Calls the function directly against a crafted `env` object —
# no real PATH/spawn involved, no MSYS PATH mangling to work around.
#
# Covers:
#   a. pwsh present (alongside powershell) -> pwsh wins, no stderr warning.
#   b. only powershell present -> falls back, warns HIMMEL-2126 on stderr.
#   c. neither present -> bare 'powershell' fallback, still warns.
#   d. HIMMELCTL_POWERSHELL override -> returned verbatim, no warning, wins
#      even when pwsh is also present.

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
helpers="$repo_root/scripts/himmelctl/lib/helpers.js"
[ -f "$helpers" ] || { echo "FAIL: $helpers not found" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 1; }
node_bin=$(command -v node)

fail() { echo "FAIL: $1" >&2; exit 1; }

work=$(mktemp -d)
cleanup() { rm -rf "$work"; }
trap cleanup EXIT
. "$repo_root/scripts/himmelctl/test/_hermetic-home.sh"  # HIMMEL-2350: shared winpath() -- dies loud on empty input/output instead of silently falling through to the operator's real home

mkdir -p "$work/pwsh-dir" "$work/pwsh-exe-dir" "$work/ps51-dir" "$work/empty-dir"
printf '#!/bin/sh\necho fake\n' > "$work/pwsh-dir/pwsh"; chmod +x "$work/pwsh-dir/pwsh"
printf '#!/bin/sh\necho fake\n' > "$work/pwsh-exe-dir/pwsh.exe"; chmod +x "$work/pwsh-exe-dir/pwsh.exe"
printf '#!/bin/sh\necho fake\n' > "$work/ps51-dir/powershell"; chmod +x "$work/ps51-dir/powershell"

HELPERS_LIB="$(winpath "$helpers")"; export HELPERS_LIB
PWSH_DIR="$(winpath "$work/pwsh-dir")"; export PWSH_DIR
PWSH_EXE_DIR="$(winpath "$work/pwsh-exe-dir")"; export PWSH_EXE_DIR
PS51_DIR="$(winpath "$work/ps51-dir")"; export PS51_DIR
EMPTY_DIR="$(winpath "$work/empty-dir")"; export EMPTY_DIR

# run_resolve <extra-env-json-fragment> -- runs resolvePowershell against a
# constructed env and prints {"r": <result-or-null>, "warned": <bool>}.
run_resolve() {
  local dirs="$1"
  "$node_bin" -e "
    const path = require('path');
    const { resolvePowershell } = require(process.env.HELPERS_LIB);
    const env = Object.assign({ PATH: [$dirs].join(path.delimiter) }, $2);
    let warned = false;
    const origWrite = process.stderr.write.bind(process.stderr);
    process.stderr.write = (s) => { warned = warned || /HIMMEL-2126/.test(s); return true; };
    const r = resolvePowershell(env);
    process.stderr.write = origWrite;
    console.log(JSON.stringify({ r, warned }));
  "
}

echo "== resolvePowershell: pwsh present alongside powershell -> pwsh wins, silent =="
out=$(run_resolve 'process.env.PWSH_DIR, process.env.PS51_DIR' '{}')
echo "$out" | jq -e '.r | test("pwsh$")' >/dev/null \
  || fail "expected r to end with 'pwsh' (got: $out)"
echo "$out" | jq -e '.warned == false' >/dev/null \
  || fail "expected no warning when pwsh is found (got: $out)"
echo "ok: pwsh preferred, silent"

echo "== resolvePowershell: pwsh absent, pwsh.exe present -> resolves pwsh.exe, no warning =="
out=$(run_resolve 'process.env.PWSH_EXE_DIR' '{}')
echo "$out" | jq -e '.r | test("pwsh\\.exe$")' >/dev/null \
  || fail "expected r to end with 'pwsh.exe' (got: $out)"
echo "$out" | jq -e '.warned == false' >/dev/null \
  || fail "expected no warning when pwsh.exe is found (got: $out)"
echo "ok: pwsh.exe resolved, silent"

echo "== resolvePowershell: only powershell present -> loud fallback =="
out=$(run_resolve 'process.env.PS51_DIR' '{}')
echo "$out" | jq -e '.r | test("powershell$")' >/dev/null \
  || fail "expected r to end with 'powershell' (got: $out)"
echo "$out" | jq -e '.warned == true' >/dev/null \
  || fail "expected a HIMMEL-2126 warning on fallback (got: $out)"
echo "ok: powershell fallback, warned (HIMMEL-2126)"

echo "== resolvePowershell: neither present -> bare 'powershell', still warns =="
out=$(run_resolve 'process.env.EMPTY_DIR' '{}')
echo "$out" | jq -e '.r == "powershell"' >/dev/null \
  || fail "expected the bare 'powershell' last-resort default (got: $out)"
echo "$out" | jq -e '.warned == true' >/dev/null \
  || fail "expected a HIMMEL-2126 warning even with nothing resolvable (got: $out)"
echo "ok: nothing resolvable -> bare 'powershell', still warned"

echo "== resolvePowershell: HIMMELCTL_POWERSHELL override wins over pwsh, silent =="
out=$(run_resolve 'process.env.PWSH_DIR' '{ HIMMELCTL_POWERSHELL: "C:\\pinned\\pwsh-custom.exe" }')
echo "$out" | jq -e '.r == "C:\\pinned\\pwsh-custom.exe"' >/dev/null \
  || fail "expected the HIMMELCTL_POWERSHELL override verbatim (got: $out)"
echo "$out" | jq -e '.warned == false' >/dev/null \
  || fail "expected no warning when the override is set (got: $out)"
echo "ok: HIMMELCTL_POWERSHELL override wins, silent"

echo
echo "ALL PASS"
