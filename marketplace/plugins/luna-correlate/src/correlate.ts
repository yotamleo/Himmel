export type KpPoint = { date: string; kp: number };
export type SeriesPoint = { date: string; value: number };
// A generic factor sample: a date-keyed value. Kp maps {date,kp}->{date,value};
// location factors (pressure/pollen/aq) arrive in this shape from the proximity
// index. The join below is identical regardless of factor.
export type FactorPoint = { date: string; value: number };
export type Signal = {
  series: string; factor: string; lagDays: number;
  n: number; nHigh: number; nLow: number;
  rateHigh: number; rateLow: number; rateRatio: number | null;
  correlation: number | null;
  caveats: string[];
  belowMinN: boolean;
};

export type CorrelateOpts = {
  minN?: number;
  // value >= highThreshold splits "high" vs "low" factor days. Kp passes 5 (the
  // geomagnetic-storm threshold). Continuous factors (pressure, pollen, aq) omit
  // it → the split uses the MEDIAN of the joined factor values, a generic rule
  // with no per-factor magic number.
  highThreshold?: number;
  factorLabel?: string; // Signal.factor label (e.g. "Kp-index", "barometric pressure …")
  seriesName?: string;  // Signal.series label
};

function median(xs: number[]): number {
  const s = [...xs].sort((a, b) => a - b);
  const m = Math.floor(s.length / 2);
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}

// Anchor the date at UTC midnight ("T00:00:00Z") and shift via setUTCDate so
// the arithmetic stays in UTC. Parsing a bare "YYYY-MM-DD" would otherwise be
// interpreted as local midnight, and the toISOString() slice back to a day
// string could land on the previous/next calendar day in non-UTC timezones
// (#541 nit — keep all date math timezone-independent).
function addDays(date: string, d: number): string {
  const t = new Date(date + "T00:00:00Z"); t.setUTCDate(t.getUTCDate() + d);
  return t.toISOString().slice(0, 10);
}

function pearson(xs: number[], ys: number[]): number | null {
  const n = xs.length; if (n < 2) return null;
  const mx = xs.reduce((a,b)=>a+b,0)/n, my = ys.reduce((a,b)=>a+b,0)/n;
  let sxy=0,sxx=0,syy=0;
  for (let i=0;i<n;i++){ const dx=xs[i]-mx, dy=ys[i]-my; sxy+=dx*dy; sxx+=dx*dx; syy+=dy*dy; }
  if (sxx===0||syy===0) return null;
  return sxy/Math.sqrt(sxx*syy);
}

export function correlate(
  series: SeriesPoint[], factor: FactorPoint[], lagDays = 0, opts: CorrelateOpts = {},
): Signal {
  const minN = opts.minN ?? 20;
  const sByDate = new Map(series.map(p => [p.date, p.value]));
  const fvals: number[] = [], vals: number[] = [];
  for (const f of factor) {
    const v = sByDate.get(addDays(f.date, lagDays));
    if (v === undefined) continue;
    fvals.push(f.value); vals.push(v);
  }
  const n = fvals.length;
  // Threshold: explicit (Kp passes 5) else the median of the joined factor values
  // (generic continuous-factor split, no magic number). n=0 → no split needed.
  const threshold = opts.highThreshold ?? (n ? median(fvals) : 0);
  const highIdx = fvals.map((k,i)=>({k,i})).filter(o=>o.k>=threshold).map(o=>o.i);
  const lowIdx  = fvals.map((k,i)=>({k,i})).filter(o=>o.k<threshold).map(o=>o.i);
  const mean = (idx:number[]) => idx.length ? idx.reduce((a,i)=>a+vals[i],0)/idx.length : 0;
  const rateHigh = mean(highIdx), rateLow = mean(lowIdx);
  const factorLabel = opts.factorLabel ?? "factor";
  return {
    series: opts.seriesName ?? "(series)", factor: factorLabel, lagDays,
    n, nHigh: highIdx.length, nLow: lowIdx.length,
    rateHigh, rateLow, rateRatio: rateLow > 0 ? rateHigh/rateLow : null,
    correlation: pearson(fvals, vals),
    belowMinN: n < minN,
    caveats: [
      "Candidate signal only — correlation does not imply causation.",
      "Device/self-report data; confounders (sleep, travel, meds) not controlled.",
      `High vs low ${factorLabel} split at ${opts.highThreshold !== undefined ? `threshold ${threshold}` : `median ${Math.round(threshold*1000)/1000}`}.`,
      n === 0
        ? "No overlapping dates between series and factor — check date formats/ranges."
        : n < minN ? `n=${n} below min-n (${minN}); treat as not interpretable.` : `n=${n}.`,
      "Multiple factors/lags tested elsewhere inflate false-positive risk.",
    ],
  };
}
