#!/usr/bin/env node
// follow-dossier.mjs — HIMMEL-660 X-follow-list scorer, Task 2: dossier
// schema + corpus-local evidence lib. Pure (filesystem-only, no network).
//
// buildCorpusEvidence scans the vault's Clippings/ for clips authored by a
// given handle (author:/tweet_author:, normalized via follow-roster's
// normalizeHandle) and summarizes what the corpus already knows: sample
// tweet text + engagement stats (tweet_stats: inline flow map), a rough
// posting cadence (median day-gap between date_clipped values), and
// whether any clip is crypto/defi-tagged. No crypto tag exists in the
// sampled corpus (Task 1 grounding) — crypto_tagged will usually be false.
//
// emptyDossier/writeDossier/readDossier manage the on-disk evidence
// dossier at <vault>/30-Resources/.follow-scores/<handle>.json that later
// tasks (3-5) populate incrementally and Task 7 consumes to tier/score.

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { listClipFiles } from "./clip-lookup.mjs";
import { parse, fmList, fmScalar } from "./frontmatter.mjs";
import { normalizeHandle } from "./follow-roster.mjs";

function clipAuthorHandle(lines, close) {
  const authors = fmList(lines, close, "author");
  if (authors.length) return normalizeHandle(authors[0]);
  const tweetAuthor = fmScalar(lines, close, "tweet_author");
  if (tweetAuthor) return normalizeHandle(tweetAuthor);
  return null;
}

// Parses the inline YAML flow map `tweet_stats: { replies: 25, likes: 1148, ... }`
// (already stripped of the `tweet_stats:` key by fmScalar) into a plain
// object. Returns null when absent.
function parseStatsMap(raw) {
  const inner = raw.trim().replace(/^\{/, "").replace(/\}$/, "").trim();
  if (!inner) return null;
  const stats = {};
  for (const pair of inner.split(",")) {
    const [k, v] = pair.split(":").map((s) => s && s.trim());
    if (!k) continue;
    const num = Number(v);
    stats[k] = v !== undefined && !Number.isNaN(num) && v !== "" ? num : v;
  }
  return Object.keys(stats).length ? stats : null;
}

// Median gap (in days) between sorted date_clipped values; null if fewer
// than 2 parseable dates.
function computeCadenceDays(dateStrings) {
  const parsed = dateStrings
    .map((d) => Date.parse(d))
    .filter((n) => !Number.isNaN(n))
    .sort((a, b) => a - b);
  if (parsed.length < 2) return null;
  const gaps = [];
  for (let i = 1; i < parsed.length; i++) {
    gaps.push((parsed[i] - parsed[i - 1]) / 86400000);
  }
  gaps.sort((a, b) => a - b);
  const mid = Math.floor(gaps.length / 2);
  return gaps.length % 2 ? gaps[mid] : (gaps[mid - 1] + gaps[mid]) / 2;
}

/**
 * Scan the vault's corpus for clips authored by `handle` and summarize
 * what's already known: { clip_count, sample_tweets: [{text, stats}],
 * cadence_days, crypto_tagged }.
 */
export function buildCorpusEvidence(vaultRoot, handle) {
  const target = normalizeHandle(handle);
  const sampleTweets = [];
  const dateStrings = [];
  let cryptoTagged = false;

  for (const file of listClipFiles(vaultRoot)) {
    let text;
    try {
      text = readFileSync(file, "utf8");
    } catch {
      continue;
    }
    const { lines, bounds } = parse(text);
    if (!bounds) continue;
    if (clipAuthorHandle(lines, bounds.close) !== target) continue;

    const statsRaw = fmScalar(lines, bounds.close, "tweet_stats");
    const stats = statsRaw ? parseStatsMap(statsRaw) : null;
    const bodyText = lines.slice(bounds.close + 1).join("\n").trim().slice(0, 500);
    sampleTweets.push({ text: bodyText, stats });

    const tags = fmList(lines, bounds.close, "tags");
    if (tags.some((t) => /crypto|defi/i.test(t))) cryptoTagged = true;

    const dateClipped = fmScalar(lines, bounds.close, "date_clipped");
    if (dateClipped) dateStrings.push(dateClipped);
  }

  return {
    clip_count: sampleTweets.length,
    sample_tweets: sampleTweets,
    cadence_days: computeCadenceDays(dateStrings),
    crypto_tagged: cryptoTagged,
  };
}

// Sample-tweet bodies carry shortened `https://t.co/...` links that hide the
// real github/course/product URLs from claim extraction. This surfaces them
// so the CLI can resolve each to its final destination and feed the resolved
// URL back into `follow-verify.extractClaims` as extra claim-source text.
const SHORT_LINK_RE = /https?:\/\/t\.co\/[A-Za-z0-9]+/gi;

/** Returns the t.co shortened URLs found in `text`. Pure — no network. */
export function extractShortLinks(text) {
  if (!text) return [];
  return [...text.matchAll(SHORT_LINK_RE)].map((m) => m[0]);
}

/** A fresh dossier shell for `handle`, seeded with roster info from Task 1's resolveRoster entry ({clipCount, inList}). */
export function emptyDossier(handle, rosterInfo = {}) {
  return {
    handle: normalizeHandle(handle),
    roster: {
      clip_count: rosterInfo.clipCount ?? 0,
      in_list: rosterInfo.inList ?? false,
    },
    account: {
      bio: null,
      followers: null,
      following: null,
      created_at: null,
      cadence_days: null,
      source: null,
      fetch_status: null,
    },
    repos: {
      login: null,
      repo_count: null,
      total_stars: null,
      recent_pushed_at: null,
      topical_hits: null,
      sample_descriptions: [],
      source: null,
      status: null,
    },
    corpus: {
      sample_tweets: [],
      crypto_tagged: false,
    },
    claims: [],
    injection_suspect: false,
    screen_status: null,
  };
}

function dossierDir(vaultRoot) {
  return join(vaultRoot, "30-Resources", ".follow-scores");
}

function dossierPath(vaultRoot, handle) {
  return join(dossierDir(vaultRoot), `${normalizeHandle(handle)}.json`);
}

/** Writes `dossier` as pretty JSON to <vault>/30-Resources/.follow-scores/<handle>.json, creating the dir. */
export function writeDossier(vaultRoot, dossier) {
  mkdirSync(dossierDir(vaultRoot), { recursive: true });
  const path = dossierPath(vaultRoot, dossier.handle);
  writeFileSync(path, JSON.stringify(dossier, null, 2) + "\n", "utf8");
  return path;
}

/** Reads the dossier for `handle`, or null if it hasn't been written yet. */
export function readDossier(vaultRoot, handle) {
  const path = dossierPath(vaultRoot, handle);
  if (!existsSync(path)) return null;
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return null;
  }
}
