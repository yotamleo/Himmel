#!/usr/bin/env node
/**
 * fxtwitter-enrich.mjs — browser-free X-clip enricher via api.fxtwitter.com.
 *
 * For every clip in <vault>/Clippings/ with:
 *   - processed: true (Stage-4 enrichment runs ONLY on triaged clips)
 *   - source: https://x.com/<user>/status/<id> (or twitter.com)
 *   - no existing enriched_at: marker
 *
 * fetch https://api.fxtwitter.com/<user>/status/<id>, add frontmatter markers,
 * and (for X Articles + quote tweets) append a "## Crawled content" body
 * section. Plain tweets and long ("note") tweets are frontmatter-only
 * enrichments — the body already has the raw text from the clip-body harvest.
 *
 * G-3 invariant: existing body sections must be byte-identical post-write.
 * Only "## Crawled content" may be added (articles + quote-context).
 * Frontmatter mutation is whitelisted to the keys listed in FM_KEYS below.
 * YAML parse-validate post-write; revert to baseline on parse failure.
 * Scoped exception: the backfill re-triage reset (body-fill on an
 * already-processed clip) deliberately mutates the body beyond a single
 * section-add — it strips the triage-authored "## Promotion candidate"
 * section and clears processed:/triaged_at:. On that path the single-
 * section-add identity is skipped; the write-matches-intended-newBody check
 * and YAML parse-validate still guard it.
 *
 * Idempotent: re-runs skip clips with enriched_at: already present.
 *
 * Usage:
 *   bun fxtwitter-enrich.mjs --vault <path> [--limit N] [--dry-run]
 *
 * Exit codes:
 *   0 — run completed (may include partial/failed clips; see summary)
 *   1 — bad usage
 *
 * LUNA-33. Sister script: playwright-crawl-x.mjs (deprecated for default
 * use post-LUNA-33 — anti-bot rendering issues on x.com).
 */
import { existsSync, readFileSync, writeFileSync, readdirSync } from "node:fs";
import { join, relative, sep, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
// js-yaml is dynamically imported lazily in writeEnrichment so the
// draftJsToMarkdown export can be loaded by tests without the dep
// installed. Tests don't exercise the write path.

const TODAY = new Date().toISOString().slice(0, 10);
const RATE_LIMIT_MS = 1000;
const FETCH_TIMEOUT_MS = 15000;
const FXT_BASE = "https://api.fxtwitter.com";
const FM_KEYS = [
  "enriched_at",
  "enrichment_source",
  "tweet_stats",
  "tweet_is_note",
  "tweet_is_article",
  "tweet_has_quote",
  "enrichment_status",
  "needs_thread",
  "last_error",
  "author",
  "title",
  "harvest_flag",
  "harvest_flag_detail",
];

// Triage-authored frontmatter keys cleared on the backfill re-triage reset
// (body-fill on an already-processed clip). They are NOT in FM_KEYS, so
// upsertEnrichMarkers won't touch them — they must be filtered explicitly.
const RESET_FM_KEYS = ["processed", "triaged_at"];

// The triage-authored "## Promotion candidate" section: heading + its
// `<!-- triage <date> ... -->` marker, up to the next `## ` heading or
// end-of-body. Stripped on the backfill re-triage reset.
const PROMOTION_SECTION_RE = /\n## Promotion candidate\n<!-- triage (?:(?!-->)[\s\S])*?-->[\s\S]*?(?=\n## |\s*$)/;

function usage(code = 1) {
  const out = code === 0 ? console.log : console.error;
  out("Usage: fxtwitter-enrich.mjs --vault <path> [--limit N] [--dry-run] [--reflag]");
  out("");
  out("Enrich X clips via api.fxtwitter.com (no browser, no auth).");
  out("--reflag: backfill the needs_thread signal onto already-enriched X clips");
  out("          (fetch + re-evaluate; writes ONLY needs_thread, no body change).");
  out("Only clips with `processed: true` are enriched.");
  process.exit(code);
}

function parseArgs(argv) {
  const out = { vault: null, limit: 0, dryRun: false, reflag: false };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--vault") out.vault = argv[++i];
    else if (a === "--limit") out.limit = parseInt(argv[++i] || "0", 10) || 0;
    else if (a === "--dry-run") out.dryRun = true;
    else if (a === "--reflag") out.reflag = true;
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

/**
 * Glob Clippings/*.md + one-level subfolders. Mirrors playwright-crawl-x.mjs.
 */
function findClips(vault) {
  const root = join(vault, "Clippings");
  if (!existsSync(root)) {
    console.error(`fxt-enrich: no Clippings/ dir at ${root}`);
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
      } catch {
        // skip unreadable subdir
      }
    }
  }
  return out.sort();
}

/**
 * Parse top-level frontmatter. Mirrors playwright-crawl-x.mjs — minimal
 * YAML-ish, top-level key: value only, CRLF normalized on read.
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

/**
 * Return true when a tweet clip body carries no real tweet text.
 *
 * A body is "thin" when:
 *   - The `## The Idea` section (if present) contains no meaningful lines
 *     (blank, image, template-italic, or bare URL lines are not meaningful).
 *   - The prose between the H1 title and the first `## ` heading is empty or
 *     only the source URL.
 *
 * Used by body-fill enrichment to decide whether to populate `## The Idea`.
 *
 * @param {string} body - the clip body (text after the frontmatter `---`).
 * @returns {boolean}
 */
export function isThinTweetBody(body) {
  const ideaMatch = body.match(/^## The Idea\s*$/m);
  if (ideaMatch) {
    const after = body.slice(ideaMatch.index + ideaMatch[0].length);
    const next = after.search(/^## /m);
    const section = (next < 0 ? after : after.slice(0, next));
    const meaningful = section.split("\n").map((l) => l.trim())
      .filter((l) => l && !/^!\[/.test(l) && !/^\*\(.*\)\*$/.test(l) && !/^https?:\/\/\S+$/.test(l));
    if (meaningful.length > 0) return false;
  }
  const firstH2 = body.search(/^## /m);
  const head = (firstH2 < 0 ? body : body.slice(0, firstH2));
  const prose = head.split("\n").map((l) => l.trim())
    .filter((l) => l && !l.startsWith("# ") && !/^https?:\/\/\S+$/.test(l));
  return prose.length === 0;
}

function alreadyEnriched(fmRaw) {
  return /^enriched_at:\s*\S/m.test(fmRaw);
}

function isProcessed(fm) {
  const v = (fm.processed || "").toLowerCase().replace(/^"|"$/g, "");
  return v === "true";
}

function isXSource(sourceVal) {
  if (!sourceVal) return false;
  const s = sourceVal.trim().replace(/^"|"$/g, "");
  return /^https?:\/\/(www\.|mobile\.)?(x|twitter)\.com\/[^/]+\/status\/\d+/.test(s);
}

/**
 * Mirrors playwright-crawl-x.mjs canonicalisation: strip mobile./www.,
 * map twitter.com → x.com, drop query/fragment, keep just /user/status/id.
 */
function canonicalXUrl(sourceVal) {
  const s = sourceVal.trim().replace(/^"|"$/g, "");
  const m = s.match(/^https?:\/\/(?:www\.|mobile\.)?(?:x|twitter)\.com(\/[^/]+\/status\/\d+)/);
  if (!m) return null;
  return `https://x.com${m[1]}`;
}

function fxtUrlFor(canonical) {
  // canonical = https://x.com/<user>/status/<id>
  const m = canonical.match(/^https:\/\/x\.com(\/[^/]+\/status\/\d+)/);
  if (!m) return null;
  return `${FXT_BASE}${m[1]}`;
}

/**
 * Fetch the fxtwitter JSON. Returns { ok, tweet, error }.
 */
async function fetchFxt(url) {
  if (process.env.FXT_FIXTURE) {
    try {
      const data = JSON.parse(readFileSync(process.env.FXT_FIXTURE, "utf-8"));
      if (data.code !== 200 || !data.tweet) return { ok: false, error: `api_${data.code}` };
      return { ok: true, tweet: data.tweet };
    } catch (e) { return { ok: false, error: `fixture_err: ${e.message}` }; }
  }
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), FETCH_TIMEOUT_MS);
  try {
    const r = await fetch(url, {
      headers: { Accept: "application/json", "User-Agent": "fxtwitter-enrich/1.0" },
      signal: ctrl.signal,
    });
    if (!r.ok) return { ok: false, error: `http_${r.status}` };
    const data = await r.json();
    if (data.code !== 200 || !data.tweet) {
      return { ok: false, error: `api_${data.code || "unknown"}_${data.message || ""}`.slice(0, 80) };
    }
    return { ok: true, tweet: data.tweet };
  } catch (e) {
    return { ok: false, error: `fetch_err: ${(e.message || String(e)).slice(0, 80)}` };
  } finally {
    clearTimeout(t);
  }
}

// ---------------------------------------------------------------------------
// Draft.js → markdown converter
//
// X Articles serialize as a Draft.js ContentState:
//   { blocks: [{type, text, inlineStyleRanges, entityRanges, depth}, ...],
//     entityMap: { "<key>": { type, mutability, data: {url, ...} } } }
//
// Inline styles overlap arbitrarily; we resolve them by walking the text
// per character, computing the active style-set at each index, and emitting
// markdown delimiter transitions on style-set changes.
//
// Link entities take precedence over inline styles for the wrapping —
// markdown links wrap, and inline styles emit inside the link text.
// ---------------------------------------------------------------------------

const BLOCK_TYPES = new Set([
  "unstyled",
  "header-one",
  "header-two",
  "header-three",
  "header-four",
  "header-five",
  "header-six",
  "unordered-list-item",
  "ordered-list-item",
  "blockquote",
  "code-block",
  "atomic",
]);

const INLINE_DELIMS = {
  // Order matters for emission stability (BOLD outside ITALIC outside CODE).
  // Map style-name → markdown delimiter.
  BOLD: "**",
  ITALIC: "*",
  CODE: "`",
};
const INLINE_ORDER = ["BOLD", "ITALIC", "CODE"];

function mdEscape(s) {
  // Conservative: escape characters that would prematurely terminate
  // inline markdown. Keep newlines (block renderer handles them) and
  // leave backslash-existing escapes alone.
  return s.replace(/([*_`[\]\\])/g, "\\$1");
}

/**
 * Build a per-character style-set for a single block's text. Returns an
 * array of Sets the same length as the text (counting code points as
 * single positions where Draft.js does — Draft's offset/length count
 * UTF-16 code units, so str.length is the right measure).
 */
function buildStyleMap(text, inlineStyleRanges) {
  const styles = new Array(text.length).fill(null).map(() => new Set());
  if (!Array.isArray(inlineStyleRanges)) return styles;
  for (const r of inlineStyleRanges) {
    if (!r || typeof r.offset !== "number" || typeof r.length !== "number") continue;
    const style = r.style;
    if (!style || !(style in INLINE_DELIMS)) continue;
    const start = Math.max(0, r.offset);
    const end = Math.min(text.length, r.offset + r.length);
    for (let i = start; i < end; i++) styles[i].add(style);
  }
  return styles;
}

/**
 * Build a per-character link-key map. null where no link applies.
 */
function buildLinkMap(text, entityRanges, entityMap) {
  const links = new Array(text.length).fill(null);
  if (!Array.isArray(entityRanges) || !entityMap) return links;
  for (const r of entityRanges) {
    if (!r || typeof r.offset !== "number" || typeof r.length !== "number") continue;
    const ent = entityMap[String(r.key)];
    if (!ent || (ent.type || "").toUpperCase() !== "LINK") continue;
    const url = ent.data && (ent.data.url || ent.data.href);
    if (!url) continue;
    const start = Math.max(0, r.offset);
    const end = Math.min(text.length, r.offset + r.length);
    for (let i = start; i < end; i++) links[i] = url;
  }
  return links;
}

function setsEqual(a, b) {
  if (a.size !== b.size) return false;
  for (const v of a) if (!b.has(v)) return false;
  return true;
}

/**
 * Render a single Draft.js block's inline content to markdown.
 * Handles: inline styles (BOLD/ITALIC/CODE), LINK entities. Other
 * inline styles + entity types fall through as plain text.
 */
function renderInline(block, entityMap) {
  const text = typeof block.text === "string" ? block.text : "";
  if (!text) return "";

  const styleMap = buildStyleMap(text, block.inlineStyleRanges || []);
  const linkMap = buildLinkMap(text, block.entityRanges || [], entityMap || {});

  // Walk text, segment by (linkUrl, styleSet) tuple. Emit one segment at a
  // time. Inline delimiters wrap inside link markdown.
  let out = "";
  let i = 0;
  while (i < text.length) {
    const linkUrl = linkMap[i];
    const styleSet = styleMap[i];
    let j = i + 1;
    while (
      j < text.length &&
      linkMap[j] === linkUrl &&
      setsEqual(styleMap[j], styleSet)
    ) {
      j++;
    }
    const slice = text.slice(i, j);
    // Inline-style wrap, in declared order.
    let wrapped = mdEscape(slice);
    // Strip pure whitespace from the styled wrap targets to avoid e.g. "** **".
    const isAllSpace = !slice.trim();
    if (!isAllSpace) {
      for (const k of INLINE_ORDER) {
        if (styleSet.has(k)) {
          const d = INLINE_DELIMS[k];
          wrapped = `${d}${wrapped}${d}`;
        }
      }
    }
    if (linkUrl) {
      // Markdown link with the wrapped inline content as link text.
      const safeUrl = String(linkUrl).replace(/\)/g, "\\)");
      out += `[${wrapped}](${safeUrl})`;
    } else {
      out += wrapped;
    }
    i = j;
  }
  return out;
}

/**
 * Convert a Draft.js content object to markdown.
 * content = { blocks: [...], entityMap: {...} }
 */
export function draftJsToMarkdown(content) {
  if (!content || !Array.isArray(content.blocks)) return "";
  const entityMap = content.entityMap || {};
  const out = [];
  // Numbered-list counter; resets when block type breaks the run.
  let olCounter = 0;
  for (const block of content.blocks) {
    if (!block || typeof block !== "object") continue;
    const type = (block.type || "unstyled");
    if (type !== "ordered-list-item") olCounter = 0;
    const rendered = renderInline(block, entityMap);
    if (!BLOCK_TYPES.has(type)) {
      // Unknown block type — emit text as plain paragraph; preserves content
      // even when the renderer doesn't know the structural meaning.
      out.push(rendered);
    } else if (type === "header-one") out.push(`# ${rendered}`);
    else if (type === "header-two") out.push(`## ${rendered}`);
    else if (type === "header-three") out.push(`### ${rendered}`);
    else if (type === "header-four") out.push(`#### ${rendered}`);
    else if (type === "header-five") out.push(`##### ${rendered}`);
    else if (type === "header-six") out.push(`###### ${rendered}`);
    else if (type === "unordered-list-item") {
      const depth = Math.max(0, Math.min(6, block.depth || 0));
      out.push(`${"  ".repeat(depth)}- ${rendered}`);
    } else if (type === "ordered-list-item") {
      olCounter += 1;
      const depth = Math.max(0, Math.min(6, block.depth || 0));
      out.push(`${"  ".repeat(depth)}${olCounter}. ${rendered}`);
    } else if (type === "blockquote") {
      // Preserve internal newlines as quoted lines.
      const lines = rendered.split("\n").map((l) => `> ${l}`).join("\n");
      out.push(lines || "> ");
    } else if (type === "code-block") {
      // Wrap in fenced code block. Don't markdown-escape inside.
      const raw = (block.text || "");
      out.push(`\`\`\`\n${raw}\n\`\`\``);
    } else if (type === "atomic") {
      // Atomic blocks reference media via entityRanges; render any link entity.
      if (rendered) out.push(rendered);
    } else {
      // unstyled (paragraph).
      out.push(rendered);
    }
  }
  return out.join("\n\n").trim();
}

// ---------------------------------------------------------------------------
// Frontmatter mutation
// ---------------------------------------------------------------------------

function formatYamlValue(v) {
  if (v === null || v === undefined) return "";
  if (typeof v === "boolean") return v ? "true" : "false";
  if (typeof v === "number") return String(v);
  if (Array.isArray(v)) {
    // Flow sequence, e.g. ["@aiedge_"]. Each element formatted recursively
    // so strings get the same quoting/escaping rules.
    return `[${v.map((x) => formatYamlValue(x)).join(", ")}]`;
  }
  if (typeof v === "object") {
    // Flow-style mapping for compact stats: { replies: N, ... }
    const parts = [];
    for (const [k, val] of Object.entries(v)) {
      parts.push(`${k}: ${formatYamlValue(val)}`);
    }
    return `{ ${parts.join(", ")} }`;
  }
  const s = String(v);
  // `@` and backtick are YAML reserved indicators (e.g. @screen_name in a
  // flow sequence) and MUST be quoted or the parse fails.
  if (/[:#"\n]|^\s|\s$|^-|^[0-9]|^[@`]/.test(s)) {
    return `"${s.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
  }
  return s;
}

/**
 * Insert/replace whitelisted frontmatter keys (FM_KEYS). In-place replace
 * when key already exists; append after last non-empty line otherwise.
 * Mirrors playwright-crawl-x.mjs.upsertCrawlMarkers contract.
 */
function upsertEnrichMarkers(fmRaw, markers) {
  let lines = fmRaw.split("\n");
  const seen = new Set();
  lines = lines.map((line) => {
    for (const k of FM_KEYS) {
      const re = new RegExp(`^${k}:`);
      if (re.test(line)) {
        seen.add(k);
        // Key not set this run → leave the existing line UNCHANGED. Critical
        // for keys like `author:` that head a YAML block-list — deleting the
        // key line would orphan its `  - "@handle"` items into invalid YAML
        // (the frontmatter-only enrich path doesn't set author/title). Only an
        // EXPLICIT null marker (e.g. last_error: null to clear) deletes.
        if (!(k in markers)) return line;
        if (markers[k] === null) return null;
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

/**
 * Insert "## Crawled content" BEFORE "## Source" (or "## Comments"). Mirrors
 * playwright-crawl-x.mjs placement contract.
 */
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
// Section renderers
// ---------------------------------------------------------------------------

function renderArticleSection(tweet) {
  const article = tweet.article || {};
  // Collapse any whitespace (incl. newlines) into a single space so the
  // markdown H3 stays on one line. Truncate fallback to 80 chars after
  // collapsing.
  const rawTitle = article.title || tweet.text || "(untitled article)";
  const title = String(rawTitle).replace(/\s+/g, " ").trim().slice(0, 80) || "(untitled article)";
  const content = article.content || {};
  const md = draftJsToMarkdown(content);
  const lines = [
    "## Crawled content",
    `<!-- enriched ${TODAY} via fxtwitter (article) -->`,
    "",
    `### ${title}`,
    "",
    md || "_(article body empty)_",
  ];
  return lines.join("\n");
}

function renderQuoteSection(tweet) {
  // tweet.quote holds the quoted tweet
  const q = tweet.quote || {};
  const author = q.author?.screen_name ? `@${q.author.screen_name}` : "(unknown)";
  const text = (q.raw_text?.text || q.text || "").trim();
  const url = q.url || "";
  const lines = [
    "## Crawled content",
    `<!-- enriched ${TODAY} via fxtwitter (quote-context) -->`,
    "",
    `### Quoted tweet (${author})`,
    "",
    text || "_(no quote text)_",
    "",
  ];
  if (url) lines.push(`[Quoted tweet](${url})`);
  return lines.join("\n");
}

/**
 * Build a populated `## The Idea` section from fetched tweet text.
 *
 * Used by body-fill enrichment to inject tweet text into thin clips.
 *
 * @param {string} text - the tweet's raw text.
 * @returns {string} a markdown section string (no trailing newline).
 */
export function renderIdeaSection(text) {
  const t = String(text || "").trim();
  return ["## The Idea", `<!-- enriched ${TODAY} via fxtwitter (text) -->`, "", t || "_(no tweet text)_"].join("\n");
}

/**
 * Return true when a clip title is a Telegram-harvester placeholder rather
 * than a real title (e.g. "tweet from x.com/i/status/123").
 *
 * Telegram-harvested clips that lack a resolved title arrive with a generated
 * placeholder that encodes the URL. Body-fill enrichment can replace this
 * with the tweet author + text snippet once the fxtwitter payload is fetched.
 *
 * @param {string} title - the clip's H1 title (without the leading `# `).
 * @returns {boolean}
 */
export function isTelegramTitlePlaceholder(title) {
  const s = String(title || "").trim().replace(/^['"]|['"]$/g, "");
  return /^(tweet|article|research|youtube|reddit|note) from (?:x\.com|twitter\.com|mobile\.twitter\.com|\S+)\//.test(s);
}

/**
 * Detect whether a tweet hides content elsewhere — a self-thread
 * continuation ("1/5"), or a payload parked in replies ("repo in comment").
 * Pure + side-effect free. Used to set needs_thread for the escalation pass.
 * Edge-anchors the n/N counter (N in 2..25) to dodge mid-line fractions
 * ("1/2 cup"). Line-start dates ("6/14 …") are an accepted rare false
 * positive — cost is one wasted burner fetch.
 *
 * @param {string} text          tweet.text
 * @param {number} repliesCount  tweet.replies (0 if absent)
 * @returns {boolean}
 */
export function detectThreadSignal(text, repliesCount = 0) {
  if (!text) return false;
  const lines = text.split("\n").map((l) => l.trim());
  const counterRe = /^(\d{1,2})\s*\/\s*(\d{1,2})\b|\b(\d{1,2})\s*\/\s*(\d{1,2})$/;
  const isThreadCounter = lines.some((ln) => {
    const m = ln.match(counterRe);
    if (!m) return false;
    const n = Number(m[1] ?? m[3]);
    const N = Number(m[2] ?? m[4]);
    return N >= 2 && N <= 25 && n >= 1 && n <= N;
  });
  const selfThread =
    isThreadCounter ||
    /\u{1F9F5}/u.test(text) ||            // 🧵
    /\b(a thread|thread:)/i.test(text);
  const replyPointer =
    /repo in (the )?comments?/i.test(text) ||
    /links? in (the )?repl(y|ies)/i.test(text) ||
    /\bin (the )?comments?\b/i.test(text) ||
    /[↓\u{1F447}]/u.test(text);      // ↓ 👇
  return selfThread || (replyPointer && repliesCount > 0);
}

// ---------------------------------------------------------------------------
// Post-body-fill injection re-screen (HIMMEL-256)
//
// Body-fill writes untrusted tweet.text into `## The Idea`. That content
// didn't exist when the harvest-time screen ran, so the just-written clip
// must be re-screened before downstream agents (/triage-clips,
// /synthesize-clips) read it. Flag-only — never blocks. The screener is the
// python tool that owns the canonical pattern list.
// ---------------------------------------------------------------------------

const TOOLS_DIR = dirname(fileURLToPath(import.meta.url));
const SCREENER = join(TOOLS_DIR, "harvest-clip-body-batch.py");

/**
 * Run harvest-clip-body-batch.py --scan-only over a just-written clip.
 *
 * Returns null when the clip is clean (no flag needed), or
 * { detail: "<comma-joined classes>" } when a flag must be upserted.
 * Fail-closed: a scanner error (exit 2), a missing interpreter, or any
 * spawn error all return { detail: "screen-error" } so an unscreenable
 * clip is still flagged rather than passing through trusted.
 *
 * @param {string} clipPath - absolute path to the just-written clip.
 * @returns {{detail: string}|null}
 */
function rescreenInjection(clipPath) {
  const screener = process.env.FXT_SCREENER || SCREENER;
  const args = [screener, "--scan-only", clipPath];
  const opts = { encoding: "utf-8", timeout: 20000, windowsHide: true };
  let res = spawnSync("python", args, opts);
  if (res.error && res.error.code === "ENOENT") {
    res = spawnSync("python3", args, opts);
  }
  if (res.error) {
    // Both interpreters ENOENT, or any other spawn failure — fail-closed.
    return { detail: "screen-error" };
  }
  if (res.status === 0) return null;
  if (res.status === 1) {
    const classes = String(res.stdout || "")
      .split("\n").map((l) => l.trim()).filter(Boolean);
    return { detail: classes.join(",") || "injection-suspect" };
  }
  // Exit 2 (scanner error) or any other non-{0,1} status — fail-closed.
  return { detail: "screen-error" };
}

// ---------------------------------------------------------------------------
// Per-clip processing
// ---------------------------------------------------------------------------

export async function processClip(clipPath, vault, dryRun, opts = {}) {
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

  // --reflag (backfill): the normal enrich path below skips already-enriched
  // clips (alreadyEnriched gate), so X clips enriched BEFORE the
  // detectThreadSignal feature never get a needs_thread evaluation. This branch
  // re-evaluates exactly those: fetch the tweet, run the pure detector, and
  // write ONLY needs_thread:true when it fires — no body mutation, no other
  // marker changes (writeEnrichment with section=null keeps the body
  // byte-identical under the no-section G-3 guard). Idempotent: a clip that
  // already has needs_thread:true is skipped.
  if (opts.reflag) {
    const src = fm.source || "";
    if (!isXSource(src)) return { glyph: "o", message: `${rel} -- skipped (reflag: not x/twitter source)` };
    if (!alreadyEnriched(fmRaw)) return { glyph: "o", message: `${rel} -- skipped (reflag: not enriched — normal enrich handles it)` };
    if (/^needs_thread:\s*true\s*$/m.test(fmRaw)) return { glyph: "o", message: `${rel} -- skipped (reflag: needs_thread already set)` };
    const canon = canonicalXUrl(fm.harvest_url_canonical || src) || canonicalXUrl(src);
    const fxtUrl = canon && fxtUrlFor(canon);
    if (!fxtUrl) return { glyph: "x", message: `${rel} -- failed (reflag canonicalize): ${src}` };
    if (dryRun) return { glyph: "v", message: `${rel} -- would reflag via ${fxtUrl} [dry-run]` };
    if (!opts.skipRateLimit) await sleep(RATE_LIMIT_MS);
    const fxt = await fetchFxt(fxtUrl);
    if (!fxt.ok) return { glyph: "~", message: `${rel} -- partial (reflag fetch): ${fxt.error}` };
    const replies = fxt.tweet.replies ?? 0;
    if (!detectThreadSignal(fxt.tweet.text || "", replies)) {
      return { glyph: "o", message: `${rel} -- skipped (reflag: no thread signal)` };
    }
    return await writeEnrichment({
      clipPath, rel, text, baselineSha, fmRaw, body,
      markers: { needs_thread: true }, section: null, resetTriage: false,
      statusGlyph: "v", statusMsg: "reflagged needs_thread",
    });
  }

  const thinBody = isThinTweetBody(body);
  if (!isProcessed(fm) && !thinBody) {
    return { glyph: "o", message: `${rel} -- skipped (not processed, body not thin)` };
  }
  if (alreadyEnriched(fmRaw)) return { glyph: "o", message: `${rel} -- skipped (already enriched)` };
  const sourceVal = fm.source || "";
  if (!isXSource(sourceVal)) return { glyph: "o", message: `${rel} -- skipped (not x/twitter source)` };

  const canon = canonicalXUrl(fm.harvest_url_canonical || sourceVal) || canonicalXUrl(sourceVal);
  if (!canon) return { glyph: "x", message: `${rel} -- failed (canonicalize): ${sourceVal}` };
  const fxtUrl = fxtUrlFor(canon);
  if (!fxtUrl) return { glyph: "x", message: `${rel} -- failed (build fxt url): ${canon}` };

  if (dryRun) return { glyph: "v", message: `${rel} -- would enrich via ${fxtUrl} [dry-run]` };

  // Rate-limit BEFORE the network call. The single inline telegram-clip call
  // (serial bridge) skips it — politeness only matters for the batch loop.
  if (!opts.skipRateLimit) await sleep(RATE_LIMIT_MS);

  const fxt = await fetchFxt(fxtUrl);
  if (!fxt.ok) {
    // Network / API failure — do NOT write enriched_at, so a re-run picks
    // the clip back up (transient 429s / 5xx clear naturally). Permanent
    // failures (404 tweet-deleted, 401 suspended) will keep tripping this
    // path on every run; the operator handles those out-of-band.
    return { glyph: "~", message: `${rel} -- partial (fxt fetch): ${fxt.error}` };
  }

  const tweet = fxt.tweet;
  const isArticle = !!(tweet.article && tweet.article.content);
  const isNote = !!tweet.is_note_tweet;
  const hasQuote = !!tweet.quote;

  const stats = {
    replies: tweet.replies ?? 0,
    retweets: tweet.retweets ?? 0,
    quotes: tweet.quotes ?? 0,
    likes: tweet.likes ?? 0,
    views: tweet.views ?? 0,
  };

  let section = null;
  // True only on the real-text body-fill path (## The Idea inserted from
  // untrusted tweet.text) — the path that needs the injection re-screen.
  let didBodyFill = false;
  // Body-fill markers for thin plain/note tweets (author/title repair).
  const bodyFill = {};
  if (isArticle) {
    section = renderArticleSection(tweet);
  } else if (hasQuote) {
    section = renderQuoteSection(tweet);
  } else if (thinBody) {
    // Thin plain/note tweet: inject tweet text into `## The Idea`.
    const tweetText = (tweet.text || "").trim();
    if (!tweetText && tweet.media?.all?.length) {
      // Media-only tweet: no text to inject. Mark partial so a later
      // resolver (or operator) can attend to the media.
      const mediaMarkers = {
        enriched_at: TODAY,
        enrichment_source: "fxtwitter",
        enrichment_status: "partial",
        last_error: "media_only",
        tweet_is_note: isNote,
        tweet_is_article: false,
        tweet_has_quote: false,
      };
      return writeEnrichment({ clipPath, rel, text, baselineSha, fmRaw, body, markers: mediaMarkers, section: null, resetTriage: false, statusGlyph: "~", statusMsg: "partial (media_only)" });
    }
    if (!tweetText) {
      // Empty text, no media — write NO marker so a re-run retries (the
      // fxt payload may have been transiently empty).
      return { glyph: "~", message: `${rel} -- partial (tweet_unavailable: empty text)` };
    }
    section = renderIdeaSection(tweet.text);
    didBodyFill = true;
    if (!fm.author) bodyFill.author = [`@${tweet.author?.screen_name || ""}`];
    if (isTelegramTitlePlaceholder(fm.title)) {
      bodyFill.title = tweet.text.replace(/\s+/g, " ").trim().slice(0, 80);
    }
  }
  // Plain tweets + note tweets: frontmatter-only enrichment.

  // Signal whether this clip needs the authenticated thread/reply escalation.
  const needsThread = detectThreadSignal(tweet.text || "", stats.replies || 0);

  const markers = {
    enriched_at: TODAY,
    enrichment_source: "fxtwitter",
    enrichment_status: "ok",
    tweet_stats: stats,
    tweet_is_note: isNote,
    tweet_is_article: isArticle,
    tweet_has_quote: hasQuote,
    ...(needsThread ? { needs_thread: true } : {}),
    last_error: null,
    ...bodyFill,
  };
  const res = await writeEnrichment({ clipPath, rel, text, baselineSha, fmRaw, body, markers, section, resetTriage: thinBody && isProcessed(fm), statusGlyph: "v", statusMsg: `enriched (article=${isArticle}, note=${isNote}, quote=${hasQuote})` });

  // HIMMEL-256: re-screen the just-written clip for prompt injection on the
  // real-text body-fill path only (## The Idea now holds untrusted tweet
  // text). Flag-only — a hit (or a fail-closed screen-error) adds the
  // harvest_flag markers via a second small marker-only write. The body is
  // byte-identical on this second write, so the normal no-section G-3 check
  // protects it. Re-screen only after a verified write (res.glyph === "v").
  if (didBodyFill && res.glyph === "v") {
    const flag = rescreenInjection(clipPath);
    if (flag) {
      const flagMarkers = { harvest_flag: "injection-suspect", harvest_flag_detail: flag.detail };
      // Fail-closed flag-write. If the re-read/parse/write of the flag fails
      // (throw or no parseable frontmatter), the injection verdict would be
      // silently dropped — leaving untrusted tweet.text in `## The Idea` with
      // NO harvest_flag (downstream reads it as trusted). The fail-closed move
      // is to NOT leave the untrusted content on disk: revert to the original
      // pre-enrichment stub (harvest retries later).
      try {
        const enrichedText = readFileSync(clipPath, "utf-8");
        const ep = parseFrontmatter(enrichedText);
        if (!ep.present) {
          writeFileSync(clipPath, text, { encoding: "utf-8" });
          return { glyph: "x", message: `${rel} -- failed (injection flag-write; reverted to stub, fail-closed): no parseable frontmatter on re-read` };
        }
        const flagRes = await writeEnrichment({
          clipPath, rel, text: enrichedText, baselineSha: sha256(enrichedText),
          fmRaw: ep.fmRaw, body: ep.body, markers: flagMarkers, section: null,
          resetTriage: false, statusGlyph: "v",
          statusMsg: `${res.message.replace(`${rel} -- `, "")} [injection-suspect: ${flag.detail}]`,
        });
        return flagRes;
      } catch (e) {
        writeFileSync(clipPath, text, { encoding: "utf-8" });
        return { glyph: "x", message: `${rel} -- failed (injection flag-write; reverted to stub, fail-closed): ${e.message}` };
      }
    }
  }
  return res;
}

/**
 * Write the enriched clip with full G-3 / YAML verification and revert.
 */
async function writeEnrichment({ clipPath, rel, text, baselineSha, fmRaw, body, markers, section, resetTriage = false, statusGlyph, statusMsg }) {
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
  let fmForMarkers = fmRaw;
  if (resetTriage) {
    // Backfill re-triage reset: strip the triage-authored promotion section
    // from the body, and drop processed:/triaged_at: from the frontmatter so
    // a later /triage-clips re-tags the now-rich clip cleanly. These keys are
    // not in FM_KEYS, so upsertEnrichMarkers leaves them — filter explicitly.
    newBody = newBody.replace(PROMOTION_SECTION_RE, "");
    fmForMarkers = fmRaw.split("\n")
      .filter((line) => !RESET_FM_KEYS.some((k) => new RegExp(`^${k}:`).test(line)))
      .join("\n");
  }
  const newFm = upsertEnrichMarkers(fmForMarkers, markers);
  const newText = `---\n${newFm}\n---\n${newBody}`;

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
    writeFileSync(clipPath, text, { encoding: "utf-8" });
    return { glyph: "x", message: `${rel} -- failed (post-write read; reverted): ${e.message}` };
  }
  const post = parseFrontmatter(diskText);
  if (!post.present) {
    writeFileSync(clipPath, text, { encoding: "utf-8" });
    return { glyph: "x", message: `${rel} -- failed (post-write parse; reverted)` };
  }
  if (post.body !== newBody) {
    writeFileSync(clipPath, text, { encoding: "utf-8" });
    return { glyph: "x", message: `${rel} -- failed (G-3 body-write mismatch; reverted)` };
  }
  // G-3 single-section-add: when we added a section, stripping it from the
  // post-write body must leave the original intact. When we didn't, body
  // must be byte-identical to the original.
  //
  // SKIPPED on the backfill re-triage reset: that path deliberately mutates
  // the body beyond a single-section-add (it strips the promotion section),
  // so the single-section-add identity no longer holds. The other guards
  // (post.body === newBody write-succeeded check above, frontmatter-present
  // check above, YAML parse-validate below) still fully protect the write.
  if (!resetTriage) {
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
  }
  // YAML parse-validate. js-yaml imported lazily so test imports
  // of draftJsToMarkdown don't need the dep installed.
  try {
    const yaml = await import("js-yaml");
    yaml.load(post.fmRaw);
  } catch (e) {
    writeFileSync(clipPath, text, { encoding: "utf-8" });
    return { glyph: "x", message: `${rel} -- failed (yaml parse; reverted): ${e.message}` };
  }
  return { glyph: statusGlyph, message: `${rel} -- ${statusMsg}` };
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  const args = parseArgs(process.argv);
  if (!existsSync(args.vault)) {
    console.error(`fxt-enrich: vault not found: ${args.vault}`);
    process.exit(1);
  }
  const clips = findClips(args.vault);
  if (clips.length === 0) {
    console.log("fxt-enrich: 0 clips found.");
    process.exit(0);
  }

  let ok = 0, partial = 0, failed = 0, skipped = 0, processed = 0;
  for (const clip of clips) {
    if (args.limit > 0 && processed >= args.limit) break;
    const res = await processClip(clip, args.vault, args.dryRun, { reflag: args.reflag });
    const prefix =
      res.glyph === "v" ? "OK  " :
      res.glyph === "o" ? "SKIP" :
      res.glyph === "~" ? "PART" :
      "FAIL";
    const target = res.glyph === "x" ? process.stderr : process.stdout;
    target.write(`${prefix} ${res.message}\n`);
    if (res.glyph === "v") { ok++; processed++; }
    else if (res.glyph === "~") { partial++; processed++; }
    else if (res.glyph === "x") { failed++; processed++; }
    else skipped++;
  }
  console.log(`\nfxt-enrich: ${ok} ok, ${partial} partial, ${failed} failed, ${skipped} skipped. (dry_run=${args.dryRun})`);
  process.exit(0);
}

// Run unless imported as a module (tests import draftJsToMarkdown directly).
// import.meta.main is bun-only; fall back to argv[1] basename match for node.
const _argv1 = (process.argv[1] || "").replace(/\\/g, "/");
const _isMain = import.meta.main === true || _argv1.endsWith("fxtwitter-enrich.mjs");

if (_isMain) {
  main().catch((e) => {
    console.error("fxt-enrich: fatal:", e);
    process.exit(1);
  });
}
