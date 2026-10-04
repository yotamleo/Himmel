#!/usr/bin/env node
/**
 * playwright-crawl-youtube.mjs — batch enrich YouTube clips (transcript-only MVP).
 *
 * For every clip in <vault>/Clippings/ with:
 *   - harvest_skill: clip-body
 *   - source: youtube.com/watch?v=<id> or youtu.be/<id>
 *   - no existing crawled_at: marker
 *
 * navigate to the video, scrape metadata + transcript + top comments, fold
 * a "## Crawled content" section into the clip body BEFORE "## Source" (or
 * "## Comments" if no Source).
 *
 * Scope (MVP): TRANSCRIPT ONLY. No video download, no STT, no keyframes.
 * If transcript unavailable (no auto-CC, age-gated, etc.): mark partial,
 * skip the transcript block, still capture metadata + comments.
 *
 * G-3 + idempotency + YAML parse-validate: same contract as crawl-x.
 *
 * Usage:
 *   bun playwright-crawl-youtube.mjs --vault <path> [--limit N] [--dry-run]
 *
 * Exit codes:
 *   0 — run completed (may include partial/failed clips; see summary)
 *   1 — bad usage
 *   2 — storage_state missing (run playwright-auth-save.mjs youtube first)
 *   3 — playwright module missing
 *
 * LUNA-27.
 */
import { existsSync, readFileSync, writeFileSync, readdirSync } from "node:fs";
import { homedir } from "node:os";
import { join, relative, sep } from "node:path";
import { createHash } from "node:crypto";

const TODAY = new Date().toISOString().slice(0, 10);
const NOW_ISO = new Date().toISOString();
const SLEEP_MIN_MS = 3000;
const SLEEP_MAX_MS = 5000;
const NAV_TIMEOUT_MS = 20000;
const TRANSCRIPT_WAIT_MS = 6000;

function usage(code = 1) {
  console.error("Usage: playwright-crawl-youtube.mjs --vault <path> [--limit N] [--dry-run]");
  console.error("");
  console.error("Pre-req: ~/.luna/playwright-state/youtube.json (run playwright-auth-save.mjs youtube).");
  process.exit(code);
}

function parseArgs(argv) {
  const out = { vault: null, limit: 0, dryRun: false };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--vault") out.vault = argv[++i];
    else if (a === "--limit") out.limit = parseInt(argv[++i] || "0", 10) || 0;
    else if (a === "--dry-run") out.dryRun = true;
    else if (a === "-h" || a === "--help") usage(0);
    else {
      console.error(`unknown arg: ${a}`);
      usage(1);
    }
  }
  if (!out.vault) usage(1);
  return out;
}

function sleep(ms) { return new Promise((r) => setTimeout(r, ms)); }
function jitterSleep() {
  const ms = SLEEP_MIN_MS + Math.floor(Math.random() * (SLEEP_MAX_MS - SLEEP_MIN_MS));
  return sleep(ms);
}
function sha256(s) { return createHash("sha256").update(s).digest("hex"); }

function findClips(vault) {
  const root = join(vault, "Clippings");
  if (!existsSync(root)) {
    console.error(`crawl-youtube: no Clippings/ dir at ${root}`);
    return [];
  }
  const out = [];
  const entries = readdirSync(root, { withFileTypes: true });
  for (const e of entries) {
    if (e.isFile() && e.name.endsWith(".md")) {
      out.push(join(root, e.name));
    } else if (e.isDirectory()) {
      const sub = join(root, e.name);
      try {
        for (const s of readdirSync(sub, { withFileTypes: true })) {
          if (s.isFile() && s.name.endsWith(".md")) {
            out.push(join(sub, s.name));
          }
        }
      } catch { /* skip */ }
    }
  }
  return out.sort();
}

function parseFrontmatter(text) {
  // CRLF → LF normalisation: see crawl-x.mjs parseFrontmatter docs. Without
  // this, Windows-edited clips skip silently as 'no closing ---'.
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

function isYouTubeSource(sourceVal) {
  if (!sourceVal) return false;
  const s = sourceVal.trim().replace(/^"|"$/g, "");
  return /^https?:\/\/(www\.|m\.)?(youtube\.com\/watch\?v=|youtu\.be\/)/.test(s);
}

function canonicalYouTubeUrl(sourceVal) {
  const s = sourceVal.trim().replace(/^"|"$/g, "");
  let m = s.match(/^https?:\/\/(?:www\.|m\.)?youtube\.com\/watch\?v=([A-Za-z0-9_-]{6,})/);
  if (m) return `https://www.youtube.com/watch?v=${m[1]}`;
  m = s.match(/^https?:\/\/(?:www\.)?youtu\.be\/([A-Za-z0-9_-]{6,})/);
  if (m) return `https://www.youtube.com/watch?v=${m[1]}`;
  return null;
}

function formatYamlValue(v) {
  if (typeof v !== "string") return String(v);
  if (/[:#"\n]|^\s|\s$|^-|^[0-9]/.test(v)) {
    return `"${v.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
  }
  return v;
}

function upsertCrawlMarkers(fmRaw, markers) {
  const orderedKeys = ["crawled_at", "crawl_skill", "crawl_status", "last_error"];
  let lines = fmRaw.split("\n");
  const seen = new Set();
  lines = lines.map((line) => {
    for (const k of orderedKeys) {
      const re = new RegExp(`^${k}:`);
      if (re.test(line)) {
        seen.add(k);
        if (markers[k] === undefined || markers[k] === null) return null;
        return `${k}: ${formatYamlValue(markers[k])}`;
      }
    }
    return line;
  }).filter((l) => l !== null);

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

function insertCrawledSection(body, sectionMarkdown) {
  const sourceMatch = body.match(/^## Source\b/m);
  const commentsMatch = body.match(/^## Comments\b/m);
  let insertAt;
  if (sourceMatch) insertAt = sourceMatch.index;
  else if (commentsMatch) insertAt = commentsMatch.index;
  else {
    const sep = body.endsWith("\n") ? "" : "\n";
    return body + sep + "\n" + sectionMarkdown + "\n";
  }
  const before = body.slice(0, insertAt);
  const after = body.slice(insertAt);
  const trailingNewlines = before.match(/\n*$/)[0].length;
  let prefix = before;
  if (trailingNewlines < 2) {
    prefix = before.replace(/\n*$/, "") + "\n\n";
  }
  return prefix + sectionMarkdown + "\n\n" + after;
}

/**
 * Scrape video metadata + transcript + top comments.
 * Selector strategy (verify periodically — YouTube DOM changes):
 *   - h1.ytd-watch-metadata: video title
 *   - ytd-channel-name #text: channel
 *   - .ytp-time-duration: duration (player chrome)
 *   - #info #info-text yt-formatted-string: publish date
 *   - ytd-watch-metadata #info span.bold: view count fragment
 *   - Transcript: click "Show transcript" — robust via aria-label search.
 *   - Comments: scroll until ytd-comments renders, then collect ytd-comment-thread-renderer top 10.
 */
async function scrapeVideo(page, url) {
  try {
    await page.goto(url, { waitUntil: "domcontentloaded", timeout: NAV_TIMEOUT_MS });
  } catch (e) {
    return { ok: false, partial: false, error: `nav_timeout: ${e.message.slice(0, 120)}` };
  }
  try {
    await page.waitForSelector("h1.ytd-watch-metadata, h1.title", { timeout: NAV_TIMEOUT_MS });
  } catch {
    return { ok: false, partial: false, error: "player_not_rendered" };
  }
  await page.waitForTimeout(2000);

  // Metadata.
  const meta = await page.evaluate(() => {
    const text = (sel) => {
      const el = document.querySelector(sel);
      return el ? el.textContent.trim() : "";
    };
    const title =
      text("h1.ytd-watch-metadata yt-formatted-string") ||
      text("h1.ytd-watch-metadata") ||
      text("h1.title");
    const channel =
      text("ytd-channel-name #text a") ||
      text("ytd-channel-name #text") ||
      text("ytd-video-owner-renderer ytd-channel-name");
    const duration = text(".ytp-time-duration");
    // Publish + views are typically TWO yt-formatted-string elements inside
    // #info-strings (DOM varies by YouTube experiment cell). Collect ALL of
    // them and join with ' · ' so we don't drop one or the other.
    const infoEls = Array.from(
      document.querySelectorAll("#info-strings yt-formatted-string")
    );
    let infoLine = infoEls
      .map((el) => el.textContent.trim())
      .filter(Boolean)
      .join(" · ");
    if (!infoLine) {
      infoLine =
        text("ytd-watch-info-text") ||
        text("#description-inline-expander #info") ||
        "";
    }
    return { title, channel, duration, infoLine };
  });

  // Try to open the transcript.
  let transcript = null;
  let transcriptError = null;
  try {
    // Two strategies: (1) explicit transcript button by aria-label,
    // (2) more-actions menu → "Show transcript" item.
    const direct = await page.$('button[aria-label*="transcript" i]');
    if (direct) {
      await direct.click({ timeout: 3000 });
    } else {
      // Menu approach: click the three-dot under-video menu, then click the item.
      const moreBtn = await page.$('ytd-watch-metadata #button-shape button[aria-label*="more" i], #menu button[aria-label*="More actions" i]');
      if (moreBtn) {
        await moreBtn.click({ timeout: 3000 });
        await page.waitForTimeout(500);
        const item = await page.$('tp-yt-paper-item:has-text("Show transcript"), ytd-menu-service-item-renderer:has-text("Show transcript")');
        if (item) await item.click({ timeout: 3000 });
        else throw new Error("transcript_menu_item_missing");
      } else {
        throw new Error("transcript_button_missing");
      }
    }
    await page.waitForSelector("ytd-transcript-segment-renderer, ytd-transcript-renderer", { timeout: TRANSCRIPT_WAIT_MS });
    transcript = await page.evaluate(() => {
      const rows = Array.from(document.querySelectorAll("ytd-transcript-segment-renderer"));
      return rows.map((r) => {
        const ts = r.querySelector(".segment-timestamp")?.textContent.trim() || "";
        const tx = r.querySelector(".segment-text")?.textContent.trim() || "";
        return { ts, tx };
      }).filter((s) => s.ts && s.tx);
    });
    if (!transcript || transcript.length === 0) {
      transcript = null;
      transcriptError = "transcript_empty";
    }
  } catch (e) {
    transcript = null;
    transcriptError = `transcript_unavailable: ${(e.message || String(e)).slice(0, 80)}`;
  }

  // Comments. Scroll to load.
  let comments = [];
  try {
    await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight * 0.5));
    await page.waitForSelector("ytd-comments", { timeout: 8000 });
    await page.waitForTimeout(2000);
    comments = await page.evaluate(() => {
      const threads = Array.from(document.querySelectorAll("ytd-comment-thread-renderer")).slice(0, 10);
      return threads.map((t) => {
        const author = t.querySelector("#author-text")?.textContent.trim() || "";
        const text = t.querySelector("#content-text")?.textContent.trim() || "";
        return { author, text };
      }).filter((c) => c.author && c.text);
    });
  } catch {
    // Comments may be disabled or slow — leave empty.
    comments = [];
  }

  const partial = transcript === null;
  return {
    ok: true,
    partial,
    error: partial ? transcriptError : null,
    title: meta.title,
    channel: meta.channel,
    duration: meta.duration,
    infoLine: meta.infoLine,
    transcript,
    comments,
  };
}

function renderCrawledSection(data) {
  const lines = [
    "## Crawled content",
    `<!-- crawled ${TODAY} via playwright-youtube (transcript-only MVP) -->`,
    "",
    "### Metadata",
    "",
    `- Title: ${data.title || "_unknown_"}`,
    `- Channel: ${data.channel || "_unknown_"}`,
    `- Duration: ${data.duration || "_unknown_"}`,
    `- Info: ${data.infoLine || "_unknown_"}`,
    "",
    "### Transcript",
    "",
  ];
  if (data.transcript && data.transcript.length > 0) {
    for (const seg of data.transcript) {
      lines.push(`[${seg.ts}] ${seg.tx}`, "");
    }
  } else {
    lines.push("_Transcript unavailable._", "");
  }
  lines.push("### Top comments", "");
  if (data.comments && data.comments.length > 0) {
    for (const c of data.comments) {
      const escapedText = c.text.replace(/\n+/g, " ").replace(/"/g, "'").slice(0, 500);
      lines.push(`- **${c.author}** — "${escapedText}"`);
    }
  } else {
    lines.push("_No comments captured._");
  }
  return lines.join("\n");
}

async function processClip(page, clipPath, vault, dryRun) {
  const rel = relative(vault, clipPath).split(sep).join("/");
  let text;
  try {
    text = readFileSync(clipPath, "utf-8");
  } catch (e) {
    return { glyph: "x", message: `${rel} -- failed (read): ${e.message}` };
  }
  const baselineSha = sha256(text);
  const { fm, fmRaw, body, present } = parseFrontmatter(text);
  if (!present) return { glyph: "o", message: `${rel} -- skipped (frontmatter): no closing ---` };
  if (fm.harvest_skill !== "clip-body") return { glyph: "o", message: `${rel} -- skipped (not clip-body harvest)` };
  if (alreadyCrawled(fmRaw)) return { glyph: "o", message: `${rel} -- skipped (already-crawled)` };

  const sourceVal = fm.source || "";
  if (!isYouTubeSource(sourceVal)) return { glyph: "o", message: `${rel} -- skipped (not youtube source)` };
  const url = canonicalYouTubeUrl(fm.harvest_url_canonical || sourceVal) || canonicalYouTubeUrl(sourceVal);
  if (!url) return { glyph: "x", message: `${rel} -- failed (canonicalize): ${sourceVal}` };

  if (dryRun) return { glyph: "v", message: `${rel} -- would crawl ${url} [dry-run]` };

  await jitterSleep();

  const scrape = await scrapeVideo(page, url);
  let status, lastError, section;
  if (scrape.ok && !scrape.partial) {
    status = "ok";
    lastError = null;
    section = renderCrawledSection(scrape);
  } else if (scrape.ok && scrape.partial) {
    status = "partial";
    lastError = scrape.error || "transcript_unavailable";
    section = renderCrawledSection(scrape);
  } else {
    status = "failed";
    lastError = scrape.error || "scrape_failed";
    section = null;
  }

  // Stale-read guard.
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
  if (section) newBody = insertCrawledSection(body, section);

  const markers = {
    crawled_at: NOW_ISO,
    crawl_skill: "playwright-youtube",
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
  if (post.body !== newBody) {
    writeFileSync(clipPath, text, { encoding: "utf-8" });
    return { glyph: "x", message: `${rel} -- failed (G-3 body-write mismatch; reverted)` };
  }
  if (section) {
    const stripped = post.body.replace(section, "").replace(/\n{3,}/g, "\n\n");
    const origNorm = body.replace(/\n{3,}/g, "\n\n");
    if (!stripped.includes(origNorm.trim().slice(0, 200))) {
      writeFileSync(clipPath, text, { encoding: "utf-8" });
      return { glyph: "x", message: `${rel} -- failed (G-3 single-section-add; reverted)` };
    }
  } else if (post.body !== body) {
    writeFileSync(clipPath, text, { encoding: "utf-8" });
    return { glyph: "x", message: `${rel} -- failed (G-3 body changed without section; reverted)` };
  }
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
  if (!existsSync(args.vault)) {
    console.error(`crawl-youtube: vault not found: ${args.vault}`);
    process.exit(1);
  }
  const statePath = join(homedir(), ".luna", "playwright-state", "youtube.json");
  if (!existsSync(statePath)) {
    console.error(`crawl-youtube: storage_state missing at ${statePath}`);
    console.error(`crawl-youtube: run \`bun playwright-auth-save.mjs youtube\` first.`);
    process.exit(2);
  }

  let chromium;
  try {
    ({ chromium } = await import("playwright"));
  } catch (e) {
    console.error("crawl-youtube: playwright module not installed. Run `bun install` in tools/.");
    console.error("  underlying:", e.message);
    process.exit(3);
  }

  const clips = findClips(args.vault);
  if (clips.length === 0) {
    console.log("crawl-youtube: 0 clips found.");
    process.exit(0);
  }

  const browser = await chromium.launch({ headless: true });
  const ctx = await browser.newContext({ storageState: statePath });
  const page = await ctx.newPage();

  let ok = 0, partial = 0, failed = 0, skipped = 0, processed = 0;

  try {
    for (const clip of clips) {
      if (args.limit > 0 && processed >= args.limit) break;
      const { glyph, message } = await processClip(page, clip, args.vault, args.dryRun);
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
    await browser.close();
  }

  console.log(
    `\ncrawl-youtube: ${ok} ok, ${partial} partial, ${failed} failed, ${skipped} skipped. ` +
    `(dry_run=${args.dryRun})`
  );
  process.exit(0);
}

main().catch((e) => {
  console.error("crawl-youtube: fatal:", e);
  process.exit(1);
});
