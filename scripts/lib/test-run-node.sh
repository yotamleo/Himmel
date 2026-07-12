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

UTILS_DIR="$(dirname "$(command -v sort)")"

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

echo "== run-node: args pass through + stdout =="
tmp="$(mktemp -d)"; make_fake_node "$tmp/bin"
out="$(PATH="$UTILS_DIR" RESOLVE_NODE_PROBE_DIRS="$tmp/bin" RESOLVE_NODE_NVM_ROOT="$tmp/none" FNM_DIR="$tmp/none" bash "$RUN" "$tmp/echo-args.js" A B)"
if [ "$out" = "args:A B" ]; then pass "args -> '$out'"; else fail "args -> '$out'"; fi
rm -rf "$tmp"

echo "== run-node: exit code propagates =="
tmp="$(mktemp -d)"; make_fake_node "$tmp/bin"
PATH="$UTILS_DIR" RESOLVE_NODE_PROBE_DIRS="$tmp/bin" RESOLVE_NODE_NVM_ROOT="$tmp/none" FNM_DIR="$tmp/none" bash "$RUN" "$tmp/exit42.js" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 42 ]; then pass "exit -> 42"; else fail "exit -> $rc (want 42)"; fi
rm -rf "$tmp"

echo "== run-node: stdin reaches the child =="
tmp="$(mktemp -d)"; make_fake_node "$tmp/bin"
out="$(printf 'PAYLOAD-123' | PATH="$UTILS_DIR" RESOLVE_NODE_PROBE_DIRS="$tmp/bin" RESOLVE_NODE_NVM_ROOT="$tmp/none" FNM_DIR="$tmp/none" bash "$RUN" "$tmp/echo-stdin.js")"
if [ "$out" = "PAYLOAD-123" ]; then pass "stdin -> '$out'"; else fail "stdin -> '$out'"; fi
rm -rf "$tmp"

echo "== run-node: no node -> silent, exit 0, one log line =="
tmp="$(mktemp -d)"; cdir="$tmp/claude"
out="$(PATH="$UTILS_DIR" RESOLVE_NODE_PROBE_DIRS="" RESOLVE_NODE_NVM_ROOT="$tmp/none" FNM_DIR="$tmp/none" CLAUDE_DIR="$cdir" bash "$RUN" "$tmp/caveman-activate.js" 2>"$tmp/err.txt")"
rc=$?
err="$(cat "$tmp/err.txt")"
logc=0; [ -f "$cdir/himmel-node.log" ] && logc="$(wc -l < "$cdir/himmel-node.log" | tr -d ' ')"
if [ "$rc" -eq 0 ] && [ -z "$out" ] && [ -z "$err" ] && [ "$logc" = "1" ]; then
    pass "no-node -> rc0, silent, 1 log line"
else
    fail "no-node -> rc=$rc out='$out' err='$err' logc=$logc"
fi
rm -rf "$tmp"

echo
if [ "$failures" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$failures FAILURE(S)"; exit 1; fi
