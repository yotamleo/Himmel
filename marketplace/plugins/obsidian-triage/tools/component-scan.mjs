#!/usr/bin/env node
/**
 * component-scan.mjs — LUNA-57 deep repo component-scan for luna-ingest --deep.
 *
 * Scans ONE github repo via gh-API (recursive git tree + raw file reads; NO
 * clone — bounded read surface per the LUNA-43 safety note) and inventories
 * its reusable components (skills / commands / agents / tools / plugin
 * manifests). Emits a JSON inventory on stdout and, in write mode, upserts
 * cross-repo-deduped notes into <vault>/<components-dir>/<type>/<slug>.md.
 *
 * Vault writes mirror dedup-sweep.mjs: on existing notes, appends to the
 * `seen_in:` frontmatter block AND the `## Seen in` body list (every other
 * section byte-identical), js-yaml parse-validate, revert-on-failure,
 * idempotent re-runs, and a resolve()-based vault-containment check (rejects
 * `..` traversal in --components-dir; does not resolve symlinks).
 *
 * Usage:
 *   bun component-scan.mjs --repo <owner/repo> [--vault <path>]
 *       [--components-dir <rel>] [--trust-tier <tier>] [--safety-flag <term>]
 *       [--max-components <N>] [--emit json|none] [--dry-run]
 *
 * Exit codes:
 *   0 — scan completed (+ writes, unless --dry-run / no --vault)
 *   1 — bad usage / missing required arg
 *   2 — env unusable (vault missing, gh unreachable, path-safety violation,
 *       js-yaml not installed, or wholesale fetch failure — nothing succeeded)
 *   4 — partial — ≥1 component file failed to fetch/parse, OR ≥1 note write
 *       failed YAML-validation and was reverted
 *
 * LUNA-57.
 */
import { existsSync, readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { resolve, relative, dirname } from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";
import {
  classifyPath, extractComponent, componentKey, componentSlug,
  componentIdentity, normalizeComponentPath,
  selectComponentPaths, parseFrontmatterFields,
} from "./lib/component-extract.mjs";

/** Canonical trust-tier vocabulary (must match the SKILL's 5-tier enum). */
const CANONICAL_TRUST_TIERS = [
  "unknown-risk", "community-thin", "community-active",
  "known-author", "anthropic-official",
];

const TODAY = process.env.COMPONENT_SCAN_TODAY || new Date().toISOString().slice(0, 10);
const NOW_ISO = process.env.COMPONENT_SCAN_NOW || new Date().toISOString();
const DEFAULT_MAX = parseInt(process.env.COMPONENT_SCAN_MAX || "60", 10);

// Most-cautious → least-cautious. Lower rank = more cautious. Unknown /
// unrecognised tier strings sort as most-cautious (fail-safe), at the same
// rank as the most-cautious *named* tier `unknown-risk`.
const TRUST_TIER_RANK = {
  "unknown-risk": 0,
  "community-thin": 1,
  "community-active": 2,
  "known-author": 3,
  "anthropic-official": 4,
};
const MOST_CAUTIOUS_RANK = 0;

/** Rank of a tier; unrecognised strings → most-cautious rank (fail-safe). */
function trustTierRank(t) {
  const r = TRUST_TIER_RANK[t];
  return r === undefined ? MOST_CAUTIOUS_RANK : r;
}

/**
 * Return the more-cautious (lower-rank) of two trust tiers. On a rank tie,
 * prefer a recognised label over an unrecognised string (so an arbitrary
 * unknown value never shadows the canonical `unknown-risk`); failing that,
 * keep `a` (first-wins).
 */
function escalateTrustTier(a, b) {
  const ra = trustTierRank(a), rb = trustTierRank(b);
  if (rb < ra) return b;
  if (ra < rb) return a;
  // tie: prefer the recognised label
  const aKnown = a in TRUST_TIER_RANK, bKnown = b in TRUST_TIER_RANK;
  if (bKnown && !aKnown) return b;
  return a;
}

function usage(code = 1) {
  const out = code === 0 ? console.log : console.error;
  out("Usage: component-scan.mjs --repo <owner/repo> [--vault <path>] [--components-dir <rel>]");
  out("       [--trust-tier <tier>] [--safety-flag <term>] [--max-components <N>] [--emit json|none] [--dry-run]");
  out("");
  out("LUNA-57 deep repo component-scan. gh-API only, no clone.");
  process.exit(code);
}

function parseArgs(argv) {
  const out = {
    repo: null, vault: null, componentsDir: "30-Resources/Components",
    trustTier: "", safetyFlag: "", maxComponents: DEFAULT_MAX,
    emit: "json", dryRun: false,
  };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--repo") out.repo = argv[++i];
    else if (a === "--vault") out.vault = argv[++i];
    else if (a === "--components-dir") out.componentsDir = argv[++i];
    else if (a === "--trust-tier") out.trustTier = argv[++i] || "";
    else if (a === "--safety-flag") out.safetyFlag = argv[++i] || "";
    else if (a === "--max-components") out.maxComponents = parseInt(argv[++i], 10);
    else if (a === "--emit") out.emit = argv[++i] || "json";
    else if (a === "--dry-run") out.dryRun = true;
    else if (a === "-h" || a === "--help") usage(0);
    else { console.error(`unknown arg: ${a}`); usage(1); }
  }
  if (!out.repo) usage(1);
  if (!/^[A-Za-z0-9_-][A-Za-z0-9_.-]*\/[A-Za-z0-9_-][A-Za-z0-9_.-]*$/.test(out.repo)) {
    console.error(`bad --repo (want <owner/repo>): ${out.repo}`); usage(1);
  }
  if (!["json", "none"].includes(out.emit)) { console.error(`bad --emit: ${out.emit}`); usage(1); }
  if (!Number.isFinite(out.maxComponents) || out.maxComponents < 1) out.maxComponents = DEFAULT_MAX;
  if (out.trustTier && !CANONICAL_TRUST_TIERS.includes(out.trustTier)) {
    console.error(`unrecognised trust-tier '${out.trustTier}', treating as most-cautious`);
  }
  return out;
}

/** Capture stdout of a gh invocation. Throws on non-zero exit. */
function ghCapture(args) {
  return execFileSync("gh", args, { encoding: "utf-8", maxBuffer: 32 * 1024 * 1024 });
}

/** Fetch the repo default branch + recursive tree blob paths. */
function fetchTree(repo) {
  const meta = JSON.parse(ghCapture(["api", `repos/${repo}`, "--jq", "{default_branch}"]));
  const branch = meta.default_branch;
  const raw = ghCapture([
    "api", `repos/${repo}/git/trees/${branch}?recursive=1`,
    "--jq", '.tree[] | select(.type=="blob") | .path',
  ]);
  return { branch, paths: raw.split("\n").filter(Boolean) };
}

/**
 * Fetch + base64-decode one file's content. Returns a tagged result:
 *   { kind: "ok", content }              — decoded non-empty content
 *   { kind: "skip", reason }             — file genuinely gone (404 / Not Found)
 *   { kind: "fail", reason }             — transient/auth (403/429/5xx) or
 *                                          empty content (blob >1MB)
 * Never throws.
 */
function fetchFile(repo, branch, path) {
  let b64;
  try {
    b64 = ghCapture([
      "api", `repos/${repo}/contents/${path}?ref=${branch}`, "--jq", ".content",
    ]);
  } catch (e) {
    const msg = String(e && e.message || e).split("\n")[0].trim();
    // 404 / "Not Found" → file genuinely gone (a skip, not a hard failure).
    if (/\b404\b|not found/i.test(msg)) return { kind: "skip", reason: msg };
    return { kind: "fail", reason: msg };
  }
  const content = Buffer.from(b64.replace(/\n/g, ""), "base64").toString("utf-8");
  // GitHub contents API returns empty `content` for blobs >1MB — that is a
  // content-blind read, not a real empty component.
  if (content === "") return { kind: "fail", reason: "empty/>1MB" };
  return { kind: "ok", content };
}

/**
 * Scan one repo → component records. Each record:
 *   { name, type, description, path, repo, key, trust_tier, safety_flag }
 * Returns { records, scanned, skipped, failures, branch }. Emits one stderr
 * line per fetch failure/skip naming the path + first line of the gh error.
 */
function scanRepo(repo, opts) {
  const { branch, paths } = fetchTree(repo);
  const { selected, skipped: capSkipped } = selectComponentPaths(paths, { maxComponents: opts.maxComponents });
  const records = [];
  let failures = 0;
  let skipped = capSkipped;
  for (const { path, type } of selected) {
    const res = fetchFile(repo, branch, path);
    if (res.kind === "skip") {
      console.error(`fetch-skip ${path}: ${res.reason}`);
      skipped++;
      continue;
    }
    if (res.kind === "fail") {
      console.error(`fetch-fail ${path}: ${res.reason}`);
      failures++;
      continue;
    }
    const rec = extractComponent({ path, type, content: res.content });
    records.push({
      ...rec, repo, key: componentKey(rec),
      trust_tier: opts.trustTier, safety_flag: opts.safetyFlag,
    });
  }
  return { records, scanned: selected.length, skipped, failures, branch };
}

/**
 * Normalise a vault path that may be a POSIX-style Git-Bash path on Windows
 * (e.g. /c/Users/...) to a proper Windows absolute path so that Node's
 * path.resolve() works correctly. No-op on Linux/macOS.
 */
function normalizeVaultPath(p) {
  if (process.platform !== "win32") return p;
  // /c/... or /C/... → C:\...
  const m = String(p || "").match(/^\/([a-zA-Z])(\/.*)?$/);
  if (m) return `${m[1].toUpperCase()}:${(m[2] || "/").replace(/\//g, "\\")}`;
  return p;
}

/** Resolve + path-safety-check the note path for a component record. */
function notedPath(record, opts) {
  const vaultRoot = resolve(normalizeVaultPath(opts.vault));
  const target = resolve(vaultRoot, opts.componentsDir, record.type, `${componentSlug(componentIdentity(record))}.md`);
  const rel = relative(vaultRoot, target);
  if (rel.startsWith("..") || rel.includes("..")) {
    throw new Error(`path-safety: ${rel} escapes vault root`);
  }
  return target;
}

/**
 * Escape a value for a double-quoted YAML scalar: backslash FIRST, then the
 * double-quote (so tool descriptions containing `\d+` or `C:\path` survive).
 * Matches the fxtwitter-enrich.mjs convention.
 */
function yamlString(v) {
  return String(v).replace(/\\/g, "\\\\").replace(/"/g, '\\"');
}

/** Render a fresh component note. */
function renderNote(record) {
  const url = `https://github.com/${record.repo}`;
  const seenPath = normalizeComponentPath(record.path); // LUNA-63: canonical spelling
  return [
    "---",
    "type: component",
    `component_type: ${record.type}`,
    `name: "${yamlString(record.name)}"`,
    `component_key: ${record.key}`,
    `description: "${yamlString(record.description || "")}"`,
    "seen_in:",
    `  - "${record.repo}#${seenPath}"`,
    `trust_tier: "${yamlString(record.trust_tier || "unknown-risk")}"`,
    `safety_flag: "${yamlString(record.safety_flag || "")}"`,
    `ingested_at: ${NOW_ISO}`,
    `last_revalidated: ${NOW_ISO}`,
    "---",
    "",
    `# ${record.name} (${record.type})`,
    "",
    record.description || "_(no description found in source)_",
    "",
    "## Reuse for himmel/luna",
    "",
    `_Candidate ${record.type} from [${record.repo}](${url}). ${record.description || ""}_`,
    "_Refine this note with the concrete himmel/luna adaptation when the component is evaluated._",
    "",
    "## Seen in",
    "",
    `- [${record.repo}](${url}) — \`${seenPath}\``,
    "",
  ].join("\n");
}

/**
 * Resolve the js-yaml module once per run. Caches onto opts._yaml so the
 * per-note validate path never re-imports. Throws if js-yaml is not installed
 * (distinct from a note's own invalid frontmatter) — callers surface that as
 * an rc=2 env error.
 */
async function loadYaml(opts) {
  if (opts && opts._yaml) return opts._yaml;
  const mod = (await import("js-yaml")).default;
  if (opts) opts._yaml = mod;
  return mod;
}

/** Slice the `---`…`---` frontmatter block out of a rendered note. */
function frontmatterBlock(text) {
  return text.slice(4, text.indexOf("\n---", 4));
}

/**
 * Upsert a deduped Components/ note. New key → render fresh. Existing key →
 * append this repo to the `seen_in:` block + the `## Seen in` list (dedup by
 * exact string), frontmatter+body merge only, idempotent, js-yaml-validated,
 * revert-on-failure. Returns { ok, changed, message }.
 *
 * Both create and update validate the rendered frontmatter via js-yaml so a
 * malformed note can never land: create validates BEFORE writing; update
 * writes-then-validates-then-reverts.
 */
async function upsertComponentNote(record, opts) {
  const target = notedPath(record, opts); // throws on traversal
  const seenPath = normalizeComponentPath(record.path); // LUNA-63: canonical spelling
  const seenFmEntry = `${record.repo}#${seenPath}`;
  const url = `https://github.com/${record.repo}`;
  const seenListLine = `- [${record.repo}](${url}) — \`${seenPath}\``;
  const yaml = await loadYaml(opts);

  if (!existsSync(target)) {
    if (opts.dryRun) return { ok: true, changed: true, message: "would create" };
    const rendered = renderNote(record);
    // Validate BEFORE writing — a malformed fresh note must never land.
    try {
      yaml.load(frontmatterBlock(rendered));
    } catch (e) {
      return { ok: false, changed: false, message: `frontmatter-yaml (create): ${e.message}; not written` };
    }
    mkdirSync(dirname(target), { recursive: true });
    writeFileSync(target, rendered, "utf-8");
    return { ok: true, changed: true, message: "created" };
  }

  const before = readFileSync(target, "utf-8");
  const seenExists = before.includes(`"${seenFmEntry}"`) || before.includes(seenListLine);

  // Cross-repo risk escalation (LUNA-57 I1): a later repo sharing this
  // component_key must escalate the note's risk to the most-cautious value
  // across all contributing repos — first-create no longer owns the risk.
  const existingFm = parseFrontmatterFields(before);
  const existingFlag = existingFm.safety_flag || "";
  const incomingFlag = record.safety_flag || "";
  // Keep whichever flag is non-blank; if both non-blank and differ, keep
  // existing (first-flag-wins) — but never silently drop a flag.
  const newFlag = existingFlag || incomingFlag;
  // LUNA-63: validate the tier parsed back off disk — a hand-edited or
  // corrupted note may carry a non-canonical label; normalise it to the
  // most-cautious tier (unknown-risk) rather than persisting garbage or
  // letting it shadow a real tier during escalation.
  const rawExistingTier = existingFm.trust_tier || "";
  const existingTierOk = !rawExistingTier || CANONICAL_TRUST_TIERS.includes(rawExistingTier);
  if (!existingTierOk) {
    console.error(`tier-normalise ${target}: non-canonical '${rawExistingTier}' → unknown-risk`);
  }
  const existingTier = existingTierOk ? rawExistingTier : "unknown-risk";
  const incomingTier = record.trust_tier || "";
  // A newly-introduced flag forces unknown-risk; otherwise escalate to the
  // most-cautious of {existing, incoming} tier. If either side is blank, the
  // non-blank one stands (a missing tier carries no risk signal).
  const flagEscalated = !existingFlag && incomingFlag;
  let newTier;
  if (flagEscalated) newTier = "unknown-risk";
  else if (!existingTier) newTier = incomingTier;
  else if (!incomingTier) newTier = existingTier;
  else newTier = escalateTrustTier(existingTier, incomingTier);
  const flagChanged = newFlag !== existingFlag;
  // Compare against the RAW on-disk tier (not the normalised one) so a
  // non-canonical label parsed back off disk is actually rewritten. (LUNA-63)
  const tierChanged = newTier !== rawExistingTier;

  if (seenExists && !flagChanged && !tierChanged) {
    return { ok: true, changed: false, message: "no-op (idempotent)" };
  }

  // Insert the new seen_in fm entry after the `seen_in:` key (unless already
  // present), the list line after the `## Seen in` header block, and rewrite
  // the trust_tier / safety_flag frontmatter lines to the escalated values.
  const lines = before.replace(/\r\n/g, "\n").split("\n");
  const out = [];
  for (let i = 0; i < lines.length; i++) {
    if (tierChanged && /^trust_tier:\s/.test(lines[i])) {
      // Quote on the update path too, for create/update symmetry. (LUNA-63)
      out.push(`trust_tier: "${yamlString(newTier)}"`);
      continue;
    }
    if (flagChanged && /^safety_flag:\s?/.test(lines[i])) {
      out.push(`safety_flag: "${yamlString(newFlag)}"`);
      continue;
    }
    out.push(lines[i]);
    if (!seenExists && /^seen_in:\s*$/.test(lines[i])) out.push(`  - "${seenFmEntry}"`);
    if (!seenExists && /^## Seen in\s*$/.test(lines[i])) {
      out.push("");
      out.push(seenListLine);
      // skip following blank line if present (avoid double-blank)
      if (lines[i + 1] === "") i++;
    }
  }
  const after = out.join("\n");
  if (after === before) return { ok: true, changed: false, message: "no-op" };
  if (opts.dryRun) return { ok: true, changed: true, message: "would update seen_in" };

  writeFileSync(target, after, "utf-8");
  // YAML parse-validate the rewritten frontmatter; revert on failure. Scoped
  // to yaml.load() only — js-yaml-not-installed was already caught in loadYaml,
  // so a throw here unambiguously means this note's frontmatter is invalid.
  try {
    yaml.load(frontmatterBlock(after));
  } catch (e) {
    writeFileSync(target, before, "utf-8");
    return { ok: false, changed: false, message: `frontmatter-yaml: ${e.message}; reverted` };
  }
  return { ok: true, changed: true, message: "updated seen_in" };
}

/** Main: scan repo, optionally write notes, emit JSON inventory. */
async function mainEntryImpl(opts) {
  if (opts.vault) opts.vault = normalizeVaultPath(opts.vault);
  if (opts.vault && !existsSync(opts.vault)) {
    console.error(`vault not found: ${opts.vault}`); process.exit(2);
  }
  // Hoist js-yaml resolution once: a missing dep is an env error (rc=2),
  // distinct from a note's own invalid frontmatter (rc=4 via upsert revert).
  // Only needed when we actually write notes.
  if (opts.vault) {
    try { await loadYaml(opts); }
    catch { console.error("js-yaml not installed; run `bun install` in tools/"); process.exit(2); }
  }
  let scan;
  // Guards both the gh fetch AND extractComponent (which now throws on an
  // unknown type — LUNA-62); keep the label generic so a code/type bug is not
  // mis-framed as a network failure.
  try { scan = scanRepo(opts.repo, opts); }
  catch (e) { console.error(`scan failed: ${e.message}`); process.exit(2); }

  // Wholesale fetch failure (nothing succeeded) means the scan is
  // untrustworthy (rate-limit/auth), not merely partial → rc=2, not rc=4.
  if (scan.failures > 0 && scan.failures === scan.scanned) {
    console.error(`scan untrustworthy: all ${scan.scanned} component fetches failed (rate-limit/auth?)`);
    process.exit(2);
  }

  let writes = 0, skips = 0, errors = 0;
  if (opts.vault) {
    for (const rec of scan.records) {
      let r;
      try { r = await upsertComponentNote(rec, opts); }
      catch (e) { console.error(`path-safety: ${e.message}`); process.exit(2); }
      if (!r.ok) { console.error(`  FAIL ${rec.key}: ${r.message}`); errors++; }
      else if (r.changed) writes++; else skips++;
    }
  }

  if (opts.emit === "json") {
    // JSON contract: {
    //   repo: string, branch: string,
    //   counts: { scanned, skipped, failures, writes, idempotent_skips, errors },
    //   components: [{ name, type, key, path, description }],
    // }  (no schema_version field — intentionally unversioned)
    process.stdout.write(JSON.stringify({
      repo: opts.repo, branch: scan.branch,
      counts: {
        scanned: scan.scanned, skipped: scan.skipped, failures: scan.failures,
        writes, idempotent_skips: skips, errors,
      },
      components: scan.records.map((r) => ({
        name: r.name, type: r.type, key: r.key, path: r.path, description: r.description,
      })),
    }, null, 2) + "\n");
  }
  if (opts.emit !== "json") {
    console.error(`scanned ${scan.scanned}, skipped ${scan.skipped}, failures ${scan.failures}, writes ${writes}, skips ${skips}`);
  }
  process.exit(scan.failures > 0 || errors > 0 ? 4 : 0);
}

const __thisFile = fileURLToPath(import.meta.url);
const __invokedAs = process.argv[1] ? process.argv[1] : "";
function isMain() {
  if (!__invokedAs) return false;
  try { return pathToFileURL(__invokedAs).href === import.meta.url; }
  catch { return __thisFile === __invokedAs; }
}

function mainEntry(opts) {
  mainEntryImpl(opts).catch((e) => {
    console.error(`unexpected error: ${e.message}`);
    process.exit(2);
  });
}

if (isMain()) {
  const opts = parseArgs(process.argv);
  mainEntry(opts);
}

export { parseArgs, scanRepo, upsertComponentNote, renderNote, notedPath, escalateTrustTier };
