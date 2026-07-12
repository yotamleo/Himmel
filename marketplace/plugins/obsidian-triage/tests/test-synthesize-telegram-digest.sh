#!/usr/bin/env bash
# Integration test: synthesize-stubs --apply emits the LUNA-91 promotion digest.
#
# Contract (design §8 + §12.F, Jira LUNA-91 acceptance):
#   - promoting telegram-origin evidence clips writes ONE batched digest reply
#     per originating chat to <vault>/.synthesize-stubs.telegram-digest.json
#     (NOT one per promotion).
#   - a re-run that promotes nothing new clears the stale digest (sends nothing).
#   - non-telegram clips trigger NO digest.
#   - --no-telegram-digest (migration backfill) suppresses the digest entirely.

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOL="$PLUGIN_DIR/tools/synthesize-stubs.mjs"

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

# A telegram-origin evidence clip sharing tag $4, with chat/msg provenance.
tg_clip() { # vault name author url tag chat msg
    local v="$1" name="$2" author="$3" url="$4" tag="$5" chat="$6" msg="$7"
    cat > "$v/Clippings/_evidence/$name" <<EOF
---
title: "tg $name"
author: $author
source: $url
harvest_url_canonical: $url
type: article
processed: true
triaged_at: 2026-06-28
evidence_kind:
  - concepts
clipped_via: telegram
telegram_sender: "op"
telegram_msg_id: "$msg"
telegram_chat_id: "$chat"
tags:
  - $tag
---
clip $name
EOF
}

# A non-telegram (web-clipper) evidence clip.
web_clip() { # vault name author url tag
    cat > "$1/Clippings/_evidence/$2" <<EOF
---
title: "web $2"
author: $3
source: $4
harvest_url_canonical: $4
type: article
processed: true
triaged_at: 2026-06-28
evidence_kind:
  - concepts
tags:
  - $5
---
clip $2
EOF
}

mkvault() {
    local v="$1"
    mkdir -p "$v/Clippings/_evidence" "$v/30-Resources/Concepts" "$v/60-Maps" "$v/.obsidian"
}

# ── Vault A: two telegram-origin clips on one concept → 1 stub, 1 digest ──────
A="$(mktemp -d)"; trap 'rm -rf "$A" "$B" "$C" "$E"' EXIT
mkvault "$A"
tg_clip "$A" tg1.md "Alice R" "https://alpha.com/x"  "agent-loops" 555 11
tg_clip "$A" tg2.md "Bob W"   "https://beta.org/y"   "agent-loops" 555 12
DIGEST_A="$A/.synthesize-stubs.telegram-digest.json"

echo "Test 1: apply promotes telegram clips → exactly one digest reply"
node "$TOOL" "$A" --apply >/dev/null 2>&1
if [ -f "$DIGEST_A" ]; then f=yes; else f=no; fi
assert "digest file written" "yes" "$f"

n_replies=$(node -e 'const j=require(process.argv[1]); console.log(j.replies.length)' "$DIGEST_A" 2>/dev/null)
assert "exactly ONE reply for two promotions (batched, not per-promotion)" "1" "$n_replies"

chat=$(node -e 'const j=require(process.argv[1]); console.log(j.replies[0].chat_id)' "$DIGEST_A" 2>/dev/null)
assert "reply targets the originating chat 555" "555" "$chat"

reply_to=$(node -e 'const j=require(process.argv[1]); console.log(j.replies[0].reply_to)' "$DIGEST_A" 2>/dev/null)
assert "reply threads under the most recent msg id (12)" "12" "$reply_to"

has_text=$(node -e 'const j=require(process.argv[1]); console.log(/Saved → now a subject/.test(j.replies[0].text)?"yes":"no")' "$DIGEST_A" 2>/dev/null)
assert "reply text announces the new subject" "yes" "$has_text"

echo "Test 2: re-run promotes nothing new → stale digest cleared (sends nothing)"
node "$TOOL" "$A" --apply >/dev/null 2>&1
if [ -f "$DIGEST_A" ]; then f=present; else f=cleared; fi
assert "digest file removed on no-op re-run" "cleared" "$f"

# ── Vault B: non-telegram clips → stub created, but NO digest ─────────────────
B="$(mktemp -d)"
mkvault "$B"
web_clip "$B" w1.md "Carol H" "https://gamma.com/p" "vector-db"
web_clip "$B" w2.md "Dave K"  "https://delta.org/q" "vector-db"
DIGEST_B="$B/.synthesize-stubs.telegram-digest.json"

echo "Test 3: non-telegram promotions produce NO digest"
out_b="$(node "$TOOL" "$B" --apply 2>&1)"
# sanity: a stub was actually created (otherwise the test proves nothing)
if printf '%s' "$out_b" | grep -qE '✓ .*30-Resources/Concepts'; then f=yes; else f=no; fi
assert "a stub was created from the web clips (test is meaningful)" "yes" "$f"
if [ -f "$DIGEST_B" ]; then f=present; else f=absent; fi
assert "no digest file for non-telegram promotions" "absent" "$f"

# ── Vault C: --no-telegram-digest suppresses (migration backfill) ─────────────
C="$(mktemp -d)"
mkvault "$C"
tg_clip "$C" tg1.md "Erin V"  "https://eps.com/a"  "rag-pipeline" 777 21
tg_clip "$C" tg2.md "Frank D" "https://zed.org/b"  "rag-pipeline" 777 22
DIGEST_C="$C/.synthesize-stubs.telegram-digest.json"

echo "Test 4: --no-telegram-digest suppresses the digest"
node "$TOOL" "$C" --apply --no-telegram-digest >/dev/null 2>&1
if [ -f "$DIGEST_C" ]; then f=present; else f=absent; fi
assert "no digest written under --no-telegram-digest" "absent" "$f"

# ── Vault E: real-bridge COMPOSITE telegram_msg_id, NO separate chat_id ──────
# Some bridges file chat+message into one composite id. The digest must derive
# the chat + numeric reply target from it end-to-end — no telegram_chat_id, no
# backfill (the pre-LUNA-91 clips still work).
E="$(mktemp -d)"
mkvault "$E"
comp_clip() { # name author url tag composite_msg_id
    cat > "$E/Clippings/_evidence/$1" <<EOF
---
title: "comp $1"
author: $2
source: $3
harvest_url_canonical: $3
type: article
processed: true
triaged_at: 2026-06-28
evidence_kind:
  - concepts
clipped_via: telegram
telegram_sender: "1087968824"
telegram_msg_id: "$5"
tags:
  - $4
---
clip $1
EOF
}
comp_clip e1.md "Gina P" "https://one.com/x" "voice-ui" "telegram-tg-group_-1003985279697-1782605997"
comp_clip e2.md "Hal R"  "https://two.org/y" "voice-ui" "tg-group_-1003985279697-1782605414-7"
DIGEST_E="$E/.synthesize-stubs.telegram-digest.json"

echo "Test 5: composite telegram_msg_id (no chat_id) → digest with derived chat + numeric reply_to"
node "$TOOL" "$E" --apply >/dev/null 2>&1
if [ -f "$DIGEST_E" ]; then f=yes; else f=no; fi
assert "digest written from composite-id telegram clips" "yes" "$f"
chat_e=$(node -e 'const j=require(process.argv[1]); console.log(j.replies[0].chat_id)' "$DIGEST_E" 2>/dev/null)
assert "chat derived from the composite id" "-1003985279697" "$chat_e"
reply_e=$(node -e 'const j=require(process.argv[1]); console.log(j.replies[0].reply_to)' "$DIGEST_E" 2>/dev/null)
assert "reply_to is the numeric message id (most recent)" "1782605997" "$reply_e"

echo "Test 6: structural — synthesize-stubs runbook documents the digest send"
if grep -qF 'telegram-digest.json' "$PLUGIN_DIR/commands/synthesize-stubs.md"; then f=yes; else f=no; fi
assert "synthesize-stubs.md documents the telegram digest reply step" "yes" "$f"

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -gt 0 ] && exit 1 || exit 0
