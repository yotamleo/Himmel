import { test, expect } from "bun:test";
import { correlate } from "../src/correlate";

test("joins on date with lag and computes rates (explicit threshold)", () => {
  const series = [ {date:"2026-05-02",value:1}, {date:"2026-05-03",value:0} ];
  const factor = [ {date:"2026-05-01",value:6}, {date:"2026-05-02",value:1} ];
  const s = correlate(series, factor, 1, { minN: 1, highThreshold: 5 }); // factor d -> series d+1
  expect(s.n).toBe(2);
  expect(s.nHigh).toBe(1);          // value 6 on 05-01 -> series 05-02 (value 1)
  expect(s.rateHigh).toBe(1);
  expect(s.rateLow).toBe(0);
  expect(s.belowMinN).toBe(false);
  expect(s.caveats.length).toBeGreaterThan(0);
});

test("flags below-min-n", () => {
  const s = correlate([{date:"2026-05-02",value:1}], [{date:"2026-05-02",value:1}], 0, { minN: 20 });
  expect(s.belowMinN).toBe(true);
});

test("continuous factor with no threshold splits on the median", () => {
  // Pressure-like values; no highThreshold -> median split. median([1000,1005,1010,1015])=1007.5
  const factor = [
    {date:"2026-05-01",value:1000}, {date:"2026-05-02",value:1005},
    {date:"2026-05-03",value:1010}, {date:"2026-05-04",value:1015},
  ];
  const series = [
    {date:"2026-05-01",value:3}, {date:"2026-05-02",value:2},
    {date:"2026-05-03",value:1}, {date:"2026-05-04",value:0},
  ];
  const s = correlate(series, factor, 0, { minN: 1, factorLabel: "barometric pressure (daily min, hPa)" });
  expect(s.n).toBe(4);
  expect(s.nHigh).toBe(2); // 1010,1015 >= 1007.5
  expect(s.nLow).toBe(2);  // 1000,1005 < 1007.5
  expect(s.factor).toBe("barometric pressure (daily min, hPa)");
  expect(s.correlation).toBeCloseTo(-1, 5); // higher pressure -> lower series here
  expect(s.caveats.some(c => c.includes("median"))).toBe(true);
});

test("median split with odd n uses the middle value", () => {
  const factor = [
    {date:"2026-05-01",value:1000}, {date:"2026-05-02",value:1005}, {date:"2026-05-03",value:1010},
  ];
  const series = [
    {date:"2026-05-01",value:1}, {date:"2026-05-02",value:1}, {date:"2026-05-03",value:1},
  ];
  const s = correlate(series, factor, 0, { minN: 1 }); // median=1005
  expect(s.n).toBe(3);
  expect(s.nHigh).toBe(2); // 1005,1010 >= 1005
  expect(s.nLow).toBe(1);  // 1000 < 1005
});

test("all-equal factor values: everything is 'high', rateLow/ratio/correlation degrade safely", () => {
  const factor = [
    {date:"2026-05-01",value:1000}, {date:"2026-05-02",value:1000}, {date:"2026-05-03",value:1000},
  ];
  const series = [
    {date:"2026-05-01",value:3}, {date:"2026-05-02",value:2}, {date:"2026-05-03",value:1},
  ];
  const s = correlate(series, factor, 0, { minN: 1 }); // median=1000, all >= 1000
  expect(s.nHigh).toBe(3);
  expect(s.nLow).toBe(0);
  expect(s.rateLow).toBe(0);
  expect(s.rateRatio).toBeNull();
  expect(s.correlation).toBeNull(); // zero variance in the factor
});

test("no overlapping dates -> n=0 with the no-overlap caveat", () => {
  const s = correlate(
    [{date:"2026-05-01",value:1}], [{date:"2026-09-01",value:1000}], 0, { minN: 1 },
  );
  expect(s.n).toBe(0);
  expect(s.correlation).toBeNull();
  expect(s.caveats.some(c => c.includes("No overlapping dates"))).toBe(true);
});

test("labels series and factor from opts", () => {
  const s = correlate([{date:"2026-05-01",value:1}], [{date:"2026-05-01",value:1}], 0, {
    minN: 1, seriesName: "migraine", factorLabel: "Kp-index", highThreshold: 5,
  });
  expect(s.series).toBe("migraine");
  expect(s.factor).toBe("Kp-index");
});
