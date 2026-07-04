#!/usr/bin/env node
// follow-web.mjs — HIMMEL-660 X-follow-list scorer, Phase 2: a WEB
// verification rung for the claim kinds github (follow-verify.mjs) can't
// cover. Pure — takes an injected `webFn` backend, no network of its own.
//
// Dependency contract (mirrors follow-verify.mjs's ghFn/headFn seam):
//   webFn(query) -> { found: boolean, url?, title?, snippet? }  (sync OR async)
//     Searches the open web for `query` and returns the top hit. The real
//     impl is `makeFirecrawlWebFn` (firecrawl /v2/search); tests stub it
//     directly, and the CLI can inject a hermetic FOLLOW_WEB_FIXTURE map
//     (see makeWebFn).
//
// Why a WEB rung: github-linked claims already verify via `gh api`
// (follow-verify.mjs), but most accounts' evidence is non-github —
// courses, product/tool sites, "founder of <startup>", blog posts. Those
// can only be checked against the open web. This rung upgrades exactly
// those claims from `unverified` to `verified` when the web corroborates
// them, and NEVER otherwise — grounded, not trusting. A webFn error, an
// empty result, or a result whose text doesn't corroborate the claim all
// leave the claim `unverified` (we never fabricate evidence).
//
// Composition: run this AFTER follow-verify.mjs's verifyClaims. It only
// touches web-verifiable kinds (course/role/product/tool/url) that are
// still `unverified`; claims already `verified`/`contradicted` by the
// github/headFn/account rungs are passed through untouched (no downgrade),
// and repo/followers claims (owned by other rungs) are never web-checked.

import { existsSync, readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

// Kinds github/gh-api can't cover — the web rung's remit. `course` is
// included even though follow-verify's headFn does a HEAD probe: a course
// URL that 404s or was never a parseable URL stays `unverified` there and
// gets a second chance here via a content search.
// NOTE: today `extractClaims` only emits `course` and `role` among these, so
// those are the only kinds the real gather pipeline routes here. `product`,
// `tool`, and `url` are forward-declared capability for future extractors
// (exercised by unit fixtures) — the web rung already handles them, so adding
// an extractor for them is the only change needed to make them live.
export const WEB_VERIFIABLE_KINDS = new Set(["course", "role", "product", "tool", "url"]);

export const FIRECRAWL_DEFAULT_BASE_URL = "https://api.firecrawl.dev";
export const FIRECRAWL_DEFAULT_BUDGET = 20; // max searches per run (~1 credit each)
const FIRECRAWL_TIMEOUT_MS = 20000;

// qmd local-vault rung (FREE — a BM25 lookup against the operator's already-
// indexed luna vault, no external call, no credits). Generous budget since
// each probe is a local subprocess, not a metered API hit.
export const QMD_DEFAULT_COLLECTION = "luna";
export const QMD_DEFAULT_BUDGET = 40;
export const QMD_DEFAULT_MIN_SCORE = 0.5;
const QMD_TIMEOUT_MS = 20000;

// External-CLI rung (generalized prompt-in/JSON-out adapter — e.g. Google
// Antigravity's `agy`). Configured entirely via ENV so any similar CLI plugs
// in without per-tool code. Budget-capped like firecrawl.
export const CLI_DEFAULT_BUDGET = 20;
const CLI_DEFAULT_TIMEOUT_MS = 30000;

// hermes rung (the repo's multi-provider chokepoint via scripts/hermes/invoke.sh).
// hermes agent turns are slow, so a longer default timeout. Budget-capped.
export const HERMES_DEFAULT_BUDGET = 15;
const HERMES_DEFAULT_TIMEOUT_MS = 60000;
// hermes' built-in web-search toolset (CONFIGURABLE_TOOLSETS "web" -> web_search,
// web_extract). Overridable via FOLLOW_WEB_HERMES_TOOLSET if it's renamed.
export const HERMES_DEFAULT_TOOLSET = "web";

// Kind-indicator words + generic terms stripped before corroboration so a
// match must land on a claim-specific token (the startup/product/course
// name), not on the boilerplate "founder"/"course"/"http" that appears in
// every result. Keeps verification grounded rather than trivially positive.
const STOPWORDS = new Set([
  "http", "https", "www", "com", "org", "net", "the", "and", "for", "with",
  "from", "this", "that", "founder", "cofounder", "course", "works", "work",
  "product", "tool", "builder", "building", "author", "creator", "maker",
]);

// Alphanumeric tokens of length >= 4, minus stopwords — the claim-specific
// anchors we require the web result to echo.
function salientTokens(text) {
  // Split camelCase / PascalCase first ("GoogleChrome" -> "Google Chrome") so a
  // compound handle or claim fragment yields its component words, which a real
  // web result renders space-separated ("...at Google Chrome").
  const spaced = String(text || "").replace(/([a-z0-9])([A-Z])/g, "$1 $2");
  return (spaced.toLowerCase().match(/[a-z0-9]{4,}/g) || []).filter((t) => !STOPWORDS.has(t));
}

// True iff the web result actually corroborates the claim. Requires a real
// result URL (a bare `found:true` with no page can't verify anything) AND a
// CLAIM-specific token in the result's url/title/snippet. The handle is NOT an
// anchor: the query already carries the handle, so a result page about the
// account (its own X profile, say) would trivially contain the handle and
// verify any claim — that is the circular verification we must avoid. When the
// claim yields no salient token to anchor on, the fail-safe direction for a
// grounding tool is `unverified` (false), never a blanket accept.
function corroborates(claim, result) {
  const url = result.url || "";
  if (!url) return false;
  const hay = `${url} ${result.title || ""} ${result.snippet || ""}`.toLowerCase();
  const toks = salientTokens(claim.text);
  if (toks.length === 0) return false;
  return toks.some((t) => hay.includes(t));
}

/**
 * Cross-check `dossier.claims` against the open web via `webFn`. Returns a
 * NEW claims array (each claim + `status`). Only web-verifiable kinds that
 * are still `unverified` are probed; a claim becomes `verified` when webFn
 * returns `found:true` AND the result corroborates the claim text, else it
 * stays `unverified`. Claims already `verified`/`contradicted`, non-web
 * kinds, and every claim are otherwise passed through unchanged. A missing
 * `webFn` (web rung off) is a no-op — all claims pass through as-is.
 */
export async function verifyWebClaims(dossier, { webFn } = {}) {
  const claims = (dossier && dossier.claims) || [];
  if (!webFn) return claims.map((c) => ({ ...c }));

  const handle = dossier && dossier.handle ? String(dossier.handle) : "";
  const out = [];
  for (const claim of claims) {
    if (
      !WEB_VERIFIABLE_KINDS.has(claim.kind) ||
      claim.status === "verified" ||
      claim.status === "contradicted"
    ) {
      out.push({ ...claim });
      continue;
    }
    let status = "unverified";
    try {
      // Query carries the handle so the backend verifies THIS account's
      // claim, not a bare topic fragment (e.g. "@GoogleCloud" alone is
      // unsearchable; "X account @addyosmani: @GoogleCloud" is not).
      const claimText = String(claim.text || "").trim();
      const query = handle ? `X/Twitter account @${handle}: ${claimText}` : claimText;
      const result = await webFn(query);
      if (result && result.found && corroborates(claim, result)) {
        status = "verified";
      }
    } catch {
      status = "unverified"; // webFn error -> never fabricate
    }
    out.push({ ...claim, status });
  }
  return out;
}

// ---------------------------------------------------------------------------
// Fallback-chain composition (pure — no I/O of its own).
// ---------------------------------------------------------------------------

/**
 * Compose an array of webFns (nulls skipped) into a single webFn that tries
 * each in order and returns the FIRST `{found:true}` (short-circuit), falling
 * through to the next on a miss OR a thrown error (per-backend errors are
 * swallowed and treated as a miss). When every backend misses, returns
 * `{found:false}`. This is the free-first fallback: cheap local backends come
 * first, metered ones last, and the chain stops the moment one corroborates.
 */
export function chainWebFns(fns) {
  const active = (fns || []).filter(Boolean);
  return async function chainedWebFn(query) {
    for (const fn of active) {
      try {
        const r = await fn(query);
        if (r && r.found) return r;
      } catch {
        // per-backend error -> treat as a miss, try the next backend
      }
    }
    return { found: false };
  };
}

// ---------------------------------------------------------------------------
// Concrete backend: firecrawl /v2/search.
//
// Reuses the request posture of tools/harvest-clip-body-batch.py's
// FirecrawlClient: Bearer <apiKey>, honors FIRECRAWL_BASE_URL for self-hosted
// instances, budget-capped, credit-conscious. Default OFF — returns null when
// no apiKey is present, so the web rung stays dark unless the operator has
// FIRECRAWL_API_KEY set (matching the --firecrawl-thin opt-in posture).
// ---------------------------------------------------------------------------

/**
 * Build a firecrawl-backed `webFn(query) -> {found,url,title,snippet}`.
 * Returns null when `apiKey` is falsy (web rung disabled). Budget-capped:
 * after `budget` searches it returns `{found:false}` without spending a
 * credit. Any HTTP/parse failure resolves to `{found:false}` (never throws
 * into verifyWebClaims — which would only be caught as `unverified` anyway).
 */
export function makeFirecrawlWebFn({ apiKey, baseUrl, budget = FIRECRAWL_DEFAULT_BUDGET } = {}) {
  if (!apiKey) return null;
  const base = (baseUrl || FIRECRAWL_DEFAULT_BASE_URL).replace(/\/+$/, "");
  let remaining = budget;

  return async function firecrawlWebFn(query) {
    if (remaining <= 0) return { found: false };
    remaining -= 1;

    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), FIRECRAWL_TIMEOUT_MS);
    try {
      const r = await fetch(`${base}/v2/search`, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${apiKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ query, limit: 3 }),
        signal: ctrl.signal,
      });
      if (!r.ok) return { found: false };
      const data = await r.json();
      if (!data || data.success === false) return { found: false };
      // firecrawl /v2/search returns either `data: [ ... ]` or, when sources
      // are split, `data: { web: [ ... ], ... }`. Handle both defensively.
      const results = Array.isArray(data.data)
        ? data.data
        : data.data && Array.isArray(data.data.web)
          ? data.data.web
          : [];
      const top = results[0];
      if (!top || !top.url) return { found: false };
      return {
        found: true,
        url: top.url,
        title: top.title || "",
        snippet: top.description || top.snippet || top.markdown || "",
      };
    } catch {
      return { found: false }; // network/abort/parse — grounded no-op
    } finally {
      clearTimeout(t);
    }
  };
}

// ---------------------------------------------------------------------------
// Concrete backend: qmd local-vault corroboration (FREE, no external call).
//
// The FIRST rung of the chain: a BM25 (`qmd search`, no LLM/GPU) lookup of the
// claim text against the operator's already-indexed luna vault. A strong hit
// (>= min-score) whose snippet echoes a claim-specific token corroborates the
// claim without spending a credit. Headless-callable from node via the same
// invoker scripts/lib/qmd-bin.sh resolves (bun + the global qmd.js, else a
// `qmd` on PATH). Default OFF — gated on FOLLOW_WEB_QMD so the rung stays dark
// unless the operator opts in (mirrors the firecrawl default-off posture).
// ---------------------------------------------------------------------------

// Resolve the qmd invoker the same way scripts/lib/qmd-bin.sh does: prefer the
// canonical bun-global qmd.js (the plugin-cache stub shadows the bun shim on
// Git-Bash $PATH under Claude's Bash tool), else fall back to `qmd` on PATH.
function qmdInvoker(env) {
  const bunRoot = env.BUN_INSTALL || join(homedir(), ".bun");
  const bunQmd = join(bunRoot, "install", "global", "node_modules", "@tobilu", "qmd", "dist", "cli", "qmd.js");
  if (existsSync(bunQmd)) return { file: "bun", pre: [bunQmd] };
  return { file: "qmd", pre: [] };
}

/**
 * Build a qmd-backed `webFn(query) -> {found,url,title,snippet}`. Returns null
 * unless `FOLLOW_WEB_QMD` is set (default OFF). Budget-capped: after `budget`
 * lookups it returns `{found:false}` without spawning. Any spawn/parse failure
 * resolves to `{found:false}` (never throws). Maps the top `qmd search --json`
 * hit's `file`/`title`/`snippet` into the webFn contract; verifyWebClaims then
 * still requires a claim-specific token in that evidence before verifying.
 */
export function makeQmdWebFn(env = process.env) {
  if (!env.FOLLOW_WEB_QMD) return null;
  const collection = (env.FOLLOW_WEB_QMD_COLLECTION || "").trim() || QMD_DEFAULT_COLLECTION;
  const minScore = parseFloat(env.FOLLOW_WEB_QMD_MIN_SCORE || "") || QMD_DEFAULT_MIN_SCORE;
  let remaining = parseInt(env.FOLLOW_WEB_QMD_BUDGET || "", 10) || QMD_DEFAULT_BUDGET;
  const inv = qmdInvoker(env);

  return function qmdWebFn(query) {
    if (remaining <= 0) return { found: false };
    remaining -= 1;
    try {
      const res = spawnSync(
        inv.file,
        [...inv.pre, "search", query, "--json", "-c", collection, "--min-score", String(minScore), "-n", "1"],
        { encoding: "utf8", timeout: QMD_TIMEOUT_MS, maxBuffer: 8 * 1024 * 1024 },
      );
      if (res.error || res.status !== 0 || !res.stdout) return { found: false };
      const arr = JSON.parse(res.stdout);
      const top = Array.isArray(arr) ? arr[0] : null;
      if (!top || !top.file) return { found: false };
      return { found: true, url: top.file, title: top.title || "", snippet: top.snippet || "" };
    } catch {
      return { found: false }; // spawn/parse failure — grounded no-op
    }
  };
}

// ---------------------------------------------------------------------------
// Concrete backends: external prompt-in/JSON-out CLIs (generalized adapter +
// hermes). Both ask a general LLM/agent CLI to web-verify the claim and reply
// with a strict JSON object; the reply is parsed defensively (first balanced
// JSON object; any parse failure -> {found:false}, never throws). Default OFF,
// budget-capped like firecrawl.
// ---------------------------------------------------------------------------

// Extract the first balanced top-level JSON object from free-form text (a CLI
// may wrap the object in prose/markdown fences). String-aware so a brace inside
// a quoted value doesn't end the object. Returns null if none.
function extractJsonObject(text) {
  const s = String(text || "");
  const start = s.indexOf("{");
  if (start === -1) return null;
  let depth = 0, inStr = false, esc = false;
  for (let i = start; i < s.length; i += 1) {
    const ch = s[i];
    if (esc) { esc = false; continue; }
    if (ch === "\\") { esc = true; continue; }
    if (ch === '"') { inStr = !inStr; continue; }
    if (inStr) continue;
    if (ch === "{") depth += 1;
    else if (ch === "}") { depth -= 1; if (depth === 0) return s.slice(start, i + 1); }
  }
  return null;
}

// Strict-JSON web-fact-check prompt shared by both CLI adapters — asks a general
// LLM/agent CLI to verify ONE claim and reply with a single {found,url,title,
// snippet} object (the same prompt the retired gemini adapter used).
function webFactCheckPrompt(query) {
  return (
    "You are a web fact-checker. Search the web to verify this claim about a " +
    "person or online account. Reply with ONLY a single JSON object and nothing " +
    'else, exactly this shape: {"found":boolean,"url":string,"title":string,"snippet":string}. ' +
    'Set "found" true ONLY if a real web page corroborates the claim; otherwise ' +
    'false with empty strings. Claim: ' + query
  );
}

// Parse a spawned CLI/agent's stdout into the webFn contract: first balanced
// JSON object, require `found:true`, else `{found:false}`. Never throws.
function parseWebFactStdout(stdout) {
  const objText = extractJsonObject(stdout);
  if (!objText) return { found: false };
  let parsed;
  try {
    parsed = JSON.parse(objText);
  } catch {
    return { found: false }; // non-JSON reply — grounded no-op
  }
  if (!parsed || !parsed.found) return { found: false };
  return { found: true, url: parsed.url || "", title: parsed.title || "", snippet: parsed.snippet || "" };
}

/**
 * Build a generalized external-CLI-backed `webFn(query) -> {found,url,title,
 * snippet}`. This is the Antigravity rung: the operator sets FOLLOW_WEB_CLI to
 * the command (e.g. `agy` or an absolute path) and FOLLOW_WEB_CLI_ARGS to
 * whatever flags run one headless prompt; the prompt is passed as the LAST arg.
 * Returns null unless FOLLOW_WEB_CLI is set (default OFF). Budget-capped: after
 * `budget` calls it returns `{found:false}` without spawning. Any spawn error /
 * nonzero status / non-JSON reply resolves to `{found:false}` (never throws).
 * verifyWebClaims still requires a claim-specific token in the returned evidence.
 */
export function makeCliWebFn(env = process.env) {
  const cmd = (env.FOLLOW_WEB_CLI || "").trim();
  if (!cmd) return null;
  const extra = (env.FOLLOW_WEB_CLI_ARGS || "").trim();
  const preArgs = extra ? extra.split(/\s+/) : [];
  let remaining = parseInt(env.FOLLOW_WEB_CLI_BUDGET || "", 10) || CLI_DEFAULT_BUDGET;
  const timeout = parseInt(env.FOLLOW_WEB_CLI_TIMEOUT_MS || "", 10) || CLI_DEFAULT_TIMEOUT_MS;

  return function cliWebFn(query) {
    if (remaining <= 0) return { found: false };
    remaining -= 1;
    try {
      const res = spawnSync(cmd, [...preArgs, webFactCheckPrompt(query)], {
        encoding: "utf8",
        timeout,
        maxBuffer: 8 * 1024 * 1024,
      });
      if (res.error || res.status !== 0 || !res.stdout) return { found: false };
      return parseWebFactStdout(res.stdout);
    } catch {
      return { found: false }; // spawn failure — grounded no-op
    }
  };
}

/**
 * Build a hermes-backed `webFn(query) -> {found,url,title,snippet}` via the
 * repo's multi-provider chokepoint scripts/hermes/invoke.sh. Returns null unless
 * FOLLOW_WEB_HERMES is truthy (default OFF — an unconfigured run never fans
 * hermes calls). The default `todo` toolset has NO network, so the run passes a
 * web-search toolset (FOLLOW_WEB_HERMES_TOOLSET, default "web"). Budget-capped;
 * any spawn/parse failure resolves to `{found:false}` (never throws).
 */
export function makeHermesWebFn(env = process.env) {
  if (!env.FOLLOW_WEB_HERMES) return null;
  const scriptPath = fileURLToPath(new URL("../../../../../scripts/hermes/invoke.sh", import.meta.url));
  const toolset = (env.FOLLOW_WEB_HERMES_TOOLSET || "").trim() || HERMES_DEFAULT_TOOLSET;
  const model = (env.FOLLOW_WEB_HERMES_MODEL || "").trim();
  let remaining = parseInt(env.FOLLOW_WEB_HERMES_BUDGET || "", 10) || HERMES_DEFAULT_BUDGET;
  const timeout = parseInt(env.FOLLOW_WEB_HERMES_TIMEOUT_MS || "", 10) || HERMES_DEFAULT_TIMEOUT_MS;

  return function hermesWebFn(query) {
    if (remaining <= 0) return { found: false };
    remaining -= 1;
    const args = [scriptPath, "--toolsets", toolset];
    if (model) args.push("--model", model);
    args.push(webFactCheckPrompt(query));
    try {
      const res = spawnSync("bash", args, { encoding: "utf8", timeout, maxBuffer: 8 * 1024 * 1024 });
      if (res.error || res.status !== 0 || !res.stdout) return { found: false };
      return parseWebFactStdout(res.stdout);
    } catch {
      return { found: false }; // spawn failure — grounded no-op
    }
  };
}

// ---------------------------------------------------------------------------
// Hermetic fixture seam (mirrors follow-list-score.mjs's FOLLOW_ACCOUNT_FIXTURE).
// ---------------------------------------------------------------------------

// Read a FOLLOW_*_FIXTURE env var: value is a path to a JSON file OR the JSON
// inline. Returns raw text, or null when unset/empty. (Copy of the resolver
// in follow-list-score.mjs — kept local so this module owns its own seam.)
function readFixtureEnv(name, env) {
  const raw = env[name];
  if (raw == null || raw === "") return null;
  try {
    if (existsSync(raw)) return readFileSync(raw, "utf8");
  } catch {
    // not a path -- treat the value as inline JSON
  }
  return raw;
}

/**
 * Build a webFn from a FOLLOW_WEB_FIXTURE JSON map (query -> result object).
 * `raw` is the JSON text (map of exact query string -> {found,url,title,
 * snippet}). An unknown query resolves to `{found:false}` (a miss, not an
 * error) so a fixture only needs the queries a test cares about.
 */
export function makeFixtureWebFn(raw) {
  const map = JSON.parse(raw);
  return (query) => (query in map ? map[query] : { found: false });
}

/**
 * Resolve the webFn the CLI should use, fixture-first, then a FREE-FIRST
 * fallback chain (mirrors follow-list-score.mjs's makeFetchFn precedence):
 *   FOLLOW_WEB_FIXTURE set -> hermetic fixture-backed webFn (tests/CI).
 *   else -> chainWebFns of the enabled backends, tried in order:
 *     1. qmd    (FREE local vault BM25)     — gated on FOLLOW_WEB_QMD
 *     2. cli    (external prompt-in/JSON CLI) — gated on FOLLOW_WEB_CLI
 *     3. hermes (multi-provider agent)       — gated on FOLLOW_WEB_HERMES
 *     4. firecrawl (metered, LAST)           — gated on FIRECRAWL_API_KEY
 *   Each backend is independently budget-capped; the chain returns the first
 *   `{found:true}` and only reaches firecrawl when the free rungs miss.
 *   If NO backend is enabled -> null (web rung OFF; verifyWebClaims no-ops).
 * The parent passes the result straight to verifyWebClaims(dossier,{webFn}).
 */
export function makeWebFn(env = process.env) {
  const fixtureRaw = readFixtureEnv("FOLLOW_WEB_FIXTURE", env);
  if (fixtureRaw != null) return makeFixtureWebFn(fixtureRaw);

  const apiKey = (env.FIRECRAWL_API_KEY || "").trim();
  const baseUrl = (env.FIRECRAWL_BASE_URL || "").trim() || undefined;
  const fcBudget = parseInt(env.FOLLOW_WEB_BUDGET || "", 10) || FIRECRAWL_DEFAULT_BUDGET;

  const chain = [
    makeQmdWebFn(env),
    makeCliWebFn(env),
    makeHermesWebFn(env),
    makeFirecrawlWebFn({ apiKey, baseUrl, budget: fcBudget }),
  ].filter(Boolean);

  if (chain.length === 0) return null;
  return chainWebFns(chain);
}

// ---------------------------------------------------------------------------
// STUB adapter — Agent Reach.
//
// Survey (HIMMEL-660 Phase 2): does not expose a callable, structured
// web-search interface today, so it is not wired. Left as a documented stub
// (return null = "unavailable") so the parent can drop in a real adapter
// if/when the interface materializes, without touching the seam.
//
// AGENT REACH — NOT a general web-search backend. In this repo "Agent Reach"
//   is the X reply-thread capture backend (public-clis/twitter-cli, registry
//   entry `docs/tool-adoption/registry.md` line ~80: "twitter tweet <id>
//   --json"). It is X-specific (auth = burner TWITTER_AUTH_TOKEN/TWITTER_CT0
//   cookies), owned by the fxtwitter/X path — not an open-web search/fetch
//   API. There is no `channels/` registry in the repo (the LUNA-92 routing
//   layer is a proposal, unbuilt). So there is nothing to call for generic
//   web verification. If a general Agent-Reach web channel ships, wire it
//   here to return {found,url,title,snippet}.
export function makeAgentReachWebFn() {
  return null; // unavailable — see comment above
}
