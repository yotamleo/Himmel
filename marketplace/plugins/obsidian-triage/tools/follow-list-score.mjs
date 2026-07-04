#!/usr/bin/env node
// follow-list-score.mjs — HIMMEL-660 X-follow-list scorer, Task 5: CLI
// entry + `gather` subcommand. Wires Tasks 1-4 (roster, dossier, verify,
// screen) into one per-handle evidence-gathering pipeline.
//
// Usage:
//   node follow-list-score.mjs gather --vault <path> [--limit N] [--dry-run] [--refetch]
//   node follow-list-score.mjs assemble --vault <path>    (Task 7: reads every
//     <handle>.judgment.json under <vault>/30-Resources/.follow-scores/,
//     ranks via follow-score.mjs's rankAccounts (deterministic tiering +
//     ./follow-overrides.json whitelist/force-exclude), regenerates ONLY
//     the tier sections of ai-x-follow-list.md (frontmatter + any footer
//     stay byte-identical), and writes ai-x-follow-scores.md.)
//   node follow-list-score.mjs judge-prep --vault <path>  (Task 6: reads every
//     dossier under <vault>/30-Resources/.follow-scores/*.json, trims it via
//     follow-screen's trimForJudge, and writes the redacted judge queue to
//     <vault>/30-Resources/.follow-scores/_judge-queue.jsonl. This is the
//     pluggable LLM seam: a Claude judge pass (or any future replacement)
//     consumes the queue against ./follow-judge-charter.md and writes
//     <handle>.judgment.json — swapping the judge changes only that
//     consumer, never gather/assemble.
//
// Exit codes: 0 — run completed; 1 — bad usage / vault not found.
//
// Account-level fetch (Task 0 SPIKE_RESULT: A) is encoded at
// ./follow-account-source.json, read at runtime — never the state-repo
// findings note (Global Constraint).
//
// gather pipeline, per roster handle:
//   buildCorpusEvidence -> fetchAccount -> extractClaims -> resolveGithub
//   + fetchRepos -> verifyClaims -> screenDossier -> verifyWebClaims
//   (skipped when injection_suspect, HIMMEL-703 Gap B) -> writeDossier
// A handle with an existing (fresh) dossier is skipped unless --refetch.
// "Fresh" == a dossier already exists on disk; the dossier schema (Task 2)
// carries no fetch timestamp, so existence is the only signal available.
//
// Hermetic test seams (mirror fxtwitter-enrich.mjs's FXT_FIXTURE): when
// FOLLOW_GH_FIXTURE / FOLLOW_ACCOUNT_FIXTURE / FOLLOW_SCAN_FIXTURE are set
// (to a file path OR inline JSON text), the corresponding real dependency
// (gh / fxtwitter fetch / HIMMEL-256 python screener) is bypassed:
//   FOLLOW_GH_FIXTURE      -> JSON object keyed by `args.join(" ")`
//                             (e.g. "api users/x/repos?per_page=100").
//   FOLLOW_ACCOUNT_FIXTURE -> JSON object keyed by the fetch URL.
//   FOLLOW_SCAN_FIXTURE    -> a single JSON boolean (true = injection hit), or
//                             the JSON string "error" (scanner-can't-run ->
//                             fail-closed screen_error).
//   FOLLOW_URL_FIXTURE     -> JSON object mapping a t.co shortUrl -> finalUrl
//                             (bypasses the real curl redirect-follow).

import { existsSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

import { resolveRoster } from "./lib/follow-roster.mjs";
import {
  buildCorpusEvidence,
  emptyDossier,
  writeDossier,
  readDossier,
  extractShortLinks,
} from "./lib/follow-dossier.mjs";
import {
  extractClaims,
  resolveGithub,
  fetchRepos,
  verifyClaims,
} from "./lib/follow-verify.mjs";
import { screenDossier, trimForJudge } from "./lib/follow-screen.mjs";
import { verifyWebClaims, makeWebFn } from "./lib/follow-web.mjs";
import { sha256 } from "./lib/frontmatter.mjs";
import { rankAccounts, renderList, renderScorecard } from "./lib/follow-score.mjs";

const TOOLS_DIR = dirname(fileURLToPath(import.meta.url));
const SUBCOMMANDS = ["gather", "assemble", "judge-prep"];

function usage(code = 1) {
  const out = code === 0 ? console.log : console.error;
  out("Usage: follow-list-score.mjs <gather|assemble|judge-prep> --vault <path> [--limit N] [--dry-run] [--refetch]");
  out("");
  out("gather:      fetch/verify/screen evidence per roster handle; writes one dossier JSON per handle.");
  out("assemble:    ranks judgments (tiering + overrides) and writes ai-x-follow-list.md + ai-x-follow-scores.md.");
  out("judge-prep:  trims every dossier via trimForJudge and writes the judge queue (_judge-queue.jsonl).");
  process.exit(code);
}

function parseArgs(argv) {
  const rest = argv.slice(2);
  if (rest.length === 0) usage(1);
  const first = rest[0];
  if (first === "-h" || first === "--help") usage(0);
  if (!SUBCOMMANDS.includes(first)) {
    console.error(`unknown subcommand: ${first}`);
    usage(1);
  }
  const out = { cmd: first, vault: null, limit: 0, dryRun: false, refetch: false };
  for (let i = 1; i < rest.length; i++) {
    const a = rest[i];
    if (a === "--vault") out.vault = rest[++i];
    else if (a === "--limit") out.limit = parseInt(rest[++i] || "0", 10) || 0;
    else if (a === "--dry-run") out.dryRun = true;
    else if (a === "--refetch") out.refetch = true;
    else if (a === "-h" || a === "--help") usage(0);
    else {
      console.error(`unknown arg: ${a}`);
      usage(1);
    }
  }
  if (!out.vault) usage(1);
  return out;
}

// ---------------------------------------------------------------------------
// Account-source (Task 0 spike decision, read at runtime — never the
// state-repo findings note).
// ---------------------------------------------------------------------------

function loadAccountSource() {
  const path = join(TOOLS_DIR, "follow-account-source.json");
  return JSON.parse(readFileSync(path, "utf8"));
}

/**
 * Fetches account-level evidence for `handle`. If `accountSource.spike_result`
 * is "A", GETs `accountSource.endpoint` (with `<handle>` substituted) via
 * `fetchFn` and maps the fxtwitter user response into account{}. If "B" (no
 * confirmed account-level source), returns the corpus-only shape. Does NOT
 * populate `cadence_days` — the caller merges that in from
 * `buildCorpusEvidence` (its own dependency, not fetchAccount's).
 */
export async function fetchAccount(handle, accountSource, { fetchFn } = {}) {
  const empty = (source, status) => ({
    followers: null,
    following: null,
    bio: null,
    created_at: null,
    source,
    fetch_status: status,
  });

  if (!accountSource || accountSource.spike_result !== "A") {
    return empty("corpus", "no_account_source");
  }
  if (!accountSource.endpoint || !fetchFn) {
    return empty("fxtwitter", "failed");
  }

  const url = accountSource.endpoint.replace("<handle>", encodeURIComponent(handle));
  try {
    const data = await fetchFn(url);
    const user = data && data.user;
    if (!user) return empty("fxtwitter", "failed");
    return {
      followers: typeof user.followers === "number" ? user.followers : null,
      following: typeof user.following === "number" ? user.following : null,
      bio: user.description ?? null,
      created_at: user.joined ?? null,
      source: "fxtwitter",
      fetch_status: "ok",
    };
  } catch {
    return empty("fxtwitter", "failed");
  }
}

// ---------------------------------------------------------------------------
// Real dependency impls + hermetic fixture seams.
// ---------------------------------------------------------------------------

// Reads a FOLLOW_*_FIXTURE env var: its value is either a path to a file
// containing the fixture JSON, or the JSON itself inline. Returns the raw
// text, or null when the env var is unset/empty.
function readFixtureEnv(name) {
  const raw = process.env[name];
  if (raw == null || raw === "") return null;
  try {
    if (existsSync(raw)) return readFileSync(raw, "utf8");
  } catch {
    // not a valid path -- fall through to treating it as inline JSON
  }
  return raw;
}

function makeGhFn() {
  const fixtureRaw = readFixtureEnv("FOLLOW_GH_FIXTURE");
  if (fixtureRaw != null) {
    const map = JSON.parse(fixtureRaw);
    return (args) => {
      const key = args.join(" ");
      if (!(key in map)) {
        throw new Error(`follow-list-score: no FOLLOW_GH_FIXTURE entry for "gh ${key}"`);
      }
      return map[key];
    };
  }
  return (args) => {
    const res = spawnSync("gh", args, {
      encoding: "utf-8",
      windowsHide: true,
      maxBuffer: 10 * 1024 * 1024,
    });
    if (res.error) throw res.error;
    if (res.status !== 0) {
      throw new Error(`gh ${args.join(" ")} exited ${res.status}: ${(res.stderr || "").slice(0, 200)}`);
    }
    return JSON.parse(res.stdout);
  };
}

function makeFetchFn() {
  const fixtureRaw = readFixtureEnv("FOLLOW_ACCOUNT_FIXTURE");
  if (fixtureRaw != null) {
    const map = JSON.parse(fixtureRaw);
    return async (url) => {
      if (!(url in map)) {
        throw new Error(`follow-list-score: no FOLLOW_ACCOUNT_FIXTURE entry for "${url}"`);
      }
      return map[url];
    };
  }
  return async (url) => {
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), 15000);
    try {
      const r = await fetch(url, {
        headers: { Accept: "application/json", "User-Agent": "follow-list-score/1.0" },
        signal: ctrl.signal,
      });
      if (!r.ok) throw new Error(`http_${r.status}`);
      return await r.json();
    } finally {
      clearTimeout(t);
    }
  };
}

// No fixture seam is defined for headFn (not one of the three named
// FOLLOW_* fixtures) -- real course-claim verification isn't exercised by
// this task's tests. Implemented synchronously (spawnSync curl) to match
// verifyClaims' sync headFn(url)->number contract.
function makeHeadFn() {
  return (url) => {
    const res = spawnSync("curl", ["-s", "-I", "--max-time", "10", url], {
      encoding: "utf-8",
      windowsHide: true,
    });
    if (res.error || res.status !== 0) throw new Error("follow-list-score: HEAD request failed");
    const m = /^HTTP\/\S+\s+(\d{3})/.exec(res.stdout || "");
    if (!m) throw new Error("follow-list-score: HEAD: no status line");
    return parseInt(m[1], 10);
  };
}

// Resolves a shortened t.co URL to its final destination. Fixture seam
// (FOLLOW_URL_FIXTURE = JSON map shortUrl->finalUrl) for hermetic tests;
// otherwise a real curl redirect-follow (matches makeHeadFn's spawnSync
// style). Returns the final URL, or null on failure / unknown short link.
function makeUrlFn() {
  const fixtureRaw = readFixtureEnv("FOLLOW_URL_FIXTURE");
  if (fixtureRaw != null) {
    const map = JSON.parse(fixtureRaw);
    return (url) => (url in map ? map[url] : null);
  }
  return (url) => {
    const res = spawnSync(
      "curl",
      ["-s", "-o", "/dev/null", "-w", "%{url_effective}", "-L", "--max-time", "10", url],
      { encoding: "utf-8", windowsHide: true }
    );
    if (res.error || res.status !== 0) return null;
    const out = (res.stdout || "").trim();
    return out || null;
  };
}

function makeScanFn() {
  const fixtureRaw = readFixtureEnv("FOLLOW_SCAN_FIXTURE");
  if (fixtureRaw == null) return undefined; // let screenDossier use its real defaultScanFn
  const parsed = JSON.parse(fixtureRaw);
  // The string "error" simulates a scanner that can't run: screenDossier's
  // fail-closed catch flags injection_suspect + screen_status="screen_error".
  // Lets a hermetic test prove the fail-closed path skips the web rung too.
  if (parsed === "error") {
    return () => {
      throw new Error("follow-scan fixture: forced scanner error");
    };
  }
  return () => !!parsed;
}

// ---------------------------------------------------------------------------
// gather subcommand
// ---------------------------------------------------------------------------

function listPathFor(vaultRoot) {
  return join(vaultRoot, "30-Resources", "ai-x-follow-list.md");
}

async function processHandle(vaultRoot, handle, rosterInfo, accountSource, deps) {
  const corpus = buildCorpusEvidence(vaultRoot, handle);
  const dossier = emptyDossier(handle, rosterInfo);
  dossier.corpus.sample_tweets = corpus.sample_tweets;
  dossier.corpus.crypto_tagged = corpus.crypto_tagged;

  const account = await fetchAccount(handle, accountSource, { fetchFn: deps.fetchFn });
  dossier.account = { ...dossier.account, ...account, cadence_days: corpus.cadence_days };

  // Surface github/course/product URLs hidden behind t.co shorteners in the
  // sample tweets: resolve each and feed the final URLs to extractClaims as
  // extra claim-source strings (extractClaims stays pure — just more text).
  const sampleTexts = corpus.sample_tweets.map((t) => t.text);
  const resolvedUrls = sampleTexts
    .flatMap((t) => extractShortLinks(t))
    .map((u) => deps.urlFn(u))
    .filter((u) => typeof u === "string" && u.length > 0);
  dossier.claims = extractClaims(dossier.account.bio, [...sampleTexts, ...resolvedUrls]);

  const gh = resolveGithub(dossier.account.bio, handle, { ghFn: deps.ghFn });
  const repoEvidence = fetchRepos(gh.login, { ghFn: deps.ghFn });
  dossier.repos = {
    ...dossier.repos,
    login: gh.login,
    ...repoEvidence,
    source: gh.login ? "github" : null,
  };

  dossier.claims = verifyClaims(dossier, {
    ghFn: deps.ghFn,
    headFn: deps.headFn,
    accountSource,
  });

  // Injection screen BEFORE any LLM-backed web backend (HIMMEL-703 Gap B).
  // screenDossier concatenates the untrusted bio / repo-descriptions / tweet
  // text that claim.text is derived from and flags injection_suspect
  // (fail-closed). It runs here — not after the web rung — so a suspect
  // account's untrusted-derived claim text never reaches the LLM-backed web
  // backends (agy/hermes), which would otherwise judge it before it was ever
  // screened.
  screenDossier(dossier, deps.scanFn ? { scanFn: deps.scanFn } : {});

  // Web rung: upgrade the non-github claims verifyClaims left `unverified`
  // (course/role/product/url) against the open web. Skipped entirely for an
  // injection-suspect dossier (HIMMEL-703 Gap B) — we never feed a flagged
  // account's claims to an LLM-backed backend. Dark unless a backend is wired
  // (deps.webFn null -> no-op); the chain tries free/local sources before the
  // metered firecrawl last resort. Shared webFn budget-caps the run.
  if (!dossier.injection_suspect) {
    dossier.claims = await verifyWebClaims(dossier, { webFn: deps.webFn });
  }

  return dossier;
}

async function runGather(args) {
  const vaultRoot = args.vault;
  const roster = resolveRoster(vaultRoot, listPathFor(vaultRoot), {});
  const limited = args.limit > 0 ? roster.slice(0, args.limit) : roster;

  console.log(`follow-list-score gather: ${limited.length} handle(s) resolved from roster. vault=${vaultRoot}`);

  if (args.dryRun) {
    for (const r of limited) {
      console.log(`  DRY  ${r.handle}  clips=${r.clipCount}  in_list=${r.inList}`);
    }
    console.log(`\nfollow-list-score gather: dry-run, 0 dossiers written.`);
    process.exit(0);
  }

  const accountSource = loadAccountSource();
  const deps = {
    ghFn: makeGhFn(),
    fetchFn: makeFetchFn(),
    headFn: makeHeadFn(),
    urlFn: makeUrlFn(),
    scanFn: makeScanFn(),
    webFn: makeWebFn(),
  };

  let ok = 0;
  let skipped = 0;
  for (const r of limited) {
    if (!args.refetch && readDossier(vaultRoot, r.handle) !== null) {
      console.log(`SKIP ${r.handle} (fresh dossier on disk; use --refetch)`);
      skipped++;
      continue;
    }
    const dossier = await processHandle(
      vaultRoot,
      r.handle,
      { clipCount: r.clipCount, inList: r.inList },
      accountSource,
      deps
    );
    writeDossier(vaultRoot, dossier);
    console.log(`OK   ${r.handle}`);
    ok++;
  }
  console.log(`\nfollow-list-score gather: ${ok} scored, ${skipped} skipped (fresh).`);
  process.exit(0);
}

// ---------------------------------------------------------------------------
// judge-prep subcommand (Task 6, the pluggable LLM judge seam)
// ---------------------------------------------------------------------------

function dossierScoresDir(vaultRoot) {
  return join(vaultRoot, "30-Resources", ".follow-scores");
}

function charterRefFor() {
  const path = join(TOOLS_DIR, "follow-judge-charter.md");
  return { path, sha256: sha256(readFileSync(path, "utf8")) };
}

function runJudgePrep(args) {
  const vaultRoot = args.vault;
  const scoresDir = dossierScoresDir(vaultRoot);
  const queuePath = join(scoresDir, "_judge-queue.jsonl");

  // No dossiers gathered yet -- nothing to prep. Don't create the dir as a
  // side effect of a no-op run.
  if (!existsSync(scoresDir)) {
    console.log(`follow-list-score judge-prep: 0 dossiers found (no .follow-scores dir yet) under ${vaultRoot}`);
    process.exit(0);
  }

  const charterRef = charterRefFor();
  const dossierFiles = readdirSync(scoresDir)
    .filter((f) => f.endsWith(".json") && !f.endsWith(".judgment.json"))
    .sort();

  const lines = [];
  for (const file of dossierFiles) {
    let dossier;
    try {
      dossier = JSON.parse(readFileSync(join(scoresDir, file), "utf8"));
    } catch {
      continue; // skip unreadable/malformed dossier files
    }
    lines.push(
      JSON.stringify({
        handle: dossier.handle,
        charter_ref: charterRef,
        trimmed_dossier: trimForJudge(dossier),
      })
    );
  }

  writeFileSync(queuePath, lines.length ? lines.join("\n") + "\n" : "", "utf8");

  console.log(`follow-list-score judge-prep: wrote ${lines.length} dossier(s) to ${queuePath}`);
  process.exit(0);
}

// ---------------------------------------------------------------------------
// assemble subcommand (Task 7: deterministic tiering + overrides + write-back)
// ---------------------------------------------------------------------------

function loadOverrides() {
  const path = join(TOOLS_DIR, "follow-overrides.json");
  return JSON.parse(readFileSync(path, "utf8"));
}

function scorecardPathFor(vaultRoot) {
  return join(vaultRoot, "30-Resources", "ai-x-follow-scores.md");
}

function runAssemble(args) {
  const vaultRoot = args.vault;
  const scoresDir = dossierScoresDir(vaultRoot);

  // No dossiers gathered yet -- nothing to assemble. Don't touch the list
  // or scorecard files on a no-op run (mirrors judge-prep's guard).
  if (!existsSync(scoresDir)) {
    console.log(`follow-list-score assemble: 0 dossiers found (no .follow-scores dir yet) under ${vaultRoot}`);
    process.exit(0);
  }

  const judgmentFiles = readdirSync(scoresDir)
    .filter((f) => f.endsWith(".judgment.json"))
    .sort();

  const judgments = [];
  const dossiers = {};
  for (const file of judgmentFiles) {
    let judgment;
    try {
      judgment = JSON.parse(readFileSync(join(scoresDir, file), "utf8"));
    } catch {
      continue; // skip unreadable/malformed judgment files
    }
    judgments.push(judgment);
    const dossier = readDossier(vaultRoot, judgment.handle);
    if (dossier) dossiers[dossier.handle] = dossier;
  }

  const overrides = loadOverrides();
  const ranked = rankAccounts(judgments, overrides);

  const listPath = listPathFor(vaultRoot);
  const existing = existsSync(listPath) ? readFileSync(listPath, "utf8") : "";
  writeFileSync(listPath, renderList(ranked, existing), "utf8");

  const scorecardPath = scorecardPathFor(vaultRoot);
  writeFileSync(scorecardPath, renderScorecard(ranked, dossiers), "utf8");

  const excluded = ranked.filter((e) => e.tier === "exclude").length;
  const visible = ranked.length - excluded;
  console.log(
    `follow-list-score assemble: ${judgments.length} judgment(s) ranked, ${visible} visible, ${excluded} excluded. Wrote ${listPath} and ${scorecardPath}.`
  );
  process.exit(0);
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  const args = parseArgs(process.argv);
  if (!existsSync(args.vault)) {
    console.error(`follow-list-score: vault not found: ${args.vault}`);
    process.exit(1);
  }

  if (args.cmd === "gather") {
    await runGather(args);
    return;
  }

  if (args.cmd === "judge-prep") {
    runJudgePrep(args);
    return;
  }

  if (args.cmd === "assemble") {
    runAssemble(args);
    return;
  }
}

// Run unless imported as a module (tests import fetchAccount directly).
// import.meta.main is bun-only; fall back to argv[1] basename match for node.
const _argv1 = (process.argv[1] || "").replace(/\\/g, "/");
const _isMain = import.meta.main === true || _argv1.endsWith("follow-list-score.mjs");

if (_isMain) {
  main().catch((e) => {
    console.error("follow-list-score: fatal:", e);
    process.exit(1);
  });
}
