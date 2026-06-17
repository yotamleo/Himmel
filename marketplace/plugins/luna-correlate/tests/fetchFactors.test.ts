import { test, expect } from "bun:test";
import { join } from "path";
import {
  parseBbox, gridCells, fetchFactorToCache, factorCachePath, FACTOR_CONFIG,
} from "../src/fetchFactors";

const FIXTURES = join(import.meta.dir, "fixtures");
async function archiveFixture(): Promise<unknown> {
  return Bun.file(join(FIXTURES, "open-meteo-archive-sample.json")).json();
}

test("parseBbox parses the LUNA_REGION_BBOX shape", () => {
  expect(parseBbox("47,5,55,15")).toEqual({ latMin: 47, lonMin: 5, latMax: 55, lonMax: 15 });
});

test("parseBbox rejects malformed / inverted bboxes", () => {
  expect(() => parseBbox("47,5,55")).toThrow(/expected/);
  expect(() => parseBbox("a,b,c,d")).toThrow(/expected/);
  expect(() => parseBbox("55,5,47,15")).toThrow(/min > max/);
});

test("gridCells covers the bbox inclusively at 1 deg spacing", () => {
  const cells = gridCells({ latMin: 47, lonMin: 5, latMax: 55, lonMax: 15 }, 1);
  expect(cells.length).toBe(9 * 11); // lat 47..55 inclusive, lon 5..15 inclusive
  expect(cells[0]).toEqual({ lat: 47, lon: 5 });
  expect(cells[cells.length - 1]).toEqual({ lat: 55, lon: 15 });
});

test("gridCells handles a single-cell bbox", () => {
  expect(gridCells({ latMin: 52, lonMin: 13, latMax: 52, lonMax: 13 }, 1)).toEqual([{ lat: 52, lon: 13 }]);
});

test("fetchFactorToCache: iterates the grid, caches per cell, sends country-grid coords only", async () => {
  const requested: Array<{ lat: number; lon: number }> = [];
  const fake = async (url: string | URL): Promise<Response> => {
    const u = new URL(url);
    requested.push({ lat: Number(u.searchParams.get("latitude")), lon: Number(u.searchParams.get("longitude")) });
    return new Response(JSON.stringify(await archiveFixture()));
  };
  const r = await fetchFactorToCache({
    factor: "pressure",
    bbox: "52,13,53,14", // 2x2 grid = 4 cells
    dateRange: { start: "2024-06-14", end: "2024-06-15" },
    fetchImpl: fake as unknown as typeof fetch,
  });
  expect(r.cells).toBe(4);
  expect(requested.length).toBe(4);
  // Boundary invariant: every request coord is a bbox grid cell — never an
  // operator point. (The operator's location never enters the fetcher.)
  for (const q of requested) {
    expect(q.lat).toBeGreaterThanOrEqual(52);
    expect(q.lat).toBeLessThanOrEqual(53);
    expect(q.lon).toBeGreaterThanOrEqual(13);
    expect(q.lon).toBeLessThanOrEqual(14);
    expect(Number.isInteger(q.lat) && Number.isInteger(q.lon)).toBe(true);
  }
  // Explicit no-leak check: the operator point in tests/fixtures/location-sample.csv
  // (52.1,13.2 — fractional, lands inside this bbox) must NEVER be requested.
  expect(requested.some(q => q.lat === 52.1 && q.lon === 13.2)).toBe(false);
  const cache = await Bun.file(factorCachePath("pressure")).json();
  expect(cache.factor).toBe("pressure");
  expect(cache.metric).toBe("min");
  expect(cache.cells.length).toBe(4);
  expect(cache.cells[0].daily.map((d: { date: string }) => d.date)).toEqual(["2024-06-14", "2024-06-15"]);
});

test("fetchFactorToCache requests pressure_msl from the archive API with timezone=UTC", async () => {
  let seen = "";
  const fake = async (url: string | URL): Promise<Response> => {
    seen = String(url);
    return new Response(JSON.stringify(await archiveFixture()));
  };
  await fetchFactorToCache({
    factor: "pressure", bbox: "52,13,52,13",
    dateRange: { start: "2024-06-14", end: "2024-06-15" },
    fetchImpl: fake as unknown as typeof fetch,
  });
  expect(seen).toContain("archive-api.open-meteo.com");
  expect(seen).toContain("hourly=pressure_msl");
  expect(seen).toContain("timezone=UTC");
});

test("fetchFactorToCache rejects an unknown location factor", async () => {
  await expect(
    fetchFactorToCache({ factor: "rainfall", bbox: "52,13,52,13", dateRange: { start: "2024-06-14", end: "2024-06-15" } }),
  ).rejects.toThrow(/unsupported location factor/);
});

test("fetchFactorToCache validates the date range", async () => {
  const noop = (async () => new Response("{}")) as unknown as typeof fetch;
  await expect(
    fetchFactorToCache({ factor: "pressure", bbox: "52,13,52,13", dateRange: { start: "2024/06/14", end: "2024-06-15" }, fetchImpl: noop }),
  ).rejects.toThrow(/ISO YYYY-MM-DD/);
  await expect(
    fetchFactorToCache({ factor: "pressure", bbox: "52,13,52,13", dateRange: { start: "2024-06-15", end: "2024-06-14" }, fetchImpl: noop }),
  ).rejects.toThrow(/start after end/);
});

test("fetchFactorToCache throws on a non-ok response", async () => {
  const fake = async () => new Response("nope", { status: 429 });
  await expect(
    fetchFactorToCache({
      factor: "pressure", bbox: "52,13,52,13",
      dateRange: { start: "2024-06-14", end: "2024-06-15" },
      fetchImpl: fake as unknown as typeof fetch,
    }),
  ).rejects.toThrow(/HTTP 429/);
});

test("fetchFactorToCache fails loud when the whole grid yields 0 daily points", async () => {
  // Parseable response (hourly.time + field present) but empty -> 0 daily points.
  const fake = async () => new Response(JSON.stringify({ hourly: { time: [], pressure_msl: [] } }));
  await expect(
    fetchFactorToCache({
      factor: "pressure", bbox: "52,13,52,13",
      dateRange: { start: "2024-06-14", end: "2024-06-15" },
      fetchImpl: fake as unknown as typeof fetch,
    }),
  ).rejects.toThrow(/0 daily points/);
});

test("FACTOR_CONFIG routes pollen/aq to the air-quality API", () => {
  expect(FACTOR_CONFIG.aq.api).toContain("air-quality-api.open-meteo.com");
  expect(FACTOR_CONFIG.pollen.api).toContain("air-quality-api.open-meteo.com");
  expect(FACTOR_CONFIG.pressure.api).toContain("archive-api.open-meteo.com");
});
