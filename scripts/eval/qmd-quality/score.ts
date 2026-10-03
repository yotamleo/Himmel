// scripts/eval/qmd-quality/score.ts - score qmd ranked lists against the
// golden set (HIMMEL-4184). Pure: reads two JSONL files, prints a TSV.
//
//   bun score.ts --golden <golden.jsonl> --runs <runs.jsonl>
//
// golden row: {"id","query","collections":[...],"expect":["<coll>/<path>",...]}
// runs row:   {"id","mode","ranked":["<coll>/<path>",...]}  (best first)
//
// Per mode, for ALL queries and per collection (a query's first collection):
//   hit@1 / hit@5  share of queries with an expected doc in the top 1 / 5
//   mrr            mean of 1/rank of the first expected doc (0 when absent)
//   missing        golden queries with no run row for that mode (scored 0)
// Paths compare case-blind: qmd lowercases the paths it indexes.
// Exit 0 scored, 2 bad input (unreadable file, no expect doc, duplicate id).
import { readFileSync } from "node:fs";

export type Golden = { id: string; query: string; collections: string[]; expect: string[] };
export type Run = { id: string; mode: string; ranked: string[] };
export type Row = { mode: string; collection: string; n: number; hit1: number; hit5: number; mrr: number; missing: number };

export function readJsonl<T>(path: string): T[] {
  return readFileSync(path, "utf8")
    .split("\n")
    .filter((l) => l.trim() !== "")
    .map((l) => JSON.parse(l) as T);
}

export function validateGolden(golden: Golden[]): string | null {
  const seen = new Set<string>();
  for (const g of golden) {
    if (!g.id || seen.has(g.id)) return `duplicate or empty golden id: '${g.id}'`;
    seen.add(g.id);
    if (!Array.isArray(g.expect) || g.expect.length === 0) return `golden ${g.id}: no expect doc`;
    if (!Array.isArray(g.collections) || g.collections.length === 0) return `golden ${g.id}: no collection`;
  }
  return null;
}

const norm = (p: string) => p.toLowerCase();

// 1-indexed rank of the first expected doc, 0 when none is ranked.
export function firstHit(g: Golden, ranked: string[]): number {
  const want = new Set(g.expect.map(norm));
  const i = ranked.findIndex((p) => want.has(norm(p)));
  return i < 0 ? 0 : i + 1;
}

export function score(golden: Golden[], runs: Run[]): Row[] {
  const modes: string[] = [];
  const byKey = new Map<string, Run>();
  for (const r of runs) {
    if (!modes.includes(r.mode)) modes.push(r.mode);
    byKey.set(`${r.mode}\t${r.id}`, r);
  }
  const colls = [...new Set(golden.map((g) => g.collections[0]!))].sort();
  const rows: Row[] = [];
  for (const mode of modes) {
    for (const coll of ["ALL", ...colls]) {
      const qs = coll === "ALL" ? golden : golden.filter((g) => g.collections[0] === coll);
      let hit1 = 0, hit5 = 0, rr = 0, missing = 0;
      for (const g of qs) {
        const run = byKey.get(`${mode}\t${g.id}`);
        if (!run) { missing++; continue; }
        const rank = firstHit(g, run.ranked);
        if (rank === 1) hit1++;
        if (rank >= 1 && rank <= 5) hit5++;
        if (rank >= 1) rr += 1 / rank;
      }
      const n = qs.length;
      rows.push({ mode, collection: coll, n, hit1: hit1 / n, hit5: hit5 / n, mrr: rr / n, missing });
    }
  }
  return rows;
}

export function formatTsv(rows: Row[]): string {
  const f = (x: number) => x.toFixed(3);
  return [
    "mode\tcollection\tn\thit@1\thit@5\tmrr\tmissing",
    ...rows.map((r) => [r.mode, r.collection, r.n, f(r.hit1), f(r.hit5), f(r.mrr), r.missing].join("\t")),
  ].join("\n");
}

function arg(name: string): string | undefined {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : undefined;
}

if (import.meta.main) {
  const goldenPath = arg("--golden");
  const runsPath = arg("--runs");
  if (!goldenPath || !runsPath) {
    console.error("usage: bun score.ts --golden <golden.jsonl> --runs <runs.jsonl>");
    process.exit(2);
  }
  let golden: Golden[], runs: Run[];
  try {
    golden = readJsonl<Golden>(goldenPath);
    runs = readJsonl<Run>(runsPath);
  } catch (e) {
    console.error(`score: ${(e as Error).message}`);
    process.exit(2);
  }
  const bad = validateGolden(golden);
  if (bad) {
    console.error(`score: ${bad}`);
    process.exit(2);
  }
  console.log(formatTsv(score(golden, runs)));
}
