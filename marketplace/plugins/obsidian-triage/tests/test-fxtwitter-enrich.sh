#!/usr/bin/env bash
# Smoke tests for LUNA-33 fxtwitter enricher.
#
# Scope:
#   - script parses (node --check)
#   - package.json declares js-yaml
#   - canonicalisation rules match playwright-crawl-x.mjs
#   - DraftJS→md unit converter: header-two + unstyled + unordered-list-item
#     fixture renders to expected markdown
#   - inline styles (BOLD, ITALIC, CODE) + LINK entity render correctly
#   - idempotency: re-run skips clips with enriched_at:
#   - G-3 byte-identity check is present in the script
#   - --dry-run blocks writes
#   - smoke against cached fxt JSON in /tmp/fxt-compare/ (skip if absent)
#
# Does NOT hit the network.

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$(cd "$SCRIPT_DIR/../tools" && pwd)"
SCRIPT="$TOOLS_DIR/fxtwitter-enrich.mjs"

pass=0
fail=0

assert() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS  $desc"
        pass=$((pass+1))
    else
        echo "  FAIL  $desc"
        echo "         expected: $expected"
        echo "         actual:   $actual"
        fail=$((fail+1))
    fi
}

# -- Test 1: script parses via node --check ------------------------------
echo "Test 1: fxtwitter-enrich.mjs parses"
if [ ! -r "$SCRIPT" ]; then
    assert "script exists" "yes" "no"
else
    assert "script exists" "yes" "yes"
    if node --check "$SCRIPT" 2>/dev/null; then parsed=ok; else parsed=fail; fi
    assert "script parses (node --check)" "ok" "$parsed"
fi

# -- Test 2: package.json declares js-yaml -------------------------------
echo "Test 2: js-yaml dep present"
pkg="$TOOLS_DIR/package.json"
if grep -q '"js-yaml"' "$pkg"; then has_yaml=yes; else has_yaml=no; fi
assert "package.json declares js-yaml" "yes" "$has_yaml"

# -- Test 3: canonicalisation parity with playwright-crawl-x.mjs --------
# Both scripts must use the same /[^/]+/status/\d+ regex + map twitter.com → x.com.
echo "Test 3: canonicalisation rules match playwright-crawl-x.mjs"
xrx='canonicalXUrl'
if grep -q "$xrx" "$SCRIPT" && grep -q "$xrx" "$TOOLS_DIR/playwright-crawl-x.mjs"; then
    has_fn=yes
else
    has_fn=no
fi
assert "canonicalXUrl symbol present in both" "yes" "$has_fn"
# Spot-check: both scripts must strip mobile./www. and map twitter→x.
# Literal substring match — the canonical regex appears in both files.
# playwright-crawl-x.mjs uses (?:x|twitter); fxtwitter-enrich.mjs uses (x|twitter).
for f in "$SCRIPT" "$TOOLS_DIR/playwright-crawl-x.mjs"; do
    if grep -q 'mobile\\\.' "$f" && grep -qE '\(\??:?x\|twitter\)' "$f"; then
        has_rx=yes
    else
        has_rx=no
    fi
    assert "$(basename "$f") strips mobile. + maps twitter→x" "yes" "$has_rx"
done

# -- Test 4: DraftJS→md fixture --------------------------------------
echo "Test 4: DraftJS → markdown converter"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
# Resolve the absolute file:// URL once so node ESM works on Win + POSIX.
script_url="$(node -e 'console.log(require("url").pathToFileURL(process.argv[1]).href)' "$SCRIPT")"
cat >"$tmpdir/draft-test.mjs" <<EOF
import { draftJsToMarkdown } from "$script_url";

// Block-type fixture: header-two + unstyled + unordered-list-item.
const fixture1 = {
  blocks: [
    { type: "header-two", text: "Heading", inlineStyleRanges: [], entityRanges: [], depth: 0 },
    { type: "unstyled", text: "A paragraph.", inlineStyleRanges: [], entityRanges: [], depth: 0 },
    { type: "unordered-list-item", text: "item one", inlineStyleRanges: [], entityRanges: [], depth: 0 },
    { type: "unordered-list-item", text: "item two", inlineStyleRanges: [], entityRanges: [], depth: 0 },
  ],
  entityMap: {},
};
const md1 = draftJsToMarkdown(fixture1);
const expected1 = "## Heading\n\nA paragraph.\n\n- item one\n\n- item two";
console.log("FIXTURE1_MATCH=" + (md1 === expected1 ? "yes" : "no"));
if (md1 !== expected1) {
  console.log("  got     :", JSON.stringify(md1));
  console.log("  expected:", JSON.stringify(expected1));
}

// Inline-style fixture: BOLD wrap on a substring + LINK entity.
const fixture2 = {
  blocks: [{
    type: "unstyled",
    text: "Hello bold world",
    inlineStyleRanges: [{ offset: 6, length: 4, style: "BOLD" }],
    entityRanges: [{ offset: 11, length: 5, key: 0 }],
    depth: 0,
  }],
  entityMap: { "0": { type: "LINK", mutability: "MUTABLE", data: { url: "https://x.com" } } },
};
const md2 = draftJsToMarkdown(fixture2);
// Expect: "Hello **bold** [world](https://x.com)"
console.log("FIXTURE2_BOLD=" + (md2.includes("**bold**") ? "yes" : "no"));
console.log("FIXTURE2_LINK=" + (md2.includes("[world](https://x.com)") ? "yes" : "no"));

// Ordered-list-item counter
const fixture3 = {
  blocks: [
    { type: "ordered-list-item", text: "first", inlineStyleRanges: [], entityRanges: [], depth: 0 },
    { type: "ordered-list-item", text: "second", inlineStyleRanges: [], entityRanges: [], depth: 0 },
    { type: "ordered-list-item", text: "third", inlineStyleRanges: [], entityRanges: [], depth: 0 },
  ],
  entityMap: {},
};
const md3 = draftJsToMarkdown(fixture3);
const expected3 = "1. first\n\n2. second\n\n3. third";
console.log("FIXTURE3_OL=" + (md3 === expected3 ? "yes" : "no"));

// Unknown block type — falls back to plain text
const fixture4 = {
  blocks: [{ type: "some-future-type", text: "unknown but printed", inlineStyleRanges: [], entityRanges: [], depth: 0 }],
  entityMap: {},
};
const md4 = draftJsToMarkdown(fixture4);
console.log("FIXTURE4_FALLBACK=" + (md4.includes("unknown but printed") ? "yes" : "no"));

// Code-block
const fixture5 = {
  blocks: [{ type: "code-block", text: "console.log('hi')", inlineStyleRanges: [], entityRanges: [], depth: 0 }],
  entityMap: {},
};
const md5 = draftJsToMarkdown(fixture5);
console.log("FIXTURE5_CODE=" + (md5.startsWith("\`\`\`") && md5.endsWith("\`\`\`") ? "yes" : "no"));
EOF

# Use node (NOT bun) because bun may not be on PATH in CI;
# import.meta.main is bun-only but we don't need it for an import-only test.
out="$(node "$tmpdir/draft-test.mjs" 2>&1)"
echo "$out" | grep -q 'FIXTURE1_MATCH=yes' && r1=yes || r1=no
echo "$out" | grep -q 'FIXTURE2_BOLD=yes' && r2=yes || r2=no
echo "$out" | grep -q 'FIXTURE2_LINK=yes' && r3=yes || r3=no
echo "$out" | grep -q 'FIXTURE3_OL=yes' && r4=yes || r4=no
echo "$out" | grep -q 'FIXTURE4_FALLBACK=yes' && r5=yes || r5=no
echo "$out" | grep -q 'FIXTURE5_CODE=yes' && r6=yes || r6=no
assert "DraftJS: header-two + unstyled + ul block-types" "yes" "$r1"
assert "DraftJS: BOLD inline-style wrap" "yes" "$r2"
assert "DraftJS: LINK entity wrap" "yes" "$r3"
assert "DraftJS: ordered-list-item counter" "yes" "$r4"
assert "DraftJS: unknown block-type fallback to plain text" "yes" "$r5"
assert "DraftJS: code-block fenced output" "yes" "$r6"
if [ "$r1" != "yes" ] || [ "$r2" != "yes" ]; then
    echo "  (debug output)"
    printf '    %s\n' "$out"
fi

# -- Test 5: idempotency — already-enriched clips skip --------------
echo "Test 5: idempotency on enriched_at: marker"
if grep -q 'alreadyEnriched' "$SCRIPT" && grep -q 'enriched_at:' "$SCRIPT"; then
    has_idem=yes
else
    has_idem=no
fi
assert "alreadyEnriched / enriched_at: present in script" "yes" "$has_idem"

# -- Test 6: G-3 byte-identity check + revert-on-failure ----------------
echo "Test 6: G-3 byte-identity check present"
if grep -q 'G-3' "$SCRIPT" && grep -q 'reverted' "$SCRIPT"; then
    has_g3=yes
else
    has_g3=no
fi
assert "G-3 invariant + revert paths present" "yes" "$has_g3"

# -- Test 7: --dry-run guard blocks writes ------------------------------
echo "Test 7: --dry-run flag is honored"
if grep -q 'dryRun' "$SCRIPT" && grep -q 'would enrich' "$SCRIPT"; then
    has_dry=yes
else
    has_dry=no
fi
assert "--dry-run short-circuits write path" "yes" "$has_dry"

# Functional dry-run: build a fake vault, invoke --dry-run --limit 1, confirm
# zero file mutations.
fake_vault="$tmpdir/vault"
mkdir -p "$fake_vault/Clippings"
cat >"$fake_vault/Clippings/sample.md" <<'EOF'
---
source: https://x.com/jack/status/20
processed: true
---
# Sample
body
EOF
before_sha="$(sha256sum "$fake_vault/Clippings/sample.md" | cut -d' ' -f1)"
node "$SCRIPT" --vault "$fake_vault" --limit 1 --dry-run >/dev/null 2>"$tmpdir/dr.err"
dr_rc=$?
after_sha="$(sha256sum "$fake_vault/Clippings/sample.md" | cut -d' ' -f1)"
assert "--dry-run exit 0" "0" "$dr_rc"
assert "--dry-run leaves clip byte-identical" "$before_sha" "$after_sha"

# -- Test 8: YAML parse-validate via js-yaml present -------------------
echo "Test 8: js-yaml import + parse-validate present"
if grep -q 'js-yaml' "$SCRIPT"; then has_yi=yes; else has_yi=no; fi
assert "js-yaml referenced in script" "yes" "$has_yi"

# -- Test 9: rate-limit politeness — 1s sleep before fetch -------------
echo "Test 9: rate-limit 1000ms sleep present"
if grep -qE 'RATE_LIMIT_MS\s*=\s*1000' "$SCRIPT"; then has_rl=yes; else has_rl=no; fi
assert "1000ms rate-limit constant present" "yes" "$has_rl"

# -- Test 10: smoke against cached JSON in /tmp/fxt-compare/ ----------
echo "Test 10: cached fxt JSON smoke (optional)"
# Resolve to a node-friendly absolute path. /tmp/ on Git Bash is a shell
# alias to %TEMP%; node sees /tmp/ as C:\tmp\ literally. Use cygpath when
# available; fall back to the bash-visible path otherwise.
fxt_cache_raw="/tmp/fxt-compare"
if command -v cygpath >/dev/null 2>&1; then
    fxt_cache="$(cygpath -w "$fxt_cache_raw" 2>/dev/null)"
else
    fxt_cache="$fxt_cache_raw"
fi
# Normalise backslashes for the JS string literal.
fxt_cache_js="${fxt_cache//\\//}"
if [ ! -d "$fxt_cache_raw" ]; then
    echo "  SKIP  $fxt_cache_raw not present"
else
    cat >"$tmpdir/smoke.mjs" <<EOF
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
const dir = "$fxt_cache_js";
const files = readdirSync(dir).filter(f => f.endsWith(".json"));
let parsed = 0, withTweet = 0, withArticle = 0, withNote = 0, withQuote = 0;
for (const f of files) {
  const raw = JSON.parse(readFileSync(join(dir, f), "utf-8"));
  parsed++;
  if (raw.tweet) {
    withTweet++;
    if (raw.tweet.article) withArticle++;
    if (raw.tweet.is_note_tweet) withNote++;
    if (raw.tweet.quote) withQuote++;
  }
}
console.log("PARSED=" + parsed);
console.log("WITH_TWEET=" + withTweet);
console.log("WITH_NOTE=" + withNote);
console.log("WITH_QUOTE=" + withQuote);
console.log("WITH_ARTICLE=" + withArticle);
EOF
    out="$(node "$tmpdir/smoke.mjs" 2>&1)"
    parsed_n="$(echo "$out" | grep -oE 'PARSED=[0-9]+' | cut -d= -f2)"
    if [ -n "$parsed_n" ] && [ "$parsed_n" -gt 0 ]; then
        assert "fxt JSON cache parses (n>0)" "yes" "yes"
        printf '    info: %s\n' "$out"
    else
        assert "fxt JSON cache parses (n>0)" "yes" "no"
    fi
fi

# -- Test 11: Stage-4 gate — only processed: true clips enrich -------
echo "Test 11: Stage-4 gate (processed: true) present"
if grep -q 'isProcessed' "$SCRIPT" && grep -q 'processed' "$SCRIPT"; then
    has_p4=yes
else
    has_p4=no
fi
assert "isProcessed gate present" "yes" "$has_p4"

# -- Test 12: needs_thread written to .md frontmatter (end-to-end write path) --
echo "Test 12: needs_thread written to clip frontmatter (end-to-end)"

# Strategy: use the FXT_FIXTURE env var (supported by fetchFxt in fxtwitter-enrich.mjs)
# to serve a local JSON file as the fxtwitter API response, bypassing the network.
# We drive the full processClip → writeEnrichment path and grep the written .md.

# --- Case A: thread-signal tweet (text contains "1/5") → needs_thread: true ---
thread_vault="$tmpdir/vault-thread"
mkdir -p "$thread_vault/Clippings"
cat >"$thread_vault/Clippings/thread-clip.md" <<'EOF'
---
source: https://x.com/jack/status/20
processed: true
---
# tweet from x.com/jack/status/20

## The Idea

## Source
https://x.com/jack/status/20
EOF

# Minimal fxtwitter JSON fixture with a thread-signal in tweet.text (1/5).
cat >"$tmpdir/fixture-thread.json" <<'EOF'
{
  "code": 200,
  "tweet": {
    "text": "thoughts on agents\n\n1/5 first point",
    "replies": 0,
    "retweets": 0,
    "quotes": 0,
    "likes": 0,
    "views": 0,
    "author": { "screen_name": "jack" }
  }
}
EOF

FXT_FIXTURE="$tmpdir/fixture-thread.json" node "$SCRIPT" --vault "$thread_vault" --limit 1 >"$tmpdir/t12a.out" 2>&1
t12a_rc=$?
t12a_written="$thread_vault/Clippings/thread-clip.md"
if grep -q "needs_thread: true" "$t12a_written" 2>/dev/null; then
    t12a_has_flag=yes
else
    t12a_has_flag=no
fi
assert "Test12A: thread tweet writes needs_thread: true to frontmatter" "yes" "$t12a_has_flag"
if [ "$t12a_has_flag" != "yes" ]; then
    echo "  (debug rc=$t12a_rc out=$(cat "$tmpdir/t12a.out" 2>/dev/null))"
    echo "  (written file: $(head -20 "$t12a_written" 2>/dev/null))"
fi

# --- Case B: plain tweet (no thread signal) → needs_thread absent ---
plain_vault="$tmpdir/vault-plain"
mkdir -p "$plain_vault/Clippings"
cat >"$plain_vault/Clippings/plain-clip.md" <<'EOF'
---
source: https://x.com/jack/status/21
processed: true
---
# tweet from x.com/jack/status/21

## The Idea

## Source
https://x.com/jack/status/21
EOF

cat >"$tmpdir/fixture-plain.json" <<'EOF'
{
  "code": 200,
  "tweet": {
    "text": "just a normal tweet",
    "replies": 5,
    "retweets": 0,
    "quotes": 0,
    "likes": 0,
    "views": 0,
    "author": { "screen_name": "jack" }
  }
}
EOF

FXT_FIXTURE="$tmpdir/fixture-plain.json" node "$SCRIPT" --vault "$plain_vault" --limit 1 >"$tmpdir/t12b.out" 2>&1
t12b_rc=$?
t12b_written="$plain_vault/Clippings/plain-clip.md"
if grep -q "needs_thread:" "$t12b_written" 2>/dev/null; then
    t12b_has_flag=yes
else
    t12b_has_flag=no
fi
assert "Test12B: plain tweet does NOT write needs_thread to frontmatter" "no" "$t12b_has_flag"
if [ "$t12b_has_flag" != "no" ]; then
    echo "  (debug rc=$t12b_rc out=$(cat "$tmpdir/t12b.out" 2>/dev/null))"
    echo "  (written file: $(head -20 "$t12b_written" 2>/dev/null))"
fi

# -- Test 13: --reflag backfills needs_thread onto already-enriched clips ------
echo "Test 13: --reflag mode (body-safe needs_thread backfill)"

# Case A: an ALREADY-enriched clip (enriched_at set) with NO needs_thread, whose
# tweet has a thread signal → --reflag adds needs_thread:true, body byte-identical,
# enriched_at untouched.
reflag_vault="$tmpdir/vault-reflag"
mkdir -p "$reflag_vault/Clippings"
cat >"$reflag_vault/Clippings/enriched-clip.md" <<'EOF'
---
source: https://x.com/jack/status/30
processed: true
enriched_at: 2026-06-01
enrichment_source: fxtwitter
enrichment_status: ok
---
# tweet from x.com/jack/status/30

## The Idea
real body content that must survive verbatim

## Source
https://x.com/jack/status/30
EOF
body_before_a=$(awk 'f{print} /^---$/{c++} c==2{f=1}' "$reflag_vault/Clippings/enriched-clip.md")

cat >"$tmpdir/fixture-reflag-thread.json" <<'EOF'
{ "code": 200, "tweet": { "text": "deep dive on agents\n\n1/5 the first point", "replies": 0, "author": { "screen_name": "jack" } } }
EOF

FXT_FIXTURE="$tmpdir/fixture-reflag-thread.json" node "$SCRIPT" --vault "$reflag_vault" --reflag --limit 1 >"$tmpdir/t13a.out" 2>&1
t13a_flag=no; grep -q "needs_thread: true" "$reflag_vault/Clippings/enriched-clip.md" 2>/dev/null && t13a_flag=yes
assert "Test13A: --reflag adds needs_thread:true to enriched clip with signal" "yes" "$t13a_flag"
t13a_enriched=no; grep -q "enriched_at: 2026-06-01" "$reflag_vault/Clippings/enriched-clip.md" 2>/dev/null && t13a_enriched=yes
assert "Test13A: --reflag leaves enriched_at untouched" "yes" "$t13a_enriched"
body_after_a=$(awk 'f{print} /^---$/{c++} c==2{f=1}' "$reflag_vault/Clippings/enriched-clip.md")
t13a_body=changed; [ "$body_before_a" = "$body_after_a" ] && t13a_body=identical
assert "Test13A: --reflag leaves body byte-identical (no section added)" "identical" "$t13a_body"

# Case B: already-enriched clip, tweet has NO thread signal → needs_thread NOT added.
cat >"$reflag_vault/Clippings/enriched-plain.md" <<'EOF'
---
source: https://x.com/jack/status/31
processed: true
enriched_at: 2026-06-01
---
## The Idea
plain enriched body
EOF
cat >"$tmpdir/fixture-reflag-plain.json" <<'EOF'
{ "code": 200, "tweet": { "text": "just a normal tweet", "replies": 0, "author": { "screen_name": "jack" } } }
EOF
FXT_FIXTURE="$tmpdir/fixture-reflag-plain.json" node "$SCRIPT" --vault "$reflag_vault" --reflag >"$tmpdir/t13b.out" 2>&1 || true
t13b_flag=no; grep -q "needs_thread:" "$reflag_vault/Clippings/enriched-plain.md" 2>/dev/null && t13b_flag=yes
assert "Test13B: --reflag does NOT flag a no-signal enriched clip" "no" "$t13b_flag"

# Case C: a NON-enriched clip in --reflag mode is skipped (reflag only backfills enriched).
cat >"$reflag_vault/Clippings/not-enriched.md" <<'EOF'
---
source: https://x.com/jack/status/32
processed: true
---
## The Idea
not yet enriched
EOF
FXT_FIXTURE="$tmpdir/fixture-reflag-thread.json" node "$SCRIPT" --vault "$reflag_vault" --reflag >"$tmpdir/t13c.out" 2>&1 || true
t13c_flag=no; grep -q "needs_thread:" "$reflag_vault/Clippings/not-enriched.md" 2>/dev/null && t13c_flag=yes
assert "Test13C: --reflag skips a non-enriched clip (no needs_thread written)" "no" "$t13c_flag"

# -- Summary -----------------------------------------------------------
total=$((pass + fail))
echo ""
echo "Results: $pass / $total passed, $fail failed."
[ "$fail" -eq 0 ]
