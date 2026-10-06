// scripts/eval/qmd-quality/compare.ts - paired per-query comparison of two
// runs.jsonl files scored against one golden set (HIMMEL-4650).
//
//   bun compare.ts --golden <golden.jsonl> --a <runs.jsonl> --b <runs.jsonl> [--mode M]
//
// Per mode present in both runs, on the per-query reciprocal rank (0 when the
// query has no expected doc ranked or no run row):
//   n_pairs      queries whose rr differs (ties are dropped from both tests)
//   mean_rr_a/b  mean rr over ALL golden queries; delta = b - a
//   b_up/b_down  queries where b ranks the expected doc higher / lower
//   sign_p       exact two-sided binomial sign test, p = 0.5
//   wilcoxon_p   two-sided signed-rank test, normal approximation with tie and
//                continuity corrections (read sign_p when n_pairs is under ~10)
// then one `flip` line per query whose first-hit rank changed.
// Exit 0 compared, 2 bad input.
import { type Golden, type Run, readJsonl, validateGolden, firstHit } from "./score.ts";

export function signTestP(up: number, down: number): number {
  const n = up + down;
  if (n === 0) return 1;
  const k = Math.min(up, down);
  // P(X <= k) for X ~ Bin(n, 0.5), summed in log space so a large n cannot overflow.
  let lg = 0; // log C(n, i), starting at i = 0
  let tail = 0;
  for (let i = 0; i <= k; i++) {
    tail += Math.exp(lg - n * Math.LN2);
    lg += Math.log(n - i) - Math.log(i + 1);
  }
  return Math.min(1, 2 * tail);
}

// Standard normal upper tail, via the Abramowitz-Stegun 7.1.26 erfc approximation.
function normSf(z: number): number {
  const x = Math.abs(z) / Math.SQRT2;
  const t = 1 / (1 + 0.3275911 * x);
  const y = ((((1.061405429 * t - 1.453152027) * t + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t;
  return 0.5 * y * Math.exp(-x * x);
}

export function wilcoxonP(diffs: number[]): number {
  const d = diffs.filter((x) => Math.abs(x) > 1e-12);
  const n = d.length;
  if (n === 0) return 1;
  const order = d.map((x) => ({ a: Math.abs(x), pos: x > 0 })).sort((p, q) => p.a - q.a);
  const ranks = new Array<number>(n);
  let tieTerm = 0;
  for (let i = 0; i < n; ) {
    let j = i;
    while (j + 1 < n && Math.abs(order[j + 1]!.a - order[i]!.a) < 1e-12) j++;
    const r = (i + j) / 2 + 1;
    for (let k = i; k <= j; k++) ranks[k] = r;
    const t = j - i + 1;
    tieTerm += t * t * t - t;
    i = j + 1;
  }
  let wPlus = 0;
  order.forEach((o, k) => { if (o.pos) wPlus += ranks[k]!; });
  const mean = (n * (n + 1)) / 4;
  const varW = (n * (n + 1) * (2 * n + 1)) / 24 - tieTerm / 48;
  if (varW <= 0) return 1;
  const dev = Math.max(0, Math.abs(wPlus - mean) - 0.5);
  return Math.min(1, 2 * normSf(dev / Math.sqrt(varW)));
}

export type Pair = {
  mode: string; nPairs: number; meanA: number; meanB: number; up: number; down: number;
  signP: number; wilcoxonP: number; flips: { id: string; a: number; b: number }[];
};

export function compare(golden: Golden[], a: Run[], b: Run[], only?: string): Pair[] {
  const idx = (runs: Run[]) => new Map(runs.map((r) => [`${r.mode}\t${r.id}`, r]));
  const ia = idx(a), ib = idx(b);
  const modesA = new Set(a.map((r) => r.mode));
  const modes = [...new Set(b.map((r) => r.mode))].filter((m) => modesA.has(m) && (!only || m === only));
  return modes.map((mode) => {
    const diffs: number[] = [];
    const flips: Pair["flips"] = [];
    let sa = 0, sb = 0, up = 0, down = 0;
    for (const g of golden) {
      const ra = ia.get(`${mode}\t${g.id}`), rb = ib.get(`${mode}\t${g.id}`);
      const ka = ra ? firstHit(g, ra.ranked) : 0, kb = rb ? firstHit(g, rb.ranked) : 0;
      const xa = ka ? 1 / ka : 0, xb = kb ? 1 / kb : 0;
      sa += xa; sb += xb;
      diffs.push(xb - xa);
      if (ka !== kb) flips.push({ id: g.id, a: ka, b: kb });
      if (xb - xa > 1e-12) up++;
      else if (xa - xb > 1e-12) down++;
    }
    const n = golden.length;
    return { mode, nPairs: up + down, meanA: sa / n, meanB: sb / n, up, down, signP: signTestP(up, down), wilcoxonP: wilcoxonP(diffs), flips };
  });
}

export function formatPairs(pairs: Pair[]): string {
  const f = (x: number) => x.toFixed(3);
  const p = (x: number) => x.toFixed(4);
  const lines = ["mode\tn_pairs\tmean_rr_a\tmean_rr_b\tdelta\tb_up\tb_down\tsign_p\twilcoxon_p"];
  for (const r of pairs) {
    const d = r.meanB - r.meanA;
    lines.push([r.mode, r.nPairs, f(r.meanA), f(r.meanB), (d >= 0 ? "+" : "") + f(d), r.up, r.down, p(r.signP), p(r.wilcoxonP)].join("\t"));
  }
  for (const r of pairs)
    for (const x of r.flips) lines.push(["flip", r.mode, x.id, `rank_a=${x.a || "-"}`, `rank_b=${x.b || "-"}`].join("\t"));
  return lines.join("\n");
}

function arg(name: string): string | undefined {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : undefined;
}

if (import.meta.main) {
  const [gp, ap, bp] = [arg("--golden"), arg("--a"), arg("--b")];
  if (!gp || !ap || !bp) {
    console.error("usage: bun compare.ts --golden <golden.jsonl> --a <runs.jsonl> --b <runs.jsonl> [--mode M]");
    process.exit(2);
  }
  let golden: Golden[], a: Run[], b: Run[];
  try {
    golden = readJsonl<Golden>(gp);
    a = readJsonl<Run>(ap);
    b = readJsonl<Run>(bp);
  } catch (e) {
    console.error(`compare: ${(e as Error).message}`);
    process.exit(2);
  }
  const bad = validateGolden(golden);
  if (bad) { console.error(`compare: ${bad}`); process.exit(2); }
  // Same refusal as score.ts: a mode where every query errored is a broken run, not a zero.
  for (const [label, runs] of [["a", a], ["b", b]] as const) {
    const only = arg("--mode");
    const broken = [...new Set(runs.map((r) => r.mode))].filter((m) => (!only || m === only) && runs.every((r) => r.mode !== m || r.error));
    if (broken.length) { console.error(`compare: every query errored in mode(s) ${broken.join(",")} of --${label}; refusing to compare a broken run`); process.exit(2); }
  }
  const pairs = compare(golden, a, b, arg("--mode"));
  if (pairs.length === 0) { console.error("compare: no mode present in both runs"); process.exit(2); }
  console.log(formatPairs(pairs));
}
