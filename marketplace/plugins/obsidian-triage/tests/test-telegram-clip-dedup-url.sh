#!/usr/bin/env bash
# Dedup-at-ingest: telegram-clip skips a URL that duplicates an existing clip.
#
# Today the tool dedups only by telegram_msg_id (the same MESSAGE re-forwarded).
# This covers the URL/tweet dedup: two DIFFERENT messages sharing a URL — or an
# X-tweet reachable via two path forms (x.com/i/status/<id> telegram forward vs
# x.com/<user>/status/<id> browser clip) — file only once.
#
# Match key: X URLs → numeric status id; non-X URLs → canonical URL; note → none.
# Scope: Clippings/ inbox (depth ≤2) AND _done/ (recursive). Matches against each
# clip's source: / harvest_url_canonical: frontmatter.
#
# Cross-platform: bash on Linux/macOS/Git-Bash. Uses node (not bun) for CI.
set -u -o pipefail
cd "$(dirname "$0")/.." || exit 1

SCRIPT="tools/telegram-clip.mjs"
pass=0; fail=0
# ckgrep DESC PATTERN — PASS if $out (set by the caller's `run`) matches PATTERN.
ckgrep() { if printf '%s' "$out" | grep -q "$2"; then echo "  PASS  $1"; pass=$((pass+1)); else echo "  FAIL  $1"; fail=$((fail+1)); fi; }
# ckcount DESC GLOB N — PASS if exactly N inbox clips match GLOB.
ckcount() { local n; n=$(find "$tmp/Clippings" -maxdepth 1 -name "$2" | wc -l | tr -d ' '); if [ "$n" = "$3" ]; then echo "  PASS  $1"; pass=$((pass+1)); else echo "  FAIL  $1 (got $n, want $3)"; fail=$((fail+1)); fi; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/.obsidian" "$tmp/Clippings" "$tmp/Clippings/_done/2026-05" "$tmp/Clippings/sub" "$tmp/Clippings/_synthesis"

# fxtwitter fixture so a non-dup X write enriches offline (no network).
cat > "$tmp/fxt-ok.json" <<'EOF'
{"code":200,"tweet":{"text":"some tweet text","author":{"screen_name":"u","name":"U"},"is_note_tweet":false,"likes":1,"views":1}}
EOF

# --- fixture: an existing inbox X clip (browser-clip /user/status/ form) ---
cat > "$tmp/Clippings/existing-inbox.md" <<'EOF'
---
title: "existing inbox tweet"
source: https://x.com/someuser/status/111
date_clipped: 2026-05-28
type: tweet
tags: []
---
# existing inbox tweet
body
EOF

# --- fixture: an existing graduated clip in _done/ (still owns its URL) ---
cat > "$tmp/Clippings/_done/2026-05/existing-done.md" <<'EOF'
---
title: "graduated tweet"
source: https://x.com/anotheruser/status/222
date_clipped: 2026-05-20
type: tweet
processed: true
---
# graduated tweet
body
EOF

# --- fixture: a clip whose URL lives only in harvest_url_canonical: ---
cat > "$tmp/Clippings/existing-canon-key.md" <<'EOF'
---
title: "canon-key tweet"
harvest_url_canonical: https://x.com/u/status/333
date_clipped: 2026-05-21
type: tweet
---
# canon-key tweet
body
EOF

# --- fixture: a non-X article clip (canonical-URL match) ---
cat > "$tmp/Clippings/existing-article.md" <<'EOF'
---
title: "an article"
source: https://example.com/some-article
date_clipped: 2026-05-22
type: article
---
# an article
body
EOF

# --- fixture: a clip one level deep (inbox depth 2) ---
cat > "$tmp/Clippings/sub/existing-subdir.md" <<'EOF'
---
title: "subdir tweet"
source: https://x.com/u/status/444
date_clipped: 2026-05-23
type: tweet
---
# subdir tweet
body
EOF

# --- fixture: a synthesis page (MUST be excluded from the dedup scan) ---
cat > "$tmp/Clippings/_synthesis/synth-page.md" <<'EOF'
---
title: "a synthesis MOC"
source: https://x.com/u/status/555
date_clipped: 2026-05-24
type: note
---
# a synthesis MOC
This page references a tweet it does not own.
EOF

# --- fixture: a quoted source: value (the real LUNA-2 Web Clipper shape) ---
cat > "$tmp/Clippings/existing-quoted.md" <<'EOF'
---
title: "quoted source tweet"
source: "https://x.com/u/status/666"
date_clipped: 2026-05-25
type: tweet
---
# quoted source tweet
body
EOF

# --- fixture: a graduated non-X article whose URL lives only in harvest_url_canonical: ---
cat > "$tmp/Clippings/_done/2026-05/existing-article-done.md" <<'EOF'
---
title: "graduated article"
harvest_url_canonical: https://example.com/grad-article
date_clipped: 2026-05-19
type: article
processed: true
---
# graduated article
body
EOF

run() { FXT_FIXTURE="$tmp/fxt-ok.json" node "$SCRIPT" --vault "$tmp" "$@" 2>"$tmp/err.txt"; }

# --- Case 1: X dup via the i/status form matches an inbox /user/status clip ---
out="$(run --sender t --msg-id 5001 --text 'https://x.com/i/status/111')"
ckgrep "X i/status dup matches inbox user/status clip" 'dup-url'
ckcount "no duplicate written for inbox X dup" 'telegram-5001-*.md' 0
ckgrep "dup-url report names the matched relpath" 'existing-inbox.md'

# --- Case 2: X dup matches a clip in _done/ (recursive scope) ---
out="$(run --sender t --msg-id 5002 --text 'https://x.com/i/status/222')"
ckgrep "X dup matches clip in _done/" 'dup-url'
ckcount "no duplicate written for _done X dup" 'telegram-5002-*.md' 0

# --- Case 3: X dup matches via harvest_url_canonical: frontmatter ---
out="$(run --sender t --msg-id 5003 --text 'https://x.com/i/status/333')"
ckgrep "X dup matches via harvest_url_canonical key" 'dup-url'
ckcount "no duplicate written for harvest_url_canonical dup" 'telegram-5003-*.md' 0

# --- Case 4: non-X canonical-URL match (tracking params stripped) ---
out="$(run --sender t --msg-id 5004 --text 'https://example.com/some-article?utm_source=telegram')"
ckgrep "non-X canonical dup-url match" 'dup-url'
ckcount "no duplicate written for non-X dup" 'telegram-5004-*.md' 0

# --- Case 5: a NON-matching X url files normally (different status id) ---
out="$(run --sender t --msg-id 5005 --text 'https://x.com/i/status/999')"
ckgrep "non-dup X url files normally" '✓'
ckcount "non-dup X url wrote one clip" 'telegram-5005-*.md' 1

# --- Case 6: a non-matching non-X url files normally ---
out="$(run --sender t --msg-id 5006 --text 'https://example.com/totally-different')"
ckgrep "non-dup article url files normally" '✓'
ckcount "non-dup article url wrote one clip" 'telegram-5006-*.md' 1

# --- Case 7: a note (no URL) skips the url-dedup check entirely ---
out="$(run --sender t --msg-id 5007 --text 'just a plain thought, no link')"
ckgrep "note (no url) files normally (url-dedup skipped)" '✓'
ckcount "note wrote one clip" 'telegram-5007-*.md' 1

# --- Case 8: X dup matches an inbox clip one level deep (depth-2 boundary) ---
out="$(run --sender t --msg-id 5008 --text 'https://x.com/i/status/444')"
ckgrep "X dup matches a clip in Clippings/sub/ (depth 2)" 'dup-url'
ckcount "no duplicate written for subdir X dup" 'telegram-5008-*.md' 0

# --- Case 9: a URL living ONLY in _synthesis/ is excluded → clip files normally ---
out="$(run --sender t --msg-id 5009 --text 'https://x.com/i/status/555')"
ckgrep "URL only in _synthesis/ does NOT dedup (excluded from scan)" '✓'
ckcount "_synthesis-only URL wrote one clip" 'telegram-5009-*.md' 1

# --- Case 10: a quoted source: value (real LUNA-2 clip shape) still matches ---
out="$(run --sender t --msg-id 5010 --text 'https://x.com/i/status/666')"
ckgrep "X dup matches a quoted source: value" 'dup-url'
ckcount "no duplicate written for quoted-source X dup" 'telegram-5010-*.md' 0

# --- Case 11: non-X canonical match via harvest_url_canonical in _done/ ---
out="$(run --sender t --msg-id 5011 --text 'https://example.com/grad-article?utm_source=x')"
ckgrep "non-X dup matches harvest_url_canonical in _done/" 'dup-url'
ckcount "no duplicate written for non-X _done dup" 'telegram-5011-*.md' 0

echo ""
echo "test-telegram-clip-dedup-url: $pass passed, $fail failed"
[ "$fail" -eq 0 ] && echo "test-telegram-clip-dedup-url OK" || exit 1
