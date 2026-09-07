#!/usr/bin/env bash
# Integration test for HIMMEL-2621 — a quote-tweet must keep its OWN text.
#
# Before the fix the section chooser was an exclusive if/else-if chain, so any
# tweet carrying a `quote` never reached the body-fill path: the clip recorded
# the QUOTED author's words and dropped the clipped author's own text (for
# `is_note_tweet` payloads, an entire long-form note).
#
# Drives the full processClip write path against a fixture-backed fetch
# (FXT_FIXTURE shim — no network) over temp vaults:
#   - note tweet + quote  → `## The Idea` carries the note text AND the
#     `### Quoted tweet (@handle)` section is still there.
#   - article-shaped quote → the quote section renders the article title +
#     preview, never a bare t.co shortener.
#   - media-shaped quote   → a `quoted media: <n> item(s)` marker, never a
#     bare t.co shortener.
#   - URL-only quote with no article/media → the real external link SURVIVES
#     (the forbidden thing is the shortener, not the URL); a t.co-only quote
#     with nothing else degrades to the no-text marker instead.
#   - the HIMMEL-256 post-body-fill injection re-screen RUNS on the new quote
#     path, and is handed the just-written body (stub screener records it).
#   - `--reenrich-quote-only` backfill: an already-enriched quote-only clip is
#     skipped by a normal run and re-processed under the switch — `## The Idea`
#     comes back, the stale quote-context section is replaced (not duplicated),
#     and `enriched_at` is bumped rather than erased.
#   - controls: the switch skips a clip that already has `## The Idea`, skips
#     a clip that is not an fxtwitter quote clip, and skips a quote clip that
#     already carries its own text elsewhere in the body (HIMMEL-2621 CR
#     finding: isQuoteOnlyClip must also require isThinTweetBody, or it
#     duplicates text an unaffected clip already has).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$(cd "$SCRIPT_DIR/../tools" && pwd)"
SCRIPT="$TOOLS_DIR/fxtwitter-enrich.mjs"

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/cr-quote-own-text.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT

fail=0
check() {
  local desc="$1" cond="$2"
  if [ "$cond" = "yes" ]; then
    echo "  PASS  $desc"
  else
    echo "  FAIL  $desc"
    fail=1
  fi
}

# The FXT_FIXTURE shim returns ONE fixture for every clip in a run, so each
# fixture gets its own single-clip vault.
vault_note="$tmpdir/vault-note"
vault_article="$tmpdir/vault-article"
vault_media="$tmpdir/vault-media"
vault_backfill="$tmpdir/vault-backfill"
vault_skip_idea="$tmpdir/vault-skip-idea"
vault_skip_plain="$tmpdir/vault-skip-plain"
vault_dryrun="$tmpdir/vault-dryrun"
vault_link="$tmpdir/vault-link"
vault_tco="$tmpdir/vault-tco"
vault_own_text="$tmpdir/vault-own-text"
mkdir -p "$vault_note/Clippings" "$vault_article/Clippings" "$vault_media/Clippings" \
         "$vault_backfill/Clippings" "$vault_skip_idea/Clippings" "$vault_skip_plain/Clippings" \
         "$vault_dryrun/Clippings" "$vault_link/Clippings" "$vault_tco/Clippings" \
         "$vault_own_text/Clippings"

# Stub screener: records the body it was handed, then exits 0 (clean). Proves
# the HIMMEL-256 re-screen ran on the new quote path with the NEW body.
screener_log="$tmpdir/screener-saw.txt"
cat >"$tmpdir/stub-screener.py" <<'EOF'
import sys, os
# argv: <screener> --scan-only <clip>
clip = sys.argv[-1]
with open(os.environ["SCREENER_LOG"], "a", encoding="utf-8") as log:
    log.write(open(clip, encoding="utf-8").read())
sys.exit(0)
EOF

# -- Clip 1: thin telegram X stub whose tweet is a NOTE with a quote -----
cat >"$vault_note/Clippings/tweet-note-quote.md" <<'EOF'
---
title: "tweet from x.com/i/status/111"
source: https://x.com/i/status/111
type: tweet
tags: []
clipped_via: telegram
---
# tweet from x.com/i/status/111

https://x.com/i/status/111

## Source
[x](https://x.com/i/status/111)
EOF

# `text` carries t.co links already expanded; `raw_text.text` keeps the
# shortener — mirrors the live api.fxtwitter.com payload for
# x.com/stretchcloud/status/2096439998539321653.
cat >"$tmpdir/fixture-note-quote.json" <<'EOF'
{"code":200,"tweet":{
  "text":"Portal routes cheap assistant models for the mechanical work and keeps the frontier model for judgement. Routing to capability level is a legitimate architecture pattern.\n\nhttps://x.com/quotedki/status/222",
  "raw_text":{"text":"Portal routes cheap assistant models for the mechanical work and keeps the frontier model for judgement. Routing to capability level is a legitimate architecture pattern.\n\nhttps://t.co/4Kd8y24ILo"},
  "author":{"screen_name":"stretchcloud","name":"Stretch"},
  "is_note_tweet":true,"likes":10,"views":99,
  "quote":{"url":"https://x.com/quotedki/status/222",
    "text":"The quoted author published the internal setup their engineers use.",
    "raw_text":{"text":"The quoted author published the internal setup their engineers use."},
    "author":{"screen_name":"quotedki"},
    "media":{"all":[{"type":"photo"}]}}}}
EOF

# -- Clip 2: quote is an X Article (quote text is a bare URL) ------------
cat >"$vault_article/Clippings/tweet-article-quote.md" <<'EOF'
---
title: "tweet from x.com/i/status/333"
source: https://x.com/i/status/333
type: tweet
tags: []
clipped_via: telegram
---
# tweet from x.com/i/status/333

https://x.com/i/status/333

## Source
[x](https://x.com/i/status/333)
EOF

cat >"$tmpdir/fixture-article-quote.json" <<'EOF'
{"code":200,"tweet":{
  "text":"Do this before your next session: read the article, then audit your skills and AGENTS.md files.",
  "author":{"screen_name":"danielmac","name":"Daniel"},
  "is_note_tweet":false,"likes":450,"views":102268,
  "quote":{"url":"https://x.com/pvncher/status/444",
    "text":"https://x.com/i/article/555",
    "raw_text":{"text":"https://t.co/iDl6I25AQu"},
    "author":{"screen_name":"pvncher"},
    "article":{"title":"Rethinking skills and prompts",
      "preview_text":"Coding agents have come a long way, and best practices are changing fast."}}}}
EOF

# -- Clip 3: quote is media-only (no article, quote text is a bare URL) --
cat >"$vault_media/Clippings/tweet-media-quote.md" <<'EOF'
---
title: "tweet from x.com/i/status/666"
source: https://x.com/i/status/666
type: tweet
tags: []
clipped_via: telegram
---
# tweet from x.com/i/status/666

https://x.com/i/status/666

## Source
[x](https://x.com/i/status/666)
EOF

cat >"$tmpdir/fixture-media-quote.json" <<'EOF'
{"code":200,"tweet":{
  "text":"This chart is the whole argument in one picture.",
  "author":{"screen_name":"charter","name":"Charter"},
  "is_note_tweet":false,"likes":3,"views":40,
  "quote":{"url":"https://x.com/shooter/status/777",
    "text":"https://t.co/lZHs4AgZn0",
    "raw_text":{"text":"https://t.co/lZHs4AgZn0"},
    "author":{"screen_name":"shooter"},
    "media":{"all":[{"type":"photo"},{"type":"photo"}]}}}}
EOF

# -- Clip 4: already-enriched quote-only clip (the backfill target) ------
# Byte-shape of the live LUNA clips on HIMMEL-2621: enriched, quote section
# present, NO ## The Idea.
cat >"$vault_backfill/Clippings/tweet-backfill.md" <<'EOF'
---
title: "tweet from x.com/i/status/888"
source: https://x.com/i/status/888
type: tweet
tags: []
clipped_via: telegram
enriched_at: "2026-09-01"
enrichment_source: fxtwitter
tweet_is_note: false
tweet_is_article: false
tweet_has_quote: true
enrichment_status: ok
processed: true
triaged_at: 2026-09-02
---
# tweet from x.com/i/status/888

https://x.com/i/status/888

## Crawled content
<!-- enriched 2026-09-01 via fxtwitter (quote-context) -->

### Quoted tweet (@pvncher)

https://t.co/iDl6I25AQu

[Quoted tweet](https://x.com/pvncher/status/444)

## Source
[x](https://x.com/i/status/888)

## Promotion candidate
<!-- triage 2026-09-02 — do NOT auto-promote -->
- **Suggested target:** `30-Resources/Concepts/`
EOF

cat >"$tmpdir/fixture-backfill.json" <<'EOF'
{"code":200,"tweet":{
  "text":"The backfilled tweet finally records its own words instead of the quoted author's.",
  "author":{"screen_name":"danielmac","name":"Daniel"},
  "is_note_tweet":false,"likes":450,"views":102268,
  "quote":{"url":"https://x.com/pvncher/status/444",
    "text":"https://x.com/i/article/555",
    "raw_text":{"text":"https://t.co/iDl6I25AQu"},
    "author":{"screen_name":"pvncher"},
    "article":{"title":"Rethinking skills and prompts",
      "preview_text":"Coding agents have come a long way, and best practices are changing fast."}}}}
EOF

# -- Clip 5 (control): enriched quote clip that ALREADY has ## The Idea --
cat >"$vault_skip_idea/Clippings/tweet-has-idea.md" <<'EOF'
---
title: "Already rich"
source: https://x.com/i/status/999
type: tweet
tags: []
clipped_via: telegram
enriched_at: "2026-09-01"
enrichment_source: fxtwitter
tweet_has_quote: true
enrichment_status: ok
---
# Already rich

## The Idea
<!-- enriched 2026-09-01 via fxtwitter (text) -->

The clipped author's own words are already here.

## Source
[x](https://x.com/i/status/999)
EOF

# -- Clip 6 (control): enriched fxtwitter clip with NO quote -------------
cat >"$vault_skip_plain/Clippings/tweet-no-quote.md" <<'EOF'
---
title: "Plain enriched tweet"
source: https://x.com/i/status/1010
type: tweet
tags: []
clipped_via: telegram
enriched_at: "2026-09-01"
enrichment_source: fxtwitter
tweet_has_quote: false
enrichment_status: ok
---
# Plain enriched tweet

https://x.com/i/status/1010

## Source
[x](https://x.com/i/status/1010)
EOF

# -- Clip 7: untouched quote-only clip reserved for the DRY-RUN run -----
# Run 7 must assert on a clip that is still an eligible target; reusing the
# run-4b clip would pass vacuously, since that one already has ## The Idea.
cat >"$vault_dryrun/Clippings/tweet-dryrun.md" <<'EOF'
---
title: "tweet from x.com/i/status/1212"
source: https://x.com/i/status/1212
type: tweet
tags: []
clipped_via: telegram
enriched_at: "2026-09-01"
enrichment_source: fxtwitter
tweet_has_quote: true
enrichment_status: ok
---
# tweet from x.com/i/status/1212

https://x.com/i/status/1212

## Crawled content
<!-- enriched 2026-09-01 via fxtwitter (quote-context) -->

### Quoted tweet (@pvncher)

https://t.co/iDl6I25AQu

## Source
[x](https://x.com/i/status/1212)
EOF

# -- Clip 8: quote whose whole text is a real external link -------------
# No article, no media: the URL IS the content, and must survive.
cat >"$vault_link/Clippings/tweet-link-quote.md" <<'EOF'
---
title: "tweet from x.com/i/status/1313"
source: https://x.com/i/status/1313
type: tweet
tags: []
clipped_via: telegram
---
# tweet from x.com/i/status/1313

https://x.com/i/status/1313

## Source
[x](https://x.com/i/status/1313)
EOF

cat >"$tmpdir/fixture-link-quote.json" <<'EOF'
{"code":200,"tweet":{
  "text":"The repo behind the whole thread.",
  "author":{"screen_name":"linker","name":"Linker"},
  "is_note_tweet":false,"likes":9,"views":90,
  "quote":{"url":"https://x.com/tooler/status/1414",
    "text":"https://github.com/example/project",
    "raw_text":{"text":"https://t.co/aBcDeF1234"},
    "author":{"screen_name":"tooler"}}}}
EOF

# -- Clip 9: quote whose only text is a t.co, with nothing else ---------
# No article, no media, no expanded form: the shortener carries nothing, so
# it degrades to the no-text marker rather than being emitted bare.
cat >"$vault_tco/Clippings/tweet-tco-quote.md" <<'EOF'
---
title: "tweet from x.com/i/status/1515"
source: https://x.com/i/status/1515
type: tweet
tags: []
clipped_via: telegram
---
# tweet from x.com/i/status/1515

https://x.com/i/status/1515

## Source
[x](https://x.com/i/status/1515)
EOF

cat >"$tmpdir/fixture-tco-quote.json" <<'EOF'
{"code":200,"tweet":{
  "text":"Quoting a post that fxtwitter could not expand.",
  "author":{"screen_name":"quoter","name":"Quoter"},
  "is_note_tweet":false,"likes":2,"views":20,
  "quote":{"url":"https://x.com/opaque/status/1616",
    "text":"https://t.co/zZzZzZzZzZ",
    "raw_text":{"text":"https://t.co/zZzZzZzZzZ"},
    "author":{"screen_name":"opaque"}}}}
EOF

# -- Clip 10 (control): fxtwitter quote clip with NO ## The Idea but real ---
# own prose already harvested under a ## Summary section. isQuoteOnlyClip
# must NOT treat this as a backfill target — it was never a casualty of the
# old exclusive chooser, so body-filling it would DUPLICATE text it already
# has. Reuses fixture-backfill.json — the switch must skip before any fetch.
cat >"$vault_own_text/Clippings/tweet-own-text.md" <<'EOF'
---
title: "tweet from x.com/i/status/1717"
source: https://x.com/i/status/1717
type: tweet
tags: []
clipped_via: telegram
enriched_at: "2026-09-01"
enrichment_source: fxtwitter
tweet_is_note: false
tweet_is_article: false
tweet_has_quote: true
enrichment_status: ok
---
# tweet from x.com/i/status/1717

The author's own real prose survives here — this clip was never a casualty
of the old exclusive chooser, so the backfill must leave it alone.

## Summary
Additional summary notes captured by an earlier enrichment pass.

## Crawled content
<!-- enriched 2026-09-01 via fxtwitter (quote-context) -->

### Quoted tweet (@pvncher)

https://t.co/iDl6I25AQu

[Quoted tweet](https://x.com/pvncher/status/444)

## Source
[x](https://x.com/i/status/1717)
EOF

# -- Run 1: note tweet + quote ------------------------------------------
SCREENER_LOG="$screener_log" FXT_SCREENER="$tmpdir/stub-screener.py" \
  FXT_FIXTURE="$tmpdir/fixture-note-quote.json" \
  node "$SCRIPT" --vault "$vault_note" >"$tmpdir/run1.out" 2>&1 || true

note_clip="$vault_note/Clippings/tweet-note-quote.md"

grep -q '^## The Idea' "$note_clip" && r=yes || r=no
check "note+quote clip has ## The Idea" "$r"

grep -q 'Routing to capability level is a legitimate architecture pattern' "$note_clip" && r=yes || r=no
check "note+quote clip ## The Idea carries the CLIPPED author's own text" "$r"

grep -q '^### Quoted tweet (@quotedki)' "$note_clip" && r=yes || r=no
check "note+quote clip still has the ### Quoted tweet section" "$r"

grep -q 'The quoted author published the internal setup' "$note_clip" && r=yes || r=no
check "note+quote clip still carries the quoted author's text" "$r"

# The Idea must come BEFORE the Crawled content section.
idea_line="$(grep -n '^## The Idea' "$note_clip" | head -1 | cut -d: -f1 || true)"
crawl_line="$(grep -n '^## Crawled content' "$note_clip" | head -1 | cut -d: -f1 || true)"
if [ -n "$idea_line" ] && [ -n "$crawl_line" ] && [ "$idea_line" -lt "$crawl_line" ]; then r=yes; else r=no; fi
check "note+quote clip orders ## The Idea before ## Crawled content" "$r"

grep -qE '^enriched_at:' "$note_clip" && r=yes || r=no
check "note+quote clip has enriched_at: marker" "$r"

grep -qE '^tweet_has_quote:[[:space:]]*true' "$note_clip" && r=yes || r=no
check "note+quote clip keeps tweet_has_quote: true" "$r"

# title repaired from the telegram placeholder (body-fill path ran)
if grep -qE '^title:.*tweet from x\.com' "$note_clip"; then r=no; else r=yes; fi
check "note+quote clip title repaired (body-fill path ran)" "$r"

# HIMMEL-256: the injection re-screen ran, and saw the NEW body.
[ -s "$screener_log" ] && r=yes || r=no
check "HIMMEL-256 re-screen invoked on the quote path" "$r"

grep -q 'Routing to capability level is a legitimate architecture pattern' "$screener_log" 2>/dev/null && r=yes || r=no
check "HIMMEL-256 re-screen was handed the just-written body-fill text" "$r"

# -- Run 2: article-shaped quote ----------------------------------------
FXT_FIXTURE="$tmpdir/fixture-article-quote.json" \
  node "$SCRIPT" --vault "$vault_article" >"$tmpdir/run2.out" 2>&1 || true

article_clip="$vault_article/Clippings/tweet-article-quote.md"

grep -q 'then audit your skills and AGENTS.md files' "$article_clip" && r=yes || r=no
check "article-quote clip carries the clipped author's own text" "$r"

grep -q 'Rethinking skills and prompts' "$article_clip" && r=yes || r=no
check "article-quote section renders the quoted article title" "$r"

grep -q 'Coding agents have come a long way' "$article_clip" && r=yes || r=no
check "article-quote section renders the quoted article preview" "$r"

# No section whose only content is a shortener URL.
if grep -qE '^https?://t\.co/' "$article_clip"; then r=no; else r=yes; fi
check "article-quote clip has NO bare t.co line" "$r"

# -- Run 3: media-shaped quote ------------------------------------------
FXT_FIXTURE="$tmpdir/fixture-media-quote.json" \
  node "$SCRIPT" --vault "$vault_media" >"$tmpdir/run3.out" 2>&1 || true

media_clip="$vault_media/Clippings/tweet-media-quote.md"

grep -q 'This chart is the whole argument in one picture' "$media_clip" && r=yes || r=no
check "media-quote clip carries the clipped author's own text" "$r"

grep -q 'quoted media: 2 item(s)' "$media_clip" && r=yes || r=no
check "media-quote section renders a quoted-media marker" "$r"

if grep -qE '^https?://t\.co/' "$media_clip"; then r=no; else r=yes; fi
check "media-quote clip has NO bare t.co line" "$r"

# -- Run 4a: backfill target is SKIPPED by a normal run ------------------
# Same rule as runs 5/6/10: byte-identity alone would also pass on a crash,
# so assert the run exited 0 and named the clip as already enriched.
backfill_clip="$vault_backfill/Clippings/tweet-backfill.md"
before_sha="$(sha256sum "$backfill_clip" | cut -d' ' -f1)"

normal_rc=0
FXT_FIXTURE="$tmpdir/fixture-backfill.json" \
  node "$SCRIPT" --vault "$vault_backfill" >"$tmpdir/run4a.out" 2>&1 || normal_rc=$?

after_sha="$(sha256sum "$backfill_clip" | cut -d' ' -f1)"

[ "$normal_rc" -eq 0 ] && r=yes || r=no
check "control: the normal run exited 0 (rc=$normal_rc, not a crash)" "$r"

grep -q 'skipped (already enriched)' "$tmpdir/run4a.out" && r=yes || r=no
check "control: normal run names the backfill target as already enriched" "$r"

[ "$before_sha" = "$after_sha" ] && r=yes || r=no
check "backfill target untouched by a normal run (alreadyEnriched gate holds)" "$r"

# -- Run 4b: --reenrich-quote-only re-processes it -----------------------
SCREENER_LOG="$screener_log" FXT_SCREENER="$tmpdir/stub-screener.py" \
  FXT_FIXTURE="$tmpdir/fixture-backfill.json" \
  node "$SCRIPT" --vault "$vault_backfill" --reenrich-quote-only >"$tmpdir/run4b.out" 2>&1 || true

grep -q '^## The Idea' "$backfill_clip" && r=yes || r=no
check "backfill clip gained ## The Idea" "$r"

grep -q "records its own words instead of the quoted author" "$backfill_clip" && r=yes || r=no
check "backfill clip ## The Idea carries the clipped author's own text" "$r"

crawl_count="$(grep -c '^## Crawled content' "$backfill_clip" || true)"
[ "$crawl_count" = "1" ] && r=yes || r=no
check "backfill clip has exactly ONE ## Crawled content section (got: $crawl_count)" "$r"

if grep -qE '^https?://t\.co/' "$backfill_clip"; then r=no; else r=yes; fi
check "backfill clip's stale bare-t.co quote section was replaced" "$r"

grep -q 'Rethinking skills and prompts' "$backfill_clip" && r=yes || r=no
check "backfill clip quote section re-rendered from the fresh fetch" "$r"

# enriched_at bumped, not erased.
grep -qE '^enriched_at:[[:space:]]*"?[0-9]{4}-[0-9]{2}-[0-9]{2}' "$backfill_clip" && r=yes || r=no
check "backfill clip still has an enriched_at: date (bumped, not erased)" "$r"

if grep -qE '^enriched_at:[[:space:]]*"?2026-09-01' "$backfill_clip"; then r=no; else r=yes; fi
check "backfill clip enriched_at was bumped off the stale date" "$r"

# The corrective backfill must NOT re-open triage verdicts: 170 of the 172
# live targets are already-triaged _evidence clips carrying a triage-authored
# ## Promotion candidate. Clearing processed: there would dump the archive
# back into the triage queue and destroy those recommendations.
grep -q '^processed:' "$backfill_clip" && r=yes || r=no
check "backfill clip: processed: STILL PRESENT (no re-triage reset)" "$r"

grep -q '^triaged_at:' "$backfill_clip" && r=yes || r=no
check "backfill clip: triaged_at: STILL PRESENT (no re-triage reset)" "$r"

grep -q '^## Promotion candidate' "$backfill_clip" && r=yes || r=no
check "backfill clip: ## Promotion candidate STILL PRESENT (no re-triage reset)" "$r"

# Frontmatter still parses as YAML after the re-enrich write.
bf_yaml="$(cd "$TOOLS_DIR" && node -e '
const { readFileSync } = require("node:fs");
import("js-yaml").then((yaml) => {
  const txt = readFileSync(process.argv[1], "utf-8").replace(/\r\n/g, "\n");
  const fmRaw = txt.slice(4, txt.indexOf("\n---\n", 4));
  const fm = yaml.load(fmRaw);
  console.log(fm && typeof fm === "object" ? "yaml-ok" : "yaml-bad");
});
' "$backfill_clip")"
[ "$bf_yaml" = "yaml-ok" ] && r=yes || r=no
check "backfill clip frontmatter still parses as YAML (got: $bf_yaml)" "$r"

# -- Run 5 (control): switch skips a clip that already has ## The Idea ---
# Byte-identity alone is not enough: a crash also leaves the file untouched.
# Assert the run SUCCEEDED and named the clip as skipped too, so a broken
# enricher cannot pass this control by failing early.
idea_clip="$vault_skip_idea/Clippings/tweet-has-idea.md"
idea_before="$(sha256sum "$idea_clip" | cut -d' ' -f1)"
idea_rc=0
FXT_FIXTURE="$tmpdir/fixture-backfill.json" \
  node "$SCRIPT" --vault "$vault_skip_idea" --reenrich-quote-only >"$tmpdir/run5.out" 2>&1 || idea_rc=$?
idea_after="$(sha256sum "$idea_clip" | cut -d' ' -f1)"

[ "$idea_rc" -eq 0 ] && r=yes || r=no
check "control: the ## The Idea skip run exited 0 (rc=$idea_rc, not a crash)" "$r"

grep -q 'skipped (reenrich-quote-only: not a quote-only fxtwitter clip)' "$tmpdir/run5.out" && r=yes || r=no
check "control: run output names the ## The Idea clip as skipped" "$r"

[ "$idea_before" = "$idea_after" ] && r=yes || r=no
check "control: --reenrich-quote-only skips a clip that already has ## The Idea" "$r"

# -- Run 6 (control): switch skips a non-quote fxtwitter clip -----------
plain_clip="$vault_skip_plain/Clippings/tweet-no-quote.md"
plain_before="$(sha256sum "$plain_clip" | cut -d' ' -f1)"
plain_rc=0
FXT_FIXTURE="$tmpdir/fixture-backfill.json" \
  node "$SCRIPT" --vault "$vault_skip_plain" --reenrich-quote-only >"$tmpdir/run6.out" 2>&1 || plain_rc=$?
plain_after="$(sha256sum "$plain_clip" | cut -d' ' -f1)"

[ "$plain_rc" -eq 0 ] && r=yes || r=no
check "control: the non-quote skip run exited 0 (rc=$plain_rc, not a crash)" "$r"

grep -q 'skipped (reenrich-quote-only: not a quote-only fxtwitter clip)' "$tmpdir/run6.out" && r=yes || r=no
check "control: run output names the non-quote clip as skipped" "$r"

[ "$plain_before" = "$plain_after" ] && r=yes || r=no
check "control: --reenrich-quote-only skips a non-quote fxtwitter clip" "$r"

# -- Run 7: --dry-run under the switch names its targets, writes nothing -
# Against an UNTOUCHED, still-eligible clip — the run-4b clip already has
# ## The Idea, so asserting on it would pass even if --dry-run wrote.
dryrun_clip="$vault_dryrun/Clippings/tweet-dryrun.md"
dry_before="$(sha256sum "$dryrun_clip" | cut -d' ' -f1)"
FXT_FIXTURE="$tmpdir/fixture-backfill.json" \
  node "$SCRIPT" --vault "$vault_dryrun" --reenrich-quote-only --dry-run >"$tmpdir/run7.out" 2>&1 || true
dry_after="$(sha256sum "$dryrun_clip" | cut -d' ' -f1)"

grep -q 'would re-enrich (quote-only)' "$tmpdir/run7.out" && r=yes || r=no
check "--dry-run under the switch REPORTS the eligible target" "$r"

[ "$dry_before" = "$dry_after" ] && r=yes || r=no
check "--dry-run under the switch leaves the eligible target byte-identical" "$r"

# -- Run 8: URL-only quote with no article/media — the URL survives ------
FXT_FIXTURE="$tmpdir/fixture-link-quote.json" \
  node "$SCRIPT" --vault "$vault_link" >"$tmpdir/run8.out" 2>&1 || true

link_clip="$vault_link/Clippings/tweet-link-quote.md"

grep -q 'https://github.com/example/project' "$link_clip" && r=yes || r=no
check "URL-only quote keeps its real external link (not discarded)" "$r"

if grep -q '_(no quote text)_' "$link_clip"; then r=no; else r=yes; fi
check "URL-only quote is NOT rendered as _(no quote text)_" "$r"

if grep -qE '^https?://t\.co/' "$link_clip"; then r=no; else r=yes; fi
check "URL-only quote clip has NO bare t.co line" "$r"

# -- Run 9: t.co-only quote with nothing else — degrades, never bare ----
FXT_FIXTURE="$tmpdir/fixture-tco-quote.json" \
  node "$SCRIPT" --vault "$vault_tco" >"$tmpdir/run9.out" 2>&1 || true

tco_clip="$vault_tco/Clippings/tweet-tco-quote.md"

if grep -qE '^https?://t\.co/' "$tco_clip"; then r=no; else r=yes; fi
check "t.co-only quote emits NO bare shortener line" "$r"

grep -q '_(no quote text)_' "$tco_clip" && r=yes || r=no
check "t.co-only quote degrades to the no-text marker" "$r"

# -- Run 10 (control): switch skips a quote clip that already has its own --
# text elsewhere in the body (no ## The Idea, but real prose under
# ## Summary — isThinTweetBody returns false). RED control: relaxing
# isQuoteOnlyClip back to "no ## The Idea" alone (dropping the
# `isThinTweetBody(body)` requirement) makes this clip a backfill target
# again, and this assertion fails because the file is mutated.
own_text_clip="$vault_own_text/Clippings/tweet-own-text.md"
own_text_before="$(sha256sum "$own_text_clip" | cut -d' ' -f1)"
FXT_FIXTURE="$tmpdir/fixture-backfill.json" \
  node "$SCRIPT" --vault "$vault_own_text" --reenrich-quote-only >"$tmpdir/run10.out" 2>&1 || true
own_text_after="$(sha256sum "$own_text_clip" | cut -d' ' -f1)"

[ "$own_text_before" = "$own_text_after" ] && r=yes || r=no
check "control: --reenrich-quote-only skips a quote clip with its own text elsewhere in the body" "$r"

grep -q 'skipped (reenrich-quote-only: not a quote-only fxtwitter clip)' "$tmpdir/run10.out" && r=yes || r=no
check "control: run output names the own-text clip as skipped" "$r"

if [ "$fail" -ne 0 ]; then
  echo ""
  for n in 1 2 3 4a 4b 5 6 7 8 9 10; do
    echo "--- run$n output ---"; cat "$tmpdir/run$n.out" 2>/dev/null || true
  done
  echo "--- note clip ---";     cat "$note_clip"
  echo "--- article clip ---";  cat "$article_clip"
  echo "--- media clip ---";    cat "$media_clip"
  echo "--- backfill clip ---"; cat "$backfill_clip"
  exit 1
fi

echo "test-fxtwitter-quote-own-text OK"
