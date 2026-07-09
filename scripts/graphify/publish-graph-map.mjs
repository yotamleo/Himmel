#!/usr/bin/env node
// publish-graph-map.mjs — curate a graphify GRAPH_REPORT.md into a compact,
// tracked 60-Maps MOC note (HIMMEL-825/826).
//
// WHY: the raw GRAPH_REPORT.md is 3k+ lines / 150KB+ (one ### per community,
// 1500+ of them) — too big to track as an Obsidian note (git-diff noise every
// refresh, sluggish vault, over-chunked in qmd). The navigational VALUE lives
// in a few sections: Summary, God Nodes (core abstractions), Surprising
// Connections, and the largest named communities. This tool extracts exactly
// those into a small MOC that IS worth tracking — the full report + graph.json
// stay repo-local (gitignored, regenerable) as the "latest in repo" substrate;
// the MOC is what "moves" to 60-Maps on each update.
//
// Pure core: parseReport(text) + renderMoc(parsed, meta) are side-effect-free
// (unit-tested). main() does the fs IO.
//
// Usage:
//   publish-graph-map.mjs --report <GRAPH_REPORT.md> --out <60-Maps/note.md>
//       --title "<Name>" --slug <kebab-slug> [--corpus <tag>]
//       [--top-communities N] [--top-surprising N] [--source-graph <rel-path>]

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";

// ── pure parse ──────────────────────────────────────────────────────────────
// Split a GRAPH_REPORT.md into the sections we curate. Returns raw section
// bodies (trimmed) keyed by a stable name; missing sections → "".
export function parseReport(text) {
  const lines = text.split(/\r?\n/);
  const sections = {};
  let curKey = null;
  let buf = [];
  const flush = () => { if (curKey !== null) sections[curKey] = buf.join("\n").trim(); buf = []; };
  for (const line of lines) {
    const m = /^##\s+(.+?)\s*$/.exec(line);
    if (m && !/^###/.test(line)) {
      flush();
      const h = m[1].toLowerCase();
      if (h.startsWith("summary")) curKey = "summary";
      else if (h.startsWith("god nodes")) curKey = "godNodes";
      else if (h.startsWith("surprising")) curKey = "surprising";
      else if (h.startsWith("communities")) curKey = "communities";
      else curKey = null; // skip Corpus Check / Graph Freshness / Community Hubs / Import Cycles
      continue;
    }
    if (curKey !== null) buf.push(line);
  }
  flush();

  // Communities: parse each `### Community N - "name"` block into {name, nodeCount, sample}.
  const communities = [];
  if (sections.communities) {
    const cl = sections.communities.split(/\r?\n/);
    let cur = null;
    for (const line of cl) {
      const cm = /^###\s+Community\s+\d+\s*-\s*"(.+)"\s*$/.exec(line);
      if (cm) { if (cur) communities.push(cur); cur = { name: cm[1], nodeCount: 0, sample: "" }; continue; }
      if (!cur) continue;
      const nm = /^Nodes\s*\((\d+)\):\s*(.+)$/.exec(line);
      if (nm) { cur.nodeCount = parseInt(nm[1], 10); cur.sample = nm[2].trim(); }
    }
    if (cur) communities.push(cur);
  }
  // Largest first — the biggest communities are the most map-worthy.
  communities.sort((a, b) => b.nodeCount - a.nodeCount);

  return {
    summary: sections.summary || "",
    godNodes: sections.godNodes || "",
    surprising: sections.surprising || "",
    communities,
  };
}

// A parse with NO recognizable section at all means the report is malformed /
// wrong-format / truncated — publishing would silently clobber the last-good
// tracked MOC with an empty placeholder on the unattended cadence. Callers must
// refuse to publish when this is true. (parseReport stays resilient to any
// SINGLE missing section — this is the all-empty floor only.)
export function isEmptyParse(parsed) {
  return !parsed.summary && !parsed.godNodes && !parsed.surprising && parsed.communities.length === 0;
}

// Extract "N nodes · M edges · K communities" from the Summary bullet for frontmatter.
export function statsFromSummary(summary) {
  const m = /(\d[\d,]*)\s*nodes\s*·\s*(\d[\d,]*)\s*edges\s*·\s*(\d[\d,]*)\s*communities/i.exec(summary);
  const n = (s) => (s ? parseInt(s.replace(/,/g, ""), 10) : 0);
  return m ? { nodes: n(m[1]), edges: n(m[2]), communities: n(m[3]) } : { nodes: 0, edges: 0, communities: 0 };
}

// Keep only the first N bullet entries of the Surprising section (each entry is a
// `- …` line optionally followed by an indented provenance line we drop for brevity).
function topSurprising(surprising, n) {
  const out = [];
  for (const line of surprising.split(/\r?\n/)) {
    if (/^-\s/.test(line)) { if (out.length >= n) break; out.push(line); }
  }
  return out.join("\n");
}

// ── pure render ─────────────────────────────────────────────────────────────
export function renderMoc(parsed, meta) {
  const stats = statsFromSummary(parsed.summary);
  const topN = meta.topCommunities ?? 40;
  const topS = meta.topSurprising ?? 12;
  const tags = ["graphify", "knowledge-graph", "moc", meta.corpus].filter(Boolean);

  const fm = [
    "---",
    "type: moc",
    `title: "${meta.title}"`,
    `slug: ${meta.slug}`,
    "tags:",
    ...tags.map((t) => `  - ${t}`),
    `date: ${meta.date}`,
    "ai-first: true",
    "generated_by: graphify-map-cadence",
    `graph_nodes: ${stats.nodes}`,
    `graph_edges: ${stats.edges}`,
    `graph_communities: ${stats.communities}`,
    ...(meta.sourceGraph ? [`source_graph: ${meta.sourceGraph}`] : []),
    "---",
  ].join("\n");

  const communityLines = parsed.communities.slice(0, topN).map((c) => {
    const sample = c.sample ? ` — ${c.sample.replace(/\s*\(\+\d+ more\)\s*$/, "")}` : "";
    return `- **${c.name}** (${c.nodeCount})${sample}`;
  });

  const body = [
    fm,
    "",
    `# ${meta.title}`,
    "",
    "> Auto-generated by graphify-map-cadence (HIMMEL-825). Do not edit manually —",
    `> regenerated on each graph refresh. Full report + queryable graph live in the`,
    `> repo's \`graphify-out/\` (derived, gitignored); this is the curated map.`,
    "",
    "## Summary",
    "",
    parsed.summary || "_(no summary)_",
    "",
    "## God Nodes (core abstractions)",
    "",
    parsed.godNodes || "_(none)_",
    "",
    `## Surprising Connections (top ${topS})`,
    "",
    topSurprising(parsed.surprising, topS) || "_(none)_",
    "",
    `## Largest Communities (top ${topN} of ${parsed.communities.length})`,
    "",
    communityLines.length ? communityLines.join("\n") : "_(none)_",
    "",
  ].join("\n");

  return body.replace(/\n{3,}/g, "\n\n").trimEnd() + "\n";
}

// ── IO shell ────────────────────────────────────────────────────────────────
function parseArgs(argv) {
  const a = {};
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    const take = () => { const v = argv[++i]; if (v === undefined) throw new Error(`${k} requires a value`); return v; };
    if (k === "--report") a.report = take();
    else if (k === "--out") a.out = take();
    else if (k === "--title") a.title = take();
    else if (k === "--slug") a.slug = take();
    else if (k === "--corpus") a.corpus = take();
    else if (k === "--top-communities") a.topCommunities = parseInt(take(), 10);
    else if (k === "--top-surprising") a.topSurprising = parseInt(take(), 10);
    else if (k === "--source-graph") a.sourceGraph = take();
    else if (k === "--date") a.date = take(); // test hook (Date.now unavailable in some sandboxes)
    else throw new Error(`unknown flag: ${k}`);
  }
  for (const req of ["report", "out", "title", "slug"]) {
    if (!a[req]) throw new Error(`--${req} is required`);
  }
  return a;
}

function main() {
  const a = parseArgs(process.argv.slice(2));
  const text = readFileSync(a.report, "utf8");
  const parsed = parseReport(text);
  if (isEmptyParse(parsed)) {
    throw new Error(`report at ${a.report} has no recognizable sections (Summary/God Nodes/Surprising/Communities) — refusing to publish a placeholder MOC that would clobber the last-good map`);
  }
  const date = a.date || new Date().toISOString().slice(0, 10);
  const moc = renderMoc(parsed, {
    title: a.title, slug: a.slug, corpus: a.corpus, date,
    topCommunities: a.topCommunities, topSurprising: a.topSurprising, sourceGraph: a.sourceGraph,
  });
  mkdirSync(dirname(a.out), { recursive: true });
  writeFileSync(a.out, moc);
  process.stderr.write(`publish-graph-map: wrote ${a.out} (${parsed.communities.length} communities parsed, ${moc.length} bytes)\n`);
}

// Run main() only as a CLI, not when imported by the test.
import { fileURLToPath } from "node:url";
if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  try { main(); } catch (e) { process.stderr.write(`publish-graph-map: ERROR ${e.message}\n`); process.exit(1); }
}
