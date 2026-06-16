/**
 * test-fxtwitter-bodyfill.mjs — unit tests for body-fill helper functions.
 *
 * Tests Task 1: isThinTweetBody
 *       Task 2: renderIdeaSection + isTelegramTitlePlaceholder
 *
 * Run: node tests/test-fxtwitter-bodyfill.mjs
 * (from marketplace/plugins/obsidian-triage/)
 */
import assert from "node:assert/strict";
import { isThinTweetBody, renderIdeaSection, isTelegramTitlePlaceholder } from "../tools/fxtwitter-enrich.mjs";

// ---------------------------------------------------------------------------
// Task 1: isThinTweetBody
// ---------------------------------------------------------------------------

const stub = "# tweet from x.com/i/status/123\n\nhttps://x.com/i/status/123\n\n## Source\n[x](x)\n";
assert.equal(isThinTweetBody(stub), true, "telegram url-only stub is thin");

const rich = "# Tweet by @x\n\n## The Idea\n\nFable 5 is the first model that made me feel audited. 36 hours...\n\n## Source\n[x](x)\n";
assert.equal(isThinTweetBody(rich), false, "populated ## The Idea is not thin");

const shortprose = "# Tweet by @x\n\nThis Skills .md file is really good.\n\n## Source\n[x](x)\n";
assert.equal(isThinTweetBody(shortprose), false, "real prose body is not thin");

// ---------------------------------------------------------------------------
// Task 2: renderIdeaSection + isTelegramTitlePlaceholder
// ---------------------------------------------------------------------------

const sec = renderIdeaSection("Hermes x Obsidian is the most powerful AI memory system.");
assert.match(sec, /^## The Idea\n/);
assert.match(sec, /Hermes x Obsidian/);
assert.match(sec, /<!-- enriched .* via fxtwitter \(text\) -->/);

assert.equal(isTelegramTitlePlaceholder("tweet from x.com/i/status/123"), true);
assert.equal(isTelegramTitlePlaceholder("Claude Fable 5: The Ultimate Guide"), false);
assert.equal(isTelegramTitlePlaceholder('"tweet from x.com/i/status/123"'), true);

// image-only ## The Idea is still thin (image line is not "meaningful")
const imgIdea = "# Tweet by @x\n\n## The Idea\n\n![Image](https://pbs.twimg.com/x.jpg)\n\n## Source\n[x](x)\n";
assert.equal(isThinTweetBody(imgIdea), true, "image-only ## The Idea is thin");
// empty text falls back
assert.match(renderIdeaSection(""), /_\(no tweet text\)_/, "empty text fallback");
// single-quoted placeholder + twitter.com host
assert.equal(isTelegramTitlePlaceholder("'tweet from x.com/i/status/9'"), true, "single-quoted placeholder");
assert.equal(isTelegramTitlePlaceholder("article from twitter.com/u/status/9"), true, "twitter.com host placeholder");

console.log("test-fxtwitter-bodyfill OK");
