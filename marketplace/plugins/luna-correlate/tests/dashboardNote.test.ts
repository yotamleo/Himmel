import { expect, test } from "bun:test";
import { formatDashboard, dashboardJson } from "../src/dashboardNote";
import type { DashboardResult } from "../src/analyze";

const res: DashboardResult = {
  rows: [
    { series: "sleep_hours (2025-01-01+)", factor: "Kp-index", bestLag: 1, n: 120,
      correlation: 0.31, pValue: 4e-7, rateHigh: 6.8, rateLow: 7.4, rateRatio: 0.92,
      belowMinN: false, fdrSurvivor: true,
      lagProfile: [{ lag: -1, r: 0.10, n: 118 }, { lag: 0, r: 0.20, n: 120 }, { lag: 1, r: 0.31, n: 120 }] },
    { series: "rhr_bpm (2025-01-01+)", factor: "daylight (hours, region-centroid lat)", bestLag: 0,
      n: 110, correlation: -0.08, pValue: 0.4, rateHigh: 60, rateLow: 61, rateRatio: 0.98,
      belowMinN: false, fdrSurvivor: false,
      lagProfile: [{ lag: -1, r: -0.02, n: 108 }, { lag: 0, r: -0.08, n: 110 }, { lag: 1, r: -0.05, n: 109 }] },
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

test("renders a sub-0.001 p-value as <0.001, not 0", () => {
  const md = formatDashboard(res);
  expect(md).toContain("<0.001");          // the p=4e-7 survivor row
  expect(md).not.toMatch(/\| 0 \| ✓/);     // never display a rounded-to-zero p
});

test("emits Obsidian Charts blocks (ranked |r| bar + lag profile) and keeps the table", () => {
  const md = formatDashboard(res);
  expect(md).toContain("```chart");
  expect(md).toContain("type: bar");
  expect(md).toContain("indexAxis: y");          // horizontal ranked-|r| bar
  expect(md).toContain("type: line");            // per-signal lag profile
  expect(md).toContain("| series | factor |");   // table retained alongside charts
});

test("ranked bar marks FDR survivors with a ✓ in the label", () => {
  const md = formatDashboard(res);
  expect(md).toMatch(/✓ sleep_hours/);
});

test("fmtP boundaries: 0.001 renders literally, a tiny p and exact 0 render <0.001", () => {
  const mk = (pValue: number): DashboardResult => ({
    rows: [{ series: "s", factor: "f", bestLag: 0, n: 50, correlation: 0.5, pValue,
      rateHigh: 1, rateLow: 1, rateRatio: 1, belowMinN: false, fdrSurvivor: true,
      lagProfile: [{ lag: 0, r: 0.5, n: 50 }] }],
    testCount: 1, pairCount: 1, lagCount: 1, fdrQ: 0.1, survivorCount: 1, familySize: 1,
  });
  expect(formatDashboard(mk(0.001))).toContain("| 0.001 |");   // boundary: not <0.001
  expect(formatDashboard(mk(0.0009))).toContain("<0.001");      // just inside
  expect(formatDashboard(mk(0))).toContain("<0.001");           // exact 0 (r=±1) — never "0"
});

test("lag-profile line emits literal null for undefined-r lags (renders a gap)", () => {
  const withNull: DashboardResult = {
    rows: [{ series: "s", factor: "f", bestLag: 0, n: 40, correlation: 0.3, pValue: 0.01,
      rateHigh: 1, rateLow: 1, rateRatio: 1, belowMinN: false, fdrSurvivor: true,
      lagProfile: [{ lag: -1, r: null, n: 5 }, { lag: 0, r: 0.3, n: 40 }, { lag: 1, r: 0.2, n: 39 }] }],
    testCount: 3, pairCount: 1, lagCount: 3, fdrQ: 0.1, survivorCount: 1, familySize: 1,
  };
  const md = formatDashboard(withNull);
  expect(md).toContain("type: line");
  expect(md).toMatch(/data: \[null,/);   // null token, not NaN/empty
  expect(md).not.toContain("NaN");
});

test("lag-profile chart caps at the top signals (survivors-first ordering preserved)", () => {
  // 6 interpretable rows pre-sorted survivors-first by analyze; the lag chart must
  // draw at most LAG_CHART_MAX (4) line series.
  const mkRow = (i: number, surv: boolean): DashboardResult["rows"][number] => ({
    series: `s${i}`, factor: "f", bestLag: 0, n: 50, correlation: 0.5 - i * 0.05,
    pValue: 0.001, rateHigh: 1, rateLow: 1, rateRatio: 1, belowMinN: false, fdrSurvivor: surv,
    lagProfile: [{ lag: -1, r: 0.1, n: 50 }, { lag: 0, r: 0.5 - i * 0.05, n: 50 }, { lag: 1, r: 0.2, n: 50 }],
  });
  const many: DashboardResult = {
    rows: [mkRow(0, true), mkRow(1, false), mkRow(2, false), mkRow(3, false), mkRow(4, false), mkRow(5, false)],
    testCount: 18, pairCount: 6, lagCount: 3, fdrQ: 0.1, survivorCount: 1, familySize: 6,
  };
  const md = formatDashboard(many);
  const lineBlock = md.slice(md.indexOf("## Lag profiles"));
  expect((lineBlock.match(/^  - title:/gm) ?? []).length).toBe(4);   // capped at 4
});

test("no chart blocks when no row is interpretable (table still renders)", () => {
  const onlyBelowMin: DashboardResult = {
    rows: [{ series: "s", factor: "f", bestLag: 0, n: 3, correlation: 0.9, pValue: null,
      rateHigh: 1, rateLow: 1, rateRatio: 1, belowMinN: true, fdrSurvivor: false,
      lagProfile: [{ lag: 0, r: 0.9, n: 3 }] }],
    testCount: 1, pairCount: 1, lagCount: 1, fdrQ: 0.1, survivorCount: 0, familySize: 0,
  };
  const md = formatDashboard(onlyBelowMin);
  expect(md).toContain("| series | factor |");   // table present
  expect(md).not.toContain("```chart");            // no chart for un-interpretable data
});
