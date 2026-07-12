#!/usr/bin/env bash
# Smoke test for the opt-in MCP launch gate (marketplace/plugins/*/mcp-gate.sh,
# HIMMEL-591). Mirrors scripts/lib/test-run-bun.sh. Runs every assertion against
# BOTH shipped copies so the two stay byte-identical and neither regresses.
# Usage: bash scripts/lib/test-mcp-gate.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
G1="$REPO_ROOT/marketplace/plugins/luna-correlate/mcp-gate.sh"
G2="$REPO_ROOT/marketplace/plugins/telegram-himmel/mcp-gate.sh"

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

# The command the gate exec's when opted in — prints a sentinel so we can prove
# it ran (or didn't). Absolute path so it needs no PATH.
tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT
SENTINEL="$tmp_root/child.sh"
cat > "$SENTINEL" <<'EOF'
#!/bin/sh
printf 'CHILD-RAN:%s\n' "$*"
EOF
chmod +x "$SENTINEL"

# A child that echoes stdin — MCP is stdio JSON-RPC, so stdin must survive the gate.
STDIN_CHILD="$tmp_root/cat.sh"
printf '#!/bin/sh\ncat\n' > "$STDIN_CHILD"; chmod +x "$STDIN_CHILD"

for GATE in "$G1" "$G2"; do
    [ -f "$GATE" ] || { fail "$GATE not found"; continue; }
    label="${GATE#"$REPO_ROOT"/marketplace/plugins/}"; label="${label%/mcp-gate.sh}"

    echo "== $label: gated OFF (no var set) -> exit 0, child NOT spawned =="
    out="$(env -u HIMMEL_MCP_TELEGRAM -u TELEGRAM_OWN_POLLER -u HIMMEL_MCP_LUNA_CORRELATE \
        bash "$GATE" "HIMMEL_MCP_TELEGRAM TELEGRAM_OWN_POLLER" "$SENTINEL" A B 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ] && [ -z "$out" ]; then pass "off -> rc0, no child"; else fail "off -> rc=$rc out='$out'"; fi

    echo "== $label: var='0' is treated as OFF =="
    out="$(HIMMEL_MCP_TELEGRAM=0 bash "$GATE" "HIMMEL_MCP_TELEGRAM" "$SENTINEL" A 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ] && [ -z "$out" ]; then pass "'0' -> rc0, no child"; else fail "'0' -> rc=$rc out='$out'"; fi

    echo "== $label: gated ON via first var -> child exec'd with args =="
    out="$(HIMMEL_MCP_TELEGRAM=1 bash "$GATE" "HIMMEL_MCP_TELEGRAM TELEGRAM_OWN_POLLER" "$SENTINEL" A B 2>&1)"
    if [ "$out" = "CHILD-RAN:A B" ]; then pass "on(var1) -> '$out'"; else fail "on(var1) -> '$out'"; fi

    echo "== $label: gated ON via second var (any-of semantics) =="
    out="$(TELEGRAM_OWN_POLLER=1 bash "$GATE" "HIMMEL_MCP_TELEGRAM TELEGRAM_OWN_POLLER" "$SENTINEL" X 2>&1)"
    if [ "$out" = "CHILD-RAN:X" ]; then pass "on(var2) -> '$out'"; else fail "on(var2) -> '$out'"; fi

    echo "== $label: a '0' EARLIER in the list does not suppress a later opted-in var =="
    out="$(HIMMEL_MCP_TELEGRAM=0 TELEGRAM_OWN_POLLER=1 bash "$GATE" "HIMMEL_MCP_TELEGRAM TELEGRAM_OWN_POLLER" "$SENTINEL" Z 2>&1)"
    if [ "$out" = "CHILD-RAN:Z" ]; then pass "0-then-1 -> '$out'"; else fail "0-then-1 -> '$out'"; fi

    echo "== $label: stdin survives the gate on the opt-in path (stdio MCP) =="
    out="$(printf 'STDIN-9' | HIMMEL_MCP_TELEGRAM=1 bash "$GATE" "HIMMEL_MCP_TELEGRAM" "$STDIN_CHILD" 2>&1)"
    if [ "$out" = "STDIN-9" ]; then pass "stdin -> '$out'"; else fail "stdin -> '$out'"; fi

    echo "== $label: opted-in exit code propagates from the child =="
    FAKE="$tmp_root/exit7.sh"; printf '#!/bin/sh\nexit 7\n' > "$FAKE"; chmod +x "$FAKE"
    HIMMEL_MCP_TELEGRAM=1 bash "$GATE" "HIMMEL_MCP_TELEGRAM" "$FAKE" >/dev/null 2>&1; rc=$?
    if [ "$rc" -eq 7 ]; then pass "child exit -> 7"; else fail "child exit -> $rc (want 7)"; fi
done

echo "== both gates are byte-identical (no drift) =="
if cmp -s "$G1" "$G2"; then pass "luna-correlate/mcp-gate.sh == telegram-himmel/mcp-gate.sh"; else fail "gates diverged"; fi

echo
if [ "$failures" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$failures FAILURE(S)"; exit 1; fi
