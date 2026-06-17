// Offline statistics: a two-tailed Pearson-correlation p-value via the
// regularized incomplete beta function (Numerical Recipes betai / betacf /
// gammln). Exact at the small n (≈50–150 per era-pair) where a normal
// approximation would be biased — and the FDR honesty downstream depends on it.
// No network, no dependencies.

function gammln(x: number): number {
  const cof = [
    76.18009172947146, -86.50532032941677, 24.01409824083091,
    -1.231739572450155, 0.1208650973866179e-2, -0.5395239384953e-5,
  ];
  let y = x;
  let tmp = x + 5.5;
  tmp -= (x + 0.5) * Math.log(tmp);
  let ser = 1.000000000190015;
  for (let j = 0; j < 6; j++) { y += 1; ser += cof[j] / y; }
  return -tmp + Math.log((2.5066282746310005 * ser) / x);
}

function betacf(a: number, b: number, x: number): number {
  const MAXIT = 200, EPS = 3e-12, FPMIN = 1e-300;
  const qab = a + b, qap = a + 1, qam = a - 1;
  let c = 1;
  let d = 1 - (qab * x) / qap;
  if (Math.abs(d) < FPMIN) d = FPMIN;
  d = 1 / d;
  let h = d;
  for (let m = 1; m <= MAXIT; m++) {
    const m2 = 2 * m;
    let aa = (m * (b - m) * x) / ((qam + m2) * (a + m2));
    d = 1 + aa * d; if (Math.abs(d) < FPMIN) d = FPMIN;
    c = 1 + aa / c; if (Math.abs(c) < FPMIN) c = FPMIN;
    d = 1 / d; h *= d * c;
    aa = (-(a + m) * (qab + m) * x) / ((a + m2) * (qap + m2));
    d = 1 + aa * d; if (Math.abs(d) < FPMIN) d = FPMIN;
    c = 1 + aa / c; if (Math.abs(c) < FPMIN) c = FPMIN;
    d = 1 / d;
    const del = d * c; h *= del;
    if (Math.abs(del - 1) < EPS) break;
  }
  return h;
}

/** Regularized incomplete beta I_x(a,b) for x in [0,1]. */
export function betai(a: number, b: number, x: number): number {
  if (x < 0 || x > 1) throw new Error(`betai: x out of [0,1]: ${x}`);
  if (x === 0 || x === 1) return x;
  const bt = Math.exp(
    gammln(a + b) - gammln(a) - gammln(b) + a * Math.log(x) + b * Math.log(1 - x),
  );
  if (x < (a + 1) / (a + b + 2)) return (bt * betacf(a, b, x)) / a;
  return 1 - (bt * betacf(b, a, 1 - x)) / b;
}

/** Two-tailed p-value for a Pearson correlation r over n samples. */
export function pearsonPValue(r: number, n: number): number {
  if (n < 3) return 1;
  if (r <= -1 || r >= 1) return 0;
  const df = n - 2;
  const t2 = (r * r * df) / (1 - r * r);
  const p = betai(df / 2, 0.5, df / (df + t2));
  if (!Number.isFinite(p)) throw new Error(`pearsonPValue: non-finite p (${p}) for r=${r}, n=${n}`);
  return p;
}
