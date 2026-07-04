#!/usr/bin/env bash
# Tests for HIMMEL-660 follow-dossier.mjs — corpus evidence gather +
# dossier write/read round-trip. Filesystem-only; no network. Cross-platform:
# bash on Linux/macOS/Git-Bash. Uses node (not bun) for CI.

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$(cd "$SCRIPT_DIR/../tools" && pwd)"
LIB="$TOOLS_DIR/lib/follow-dossier.mjs"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

pass=0
fail=0
assert() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS  $desc"; pass=$((pass+1))
    else
        echo "  FAIL  $desc"; echo "         expected: $expected"; echo "         actual:   $actual"; fail=$((fail+1))
    fi
}

node --check "$LIB" 2>/dev/null && s=ok || s=fail
assert "follow-dossier.mjs parses" ok "$s"

# NB: vault paths go through env vars (not embedded literally in the .mjs
# source) — MSYS/Git-Bash auto-converts POSIX paths in argv/env when
# invoking a native Windows node.exe, but NOT plain text written into a
# heredoc-generated file (see Task 1's report for the full gotcha).
lib_url="$(node -e 'console.log(require("url").pathToFileURL(process.argv[1]).href)' "$LIB")"

# -- Test 1: buildCorpusEvidence ---------------------------------------------
echo "Test 1: buildCorpusEvidence"

vault="$tmpdir/vault"
mkdir -p "$vault/.obsidian"
mkdir -p "$vault/Clippings"

cat > "$vault/Clippings/clip-x-1.md" <<'EOF'
---
title: "clip 1"
author:
  - "@x"
source: "https://x.com/x/status/1"
date_clipped: 2026-06-01
type: tweet
tags: [crypto]
tweet_stats: { likes: 10 }
---
## The Idea
First captured tweet text for handle x, definitely not a placeholder.
EOF

cat > "$vault/Clippings/clip-x-2.md" <<'EOF'
---
title: "clip 2"
tweet_author: "x"
source: "https://x.com/x/status/2"
date_clipped: 2026-06-11
type: tweet
tags: []
tweet_stats: { likes: 10 }
---
## The Idea
Second captured tweet text for handle x, definitely not a placeholder.
EOF

# unrelated clip (different handle) must not be counted
cat > "$vault/Clippings/clip-other.md" <<'EOF'
---
title: "clip other"
author:
  - "@someoneelse"
source: "https://x.com/someoneelse/status/9"
date_clipped: 2026-06-05
type: tweet
tags: []
---
## The Idea
Unrelated tweet text, must not be counted for handle x.
EOF

cat > "$tmpdir/evidence.mjs" <<EOF
import { buildCorpusEvidence } from "$lib_url";
const e = buildCorpusEvidence(process.env.FD_VAULT, "x");
console.log("CLIP_COUNT=" + e.clip_count);
console.log("SAMPLE_LEN=" + e.sample_tweets.length);
console.log("CRYPTO_TAGGED=" + e.crypto_tagged);
console.log("CADENCE_DAYS=" + e.cadence_days);
console.log("STATS_LIKES=" + (e.sample_tweets[0] && e.sample_tweets[0].stats ? e.sample_tweets[0].stats.likes : "MISSING"));
EOF
out1="$(FD_VAULT="$vault" node "$tmpdir/evidence.mjs" 2>&1)"
echo "$out1" | grep -q 'CLIP_COUNT=2' && r=yes || r=no; assert "clip_count==2" yes "$r"
echo "$out1" | grep -q 'SAMPLE_LEN=2' && r=yes || r=no; assert "sample_tweets.length==2" yes "$r"
echo "$out1" | grep -q 'CRYPTO_TAGGED=true' && r=yes || r=no; assert "crypto_tagged==true" yes "$r"
echo "$out1" | grep -q 'CADENCE_DAYS=10' && r=yes || r=no; assert "cadence_days==10 (median gap, 2026-06-01 to 2026-06-11)" yes "$r"
echo "$out1" | grep -q 'STATS_LIKES=10' && r=yes || r=no; assert "sample_tweets[0].stats.likes==10" yes "$r"

# -- Test 2: emptyDossier / writeDossier / readDossier round-trip -----------
echo "Test 2: write/read round-trip"

vault2="$tmpdir/vault2"
mkdir -p "$vault2/.obsidian"

cat > "$tmpdir/roundtrip.mjs" <<EOF
import { existsSync } from "node:fs";
import { emptyDossier, writeDossier, readDossier } from "$lib_url";
const d = emptyDossier("@Y", { clipCount: 3, inList: true });
d.corpus.clip_count = 3;
d.corpus.sample_tweets = [{ text: "hi", stats: { likes: 1 } }];
const path = writeDossier(process.env.FD_VAULT2, d);
console.log("WROTE_EXISTS=" + existsSync(path));
const back = readDossier(process.env.FD_VAULT2, "y");
console.log("HANDLE_MATCH=" + (back && back.handle === d.handle));
console.log("CORPUS_CLIP_COUNT_MATCH=" + (back && back.corpus.clip_count === d.corpus.clip_count));
console.log("MISSING_HANDLE=" + (readDossier(process.env.FD_VAULT2, "nobody") === null));
EOF
out2="$(FD_VAULT2="$vault2" node "$tmpdir/roundtrip.mjs" 2>&1)"
echo "$out2" | grep -q 'WROTE_EXISTS=true' && r=yes || r=no; assert "writeDossier creates the file" yes "$r"
echo "$out2" | grep -q 'HANDLE_MATCH=true' && r=yes || r=no; assert "readDossier round-trips handle" yes "$r"
echo "$out2" | grep -q 'CORPUS_CLIP_COUNT_MATCH=true' && r=yes || r=no; assert "readDossier round-trips corpus.clip_count" yes "$r"
echo "$out2" | grep -q 'MISSING_HANDLE=true' && r=yes || r=no; assert "readDossier returns null for absent handle" yes "$r"

# -- Test 3: extractShortLinks -----------------------------------------------
echo "Test 3: extractShortLinks"

cat > "$tmpdir/shortlinks.mjs" <<EOF
import { extractShortLinks } from "$lib_url";
const body = "check my repo https://t.co/abc123 and course https://t.co/XyZ789 now";
const links = extractShortLinks(body);
console.log("COUNT=" + links.length);
console.log("HAS_FIRST=" + links.includes("https://t.co/abc123"));
console.log("HAS_SECOND=" + links.includes("https://t.co/XyZ789"));
console.log("NONE_ON_PLAIN=" + (extractShortLinks("no short links here, just github.com/x/bar").length === 0));
console.log("EMPTY_SAFE=" + (extractShortLinks("").length === 0 && extractShortLinks(null).length === 0));
EOF
out3="$(node "$tmpdir/shortlinks.mjs" 2>&1)"
echo "$out3" | grep -q 'COUNT=2' && r=yes || r=no; assert "extractShortLinks: finds both t.co links" yes "$r"
echo "$out3" | grep -q 'HAS_FIRST=true' && r=yes || r=no; assert "extractShortLinks: returns first t.co url verbatim" yes "$r"
echo "$out3" | grep -q 'HAS_SECOND=true' && r=yes || r=no; assert "extractShortLinks: returns second t.co url verbatim" yes "$r"
echo "$out3" | grep -q 'NONE_ON_PLAIN=true' && r=yes || r=no; assert "extractShortLinks: no t.co -> empty array" yes "$r"
echo "$out3" | grep -q 'EMPTY_SAFE=true' && r=yes || r=no; assert "extractShortLinks: empty/null input -> empty array" yes "$r"

# -- Results summary -----------------------------------------------------
total=$((pass + fail))
echo ""
echo "Results: $pass / $total passed, $fail failed."
[ "$fail" -eq 0 ]
