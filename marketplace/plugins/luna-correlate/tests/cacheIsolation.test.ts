import { test, expect } from "bun:test";
import { join } from "path";
import { existsSync, readFileSync } from "fs";
import { fetchKpToCache } from "../src/fetchKp";
import { fetchFactorToCache } from "../src/fetchFactors";

// HIMMEL-370: the operator's real cache lives at marketplace/plugins/luna-correlate/cache/.
// These paths are hardcoded (not imported from src) so the assertion holds independently
// of whatever cache-location logic is under test.
const OPERATOR_KP_CACHE = join(import.meta.dir, "..", "cache", "kp.json");
const OPERATOR_PRESSURE_CACHE = join(import.meta.dir, "..", "cache", "pressure.json");

function snapshot(path: string): Buffer | null {
  return existsSync(path) ? readFileSync(path) : null;
}

test("fetchKpToCache never touches the operator's Kp cache", async () => {
  const before = snapshot(OPERATOR_KP_CACHE);
  const fake = async () => new Response("2026-05-01 1 2 3\n");
  await fetchKpToCache({ fetchImpl: fake as unknown as typeof fetch });
  expect(snapshot(OPERATOR_KP_CACHE)).toEqual(before);
});

test("fetchFactorToCache never touches the operator's factor cache", async () => {
  const before = snapshot(OPERATOR_PRESSURE_CACHE);
  const fake = async () => new Response(JSON.stringify({ hourly: { time: ["2024-06-14T00:00"], pressure_msl: [1000] } }));
  await fetchFactorToCache({
    factor: "pressure",
    bbox: "52,13,52,13",
    dateRange: { start: "2024-06-14", end: "2024-06-14" },
    fetchImpl: fake as unknown as typeof fetch,
  });
  expect(snapshot(OPERATOR_PRESSURE_CACHE)).toEqual(before);
});
