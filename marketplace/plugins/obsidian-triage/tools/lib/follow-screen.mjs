#!/usr/bin/env node
// follow-screen.mjs — HIMMEL-660 X-follow-list scorer, Task 4: injection
// screen + judge-view redaction (HIMMEL-256 defense).
//
// screenDossier concatenates every UNTRUSTED text field a dossier carries
// (account.bio, repos.sample_descriptions[], corpus.sample_tweets[].text)
// into one temp file and hands it to `scanFn` — the same
// harvest-clip-body-batch.py --scan-only screener fxtwitter-enrich.mjs
// already uses for post-body-fill re-screening. A hit (or any failure to
// run the scanner at all) sets dossier.injection_suspect. Fail-closed: if
// the scanner can't run, the dossier is flagged rather than trusted.
//
// trimForJudge is the redacting view a judge/LLM prompt is built from: it
// never sees an injection-suspect account's raw bio/repo descriptions, and
// it never sees more than the top-5 sample tweets regardless of suspicion.

import { spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { writeFileSync, unlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const TOOLS_DIR = dirname(dirname(fileURLToPath(import.meta.url)));
const SCREENER = join(TOOLS_DIR, "harvest-clip-body-batch.py");

/**
 * Real scanFn: runs harvest-clip-body-batch.py --scan-only over `tmpFile`.
 * Returns true on a hit, false when clean. Throws on any spawn failure or
 * unexpected exit status so the caller's fail-closed handling kicks in.
 */
function defaultScanFn(tmpFile) {
  const screener = process.env.FOLLOW_SCREENER || SCREENER;
  const args = [screener, "--scan-only", tmpFile];
  const opts = { encoding: "utf-8", timeout: 20000, windowsHide: true };
  let res = spawnSync("python", args, opts);
  if (res.error && res.error.code === "ENOENT") {
    res = spawnSync("python3", args, opts);
  }
  if (res.error) throw new Error(`follow-screen: spawn failed: ${res.error.message}`);
  if (res.status === 0) return false;
  if (res.status === 1) return true;
  throw new Error(`follow-screen: scanner exited ${res.status}`);
}

function untrustedText(dossier) {
  const parts = [];
  if (dossier.account?.bio) parts.push(dossier.account.bio);
  for (const desc of dossier.repos?.sample_descriptions || []) {
    if (desc) parts.push(desc);
  }
  for (const tweet of dossier.corpus?.sample_tweets || []) {
    if (tweet?.text) parts.push(tweet.text);
  }
  return parts.join("\n");
}

/**
 * Screens a dossier's untrusted text fields for prompt injection.
 *
 * Writes account.bio + repos.sample_descriptions[] + corpus.sample_tweets[]
 * .text into a single temp file (os.tmpdir()) and calls `scanFn(tmpFile)`.
 * On a hit, sets dossier.injection_suspect = true. Fail-closed: if scanFn
 * throws (scanner missing, spawn error, unexpected exit), also sets
 * injection_suspect = true and screen_status = "screen_error". On a clean
 * scan, sets injection_suspect = false and screen_status = "ok".
 *
 * Mutates and returns `dossier`.
 *
 * @param {object} dossier
 * @param {{scanFn?: (tmpFile: string) => boolean}} [opts]
 * @returns {object} the same dossier, with injection_suspect/screen_status set.
 */
export function screenDossier(dossier, { scanFn = defaultScanFn } = {}) {
  const tmpFile = join(tmpdir(), `follow-screen-${randomUUID()}.txt`);
  try {
    writeFileSync(tmpFile, untrustedText(dossier), "utf8");
    dossier.injection_suspect = !!scanFn(tmpFile);
    dossier.screen_status = "ok";
  } catch {
    dossier.injection_suspect = true;
    dossier.screen_status = "screen_error";
  } finally {
    try {
      unlinkSync(tmpFile);
    } catch {
      // best-effort cleanup only
    }
  }
  return dossier;
}

/**
 * Builds the redacted view of `dossier` a judge/LLM prompt is built from.
 *
 * Always trims corpus.sample_tweets to the top 5. When
 * dossier.injection_suspect is true, also replaces account.bio, every
 * repos.sample_descriptions[] entry, every surviving sample_tweets[].text, AND
 * every claims[].text with "[withheld: injection-suspect]" — the tweet body is
 * often exactly where the injection hit lives (HIMMEL-703 Gap C), and claims[]
 * carry regex-extracted spans of that same untrusted bio/tweet text, so
 * redacting bio/descriptions while leaking the tweets or claims would defeat
 * the screen. A clean dossier (injection_suspect: false) passes
 * bio/descriptions/tweets/claims through unredacted. Never mutates the input.
 *
 * @param {object} dossier
 * @returns {object} a deep-cloned, redacted dossier.
 */
export function trimForJudge(dossier) {
  const out = structuredClone(dossier);
  if (out.corpus?.sample_tweets) {
    out.corpus.sample_tweets = out.corpus.sample_tweets.slice(0, 5);
  }
  if (out.injection_suspect) {
    const withheld = "[withheld: injection-suspect]";
    // Blank the untrusted text but keep the object's metadata (tweet stats,
    // claim kind/status) the judge legitimately needs. The `typeof === "object"`
    // guard means a non-object entry can never leak its characters through
    // numeric spread keys while `text` merely looks redacted.
    const redactText = (t) => ({ ...(t && typeof t === "object" ? t : {}), text: withheld });
    if (out.account) out.account.bio = withheld;
    if (out.repos?.sample_descriptions) {
      out.repos.sample_descriptions = out.repos.sample_descriptions.map(() => withheld);
    }
    // Gap C (HIMMEL-703): the tweet body is often where the injection hit
    // lives, yet the (top-5) tweets would otherwise still reach the judge.
    // Redact each tweet's text; the stats/shape are kept so the judge still
    // sees engagement signal, just never the untrusted body.
    if (out.corpus?.sample_tweets) {
      out.corpus.sample_tweets = out.corpus.sample_tweets.map(redactText);
    }
    // Claims carry regex-extracted spans of the SAME untrusted bio/tweet text
    // (extractClaims) and the judge charter reads them, so a suspect account's
    // claim.text must be withheld too — the sibling of the Gap C tweet leak.
    // kind/status are preserved for the judge's verified/unverified weighting.
    if (Array.isArray(out.claims)) {
      out.claims = out.claims.map(redactText);
    }
  }
  return out;
}
