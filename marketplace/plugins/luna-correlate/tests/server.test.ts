import { test, expect } from "bun:test";
import { join } from "path";
import {
  factorsCacheLogic,
  seriesLoadLogic,
  correlateLogic,
  signalsReportLogic,
  loadCachedFactor,
  loadFactorCache,
} from "../src/mcp";
import { factorCachePath } from "../src/fetchFactors";
import { TOOLS, callTool } from "../server";
import { tmpdir } from "os";

const FIXTURES = join(import.meta.dir, "fixtures");
const archiveFetch = (async () =>
  new Response(await Bun.file(join(FIXTURES, "open-meteo-archive-sample.json")).text())
) as unknown as typeof fetch;
const GFZ_ROW =
  "2026 05 01 34089 34089.5 2607  1  5.000  4.667  4.333  3.667  3.000  2.667  3.333  4.000   48   39   32   22   15   12   18   27     8 160    170.0    175.0 2";

test("factorsCacheLogic caches via injected fetch and rejects unknown factors", async () => {
  const fake = async () => new Response(GFZ_ROW + "\n");
  const r = await factorsCacheLogic({ factor: "kp", fetchImpl: fake as unknown as typeof fetch });
  expect(r.cached).toBe(1);
  await expect(factorsCacheLogic({ factor: "weather" })).rejects.toThrow(/unsupported factor/);
});

test("seriesLoadLogic loads a named series with a count", async () => {
  const r = await seriesLoadLogic({ name: "pain-fixture", dir: FIXTURES });
  expect(r.n).toBe(10);
  expect(r.points[0]).toEqual({ date: "2026-05-01", value: 2 });
});

test("correlateLogic joins a loaded series against the cached factor", async () => {
  // Seed the cache first (factor on 2026-05-01).
  await factorsCacheLogic({
    factor: "kp",
    fetchImpl: (async () => new Response(GFZ_ROW + "\n")) as unknown as typeof fetch,
  });
  const sig = await correlateLogic({ series: "migraine-fixture", lag: 0, dir: FIXTURES });
  expect(sig.factor).toBe("Kp-index");
  expect(sig.series).toBe("migraine-fixture");
  expect(sig.n).toBeGreaterThan(0);
});

test("factorsCacheLogic routes a location factor to the region-grid fetcher", async () => {
  const r = await factorsCacheLogic({
    factor: "pressure",
    region: "48,11,52,13", // covers the location-sample.csv coords
    dateRange: { start: "2024-06-14", end: "2024-06-15" },
    fetchImpl: archiveFetch,
  });
  expect(r.factor).toBe("pressure");
  expect(r.cells).toBe(5 * 3); // lat 48..52, lon 11..13 inclusive
});

test("factorsCacheLogic requires a dateRange for location factors", async () => {
  await expect(factorsCacheLogic({ factor: "pressure", region: "48,11,52,13" })).rejects.toThrow(/requires a dateRange/);
});

test("correlateLogic joins a series against a location factor via the proximity index", async () => {
  await factorsCacheLogic({
    factor: "pressure", region: "48,11,52,13",
    dateRange: { start: "2024-06-14", end: "2024-06-15" }, fetchImpl: archiveFetch,
  });
  const sig = await correlateLogic({
    series: "location-series-fixture", factor: "pressure",
    dir: FIXTURES, location: join(FIXTURES, "location-sample.csv"),
  });
  expect(sig.factor).toBe("barometric pressure (daily min, hPa)");
  expect(sig.series).toBe("location-series-fixture");
  expect(sig.n).toBe(2); // both operator location-days resolved to a cached cell value
});

test("correlateLogic on a location factor applies the day lag", async () => {
  await factorsCacheLogic({
    factor: "pressure", region: "48,11,52,13",
    dateRange: { start: "2024-06-14", end: "2024-06-15" }, fetchImpl: archiveFetch,
  });
  // lag 1: factor day d joins series day d+1. Factor has 06-14 + 06-15; only
  // 06-14 -> series 06-15 lands (06-15 -> 06-16 is absent), so n=1.
  const sig = await correlateLogic({
    series: "location-series-fixture", factor: "pressure", lag: 1,
    dir: FIXTURES, location: join(FIXTURES, "location-sample.csv"),
  });
  expect(sig.n).toBe(1);
  expect(sig.lagDays).toBe(1);
});

test("correlateLogic fails loud when no location-day joins to a cached cell-date", async () => {
  await factorsCacheLogic({
    factor: "pressure", region: "48,11,52,13",
    dateRange: { start: "2024-06-14", end: "2024-06-15" }, fetchImpl: archiveFetch,
  });
  await expect(correlateLogic({
    series: "location-series-fixture", factor: "pressure",
    dir: FIXTURES, location: join(FIXTURES, "location-nomatch.csv"), // 2024-07 dates
  })).rejects.toThrow(/none of 2 location-days joined/);
});

test("loadFactorCache rejects a malformed cache file", async () => {
  await Bun.write(factorCachePath("aq"), JSON.stringify({ factor: "aq" })); // no cells/metric
  await expect(loadFactorCache("aq")).rejects.toThrow(/malformed/);
});

test("callTool validates the location-factor dateRange shape", async () => {
  await expect(callTool("factors.cache", { factor: "pressure", dateRange: 5 })).rejects.toThrow(/must be an object/);
});

test("server exposes exactly the 5 documented tools", () => {
  expect(TOOLS.map(t => t.name).sort()).toEqual(
    ["correlate", "factors.cache", "series.load", "signals.dashboard", "signals.report"],
  );
});

test("callTool dispatches series.load by name", async () => {
  const r = (await callTool("series.load", { name: "pain-fixture", dir: FIXTURES })) as { n: number };
  expect(r.n).toBe(10);
});

test("callTool throws on an unknown tool", async () => {
  await expect(callTool("nope", {})).rejects.toThrow(/unknown tool/);
});

test("callTool validates argument types at the MCP boundary", async () => {
  await expect(callTool("series.load", { name: 42 })).rejects.toThrow(/"name" must be a string/);
  await expect(callTool("correlate", { series: "x", lag: "2" })).rejects.toThrow(/"lag" must be a number/);
});

test("loadCachedFactor throws a clear error when the cache is absent", async () => {
  const absent = join(tmpdir(), "luna-correlate-no-such-cache-xyz.json");
  await expect(loadCachedFactor(absent)).rejects.toThrow(/factor cache not found/);
});

test("signalsReportLogic writes the note to outPath and returns it", async () => {
  await factorsCacheLogic({
    factor: "kp",
    fetchImpl: (async () => new Response(GFZ_ROW + "\n")) as unknown as typeof fetch,
  });
  const outPath = join(tmpdir(), "luna-correlate-signals-test.md");
  const r = await signalsReportLogic({ series: "migraine-fixture", lag: 0, dir: FIXTURES, outPath });
  expect(r.outPath).toBe(outPath);
  const written = await Bun.file(outPath).text();
  expect(written).toBe(r.markdown);
  expect(written.toLowerCase()).toContain("not a diagnosis");
});

test("signalsReportLogic returns markdown with the never-diagnose disclaimer", async () => {
  await factorsCacheLogic({
    factor: "kp",
    fetchImpl: (async () => new Response(GFZ_ROW + "\n")) as unknown as typeof fetch,
  });
  const r = await signalsReportLogic({ series: "migraine-fixture", lag: 0, dir: FIXTURES });
  expect(r.markdown.toLowerCase()).toContain("not a diagnosis");
  expect(r.markdown).toContain("Kp-index");
});
