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

test("resolveSignalsDir throws when unset", async () => {
  const { resolveSignalsDir } = await import("../src/mcp");
  const saved = process.env.LUNA_SIGNALS_DIR;
  delete process.env.LUNA_SIGNALS_DIR;
  expect(() => resolveSignalsDir()).toThrow(/signals dir unset/);
  if (saved !== undefined) process.env.LUNA_SIGNALS_DIR = saved;
});
