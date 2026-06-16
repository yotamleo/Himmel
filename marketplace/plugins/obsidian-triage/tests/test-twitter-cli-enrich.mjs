/**
 * test-twitter-cli-enrich.mjs — unit tests for the pure helpers of
 * twitter-cli-enrich.mjs (mapTweetData, parseThreadResult).
 *
 * Run: node tests/test-twitter-cli-enrich.mjs
 * (from marketplace/plugins/obsidian-triage/)
 *
 * No live X / no auth: mapTweetData is driven by a captured fixture and
 * parseThreadResult by literal JSON strings.
 */
import { mapTweetData, parseThreadResult, processClip } from "../tools/twitter-cli-enrich.mjs";
import { readFileSync, writeFileSync, mkdtempSync, mkdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { tmpdir } from "node:os";
import assert from "node:assert/strict";

const here = dirname(fileURLToPath(import.meta.url));
const fixture = JSON.parse(readFileSync(join(here, "fixtures/twitter-cli-thread.json"), "utf-8"));

// --- mapTweetData ---

const mapped = mapTweetData(fixture.data);

assert.equal(mapped.mainText, "agents that browse for you. wrote up how it works ↓ repo in comment");
assert.equal(mapped.quoteText, "the original idea");
// self-thread: the same-author (case-insensitive) reply, with its expanded url folded in
assert.equal(mapped.selfThread.length, 1, "one self-thread segment");
assert.ok(mapped.selfThread[0].includes("here it is"), "segment text present");
assert.ok(
  mapped.selfThread[0].includes("https://github.com/Panniantong/Agent-Reach"),
  "repo url folded into segment",
);
// top reply: first OTHER-author entry, prefer one carrying a url
assert.ok(mapped.topReply, "topReply present");
assert.equal(mapped.topReply.url, "https://example.com/related");
assert.ok(mapped.topReply.text.includes("great work"));

// empty / single-tweet inputs are safe
const solo = mapTweetData([fixture.data[0]]);
assert.equal(solo.selfThread.length, 0);
assert.equal(solo.topReply, null);
assert.equal(mapTweetData([]).mainText, "");

// self-thread BREAKS at the first other-author entry — a later same-author
// entry after an interruption is NOT pulled back into the thread.
const interrupted = mapTweetData([
  { text: "focal", author: { screenName: "alice" }, urls: [] },
  { text: "a reply", author: { screenName: "bob" }, urls: [] },
  { text: "alice again, but after bob", author: { screenName: "alice" }, urls: [] },
]);
assert.equal(interrupted.selfThread.length, 0, "self-thread stops at first other-author (no trailing same-author)");
assert.ok(interrupted.topReply, "topReply picked from the rest");

// topReply PREFERS the first reply carrying a url, not merely the first reply.
const preferUrl = mapTweetData([
  { text: "focal", author: { screenName: "alice" }, urls: [] },
  { text: "no link here", author: { screenName: "bob" }, urls: [] },
  { text: "the link", author: { screenName: "carol" }, urls: ["https://github.com/x/y"] },
]);
assert.equal(preferUrl.topReply.url, "https://github.com/x/y", "url-bearing reply preferred");
assert.ok(preferUrl.topReply.text.includes("the link"));

// a focal tweet with NO quotedTweet → quoteText empty
const noQuote = mapTweetData([{ text: "solo", author: { screenName: "alice" }, urls: [] }]);
assert.equal(noQuote.quoteText, "", "no quotedTweet → empty quoteText");

// focal tweet's OWN expanded url is folded into mainText
const focalUrl = mapTweetData([
  { text: "see this", author: { screenName: "alice" }, urls: ["https://example.com/direct"] },
]);
assert.ok(focalUrl.mainText.includes("https://example.com/direct"), "focal url folded into mainText");

console.log("test-twitter-cli-enrich (mapTweetData): PASS");

// --- parseThreadResult ---

const okRes = parseThreadResult(
  JSON.stringify({ ok: true, data: [{ id: "1", text: "hi", author: { screenName: "a" } }] }),
  0,
);
assert.equal(okRes.ok, true);
assert.equal(okRes.data.length, 1);

const errRes = parseThreadResult(
  JSON.stringify({ ok: false, error: { code: "not_authenticated", message: "expired" } }),
  1,
);
assert.equal(errRes.ok, false);
assert.equal(errRes.error, "not_authenticated");

assert.equal(parseThreadResult("", 1).error, "exit_1", "non-zero exit + empty → exit_N");
assert.equal(parseThreadResult("", 0).error, "empty_output", "zero exit + empty → empty_output");

const badRes = parseThreadResult("not json", 0);
assert.equal(badRes.ok, false);
assert.equal(badRes.error, "bad_json");

// valid JSON but not the success envelope (ok:true without a data array) → not_ok
assert.equal(parseThreadResult(JSON.stringify({ ok: true }), 0).error, "not_ok");

console.log("test-twitter-cli-enrich (parseThreadResult): PASS");

// --- processClip end-to-end (DI fake fetcher, no live X) ---

// Skip the 3-5s politeness jitter — the test seam keeps the suite fast.
process.env.CRAWL_SLEEP_MS = "0";

const tmp = mkdtempSync(join(tmpdir(), "tw-cli-enrich-"));
const vault = join(tmp, "vault");
mkdirSync(join(vault, "Clippings"), { recursive: true });
const clipPath = join(vault, "Clippings", "flagged.md");
writeFileSync(
  clipPath,
  [
    "---",
    "harvest_skill: clip-body",
    "source: https://x.com/israfill/status/2065868713895829991",
    "needs_thread: true",
    "---",
    "## The Idea",
    "agents that browse for you",
    "",
    "## Source",
    "https://x.com/israfill/status/2065868713895829991",
    "",
  ].join("\n"),
  "utf-8",
);

const fakeFetch = (id) => {
  assert.equal(id, "2065868713895829991", "extracted status id passed to fetcher");
  return { ok: true, data: fixture.data };
};
const okResult = await processClip(clipPath, vault, false, 20, fakeFetch);
assert.equal(okResult.glyph, "v", `processClip ok (got ${okResult.glyph}: ${okResult.message})`);

const written = readFileSync(clipPath, "utf-8");
assert.ok(written.includes("## Crawled content"), "crawled section folded in");
assert.ok(written.includes("https://github.com/Panniantong/Agent-Reach"), "repo url present in body");
assert.ok(written.includes("crawl_skill: twitter-cli"), "crawl_skill marker written");
assert.ok(/crawled_at:\s*\S/.test(written), "crawled_at marker written");
// G-3: the pre-existing body sections survive VERBATIM (not just present) —
// the new section is additive only.
assert.ok(
  written.includes("## The Idea\nagents that browse for you"),
  "original body block byte-preserved (G-3 verbatim)",
);
assert.ok(
  written.includes("## Source\nhttps://x.com/israfill/status/2065868713895829991"),
  "## Source block byte-preserved (G-3 verbatim)",
);

// idempotent: a second pass skips (already-crawled)
const second = await processClip(clipPath, vault, false, 20, fakeFetch);
assert.equal(second.glyph, "o", "second pass skipped (already-crawled)");

// soft-fail: a failed fetch leaves the fxtwitter body intact (no crawled section)
writeFileSync(
  join(vault, "Clippings", "softfail.md"),
  [
    "---",
    "harvest_skill: clip-body",
    "source: https://x.com/foo/status/999",
    "needs_thread: true",
    "---",
    "## The Idea",
    "body stays intact",
    "",
  ].join("\n"),
  "utf-8",
);
const softPath = join(vault, "Clippings", "softfail.md");
const failFetch = () => ({ ok: false, error: "not_authenticated" });
const failResult = await processClip(softPath, vault, false, 20, failFetch);
assert.equal(failResult.glyph, "x", "soft-fail reported as fail");
const softWritten = readFileSync(softPath, "utf-8");
assert.ok(!softWritten.includes("## Crawled content"), "no crawled section on soft-fail");
assert.ok(softWritten.includes("body stays intact"), "fxtwitter body intact on soft-fail");
assert.ok(softWritten.includes("crawl_status: failed"), "crawl_status: failed marker on soft-fail");
assert.ok(!/crawled_at:\s*\S/.test(softWritten), "soft-fail leaves crawled_at UNSET (re-attempt next run)");

// soft-failed clip is re-selected (not already-crawled) on a subsequent pass
const retry = await processClip(softPath, vault, false, 20, () => ({ ok: true, data: fixture.data }));
assert.equal(retry.glyph, "v", "soft-failed clip re-attempted + succeeds on retry");
assert.ok(/crawled_at:\s*\S/.test(readFileSync(softPath, "utf-8")), "crawled_at stamped after successful retry");

// empty-result guard (HIMMEL-306): an ok fetch that maps to nothing useful
// (media-only tweet, no thread, no reply) is a TERMINAL empty — crawled_at is
// stamped + crawl_status: empty, so the clip CONVERGES (skips on re-run) instead
// of re-fetching forever. Distinct from a transient fetch failure (above), which
// leaves crawled_at unset to re-attempt.
const emptyPath = join(vault, "Clippings", "emptyres.md");
writeFileSync(
  emptyPath,
  ["---", "harvest_skill: clip-body", "source: https://x.com/foo/status/777", "needs_thread: true", "---", "## The Idea", "media only", ""].join("\n"),
  "utf-8",
);
const emptyData = [{ text: "", author: { screenName: "foo" }, urls: [] }];
const emptyResult = await processClip(emptyPath, vault, false, 20, () => ({ ok: true, data: emptyData }));
assert.equal(emptyResult.glyph, "e", `empty result is a terminal empty (glyph e, got ${emptyResult.glyph}: ${emptyResult.message})`);
const emptyWritten = readFileSync(emptyPath, "utf-8");
assert.ok(!emptyWritten.includes("## Crawled content"), "no empty crawled section written");
assert.ok(/crawled_at:\s*\S/.test(emptyWritten), "empty-result STAMPS crawled_at (converges, HIMMEL-306)");
assert.ok(/crawl_status:\s*empty/.test(emptyWritten), "crawl_status: empty marker written");
assert.ok(!/last_error:\s*\S/.test(emptyWritten), "empty is not an error — no last_error marker");
assert.ok(emptyWritten.includes("media only"), "original body intact on empty");
// convergence: a second pass SKIPS (already-crawled) and never re-fetches —
// the fetcher throws to prove processClip returns before any network call.
const emptySecond = await processClip(emptyPath, vault, false, 20, () => {
  throw new Error("must not re-fetch a converged empty clip");
});
assert.equal(emptySecond.glyph, "o", "empty clip converged — second pass skipped (already-crawled)");

// stale-read guard: an operator edit DURING the fetch (simulated via a fetchFn
// side-effect) is detected on the re-read → glyph '~', no section written.
const stalePath = join(vault, "Clippings", "stale.md");
writeFileSync(
  stalePath,
  ["---", "harvest_skill: clip-body", "source: https://x.com/foo/status/888", "needs_thread: true", "---", "## The Idea", "original", ""].join("\n"),
  "utf-8",
);
const editingFetch = () => {
  writeFileSync(stalePath, readFileSync(stalePath, "utf-8") + "\noperator edit\n", "utf-8");
  return { ok: true, data: fixture.data };
};
const staleResult = await processClip(stalePath, vault, false, 20, editingFetch);
assert.equal(staleResult.glyph, "~", "stale-read (mid-pass edit) → partial");
assert.ok(!readFileSync(stalePath, "utf-8").includes("## Crawled content"), "no section written on stale-read");

console.log("test-twitter-cli-enrich (processClip e2e): PASS");
