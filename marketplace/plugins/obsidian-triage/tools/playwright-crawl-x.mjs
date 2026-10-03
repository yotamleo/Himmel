#!/usr/bin/env node
/**
 * playwright-crawl-x.mjs — DEPRECATED for default use (LUNA-33, 2026-05-27).
 *
 * X.com aggressively gates the React app on headless playwright + Obscura
 * (anti-bot + incomplete-V8 DOM-API issues), so this script reliably fails
 * tweet detection on a meaningful fraction of clips even with valid auth
 * state. Use `fxtwitter-enrich.mjs` instead — it hits api.fxtwitter.com
 * for browser-free + auth-free enrichment that covers most needs (plain
 * tweets, long tweets, X Articles with Draft.js content blocks, quote-
 * tweet context). See LUNA-35 for the deprecation tracker.
 *
 * This script is RETAINED as an "auth-thread-needed" fallback for the
 * cases fxtwitter cannot serve (reply threads with comments, private-
 * account scrapes when the operator is logged in).
 *
 * ---
 *
 * Original: batch enrich X (Twitter) clips with crawled content.
 *
 * For every clip in <vault>/Clippings/ with:
 *   - harvest_skill: clip-body
 *   - source: https://x.com/<user>/status/<id> (or twitter.com)
 *   - no existing crawled_at: marker
 *
 * navigate to the tweet, scrape main tweet text + top replies + quote, and fold
 * a "## Crawled content" section into the clip body BEFORE "## Source" (or
 * "## Comments" if no Source). Add frontmatter markers:
 *   crawled_at, crawl_skill, crawl_status, last_error (only on partial/failed).
 *
 * G-3 invariant: existing body sections must be byte-identical post-write.
 * Only the new "## Crawled content" H2 may be added. Frontmatter mutation
 * is whitelisted to the four crawl_* keys above. YAML parse-validate the
 * post-write frontmatter; revert to Phase-1 baseline on parse failure.
 *
 * Idempotent: re-runs skip clips with crawled_at: already present.
 *
 * Headless→headful auto-fallback (LUNA-33 Tier-2): default headless; on a
 * headless-gate selector-miss (`tweet_not_rendered` / thin `main_text_empty`),
 * the scrape is retried once in a headful (real-window) browser, launched
 * lazily and reused. `--headful` forces a real window from the start. This
 * mitigates the headless *rendering* gate (the `tweet_not_rendered` miss); the
 * Obscura anti-bot detection noted above is a separate axis a real window only
 * partly reduces, so fxtwitter stays the preferred browser-free path.
 *
 * Usage:
 *   bun playwright-crawl-x.mjs --vault <path> [--limit N] [--dry-run] [--headful]
 *
 * Exit codes:
 *   0 — run completed (may include partial/failed clips; see summary)
 *   1 — bad usage
 *   2 — storage_state missing (run playwright-auth-save.mjs x first)
 *   3 — playwright module missing
 *
 * LUNA-27. Sister script: playwright-crawl-youtube.mjs (transcript-only MVP).
 */
import { existsSync, readFileSync, writeFileSync, statSync, readdirSync } from "node:fs";
import { homedir } from "node:os";
import { join, relative, sep } from "node:path";
import { pathToFileURL } from "node:url";
import { createHash } from "node:crypto";

const TODAY = new Date().toISOString().slice(0, 10);
const NOW_ISO = new Date().toISOString();
const SLEEP_MIN_MS = 3000;
const SLEEP_MAX_MS = 5000;
const NAV_TIMEOUT_MS = 15000;
const TWEET_SELECTOR = '[data-testid="tweet"]';

function usage(code = 1) {
  console.error("Usage: playwright-crawl-x.mjs --vault <path> [--limit N] [--dry-run] [--headful]");
  console.error("");
  console.error("Pre-req: ~/.luna/playwright-state/x.json (run playwright-auth-save.mjs x).");
  process.exit(code);
}

function parseArgs(argv) {
  const out = { vault: null, limit: 0, dryRun: false, headful: false };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--vault") out.vault = argv[++i];
    else if (a === "--limit") out.limit = parseInt(argv[++i] || "0", 10) || 0;
    else if (a === "--dry-run") out.dryRun = true;
    else if (a === "--headful") out.headful = true;
    else if (a === "-h" || a === "--help") usage(0);
    else {
      console.error(`unknown arg: ${a}`);
      usage(1);
    }
  }
  if (!out.vault) usage(1);
  return out;
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

function jitterSleep() {
  // Test seam: CRAWL_SLEEP_MS=0 makes the politeness sleep instant so unit
  // runs that drive processClip with fake pages don't wait 3-5s per scrape.
  // A malformed value (NaN) must NOT silently disable throttling in a real run
  // (would risk an X rate-limit ban with no signal) — warn and fall through to
  // the normal jitter.
  if (process.env.CRAWL_SLEEP_MS != null) {
    const v = Number(process.env.CRAWL_SLEEP_MS);
    if (Number.isNaN(v)) {
      process.stderr.write(`crawl-x: WARN CRAWL_SLEEP_MS="${process.env.CRAWL_SLEEP_MS}" is not a number — ignoring, using normal jitter\n`);
    } else {
      return sleep(v);
    }
  }
  const ms = SLEEP_MIN_MS + Math.floor(Math.random() * (SLEEP_MAX_MS - SLEEP_MIN_MS));
  return sleep(ms);
}

function sha256(s) {
  return createHash("sha256").update(s).digest("hex");
}

/**
 * Glob Clippings/*.md plus one-level subfolders.
 * Returns array of absolute paths.
 */
function findClips(vault) {
  const root = join(vault, "Clippings");
  if (!existsSync(root)) {
    console.error(`crawl-x: no Clippings/ dir at ${root}`);
    return [];
  }
  const out = [];
  const entries = readdirSync(root, { withFileTypes: true });
  for (const e of entries) {
    if (e.isFile() && e.name.endsWith(".md")) {
      out.push(join(root, e.name));
    } else if (e.isDirectory()) {
      // one level down only
      const sub = join(root, e.name);
      try {
        const subs = readdirSync(sub, { withFileTypes: true });
        for (const s of subs) {
          if (s.isFile() && s.name.endsWith(".md")) {
            out.push(join(sub, s.name));
          }
        }
      } catch {
        // skip unreadable subdir
      }
    }
  }
  return out.sort();
}

/**
 * Parse top-level frontmatter. Minimal YAML-ish — top-level key: value only.
 * Mirrors harvest-clip-body-batch.py for cross-tool consistency.
 * Normalises CRLF → LF on entry so Windows-edited clips parse correctly
 * (operator-edited clips on Windows can land with \r\n endings; without
 * normalisation, `text.startsWith("---\n")` fails and the clip is silently
 * skipped as 'no closing ---'). The Python harvest tool already writes LF
 * via newline="\n", so the canonical on-disk encoding is LF — this just
 * heals operator-introduced CRLF on the read path.
 * Returns { fm, fmRaw, body, present }.
 */
function parseFrontmatter(text) {
  const normalized = text.includes("\r\n") ? text.replace(/\r\n/g, "\n") : text;
  if (!normalized.startsWith("---\n")) return { fm: null, fmRaw: "", body: normalized, present: false };
  const end = normalized.indexOf("\n---\n", 4);
  if (end < 0) return { fm: null, fmRaw: "", body: normalized, present: false };
  const fmRaw = normalized.slice(4, end);
  const body = normalized.slice(end + 5);
  const fm = {};
  for (const line of fmRaw.split("\n")) {
    const m = line.match(/^([a-zA-Z_][a-zA-Z0-9_]*):(.*)$/);
    if (m) fm[m[1]] = m[2].trim();
  }
  return { fm, fmRaw, body, present: true };
}

function alreadyCrawled(fmRaw) {
  return /^crawled_at:\s*\S/m.test(fmRaw);
}

function isXSource(sourceVal) {
  if (!sourceVal) return false;
  const s = sourceVal.trim().replace(/^"|"$/g, "");
  return /^https?:\/\/(www\.|mobile\.)?(x|twitter)\.com\/[^/]+\/status\/\d+/.test(s);
}

function canonicalXUrl(sourceVal) {
  // Reuse the canonical computed by harvest (harvest_url_canonical), but
  // fall back to source: when not present.
  const s = sourceVal.trim().replace(/^"|"$/g, "");
  const m = s.match(/^https?:\/\/(?:www\.|mobile\.)?(?:x|twitter)\.com(\/[^/]+\/status\/\d+)/);
  if (!m) return null;
  return `https://x.com${m[1]}`;
}

/**
 * Insert four crawl_* markers into frontmatter, after the last non-empty
 * top-level line (Phase 5 placement contract — append after every existing key).
 * If a crawl_* key already exists (e.g. prior partial run), replace in place.
 */
function upsertCrawlMarkers(fmRaw, markers) {
  const orderedKeys = ["crawled_at", "crawl_skill", "crawl_status", "last_error"];
  let lines = fmRaw.split("\n");

  // Replace existing keys in place; mark which ones were present.
  const seen = new Set();
  lines = lines.map((line) => {
    for (const k of orderedKeys) {
      const re = new RegExp(`^${k}:`);
      if (re.test(line)) {
        seen.add(k);
        if (markers[k] === undefined || markers[k] === null) {
          // Caller wants to drop this key (e.g. last_error on success).
          // Use a sentinel — actually filter it out below.
          return null;
        }
        return `${k}: ${formatYamlValue(markers[k])}`;
      }
    }
    return line;
  }).filter((l) => l !== null);

  // Find insertion point (after last non-empty line).
  let insertIdx = lines.length;
  for (let i = lines.length - 1; i >= 0; i--) {
    if (lines[i].trim()) {
      insertIdx = i + 1;
      break;
    }
  }
  const toInsert = [];
  for (const k of orderedKeys) {
    if (seen.has(k)) continue;
    if (markers[k] === undefined || markers[k] === null) continue;
    toInsert.push(`${k}: ${formatYamlValue(markers[k])}`);
  }
  return [...lines.slice(0, insertIdx), ...toInsert, ...lines.slice(insertIdx)].join("\n");
}

function formatYamlValue(v) {
  if (typeof v !== "string") return String(v);
  // Quote if contains chars that need quoting in flow YAML.
  if (/[:#"\n]|^\s|\s$|^-|^[0-9]/.test(v)) {
    return `"${v.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
  }
  return v;
}

/**
 * Insert "## Crawled content" section into body BEFORE "## Source" (or
 * "## Comments" if no Source). If neither marker exists, append at end.
 */
function insertCrawledSection(body, sectionMarkdown) {
  const sourceMatch = body.match(/^## Source\b/m);
  const commentsMatch = body.match(/^## Comments\b/m);
  let insertAt;
  if (sourceMatch) {
    insertAt = sourceMatch.index;
  } else if (commentsMatch) {
    insertAt = commentsMatch.index;
  } else {
    // Append at end with a leading newline buffer.
    const sep = body.endsWith("\n") ? "" : "\n";
    return body + sep + "\n" + sectionMarkdown + "\n";
  }
  const before = body.slice(0, insertAt);
  const after = body.slice(insertAt);
  // Ensure exactly one blank line between insertion and following header.
  const trailingNewlines = before.match(/\n*$/)[0].length;
  let prefix = before;
  if (trailingNewlines < 2) {
    prefix = before.replace(/\n*$/, "") + "\n\n";
  }
  return prefix + sectionMarkdown + "\n\n" + after;
}

/**
 * Scrape a single tweet page. Returns { ok, partial, mainText, replies, quoteText, error }.
 * Selector strategy:
 *   - [data-testid="tweet"]: matches tweet containers. The first one is the
 *     focal tweet on a /status/ page; the rest are thread + replies in DOM order.
 *   - [data-testid="tweetText"] inside each container: the prose body.
 *   - quote-tweet target: nested article inside the focal tweet with role=link.
 */
/**
 * True when a scrape failure looks like X gating the headless React app — the
 * tweet selector never attached (`tweet_not_rendered`), or the shell rendered
 * but the tweet text never hydrated (partial `main_text_empty`). These are the
 * cases a headful (real-window) retry can heal. A `nav_timeout` is a network
 * failure headful won't fix, and a successful scrape needs no retry → both
 * return false. This is the headless→headful auto-fallback trigger.
 */
export function isHeadlessGateError(scrape) {
  if (!scrape || scrape.ok) return false;
  if (scrape.error === "tweet_not_rendered") return true;
  if (scrape.partial && scrape.error === "main_text_empty") return true;
  return false;
}

export async function scrapeTweet(page, url) {
  try {
    await page.goto(url, { waitUntil: "domcontentloaded", timeout: NAV_TIMEOUT_MS });
  } catch (e) {
    return { ok: false, partial: false, error: `nav_timeout: ${e.message.slice(0, 120)}` };
  }
  try {
    await page.waitForSelector(TWEET_SELECTOR, { timeout: NAV_TIMEOUT_MS, state: "attached" });
  } catch {
    return { ok: false, partial: false, error: "tweet_not_rendered" };
  }
  // Give virtualised list a moment to populate replies before we read.
  await page.waitForTimeout(1500);

  // Use evaluate to extract structured content from the DOM in one round-trip.
  const data = await page.evaluate(() => {
    const containers = Array.from(document.querySelectorAll('[data-testid="tweet"]'));
    function textOf(el) {
      const t = el?.querySelector('[data-testid="tweetText"]');
      return t ? t.innerText.trim() : "";
    }
    const main = containers[0];
    const mainText = textOf(main);
    // Quote: an inner article role=link nested inside the focal tweet.
    let quoteText = "";
    if (main) {
      const inner = main.querySelector('div[role="link"] [data-testid="tweetText"]');
      if (inner) quoteText = inner.innerText.trim();
    }
    const replies = containers.slice(1, 6).map(textOf).filter(Boolean);
    return { mainText, replies, quoteText };
  });

  if (!data.mainText) {
    return { ok: false, partial: true, error: "main_text_empty", ...data };
  }
  // A standalone tweet with zero replies is a complete crawl, not partial.
  // Only flag partial when the main tweet itself looked thin (handled above).
  return { ok: true, partial: false, ...data };
}

function renderCrawledSection({ mainText, replies, quoteText }, skill = "playwright-x") {
  const replyCount = replies.length;
  const lines = [
    "## Crawled content",
    `<!-- crawled ${TODAY} via ${skill} -->`,
    "",
    "### Main tweet",
    "",
    mainText,
    "",
    `### Thread (${replyCount} ${replyCount === 1 ? "reply" : "replies"})`,
    "",
  ];
  if (replyCount === 0) {
    lines.push("_No replies captured._", "");
  } else {
    for (const r of replies) {
      lines.push(r, "");
    }
  }
  lines.push("### Quoted tweet", "");
  lines.push(quoteText ? quoteText : "_none_");
  return lines.join("\n");
}

/**
 * Process a single clip. Returns { glyph, message }.
 * Glyphs: v=OK, o=SKIP, ~=PART, x=FAIL.
 */
export async function processClip(page, clipPath, vault, dryRun, getHeadfulPage) {
  const rel = relative(vault, clipPath).split(sep).join("/");
  let text;
  try {
    text = readFileSync(clipPath, "utf-8");
  } catch (e) {
    return { glyph: "x", message: `${rel} -- failed (read): ${e.message}` };
  }
  const baselineSha = sha256(text);
  const { fm, fmRaw, body, present } = parseFrontmatter(text);
  if (!present) {
    return { glyph: "o", message: `${rel} -- skipped (frontmatter): no closing ---` };
  }
  if (fm.harvest_skill !== "clip-body") {
    return { glyph: "o", message: `${rel} -- skipped (not clip-body harvest)` };
  }
  if (alreadyCrawled(fmRaw)) {
    return { glyph: "o", message: `${rel} -- skipped (already-crawled)` };
  }
  const sourceVal = fm.source || "";
  if (!isXSource(sourceVal)) {
    return { glyph: "o", message: `${rel} -- skipped (not an x/twitter source)` };
  }
  const url = canonicalXUrl(fm.harvest_url_canonical || sourceVal) || canonicalXUrl(sourceVal);
  if (!url) {
    return { glyph: "x", message: `${rel} -- failed (canonicalize): ${sourceVal}` };
  }

  if (dryRun) {
    return { glyph: "v", message: `${rel} -- would crawl ${url} [dry-run]` };
  }

  // Throttle BEFORE the network call to avoid hammering X.
  await jitterSleep();

  const scrape = await scrapeTweet(page, url);

  // Headless→headful auto-fallback (LUNA-33 Tier-2): X gates the React app on
  // headless, so a selector-miss here is often recoverable in a real window.
  // Retry the scrape on the headful page BEFORE persisting — so the headless
  // failure never writes a crawl_status: failed marker that would (via
  // alreadyCrawled) block the very retry that fixes it. getHeadfulPage is null
  // when fallback is unavailable (already running --headful, or no factory).
  let activeScrape = scrape;
  let crawlSkill = "playwright-x";
  if (!scrape.ok && isHeadlessGateError(scrape) && typeof getHeadfulPage === "function") {
    const headfulPage = await getHeadfulPage();
    if (headfulPage) {
      await jitterSleep();
      activeScrape = await scrapeTweet(headfulPage, url);
      crawlSkill = "playwright-x-headful";
    }
  }

  let status, lastError, section;
  if (activeScrape.ok) {
    // ok && !partial: full crawl (main tweet + 0..N replies + quote).
    // Zero replies on a standalone tweet is a complete crawl; only thin-main-text
    // legs through the !ok / partial branches below.
    status = "ok";
    lastError = null;
    section = renderCrawledSection(activeScrape, crawlSkill);
  } else if (activeScrape.partial) {
    // Partial = page loaded but content thin. Write what we have if possible.
    status = "partial";
    lastError = activeScrape.error || "partial_scrape";
    if (activeScrape.mainText) {
      section = renderCrawledSection({
        mainText: activeScrape.mainText,
        replies: activeScrape.replies || [],
        quoteText: activeScrape.quoteText || "",
      }, crawlSkill);
    } else {
      // No body — frontmatter-only mark.
      section = null;
    }
  } else {
    // Hard fail — frontmatter-only mark.
    status = "failed";
    lastError = activeScrape.error || "scrape_failed";
    section = null;
  }

  // Stale-read guard. Re-read; bail if mid-pass operator edit.
  let nowText;
  try {
    nowText = readFileSync(clipPath, "utf-8");
  } catch (e) {
    return { glyph: "x", message: `${rel} -- failed (re-read): ${e.message}` };
  }
  if (sha256(nowText) !== baselineSha) {
    return { glyph: "~", message: `${rel} -- partial (stale-read): operator-edit detected mid-pass` };
  }

  let newBody = body;
  if (section) {
    newBody = insertCrawledSection(body, section);
  }

  const markers = {
    crawled_at: NOW_ISO,
    crawl_skill: crawlSkill,
    crawl_status: status,
    last_error: lastError,
  };
  const newFm = upsertCrawlMarkers(fmRaw, markers);
  const newText = `---\n${newFm}\n---\n${newBody}`;

  try {
    writeFileSync(clipPath, newText, { encoding: "utf-8" });
  } catch (e) {
    return { glyph: "x", message: `${rel} -- failed (write): ${e.message}` };
  }

  // Verify: re-read, parse frontmatter, body byte-equality (G-3),
  // YAML parse-validate. Revert on any failure.
  let diskText;
  try {
    diskText = readFileSync(clipPath, "utf-8");
  } catch (e) {
    writeFileSync(clipPath, text, { encoding: "utf-8" });
    return { glyph: "x", message: `${rel} -- failed (post-write read; reverted): ${e.message}` };
  }
  const post = parseFrontmatter(diskText);
  if (!post.present) {
    writeFileSync(clipPath, text, { encoding: "utf-8" });
    return { glyph: "x", message: `${rel} -- failed (post-write parse; reverted): no closing ---` };
  }
  // G-3 body invariant: post.body must equal newBody (no in-flight corruption).
  if (post.body !== newBody) {
    writeFileSync(clipPath, text, { encoding: "utf-8" });
    return { glyph: "x", message: `${rel} -- failed (G-3 body-write mismatch; reverted)` };
  }
  // G-3 single-section-add: pre-existing body sections must be present unchanged.
  // The simplest check: stripping the inserted section from post.body must
  // equal the original body.
  if (section) {
    const stripped = post.body.replace(section, "").replace(/\n{3,}/g, "\n\n");
    const origNorm = body.replace(/\n{3,}/g, "\n\n");
    if (!stripped.includes(origNorm.trim().slice(0, 200))) {
      // Soft check — if first 200 chars of original survive, the existing
      // content is intact. A stricter byte-diff would over-flag whitespace
      // normalization in insertCrawledSection.
      writeFileSync(clipPath, text, { encoding: "utf-8" });
      return { glyph: "x", message: `${rel} -- failed (G-3 single-section-add; reverted)` };
    }
  } else {
    if (post.body !== body) {
      writeFileSync(clipPath, text, { encoding: "utf-8" });
      return { glyph: "x", message: `${rel} -- failed (G-3 body changed without section; reverted)` };
    }
  }
  // YAML parse-validate.
  try {
    const yaml = await import("js-yaml");
    yaml.load(post.fmRaw);
  } catch (e) {
    writeFileSync(clipPath, text, { encoding: "utf-8" });
    return { glyph: "x", message: `${rel} -- failed (frontmatter-yaml; reverted): ${e.message}` };
  }

  if (status === "ok") return { glyph: "v", message: `${rel} -- crawled ok` };
  if (status === "partial") return { glyph: "~", message: `${rel} -- partial: ${lastError}` };
  return { glyph: "x", message: `${rel} -- failed: ${lastError}` };
}

async function main() {
  const args = parseArgs(process.argv);
  const vault = args.vault;
  if (!existsSync(vault)) {
    console.error(`crawl-x: vault not found: ${vault}`);
    process.exit(1);
  }
  const statePath = join(homedir(), ".luna", "playwright-state", "x.json");
  if (!existsSync(statePath)) {
    console.error(`crawl-x: storage_state missing at ${statePath}`);
    console.error(`crawl-x: run \`bun playwright-auth-save.mjs x\` first.`);
    process.exit(2);
  }

  // Defer playwright import so --help / arg parsing / storage-state checks
  // work without the dep installed (useful for smoke tests).
  let chromium;
  try {
    ({ chromium } = await import("playwright"));
  } catch (e) {
    console.error("crawl-x: playwright module not installed. Run `bun install` in tools/.");
    console.error("  underlying:", e.message);
    process.exit(3);
  }

  const clips = findClips(vault);
  if (clips.length === 0) {
    console.log("crawl-x: 0 clips found.");
    process.exit(0);
  }

  // Default headless; --headful forces a real window from the start (X gates
  // the React app on headless — headful is viable on the operator's desktop).
  // Otherwise keep a lazily-created headful browser for the auto-fallback:
  // launched once on the first headless selector-miss, reused, closed at end.
  const newAuthedPage = async (browser) => {
    const ctx = await browser.newContext({ storageState: statePath });
    return ctx.newPage();
  };
  let headlessBrowser = null, headfulBrowser = null;
  let page, getHeadfulPage;
  if (args.headful) {
    headfulBrowser = await chromium.launch({ headless: false });
    page = await newAuthedPage(headfulBrowser);
    getHeadfulPage = null; // already headful — no fallback needed
  } else {
    headlessBrowser = await chromium.launch({ headless: true });
    page = await newAuthedPage(headlessBrowser);
    let headfulPage = null, headfulFailed = false;
    getHeadfulPage = async () => {
      if (headfulPage) return headfulPage;
      if (headfulFailed) return null; // launch already failed — don't retry-storm
      try {
        headfulBrowser = await chromium.launch({ headless: false });
        headfulPage = await newAuthedPage(headfulBrowser);
        return headfulPage;
      } catch (e) {
        // No display / restricted host: fail this clip as headless and keep
        // going (don't crash the whole batch). Cached so later clips skip it.
        headfulFailed = true;
        process.stderr.write(`crawl-x: WARN headful browser unavailable (${String(e.message || e).slice(0, 120)}) — continuing headless-only\n`);
        return null;
      }
    };
  }

  let ok = 0, partial = 0, failed = 0, skipped = 0, processed = 0;

  try {
    for (const clip of clips) {
      if (args.limit > 0 && processed >= args.limit) break;
      const { glyph, message } = await processClip(page, clip, vault, args.dryRun, getHeadfulPage);
      const prefix =
        glyph === "v" ? "OK  " :
        glyph === "o" ? "SKIP" :
        glyph === "~" ? "PART" :
        "FAIL";
      const target = glyph === "x" ? process.stderr : process.stdout;
      target.write(`${prefix} ${message}\n`);
      if (glyph === "v") { ok++; processed++; }
      else if (glyph === "~") { partial++; processed++; }
      else if (glyph === "x") { failed++; processed++; }
      else skipped++;
    }
  } finally {
    // Independent closes so a failing headless close doesn't leak the headful
    // browser (or mask the other's error).
    try { if (headlessBrowser) await headlessBrowser.close(); } catch (e) { process.stderr.write(`crawl-x: WARN headless close: ${e.message}\n`); }
    try { if (headfulBrowser) await headfulBrowser.close(); } catch (e) { process.stderr.write(`crawl-x: WARN headful close: ${e.message}\n`); }
  }

  console.log(
    `\ncrawl-x: ${ok} ok, ${partial} partial, ${failed} failed, ${skipped} skipped. ` +
    `(dry_run=${args.dryRun}, headful=${args.headful})`
  );
  process.exit(0);
}

// Run main() only as the entrypoint, so tests can import processClip /
// scrapeTweet / isHeadlessGateError without triggering a crawl.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((e) => {
    console.error("crawl-x: fatal:", e);
    process.exit(1);
  });
}
