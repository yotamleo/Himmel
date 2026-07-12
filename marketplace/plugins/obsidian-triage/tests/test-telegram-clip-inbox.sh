#!/usr/bin/env bash
# LUNA-91 (a): telegram-clip files captures as INBOX-STATE and carries the
# chat-id provenance the promotion digest needs.
#
# Per the 3-state derivation (design §12.A — state = folder + existing markers,
# NO `lifecycle:` enum), a telegram capture is inbox simply by living top-level
# in Clippings/ with no `processed:`/`lifecycle:` marker. This test locks that
# contract (so a future refactor can't silently start stamping a marker) and
# verifies `--chat-id` adds `telegram_chat_id` provenance (omitted when absent,
# for backward compatibility).

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOL="$PLUGIN_DIR/tools/telegram-clip.mjs"

pass=0
fail=0
assert() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS  $desc"; pass=$((pass+1))
    else
        echo "  FAIL  $desc"
        echo "         expected: $expected"
        echo "         actual:   $actual"
        fail=$((fail+1))
    fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/.obsidian"

echo "Test 1: clip lands top-level in Clippings/ with chat-id provenance"
node "$TOOL" --vault "$tmp" --sender op --msg-id 4242 --chat-id 555 \
    --ts 2026-06-28T10:00:00Z --text 'a thought worth keeping' >/dev/null 2>&1
clip="$(find "$tmp/Clippings" -maxdepth 1 -name 'telegram-4242-*.md')"
if [ -n "$clip" ] && [ -f "$clip" ]; then f=yes; else f=no; fi
assert "clip written at top level of Clippings/ (inbox by folder placement)" "yes" "$f"

echo "Test 2: NO processed/lifecycle marker (inbox-state is derived, §12.A)"
if grep -qE '^processed:' "$clip"; then f=present; else f=absent; fi
assert "no 'processed:' marker on a fresh capture" "absent" "$f"
if grep -qE '^lifecycle:' "$clip"; then f=present; else f=absent; fi
assert "no 'lifecycle:' enum (dropped per design §12.A)" "absent" "$f"

echo "Test 3: provenance keys present (chat_id targets the promotion reply)"
if grep -qE '^telegram_chat_id: "?555"?$' "$clip"; then f=yes; else f=no; fi
assert "telegram_chat_id recorded from --chat-id" "yes" "$f"
if grep -qE '^telegram_msg_id: "?4242"?$' "$clip"; then f=yes; else f=no; fi
assert "telegram_msg_id recorded" "yes" "$f"
if grep -qE '^clipped_via: telegram$' "$clip"; then f=yes; else f=no; fi
assert "clipped_via: telegram recorded (digest origin filter)" "yes" "$f"

echo "Test 4: --chat-id is optional (backward-compatible — omitted key)"
node "$TOOL" --vault "$tmp" --sender op --msg-id 9999 \
    --ts 2026-06-28T11:00:00Z --text 'no chat id here' >/dev/null 2>&1
clip2="$(find "$tmp/Clippings" -maxdepth 1 -name 'telegram-9999-*.md')"
if grep -qE '^telegram_chat_id:' "$clip2"; then f=present; else f=absent; fi
assert "telegram_chat_id omitted when --chat-id not passed" "absent" "$f"

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -gt 0 ] && exit 1 || exit 0
