#!/usr/bin/env bash
# test-usage-cache-identity.sh -- tests for scripts/lib/usage-cache-identity.sh
# (HIMMEL-1712): the shared account-identity helper stamped onto and compared
# against the statusline usage cache. Scratch HOME, nothing real is read.
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fails=0
passes=0
check() { # name got want
    if [ "$2" = "$3" ]; then passes=$((passes + 1)); echo "ok - $1"
    else fails=$((fails + 1)); echo "FAIL - $1: [$2] != [$3]"; fi
}

td=$(mktemp -d "${TMPDIR:-/tmp}/usage-cache-id-test.XXXXXX") || { echo "FAIL: mktemp" >&2; exit 1; }
trap '[ -n "${td:-}" ] && [ -d "$td" ] && rm -rf "$td"' EXIT
export HOME="$td/home"
mkdir -p "$HOME"
unset CLAUDE_ACCOUNT_CONFIG

# shellcheck source=scripts/lib/usage-cache-identity.sh
. "$here/usage-cache-identity.sh"

printf '%s' '{"oauthAccount":{"accountUuid":"uuid-account-A"}}' > "$HOME/.claude.json"
h=$(current_account_hash)
check "current_account_hash: 16 lowercase hex chars" "$([[ "$h" =~ ^[0-9a-f]{16}$ ]] && echo yes)" "yes"
h2=$(current_account_hash)
check "current_account_hash: stable across calls" "$h2" "$h"

printf '%s' '{"oauthAccount":{"accountUuid":"uuid-account-B"}}' > "$HOME/.claude.json"
hb=$(current_account_hash)
check "current_account_hash: differs for a different uuid" "$([ "$hb" != "$h" ] && echo yes)" "yes"

rm -f "$HOME/.claude.json"
check "current_account_hash: missing config -> empty" "$(current_account_hash)" ""

printf '%s' '{"oauthAccount":{}}' > "$HOME/.claude.json"
check "current_account_hash: missing accountUuid field -> empty" "$(current_account_hash)" ""

printf '%s' '{"oauthAccount":{"accountUuid":"uuid-account-A"}}' > "$HOME/.claude.json"
current=$(current_account_hash)

cache="$td/cache.json"
printf '%s' "{\"account\":\"$current\"}" > "$cache"
usage_cache_account_mismatch "$cache"; rc=$?
check "usage_cache_account_mismatch: matching account -> 1 (trusted)" "$rc" "1"

printf '%s' '{"account":"0000000000000000"}' > "$cache"
usage_cache_account_mismatch "$cache"; rc=$?
check "usage_cache_account_mismatch: mismatched account -> 0 (UNKNOWN)" "$rc" "0"

printf '%s' '{"five_hour":{}}' > "$cache"
usage_cache_account_mismatch "$cache"; rc=$?
check "usage_cache_account_mismatch: no account field (old schema) -> 0 (UNKNOWN)" "$rc" "0"

printf '%s' '{"account":""}' > "$cache"
usage_cache_account_mismatch "$cache"; rc=$?
check "usage_cache_account_mismatch: empty account field -> 0 (UNKNOWN)" "$rc" "0"

rm -f "$HOME/.claude.json"
printf '%s' "{\"account\":\"$current\"}" > "$cache"
usage_cache_account_mismatch "$cache"; rc=$?
check "usage_cache_account_mismatch: current identity undeterminable -> 0 (UNKNOWN)" "$rc" "0"

echo "$passes passed, $fails failed"
[ "$fails" -eq 0 ]
