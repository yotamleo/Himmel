#!/usr/bin/env node
// follow-roster.mjs — HIMMEL-660 X-follow-list scorer, Task 1: roster +
// handle-normalization lib. Pure (filesystem-only, no network).
//
// Grounded 2026-07-02 against REAL vault content (not assumed):
//
// - List file (~/Documents/luna/30-Resources/ai-x-follow-list.md) encodes
//   each entry as a markdown link with an `@`-prefixed display handle:
//     - **[@_avichawla](https://x.com/_avichawla)** (10) — description
//   Bullets are grouped under `## Tier N — …` / `## Excluded …` headings;
//   the handle to extract is the link TEXT (`@_avichawla`), not the URL
//   slug (though today they're identical).
//
// - Clip frontmatter author fields — two distinct shapes coexist in the
//   corpus, both spec-confirmed by the brief:
//     * `author:` — YAML list, web-clipper shaped, display-cased with `@`:
//         author:
//           - "@DivyanshT91162"
//     * `tweet_author:` — scalar, fxtwitter-enrichment shaped, lowercase,
//       no `@`:
//         tweet_author: "garrytan"
//   A clip has AT MOST one of the two in practice; both normalize to the
//   same handle space via normalizeHandle().
//
// - `tweet_stats:` (fxtwitter-enriched clips only) is an inline YAML flow
//   map, e.g. `tweet_stats: { replies: 25, retweets: 135, quotes: 4,
//   likes: 1148, views: 345148 }` — not consumed by this task (roster
//   resolution doesn't need engagement stats), confirmed present but out
//   of scope here.
//
// - Timestamps in the corpus: `date_clipped` (YYYY-MM-DD, always present),
//   `enriched_at` (fxtwitter clips only), `harvested_at` (post-harvest
//   clips only). Not consumed by this task.
//
// - Crypto tag: none found in the sampled corpus (`grep tags: | grep -i
//   crypto` over Clippings/ returned no hits) — not in use today; not
//   consumed by this task.
//
// Consumes: listClipFiles, resolveVaultRoot from ./clip-lookup.mjs;
// parse, fmList, fmScalar from ./frontmatter.mjs.

import { readFileSync } from "node:fs";
import { listClipFiles } from "./clip-lookup.mjs";
import { parse, fmList, fmScalar } from "./frontmatter.mjs";

/**
 * Normalize a raw handle/URL/mention into a bare lowercase handle: strip
 * a leading `@`, strip an `https://(x|twitter).com/` wrapper, drop any
 * trailing path/query/fragment, lowercase.
 */
export function normalizeHandle(raw) {
  let h = String(raw ?? "").trim();
  h = h.replace(/^(https?:\/\/)?(www\.|mobile\.)?(x|twitter)\.com\//i, "");
  h = h.split(/[/?#]/)[0]; // drop path/query after handle
  h = h.replace(/^@/, "");
  return h.toLowerCase();
}

// Matches a follow-list bullet's handle link: [@handle](url-or-anything).
const LIST_HANDLE_RE = /\[@([A-Za-z0-9_]+)\]/g;

function parseListHandles(listPath) {
  const set = new Set();
  let text;
  try {
    text = readFileSync(listPath, "utf8");
  } catch {
    return set;
  }
  for (const m of text.matchAll(LIST_HANDLE_RE)) {
    set.add(normalizeHandle(m[1]));
  }
  return set;
}

function clipHandle(path) {
  let text;
  try {
    text = readFileSync(path, "utf8");
  } catch {
    return null;
  }
  const { lines, bounds } = parse(text);
  if (!bounds) return null;
  const authors = fmList(lines, bounds.close, "author");
  if (authors.length) return normalizeHandle(authors[0]);
  const tweetAuthor = fmScalar(lines, bounds.close, "tweet_author");
  if (tweetAuthor) return normalizeHandle(tweetAuthor);
  return null;
}

/**
 * Resolve the follow roster: the union of every handle in the curated
 * list (clipCount from the corpus tally, may be 0) and every corpus
 * handle with clipCount >= minClips. Deduped on normalized handle.
 */
export function resolveRoster(vaultRoot, listPath, { minClips = 2 } = {}) {
  const inListSet = parseListHandles(listPath);

  const counts = new Map();
  for (const file of listClipFiles(vaultRoot)) {
    const handle = clipHandle(file);
    if (!handle) continue;
    counts.set(handle, (counts.get(handle) || 0) + 1);
  }

  const handles = new Set([...inListSet, ...counts.keys()]);
  const roster = [];
  for (const handle of handles) {
    const clipCount = counts.get(handle) || 0;
    const inList = inListSet.has(handle);
    if (!inList && clipCount < minClips) continue;
    roster.push({ handle, clipCount, inList });
  }
  return roster;
}
