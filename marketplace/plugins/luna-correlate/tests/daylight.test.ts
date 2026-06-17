import { expect, test } from "bun:test";
import { daylightHours, daylightSeries, bboxCentroidLat } from "../src/daylight";

test("equinox ≈ 12h at any latitude", () => {
  expect(daylightHours("2025-03-20", 50)).toBeCloseTo(12, 0);
  expect(daylightHours("2025-09-22", 10)).toBeCloseTo(12, 0);
});

test("summer solstice longer at mid-latitude than equator", () => {
  expect(daylightHours("2025-06-21", 50)).toBeGreaterThan(15);
  expect(daylightHours("2025-06-21", 0)).toBeCloseTo(12, 0);
});

test("winter solstice shorter than summer at mid-latitude", () => {
  expect(daylightHours("2025-12-21", 50)).toBeLessThan(daylightHours("2025-06-21", 50));
});

test("bboxCentroidLat averages the lat bounds", () => {
  // "lat_min,lon_min,lat_max,lon_max"
  expect(bboxCentroidLat("47,5,55,15")).toBe(51);
});

test("daylightSeries maps dates at a fixed lat", () => {
  const s = daylightSeries(["2025-06-21", "2025-12-21"], 50);
  expect(s.map(p => p.date)).toEqual(["2025-06-21", "2025-12-21"]);
  expect(s[0].value).toBeGreaterThan(s[1].value);
});

test("polar clamps — night and midnight sun", () => {
  expect(daylightHours("2025-12-21", 85)).toBe(0);   // polar night
  expect(daylightHours("2025-06-21", 85)).toBe(24);  // polar day
});
