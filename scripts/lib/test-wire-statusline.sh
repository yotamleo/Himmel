#!/usr/bin/env bash
# Hermetic test for wire-statusline.sh (HIMMEL-359 / HIMMEL-718). No network,
# temp dir only. HIMMEL-718 Task 4.1 switched the command to the hud renderer
# (node) + added the .env extra-cmd gate + the dropped hud config.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$HERE/wire-statusline.sh"
REPO_ROOT="$(cd -- "$HERE/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

# 1. fresh file gets a valid hud statusLine + the extra-cmd gate.
bash "$HELPER" "$TMP/s1.json" "/c/Users/me/himmel" >/dev/null
[ "$(jq -r .statusLine.type "$TMP/s1.json")" = "command" ] || fail "fresh type"
[ "$(jq -r .statusLine.command "$TMP/s1.json")" = 'node "/c/Users/me/himmel/marketplace/plugins/claude-hud/dist/index.js"' ] || fail "fresh command"
[ "$(jq -r .env.CLAUDE_HUD_ALLOW_EXTRA_CMD "$TMP/s1.json")" = "1" ] || fail "extra-cmd gate set"
echo "ok 1 fresh file"

# 2. existing keys preserved, incl. pre-existing .env keys (non-destructive merge)
echo '{"theme":"dark","hooks":{"PreToolUse":[1]},"env":{"CR_PROFILE":"paid"}}' > "$TMP/s2.json"
bash "$HELPER" "$TMP/s2.json" "/c/Users/me/himmel" >/dev/null
[ "$(jq -r .theme "$TMP/s2.json")" = "dark" ] || fail "theme preserved"
[ "$(jq -r '.hooks.PreToolUse[0]' "$TMP/s2.json")" = "1" ] || fail "hooks preserved"
[ "$(jq -r .env.CR_PROFILE "$TMP/s2.json")" = "paid" ] || fail "pre-existing env key preserved"
[ "$(jq -r .env.CLAUDE_HUD_ALLOW_EXTRA_CMD "$TMP/s2.json")" = "1" ] || fail "extra-cmd gate merged"
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
[ "$(jq -r .statusLine.command "$TMP/s4.json")" = 'node "C:/Users/me/himmel/marketplace/plugins/claude-hud/dist/index.js"' ] || fail "backslash normalize"
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

# 10. hud config dropped next to settings.json with <himmel-path> SUBSTITUTED.
# Uses the REAL himmel clone so the source himmel-config.json exists.
sdir="$TMP/cfgdrop"
bash "$HELPER" "$sdir/settings.json" "$REPO_ROOT" >/dev/null
dropped="$sdir/plugins/claude-hud/config.json"
[ -f "$dropped" ] || fail "hud config not dropped"
jq -e . "$dropped" >/dev/null 2>&1 || fail "dropped config not valid JSON"
grep -q '<himmel-path>' "$dropped" && fail "placeholder <himmel-path> left in dropped config"
grep -qF "$REPO_ROOT" "$dropped" || fail "real himmel path not substituted into dropped config"
[ "$(jq -r .statusLine.command "$sdir/settings.json")" = "node \"$REPO_ROOT/marketplace/plugins/claude-hud/dist/index.js\"" ] || fail "command not node w/ real path"
echo "ok 10 hud config dropped + substituted"

# 11. config drop is idempotent too (deterministic)
B="$(cat "$dropped")"
bash "$HELPER" "$sdir/settings.json" "$REPO_ROOT" >/dev/null
[ "$B" = "$(cat "$dropped")" ] || fail "config drop not idempotent"
echo "ok 11 config drop idempotent"

echo "ALL PASS"
