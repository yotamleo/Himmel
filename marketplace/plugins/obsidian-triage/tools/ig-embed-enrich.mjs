#!/usr/bin/env node
/**
 * ig-embed-enrich.mjs — browser-free, no-login Instagram clip enricher.
 *
 * For every clip in <vault>/Clippings/ with:
 *   - source: matching instagram.com/(p|reel|reels|tv)/<shortcode>
 *   - no existing enriched_at: marker
 *
 * fetch https://www.instagram.com/<kind>/<shortcode>/embed/captioned/,
 * parse the caption HTML, and add frontmatter markers + a
 * "## Crawled content" body section.
 *
 * NOTE: `reels` is normalised to `reel` in the embed URL (Instagram
 * accepts both; `reel` is canonical).
 *
 * Login-walled / removed posts return the embed page without a Caption
 * div — treated as enrichment_status: failed (not an exception).
 * These clips remain for the LUNA-27 authenticated rung.
 *
 * G-3 invariant: existing body sections are byte-identical post-write.
 * Only "## Crawled content" may be added. Frontmatter mutation is
 * whitelisted to FM_KEYS below. YAML parse-validate post-write; revert
 * to baseline on parse failure.
 *
 * Idempotent: re-runs skip clips with enriched_at: already present.
 *
 * DELIBERATE deviation from fxtwitter-enrich.mjs: this rung does NOT
 * gate on `processed: true`. IG enrichment is harvest-layer (feeds
 * triage), like the YouTube rung's harvest-gate — not post-triage like
 * the X rung.
 *
 * Usage:
 *   bun ig-embed-enrich.mjs --vault <path> [--limit N] [--dry-run]
 *
 * Exit codes:
 *   0 — run completed (may include partial/failed clips; see summary)
 *   1 — bad usage
 *
 * HIMMEL-280. Sister authenticated rung: LUNA-27 (playwright-crawl-ig.mjs,
 * not yet implemented). No-login limitation: login-walled / removed posts
 * return enrichment_status: failed; run LUNA-27 for those clips.
 */
import { existsSync, readFileSync, writeFileSync, readdirSync } from "node:fs";
import { join, relative, sep } from "node:path";
import { createHash } from "node:crypto";

const TODAY = new Date().toISOString().slice(0, 10);
const RATE_LIMIT_MS = 800;
const FETCH_TIMEOUT_MS = 15000;
const FM_KEYS = [
  "enriched_at",
  "enrichment_source",
  "enrichment_status",
  "ig_author",
  "last_error",
];

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

function usage(code = 1) {
  const out = code === 0 ? console.log : console.error;
  out("Usage: ig-embed-enrich.mjs --vault <path> [--limit N] [--dry-run]");
  out("");
  out("Enrich Instagram clips via embed/captioned/ (no browser, no auth).");
  out("Clips with enriched_at: already set are skipped (idempotent).");
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

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

function sha256(s) {
  return createHash("sha256").update(s).digest("hex");
}

// ---------------------------------------------------------------------------
// Clip discovery — mirrors fxtwitter-enrich.mjs exactly
// ---------------------------------------------------------------------------

function findClips(vault) {
  const root = join(vault, "Clippings");
  if (!existsSync(root)) {
    console.error(`ig-embed-enrich: no Clippings/ dir at ${root}`);
    return [];
  }
  const out = [];
  for (const e of readdirSync(root, { withFileTypes: true })) {
    if (e.isFile() && e.name.endsWith(".md")) {
      out.push(join(root, e.name));
    } else if (e.isDirectory()) {
      const sub = join(root, e.name);
      try {
        for (const s of readdirSync(sub, { withFileTypes: true })) {
          if (s.isFile() && s.name.endsWith(".md")) out.push(join(sub, s.name));
        }
      } catch (e) {
        console.error(`ig-embed-enrich: skipping unreadable dir ${sub}: ${e.message}`);
      }
    }
  }
  return out.sort();
}

// ---------------------------------------------------------------------------
// Frontmatter parsing — mirrors fxtwitter-enrich.mjs
// ---------------------------------------------------------------------------

function parseFrontmatter(text) {
  const hasCrlf = text.includes("\r\n");
  const normalized = hasCrlf ? text.replace(/\r\n/g, "\n") : text;
  if (!normalized.startsWith("---\n")) return { fm: null, fmRaw: "", body: normalized, present: false, hasCrlf };
  const end = normalized.indexOf("\n---\n", 4);
  if (end < 0) return { fm: null, fmRaw: "", body: normalized, present: false, hasCrlf };
  const fmRaw = normalized.slice(4, end);
  const body = normalized.slice(end + 5);
  const fm = {};
  for (const line of fmRaw.split("\n")) {
    const m = line.match(/^([a-zA-Z_][a-zA-Z0-9_]*):(.*)$/);
    if (m) fm[m[1]] = m[2].trim();
  }
  return { fm, fmRaw, body, present: true, hasCrlf };
}

function alreadyEnriched(fmRaw) {
  return /^enriched_at:\s*\S/m.test(fmRaw);
}

// ---------------------------------------------------------------------------
// Instagram URL detection + normalisation
// ---------------------------------------------------------------------------

const IG_URL_RE = /^https?:\/\/(?:www\.)?instagram\.com\/(p|reel|reels|tv)\/([A-Za-z0-9_-]+)/;

function isIgSource(sourceVal) {
  if (!sourceVal) return false;
  return IG_URL_RE.test(sourceVal.trim().replace(/^"|"$/g, ""));
}

/**
 * Returns { kind, shortcode } with kind normalised: reels → reel.
 * Returns null on mismatch.
 */
function parseIgUrl(sourceVal) {
  const s = sourceVal.trim().replace(/^"|"$/g, "");
  const m = s.match(IG_URL_RE);
  if (!m) return null;
  const kind = m[1] === "reels" ? "reel" : m[1];
  return { kind, shortcode: m[2] };
}

function embedUrl(kind, shortcode) {
  return `https://www.instagram.com/${kind}/${shortcode}/embed/captioned/`;
}

// ---------------------------------------------------------------------------
// HTML fetch + parsing
// ---------------------------------------------------------------------------

async function fetchEmbed(url) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), FETCH_TIMEOUT_MS);
  try {
    const r = await fetch(url, {
      headers: { "User-Agent": "Mozilla/5.0" },
      redirect: "follow",
      signal: ctrl.signal,
    });
    if (!r.ok) return { ok: false, error: `http_${r.status}` };
    const html = await r.text();
    if (html.length > 2_000_000) return { ok: false, error: "response_too_large" };
    return { ok: true, html };
  } catch (e) {
    return { ok: false, error: `fetch_error: ${(e.message || String(e)).slice(0, 80)}` };
  } finally {
    clearTimeout(t);
  }
}

/**
 * Decode the 5 basic HTML entities.
 */
function decodeHtmlEntities(s) {
  return s
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'");
}

/**
 * Depth-aware Caption div extractor. Finds `<div class="Caption"`, then
 * walks forward counting <div opens vs </div> closes to return the full
 * balanced inner HTML. Handles nested divs that would truncate under a
 * non-greedy regex.
 *
 * Returns null if no Caption div found (login-walled / removed).
 */
function extractCaptionInnerHtml(html) {
  const startTag = '<div class="Caption"';
  const startIdx = html.indexOf(startTag);
  if (startIdx < 0) return null;

  // Find the end of the opening tag (position after ">")
  const tagEnd = html.indexOf(">", startIdx);
  if (tagEnd < 0) return null;

  let depth = 1;
  let pos = tagEnd + 1;
  while (pos < html.length && depth > 0) {
    const nextOpen = html.indexOf("<div", pos);
    const nextClose = html.indexOf("</div>", pos);
    if (nextClose < 0) break; // malformed HTML
    if (nextOpen >= 0 && nextOpen < nextClose) {
      depth++;
      pos = nextOpen + 4;
    } else {
      depth--;
      if (depth === 0) {
        return html.slice(tagEnd + 1, nextClose);
      }
      pos = nextClose + 6;
    }
  }
  return null;
}

/**
 * Parse the embed HTML into { author, caption, posterUrl }.
 * Returns null when no Caption div found (login-walled / removed).
 */
function parseEmbedHtml(html) {
  // Author
  const authorMatch = html.match(/class="CaptionUsername"[^>]*href="https:\/\/www\.instagram\.com\/([^/?"]+)/);
  const author = authorMatch ? authorMatch[1] : null;

  // Caption div — depth-aware to handle nested divs
  const rawInner = extractCaptionInnerHtml(html);
  if (rawInner === null) return null;

  let raw = rawInner;

  // Convert <br> variants to newlines
  raw = raw.replace(/<br\s*\/?>/gi, "\n");

  // Strip remaining tags
  raw = raw.replace(/<[^>]+>/g, "");

  // Decode entities
  raw = decodeHtmlEntities(raw);

  // Collapse 3+ newlines
  raw = raw.replace(/\n{3,}/g, "\n\n");

  // Trim
  raw = raw.trim();

  // Strip a leading line that just duplicates the author username
  if (author) {
    const lines = raw.split("\n");
    if (lines.length > 0 && lines[0].trim() === author) {
      raw = lines.slice(1).join("\n").trim();
    }
  }

  // Strip trailing "View all N comments" fragment (may be inline, no leading newline)
  raw = raw.replace(/\s*View all \d+ comments\s*$/i, "").trim();

  // Poster image (optional) — decode HTML entities in the src attribute value
  const posterMatch = html.match(/class="EmbeddedMediaImage"[^>]*src="([^"]+)"/);
  const posterUrl = posterMatch ? decodeHtmlEntities(posterMatch[1]) : null;

  return { author, caption: raw, posterUrl };
}

// ---------------------------------------------------------------------------
// Frontmatter mutation — mirrors fxtwitter-enrich.mjs
// ---------------------------------------------------------------------------

function formatYamlValue(v) {
  if (v === null || v === undefined) return "";
  if (typeof v === "boolean") return v ? "true" : "false";
  if (typeof v === "number") return String(v);
  if (typeof v === "object") {
    const parts = [];
    for (const [k, val] of Object.entries(v)) {
      parts.push(`${k}: ${formatYamlValue(val)}`);
    }
    return `{ ${parts.join(", ")} }`;
  }
  const s = String(v);
  if (/[:#"\n]|^\s|\s$|^-|^[0-9]/.test(s)) {
    return `"${s.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
  }
  return s;
}

function upsertEnrichMarkers(fmRaw, markers) {
  let lines = fmRaw.split("\n");
  const seen = new Set();
  lines = lines.map((line) => {
    for (const k of FM_KEYS) {
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
    if (lines[i].trim()) { insertIdx = i + 1; break; }
  }
  const toInsert = [];
  for (const k of FM_KEYS) {
    if (seen.has(k)) continue;
    if (markers[k] === undefined || markers[k] === null) continue;
    toInsert.push(`${k}: ${formatYamlValue(markers[k])}`);
  }
  return [...lines.slice(0, insertIdx), ...toInsert, ...lines.slice(insertIdx)].join("\n");
}

// ---------------------------------------------------------------------------
// Body section insertion — mirrors fxtwitter-enrich.mjs placement contract
// ---------------------------------------------------------------------------

function insertCrawledSection(body, sectionMarkdown) {
  const sourceMatch = body.match(/^## Source\b/m);
  const commentsMatch = body.match(/^## Comments\b/m);
  let insertAt;
  if (sourceMatch) insertAt = sourceMatch.index;
  else if (commentsMatch) insertAt = commentsMatch.index;
  else {
    const sep2 = body.endsWith("\n") ? "" : "\n";
    return body + sep2 + "\n" + sectionMarkdown + "\n";
  }
  const before = body.slice(0, insertAt);
  const after = body.slice(insertAt);
  const trailingNewlines = before.match(/\n*$/)[0].length;
  let prefix = before;
  if (trailingNewlines < 2) prefix = before.replace(/\n*$/, "") + "\n\n";
  return prefix + sectionMarkdown + "\n\n" + after;
}

// ---------------------------------------------------------------------------
// Section renderer
// ---------------------------------------------------------------------------

function renderCrawledSection(author, caption, posterUrl) {
  const lines = [
    "## Crawled content",
    `<!-- enriched ${TODAY} via ig-embed (no-login) -->`,
    "",
  ];
  if (author) lines.push(`**@${author}**`, "");
  if (caption) lines.push(caption, "");
  if (posterUrl) lines.push(posterUrl, "");
  // Remove trailing blank line from the array before joining
  while (lines.length > 0 && lines[lines.length - 1] === "") lines.pop();
  return lines.join("\n");
}

// ---------------------------------------------------------------------------
// Per-clip processing
// ---------------------------------------------------------------------------

async function processClip(clipPath, vault, dryRun) {
  const rel = relative(vault, clipPath).split(sep).join("/");
  let text;
  try {
    text = readFileSync(clipPath, "utf-8");
  } catch (e) {
    return { glyph: "x", message: `${rel} -- failed (read): ${e.message}` };
  }
  const baselineSha = sha256(text);
  const { fm, fmRaw, body, present } = parseFrontmatter(text);
  if (!present) return { glyph: "o", message: `${rel} -- skipped (no closing ---)` };
  if (alreadyEnriched(fmRaw)) return { glyph: "o", message: `${rel} -- skipped (already enriched)` };
  const sourceVal = fm.source || "";
  if (!isIgSource(sourceVal)) return { glyph: "o", message: `${rel} -- skipped (not instagram source)` };

  const parsed = parseIgUrl(sourceVal);
  if (!parsed) return { glyph: "x", message: `${rel} -- failed (parse ig url): ${sourceVal}` };

  const url = embedUrl(parsed.kind, parsed.shortcode);

  if (dryRun) return { glyph: "v", message: `${rel} -- would enrich via ${url} [dry-run]` };

  // Rate-limit BEFORE the network call.
  await sleep(RATE_LIMIT_MS);

  const fetched = await fetchEmbed(url);
  if (!fetched.ok) {
    return writeFailure({ clipPath, rel, text, baselineSha, fmRaw, body, error: fetched.error });
  }

  const parsed2 = parseEmbedHtml(fetched.html);
  if (!parsed2) {
    // Login-walled or removed — leave for LUNA-27 authenticated rung.
    return writeFailure({ clipPath, rel, text, baselineSha, fmRaw, body, error: "embed_no_caption" });
  }

  const { author, caption, posterUrl } = parsed2;
  const section = renderCrawledSection(author, caption, posterUrl);

  const markers = {
    enriched_at: TODAY,
    enrichment_source: "ig-embed",
    enrichment_status: "ok",
    ig_author: author || null,
    last_error: null,
  };

  return writeEnrichment({
    clipPath, rel, text, baselineSha, fmRaw, body, markers, section,
    statusGlyph: "v",
    statusMsg: `enriched (author=${author || "unknown"})`,
  });
}

async function writeFailure({ clipPath, rel, text, baselineSha, fmRaw, body, error }) {
  const markers = {
    enriched_at: null,
    enrichment_source: "ig-embed",
    enrichment_status: "failed",
    ig_author: null,
    last_error: error,
  };
  // Write failure markers but no body change; no enriched_at so re-runs pick it up.
  return writeEnrichment({
    clipPath, rel, text, baselineSha, fmRaw, body, markers, section: null,
    statusGlyph: "~",
    statusMsg: `failed (${error}) — kept for LUNA-27`,
  });
}

async function writeEnrichment({ clipPath, rel, text, baselineSha, fmRaw, body, markers, section, statusGlyph, statusMsg }) {
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
  const newFm = upsertEnrichMarkers(fmRaw, markers);

  // CRLF preservation: re-join with CRLF if original text used CRLF line endings.
  const { hasCrlf } = parseFrontmatter(text);
  let newText = `---\n${newFm}\n---\n${newBody}`;
  if (hasCrlf) newText = newText.replace(/\n/g, "\r\n");

  try {
    writeFileSync(clipPath, newText, { encoding: "utf-8" });
  } catch (e) {
    return { glyph: "x", message: `${rel} -- failed (write): ${e.message}` };
  }

  // Verify + revert-on-failure.
  let diskText;
  try {
    diskText = readFileSync(clipPath, "utf-8");
  } catch (e) {
    try {
      writeFileSync(clipPath, text, { encoding: "utf-8" });
    } catch (revertErr) {
      process.stderr.write(`REVERT ALSO FAILED for ${rel}: ${revertErr.message}\n`);
    }
    return { glyph: "x", message: `${rel} -- failed (post-write read; reverted): ${e.message}` };
  }
  const post = parseFrontmatter(diskText);
  if (!post.present) {
    try {
      writeFileSync(clipPath, text, { encoding: "utf-8" });
    } catch (revertErr) {
      process.stderr.write(`REVERT ALSO FAILED for ${rel}: ${revertErr.message}\n`);
    }
    return { glyph: "x", message: `${rel} -- failed (post-write parse; reverted)` };
  }
  if (post.body !== newBody) {
    try {
      writeFileSync(clipPath, text, { encoding: "utf-8" });
    } catch (revertErr) {
      process.stderr.write(`REVERT ALSO FAILED for ${rel}: ${revertErr.message}\n`);
    }
    return { glyph: "x", message: `${rel} -- failed (G-3 body-write mismatch; reverted)` };
  }
  // G-3 single-section-add check.
  if (section) {
    const stripped = post.body.replace(section, "").replace(/\n{3,}/g, "\n\n");
    const origNorm = body.replace(/\n{3,}/g, "\n\n");
    if (!stripped.includes(origNorm.trim().slice(0, 200))) {
      try {
        writeFileSync(clipPath, text, { encoding: "utf-8" });
      } catch (revertErr) {
        process.stderr.write(`REVERT ALSO FAILED for ${rel}: ${revertErr.message}\n`);
      }
      return { glyph: "x", message: `${rel} -- failed (G-3 single-section-add; reverted)` };
    }
  } else if (post.body !== body) {
    try {
      writeFileSync(clipPath, text, { encoding: "utf-8" });
    } catch (revertErr) {
      process.stderr.write(`REVERT ALSO FAILED for ${rel}: ${revertErr.message}\n`);
    }
    return { glyph: "x", message: `${rel} -- failed (G-3 body changed without section; reverted)` };
  }
  // YAML parse-validate (js-yaml imported at main() startup).
  try {
    yaml.load(post.fmRaw);
  } catch (e) {
    try {
      writeFileSync(clipPath, text, { encoding: "utf-8" });
    } catch (revertErr) {
      process.stderr.write(`REVERT ALSO FAILED for ${rel}: ${revertErr.message}\n`);
    }
    return { glyph: "x", message: `${rel} -- failed (yaml parse; reverted): ${e.message}` };
  }
  return { glyph: statusGlyph, message: `${rel} -- ${statusMsg}` };
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

// Module-level variable; populated in main() after fail-fast import check.
let yaml;

async function main() {
  // js-yaml fail-fast: import once and exit cleanly if missing.
  try {
    yaml = await import("js-yaml");
  } catch {
    console.error("ig-embed-enrich: js-yaml not installed — run 'bun install'");
    process.exit(1);
  }

  const args = parseArgs(process.argv);
  if (!existsSync(args.vault)) {
    console.error(`ig-embed-enrich: vault not found: ${args.vault}`);
    process.exit(1);
  }
  const clips = findClips(args.vault);
  if (clips.length === 0) {
    console.log("ig-embed-enrich: 0 clips found.");
    process.exit(0);
  }

  let enriched = 0, partial = 0, failed = 0, skipped = 0, processed = 0;
  for (const clip of clips) {
    if (args.limit > 0 && processed >= args.limit) break;
    const res = await processClip(clip, args.vault, args.dryRun);
    const prefix =
      res.glyph === "v" ? "OK  " :
      res.glyph === "o" ? "SKIP" :
      res.glyph === "~" ? "PART" :
      "FAIL";
    const target = res.glyph === "x" ? process.stderr : process.stdout;
    target.write(`${prefix} ${res.message}\n`);
    if (res.glyph === "v") { enriched++; processed++; }
    else if (res.glyph === "~") { partial++; processed++; }
    else if (res.glyph === "x") { failed++; processed++; }
    else skipped++;
  }
  console.log(`\nig-embed-enrich: ${enriched} enriched, ${partial} partial, ${failed} failed, ${skipped} skipped. (dry_run=${args.dryRun})`);
  process.exit(0);
}

const _argv1 = (process.argv[1] || "").replace(/\\/g, "/");
const _isMain = import.meta.main === true || _argv1.endsWith("ig-embed-enrich.mjs");

if (_isMain) {
  main().catch((e) => {
    console.error("ig-embed-enrich: fatal:", e);
    process.exit(1);
  });
}
