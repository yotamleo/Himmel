import { test, expect } from "bun:test";
import { join } from "path";
import {
  parseLocationCsv, loadLocation, nearestCell, resolveFactorSeries, type LocationDay,
} from "../src/proximity";
import type { FactorCache, CachedCell } from "../src/fetchFactors";

const FIXTURES = join(import.meta.dir, "fixtures");

const CELLS: CachedCell[] = [
  { lat: 52, lon: 13, daily: [{ date: "2024-06-14", mean: 1012, min: 1009, max: 1016 }] }, // Berlin-ish
  { lat: 48, lon: 11, daily: [{ date: "2024-06-15", mean: 1008, min: 1005, max: 1010 }] }, // Munich-ish
];
const CACHE: FactorCache = {
  factor: "pressure", field: "pressure_msl", unit: "hPa", metric: "min",
  label: "barometric pressure (daily min, hPa)",
  bbox: { latMin: 47, lonMin: 5, latMax: 55, lonMax: 15 },
  dateRange: { start: "2024-06-14", end: "2024-06-15" },
  cells: CELLS,
};

test("parseLocationCsv parses date,lat,lon rows", () => {
  expect(parseLocationCsv("date,lat,lon\n2024-06-14,52.1,13.2\n")).toEqual([
    { date: "2024-06-14", lat: 52.1, lon: 13.2 },
  ]);
});

test("parseLocationCsv rejects a non-ISO date and non-numeric coords", () => {
  expect(() => parseLocationCsv("date,lat,lon\n06/14/2024,52,13\n")).toThrow(/non-ISO/);
  expect(() => parseLocationCsv("date,lat,lon\n2024-06-14,north,13\n")).toThrow(/non-numeric/);
  expect(() => parseLocationCsv("lat,lon\n52,13\n")).toThrow(/missing date\/lat\/lon/);
});

test("loadLocation reads a local CSV file", async () => {
  const loc = await loadLocation(join(FIXTURES, "location-sample.csv"));
  expect(loc).toEqual([
    { date: "2024-06-14", lat: 52.1, lon: 13.2 },
    { date: "2024-06-15", lat: 48.2, lon: 11.6 },
  ]);
});

test("loadLocation throws a clear error when the file is absent", async () => {
  await expect(loadLocation(join(FIXTURES, "no-such-location.csv"))).rejects.toThrow(/location file not found/);
});

test("nearestCell picks the geographically closest cell", () => {
  expect(nearestCell(52.1, 13.2, CELLS)).toBe(CELLS[0]); // near Berlin cell
  expect(nearestCell(48.2, 11.6, CELLS)).toBe(CELLS[1]); // near Munich cell
});

test("nearestCell cos-lat weighting changes the winner at high latitude", () => {
  // At lat 60 (cos=0.5), the 3°-lon-away cell A is closer than the 2°-lat-away cell
  // B once longitude is shrunk by cos(lat): naive picks B (4 < 9), weighted picks A
  // (2.25 < 4). This pins the cos-lat term — naive Euclidean would fail it.
  const A: CachedCell = { lat: 60, lon: 13, daily: [] };
  const B: CachedCell = { lat: 62, lon: 10, daily: [] };
  expect(nearestCell(60, 10, [A, B])).toBe(A);
});

test("nearestCell throws when the cache has no cells", () => {
  expect(() => nearestCell(52, 13, [])).toThrow(/no cells/);
});

test("resolveFactorSeries picks the nearest cell's VALUE among many same-date cells", () => {
  // 3 cells all carrying the same date but different mins; a wrong nearest pick
  // yields a wrong value (not just a drop).
  const multi: FactorCache = {
    ...CACHE,
    cells: [
      { lat: 52, lon: 13, daily: [{ date: "2024-06-14", mean: 0, min: 1000, max: 0 }] },
      { lat: 48, lon: 11, daily: [{ date: "2024-06-14", mean: 0, min: 1010, max: 0 }] },
      { lat: 50, lon: 12, daily: [{ date: "2024-06-14", mean: 0, min: 1005, max: 0 }] },
    ],
  };
  const loc: LocationDay[] = [
    { date: "2024-06-14", lat: 51.8, lon: 12.9 }, // nearest (52,13) -> 1000
    { date: "2024-06-14", lat: 48.1, lon: 11.1 }, // nearest (48,11) -> 1010
  ];
  expect(resolveFactorSeries(loc, multi)).toEqual([
    { date: "2024-06-14", value: 1000 },
    { date: "2024-06-14", value: 1010 },
  ]);
});

test("resolveFactorSeries maps each location-day to its nearest cell's daily metric", () => {
  const loc: LocationDay[] = [
    { date: "2024-06-14", lat: 52.1, lon: 13.2 }, // -> Berlin cell, min 1009
    { date: "2024-06-15", lat: 48.2, lon: 11.6 }, // -> Munich cell, min 1005
  ];
  expect(resolveFactorSeries(loc, CACHE)).toEqual([
    { date: "2024-06-14", value: 1009 },
    { date: "2024-06-15", value: 1005 },
  ]);
});

test("resolveFactorSeries drops days the nearest cell has no value for", () => {
  // location-day on a date the nearest (Berlin) cell never cached -> dropped.
  const loc: LocationDay[] = [{ date: "2024-06-15", lat: 52.1, lon: 13.2 }];
  expect(resolveFactorSeries(loc, CACHE)).toEqual([]);
});
