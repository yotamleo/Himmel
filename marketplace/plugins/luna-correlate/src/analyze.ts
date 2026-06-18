import { correlate, type SeriesPoint, type FactorPoint } from "./correlate";
import { pearsonPValue } from "./stats";

export type SeriesSpec = { name: string; points: SeriesPoint[] };
export type FactorSpec = {
  name: string; label: string; points: FactorPoint[]; highThreshold?: number;
};

// One swept-lag sample, retained per pair so the dashboard can chart r-vs-lag
// (the diagnostic that shows whether the reported best-lag is a real peak vs a
// cherry-picked maximum). `r` is null at lags where the correlation is undefined.
export type LagPoint = { lag: number; r: number | null; n: number };

export type DashboardRow = {
  series: string; factor: string; bestLag: number;
  n: number; correlation: number | null; pValue: number | null;
  rateHigh: number; rateLow: number; rateRatio: number | null;
  belowMinN: boolean; fdrSurvivor: boolean;
  // Full swept window, ascending by lag; the entry at `bestLag` has r === correlation
  // and n === this row's n (the charted best-lag point equals the headline number).
  lagProfile: LagPoint[];
};

export type DashboardResult = {
  rows: DashboardRow[];
  testCount: number;   // total comparisons run = pairCount * lagCount (disclosed)
  pairCount: number;   // (series,factor) pairs reported (one best-lag row each)
  lagCount: number;
  fdrQ: number;
  survivorCount: number;
  familySize: number;  // interpretable rows (min-n met) that entered the BH-FDR family
};

export type AnalyzeOpts = { lagWindow?: number; minN?: number; fdrQ?: number };

/** Benjamini-Hochberg: survivors are the prefix up to the largest rank k with
 *  p(k) <= (k/m)*q after ascending sort. Returns a flag per original index. */
export function bhSurvivors(pvals: number[], q: number): boolean[] {
  const m = pvals.length;
  if (m === 0) return [];
  if (pvals.some(p => !Number.isFinite(p) || p < 0 || p > 1)) {
    throw new Error(`bhSurvivors: p-values must be finite in [0,1]; got ${pvals.filter(p => !Number.isFinite(p) || p < 0 || p > 1)}`);
  }
  const ordered = pvals.map((p, i) => ({ p, i })).sort((a, b) => a.p - b.p);
  let kMax = 0;
  for (let rank = 1; rank <= m; rank++) {
    if (ordered[rank - 1].p <= (rank / m) * q) kMax = rank;
  }
  const surv = new Array<boolean>(m).fill(false);
  for (let rank = 1; rank <= kMax; rank++) surv[ordered[rank - 1].i] = true;
  return surv;
}

export function analyze(
  series: SeriesSpec[], factors: FactorSpec[], opts: AnalyzeOpts = {},
): DashboardResult {
  const w = opts.lagWindow ?? 3;
  if (w < 0) throw new Error(`analyze: lagWindow must be >= 0; got ${w}`);
  const minN = opts.minN ?? 20;
  const fdrQ = opts.fdrQ ?? 0.1;
  const lags: number[] = [];
  for (let l = -w; l <= w; l++) lags.push(l);

  const rows: DashboardRow[] = [];
  for (const s of series) {
    for (const f of factors) {
      // Sweep lags; pick the best-lag signal. Prefer lags meeting min-n, by max |r|;
      // if none meet min-n, fall back to the largest-n lag (still flagged belowMinN).
      let best: { lag: number; r: number | null; sig: ReturnType<typeof correlate> } | null = null;
      const lagProfile: LagPoint[] = [];
      for (const lag of lags) {
        const sig = correlate(s.points, f.points, lag, {
          minN, highThreshold: f.highThreshold, factorLabel: f.label, seriesName: s.name,
        });
        lagProfile.push({ lag, r: sig.correlation, n: sig.n });
        const eligible = !sig.belowMinN;
        if (best === null) { best = { lag, r: sig.correlation, sig }; continue; }
        const bestEligible = !best.sig.belowMinN;
        const better = eligible !== bestEligible
          ? eligible // an eligible lag always beats an ineligible one
          : eligible
            ? Math.abs(sig.correlation ?? 0) > Math.abs(best.r ?? 0)
            : sig.n > best.sig.n; // both ineligible → prefer larger n
        if (better) best = { lag, r: sig.correlation, sig };
      }
      const b = best!.sig;
      rows.push({
        series: s.name, factor: f.label, bestLag: best!.lag,
        n: b.n, correlation: b.correlation,
        pValue: !b.belowMinN && b.correlation !== null ? pearsonPValue(b.correlation, b.n) : null,
        rateHigh: b.rateHigh, rateLow: b.rateLow, rateRatio: b.rateRatio,
        belowMinN: b.belowMinN, fdrSurvivor: false, lagProfile,
      });
    }
  }

  // FDR family = interpretable rows only (min-n met, p computed). Best-lag was
  // selected per pair, so survivors are CANDIDATES, not confirmations (caveated).
  const familyIdx = rows.map((r, i) => ({ r, i })).filter(o => o.r.pValue !== null);
  const surv = bhSurvivors(familyIdx.map(o => o.r.pValue as number), fdrQ);
  familyIdx.forEach((o, k) => { rows[o.i].fdrSurvivor = surv[k]; });
  const survivorCount = rows.filter(r => r.fdrSurvivor).length;

  // Sort: survivors first, then by |r| desc.
  rows.sort((a, b2) => {
    if (a.fdrSurvivor !== b2.fdrSurvivor) return a.fdrSurvivor ? -1 : 1;
    return Math.abs(b2.correlation ?? 0) - Math.abs(a.correlation ?? 0);
  });

  return {
    rows,
    testCount: rows.length * lags.length,
    pairCount: rows.length,
    lagCount: lags.length,
    fdrQ,
    survivorCount,
    familySize: familyIdx.length,
  };
}
