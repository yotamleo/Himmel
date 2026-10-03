// scripts/eval/qmd-quality/latency.ts - median and p90 query latency per mode
// from a runs.jsonl written by run-eval.ts (HIMMEL-4184).
//   bun latency.ts --runs <runs.jsonl>
import { readJsonl } from "./score.ts";

const i = process.argv.indexOf("--runs");
if (i < 0 || !process.argv[i + 1]) {
  console.error("usage: bun latency.ts --runs <runs.jsonl>");
  process.exit(2);
}
const rows = readJsonl<{ mode: string; ms: number }>(process.argv[i + 1]!);
const byMode = new Map<string, number[]>();
for (const r of rows) byMode.set(r.mode, [...(byMode.get(r.mode) ?? []), r.ms]);
const pct = (xs: number[], p: number) => xs[Math.min(xs.length - 1, Math.floor(p * xs.length))]!;
console.log("mode\tn\tmedian_ms\tp90_ms");
for (const [mode, xs] of byMode) {
  xs.sort((a, b) => a - b);
  console.log([mode, xs.length, pct(xs, 0.5), pct(xs, 0.9)].join("\t"));
}
