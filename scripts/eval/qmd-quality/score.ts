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
// --ci-out <file>: bootstrap 95% CIs over the ALL queries (hit1, hit5, mrr per
//   mode) as {"<mode>.hit1":{"lo","hi"},...}, for the eval-runs ledger (HIMMEL-4650).
// --cases-out <file>: per-query {"<id>":{"<mode>.rr":x}}, for a paired compare.
// Exit 0 scored, 2 bad input (unreadable file, no expect doc, duplicate id,
// or a mode where every query errored).
import { readFileSync, writeFileSync } from "node:fs";

export type Golden = { id: string; query: string; collections: string[]; expect: string[] };
export type Run = { id: string; mode: string; ranked: string[]; error?: string };
export type Row = { mode: string; collection: string; n: number; hit1: number; hit5: number; mrr: number; missing: number };

export function readJsonl<T>(path: string): T[] {
  return readFileSync(path, "utf8")
    .split("\n")
    .filter((l) => l.trim() !== "")
    .map((l) => JSON.parse(l) as T);
}

export function validateGolden(golden: Golden[]): string | null {
  if (golden.length === 0) return "golden set is empty";
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

// Per-query reciprocal rank and hit flags, per mode (0 when absent or no run row).
export type Perq = { rr: number; hit1: number; hit5: number };
export function perQuery(golden: Golden[], runs: Run[]): Map<string, Map<string, Perq>> {
  const byKey = new Map<string, Run>();
  const modes: string[] = [];
  for (const r of runs) {
    if (!modes.includes(r.mode)) modes.push(r.mode);
    byKey.set(`${r.mode}\t${r.id}`, r);
  }
  const out = new Map<string, Map<string, Perq>>();
  for (const mode of modes) {
    const m = new Map<string, Perq>();
    for (const g of golden) {
      const run = byKey.get(`${mode}\t${g.id}`);
      const rank = run ? firstHit(g, run.ranked) : 0;
      m.set(g.id, { rr: rank ? 1 / rank : 0, hit1: rank === 1 ? 1 : 0, hit5: rank >= 1 && rank <= 5 ? 1 : 0 });
    }
    out.set(mode, m);
  }
  return out;
}

// mulberry32: a seeded PRNG, so a CI is identical on every run of the same data.
function prng(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// Percentile bootstrap CI of the mean (queries resampled with replacement).
export function bootstrapCI(xs: number[], level = 0.95, reps = 2000, seed = 1): { lo: number; hi: number } {
  const n = xs.length;
  if (n === 0) return { lo: 0, hi: 0 };
  const rnd = prng(seed);
  const means: number[] = [];
  for (let b = 0; b < reps; b++) {
    let s = 0;
    for (let i = 0; i < n; i++) s += xs[Math.floor(rnd() * n)]!;
    means.push(s / n);
  }
  means.sort((a, b) => a - b);
  const a = (1 - level) / 2;
  return { lo: means[Math.floor(a * reps)]!, hi: means[Math.min(reps - 1, Math.ceil((1 - a) * reps) - 1)]! };
}

export function ciTable(golden: Golden[], runs: Run[]): Record<string, { lo: number; hi: number }> {
  const t: Record<string, { lo: number; hi: number }> = {};
  for (const [mode, m] of perQuery(golden, runs)) {
    const v = [...m.values()];
    for (const [name, key] of [["hit1", "hit1"], ["hit5", "hit5"], ["mrr", "rr"]] as const) {
      const ci = bootstrapCI(v.map((x) => x[key]));
      t[`${mode}.${name}`] = { lo: +ci.lo.toFixed(6), hi: +ci.hi.toFixed(6) };
    }
  }
  return t;
}

export function casesTable(golden: Golden[], runs: Run[]): Record<string, Record<string, number>> {
  const t: Record<string, Record<string, number>> = {};
  for (const g of golden) t[g.id] = {};
  for (const [mode, m] of perQuery(golden, runs)) for (const [id, x] of m) t[id]![`${mode}.rr`] = +x.rr.toFixed(6);
  return t;
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
  if (runs.length === 0) {
    console.error("score: runs file is empty; nothing was measured");
    process.exit(2);
  }
  // One erroring query is a measured refusal; a mode where all of them errored
  // is a broken run (model, SDK or index), and scoring it would read as zero.
  const broken = [...new Set(runs.map((r) => r.mode))].filter((m) => runs.every((r) => r.mode !== m || r.error));
  if (broken.length) {
    console.error(`score: every query errored in mode(s) ${broken.join(",")}; refusing to score a broken run`);
    process.exit(2);
  }
  console.log(formatTsv(score(golden, runs)));
  const ciOut = arg("--ci-out"), casesOut = arg("--cases-out");
  if (ciOut) writeFileSync(ciOut, JSON.stringify(ciTable(golden, runs)) + "\n");
  if (casesOut) writeFileSync(casesOut, JSON.stringify(casesTable(golden, runs)) + "\n");
}
