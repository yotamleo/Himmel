#!/usr/bin/env bash
# LUNA-33 Tier-2: headless→headful auto-fallback in playwright-crawl-x.mjs.
#
# X gates the React app on headless playwright (waitForSelector times out →
# tweet_not_rendered) even with valid auth. This verifies the fallback: on a
# headless-gate selector-miss, the scrape is retried in a headful browser and
# persisted as crawl_skill: playwright-x-headful — WITHOUT first writing a
# failed marker that would block the retry.
#
# No real browser: processClip / scrapeTweet are driven with fake page objects
# (headless page's waitForSelector throws; headful page's evaluate yields text).
# Requires the module to be import-safe (main() guarded behind the entrypoint
# check) and to export processClip / scrapeTweet / isHeadlessGateError.
set -u -o pipefail
cd "$(dirname "$0")/.." || exit 1

CX="tools/playwright-crawl-x.mjs"
pass=0; fail=0
assert() { if [ "$2" = "$3" ]; then echo "  PASS  $1"; pass=$((pass+1)); else echo "  FAIL  $1 (want '$2', got '$3')"; fail=$((fail+1)); fi; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/vault/Clippings"

# A crawlable clip: clip-body harvest, x source, no crawled_at, has ## Source.
mkclip() {
  cat > "$1" <<'EOF'
---
title: "a tweet clip"
source: https://x.com/someuser/status/1234567890
harvest_skill: clip-body
type: tweet
---
# a tweet clip

## Source
[https://x.com/someuser/status/1234567890](https://x.com/someuser/status/1234567890)
EOF
}
mkclip "$tmp/vault/Clippings/clip-a.md"
mkclip "$tmp/vault/Clippings/clip-b.md"
mkclip "$tmp/vault/Clippings/clip-c.md"

# Node driver: import the (import-safe) module, drive processClip with fakes,
# emit KEY=value lines the shell asserts on.
cat > "$tmp/driver.mjs" <<'EOF'
import { pathToFileURL } from "node:url";
import { readFileSync } from "node:fs";
const mod = await import(pathToFileURL(process.env.CX).href);
const { processClip, isHeadlessGateError } = mod;

const vault = process.env.VAULT;
const fmval = (p, key) => {
  const m = readFileSync(p, "utf-8").match(new RegExp("^" + key + ":\\s*(.+)$", "m"));
  return m ? m[1].trim().replace(/^"|"$/g, "") : "";
};
const hasContent = (p) => /^## Crawled content/m.test(readFileSync(p, "utf-8")) ? "yes" : "no";
const countLines = (p, key) => (readFileSync(p, "utf-8").match(new RegExp("^" + key + ":", "mg")) || []).length;

// A headless page whose waitForSelector always misses (X headless gate).
const headlessPage = {
  async goto() {},
  async waitForSelector() { throw new Error("Timeout 15000ms exceeded"); },
  async waitForTimeout() {},
  async evaluate() { return { mainText: "", replies: [], quoteText: "" }; },
};
// A headless page that renders the shell but never hydrates tweet text →
// scrapeTweet returns partial main_text_empty (the OTHER headless-gate signal).
const headlessEmptyPage = {
  async goto() {},
  async waitForSelector() {},
  async waitForTimeout() {},
  async evaluate() { return { mainText: "", replies: [], quoteText: "" }; },
};
// A headful page that renders: evaluate yields real tweet text.
const headfulPage = {
  async goto() {},
  async waitForSelector() {},
  async waitForTimeout() {},
  async evaluate() { return { mainText: "the real tweet text", replies: ["a reply"], quoteText: "" }; },
};

// Predicate unit checks.
console.log("P_TNR=" + isHeadlessGateError({ ok: false, partial: false, error: "tweet_not_rendered" }));
console.log("P_MTE=" + isHeadlessGateError({ ok: false, partial: true, error: "main_text_empty" }));
console.log("P_NAV=" + isHeadlessGateError({ ok: false, partial: false, error: "nav_timeout: x" }));
console.log("P_OK=" + isHeadlessGateError({ ok: true, partial: false }));

// Scenario A: headless miss + headful factory → headful retry succeeds.
const a = vault + "/Clippings/clip-a.md";
const ra = await processClip(headlessPage, a, vault, false, async () => headfulPage);
console.log("A_GLYPH=" + ra.glyph);
console.log("A_STATUS=" + fmval(a, "crawl_status"));
console.log("A_SKILL=" + fmval(a, "crawl_skill"));
console.log("A_CONTENT=" + hasContent(a));
// Single-write invariant: the headless failure must NOT have persisted a first
// marker before the headful retry — so exactly one crawl_status line exists.
console.log("A_STATUSCOUNT=" + countLines(a, "crawl_status"));

// Scenario C: headless renders shell but text never hydrates (partial
// main_text_empty) → the OTHER gate signal → headful retry heals it.
const c = vault + "/Clippings/clip-c.md";
const rc = await processClip(headlessEmptyPage, c, vault, false, async () => headfulPage);
console.log("C_GLYPH=" + rc.glyph);
console.log("C_STATUS=" + fmval(c, "crawl_status"));
console.log("C_SKILL=" + fmval(c, "crawl_skill"));

// Scenario B: headless miss + NO factory → fails as headless (no retry).
const b = vault + "/Clippings/clip-b.md";
const rb = await processClip(headlessPage, b, vault, false, null);
console.log("B_GLYPH=" + rb.glyph);
console.log("B_STATUS=" + fmval(b, "crawl_status"));
console.log("B_SKILL=" + fmval(b, "crawl_skill"));
EOF

CRAWL_SLEEP_MS=0 CX="$CX" VAULT="$tmp/vault" node "$tmp/driver.mjs" > "$tmp/out.txt" 2>"$tmp/err.txt" || { echo "DRIVER FAILED:"; cat "$tmp/err.txt"; }
kv() { grep -m1 "^$1=" "$tmp/out.txt" | cut -d= -f2-; }

echo "Test 1: isHeadlessGateError predicate"
assert "tweet_not_rendered → true" "true" "$(kv P_TNR)"
assert "partial main_text_empty → true" "true" "$(kv P_MTE)"
assert "nav_timeout → false" "false" "$(kv P_NAV)"
assert "ok scrape → false" "false" "$(kv P_OK)"

echo "Test 2: headless miss → headful retry persists"
assert "A glyph ok (v)" "v" "$(kv A_GLYPH)"
assert "A crawl_status ok" "ok" "$(kv A_STATUS)"
assert "A crawl_skill playwright-x-headful" "playwright-x-headful" "$(kv A_SKILL)"
assert "A body got crawled content" "yes" "$(kv A_CONTENT)"
assert "A wrote crawl_status exactly once (no pre-retry failed marker)" "1" "$(kv A_STATUSCOUNT)"

echo "Test 2b: partial main_text_empty → headful retry heals"
assert "C glyph ok (v)" "v" "$(kv C_GLYPH)"
assert "C crawl_status ok" "ok" "$(kv C_STATUS)"
assert "C crawl_skill playwright-x-headful" "playwright-x-headful" "$(kv C_SKILL)"

echo "Test 3: headless miss + no fallback → fails as headless"
assert "B glyph fail (x)" "x" "$(kv B_GLYPH)"
assert "B crawl_status failed" "failed" "$(kv B_STATUS)"
assert "B crawl_skill playwright-x" "playwright-x" "$(kv B_SKILL)"

echo ""
echo "test-playwright-headful-fallback: $pass passed, $fail failed"
[ "$fail" -eq 0 ] && echo "test-playwright-headful-fallback OK" || exit 1
