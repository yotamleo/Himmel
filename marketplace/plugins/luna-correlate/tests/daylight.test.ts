import { expect, test } from "bun:test";
import { daylightHours, daylightSeries, bboxCentroidLat, daylightSeriesFromLocation } from "../src/daylight";

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

test("daylightSeriesFromLocation maps each location-day at its own latitude", () => {
  const s = daylightSeriesFromLocation([
    { date: "2025-06-21", lat: 52.5, lon: 13.4 },  // Berlin summer
    { date: "2025-12-21", lat: 52.5, lon: 13.4 },  // Berlin winter
  ]);
  expect(s.map(p => p.date)).toEqual(["2025-06-21", "2025-12-21"]);
  expect(s[0].value).toBeGreaterThan(s[1].value);   // summer > winter
});

test("daylightSeriesFromLocation reads per-row latitude (not one fixed centroid)", () => {
  // Same date, different latitudes: a high-latitude summer day is longer than the
  // equator's. This is exactly what a fixed region-centroid would get wrong.
  const s = daylightSeriesFromLocation([
    { date: "2025-06-21", lat: 52.5, lon: 13.4 },   // Berlin
    { date: "2025-06-21", lat: 0, lon: 0 },          // equator
  ]);
  expect(s[0].value).toBeGreaterThan(s[1].value);
});
