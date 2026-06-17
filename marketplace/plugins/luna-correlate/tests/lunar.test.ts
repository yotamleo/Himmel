import { expect, test } from "bun:test";
import { lunarIllumination, lunarPhaseSeries } from "../src/lunar";

test("known full moon ~1.0, known new moon ~0.0", () => {
  // 2000-01-21 was a full moon (~15 days after the 2000-01-06 new moon anchor).
  expect(lunarIllumination("2000-01-21")).toBeGreaterThan(0.9);
  // 2000-01-06 is the new-moon anchor.
  expect(lunarIllumination("2000-01-06")).toBeLessThan(0.05);
});

test("illumination stays within [0,1]", () => {
  for (const d of ["2024-03-01", "2025-07-15", "2026-06-17"]) {
    const v = lunarIllumination(d);
    expect(v).toBeGreaterThanOrEqual(0);
    expect(v).toBeLessThanOrEqual(1);
  }
});

test("lunarPhaseSeries maps each date", () => {
  const s = lunarPhaseSeries(["2026-06-17", "2026-06-18"]);
  expect(s.map(p => p.date)).toEqual(["2026-06-17", "2026-06-18"]);
  expect(typeof s[0].value).toBe("number");
});
