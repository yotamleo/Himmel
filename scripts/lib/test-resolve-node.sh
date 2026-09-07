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

# A realistic "node not on PATH" still needs coreutils — but on apt-node
# systems node LIVES in the coreutils dir (/usr/bin, HIMMEL-966), so use
# a curated symlink dir carrying only the tools these cases need.
UTILS_ROOT="$(mktemp -d)"
trap 'rm -rf "$UTILS_ROOT"' EXIT
UTILS_DIR="$UTILS_ROOT/utils"
mkdir -p "$UTILS_DIR"
for _t in sort tail; do
    _p="$(command -v "$_t" 2>/dev/null)" && ln -s "$_p" "$UTILS_DIR/$_t" 2>/dev/null
done
# Windows Git Bash: a symlink/copy of an MSYS tool loses its msys-2.0.dll
# neighborhood and won't run — probe, then fall back to the coreutils dir
# (node is never colocated with coreutils on those hosts).
if ! PATH="$UTILS_DIR" sort </dev/null >/dev/null 2>&1; then
    UTILS_DIR="$(dirname "$(command -v sort)")"
    # Self-diagnose the one bad combination (fallback dir DOES carry node —
    # the HIMMEL-966 apt-node class): the PATH-cleared cases below will fail;
    # say why up front instead of leaving a puzzling red run.
    if [ -x "$UTILS_DIR/node" ] || [ -x "$UTILS_DIR/node.exe" ]; then
        echo "WARN: curated utils dir unusable AND fallback $UTILS_DIR carries node — PATH-cleared cases will fail (HIMMEL-966)" >&2
    fi
fi

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

# NVM_SYMLINK="" and RESOLVE_NODE_NVM4W_DIR="" below (codex CR round 2,
# HIMMEL-2077): step 1 (nvm-windows) is now independent of RESOLVE_NODE_PROBE_DIRS
# — it used to be silently disabled by that seam, which incidentally made
# these step-3/nvm/fnm cases hermetic on a machine with a REAL nvm-windows
# install (this dev box has one at /c/nvm4w/nodejs). Without an explicit
# override here they would resolve the real machine node instead of the
# fixture, on such a machine.
echo "== resolve_node: found in an injected probe dir (PATH cleared) =="
tmp="$(mktemp -d)"; make_fake_node "$tmp/bin"
out="$(PATH="$UTILS_DIR" NVM_SYMLINK="" RESOLVE_NODE_NVM4W_DIR="" RESOLVE_NODE_PROBE_DIRS="$tmp/bin" RESOLVE_NODE_NVM_ROOT="$tmp/none" FNM_DIR="$tmp/none" resolve_node)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "$tmp/bin/node" ]; then pass "probe dir -> '$out'"; else fail "probe dir -> rc=$rc out='$out' (want $tmp/bin/node)"; fi
rm -rf "$tmp"

echo "== resolve_node: node.exe variant in probe dir =="
tmp="$(mktemp -d)"; make_fake_node "$tmp/bin" "node.exe"
out="$(PATH="$UTILS_DIR" NVM_SYMLINK="" RESOLVE_NODE_NVM4W_DIR="" RESOLVE_NODE_PROBE_DIRS="$tmp/bin" RESOLVE_NODE_NVM_ROOT="$tmp/none" FNM_DIR="$tmp/none" resolve_node)"; rc=$?
# On Git Bash, `[ -x node ]` already resolves node.exe, so resolve_node may print
# either basename; both are valid working paths. On macOS/Linux only node.exe exists.
if [ "$rc" -eq 0 ] && { [ "$out" = "$tmp/bin/node.exe" ] || [ "$out" = "$tmp/bin/node" ]; }; then pass "node.exe -> '$out'"; else fail "node.exe -> rc=$rc out='$out'"; fi
rm -rf "$tmp"

echo "== resolve_node: nvm-windows NVM_SYMLINK probed (built-in list, HIMMEL-2013) =="
tmp="$(mktemp -d)"; make_fake_node "$tmp/nvm4w" "node.exe"
out="$(PATH="$UTILS_DIR" NVM_SYMLINK="$tmp/nvm4w" RESOLVE_NODE_NVM_ROOT="$tmp/none" FNM_DIR="$tmp/none" resolve_node)"; rc=$?
if [ "$rc" -eq 0 ] && { [ "$out" = "$tmp/nvm4w/node.exe" ] || [ "$out" = "$tmp/nvm4w/node" ]; }; then pass "NVM_SYMLINK -> '$out'"; else fail "NVM_SYMLINK -> rc=$rc out='$out' (want $tmp/nvm4w/node.exe or $tmp/nvm4w/node)"; fi
rm -rf "$tmp"

echo "== resolve_node: NVM_SYMLINK drive-letter form (C:\\...) rewritten to /c/... (HIMMEL-2013) =="
if command -v cygpath >/dev/null 2>&1; then
    tmp="$(mktemp -d)"; make_fake_node "$tmp/nvm4w" "node.exe"
    win_symlink="$(cygpath -w "$tmp/nvm4w")"
    out="$(PATH="$UTILS_DIR" NVM_SYMLINK="$win_symlink" RESOLVE_NODE_NVM_ROOT="$tmp/none" FNM_DIR="$tmp/none" resolve_node)"; rc=$?
    if [ "$rc" -eq 0 ] && [ -x "$out" ] && { [ "$(cygpath -w "$out")" = "$(cygpath -w "$tmp/nvm4w/node.exe")" ] || [ "$(cygpath -w "$out")" = "$(cygpath -w "$tmp/nvm4w/node")" ]; }; then
        pass "NVM_SYMLINK drive-letter -> '$out'"
    else
        fail "NVM_SYMLINK drive-letter -> rc=$rc out='$out' (input '$win_symlink', want $tmp/nvm4w/node.exe or $tmp/nvm4w/node)"
    fi
    rm -rf "$tmp"
else
    pass "NVM_SYMLINK drive-letter form -> (skipped: no cygpath here)"
fi

echo "== resolve_node: NVM_SYMLINK beats a stale node already on PATH (HIMMEL-2077) =="
# HIMMEL-2013 chose NVM_SYMLINK as the operator's version specifically to beat
# a stale winget/MSI install — but a PATH probe run BEFORE that list re-broke
# it whenever the stale install was ALSO reachable via PATH (the ordering bug
# this case pins). A "stale" node lives on a PATH dir; a different "chosen"
# node lives at NVM_SYMLINK; the resolved binary must be the NVM_SYMLINK one.
tmp="$(mktemp -d "${TMPDIR:-/tmp}/resolve-node-test.XXXXXX")"
make_fake_node "$tmp/stale-on-path"
make_fake_node "$tmp/nvm4w" "node.exe"
out="$(PATH="$tmp/stale-on-path:$UTILS_DIR" NVM_SYMLINK="$tmp/nvm4w" RESOLVE_NODE_NVM_ROOT="$tmp/none" FNM_DIR="$tmp/none" resolve_node)"; rc=$?
if [ "$rc" -eq 0 ] && { [ "$out" = "$tmp/nvm4w/node.exe" ] || [ "$out" = "$tmp/nvm4w/node" ]; }; then
    pass "NVM_SYMLINK beats stale PATH node -> '$out'"
else
    fail "NVM_SYMLINK beats stale PATH node -> rc=$rc out='$out' (want $tmp/nvm4w/node.exe or $tmp/nvm4w/node, NOT $tmp/stale-on-path/node)"
fi
rm -rf "$tmp"

echo "== resolve_node: a generic OTHER absolute location does NOT beat a chosen PATH node (codex CR round on HIMMEL-2077) =="
# The HIMMEL-2077 fix above scopes ONLY nvm-windows (NVM_SYMLINK / /c/nvm4w/nodejs)
# ahead of PATH. RESOLVE_NODE_PROBE_DIRS stands in for the OTHER well-known
# locations (/usr/bin, homebrew, ...) — those must stay a PATH FALLBACK, or a
# generic system node would override an operator's deliberately-chosen PATH
# entry (a Unix version manager, asdf shims, etc.) on every platform.
tmp="$(mktemp -d "${TMPDIR:-/tmp}/resolve-node-test.XXXXXX")"
make_fake_node "$tmp/chosen-on-path"
make_fake_node "$tmp/generic-other-location"
out="$(PATH="$tmp/chosen-on-path:$UTILS_DIR" NVM_SYMLINK="" RESOLVE_NODE_NVM4W_DIR="" RESOLVE_NODE_PROBE_DIRS="$tmp/generic-other-location" RESOLVE_NODE_NVM_ROOT="$tmp/none" FNM_DIR="$tmp/none" resolve_node)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "$tmp/chosen-on-path/node" ]; then
    pass "chosen PATH node beats a generic other-location node -> '$out'"
else
    fail "chosen PATH node beats a generic other-location node -> rc=$rc out='$out' (want $tmp/chosen-on-path/node, NOT $tmp/generic-other-location/node)"
fi
rm -rf "$tmp"

echo "== resolve_node: NVM_SYMLINK still wins even with RESOLVE_NODE_PROBE_DIRS ALSO set (codex CR round 2, HIMMEL-2077) =="
# The seam contract (see resolve-node.sh's header) is that RESOLVE_NODE_PROBE_DIRS
# replaces ONLY the step-3 other-locations list -- step 1's NVM_SYMLINK must stay
# live regardless. A prior version of the fix disabled step 1 outright whenever
# this seam was set, silently contradicting its own documented contract.
tmp="$(mktemp -d "${TMPDIR:-/tmp}/resolve-node-test.XXXXXX")"
make_fake_node "$tmp/nvm4w" "node.exe"
make_fake_node "$tmp/generic-other-location"
out="$(PATH="$UTILS_DIR" NVM_SYMLINK="$tmp/nvm4w" RESOLVE_NODE_NVM4W_DIR="" RESOLVE_NODE_PROBE_DIRS="$tmp/generic-other-location" RESOLVE_NODE_NVM_ROOT="$tmp/none" FNM_DIR="$tmp/none" resolve_node)"; rc=$?
if [ "$rc" -eq 0 ] && { [ "$out" = "$tmp/nvm4w/node.exe" ] || [ "$out" = "$tmp/nvm4w/node" ]; }; then
    pass "NVM_SYMLINK wins alongside RESOLVE_NODE_PROBE_DIRS -> '$out'"
else
    fail "NVM_SYMLINK wins alongside RESOLVE_NODE_PROBE_DIRS -> rc=$rc out='$out' (want $tmp/nvm4w/node.exe or $tmp/nvm4w/node)"
fi
rm -rf "$tmp"

echo "== resolve_node: no node anywhere -> rc1, empty =="
tmp="$(mktemp -d)"
out="$(PATH="$UTILS_DIR" NVM_SYMLINK="" RESOLVE_NODE_NVM4W_DIR="" RESOLVE_NODE_PROBE_DIRS="" RESOLVE_NODE_NVM_ROOT="$tmp/none" FNM_DIR="$tmp/none" resolve_node)"; rc=$?
if [ "$rc" -eq 1 ] && [ -z "$out" ]; then pass "no node -> rc1 empty"; else fail "no node -> rc=$rc out='$out'"; fi
rm -rf "$tmp"

echo "== resolve_node: nvm picks newest (sort -V, not lexical) =="
tmp="$(mktemp -d)"; nvm="$tmp/nvm"
make_fake_node "$nvm/v8.9.0/bin"
make_fake_node "$nvm/v20.5.0/bin"
make_fake_node "$nvm/v18.0.0/bin"
out="$(PATH="$UTILS_DIR" NVM_SYMLINK="" RESOLVE_NODE_NVM4W_DIR="" RESOLVE_NODE_PROBE_DIRS="" RESOLVE_NODE_NVM_ROOT="$nvm" FNM_DIR="$tmp/none" resolve_node)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "$nvm/v20.5.0/bin/node" ]; then pass "nvm newest -> '$out'"; else fail "nvm newest -> rc=$rc out='$out' (want v20.5.0; lexical bug would give v8.9.0)"; fi
rm -rf "$tmp"

echo
if [ "$failures" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$failures FAILURE(S)"; exit 1; fi
