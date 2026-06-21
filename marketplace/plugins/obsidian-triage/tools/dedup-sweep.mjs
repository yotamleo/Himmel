#!/usr/bin/env node
/**
 * dedup-sweep.mjs — LUNA-37 dedup sweep across a luna-style Clippings/ vault.
 *
 * Two phases:
 *
 *   Phase 1 (url): group every clip by canonical source URL. Each group of ≥2
 *     clips picks the oldest by `date_clipped:` (or filename timestamp fallback)
 *     as canonical. All other clips in the group are marked dupes pointing at
 *     the canonical clip's wikilink.
 *
 *   Phase 2 (content): for each `processed: true` clip NOT already in a URL
 *     cluster, normalise the body (lowercase, strip whitespace + image lines +
 *     empty wikilinks + template-scaffold headers) and SHA256 it. Groups of ≥2
 *     produce a content-dedup cluster, same canonical pick + same marking
 *     pattern with `content_dedup_target:` and `harvest_status: content_dedup`.
 *
 * Frontmatter writes only — body is never touched (G-3 body-identity).
 * Canonical clips get a `re_clipped_by:` block-list pointing at every dupe.
 *
 * Idempotent: re-runs skip already-marked dupes/canonicals.
 *
 * Usage:
 *   bun dedup-sweep.mjs --vault <path> [--phase url|content|all] [--dry-run] [--report-only]
 *
 * Exit codes:
 *   0 — sweep completed
 *   1 — bad usage / missing vault
 *
 * LUNA-37.
 */
import { existsSync, readFileSync, writeFileSync, readdirSync, statSync, mkdirSync } from "node:fs";
import { join, relative, sep, basename } from "node:path";
import { createHash } from "node:crypto";
import { fileURLToPath, pathToFileURL } from "node:url";
import { canonicalize, unquote } from "./lib/url-canonical.mjs";
import { clipUrlKeys } from "./lib/clip-lookup.mjs";

const TODAY = process.env.DEDUP_TODAY || new Date().toISOString().slice(0, 10);

// Min normalised-body length before a clip becomes eligible for content-hash
// dedup. Scaffold-only / empty clips normalise to <50b and would hash-collide
// spuriously. Tunable via DEDUP_MIN_CONTENT_BYTES.
const CONTENT_MIN_BYTES = parseInt(process.env.DEDUP_MIN_CONTENT_BYTES || "200", 10);

function usage(code = 1) {
  const out = code === 0 ? console.log : console.error;
  out("Usage: dedup-sweep.mjs --vault <path> [--phase url|content|all] [--dry-run] [--report-only]");
  out("");
  out("LUNA-37 dedup sweep. URL-canonical + content-hash detection.");
  out("--report-only writes 60-Maps/dedup-clusters-<DATE>.md without mutating clips.");
  out("--dry-run prints what would change without writing anything.");
  process.exit(code);
}

function parseArgs(argv) {
  const out = { vault: null, phase: "all", dryRun: false, reportOnly: false };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--vault") out.vault = argv[++i];
    else if (a === "--phase") out.phase = argv[++i] || "all";
    else if (a === "--dry-run") out.dryRun = true;
    else if (a === "--report-only") out.reportOnly = true;
    else if (a === "-h" || a === "--help") usage(0);
    else {
      console.error(`unknown arg: ${a}`);
      usage(1);
    }
  }
  if (!out.vault) usage(1);
  if (!["url", "content", "all"].includes(out.phase)) {
    console.error(`bad --phase value: ${out.phase}`);
    usage(1);
  }
  return out;
}

function sha256(s) {
  return createHash("sha256").update(s).digest("hex");
}

function findClips(vault) {
  const root = join(vault, "Clippings");
  if (!existsSync(root)) return [];
  const out = [];
  for (const e of readdirSync(root, { withFileTypes: true })) {
    if (e.isFile() && e.name.endsWith(".md")) {
      out.push(join(root, e.name));
    } else if (e.isDirectory()) {
      const sub = join(root, e.name);
      try {
        for (const s of readdirSync(sub, { withFileTypes: true })) {
          if (s.isFile() && s.name.endsWith(".md")) out.push(join(sub, s.name));
        }
      } catch {}
    }
  }
  return out.sort();
}

/**
 * Parse frontmatter (CRLF-normalised, minimal YAML-ish top-level only).
 * Mirrors the parser in playwright-crawl-x.mjs / fxtwitter-enrich.mjs.
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

/**
 * Extract the clip's date for canonical-pick ordering.
 * Order of preference:
 *   1. frontmatter `date_clipped:` (date or full ISO timestamp)
 *   2. filename ISO-ish timestamp (handles `@user – 2026-05-25T024356+0200.md`)
 *   3. mtime fallback (last resort — pulls newest, so flagged as fallback)
 *
 * Returns a string that compares lexicographically (`YYYY-MM-DDTHH:MM:SS+0200`).
 */
function extractClipDate(path, fm) {
  const dc = unquote(fm.date_clipped || "");
  if (dc) return dc;
  const fname = basename(path, ".md");
  // Match `– 2026-05-25T024356+0200` or `– 2026-05-25` style suffixes.
  const m = fname.match(/(\d{4}-\d{2}-\d{2}(?:T\d{6}(?:[+-]\d{4})?)?)/);
  if (m) return m[1];
  try {
    return statSync(path).mtime.toISOString();
  } catch {
    return "9999-99-99"; // sort to bottom — won't be picked as canonical
  }
}

/**
 * Normalise body for content-hash dedup. Strips noise that wouldn't make
 * two clips meaningfully different:
 *   - lowercased
 *   - collapsed whitespace
 *   - image markdown lines dropped (`![...](...)` standalone)
 *   - empty wikilinks (`[[]]`)
 *   - operator-template scaffolding headers (NOT the operator-filled bodies):
 *       `## Why I Saved This`, `## How I Can Use This`, `## Related Notes`,
 *       `## Source` headers themselves get stripped (the headers vary across
 *       templates; the operator content under them is what we hash).
 *
 * Returns the normalised string (used as input to sha256()).
 */
function normaliseBodyForHash(body) {
  let b = body.replace(/\r\n/g, "\n");
  // Drop standalone image lines.
  b = b.replace(/^!\[[^\]]*\]\([^)]*\)\s*$/gm, "");
  // Drop empty wikilinks.
  b = b.replace(/\[\[\s*\]\]/g, "");
  // Drop the scaffold-only H2 headers (their content stays — only the
  // header tokens are noise. If two clips have the same operator-written
  // notes under different template-header text, we still want the hash
  // to match).
  const scaffoldHeaders = [
    /^##\s+Why I Saved This\s*$/gim,
    /^##\s+How I Can Use This\s*$/gim,
    /^##\s+Related Notes\s*$/gim,
    /^##\s+Source\s*$/gim,
    /^##\s+Comments\s*$/gim,
    /^##\s+The Idea\s*$/gim,
    /^##\s+Highlights\s*$/gim,
    /^##\s+Summary\s*$/gim,
    /^##\s+Key Points\s*$/gim,
    /^##\s+Crawled content\s*$/gim,
    /^##\s+Harvested content\s*$/gim,
  ];
  for (const re of scaffoldHeaders) b = b.replace(re, "");
  // Drop the operator's template-italic placeholder bodies (e.g.
  // "*(What is the single biggest claim this article is making?)*").
  b = b.replace(/^\s*\*\([^)]*\)\*\s*$/gm, "");
  // Drop the harvest comment markers.
  b = b.replace(/<!--\s*[^>]*-->/g, "");
  // Collapse all whitespace runs to a single space.
  b = b.toLowerCase().replace(/\s+/g, " ").trim();
  return b;
}

/**
 * Wikilink path for a clip — `[[Clippings/<filename-without-ext>]]`.
 */
function wikilinkFor(clipPath, vault) {
  const rel = relative(vault, clipPath).split(sep).join("/");
  // Strip .md extension for the wikilink.
  const noExt = rel.replace(/\.md$/, "");
  return `[[${noExt}]]`;
}

/**
 * Detect existing dedup markers on a clip — used for idempotency.
 * Returns "url" | "content" | "canonical" | null.
 *
 *   - url       : harvest_dedup_target present + harvest_status: dedup
 *   - content   : content_dedup_target present + harvest_status: content_dedup
 *   - canonical : re_clipped_by present (this clip is canonical for ≥1 dupe)
 */
function detectExistingState(fmRaw) {
  const hasUrlTarget = /^harvest_dedup_target:\s*\S/m.test(fmRaw);
  const hasContentTarget = /^content_dedup_target:\s*\S/m.test(fmRaw);
  const hasReClipped = /^re_clipped_by:/m.test(fmRaw);
  const statusMatch = fmRaw.match(/^harvest_status:\s*"?([^"\n]+)"?\s*$/m);
  const status = statusMatch ? statusMatch[1].trim() : "";
  if (hasUrlTarget && status === "dedup") return "url";
  if (hasContentTarget && status === "content_dedup") return "content";
  if (hasReClipped) return "canonical";
  return null;
}

/**
 * Upsert dupe-marking keys into a clip's frontmatter.
 *
 *   - `<target_key>`: wikilink to canonical clip (string)
 *   - `harvest_status`: replace existing value with `dedup` | `content_dedup`
 *   - `dedup_detected_at`: TODAY
 *
 * Idempotent: if all three keys already match, returns the input unchanged.
 */
function upsertDupeMarkers(fmRaw, { targetKey, targetWikilink, status }) {
  let lines = fmRaw.split("\n");
  const wantedTarget = `${targetKey}: "${targetWikilink}"`;
  const wantedStatus = `harvest_status: ${status}`;
  const wantedDetected = `dedup_detected_at: ${TODAY}`;

  const seen = { target: false, status: false, detected: false };
  lines = lines.map((line) => {
    if (line.match(new RegExp(`^${targetKey}:`))) {
      seen.target = true;
      return wantedTarget;
    }
    if (line.match(/^harvest_status:/)) {
      seen.status = true;
      return wantedStatus;
    }
    if (line.match(/^dedup_detected_at:/)) {
      seen.detected = true;
      return wantedDetected;
    }
    return line;
  });

  let insertIdx = lines.length;
  for (let i = lines.length - 1; i >= 0; i--) {
    if (lines[i].trim()) {
      insertIdx = i + 1;
      break;
    }
  }
  const toInsert = [];
  if (!seen.target) toInsert.push(wantedTarget);
  if (!seen.status) toInsert.push(wantedStatus);
  if (!seen.detected) toInsert.push(wantedDetected);
  return [...lines.slice(0, insertIdx), ...toInsert, ...lines.slice(insertIdx)].join("\n");
}

/**
 * Upsert `re_clipped_by:` block-list on the canonical clip.
 * Block-list style (matches `tags:` / `author:` in existing clips):
 *
 *   re_clipped_by:
 *     - "[[Clippings/dupe1]]"
 *     - "[[Clippings/dupe2]]"
 *
 * Idempotent: re-runs merge new entries, dedupe by exact string match.
 */
function upsertReClippedBy(fmRaw, wikilinks) {
  if (wikilinks.length === 0) return fmRaw;
  // Sort + dedupe input.
  const wanted = Array.from(new Set(wikilinks)).sort();

  const lines = fmRaw.split("\n");
  // Locate existing `re_clipped_by:` block.
  let blockStart = -1;
  let blockEnd = -1;
  for (let i = 0; i < lines.length; i++) {
    if (/^re_clipped_by:\s*$/.test(lines[i])) {
      blockStart = i;
      // Walk forward over the indented block-list children.
      let j = i + 1;
      while (j < lines.length && /^\s+-\s/.test(lines[j])) j++;
      blockEnd = j;
      break;
    }
  }

  const existing = new Set();
  if (blockStart >= 0) {
    for (let j = blockStart + 1; j < blockEnd; j++) {
      const m = lines[j].match(/^\s+-\s*"?([^"\n]+)"?\s*$/);
      if (m) existing.add(m[1].trim());
    }
  }
  for (const w of wanted) existing.add(w);
  const merged = Array.from(existing).sort();

  const block = ["re_clipped_by:", ...merged.map((w) => `  - "${w}"`)];

  if (blockStart >= 0) {
    // Replace existing block in place.
    return [...lines.slice(0, blockStart), ...block, ...lines.slice(blockEnd)].join("\n");
  }
  // Append at end of frontmatter (after last non-empty line).
  let insertIdx = lines.length;
  for (let i = lines.length - 1; i >= 0; i--) {
    if (lines[i].trim()) {
      insertIdx = i + 1;
      break;
    }
  }
  return [...lines.slice(0, insertIdx), ...block, ...lines.slice(insertIdx)].join("\n");
}

/**
 * Atomic clip mutation: read → mutate frontmatter → write → verify.
 * G-3 invariant: body MUST be byte-identical post-write.
 * Reverts on YAML parse failure or body drift.
 *
 * Returns { ok, changed, message }.
 */
async function writeClipFrontmatterAsync(clipPath, mutator, dryRun) {
  const text = readFileSync(clipPath, "utf-8");
  const { fmRaw, body, present } = parseFrontmatter(text);
  if (!present) return { ok: false, message: "no frontmatter" };
  const newFmRaw = mutator(fmRaw);
  if (newFmRaw === fmRaw) return { ok: true, message: "no-op (idempotent)", changed: false };
  const newText = `---\n${newFmRaw}\n---\n${body}`;
  if (dryRun) return { ok: true, message: "would write", changed: true };
  writeFileSync(clipPath, newText, { encoding: "utf-8" });
  const diskText = readFileSync(clipPath, "utf-8");
  const disk = parseFrontmatter(diskText);
  if (!disk.present) {
    writeFileSync(clipPath, text, { encoding: "utf-8" });
    return { ok: false, message: "G-3: post-write lost frontmatter; reverted" };
  }
  if (disk.body !== body) {
    writeFileSync(clipPath, text, { encoding: "utf-8" });
    return { ok: false, message: "G-3: post-write body differs; reverted" };
  }
  try {
    const yaml = await import("js-yaml");
    yaml.default.load(disk.fmRaw);
  } catch (e) {
    writeFileSync(clipPath, text, { encoding: "utf-8" });
    return { ok: false, message: `frontmatter-yaml-write: ${e.message}; reverted` };
  }
  return { ok: true, message: "wrote", changed: true };
}

/**
 * Index every clip: parse + extract canonical URL + body hash.
 * Returns { clips: [{path, fm, fmRaw, body, canonical, hash, date, state}, ...] }.
 */
function indexVault(vault) {
  const paths = findClips(vault);
  const clips = [];
  for (const p of paths) {
    let text;
    try {
      text = readFileSync(p, "utf-8");
    } catch {
      continue;
    }
    const { fm, fmRaw, body, present } = parseFrontmatter(text);
    if (!present) continue;
    const sourceVal = fm.harvest_url_canonical || fm.source || "";
    const canonical = clipUrlKeys(sourceVal).canon;
    const processed = (fm.processed || "").toLowerCase().replace(/^"|"$/g, "") === "true";
    const normalised = processed ? normaliseBodyForHash(body) : "";
    const hash = processed ? sha256(normalised) : null;
    const normalisedLen = normalised.length;
    const date = extractClipDate(p, fm);
    const state = detectExistingState(fmRaw);
    clips.push({ path: p, fm, fmRaw, body, canonical, hash, normalisedLen, date, state, processed });
  }
  return clips;
}

/**
 * Group clips by key. Returns Map<key, clips[]> with only ≥2-member groups.
 */
function groupBy(clips, keyFn) {
  const out = new Map();
  for (const c of clips) {
    const k = keyFn(c);
    if (!k) continue;
    if (!out.has(k)) out.set(k, []);
    out.get(k).push(c);
  }
  for (const [k, v] of [...out.entries()]) {
    if (v.length < 2) out.delete(k);
  }
  return out;
}

/**
 * Pick canonical clip from a group — oldest by date.
 * Tie-break: lexicographic path (deterministic).
 */
function pickCanonical(group) {
  return [...group].sort((a, b) => {
    if (a.date !== b.date) return a.date < b.date ? -1 : 1;
    return a.path < b.path ? -1 : 1;
  })[0];
}

async function runSweep(vault, opts) {
  const clips = indexVault(vault);
  console.log(`indexed ${clips.length} clips with frontmatter`);

  const urlClusters = [];
  const contentClusters = [];
  const inUrlCluster = new Set();

  // Phase 1 — URL canonical dedup.
  if (opts.phase === "url" || opts.phase === "all") {
    const groups = groupBy(clips, (c) => c.canonical);
    for (const [canonicalUrl, group] of groups) {
      const canonical = pickCanonical(group);
      const dupes = group.filter((c) => c !== canonical);
      urlClusters.push({ canonicalUrl, canonical, dupes, method: "url-canonical" });
      for (const c of group) inUrlCluster.add(c.path);
    }
    console.log(`url phase: ${urlClusters.length} clusters, ${urlClusters.reduce((s, c) => s + c.dupes.length, 0)} dupes`);
  }

  // Phase 2 — content-hash dedup, excluding clips already in URL clusters.
  // Min-content guard: clips that normalise to <CONTENT_MIN_BYTES of meaningful
  // text are scaffold-only / empty and would hash-collide spuriously. Skip them.
  if (opts.phase === "content" || opts.phase === "all") {
    const remaining = clips.filter(
      (c) =>
        c.processed &&
        c.hash &&
        c.normalisedLen >= CONTENT_MIN_BYTES &&
        !inUrlCluster.has(c.path),
    );
    const groups = groupBy(remaining, (c) => c.hash);
    for (const [hash, group] of groups) {
      const canonical = pickCanonical(group);
      const dupes = group.filter((c) => c !== canonical);
      contentClusters.push({ hash, canonical, dupes, method: "content-hash" });
    }
    console.log(`content phase: ${contentClusters.length} clusters, ${contentClusters.reduce((s, c) => s + c.dupes.length, 0)} dupes`);
  }

  // Apply mutations (unless --report-only).
  let writes = 0;
  let skips = 0;
  let errors = 0;
  let preserved = 0;
  if (!opts.reportOnly) {
    for (const cluster of [...urlClusters, ...contentClusters]) {
      const targetKey = cluster.method === "url-canonical" ? "harvest_dedup_target" : "content_dedup_target";
      const status = cluster.method === "url-canonical" ? "dedup" : "content_dedup";
      const canonicalLink = wikilinkFor(cluster.canonical.path, vault);
      // Mark each dupe.
      for (const dupe of cluster.dupes) {
        // Preserve existing operator-set dedup targets (wave-2 marked clips
        // point at 30-Resources/ synthesis notes — clip→resource linkage is
        // higher-fidelity than clip→clip; do NOT overwrite). The canonical's
        // re_clipped_by still records this dupe — reverse-index unaffected.
        if (dupe.state === "url" || dupe.state === "content") {
          preserved++;
          continue;
        }
        const r = await writeClipFrontmatterAsync(
          dupe.path,
          (fmRaw) => upsertDupeMarkers(fmRaw, { targetKey, targetWikilink: canonicalLink, status }),
          opts.dryRun,
        );
        if (!r.ok) {
          console.error(`  FAIL ${relative(vault, dupe.path)}: ${r.message}`);
          errors++;
        } else if (r.changed) {
          writes++;
        } else {
          skips++;
        }
      }
      // Update canonical's re_clipped_by list.
      const dupeLinks = cluster.dupes.map((d) => wikilinkFor(d.path, vault));
      const r = await writeClipFrontmatterAsync(
        cluster.canonical.path,
        (fmRaw) => upsertReClippedBy(fmRaw, dupeLinks),
        opts.dryRun,
      );
      if (!r.ok) {
        console.error(`  FAIL ${relative(vault, cluster.canonical.path)}: ${r.message}`);
        errors++;
      } else if (r.changed) {
        writes++;
      } else {
        skips++;
      }
    }
  }

  // Phase 3 — optional cluster-report.
  if (opts.phase === "all" || opts.reportOnly) {
    writeClusterReport(vault, urlClusters, contentClusters, opts.dryRun);
  }

  console.log("");
  console.log(`Results: ${writes} writes, ${skips} idempotent-skips, ${preserved} preserved-existing, ${errors} errors. dryRun=${opts.dryRun}`);
  return { urlClusters, contentClusters, writes, errors, preserved };
}

function writeClusterReport(vault, urlClusters, contentClusters, dryRun) {
  const mapsDir = join(vault, "60-Maps");
  if (!existsSync(mapsDir)) {
    try {
      mkdirSync(mapsDir, { recursive: true });
    } catch {
      // operator vault may not have 60-Maps/; skip cluster report
      console.log(`(60-Maps/ missing — skipping cluster report)`);
      return;
    }
  }
  const outPath = join(mapsDir, `dedup-clusters-${TODAY}.md`);
  const totalUrlDupes = urlClusters.reduce((s, c) => s + c.dupes.length, 0);
  const totalContentDupes = contentClusters.reduce((s, c) => s + c.dupes.length, 0);
  const lines = [
    "---",
    `title: "Dedup clusters — ${TODAY}"`,
    "type: map",
    `date: ${TODAY}`,
    "tags:",
    "  - luna-37",
    "  - dedup",
    "---",
    "",
    `# Dedup clusters — ${TODAY}`,
    "",
    "_Auto-generated by `dedup-sweep.mjs` (LUNA-37). Each cluster lists the",
    "canonical clip plus all dupes pointing at it. Detection method noted per",
    "cluster._",
    "",
    "## Summary",
    "",
    `- URL-canonical clusters: **${urlClusters.length}** (${totalUrlDupes} dupes)`,
    `- Content-hash clusters: **${contentClusters.length}** (${totalContentDupes} dupes)`,
    `- Total clusters: **${urlClusters.length + contentClusters.length}**`,
    `- Total dupes: **${totalUrlDupes + totalContentDupes}**`,
    "",
  ];
  if (urlClusters.length) {
    lines.push("## URL-canonical clusters", "");
    for (const c of urlClusters) {
      lines.push(`### \`${c.canonicalUrl}\``, "");
      lines.push(`- **canonical**: ${wikilinkFor(c.canonical.path, vault)} (${c.canonical.date})`);
      lines.push(`- **dupes** (${c.dupes.length}):`);
      for (const d of c.dupes) {
        lines.push(`  - ${wikilinkFor(d.path, vault)} (${d.date})`);
      }
      lines.push("");
    }
  }
  if (contentClusters.length) {
    lines.push("## Content-hash clusters", "");
    for (const c of contentClusters) {
      lines.push(`### \`hash:${c.hash.slice(0, 12)}…\``, "");
      lines.push(`- **canonical**: ${wikilinkFor(c.canonical.path, vault)} (${c.canonical.date})`);
      lines.push(`- **dupes** (${c.dupes.length}):`);
      for (const d of c.dupes) {
        lines.push(`  - ${wikilinkFor(d.path, vault)} (${d.date})`);
      }
      lines.push("");
    }
  }
  const out = lines.join("\n") + "\n";
  if (dryRun) {
    console.log(`(dry-run) would write ${outPath} (${out.length} bytes)`);
    return;
  }
  writeFileSync(outPath, out, { encoding: "utf-8" });
  console.log(`wrote cluster report: ${outPath}`);
}

// Run iff invoked as the main module (compatible with bun + node, and
// importable from tests without side effects).
const __thisFile = fileURLToPath(import.meta.url);
const __invokedAs = process.argv[1] ? process.argv[1] : "";
function isMain() {
  if (!__invokedAs) return false;
  try {
    return pathToFileURL(__invokedAs).href === import.meta.url;
  } catch {
    return __thisFile === __invokedAs;
  }
}

if (isMain()) {
  const opts = parseArgs(process.argv);
  if (!existsSync(opts.vault)) {
    console.error(`vault not found: ${opts.vault}`);
    process.exit(1);
  }
  runSweep(opts.vault, opts).then((r) => {
    process.exit(r.errors > 0 ? 4 : 0);
  });
}

// Test-only exports.
export {
  canonicalize,
  parseFrontmatter,
  normaliseBodyForHash,
  extractClipDate,
  wikilinkFor,
  detectExistingState,
  upsertDupeMarkers,
  upsertReClippedBy,
  indexVault,
  runSweep,
  pickCanonical,
  groupBy,
};
