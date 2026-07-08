#!/usr/bin/env node
/**
 * reddit-enrich.mjs -- cookie-authenticated Reddit clip enricher (HIMMEL-769).
 *
 * Structural mirror of fxtwitter-enrich.mjs. For every clip under
 * <vault>/Clippings/ (maxdepth-2, excluding _synthesis/_done/_evidence) whose
 * source: is a reddit.com / old.reddit.com / redd.it URL, lacking enriched_at:,
 * AND whose body is thin (isThinRedditBody), fetch <canonical>.json?raw_json=1
 * with the exported burner-account Cookie header + a browser UA, validate the
 * two-element listing shape, and add a "## Crawled content" section (post title
 * + selftext + top-15 comments by score) before "## Source".
 *
 * Empirically (2026-07-08) anonymous reddit .json is 403-blocked; cookies from
 * ~/.luna/cookies/reddit.txt (Netscape format, exported by the operator) carry
 * the request. redd.it short links are resolved by a manual HEAD redirect
 * (auth-walled -> needs the cookie) before canonicalization.
 *
 * G-3 invariant: existing body sections byte-identical post-write; only
 * "## Crawled content" is added. Frontmatter mutation whitelisted to FM_KEYS.
 * YAML parse-validate post-write; revert to baseline on any failure.
 *
 * Payload-shape guard: reddit blocks with 200+HTML interstitials and
 * {"error": ...} JSON, not just status codes -- a shape mismatch is NEVER
 * written as ok. Failure taxonomy: 401/403/expired-cookie/200-non-listing ->
 * auth_expired (retryable); 429 -> rate_limited (retryable); 404 or removed/
 * deleted post -> removed (permanent, enriched_at set).
 *
 * Usage:  node reddit-enrich.mjs --vault <path> [--limit N] [--dry-run]
 * Exit:   0 run done | 1 bad usage | 2 cookie file absent.
 *
 * Test seams (env): REDDIT_FIXTURE (JSON {status,body}), REDDIT_HEAD_LOCATION
 * (short-circuit redd.it HEAD), REDDIT_HEAD_MAP (JSON url->{status,location}
 * driving the REAL redirect loop, so the in-loop cookie-scoping guard is
 * exercised) + REDDIT_HEAD_CAPTURE (append per-hop {url,cookie} records),
 * REDDIT_COOKIE_FILE (cookie path override), REDDIT_SCREENER (injection
 * screener override).
 */
import { existsSync, readFileSync, writeFileSync, readdirSync, appendFileSync } from "node:fs";
import { join, relative, sep, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { homedir } from "node:os";
import { parseNetscapeCookies, cookieHeaderFor } from "./lib/cookie-jar.mjs";
import { canonicalize } from "./lib/url-canonical.mjs";
import { isThinRedditBody, isRedditHost } from "./lib/clip-lookup.mjs";

const TODAY = new Date().toISOString().slice(0, 10);
const RATE_LIMIT_MS = 2000;
const FETCH_TIMEOUT_MS = 15000;
const MAX_COMMENTS = 15;
const SECTION_CAP_BYTES = 30000;
const MAX_REDIRECT_HOPS = 3;
const BROWSER_UA =
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
  "(KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36";
const DELETED = new Set(["[deleted]", "[removed]"]);
const EXCLUDE_DIRS = new Set(["_synthesis", "_done", "_evidence"]);
const COOKIE_FILE =
  process.env.REDDIT_COOKIE_FILE || join(homedir(), ".luna", "cookies", "reddit.txt");
const FM_KEYS = [
  "enriched_at",
  "enrichment_source",
  "enrichment_status",
  "last_error",
  "harvest_url_canonical",
  "harvest_flag",
  "harvest_flag_detail",
];

function usage(code = 1) {
  const out = code === 0 ? console.log : console.error;
  out("Usage: reddit-enrich.mjs --vault <path> [--limit N] [--dry-run]");
  out("");
  out("Enrich thin reddit clips via <canonical>.json + burner-account cookies.");
  out(`Cookie file: ${COOKIE_FILE} (Netscape format; see plugin README).`);
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
    else { console.error(`unknown arg: ${a}`); usage(1); }
  }
  if (!out.vault) usage(1);
  return out;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const sha256 = (s) => createHash("sha256").update(s).digest("hex");

/** Glob Clippings/*.md + one-level subfolders, excluding pipeline-internal dirs. */
function findClips(vault) {
  const root = join(vault, "Clippings");
  if (!existsSync(root)) {
    console.error(`reddit-enrich: no Clippings/ dir at ${root}`);
    return [];
  }
  const out = [];
  for (const e of readdirSync(root, { withFileTypes: true })) {
    if (e.isFile() && e.name.endsWith(".md") && e.name !== "_deferred.md") {
      out.push(join(root, e.name));
    } else if (e.isDirectory() && !EXCLUDE_DIRS.has(e.name)) {
      const sub = join(root, e.name);
      try {
        for (const s of readdirSync(sub, { withFileTypes: true })) {
          if (s.isFile() && s.name.endsWith(".md")) out.push(join(sub, s.name));
        }
      } catch { /* skip unreadable subdir */ }
    }
  }
  return out.sort();
}

/** Parse top-level frontmatter. CRLF normalized on read (mirrors fxtwitter). */
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

const alreadyEnriched = (fmRaw) => /^enriched_at:\s*\S/m.test(fmRaw);
const isShortlink = (url) => {
  try { return new URL(url).hostname.toLowerCase().replace(/^www\./, "") === "redd.it"; }
  catch { return false; }
};

function formatYamlValue(v) {
  if (v === null || v === undefined) return "";
  if (typeof v === "boolean") return v ? "true" : "false";
  if (typeof v === "number") return String(v);
  const s = String(v);
  if (/[:#"\n]|^\s|\s$|^-|^[0-9]|^[@`]/.test(s)) {
    return `"${s.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
  }
  return s;
}

/** Insert/replace whitelisted FM_KEYS (mirrors fxtwitter.upsertEnrichMarkers). */
function upsertEnrichMarkers(fmRaw, markers) {
  let lines = fmRaw.split("\n");
  const seen = new Set();
  lines = lines.map((line) => {
    for (const k of FM_KEYS) {
      if (new RegExp(`^${k}:`).test(line)) {
        seen.add(k);
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

/** Insert "## Crawled content" BEFORE "## Source" (mirrors fxtwitter). */
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

// -------------------------------------------------------------------------
// Fetch + resolution (test-seamed)
// -------------------------------------------------------------------------

/**
 * Single HEAD hop. Real fetch, or (REDDIT_HEAD_MAP) a fixture map url->{status,
 * location} that also records each hop's {url, cookie-present} to
 * REDDIT_HEAD_CAPTURE -- this drives the REAL resolveShortlink loop so the
 * in-loop cookie-scoping guard is actually exercised. Returns { status, location }.
 */
async function headRequest(url, headers) {
  if (process.env.REDDIT_HEAD_MAP) {
    if (process.env.REDDIT_HEAD_CAPTURE) {
      appendFileSync(
        process.env.REDDIT_HEAD_CAPTURE,
        JSON.stringify({ url, cookie: headers.Cookie ? "present" : "absent" }) + "\n",
      );
    }
    const map = JSON.parse(readFileSync(process.env.REDDIT_HEAD_MAP, "utf-8"));
    const hit = map[url] || { status: 200 };
    return { status: hit.status ?? 200, location: hit.location ?? null };
  }
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), FETCH_TIMEOUT_MS);
  try {
    const r = await fetch(url, { method: "HEAD", headers, redirect: "manual", signal: ctrl.signal });
    return { status: r.status, location: r.headers.get("location") };
  } finally {
    clearTimeout(t);
  }
}

/** Resolve a redd.it short link via manual HEAD redirects (needs the cookie). */
async function resolveShortlink(url, cookieHeader) {
  if (process.env.REDDIT_HEAD_LOCATION) return { url: process.env.REDDIT_HEAD_LOCATION };
  let current = url;
  for (let i = 0; i < MAX_REDIRECT_HOPS; i++) {
    // Only attach the burner cookie on reddit hosts — a redd.it 30x can point
    // anywhere, and the cookie must never leak to an off-reddit redirect hop.
    const headers = { "User-Agent": BROWSER_UA };
    if (isRedditHost(current)) headers.Cookie = cookieHeader;
    let r;
    try {
      r = await headRequest(current, headers);
    } catch (e) {
      return { error: `redirect_err: ${(e.message || String(e)).slice(0, 60)}` };
    }
    if (r.status >= 300 && r.status < 400) {
      const loc = r.location;
      if (!loc) return { error: "redirect_no_location" };
      try { current = new URL(loc, current).href; }
      catch { return { error: "redirect_bad_location" }; }
      continue;
    }
    return { url: current };
  }
  return { url: current };
}

/** Fetch <canonUrl>.json?raw_json=1. Returns { status, body }. Seamed by REDDIT_FIXTURE. */
async function fetchRedditJson(canonUrl, cookieHeader) {
  if (process.env.REDDIT_FIXTURE) {
    const env = JSON.parse(readFileSync(process.env.REDDIT_FIXTURE, "utf-8"));
    const body = typeof env.body === "string" ? env.body : JSON.stringify(env.body ?? "");
    return { status: env.status ?? 200, body };
  }
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), FETCH_TIMEOUT_MS);
  try {
    const r = await fetch(`${canonUrl}.json?raw_json=1`, {
      headers: { "User-Agent": BROWSER_UA, Accept: "application/json", Cookie: cookieHeader },
      redirect: "follow",
      signal: ctrl.signal,
    });
    return { status: r.status, body: await r.text() };
  } catch (e) {
    return { status: 0, body: "", error: `fetch_err: ${(e.message || String(e)).slice(0, 60)}` };
  } finally {
    clearTimeout(t);
  }
}

function isRemoved(post) {
  const st = String(post.selftext || "").trim();
  if (DELETED.has(st)) return true;
  if (post.removed_by_category) return true;
  if (String(post.author || "").trim() === "[deleted]") return true;
  return false;
}

/** Map a raw response to a verdict. NEVER returns ok on a shape mismatch. */
function classifyResponse({ status, body }) {
  if (status === 429) return { kind: "retry", error: "rate_limited" };
  if (status === 401 || status === 403) return { kind: "retry", error: "auth_expired" };
  if (status === 404) return { kind: "removed" };
  if (status !== 200) return { kind: "retry", error: "auth_expired" };
  let data;
  try { data = JSON.parse(body); }
  catch { return { kind: "retry", error: "auth_expired" }; } // 200 + HTML interstitial
  if (data && !Array.isArray(data) && data.error) return { kind: "retry", error: "auth_expired" }; // {"error":..}
  if (!Array.isArray(data) || data.length < 2 || data[0]?.data?.children?.[0]?.kind !== "t3") {
    return { kind: "retry", error: "auth_expired" };
  }
  const post = data[0].data.children[0].data;
  if (isRemoved(post)) return { kind: "removed" };
  return { kind: "ok", listing: data };
}

function extractPost(listing) {
  const d = listing[0].data.children[0].data;
  return {
    title: String(d.title || "(untitled)").replace(/\s+/g, " ").trim(),
    selftext: String(d.selftext || ""),
    author: String(d.author || "[unknown]"),
    subreddit: String(d.subreddit || "?"),
    score: Number.isFinite(d.score) ? d.score : 0,
    created: d.created_utc ? new Date(d.created_utc * 1000).toISOString().slice(0, 10) : "",
  };
}

function extractComments(listing) {
  const kids = listing[1]?.data?.children;
  const rows = [];
  if (!Array.isArray(kids)) return rows;
  for (const c of kids) {
    if (!c || c.kind !== "t1" || !c.data) continue;
    const d = c.data;
    if (d.stickied) continue;
    const bodyTxt = String(d.body || "");
    if (DELETED.has(bodyTxt.trim())) continue;
    if (DELETED.has(String(d.author || "").trim())) continue;
    rows.push({
      author: String(d.author || "[unknown]"),
      score: Number.isFinite(d.score) ? d.score : 0,
      body: bodyTxt,
    });
  }
  rows.sort((a, b) => b.score - a.score);
  return rows.slice(0, MAX_COMMENTS);
}

/** Render the "## Crawled content" markdown, capped at SECTION_CAP_BYTES. */
function renderRedditSection(post, comments) {
  const lines = [
    "## Crawled content",
    `<!-- enriched ${TODAY} via reddit-json -->`,
    "",
    `### ${post.title}`,
    "",
    `r/${post.subreddit} - u/${post.author} - ${post.score} points${post.created ? " - " + post.created : ""}`,
    "",
  ];
  const self = post.selftext.trim();
  lines.push(self || "_(link post - no selftext)_", "");
  if (comments.length) {
    lines.push("### Top comments", "");
    for (const c of comments) {
      const oneLine = c.body.replace(/\s*\n\s*/g, " ").trim();
      lines.push(`- **u/${c.author}** (${c.score}): ${oneLine}`);
    }
  }
  let out = lines.join("\n").replace(/\n+$/, "");
  if (Buffer.byteLength(out, "utf-8") > SECTION_CAP_BYTES) {
    out = Buffer.from(out, "utf-8").subarray(0, SECTION_CAP_BYTES).toString("utf-8")
      .replace(/\n+$/, "") + "\n\n...truncated";
  }
  return out;
}

// -------------------------------------------------------------------------
// Injection re-screen (mirrors fxtwitter.rescreenInjection)
// -------------------------------------------------------------------------

const TOOLS_DIR = dirname(fileURLToPath(import.meta.url));
const SCREENER = join(TOOLS_DIR, "harvest-clip-body-batch.py");

function rescreenInjection(clipPath) {
  const screener = process.env.REDDIT_SCREENER || SCREENER;
  const args = [screener, "--scan-only", clipPath];
  const opts = { encoding: "utf-8", timeout: 20000, windowsHide: true };
  let res = spawnSync("python", args, opts);
  if (res.error && res.error.code === "ENOENT") res = spawnSync("python3", args, opts);
  if (res.error) return { detail: "screen-error" };
  if (res.status === 0) return null;
  if (res.status === 1) {
    const classes = String(res.stdout || "").split("\n").map((l) => l.trim()).filter(Boolean);
    return { detail: classes.join(",") || "injection-suspect" };
  }
  return { detail: "screen-error" };
}

// -------------------------------------------------------------------------
// Per-clip processing
// -------------------------------------------------------------------------

export async function processClip(clipPath, vault, dryRun, opts = {}) {
  const rel = relative(vault, clipPath).split(sep).join("/");
  let text;
  try { text = readFileSync(clipPath, "utf-8"); }
  catch (e) { return { glyph: "x", message: `${rel} -- failed (read): ${e.message}` }; }
  const baselineSha = sha256(text);
  const { fm, fmRaw, body, present } = parseFrontmatter(text);
  if (!present) return { glyph: "o", message: `${rel} -- skipped (no closing ---)` };

  const sourceVal = (fm.source || "").trim().replace(/^["']|["']$/g, "");
  if (!isRedditHost(sourceVal)) return { glyph: "o", message: `${rel} -- skipped (not reddit source)` };
  if (alreadyEnriched(fmRaw)) return { glyph: "o", message: `${rel} -- skipped (already enriched)` };
  if (!isThinRedditBody(body)) return { glyph: "o", message: `${rel} -- skipped (body already rich)` };

  if (dryRun) return { glyph: "v", message: `${rel} -- would enrich [dry-run]` };

  const cookieHeader = opts.cookieHeader || "";
  if (!cookieHeader) {
    return writeEnrichment({
      clipPath, rel, text, baselineSha, fmRaw, body,
      markers: { enrichment_source: "reddit-json", enrichment_status: "failed", last_error: "auth_expired" },
      section: null, statusGlyph: "~",
      statusMsg: "partial (auth_expired: cookie set empty/expired; refresh ~/.luna/cookies/reddit.txt)",
    });
  }

  if (!opts.skipRateLimit) await sleep(RATE_LIMIT_MS);

  let targetUrl = sourceVal;
  if (isShortlink(sourceVal)) {
    const res = await resolveShortlink(sourceVal, cookieHeader);
    if (res.error) {
      // Persist a retryable marker (no enriched_at) -- mirrors redirect_offsite,
      // so an un-resolved redd.it short link isn't silently left frontmatter-less.
      return writeEnrichment({
        clipPath, rel, text, baselineSha, fmRaw, body,
        markers: { enrichment_source: "reddit-json", enrichment_status: "failed", last_error: "redd_resolve" },
        section: null, statusGlyph: "~", statusMsg: `partial (redd_resolve: ${res.error})`,
      });
    }
    targetUrl = res.url;
  }
  // Redirect-offsite guard: a redd.it HEAD chain that lands off reddit must
  // never be fetched. Retryable (no enriched_at) — a later run retries after
  // the redirect target is re-checked.
  if (!isRedditHost(targetUrl)) {
    return writeEnrichment({
      clipPath, rel, text, baselineSha, fmRaw, body,
      markers: { enrichment_source: "reddit-json", enrichment_status: "failed", last_error: "redirect_offsite" },
      section: null, statusGlyph: "~", statusMsg: "partial (redirect_offsite: resolved URL left reddit)",
    });
  }
  const canonUrl = canonicalize(targetUrl);
  if (!canonUrl) {
    // Persist a retryable marker (no enriched_at) -- mirrors redirect_offsite,
    // so an un-canonicalizable resolved URL isn't silently left frontmatter-less.
    return writeEnrichment({
      clipPath, rel, text, baselineSha, fmRaw, body,
      markers: { enrichment_source: "reddit-json", enrichment_status: "failed", last_error: "canonicalize" },
      section: null, statusGlyph: "~", statusMsg: `partial (canonicalize: ${targetUrl})`,
    });
  }

  const resp = await fetchRedditJson(canonUrl, cookieHeader);
  const verdict = classifyResponse(resp);
  const base = { enrichment_source: "reddit-json", harvest_url_canonical: canonUrl };

  if (verdict.kind === "retry") {
    return writeEnrichment({
      clipPath, rel, text, baselineSha, fmRaw, body,
      markers: { ...base, enrichment_status: "failed", last_error: verdict.error },
      section: null, statusGlyph: "~", statusMsg: `partial (${verdict.error})`,
    });
  }
  if (verdict.kind === "removed") {
    return writeEnrichment({
      clipPath, rel, text, baselineSha, fmRaw, body,
      markers: { ...base, enriched_at: TODAY, enrichment_status: "failed", last_error: "removed" },
      section: null, statusGlyph: "x", statusMsg: "failed (removed: post deleted/removed)",
    });
  }

  const post = extractPost(verdict.listing);
  const comments = extractComments(verdict.listing);
  const section = renderRedditSection(post, comments);
  const markers = { ...base, enriched_at: TODAY, enrichment_status: "ok", last_error: null };
  const res = await writeEnrichment({
    clipPath, rel, text, baselineSha, fmRaw, body, markers, section,
    statusGlyph: "v", statusMsg: `enriched (r/${post.subreddit}, ${comments.length} comments)`,
  });

  // Injection re-screen on a verified write (the selftext/comments are
  // untrusted text just written into ## Crawled content). Flag-only; a hit or
  // fail-closed screen-error adds harvest_flag via a second body-identical write.
  if (res.glyph === "v") {
    const flag = rescreenInjection(clipPath);
    if (flag) {
      try {
        const enrichedText = readFileSync(clipPath, "utf-8");
        const ep = parseFrontmatter(enrichedText);
        if (!ep.present) {
          writeFileSync(clipPath, text, { encoding: "utf-8" });
          return { glyph: "x", message: `${rel} -- failed (injection flag-write; reverted to stub): no parseable frontmatter` };
        }
        return await writeEnrichment({
          clipPath, rel, text: enrichedText, baselineSha: sha256(enrichedText),
          fmRaw: ep.fmRaw, body: ep.body,
          markers: { harvest_flag: "injection-suspect", harvest_flag_detail: flag.detail },
          section: null, statusGlyph: "v",
          statusMsg: `${res.message.replace(`${rel} -- `, "")} [injection-suspect: ${flag.detail}]`,
        });
      } catch (e) {
        writeFileSync(clipPath, text, { encoding: "utf-8" });
        return { glyph: "x", message: `${rel} -- failed (injection flag-write; reverted): ${e.message}` };
      }
    }
  }
  return res;
}

/** Write with full G-3 / YAML verification and revert-on-failure. */
async function writeEnrichment({ clipPath, rel, text, baselineSha, fmRaw, body, markers, section, statusGlyph, statusMsg }) {
  let nowText;
  try { nowText = readFileSync(clipPath, "utf-8"); }
  catch (e) { return { glyph: "x", message: `${rel} -- failed (re-read): ${e.message}` }; }
  if (sha256(nowText) !== baselineSha) {
    return { glyph: "~", message: `${rel} -- partial (stale-read): operator-edit detected mid-pass` };
  }
  let newBody = body;
  if (section) newBody = insertCrawledSection(body, section);
  const newFm = upsertEnrichMarkers(fmRaw, markers);
  const newText = `---\n${newFm}\n---\n${newBody}`;
  try { writeFileSync(clipPath, newText, { encoding: "utf-8" }); }
  catch (e) { return { glyph: "x", message: `${rel} -- failed (write): ${e.message}` }; }

  let diskText;
  try { diskText = readFileSync(clipPath, "utf-8"); }
  catch (e) { writeFileSync(clipPath, text, { encoding: "utf-8" }); return { glyph: "x", message: `${rel} -- failed (post-write read; reverted): ${e.message}` }; }
  const post = parseFrontmatter(diskText);
  if (!post.present) { writeFileSync(clipPath, text, { encoding: "utf-8" }); return { glyph: "x", message: `${rel} -- failed (post-write parse; reverted)` }; }
  if (post.body !== newBody) { writeFileSync(clipPath, text, { encoding: "utf-8" }); return { glyph: "x", message: `${rel} -- failed (G-3 body-write mismatch; reverted)` }; }
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
  try { const yaml = await import("js-yaml"); yaml.load(post.fmRaw); }
  catch (e) { writeFileSync(clipPath, text, { encoding: "utf-8" }); return { glyph: "x", message: `${rel} -- failed (yaml parse; reverted): ${e.message}` }; }
  return { glyph: statusGlyph, message: `${rel} -- ${statusMsg}` };
}

// -------------------------------------------------------------------------
// Main
// -------------------------------------------------------------------------

async function main() {
  const args = parseArgs(process.argv);
  if (!existsSync(args.vault)) {
    console.error(`reddit-enrich: vault not found: ${args.vault}`);
    process.exit(1);
  }
  if (!existsSync(COOKIE_FILE)) {
    console.error(`reddit-enrich: cookie file not found: ${COOKIE_FILE}`);
    console.error("  Export burner-account cookies (Netscape format) from a browser logged");
    console.error("  into the reddit burner account (Cookie-Editor > Export > Netscape),");
    console.error("  save to that path, and 'chmod 600' it. See the plugin README.");
    process.exit(2);
  }
  let jar = [];
  try { jar = parseNetscapeCookies(readFileSync(COOKIE_FILE, "utf-8")); }
  catch (e) { console.error(`reddit-enrich: cookie parse failed: ${e.message}`); process.exit(2); }
  const cookieHeader = cookieHeaderFor(jar, "www.reddit.com", Math.floor(Date.now() / 1000));

  const clips = findClips(args.vault);
  if (clips.length === 0) { console.log("reddit-enrich: 0 clips found."); process.exit(0); }

  let ok = 0, partial = 0, failed = 0, skipped = 0, processed = 0;
  for (const clip of clips) {
    if (args.limit > 0 && processed >= args.limit) break;
    let res;
    try {
      res = await processClip(clip, args.vault, args.dryRun, { cookieHeader });
    } catch (e) {
      // Per-clip isolation: one clip's unexpected throw must not abort the run.
      const rel = relative(args.vault, clip).split(sep).join("/");
      process.stderr.write(`FAIL ${rel} -- failed (unexpected): ${e.message}\n`);
      failed++; processed++;
      continue;
    }
    const prefix =
      res.glyph === "v" ? "OK  " :
      res.glyph === "o" ? "SKIP" :
      res.glyph === "~" ? "PART" : "FAIL";
    (res.glyph === "x" ? process.stderr : process.stdout).write(`${prefix} ${res.message}\n`);
    if (res.glyph === "v") { ok++; processed++; }
    else if (res.glyph === "~") { partial++; processed++; }
    else if (res.glyph === "x") { failed++; processed++; }
    else skipped++;
  }
  console.log(`\nreddit-enrich: ${ok} ok, ${partial} partial, ${failed} failed, ${skipped} skipped. (dry_run=${args.dryRun})`);
  process.exit(0);
}

const _argv1 = (process.argv[1] || "").replace(/\\/g, "/");
const _isMain = import.meta.main === true || _argv1.endsWith("reddit-enrich.mjs");
if (_isMain) {
  main().catch((e) => { console.error("reddit-enrich: fatal:", e); process.exit(1); });
}
