#!/usr/bin/env bash
# Smoke test for scripts/lib/resolve-node.sh.
# Usage: bash scripts/lib/test-resolve-node.sh
# Exit 0 if all cases pass, 1 otherwise.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
LIB="$REPO_ROOT/scripts/lib/resolve-node.sh"

[ -f "$LIB" ] || { echo "FAIL: $LIB not found"; exit 1; }
# shellcheck source=/dev/null
. "$LIB"

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

# A realistic "node not on PATH" still has coreutils (/usr/bin). Use the dir
# that actually holds sort/ls so resolve_node's nvm/fnm pipeline works, while
# node stays absent from it. (Setting PATH=/nonexistent would also strip sort.)
UTILS_DIR="$(dirname "$(command -v sort)")"

# A fake node binary (executable, content irrelevant — resolve_node only checks -x).
make_fake_node() {
    # $1 = dir, $2 = optional basename (default node)
    local dir="$1" name="${2:-node}"
    mkdir -p "$dir"
    printf '#!/bin/sh\necho fake\n' > "$dir/$name"
    chmod +x "$dir/$name"
}

echo "== resolve_node: real node on PATH =="
# This box may or may not have node on PATH; only assert when it does.
if command -v node >/dev/null 2>&1; then
    out="$(resolve_node)"; rc=$?
    if [ "$rc" -eq 0 ] && [ -n "$out" ]; then pass "PATH node -> '$out' rc0"; else fail "PATH node -> rc=$rc out='$out'"; fi
else
    pass "PATH node -> (skipped: no node on PATH here)"
fi

echo "== resolve_node: found in an injected probe dir (PATH cleared) =="
tmp="$(mktemp -d)"; make_fake_node "$tmp/bin"
out="$(PATH="$UTILS_DIR" RESOLVE_NODE_PROBE_DIRS="$tmp/bin" RESOLVE_NODE_NVM_ROOT="$tmp/none" FNM_DIR="$tmp/none" resolve_node)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "$tmp/bin/node" ]; then pass "probe dir -> '$out'"; else fail "probe dir -> rc=$rc out='$out' (want $tmp/bin/node)"; fi
rm -rf "$tmp"

echo "== resolve_node: node.exe variant in probe dir =="
tmp="$(mktemp -d)"; make_fake_node "$tmp/bin" "node.exe"
out="$(PATH="$UTILS_DIR" RESOLVE_NODE_PROBE_DIRS="$tmp/bin" RESOLVE_NODE_NVM_ROOT="$tmp/none" FNM_DIR="$tmp/none" resolve_node)"; rc=$?
# On Git Bash, `[ -x node ]` already resolves node.exe, so resolve_node may print
# either basename; both are valid working paths. On macOS/Linux only node.exe exists.
if [ "$rc" -eq 0 ] && { [ "$out" = "$tmp/bin/node.exe" ] || [ "$out" = "$tmp/bin/node" ]; }; then pass "node.exe -> '$out'"; else fail "node.exe -> rc=$rc out='$out'"; fi
rm -rf "$tmp"

echo "== resolve_node: no node anywhere -> rc1, empty =="
tmp="$(mktemp -d)"
out="$(PATH="$UTILS_DIR" RESOLVE_NODE_PROBE_DIRS="" RESOLVE_NODE_NVM_ROOT="$tmp/none" FNM_DIR="$tmp/none" resolve_node)"; rc=$?
if [ "$rc" -eq 1 ] && [ -z "$out" ]; then pass "no node -> rc1 empty"; else fail "no node -> rc=$rc out='$out'"; fi
rm -rf "$tmp"

echo "== resolve_node: nvm picks newest (sort -V, not lexical) =="
tmp="$(mktemp -d)"; nvm="$tmp/nvm"
make_fake_node "$nvm/v8.9.0/bin"
make_fake_node "$nvm/v20.5.0/bin"
make_fake_node "$nvm/v18.0.0/bin"
out="$(PATH="$UTILS_DIR" RESOLVE_NODE_PROBE_DIRS="" RESOLVE_NODE_NVM_ROOT="$nvm" FNM_DIR="$tmp/none" resolve_node)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "$nvm/v20.5.0/bin/node" ]; then pass "nvm newest -> '$out'"; else fail "nvm newest -> rc=$rc out='$out' (want v20.5.0; lexical bug would give v8.9.0)"; fi
rm -rf "$tmp"

echo
if [ "$failures" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$failures FAILURE(S)"; exit 1; fi
