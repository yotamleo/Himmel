import { expect, test } from "bun:test";
import { formatDashboard, dashboardJson } from "../src/dashboardNote";
import type { DashboardResult } from "../src/analyze";

const res: DashboardResult = {
  rows: [
    { series: "sleep_hours (2025-01-01+)", factor: "Kp-index", bestLag: 1, n: 120,
      correlation: 0.31, pValue: 0.0006, rateHigh: 6.8, rateLow: 7.4, rateRatio: 0.92,
      belowMinN: false, fdrSurvivor: true },
    { series: "rhr_bpm (2025-01-01+)", factor: "daylight (hours, region-centroid lat)", bestLag: 0,
      n: 110, correlation: -0.08, pValue: 0.4, rateHigh: 60, rateLow: 61, rateRatio: 0.98,
      belowMinN: false, fdrSurvivor: false },
  ],
  testCount: 14, pairCount: 2, lagCount: 7, fdrQ: 0.1, survivorCount: 1, familySize: 2,
};

test("note carries disclaimer, banner, and a row per signal", () => {
  const md = formatDashboard(res);
  expect(md).toContain("not a diagnosis");
  expect(md).toContain("comparisons");         // total tests disclosed
  expect(md).toContain("BH-FDR q=0.1");
  expect(md).toContain("survived");
  expect(md).toContain("among survivors");     // FDR-honest phrasing
  expect(md).toContain("sleep_hours (2025-01-01+)");
  expect(md).toContain("Kp-index");
  expect(md).toContain("best-lag selection");  // selection caveat present
});

test("survivors render above non-survivors", () => {
  const md = formatDashboard(res);
  expect(md.indexOf("Kp-index")).toBeLessThan(md.indexOf("daylight"));
});

test("dashboardJson round-trips the result", () => {
  expect(JSON.parse(dashboardJson(res)).survivorCount).toBe(1);
});
