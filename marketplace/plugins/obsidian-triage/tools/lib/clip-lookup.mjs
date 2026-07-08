#!/usr/bin/env node
// clip-lookup.mjs — single source of truth for "is this URL already
// harvested (and enriched) in the vault?". Filesystem-only: no network,
// no fetch, no spawn. Returns null (never throws) when the vault or a
// clip is absent, so callers degrade straight to live fetch.
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { canonicalize } from "./url-canonical.mjs";
import { tweetStatusId } from "./telegram-clip.mjs";
import { isThinTweetBody } from "../fxtwitter-enrich.mjs";

export function resolveVaultRoot(opts = {}) {
  const cand =
    opts.vault ||
    process.env.OBSIDIAN_VAULT_PATH ||
    join(homedir(), "Documents", "luna");
  try {
    if (cand && existsSync(join(cand, ".obsidian"))) return cand;
  } catch { /* fall through */ }
  return null;
}

function walk(dir, depth, maxDepth, out) {
  let entries;
  try { entries = readdirSync(dir, { withFileTypes: true }); }
  catch { return; }
  for (const e of entries) {
    if (e.name === "_synthesis") continue;
    const full = join(dir, e.name);
    if (e.isDirectory()) {
      if (depth < maxDepth) walk(full, depth + 1, maxDepth, out);
    } else if (e.name.endsWith(".md") && e.name !== "_deferred.md") {
      out.push(full);
    }
  }
}

export function listClipFiles(vaultRoot) {
  if (!vaultRoot) return [];
  const clip = join(vaultRoot, "Clippings");
  if (!existsSync(clip)) return [];
  const out = [];
  // inbox: depth <=2, exclude _done + _synthesis
  let top;
  try { top = readdirSync(clip, { withFileTypes: true }); } catch { return out; }
  for (const e of top) {
    if (e.name === "_synthesis" || e.name === "_done") continue;
    const full = join(clip, e.name);
    if (e.isDirectory()) walk(full, 2, 2, out);
    else if (e.name.endsWith(".md") && e.name !== "_deferred.md") out.push(full);
  }
  // _done: recursive, exclude _synthesis
  const done = join(clip, "_done");
  if (existsSync(done)) walk(done, 0, 64, out);
  return out;
}

function frontmatter(text) {
  // minimal YAML-ish: grab the leading --- ... --- block as key:value lines
  const m = text.match(/^---\r?\n([\s\S]*?)\r?\n---/);
  const fm = {};
  if (!m) return { fm, body: text };
  for (const line of m[1].split(/\r?\n/)) {
    const km = line.match(/^([A-Za-z0-9_]+):\s*(.*)$/);
    if (km) fm[km[1]] = km[2].replace(/^["']|["']$/g, "").trim();
  }
  return { fm, body: text.slice(m[0].length) };
}

export function clipUrlKeys(rawUrl) {
  return { canon: canonicalize(rawUrl), statusId: tweetStatusId(rawUrl) || null };
}

export function matchesUrl(val, keys) {
  if (!val) return false;
  if (keys.statusId) { const sid = tweetStatusId(val); if (sid && sid === keys.statusId) return true; }
  return canonicalize(val) === keys.canon;
}

export function findHarvestedClipForUrl(vaultRootOrOpts, url) {
  const root =
    typeof vaultRootOrOpts === "string" ? vaultRootOrOpts
    : resolveVaultRoot(vaultRootOrOpts || {});
  if (!root) return null;
  const keys = clipUrlKeys(url);
  for (const path of listClipFiles(root)) {
    let text;
    try { text = readFileSync(path, "utf8"); } catch { continue; }
    const { fm, body } = frontmatter(text);
    if (matchesUrl(fm.source, keys) || matchesUrl(fm.harvest_url_canonical, keys)) {
      return {
        path,
        status: fm.harvest_status || "unharvested",
        enriched: !isThinClipBody(body, fm.type, fm.source),
      };
    }
  }
  return null;
}

const PLACEHOLDER_LINE = (l) => {
  const t = l.trim();
  if (t === "") return true;
  if (/^\*\(.*\)\*$/.test(t)) return true;            // *(prompt)*
  if (/^-(\s*\[ \])?\s*$/.test(t)) return true;        // empty bullet / empty task
  if (/^-\s*\[\[\s*\]\]\s*$/.test(t)) return true;     // - [[]]
  if (/^\[\[\s*\]\]$/.test(t)) return true;            // [[]]
  return false;
};

// article/research content sections (tweet delegates to isThinTweetBody)
const ARTICLE_SECTIONS = ["## Highlights", "## Summary", "## Key Points", "## Core Argument", "## Key Evidence"];

export function isThinClipBody(body, type, source) {
  if (!body) return true;
  // Source-host override (host beats type) — spec §7 (HIMMEL-769). A legacy
  // type:article reddit clip must still route to the reddit predicate.
  if (isRedditHost(source)) return isThinRedditBody(body);
  // instagram media rung (HIMMEL-770): host beats type — an IG clip routes to
  // the IG predicate regardless of type: (browser-clipped IG clips are type:article).
  if (isInstagramHost(source)) return isThinInstagramBody(body);
  // tweet branch: reuse the canonical predicate (spec Item C)
  if (type === "tweet") return isThinTweetBody(body);
  // article/other: drop the ## Source footer, scan known content sections
  const srcIdx = body.lastIndexOf("\n## Source");
  const main = srcIdx >= 0 ? body.slice(0, srcIdx) : body;
  const lines = main.split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    if (ARTICLE_SECTIONS.includes(lines[i].trim())) {
      for (let j = i + 1; j < lines.length; j++) {
        if (/^#{1,6}\s/.test(lines[j].trim())) break;   // next heading
        if (!PLACEHOLDER_LINE(lines[j])) return false;  // real content found
      }
    }
  }
  return true; // no content section had real text → thin
}

/**
 * Reddit source-host test (HIMMEL-769). reddit.com / *.reddit.com / redd.it.
 */
export function isRedditHost(sourceUrl) {
  if (!sourceUrl) return false;
  try {
    const h = new URL(String(sourceUrl).replace(/^["']|["']$/g, "").trim())
      .hostname.toLowerCase().replace(/^www\./, "");
    return h === "reddit.com" || h.endsWith(".reddit.com") || h === "redd.it";
  } catch { return false; }
}

/**
 * Reddit thinness (HIMMEL-769). A reddit clip is thin when its body (below the
 * H1, above the `## Source` footer) has NO meaningful content line — a bare
 * Telegram URL stub. A browser-Web-Clipper thread OR an enriched
 * `## Crawled content` section (real post text / comments) is rich → skipped.
 * Meaningful = a line that is not blank, a heading, an HTML comment, an image,
 * a template italic, a bare URL, a bare markdown-link line, or a placeholder.
 */
export function isThinRedditBody(body) {
  if (!body) return true;
  const srcIdx = body.lastIndexOf("\n## Source");
  const main = srcIdx >= 0 ? body.slice(0, srcIdx) : body;
  for (const raw of main.split(/\r?\n/)) {
    const l = raw.trim();
    if (!l) continue;
    if (/^#{1,6}\s/.test(l)) continue;                       // heading
    if (/^<!--/.test(l)) continue;                           // html comment / marker
    if (/^!\[/.test(l)) continue;                            // image
    if (/^\*\(.*\)\*$/.test(l)) continue;                    // template italic
    if (/^https?:\/\/\S+$/.test(l)) continue;                // bare URL
    if (/^\[[^\]]*\]\(https?:\/\/\S+\)$/.test(l)) continue;  // bare markdown link
    if (PLACEHOLDER_LINE(l)) continue;                       // empty bullet / [[]]
    return false;                                            // real content
  }
  return true;
}

/**
 * Instagram source-host test (HIMMEL-770). instagram.com / *.instagram.com
 * (www./m. aliases). Mirrors isRedditHost.
 */
export function isInstagramHost(sourceUrl) {
  if (!sourceUrl) return false;
  try {
    const h = new URL(String(sourceUrl).replace(/^["']|["']$/g, "").trim())
      .hostname.toLowerCase().replace(/^www\./, "");
    return h === "instagram.com" || h.endsWith(".instagram.com");
  } catch { return false; }
}

// instagram media rung (HIMMEL-770): thin iff ## Crawled content has neither
// a ### Transcript nor a ### Slides subsection (caption-only bodies are thin).
export function isThinInstagramBody(body) {
  if (!body) return true;
  const m = body.match(/^## Crawled content\b/m);
  if (!m) return true;
  let section = body.slice(m.index);
  const nxt = section.slice(1).match(/^## (?!Crawled content)/m);
  if (nxt) section = section.slice(0, nxt.index + 1);
  const hasTranscript = /^### Transcript\b/m.test(section);
  const hasSlides = /^### Slides\b/m.test(section);
  return !(hasTranscript || hasSlides);
}
