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
 * + selftext + the FULL comment tree in thread order, depth-indented) before
 * "## Source". "more" comment stubs are expanded via /api/morechildren
 * (HIMMEL-789 -- sources usually live deep in the threads), bounded by
 * MAX_MORE_BATCHES; anything left unexpanded is stated honestly in the section
 * ("N more comments not captured"), never silently dropped.
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
 * Usage:  node reddit-enrich.mjs --vault <path> [--limit N] [--dry-run] [--include-evidence]
 * Exit:   0 run done | 1 bad usage | 2 cookie file absent.
 *
 * Test seams (env): REDDIT_FIXTURE (JSON {status,body}), REDDIT_MORE_FIXTURE
 * (JSON {status,body} for /api/morechildren), REDDIT_HEAD_LOCATION
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
const MAX_TOTAL_COMMENTS = 400;      // whole-tree honesty cap (HIMMEL-789)
const MORE_BATCH = 100;              // /api/morechildren accepts <=100 ids/call
const MAX_MORE_BATCHES = 3;          // bounded expansion: <=300 extra comments
const INDENT_DEPTH_MAX = 6;          // deeper replies render at this indent
const SECTION_CAP_BYTES = 120000;
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
  out("Usage: reddit-enrich.mjs --vault <path> [--limit N] [--dry-run] [--include-evidence]");
  out("");
  out("Enrich thin reddit clips via <canonical>.json + burner-account cookies.");
  out(`Cookie file: ${COOKIE_FILE} (Netscape format; see plugin README).`);
  process.exit(code);
}

function parseArgs(argv) {
  const out = { vault: null, limit: 0, dryRun: false, includeEvidence: false };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--vault") out.vault = argv[++i];
    else if (a === "--limit") out.limit = parseInt(argv[++i] || "0", 10) || 0;
    else if (a === "--dry-run") out.dryRun = true;
    else if (a === "--include-evidence") out.includeEvidence = true;
    else if (a === "-h" || a === "--help") usage(0);
    else { console.error(`unknown arg: ${a}`); usage(1); }
  }
  if (!out.vault) usage(1);
  return out;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const sha256 = (s) => createHash("sha256").update(s).digest("hex");

/** Glob Clippings/*.md + one-level subfolders, excluding pipeline-internal dirs.
 * includeEvidence lifts the _evidence/ exclusion (HIMMEL-789 backfill reach). */
function findClips(vault, includeEvidence = false) {
  const root = join(vault, "Clippings");
  if (!existsSync(root)) {
    console.error(`reddit-enrich: no Clippings/ dir at ${root}`);
    return [];
  }
  const exclude = new Set(EXCLUDE_DIRS);
  if (includeEvidence) exclude.delete("_evidence");
  const out = [];
  for (const e of readdirSync(root, { withFileTypes: true })) {
    if (e.isFile() && e.name.endsWith(".md") && e.name !== "_deferred.md") {
      out.push(join(root, e.name));
    } else if (e.isDirectory() && !exclude.has(e.name)) {
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
    name: String(d.name || (d.id ? `t3_${d.id}` : "")),
    title: String(d.title || "(untitled)").replace(/\s+/g, " ").trim(),
    selftext: String(d.selftext || ""),
    author: String(d.author || "[unknown]"),
    subreddit: String(d.subreddit || "?"),
    score: Number.isFinite(d.score) ? d.score : 0,
    created: d.created_utc ? new Date(d.created_utc * 1000).toISOString().slice(0, 10) : "",
  };
}

/** Map one t1 node to a comment row, or null if filtered (stickied/deleted). */
function commentRow(d, depth) {
  if (d.stickied) return null;
  const bodyTxt = String(d.body || "");
  if (DELETED.has(bodyTxt.trim())) return null;
  if (DELETED.has(String(d.author || "").trim())) return null;
  return {
    author: String(d.author || "[unknown]"),
    score: Number.isFinite(d.score) ? d.score : 0,
    body: bodyTxt,
    depth,
  };
}

/**
 * FULL comment tree in thread order (HIMMEL-789): recursive walk of the
 * listing's t1 nodes and their data.replies, no score re-sort, no top-N cap.
 * "more" stubs collect their child ids into moreIds for /api/morechildren
 * expansion. depthMap (t1 fullname -> depth) lets the flat morechildren
 * response re-attach each expanded comment at its true depth. A deleted
 * comment is skipped but its live replies are still walked.
 */
function extractCommentTree(listing) {
  const comments = [];
  const moreIds = [];
  const depthMap = new Map();
  const rowByName = new Map();   // t1 fullname -> row (for positional insert)
  let omitted = 0;
  const walk = (children, depth) => {
    if (!Array.isArray(children)) return;
    for (const c of children) {
      if (c?.kind === "more" && c.data) {
        const ids = Array.isArray(c.data.children) ? c.data.children : [];
        if (ids.length) {
          moreIds.push(...ids);
        } else {
          // "continue this thread" stub: count>0, children:[] - no ids to
          // expand, but the cut chain MUST reach the disclosure (silent-
          // failure CR): never vanish behind an ok stamp.
          omitted += Math.max(1, Number(c.data.count) || 0);
        }
        continue;
      }
      if (!c || c.kind !== "t1" || !c.data) continue;
      const d = c.data;
      if (d.name) depthMap.set(String(d.name), depth);
      const kids = d.replies?.data?.children;
      let row = commentRow(d, depth);
      // A filtered parent (deleted/stickied) with live replies OR a more-stub
      // still needs a visible anchor, or its (expanded) replies would render
      // nested under the PREVIOUS visible comment - misattributing who they
      // answer (codex-adv r5+r6).
      if (!row && Array.isArray(kids) &&
          kids.some((k) => k?.kind === "t1" || k?.kind === "more")) {
        row = { author: "[omitted]", score: 0, body: "(comment removed or omitted)", depth };
      }
      if (row) {
        comments.push(row);
        if (d.name) rowByName.set(String(d.name), row);
      }
      walk(kids, depth + 1);
    }
  };
  walk(listing[1]?.data?.children, 0);
  return { comments, moreIds, depthMap, rowByName, omitted };
}

/** Fetch one /api/morechildren batch. Returns { status, body }. Seamed by
 * REDDIT_MORE_FIXTURE (same envelope contract as REDDIT_FIXTURE). */
async function fetchMoreChildrenBatch(linkName, ids, cookieHeader) {
  if (process.env.REDDIT_MORE_FIXTURE) {
    const env = JSON.parse(readFileSync(process.env.REDDIT_MORE_FIXTURE, "utf-8"));
    const body = typeof env.body === "string" ? env.body : JSON.stringify(env.body ?? "");
    return { status: env.status ?? 200, body };
  }
  const url = "https://www.reddit.com/api/morechildren.json?api_type=json" +
    `&raw_json=1&link_id=${encodeURIComponent(linkName)}` +
    `&children=${encodeURIComponent(ids.join(","))}`;
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), FETCH_TIMEOUT_MS);
  try {
    const r = await fetch(url, {
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

/**
 * Expand "more" stubs via /api/morechildren, bounded by MAX_MORE_BATCHES x
 * MORE_BATCH ids, inserting each expanded comment at its parent's tree
 * position in tree.comments (after the parent's current subtree) so thread
 * order holds (codex-1). Two distinct incompleteness classes (codex-adv):
 * - bounded skip (MAX_MORE_BATCHES / no linkName) -> deliberate, counted in
 *   `omitted`, the enrich proceeds with the honesty line;
 * - transient batch failure (non-200 / bad shape / fetch error) -> `failed`
 *   is set and the CALLER must persist a RETRYABLE marker, never a permanent
 *   ok -- otherwise a 429 would freeze an incomplete thread forever.
 * Returns { omitted, failed }.
 */
async function fetchMoreComments(linkName, moreIds, cookieHeader, tree, opts = {}) {
  let omitted = 0;
  let failed = false;
  let failReason = "";
  const insertRow = (row, name, parentName) => {
    const pRow = tree.rowByName.get(parentName);
    if (!pRow) {
      // t3 parent -> genuine top-level continuation. An UNKNOWN t1 parent
      // (itself unexpanded/filtered without an anchor) must not append a
      // nested row that visually attaches to the preceding comment: give it
      // its own [omitted] anchor at the parent's depth first (codex-adv r6).
      if (row.depth > 0) {
        const anchor = { author: "[omitted]", score: 0,
          body: "(comment removed or omitted)", depth: row.depth - 1 };
        tree.comments.push(anchor);
        if (parentName) tree.rowByName.set(parentName, anchor);
      }
      tree.comments.push(row);
    } else {
      let j = tree.comments.indexOf(pRow) + 1;
      while (j < tree.comments.length && tree.comments[j].depth > pRow.depth) j++;
      tree.comments.splice(j, 0, row);    // after the parent's subtree
    }
    if (name) tree.rowByName.set(name, row);
  };
  const batches = [];
  for (let i = 0; i < moreIds.length; i += MORE_BATCH) batches.push(moreIds.slice(i, i + MORE_BATCH));
  for (let b = 0; b < batches.length; b++) {
    if (b >= MAX_MORE_BATCHES || !linkName) {
      omitted += batches.slice(b).reduce((n, x) => n + x.length, 0);
      break;
    }
    if (!opts.skipRateLimit) await sleep(RATE_LIMIT_MS);
    const resp = await fetchMoreChildrenBatch(linkName, batches[b], cookieHeader);
    let things;
    try { things = JSON.parse(resp.body)?.json?.data?.things; } catch { things = null; }
    if (resp.status !== 200 || !Array.isArray(things)) {
      failed = true;
      failReason = resp.error ||
        (resp.status !== 200 ? `http_${resp.status}` : "bad_shape");
      break;
    }
    // Explicit t3/known/orphan depth resolution: a reply to the POST is a
    // genuine top-level; a reply whose t1 parent is unknown is an ORPHAN and
    // must anchor at depth 1 under an [omitted] placeholder - never render
    // flush-left impersonating a top-level comment (silent-failure CR).
    const processThing = (d, parent) => {
      let depth;
      if (parent.startsWith("t3_")) depth = 0;
      else if (tree.depthMap.has(parent)) depth = tree.depthMap.get(parent) + 1;
      else depth = 1;
      if (d.name) tree.depthMap.set(String(d.name), depth);
      const row = commentRow(d, depth);
      if (row) insertRow(row, d.name ? String(d.name) : "", parent);
    };
    // The API gives no within-batch ordering guarantee: process things
    // topologically (parents first) so a child arriving before its batch-mate
    // parent still attaches at true depth; leftovers are genuine orphans.
    const pending = [];
    for (const th of things) {
      if (th?.kind === "more" && th.data) {
        // Nested "more" stub in the expansion payload: bounded design,
        // disclosed (codex-adv r3); empty children = continue-this-thread.
        const ids = Array.isArray(th.data.children) ? th.data.children : [];
        omitted += ids.length || Math.max(1, Number(th.data.count) || 0);
        continue;
      }
      if (!th || th.kind !== "t1" || !th.data) continue;
      pending.push(th.data);
    }
    let progress = true;
    while (pending.length && progress) {
      progress = false;
      for (let i = 0; i < pending.length; ) {
        const d = pending[i];
        const parent = String(d.parent_id || "");
        if (parent.startsWith("t3_") || tree.depthMap.has(parent)) {
          processThing(d, parent);
          pending.splice(i, 1);
          progress = true;
        } else {
          i++;
        }
      }
    }
    for (const d of pending) processThing(d, String(d.parent_id || ""));
  }
  return { omitted, failed, failReason };
}

/**
 * Render the "## Crawled content" markdown with per-comment byte accounting
 * (codex-adv r3): comments append whole, one at a time, while the budget
 * (SECTION_CAP_BYTES minus reserved disclosure room) allows; every comment
 * that does not fit is COUNTED into the omission disclosure instead of being
 * blindly truncated away after it was reported captured. Disclosures append
 * after the cap so they always survive. Returns { section, rendered, omitted }.
 */
function renderRedditSection(post, comments, omitted = 0) {
  const RESERVE = 200;   // room the disclosure lines are guaranteed to have
  const budget = SECTION_CAP_BYTES - RESERVE;
  const head = [
    "## Crawled content",
    `<!-- enriched ${TODAY} via reddit-json -->`,
    "",
    `### ${post.title}`,
    "",
    `r/${post.subreddit} - u/${post.author} - ${post.score} points${post.created ? " - " + post.created : ""}`,
    "",
  ];
  const self = post.selftext.trim();
  head.push(self || "_(link post - no selftext)_", "");
  let out = head.join("\n").replace(/\n+$/, "");
  let truncated = false;
  if (Buffer.byteLength(out, "utf-8") > budget) {
    out = Buffer.from(out, "utf-8").subarray(0, budget).toString("utf-8")
      .replace(/\n+$/, "");
    truncated = true;
    omitted += comments.length;   // no room for ANY comment - all disclosed
    comments = [];
  }
  let rendered = 0;
  if (comments.length) {
    out += "\n\n### Comments\n";
    for (const c of comments) {
      const oneLine = c.body.replace(/\s*\n\s*/g, " ").trim();
      const indent = "  ".repeat(Math.min(c.depth || 0, INDENT_DEPTH_MAX));
      const line = `\n${indent}- **u/${c.author}** (${c.score}): ${oneLine}`;
      if (Buffer.byteLength(out, "utf-8") + Buffer.byteLength(line, "utf-8") > budget) {
        omitted += comments.length - rendered;   // whole-comment accounting
        break;
      }
      out += line;
      rendered++;
    }
  }
  if (truncated) out += "\n\n...truncated";
  if (omitted > 0) out += `\n\n_(${omitted} more comments not captured)_`;
  return { section: out, rendered, omitted };
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
  const tree = extractCommentTree(verdict.listing);
  let omitted = tree.omitted;
  if (tree.moreIds.length) {
    const more = await fetchMoreComments(post.name, tree.moreIds, cookieHeader, tree, opts);
    if (more.failed) {
      // Transient morechildren failure: RETRYABLE, never a permanent ok --
      // a 429/500 must not freeze an incomplete thread (codex-adv).
      return writeEnrichment({
        clipPath, rel, text, baselineSha, fmRaw, body,
        markers: { ...base, enrichment_status: "failed", last_error: "more_fetch" },
        section: null, statusGlyph: "~",
        statusMsg: `partial (more_fetch: ${more.failReason}; retried next run)`,
      });
    }
    omitted += more.omitted;
  }
  let comments = tree.comments;
  if (comments.length > MAX_TOTAL_COMMENTS) {
    omitted += comments.length - MAX_TOTAL_COMMENTS;
    comments = comments.slice(0, MAX_TOTAL_COMMENTS);
  }
  const r = renderRedditSection(post, comments, omitted);
  const markers = { ...base, enriched_at: TODAY, enrichment_status: "ok", last_error: null };
  const res = await writeEnrichment({
    clipPath, rel, text, baselineSha, fmRaw, body, markers, section: r.section,
    statusGlyph: "v",
    statusMsg: `enriched (r/${post.subreddit}, ${r.rendered} comments` +
      (r.omitted ? `, ${r.omitted} omitted` : "") + ")",
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

  const clips = findClips(args.vault, args.includeEvidence);
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
