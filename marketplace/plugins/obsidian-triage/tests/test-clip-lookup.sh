#!/usr/bin/env bash
# Tests for clip-lookup.mjs — vault resolution, enumeration, URL match,
# thinness predicate. Filesystem-only; no network.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../tools/lib/clip-lookup.mjs"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- fixture vault ---
mkdir -p "$tmp/vault/.obsidian"
mkdir -p "$tmp/vault/Clippings/_done/2026-06"
mkdir -p "$tmp/vault/Clippings/_synthesis"
cat > "$tmp/vault/Clippings/inbox-tweet.md" <<'EOF'
---
title: "A tweet"
source: "https://x.com/jane/status/123"
type: tweet
---
## The Idea
Real captured tweet text here, definitely not a placeholder.
EOF
cat > "$tmp/vault/Clippings/_synthesis/should-skip.md" <<'EOF'
---
source: "https://example.com/synth"
---
synthesis page, must be excluded
EOF

node --check "$lib"   # parses
LIBURL="$(node -e 'console.log(require("url").pathToFileURL(process.argv[1]).href)' "$lib")"

# enumeration: inbox tweet present, _synthesis excluded
cat > "$tmp/t1a.mjs" <<'JS'
const { resolveVaultRoot, listClipFiles } = await import(process.env.LIB);
const root = resolveVaultRoot();
if (!root) { console.error("FAIL: vault not resolved"); process.exit(1); }
const files = listClipFiles(root).map(f => f.split(/[\\/]/).pop());
if (!files.includes("inbox-tweet.md")) { console.error("FAIL: missing inbox clip", files); process.exit(1); }
if (files.includes("should-skip.md")) { console.error("FAIL: _synthesis not excluded", files); process.exit(1); }
console.log("OK enumeration");
JS
LIB="$LIBURL" OBSIDIAN_VAULT_PATH="$tmp/vault" node "$tmp/t1a.mjs" || { echo "enumeration test FAILED"; exit 1; }

# no-vault degrade: HOME with no .obsidian → null
cat > "$tmp/t1b.mjs" <<'JS'
const { resolveVaultRoot } = await import(process.env.LIB);
const r = resolveVaultRoot();
if (r !== null) { console.error("FAIL: expected null, got", r); process.exit(1); }
console.log("OK no-vault degrade");
JS
LIB="$LIBURL" HOME="$tmp/empty" USERPROFILE="$tmp/empty" OBSIDIAN_VAULT_PATH="" node "$tmp/t1b.mjs" || { echo "degrade test FAILED"; exit 1; }

echo "TASK1 PASS"

# --- Task 2: URL + status-id match key ---
# match by /i/status/ form against a clip filed as /<user>/status/
cat > "$tmp/vault/Clippings/_done/2026-06/done-tweet.md" <<'EOF'
---
title: "Done tweet"
source: "https://x.com/jane/status/999"
harvest_status: ok
harvested_at: 2026-06-20
---
## The Idea
Real archived content.
EOF

cat > "$tmp/t2.mjs" <<'JS'
const { findHarvestedClipForUrl } = await import(process.env.LIB);
// canonical-different but same status id
const hit = findHarvestedClipForUrl(null, "https://x.com/i/status/999");
if (!hit) { console.error("FAIL: status-id match missed"); process.exit(1); }
if (hit.status !== "ok") { console.error("FAIL: status not ok", hit); process.exit(1); }
// miss returns null, not throw
const miss = findHarvestedClipForUrl(null, "https://x.com/x/status/000");
if (miss !== null) { console.error("FAIL: expected null miss", miss); process.exit(1); }
console.log("OK url+statusid match");
JS
LIB="$LIBURL" OBSIDIAN_VAULT_PATH="$tmp/vault" node "$tmp/t2.mjs" || { echo "match test FAILED"; exit 1; }

# --- Task 3: per-type isThinClipBody predicate ---
# the GitHub Packages billing skeleton (article) → THIN
cat > "$tmp/vault/Clippings/gh-packages.md" <<'EOF'
---
title: "GitHub Packages billing"
source: "https://docs.github.com/en/billing/concepts/product-billing/github-packages"
type: "research"
---
# GitHub Packages billing

## Core Argument
*(What is the single biggest claim this article is making?)*

## Key Evidence
-
-

## Questions This Raises
-

## Related Notes
- [[]]

## Source
[Read here](https://docs.github.com/en/billing/concepts/product-billing/github-packages)
EOF

cat > "$tmp/t3.mjs" <<'JS'
const { isThinClipBody, findHarvestedClipForUrl } = await import(process.env.LIB);
const NL = "\n";
const skeleton = NL + "# X" + NL + "## Core Argument" + NL + "*(What is the single biggest claim?)*" + NL + "## Key Evidence" + NL + "- " + NL + "- " + NL + "## Source" + NL + "[Read here](u)";
if (isThinClipBody(skeleton, "research") !== true) { console.error("FAIL: skeleton not thin"); process.exit(1); }
const rich = NL + "## Core Argument" + NL + "GitHub Packages bills by storage GB-month and data transfer GB." + NL + "## Key Evidence" + NL + "- 500MB free for Free tier";
if (isThinClipBody(rich, "research") !== false) { console.error("FAIL: rich flagged thin"); process.exit(1); }
// tweet branch must equal the real isThinTweetBody (delegation check)
const richTweet = NL + "## The Idea" + NL + "A real substantive tweet body that has content.";
if (isThinClipBody(richTweet, "tweet") !== false) { console.error("FAIL: rich tweet flagged thin"); process.exit(1); }
// integration: the skeleton clip → enriched:false
const hit = findHarvestedClipForUrl(null, "https://docs.github.com/en/billing/concepts/product-billing/github-packages");
if (!hit || hit.enriched !== false) { console.error("FAIL: gh-packages should be found+thin", hit); process.exit(1); }
console.log("OK thinness predicate");
JS
LIB="$LIBURL" OBSIDIAN_VAULT_PATH="$tmp/vault" node "$tmp/t3.mjs" || { echo "thinness test FAILED"; exit 1; }

# delegation equivalence: tweet branch == real isThinTweetBody on the same inputs
fxturl="$(node -e 'console.log(require("url").pathToFileURL(process.argv[1]).href)' "$here/../tools/fxtwitter-enrich.mjs")"
cat > "$tmp/t3b.mjs" <<'JS'
const { isThinClipBody } = await import(process.env.LIB);
const { isThinTweetBody } = await import(process.env.FXT);
for (const body of ["\n## The Idea\nreal content here.", "\n*(placeholder)*", ""]) {
  if (isThinClipBody(body, "tweet") !== isThinTweetBody(body)) {
    console.error("FAIL: tweet branch diverges from isThinTweetBody", JSON.stringify(body));
    process.exit(1);
  }
}
console.log("OK tweet-branch delegation");
JS
LIB="$LIBURL" FXT="$fxturl" node "$tmp/t3b.mjs" || { echo "delegation test FAILED"; exit 1; }

# --- Task 4: runbook-callable CLI shims ---
cli="$here/../tools/clip-lookup-cli.mjs"
node --check "$cli"
out="$(LIB='' OBSIDIAN_VAULT_PATH="$tmp/vault" node "$cli" "https://x.com/i/status/999")"
echo "$out" | grep -q '"status":"ok"' || { echo "FAIL: cli hit json: $out"; exit 1; }
miss="$(OBSIDIAN_VAULT_PATH="$tmp/vault" node "$cli" "https://x.com/none/status/1")"
[ "$miss" = "null" ] || { echo "FAIL: cli miss should be null: $miss"; exit 1; }
echo "OK clip-lookup-cli"

# is-thin-cli: the gh-packages skeleton clip → thin; the inbox tweet → rich
tcli="$here/../tools/is-thin-cli.mjs"
node --check "$tcli"
[ "$(node "$tcli" "$tmp/vault/Clippings/gh-packages.md")" = "thin" ] || { echo "FAIL: gh-packages not thin"; exit 1; }
[ "$(node "$tcli" "$tmp/vault/Clippings/inbox-tweet.md")" = "rich" ] || { echo "FAIL: inbox tweet not rich"; exit 1; }
[ "$(node "$tcli" "$tmp/does-not-exist.md")" = "rich" ] || { echo "FAIL: missing file should fail-open rich"; exit 1; }
echo "OK is-thin-cli"

# --- Task 6: consolidate telegram-clip + dedup-sweep onto the shared key ---
root="$here/../tools"
# (a) both consumers import the shared lib
grep -q "clip-lookup.mjs" "$root/telegram-clip.mjs" || { echo "FAIL: telegram-clip not importing shared lib"; exit 1; }
grep -q "clip-lookup.mjs" "$root/dedup-sweep.mjs"   || { echo "FAIL: dedup-sweep not importing shared lib"; exit 1; }
# (b) NEGATIVE guard: the inline match decision is GONE from alreadyFiledByUrl.
#     The single source of truth is matchesUrl/clipUrlKeys; the old
#     "tweetStatusId(...)===wantId" comparison must no longer live in the tool.
grep -qE 'tweetStatusId\([^)]*\)\s*===' "$root/telegram-clip.mjs" && { echo "FAIL: inline status-id compare still in telegram-clip"; exit 1; }
echo "OK single-source guards"

# (c) behavior-equivalence: alreadyFiledByUrl still matches /i/status/<id> form.
cat > "$tmp/t6.mjs" <<'JS'
const { alreadyFiledByUrl } = await import(process.env.TGTOOL);
// CLIPDIR has a _done clip filed as x.com/jane/status/999
const hit = alreadyFiledByUrl(process.env.CLIPDIR, "https://x.com/i/status/999");
if (!hit) { console.error("FAIL: alreadyFiledByUrl lost /i/status/ matching"); process.exit(1); }
// negative: a totally unrelated URL must NOT match
const miss = alreadyFiledByUrl(process.env.CLIPDIR, "https://example.com/unrelated");
if (miss) { console.error("FAIL: alreadyFiledByUrl false-positive", miss); process.exit(1); }
console.log("OK alreadyFiledByUrl equivalence");
JS
tgurl="$(node -e 'console.log(require("url").pathToFileURL(process.argv[1]).href)' "$root/telegram-clip.mjs")"
# IMPORTANT: alreadyFiledByUrl's FIRST arg is the Clippings dir, not the vault root.
TGTOOL="$tgurl" CLIPDIR="$tmp/vault/Clippings" node "$tmp/t6.mjs" || { echo "equivalence test FAILED"; exit 1; }

echo "ALL PASS"
