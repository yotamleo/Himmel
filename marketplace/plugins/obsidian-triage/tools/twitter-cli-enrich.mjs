#!/usr/bin/env node
/**
 * twitter-cli-enrich.mjs — signal-gated X thread/reply escalation backend.
 *
 * For every clip in <vault>/Clippings/ with:
 *   - harvest_skill: clip-body
 *   - needs_thread: true            (set by fxtwitter-enrich.mjs on a thread/reply signal)
 *   - source: https://x.com/<user>/status/<id> (or twitter.com)
 *   - no existing crawled_at: marker
 * fetch the focal tweet + its self-thread + first link-bearing reply via
 * `twitter tweet <id> --json` (public-clis/twitter-cli, cookie+HTTP) and fold a
 * "## Crawled content" section into the clip body BEFORE "## Source" (or
 * "## Comments"). Add frontmatter markers: crawled_at, crawl_skill, crawl_status,
 * last_error (only on partial/failed).
 *
 * This is the Revision-2 replacement for the dead Playwright escalation
 * (playwright-crawl-x.mjs): X/Google anti-automation blocks login on
 * automation-controlled browsers, so a headless/headful scrape can't capture a
 * burner session at all. twitter-cli dodges that with explicit burner cookies.
 *
 * AUTH — BURNER ACCOUNT ONLY. twitter-cli reads TWITTER_AUTH_TOKEN + TWITTER_CT0
 * from the environment (auth.py::load_from_env). The operator sources the
 * gitignored .env (burner tokens) into the shell before running; this tool only
 * READS process.env (never the .env file — block-read-secrets). If the env vars
 * are absent the tool REFUSES to run, because twitter-cli would otherwise fall
 * back to browser-cookie3 extraction — the wrong (main) account, and broken on
 * Windows anyway (Chrome App-Bound-Encryption v127+).
 *
 * G-3 invariant: existing body sections are preserved verbatim post-write,
 * after CRLF→LF normalization (parseFrontmatter normalizes line endings on
 * entry, so a CRLF-authored clip is rewritten LF-only). Only the new
 * "## Crawled content" H2 may be added. Frontmatter mutation is whitelisted to
 * the four crawl_* keys. YAML parse-validate the post-write frontmatter; revert
 * to the pre-write baseline on parse failure.
 *
 * Idempotent: re-runs skip clips with crawled_at: already present. A failed
 * escalation never corrupts the fxtwitter enrichment (no body section written).
 *
 * Usage:
 *   node twitter-cli-enrich.mjs --vault <path> [--limit N] [--replies N] [--dry-run]
 *
 * Exit codes:
 *   0 — run completed (may include partial/failed clips; see summary)
 *   1 — bad usage
 *   2 — missing burner credentials (TWITTER_AUTH_TOKEN / TWITTER_CT0)
 *
 * LUNA-27. Sister scripts: fxtwitter-enrich.mjs (default auth-free X path),
 * playwright-crawl-youtube.mjs.
 */
import { existsSync, readFileSync, writeFileSync, readdirSync } from "node:fs";
import { join, relative, sep } from "node:path";
import { pathToFileURL } from "node:url";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";

const TODAY = new Date().toISOString().slice(0, 10);
const NOW_ISO = new Date().toISOString();
const SLEEP_MIN_MS = 3000;
const SLEEP_MAX_MS = 5000;

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

/**
 * Politeness jitter between CLI calls. Test seam: CRAWL_SLEEP_MS=0 makes it
 * instant. A malformed value must NOT silently disable throttling on a real run
 * (risks an X rate-limit) — warn and fall through to normal jitter.
 */
function jitterSleep() {
  if (process.env.CRAWL_SLEEP_MS != null) {
    const v = Number(process.env.CRAWL_SLEEP_MS);
    if (Number.isNaN(v)) {
      process.stderr.write(
        `twitter-cli-enrich: WARN CRAWL_SLEEP_MS="${process.env.CRAWL_SLEEP_MS}" is not a number — ignoring, using normal jitter\n`,
      );
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
 * Glob Clippings/*.md plus one-level subfolders. Returns absolute paths.
 */
function findClips(vault) {
  const root = join(vault, "Clippings");
  if (!existsSync(root)) {
    console.error(`twitter-cli-enrich: no Clippings/ dir at ${root}`);
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
        const subs = readdirSync(sub, { withFileTypes: true });
        for (const s of subs) {
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
 * Parse top-level frontmatter. Minimal YAML-ish — top-level key: value only.
 * Normalises CRLF → LF on entry so Windows-edited clips parse correctly.
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
  const s = (sourceVal || "").trim().replace(/^"|"$/g, "");
  const m = s.match(/^https?:\/\/(?:www\.|mobile\.)?(?:x|twitter)\.com(\/[^/]+\/status\/\d+)/);
  if (!m) return null;
  return `https://x.com${m[1]}`;
}

/** Extract the numeric status id from an x/twitter status URL. */
export function extractStatusId(url) {
  const m = (url || "").match(/\/status\/(\d+)/);
  return m ? m[1] : null;
}

function formatYamlValue(v) {
  if (typeof v !== "string") return String(v);
  if (/[:#"\n]|^\s|\s$|^-|^[0-9]/.test(v)) {
    return `"${v.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
  }
  return v;
}

/**
 * Insert four crawl_* markers into frontmatter, after the last non-empty
 * top-level line. Replace existing crawl_* keys in place; drop a key when its
 * marker value is null/undefined (e.g. last_error on success).
 */
function upsertCrawlMarkers(fmRaw, markers) {
  const orderedKeys = ["crawled_at", "crawl_skill", "crawl_status", "last_error"];
  let lines = fmRaw.split("\n");
  const seen = new Set();
  lines = lines
    .map((line) => {
      for (const k of orderedKeys) {
        const re = new RegExp(`^${k}:`);
        if (re.test(line)) {
          seen.add(k);
          if (markers[k] === undefined || markers[k] === null) return null;
          return `${k}: ${formatYamlValue(markers[k])}`;
        }
      }
      return line;
    })
    .filter((l) => l !== null);

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
    const sep2 = body.endsWith("\n") ? "" : "\n";
    return body + sep2 + "\n" + sectionMarkdown + "\n";
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
 * Render the "## Crawled content" body section. Backend-agnostic: takes the
 * mapped shape { mainText, selfThread[], topReply{text,url}|null, quoteText }.
 */
export function renderCrawledSection(
  { mainText, selfThread = [], topReply = null, quoteText },
  skill = "twitter-cli",
) {
  const total = selfThread.length + 1;
  const lines = [
    "## Crawled content",
    `<!-- crawled ${TODAY} via ${skill} -->`,
    "",
    "### Main tweet",
    "",
    mainText,
    "",
  ];
  if (selfThread.length > 0) {
    lines.push(`### Thread (${total} segments)`, "");
    selfThread.forEach((seg, i) => {
      lines.push(`**${i + 2}/${total}**`, "", seg, "");
    });
  }
  lines.push("### Top reply", "");
  if (topReply && topReply.text) {
    lines.push(topReply.text, "");
    if (topReply.url) lines.push(`Link: ${topReply.url}`, "");
  } else {
    lines.push("_none captured_", "");
  }
  lines.push("### Quoted tweet", "");
  lines.push(quoteText ? quoteText : "_none_");
  return lines.join("\n");
}

/**
 * Fold a tweet's expanded urls[] into its display text. X parks the payload
 * (e.g. a repo link) in urls[]; the body often only has a t.co shortlink, so
 * append any expanded url not already present verbatim in the text.
 */
function foldUrls(text, urls = []) {
  let out = text || "";
  for (const u of urls) {
    if (u && !out.includes(u)) out += `\n${u}`;
  }
  return out;
}

/**
 * Map twitter-cli `data[]` (data[0] focal, data[1:] conversation) into the
 * backend-agnostic shape renderCrawledSection consumes.
 * - selfThread: contiguous same-author (case-insensitive screenName) entries
 *   right after the focal tweet, each with its urls[] folded in. Stops at the
 *   first other-author entry (X groups the self-thread ahead of replies).
 * - topReply: among the entries AFTER the self-thread break, the first
 *   other-author entry, preferring one that carries a url (the repo case).
 * Pure + side-effect free.
 */
export function mapTweetData(data) {
  if (!Array.isArray(data) || data.length === 0) {
    return { mainText: "", selfThread: [], topReply: null, quoteText: "" };
  }
  const focal = data[0];
  const handle = (t) => (t?.author?.screenName || "").trim().toLowerCase();
  const focalHandle = handle(focal);
  // Fold the focal tweet's own expanded urls[] in too — a tweet that links out
  // directly (not just via a self-reply) parks the expanded link in urls[]
  // while the visible body carries only a t.co shortlink.
  const mainText = foldUrls(focal?.text || "", focal?.urls || []);
  const quoteText = focal?.quotedTweet?.text || "";

  const selfThread = [];
  let i = 1;
  for (; i < data.length; i++) {
    const h = handle(data[i]);
    if (h && focalHandle && h === focalHandle) {
      selfThread.push(foldUrls(data[i].text || "", data[i].urls || []));
    } else {
      break; // first other-author entry ends the self-thread run
    }
  }
  const rest = data.slice(i).filter((t) => handle(t) !== focalHandle);
  const pick = rest.find((t) => (t.urls || []).length > 0) || rest[0] || null;
  const topReply = pick
    ? { text: foldUrls(pick.text || "", pick.urls || []), url: (pick.urls || [])[0] || "" }
    : null;

  return { mainText, selfThread, topReply, quoteText };
}

/**
 * Parse a `twitter tweet --json` invocation result into a soft-fail-safe shape.
 * Pure: takes raw stdout + exit code, returns {ok:true,data} | {ok:false,error}.
 */
export function parseThreadResult(stdout, exitCode) {
  const raw = (stdout || "").trim();
  if (!raw) return { ok: false, error: exitCode === 0 ? "empty_output" : `exit_${exitCode}` };
  let payload;
  try {
    payload = JSON.parse(raw);
  } catch {
    return { ok: false, error: "bad_json" };
  }
  if (payload && payload.ok === true && Array.isArray(payload.data)) {
    return { ok: true, data: payload.data };
  }
  const code = payload && payload.error && payload.error.code ? payload.error.code : "not_ok";
  return { ok: false, error: code };
}

const TWITTER_BIN = process.env.TWITTER_BIN || "twitter";

/**
 * Run `twitter tweet <id> --json -n <n>` and parse it. Soft-fail safe: any
 * spawn error / non-zero exit / non-ok payload returns {ok:false,error}.
 */
export function fetchThread(id, n = 20) {
  let res = null;
  try {
    res = spawnSync(TWITTER_BIN, ["tweet", id, "--json", "-n", String(n)], {
      encoding: "utf-8",
      timeout: 30000,
      env: process.env,
    });
  } catch (e) {
    return { ok: false, error: `spawn_error: ${String(e.message || e).slice(0, 80)}` };
  }
  if (!res) return { ok: false, error: "spawn_error: no result" };
  if (res.error) {
    return { ok: false, error: `spawn_error: ${String(res.error.message || res.error).slice(0, 80)}` };
  }
  // spawnSync sets status=null when the child is killed by a signal — most
  // importantly the timeout above (SIGTERM). Surface that distinctly so the
  // operator's last_error breadcrumb isn't a misleading generic "exit_1".
  if (res.signal) return { ok: false, error: `killed_${res.signal}` };
  const parsed = parseThreadResult(res.stdout, res.status == null ? 1 : res.status);
  // On a non-zero exit with no parseable stdout, surface a little stderr — it's
  // the operator's only breadcrumb (rate-limited / auth-expired / not-found).
  if (!parsed.ok && res.stderr && /^(exit_|empty_output)/.test(parsed.error)) {
    const tail = String(res.stderr).trim().slice(0, 80);
    if (tail) parsed.error = `${parsed.error}: ${tail}`;
  }
  return parsed;
}

/**
 * Refuse to run without explicit burner credentials. Without them twitter-cli
 * would fall back to reading browser cookies (the main account, and broken on
 * Windows). Exits 2.
 */
function requireBurnerTokens() {
  if (!process.env.TWITTER_AUTH_TOKEN || !process.env.TWITTER_CT0) {
    console.error(
      "twitter-cli-enrich: refusing to run without burner credentials. " +
        "Set TWITTER_AUTH_TOKEN and TWITTER_CT0 (burner account only) in the " +
        "shell env (source the gitignored .env) before running. Without them " +
        "twitter-cli falls back to reading browser cookies (wrong account + " +
        "Windows App-Bound-Encryption fails).",
    );
    process.exit(2);
  }
}

/**
 * Restore the pre-write baseline after a post-write verification failure, and
 * return the FAIL result. The revert is the G-3 safety net, so it needs its own
 * safety net: a revert write that throws (e.g. the file is locked by the
 * operator's editor) must not propagate (it would abort the whole batch) and
 * must be surfaced loudly because the clip is then left in its written state.
 */
function revertBaseline(clipPath, baseline, rel, reason) {
  try {
    writeFileSync(clipPath, baseline, { encoding: "utf-8" });
    if (readFileSync(clipPath, "utf-8") !== baseline) {
      return { glyph: "x", message: `${rel} -- failed (${reason}; REVERT VERIFY FAILED — clip may be corrupt)` };
    }
  } catch (re) {
    return { glyph: "x", message: `${rel} -- failed (${reason}; REVERT THREW — clip left written: ${re.message})` };
  }
  return { glyph: "x", message: `${rel} -- failed (${reason}; reverted)` };
}

/**
 * Process a single clip. Returns { glyph, message }.
 * Glyphs: v=OK, o=SKIP, ~=PART, e=EMPTY (terminal: ok fetch, nothing to
 * capture — crawled_at stamped so it converges), x=FAIL.
 * `fetchFn(id, repliesN)` is injectable for testing (defaults to fetchThread)
 * — matches the JS-level dependency-injection pattern used by the playwright
 * crawl tests rather than a PATH-fake binary (cross-platform, no live X).
 */
export async function processClip(clipPath, vault, dryRun, repliesN, fetchFn = fetchThread) {
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
  if (!/^needs_thread:\s*true\s*$/m.test(fmRaw)) return { glyph: "o", message: `${rel} -- skipped (needs_thread not set)` };
  const sourceVal = fm.source || "";
  if (!isXSource(sourceVal)) return { glyph: "o", message: `${rel} -- skipped (not an x/twitter source)` };
  const url = canonicalXUrl(fm.harvest_url_canonical || sourceVal) || canonicalXUrl(sourceVal);
  const id = extractStatusId(url);
  if (!id) return { glyph: "x", message: `${rel} -- failed (status id): ${sourceVal}` };

  if (dryRun) return { glyph: "v", message: `${rel} -- would enrich ${url} [dry-run]` };

  // Throttle BEFORE the network call to avoid hammering X.
  await jitterSleep();

  // await so an async-injected fetchFn is handled too (the real fetchThread is
  // sync; awaiting a non-promise is a harmless no-op).
  const res = await fetchFn(id, repliesN);

  let status, lastError, section;
  if (res.ok) {
    const mapped = mapTweetData(res.data);
    if (!mapped.mainText && mapped.selfThread.length === 0 && !mapped.topReply) {
      // Fetched ok but nothing to capture (e.g. a media-only focal tweet with
      // no self-thread and no link-bearing reply). This is a TERMINAL empty,
      // NOT a transient failure: stamp crawled_at (below) + crawl_status: empty
      // so the clip converges and is skipped on re-runs, instead of re-fetching
      // forever (HIMMEL-306). Symmetric with the ok path — both stamp crawled_at
      // and converge. A media-only tweet that LATER gains a thread is therefore
      // terminal here and NOT automatically revisited by any current path
      // (fxtwitter-enrich --reflag also skips it — it short-circuits on
      // needs_thread:true, which this clip already carries); re-attempting one
      // requires manually clearing crawled_at/crawl_status. Transient fetch
      // failures (res.ok === false, below) still leave crawled_at unset to
      // re-attempt. Write no empty "## Crawled content" section (section stays null).
      status = "empty";
      lastError = null;
      section = null;
    } else {
      status = "ok";
      lastError = null;
      section = renderCrawledSection(mapped, "twitter-cli");
    }
  } else {
    // Soft fail — frontmatter-only mark; leaves the fxtwitter enrichment intact.
    status = "failed";
    lastError = res.error || "fetch_failed";
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
  if (section) newBody = insertCrawledSection(body, section);

  // Stamp crawled_at on a TERMINAL outcome (ok OR empty) so the clip skips on
  // re-run. On soft-fail, deliberately leave crawled_at UNSET so the next run
  // re-selects and re-attempts the clip — the recovery path after a burner-token
  // refresh (HIMMEL-306: empty is terminal, transient failure is not).
  const markers = {
    crawled_at: status === "ok" || status === "empty" ? NOW_ISO : null,
    crawl_skill: "twitter-cli",
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

  // Verify: re-read, parse frontmatter, body byte-equality (G-3), YAML
  // parse-validate. Revert to the pre-write baseline on any failure.
  let diskText;
  try {
    diskText = readFileSync(clipPath, "utf-8");
  } catch (e) {
    return revertBaseline(clipPath, text, rel, `post-write read: ${e.message}`);
  }
  const post = parseFrontmatter(diskText);
  if (!post.present) {
    return revertBaseline(clipPath, text, rel, "post-write parse: no closing ---");
  }
  if (post.body !== newBody) {
    return revertBaseline(clipPath, text, rel, "G-3 body-write mismatch");
  }
  if (section) {
    const stripped = post.body.replace(section, "").replace(/\n{3,}/g, "\n\n");
    const origNorm = body.replace(/\n{3,}/g, "\n\n");
    if (!stripped.includes(origNorm.trim().slice(0, 200))) {
      return revertBaseline(clipPath, text, rel, "G-3 single-section-add");
    }
  } else if (post.body !== body) {
    return revertBaseline(clipPath, text, rel, "G-3 body changed without section");
  }
  try {
    const yaml = await import("js-yaml");
    yaml.load(post.fmRaw);
  } catch (e) {
    return revertBaseline(clipPath, text, rel, `frontmatter-yaml: ${e.message}`);
  }

  if (status === "ok") return { glyph: "v", message: `${rel} -- crawled ok` };
  if (status === "empty") return { glyph: "e", message: `${rel} -- empty (ok fetch, nothing to capture; converged)` };
  return { glyph: "x", message: `${rel} -- failed: ${lastError}` };
}

function usage(code = 1) {
  console.error("Usage: twitter-cli-enrich.mjs --vault <path> [--limit N] [--replies N] [--dry-run]");
  console.error("");
  console.error("Pre-req: TWITTER_AUTH_TOKEN + TWITTER_CT0 (burner account) in the shell env.");
  process.exit(code);
}

function parseArgs(argv) {
  const out = { vault: null, limit: 0, replies: 20, dryRun: false };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--vault") out.vault = argv[++i];
    else if (a === "--limit") out.limit = parseInt(argv[++i] || "0", 10) || 0;
    else if (a === "--replies") out.replies = parseInt(argv[++i] || "20", 10) || 20;
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

async function main() {
  const args = parseArgs(process.argv);
  if (!existsSync(args.vault)) {
    console.error(`twitter-cli-enrich: vault not found: ${args.vault}`);
    process.exit(1);
  }
  if (!args.dryRun) requireBurnerTokens();

  const clips = findClips(args.vault);
  if (clips.length === 0) {
    console.log("twitter-cli-enrich: 0 clips found.");
    process.exit(0);
  }

  let ok = 0,
    failed = 0,
    skipped = 0,
    partial = 0,
    empty = 0,
    processed = 0;
  for (const clip of clips) {
    if (args.limit > 0 && processed >= args.limit) break;
    // Guard per-clip so one unexpected throw can't abort the batch (the contract
    // is "run completed, may include failed clips"). processClip is defensive,
    // but this keeps a future regression or a thrown revert contained to one clip.
    let result;
    try {
      result = await processClip(clip, args.vault, args.dryRun, args.replies);
    } catch (e) {
      const rel = relative(args.vault, clip).split(sep).join("/");
      result = { glyph: "x", message: `${rel} -- failed (unexpected): ${e.message}` };
    }
    const { glyph, message } = result;
    const prefix =
      glyph === "v" ? "OK  " : glyph === "o" ? "SKIP" : glyph === "~" ? "PART" : glyph === "e" ? "EMPT" : "FAIL";
    const target = glyph === "x" ? process.stderr : process.stdout;
    target.write(`${prefix} ${message}\n`);
    if (glyph === "v") {
      ok++;
      processed++;
    } else if (glyph === "~") {
      partial++;
      processed++;
    } else if (glyph === "e") {
      empty++;
      processed++;
    } else if (glyph === "x") {
      failed++;
      processed++;
    } else skipped++;
  }

  console.log(
    `\ntwitter-cli-enrich: ${ok} ok, ${partial} partial, ${empty} empty, ${failed} failed, ${skipped} skipped. ` +
      `(dry_run=${args.dryRun})`,
  );
  process.exit(0);
}

// Run main() only as the entrypoint, so tests can import the pure helpers.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((e) => {
    console.error("twitter-cli-enrich: fatal:", e);
    process.exit(1);
  });
}
