import { expect, test } from "bun:test";
import { join } from "path";
import { aggregateHourly } from "../src/openMeteo";

const FIXTURES = join(import.meta.dir, "fixtures");

test("air-quality pm2_5 fixture aggregates to daily means", async () => {
  const fx = JSON.parse(await Bun.file(join(FIXTURES, "air-quality-pm25.json")).text());
  const daily = aggregateHourly(fx.hourly.time, fx.hourly.pm2_5);
  expect(daily.length).toBeGreaterThan(0);
  expect(daily[0].date).toBe("2026-06-08");
  for (const d of daily) {
    expect(d.date).toMatch(/^\d{4}-\d{2}-\d{2}$/);
    expect(Number.isNaN(d.mean)).toBe(false);
  }
});

test("air-quality grass_pollen fixture aggregates to daily means", async () => {
  const fx = JSON.parse(await Bun.file(join(FIXTURES, "air-quality-pm25.json")).text());
  const daily = aggregateHourly(fx.hourly.time, fx.hourly.grass_pollen);
  expect(daily.length).toBeGreaterThan(0);
  for (const d of daily) {
    expect(d.date).toMatch(/^\d{4}-\d{2}-\d{2}$/);
    expect(Number.isNaN(d.mean)).toBe(false);
  }
});
