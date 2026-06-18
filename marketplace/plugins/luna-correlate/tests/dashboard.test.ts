import { expect, test } from "bun:test";
import { mkdtempSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { signalsDashboardLogic } from "../src/mcp";

test("dashboard over lunar_phase writes a note + json", async () => {
  const dir = mkdtempSync(join(tmpdir(), "lc-series-"));
  const out = mkdtempSync(join(tmpdir(), "lc-out-"));
  // 30 daily points so n clears the default-ish min-n we pass below.
  const rows = Array.from({ length: 30 }, (_, i) => {
    const d = `2025-02-${String(i + 1).padStart(2, "0")}`;
    return `${d},${(i % 5) + 6}`;
  });
  await Bun.write(join(dir, "sleep_hours.csv"), "date,value\n" + rows.join("\n"));

  const res = await signalsDashboardLogic({
    seriesNames: ["sleep_hours"], factors: ["lunar_phase"],
    lagWindow: 1, minN: 10, dir, outDir: out,
  });
  expect(res.outPath).toBe(join(out, "dashboard.md"));
  expect(res.jsonPath).toBe(join(out, "dashboard.json"));
  expect(res.markdown).toContain("lunar illumination");
  expect(await Bun.file(join(out, "dashboard.md")).exists()).toBe(true);
  expect(await Bun.file(join(out, "dashboard.json")).exists()).toBe(true);
  // sleep_hours is era-split; all 30 points are post-boundary → one era row.
  const parsed = JSON.parse(await Bun.file(join(out, "dashboard.json")).text());
  expect(parsed.rows[0].series).toContain("sleep_hours");
  expect(parsed.survivorCount).toBeGreaterThanOrEqual(0);
  // One post-boundary era × one factor (lunar_phase) = 1 row expected.
  expect(parsed.rows.length).toBe(1);
});

test("daylight reads per-day latitude from the location file when provided", async () => {
  const dir = mkdtempSync(join(tmpdir(), "lc-series-"));
  const out = mkdtempSync(join(tmpdir(), "lc-out-"));
  const locFile = join(mkdtempSync(join(tmpdir(), "lc-loc-")), "_location.csv");
  const days = Array.from({ length: 30 }, (_, i) => `2025-02-${String(i + 1).padStart(2, "0")}`);
  // hrv_ms is NOT era-split → one clean row; location = Berlin every day.
  await Bun.write(join(dir, "hrv_ms.csv"), "date,value\n" + days.map((d, i) => `${d},${40 + (i % 10)}`).join("\n"));
  await Bun.write(locFile, "date,lat,lon\n" + days.map(d => `${d},52.5,13.4`).join("\n"));

  const res = await signalsDashboardLogic({
    seriesNames: ["hrv_ms"], factors: ["daylight"],
    lagWindow: 1, minN: 10, dir, outDir: out, location: locFile,
  });
  // The per-day-latitude label proves the location-file path, not the centroid fallback.
  expect(res.markdown).toContain("per-day latitude");
  const parsed = JSON.parse(await Bun.file(join(out, "dashboard.json")).text());
  expect(parsed.rows.length).toBe(1);
  expect(parsed.rows[0].n).toBeGreaterThanOrEqual(10);
  expect(parsed.rows[0].lagProfile.length).toBeGreaterThan(0);   // chart source data persisted
});

test("daylight falls back to the region centroid when no location file is given", async () => {
  const dir = mkdtempSync(join(tmpdir(), "lc-series-"));
  const out = mkdtempSync(join(tmpdir(), "lc-out-"));
  const days = Array.from({ length: 30 }, (_, i) => `2025-02-${String(i + 1).padStart(2, "0")}`);
  await Bun.write(join(dir, "hrv_ms.csv"), "date,value\n" + days.map((d, i) => `${d},${40 + (i % 10)}`).join("\n"));

  const res = await signalsDashboardLogic({
    seriesNames: ["hrv_ms"], factors: ["daylight"],
    lagWindow: 1, minN: 10, dir, outDir: out, region: "47,5,55,15",  // no location → centroid arm
  });
  expect(res.markdown).toContain("region-centroid lat");   // proves the fallback arm
  const parsed = JSON.parse(await Bun.file(join(out, "dashboard.json")).text());
  expect(parsed.rows.length).toBe(1);
});

test("daylight throws when neither a location file nor a region is available", async () => {
  const dir = mkdtempSync(join(tmpdir(), "lc-series-"));
  const out = mkdtempSync(join(tmpdir(), "lc-out-"));
  const days = Array.from({ length: 30 }, (_, i) => `2025-02-${String(i + 1).padStart(2, "0")}`);
  await Bun.write(join(dir, "hrv_ms.csv"), "date,value\n" + days.map((d, i) => `${d},${40 + (i % 10)}`).join("\n"));
  const savedLoc = process.env.LUNA_LOCATION_FILE, savedBbox = process.env.LUNA_REGION_BBOX;
  delete process.env.LUNA_LOCATION_FILE; delete process.env.LUNA_REGION_BBOX;
  try {
    await expect(signalsDashboardLogic({
      seriesNames: ["hrv_ms"], factors: ["daylight"], lagWindow: 1, minN: 10, dir, outDir: out,
    })).rejects.toThrow(/daylight needs a location file/);
  } finally {
    if (savedLoc !== undefined) process.env.LUNA_LOCATION_FILE = savedLoc;
    if (savedBbox !== undefined) process.env.LUNA_REGION_BBOX = savedBbox;
  }
});

test("daylight throws on an empty (header-only) location file", async () => {
  const dir = mkdtempSync(join(tmpdir(), "lc-series-"));
  const out = mkdtempSync(join(tmpdir(), "lc-out-"));
  const locFile = join(mkdtempSync(join(tmpdir(), "lc-loc-")), "_location.csv");
  const days = Array.from({ length: 30 }, (_, i) => `2025-02-${String(i + 1).padStart(2, "0")}`);
  await Bun.write(join(dir, "hrv_ms.csv"), "date,value\n" + days.map((d, i) => `${d},${40 + (i % 10)}`).join("\n"));
  await Bun.write(locFile, "date,lat,lon\n");  // header only, no data rows
  await expect(signalsDashboardLogic({
    seriesNames: ["hrv_ms"], factors: ["daylight"], lagWindow: 1, minN: 10, dir, outDir: out, location: locFile,
  })).rejects.toThrow(/has no data rows/);
});

test("resolveSignalsDir throws when unset", async () => {
  const { resolveSignalsDir } = await import("../src/mcp");
  const saved = process.env.LUNA_SIGNALS_DIR;
  delete process.env.LUNA_SIGNALS_DIR;
  expect(() => resolveSignalsDir()).toThrow(/signals dir unset/);
  if (saved !== undefined) process.env.LUNA_SIGNALS_DIR = saved;
});
