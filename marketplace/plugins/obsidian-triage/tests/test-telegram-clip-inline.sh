#!/usr/bin/env bash
# Task 6: telegram-clip inline fxtwitter enrich for X clips.
# Filing a tweet message → clip born rich (## The Idea). Enrich failure → clip
# still filed as a stub (filing never throws).
set -euo pipefail
cd "$(dirname "$0")/.."

pass=0; fail=0
ck() { if eval "$2"; then echo "  PASS  $1"; pass=$((pass+1)); else echo "  FAIL  $1"; fail=$((fail+1)); fi; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/.obsidian" "$tmp/Clippings"

# fixture: a normal tweet with real text + author
cat > "$tmp/fxt-ok.json" <<'EOF'
{"code":200,"tweet":{"text":"Hermes x Obsidian is the most powerful AI memory system.","author":{"screen_name":"aiedge_","name":"AI Edge"},"is_note_tweet":false,"likes":3,"views":40}}
EOF
# fixture: a failure (code 404 → fxt ok:false)
cat > "$tmp/fxt-fail.json" <<'EOF'
{"code":404,"message":"NOT_FOUND"}
EOF

# --- Case 1: tweet message, enrich succeeds → clip born rich ---
FXT_FIXTURE="$tmp/fxt-ok.json" node tools/telegram-clip.mjs \
  --sender tester --msg-id 900001 --ts 2026-06-13T00:00:00Z \
  --text "https://x.com/i/status/2065290507224485973" --vault "$tmp" >/dev/null
clip1=$(ls "$tmp"/Clippings/telegram-900001-*.md)
ck "X clip was filed" "[ -f \"$clip1\" ]"
ck "filed clip has ## The Idea (born rich)" "grep -q '^## The Idea' \"$clip1\""
ck "filed clip has tweet text" "grep -q 'Hermes x Obsidian' \"$clip1\""
ck "filed clip has enriched_at" "grep -q '^enriched_at:' \"$clip1\""

# --- Case 2: enrich fails → filing STILL succeeds as a stub (no throw) ---
set +e
FXT_FIXTURE="$tmp/fxt-fail.json" node tools/telegram-clip.mjs \
  --sender tester --msg-id 900002 --ts 2026-06-13T00:00:00Z \
  --text "https://x.com/i/status/2064882870037225762" --vault "$tmp" >/dev/null 2>"$tmp/err2.txt"
rc=$?
set -e
ck "filing exits 0 even when enrich fails" "[ $rc -eq 0 ]"
clip2=$(ls "$tmp"/Clippings/telegram-900002-*.md)
ck "stub clip was filed despite enrich failure" "[ -f \"$clip2\" ]"
ck "stub clip has NO ## The Idea (enrich failed, kept as stub)" "! grep -q '^## The Idea' \"$clip2\""
# F3: the in-band partial/fail (processClip RETURNS {glyph:'~'} on a 404) must
# surface a WARN — it does not throw, so the catch-only path never fired before.
ck "enrich failure surfaces WARN inline enrich on stderr" "grep -q 'WARN inline enrich' \"$tmp/err2.txt\""

# --- Case 3: non-tweet (article) message → no enrich attempted, files fine ---
FXT_FIXTURE="$tmp/fxt-ok.json" node tools/telegram-clip.mjs \
  --sender tester --msg-id 900003 --ts 2026-06-13T00:00:00Z \
  --text "https://example.com/some-article" --vault "$tmp" >/dev/null
clip3=$(ls "$tmp"/Clippings/telegram-900003-*.md)
ck "non-tweet clip filed" "[ -f \"$clip3\" ]"
ck "non-tweet clip not enriched" "! grep -q '^enriched_at:' \"$clip3\""

echo ""
echo "test-telegram-clip-inline: $pass passed, $fail failed"
[ "$fail" -eq 0 ] && echo "test-telegram-clip-inline OK" || exit 1
