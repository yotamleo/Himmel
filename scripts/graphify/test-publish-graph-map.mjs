#!/usr/bin/env node
// Unit test for publish-graph-map.mjs pure core (parseReport / statsFromSummary
// / renderMoc). Run: node scripts/graphify/test-publish-graph-map.mjs
import { parseReport, statsFromSummary, renderMoc, isEmptyParse } from "./publish-graph-map.mjs";

let fails = 0;
const ok = (c, m) => { if (c) console.log(`  ok: ${m}`); else { console.log(`  FAIL: ${m}`); fails++; } };

const SAMPLE = `# Graph Report - X  (2026-07-09)

## Corpus Check
- cluster-only mode

## Summary
- 6275 nodes · 5865 edges · 1527 communities (527 shown, 1000 thin omitted)
- Extraction: 85% EXTRACTED · 15% INFERRED

## Graph Freshness
- Built from commit: \`abc123\`

## Community Hubs (Navigation)

## God Nodes (most connected - your core abstractions)
1. \`Claude Code\` - 107 edges
2. \`HIMMEL-654\` - 47 edges

## Surprising Connections (you probably didn't know these)
- \`A\` --references--> \`B\`  [INFERRED]
  prov/one.md → prov/two.md
- \`C\` --references--> \`D\`  [EXTRACTED]
  prov/three.md → prov/four.md
- \`E\` --references--> \`F\`  [INFERRED]

## Import Cycles
- None detected.

## Communities (1527 total, 1000 thin omitted)

### Community 0 - "Small Cluster"
Cohesion: 0.06
Nodes (10): a, b, c (+7 more)

### Community 1 - "Big Cluster"
Cohesion: 0.05
Nodes (45): x, y, z (+42 more)

### Community 2 - "Mid Cluster"
Cohesion: 0.06
Nodes (20): p, q (+18 more)
`;

const parsed = parseReport(SAMPLE);

// stats
const s = statsFromSummary(parsed.summary);
ok(s.nodes === 6275 && s.edges === 5865 && s.communities === 1527, "statsFromSummary parses nodes/edges/communities");

// sections isolated (no leakage from skipped sections)
ok(parsed.summary.includes("6275 nodes") && !parsed.summary.includes("Freshness"), "summary section isolated");
ok(parsed.godNodes.includes("Claude Code` - 107") && !parsed.godNodes.includes("Surprising"), "god nodes isolated");

// communities parsed + sorted largest-first
ok(parsed.communities.length === 3, "all 3 communities parsed");
ok(parsed.communities[0].name === "Big Cluster" && parsed.communities[0].nodeCount === 45, "communities sorted largest-first");

// render: frontmatter + banner + curated sections
const moc = renderMoc(parsed, { title: "Luna Map", slug: "graphify-luna-map", corpus: "luna", date: "2026-07-09", topCommunities: 2, topSurprising: 2, sourceGraph: "graphify-out/graph.json" });
ok(moc.startsWith("---\ntype: moc\n"), "MOC starts with type: moc frontmatter");
ok(moc.includes("graph_nodes: 6275") && moc.includes("graph_communities: 1527"), "frontmatter carries graph stats");
ok(moc.includes("source_graph: graphify-out/graph.json"), "frontmatter carries source_graph");
ok(moc.includes("Do not edit manually"), "auto-gen banner present");
ok((moc.match(/^- \*\*/gm) || []).length === 2, "top-communities cap honored (2)");
ok(moc.indexOf("Big Cluster") < moc.indexOf("Mid Cluster"), "communities rendered largest-first");
ok((moc.match(/--references-->/g) || []).length === 2, "top-surprising cap honored (2)");
ok(!moc.includes("prov/one.md"), "surprising provenance lines dropped for brevity");
ok(moc.endsWith("\n") && !moc.includes("\n\n\n"), "no triple-blank runs, trailing newline");

// missing-section resilience (a SINGLE missing section is fine)
const empty = renderMoc(parseReport("# Graph Report\n\n## Summary\n- 1 nodes · 1 edges · 1 communities\n"), { title: "T", slug: "t", date: "2026-07-09" });
ok(empty.includes("_(none)_"), "missing sections render _(none)_ not crash");
ok(!isEmptyParse(parseReport("# Graph Report\n\n## Summary\n- 1 nodes · 1 edges · 1 communities\n")), "a report with only a Summary is NOT an empty parse");

// all-empty floor: garbage input trips isEmptyParse (main() refuses to publish → exit 1)
ok(isEmptyParse(parseReport("just garbage text, no headers whatsoever\n")), "garbage input → isEmptyParse true (publish refused)");
ok(isEmptyParse(parseReport("")), "empty file → isEmptyParse true");

if (fails) { console.log(`\n${fails} FAILURES`); process.exit(1); }
console.log("\nALL PASS");
