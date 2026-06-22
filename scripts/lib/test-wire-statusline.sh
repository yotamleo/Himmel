#!/usr/bin/env bash
# Hermetic test for wire-statusline.sh (HIMMEL-359). No network, temp dir only.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$HERE/wire-statusline.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

# 1. fresh file gets a valid statusLine
bash "$HELPER" "$TMP/s1.json" "/c/Users/me/himmel" >/dev/null
[ "$(jq -r .statusLine.type "$TMP/s1.json")" = "command" ] || fail "fresh type"
[ "$(jq -r .statusLine.command "$TMP/s1.json")" = 'bash "/c/Users/me/himmel/scripts/where-are-we/statusline.sh"' ] || fail "fresh command"
echo "ok 1 fresh file"

# 2. existing keys preserved
echo '{"theme":"dark","hooks":{"PreToolUse":[1]}}' > "$TMP/s2.json"
bash "$HELPER" "$TMP/s2.json" "/c/Users/me/himmel" >/dev/null
[ "$(jq -r .theme "$TMP/s2.json")" = "dark" ] || fail "theme preserved"
[ "$(jq -r '.hooks.PreToolUse[0]' "$TMP/s2.json")" = "1" ] || fail "hooks preserved"
[ "$(jq -r .statusLine.type "$TMP/s2.json")" = "command" ] || fail "statusLine added"
echo "ok 2 existing keys preserved"

# 3. idempotent
bash "$HELPER" "$TMP/s3.json" "/c/Users/me/himmel" >/dev/null
A="$(cat "$TMP/s3.json")"
bash "$HELPER" "$TMP/s3.json" "/c/Users/me/himmel" >/dev/null
[ "$A" = "$(cat "$TMP/s3.json")" ] || fail "not idempotent"
echo "ok 3 idempotent"

# 4. backslash himmel path normalized to forward slashes
bash "$HELPER" "$TMP/s4.json" 'C:\Users\me\himmel' >/dev/null
[ "$(jq -r .statusLine.command "$TMP/s4.json")" = 'bash "C:/Users/me/himmel/scripts/where-are-we/statusline.sh"' ] || fail "backslash normalize"
echo "ok 4 backslash normalized"

# 5. overwrites a stale statusLine (authoritative)
echo '{"statusLine":{"type":"command","command":"OLD"}}' > "$TMP/s5.json"
bash "$HELPER" "$TMP/s5.json" "/c/Users/me/himmel" >/dev/null
[ "$(jq -r .statusLine.command "$TMP/s5.json")" != "OLD" ] || fail "stale not refreshed"
echo "ok 5 stale refreshed"

# 6. empty file → treated as {}, gets a valid statusLine (gemini-1/2)
: > "$TMP/s6.json"
bash "$HELPER" "$TMP/s6.json" "/c/Users/me/himmel" >/dev/null
[ "$(jq -r .statusLine.type "$TMP/s6.json")" = "command" ] || fail "empty file not handled"
echo "ok 6 empty file handled"

# 7. non-empty INVALID json → refuse (exit non-zero), do not clobber
printf '{not valid' > "$TMP/s7.json"
if bash "$HELPER" "$TMP/s7.json" "/c/Users/me/himmel" >/dev/null 2>&1; then
  fail "invalid json was not refused"
fi
[ "$(cat "$TMP/s7.json")" = '{not valid' ] || fail "invalid json was clobbered"
echo "ok 7 invalid json refused"

# 8. whitespace-only file (non-empty bytes, all blank) → treated as {}
printf '  \n\t ' > "$TMP/s8.json"
bash "$HELPER" "$TMP/s8.json" "/c/Users/me/himmel" >/dev/null
[ "$(jq -r .statusLine.type "$TMP/s8.json")" = "command" ] || fail "whitespace-only not handled"
echo "ok 8 whitespace-only handled"

# 9. nested parent dir created when absent
bash "$HELPER" "$TMP/nested/deep/s9.json" "/c/Users/me/himmel" >/dev/null
[ "$(jq -r .statusLine.type "$TMP/nested/deep/s9.json")" = "command" ] || fail "nested dir not created"
echo "ok 9 nested parent dir created"

echo "ALL PASS"
