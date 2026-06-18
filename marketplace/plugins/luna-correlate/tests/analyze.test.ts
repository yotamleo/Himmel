import { expect, test } from "bun:test";
import { analyze, bhSurvivors, type SeriesSpec, type FactorSpec } from "../src/analyze";

test("bhSurvivors flags the right prefix", () => {
  // m=4, q=0.1 thresholds k/m*q = 0.025,0.05,0.075,0.1
  // Standard BH: largest k where p(k) <= (k/m)*q. p(1)=0.001<=0.025 ✓, p(2)=0.04<=0.05 ✓ → kMax=2
  const surv = bhSurvivors([0.001, 0.04, 0.5, 0.9], 0.1);
  expect(surv).toEqual([true, true, false, false]);
});

test("bhSurvivors with all tiny p-values survives all", () => {
  expect(bhSurvivors([0.001, 0.002, 0.003], 0.1)).toEqual([true, true, true]);
});

test("bhSurvivors non-ascending input maps back to original indices", () => {
  expect(bhSurvivors([0.9, 0.001, 0.5, 0.04], 0.1)).toEqual([false, true, false, true]);
});

test("bhSurvivors no survivors when all p-values are large", () => {
  expect(bhSurvivors([0.9, 0.95], 0.1)).toEqual([false, false]);
});

test("analyze finds the planted lag and shape", () => {
  // factor leads series by exactly 1 day: series(d+1) = factor(d).
  // Use literal 40 ISO dates 2025-01-01 … 2025-02-09 to avoid date-helper brittleness.
  const dates = [
    "2025-01-01","2025-01-02","2025-01-03","2025-01-04","2025-01-05",
    "2025-01-06","2025-01-07","2025-01-08","2025-01-09","2025-01-10",
    "2025-01-11","2025-01-12","2025-01-13","2025-01-14","2025-01-15",
    "2025-01-16","2025-01-17","2025-01-18","2025-01-19","2025-01-20",
    "2025-01-21","2025-01-22","2025-01-23","2025-01-24","2025-01-25",
    "2025-01-26","2025-01-27","2025-01-28","2025-01-29","2025-01-30",
    "2025-01-31","2025-02-01","2025-02-02","2025-02-03","2025-02-04",
    "2025-02-05","2025-02-06","2025-02-07","2025-02-08","2025-02-09",
  ];
  const factor: FactorSpec = {
    name: "f", label: "f", points: dates.map((d, i) => ({ date: d, value: i % 7 })),
  };
  // series value at d+1 equals factor at d → best lag should be +1.
  const series: SeriesSpec = {
    name: "s",
    points: dates.map((d, i) => ({ date: d, value: i >= 1 ? (i - 1) % 7 : 0 })),
  };
  const res = analyze([series], [factor], { lagWindow: 2, minN: 10, fdrQ: 0.1 });
  expect(res.pairCount).toBe(1);
  expect(res.lagCount).toBe(5);          // -2..+2
  expect(res.testCount).toBe(5);         // pairs * lagCount
  expect(res.rows[0].bestLag).toBe(1);
  expect(res.rows[0].correlation).toBeGreaterThan(0.9);
  expect(res.rows[0].fdrSurvivor).toBe(true);
});

test("each row carries a lagProfile spanning the swept window, aligned to bestLag", () => {
  const dates = Array.from({ length: 30 }, (_, i) => `2025-03-${String(i + 1).padStart(2, "0")}`);
  const factor: FactorSpec = { name: "f", label: "f", points: dates.map((d, i) => ({ date: d, value: i % 7 })) };
  const series: SeriesSpec = { name: "s", points: dates.map((d, i) => ({ date: d, value: i >= 1 ? (i - 1) % 7 : 0 })) };
  const res = analyze([series], [factor], { lagWindow: 2, minN: 10 });
  const r = res.rows[0];
  expect(r.lagProfile.map(e => e.lag)).toEqual([-2, -1, 0, 1, 2]);
  const bestEntry = r.lagProfile.find(e => e.lag === r.bestLag)!;
  expect(bestEntry.r).toBe(r.correlation);   // the charted best-lag point equals the row's r
  expect(bestEntry.n).toBe(r.n);
});

test("below-min-n rows are excluded from the FDR family but still reported", () => {
  const series: SeriesSpec = { name: "s", points: [{ date: "2025-01-01", value: 1 }] };
  const factor: FactorSpec = { name: "f", label: "f", points: [{ date: "2025-01-01", value: 2 }] };
  const res = analyze([series], [factor], { lagWindow: 0, minN: 20, fdrQ: 0.1 });
  expect(res.rows[0].belowMinN).toBe(true);
  expect(res.rows[0].fdrSurvivor).toBe(false);
  expect(res.survivorCount).toBe(0);
});

test("analyze throws on negative lagWindow", () => {
  const series: SeriesSpec = { name: "s", points: [{ date: "2025-01-01", value: 1 }] };
  const factor: FactorSpec = { name: "f", label: "f", points: [{ date: "2025-01-01", value: 2 }] };
  expect(() => analyze([series], [factor], { lagWindow: -1 })).toThrow(/lagWindow/);
});
