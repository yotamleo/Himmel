#!/usr/bin/env bash
# Smoke test for scripts/guardrails/phi-egress-lib.sh (HIMMEL-1776 fence
# parity by extraction). Exercises the two predicates shared by
# graphify-fence.sh and refresh-graph-map.sh in isolation; the consumer-level
# regression coverage lives in test-graphify-fence.sh and
# test-refresh-graph-map.sh.
#
# Usage: bash scripts/guardrails/test-phi-egress-lib.sh
# Exit 0 if all cases pass, 1 otherwise.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
LIB="$REPO_ROOT/scripts/guardrails/phi-egress-lib.sh"

if [ ! -f "$LIB" ]; then
    echo "FAIL: $LIB not found"
    exit 1
fi

# shellcheck source=/dev/null
. "$LIB"

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

WS="$(mktemp -d "${TMPDIR:-/tmp}/phi-egress-lib-test.XXXXXX")"
trap 'rm -rf "$WS"' EXIT

echo "== _guard_file_readable =="
if ! _guard_file_readable "$WS/absent"; then pass "absent file -> false"; else fail "absent file -> expected false"; fi

: > "$WS/readable.txt"
if _guard_file_readable "$WS/readable.txt"; then pass "readable file -> true"; else fail "readable file -> expected true"; fi

mkdir -p "$WS/adir"
if ! _guard_file_readable "$WS/adir"; then pass "directory (not a regular file) -> false"; else fail "directory -> expected false"; fi

: > "$WS/unreadable.txt"
if chmod 000 "$WS/unreadable.txt" 2>/dev/null && [ ! -r "$WS/unreadable.txt" ]; then
    if ! _guard_file_readable "$WS/unreadable.txt"; then
        pass "existing-but-unreadable file -> false (fail-closed, not treated as absent)"
    else
        fail "existing-but-unreadable file -> expected false"
    fi
    chmod 644 "$WS/unreadable.txt"
else
    echo "  SKIP  existing-but-unreadable case (chmod 000 did not deny read on this fs/user, e.g. root or Windows ACL passthrough)"
fi

echo "== _guard_endpoint_host =="
h="$(_guard_endpoint_host "https://api.anthropic.com/v1/messages")"
if [ "$h" = "api.anthropic.com" ]; then
    pass "https URL with path -> exact lowercased host"
else
    fail "https URL with path -> expected api.anthropic.com got [$h]"
fi

h="$(_guard_endpoint_host "HTTPS://API.ANTHROPIC.COM")"
if [ "$h" = "api.anthropic.com" ]; then
    pass "uppercase scheme+host -> lowercased"
else
    fail "uppercase scheme+host -> expected api.anthropic.com got [$h]"
fi

h="$(_guard_endpoint_host "https://user:pass@api.z.ai:443/x?y=1#z")"
if [ "$h" = "api.z.ai" ]; then
    pass "userinfo+port+query+fragment all stripped -> bare host"
else
    fail "userinfo+port+query+fragment -> expected api.z.ai got [$h]"
fi

if ! _guard_endpoint_host "" >/dev/null 2>&1; then pass "empty URL -> rc=1"; else fail "empty URL -> expected rc=1"; fi

if ! _guard_endpoint_host "http://api.anthropic.com" >/dev/null 2>&1; then
    pass "plaintext http:// -> rc=1 (fail-closed, not implicitly trusted)"
else
    fail "plaintext http:// -> expected rc=1"
fi

if ! _guard_endpoint_host "api.anthropic.com" >/dev/null 2>&1; then
    pass "scheme-less value -> rc=1"
else
    fail "scheme-less value -> expected rc=1"
fi

if ! _guard_endpoint_host 'https://evil.com\@api.anthropic.com' >/dev/null 2>&1; then
    pass "backslash-bearing URL -> rc=1 (HIMMEL-1049 userinfo-smuggling guard)"
else
    fail "backslash-bearing URL -> expected rc=1"
fi

out="$(_guard_endpoint_host "https://api.anthropic.com.evil.example")"
if [ "$out" = "api.anthropic.com.evil.example" ] && [ "$out" != "api.anthropic.com" ]; then
    pass "lookalike host is returned VERBATIM, not normalized to the real host (caller's exact-match allowlist must reject it)"
else
    fail "lookalike host -> expected verbatim api.anthropic.com.evil.example got [$out]"
fi

if [ "$failures" -eq 0 ]; then
    echo "OK: all cases passed"
    exit 0
else
    echo "FAIL: $failures case(s) failed"
    exit 1
fi
