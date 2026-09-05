#!/usr/bin/env bash
# Smoke test for scripts/lib/run-node.sh.
# Usage: bash scripts/lib/test-run-node.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
RUN="$REPO_ROOT/scripts/lib/run-node.sh"
[ -f "$RUN" ] || { echo "FAIL: $RUN not found"; exit 1; }

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

# A realistic "node not on PATH" still needs coreutils — but on apt-node
# systems node LIVES in the coreutils dir (/usr/bin, HIMMEL-966), so use
# a curated symlink dir carrying only the tools these cases need.
UTILS_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-run-node-utils.XXXXXX")"
trap 'rm -rf "$UTILS_ROOT"' EXIT
UTILS_DIR="$UTILS_ROOT/utils"
mkdir -p "$UTILS_DIR"
for _t in bash dirname sort tail cat mkdir date; do
    _p="$(command -v "$_t" 2>/dev/null)" && ln -s "$_p" "$UTILS_DIR/$_t" 2>/dev/null
done
# Windows Git Bash: a symlink/copy of an MSYS tool loses its msys-2.0.dll
# neighborhood and won't run — probe, then fall back to the coreutils dir
# (node is never colocated with coreutils on those hosts).
if ! PATH="$UTILS_DIR" bash -c 'sort </dev/null >/dev/null 2>&1 && command -v dirname >/dev/null' 2>/dev/null; then
    UTILS_DIR="$(dirname "$(command -v sort)")"
    # Self-diagnose the one bad combination (fallback dir DOES carry node —
    # the HIMMEL-966 apt-node class): the PATH-cleared cases below will fail;
    # say why up front instead of leaving a puzzling red run.
    if [ -x "$UTILS_DIR/node" ] || [ -x "$UTILS_DIR/node.exe" ]; then
        echo "WARN: curated utils dir unusable AND fallback $UTILS_DIR carries node — PATH-cleared cases will fail (HIMMEL-966)" >&2
    fi
fi

# A fake node: $1 is the "script" path (we route on its basename), rest are args.
make_fake_node() {
    local dir="$1"; mkdir -p "$dir"
    cat > "$dir/node" <<'EOF'
#!/bin/sh
case "$1" in
  *echo-args*) shift; printf 'args:%s\n' "$*" ;;
  *echo-stdin*) cat ;;
  *exit42*) exit 42 ;;
  *) printf 'ran:%s\n' "$1" ;;
esac
EOF
    chmod +x "$dir/node"
}

# Every case below hands run-node.sh the SAME four-var sandbox prefix. All four
# are load-bearing: RESOLVE_NODE_PROBE_DIRS replaces resolve-node.sh's step-3
# well-known-locations list, but step 1 (NVM_SYMLINK + its hardcoded
# /c/nvm4w/nodejs default, via RESOLVE_NODE_NVM4W_DIR) is probed BEFORE both
# PATH and step 3 and stays live under that seam — so on an nvm-windows host
# the REAL node wins and the fake is never consulted (HIMMEL-2252; the seam was
# narrowed to this contract in HIMMEL-2077 and these cases still assumed the
# old one). RESOLVE_NODE_NVM4W_DIR must be set-but-EMPTY, not unset: the
# resolver reads it with ${VAR-default}. Drop any of the four and the case
# silently passes against the host's real node instead of the fake.
echo "== run-node: args pass through + stdout =="
tmp="$(mktemp -d "${TMPDIR:-/tmp}/test-run-node-args.XXXXXX")"; make_fake_node "$tmp/bin"
out="$(PATH="$UTILS_DIR" RESOLVE_NODE_PROBE_DIRS="$tmp/bin" NVM_SYMLINK="" RESOLVE_NODE_NVM4W_DIR="" RESOLVE_NODE_NVM_ROOT="$tmp/none" FNM_DIR="$tmp/none" bash "$RUN" "$tmp/echo-args.js" A B)"
if [ "$out" = "args:A B" ]; then pass "args -> '$out'"; else fail "args -> '$out'"; fi
rm -rf "$tmp"

echo "== run-node: exit code propagates =="
tmp="$(mktemp -d "${TMPDIR:-/tmp}/test-run-node-exit.XXXXXX")"; make_fake_node "$tmp/bin"
PATH="$UTILS_DIR" RESOLVE_NODE_PROBE_DIRS="$tmp/bin" NVM_SYMLINK="" RESOLVE_NODE_NVM4W_DIR="" RESOLVE_NODE_NVM_ROOT="$tmp/none" FNM_DIR="$tmp/none" bash "$RUN" "$tmp/exit42.js" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 42 ]; then pass "exit -> 42"; else fail "exit -> $rc (want 42)"; fi
rm -rf "$tmp"

echo "== run-node: stdin reaches the child =="
tmp="$(mktemp -d "${TMPDIR:-/tmp}/test-run-node-stdin.XXXXXX")"; make_fake_node "$tmp/bin"
out="$(printf 'PAYLOAD-123' | PATH="$UTILS_DIR" RESOLVE_NODE_PROBE_DIRS="$tmp/bin" NVM_SYMLINK="" RESOLVE_NODE_NVM4W_DIR="" RESOLVE_NODE_NVM_ROOT="$tmp/none" FNM_DIR="$tmp/none" bash "$RUN" "$tmp/echo-stdin.js")"
if [ "$out" = "PAYLOAD-123" ]; then pass "stdin -> '$out'"; else fail "stdin -> '$out'"; fi
rm -rf "$tmp"

echo "== run-node: no node -> silent, exit 0, one log line =="
tmp="$(mktemp -d "${TMPDIR:-/tmp}/test-run-node-nonode.XXXXXX")"; cdir="$tmp/claude"
out="$(PATH="$UTILS_DIR" RESOLVE_NODE_PROBE_DIRS="" NVM_SYMLINK="" RESOLVE_NODE_NVM4W_DIR="" RESOLVE_NODE_NVM_ROOT="$tmp/none" FNM_DIR="$tmp/none" CLAUDE_DIR="$cdir" bash "$RUN" "$tmp/hook.js" 2>"$tmp/err.txt")"
rc=$?
err="$(cat "$tmp/err.txt")"
logc=0; [ -f "$cdir/himmel-node.log" ] && logc="$(wc -l < "$cdir/himmel-node.log" | tr -d ' ')"
if [ "$rc" -eq 0 ] && [ -z "$out" ] && [ -z "$err" ] && [ "$logc" = "1" ]; then
    pass "no-node -> rc0, silent, 1 log line"
else
    fail "no-node -> rc=$rc out='$out' err='$err' logc=$logc"
fi
rm -rf "$tmp"

echo "== run-node: the wired plugin-hook launcher chain fires with node off PATH (HIMMEL-2047) =="
# HIMMEL-2015 gave run-node.sh to individual project hook scripts but left
# every marketplace/plugins/himmel-ops/hooks/hooks.json entry (and
# .claude/settings.json's) invoking run-hook-with-bash.js via a bare `node` —
# which the 2026-08-22 nvm-windows migration proved unresolvable mid-session,
# silently dropping every SessionEnd guardrail. HIMMEL-2047 routes those
# launchers through this same resolver (wire-plugin-hook-bash.mjs's
# wiredCommand()); this reproduces one verbatim, with node off PATH, and
# proves the target hook script still runs end to end.
tmp="$(mktemp -d "${TMPDIR:-/tmp}/test-run-node-plugin-launcher.XXXXXX")"
real_node="$(command -v node 2>/dev/null || true)"
if [ -z "$real_node" ]; then
    echo "  SKIP: no real node on PATH to resolve against"
else
    node_dir="$(dirname "$real_node")"
    hook_dir="$tmp/hooks"; mkdir -p "$hook_dir"
    cat > "$hook_dir/marker-hook.sh" <<'EOF'
#!/usr/bin/env bash
echo HOOK_FIRED
EOF
    chmod +x "$hook_dir/marker-hook.sh"
    # The exact launcher shape wire-plugin-hook-bash.mjs wires into every
    # hooks.json entry (and wire-hook-bash.mjs into settings.json): sourced
    # run-node.sh resolves node at runtime and execs run-hook-with-bash.js,
    # which spawns the target hook under a resolved bash. Only the final
    # target is swapped for the harmless marker script above.
    cmd=". \"$REPO_ROOT/scripts/lib/run-node.sh\" \"$REPO_ROOT/scripts/hooks/run-hook-with-bash.js\" \"$hook_dir/marker-hook.sh\""
    out="$(PATH="$UTILS_DIR" RESOLVE_NODE_PROBE_DIRS="$node_dir" NVM_SYMLINK="" RESOLVE_NODE_NVM4W_DIR="" RESOLVE_NODE_NVM_ROOT="$tmp/none" FNM_DIR="$tmp/none" HOME="${HOME:-}" CLAUDE_PROJECT_DIR="$REPO_ROOT" bash -c "$cmd" 2>"$tmp/err.txt")"
    rc=$?
    err="$(cat "$tmp/err.txt")"
    if [ "$rc" -eq 0 ] && [ "$out" = "HOOK_FIRED" ]; then
        pass "plugin-hook launcher fires with node off PATH (out='$out')"
    else
        fail "plugin-hook launcher with node off PATH -> rc=$rc out='$out' err='$err'"
    fi
fi
rm -rf "$tmp"

echo
if [ "$failures" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$failures FAILURE(S)"; exit 1; fi
