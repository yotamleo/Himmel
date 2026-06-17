import { test, expect } from "bun:test";
import { join } from "path";
import { aggregateHourly, parseOpenMeteoHourly } from "../src/openMeteo";

const FIXTURES = join(import.meta.dir, "fixtures");

test("aggregateHourly groups by UTC date -> mean/min/max", () => {
  const time = [
    "2024-06-14T00:00", "2024-06-14T12:00", "2024-06-14T23:00",
    "2024-06-15T00:00", "2024-06-15T06:00",
  ];
  const vals = [1010, 1000, 1020, 990, 1010];
  expect(aggregateHourly(time, vals)).toEqual([
    { date: "2024-06-14", mean: 1010, min: 1000, max: 1020 },
    { date: "2024-06-15", mean: 1000, min: 990, max: 1010 },
  ]);
});

test("aggregateHourly skips null/NaN samples and drops all-null days", () => {
  const time = ["2024-06-14T00:00", "2024-06-14T01:00", "2024-06-15T00:00"];
  const vals = [1010, null, null];
  expect(aggregateHourly(time, vals)).toEqual([
    { date: "2024-06-14", mean: 1010, min: 1010, max: 1010 },
  ]);
});

test("aggregateHourly throws when the hourly arrays are misaligned", () => {
  expect(() => aggregateHourly(["2024-06-14T00:00"], [1, 2])).toThrow(/misaligned/);
});

test("parseOpenMeteoHourly: real archive fixture -> correct daily pressure aggregates", async () => {
  const json = await Bun.file(join(FIXTURES, "open-meteo-archive-sample.json")).json();
  const daily = parseOpenMeteoHourly(json, "pressure_msl");
  expect(daily.map(d => d.date)).toEqual(["2024-06-14", "2024-06-15"]);
  // 2024-06-14: 24 hourly hPa samples, real values from the captured response.
  expect(daily[0].min).toBeCloseTo(1009.5, 5);
  expect(daily[0].max).toBeCloseTo(1016.1, 5);
  expect(daily[0].mean).toBeCloseTo(1012.8792, 3);
  // 2024-06-15 shows the front-passage pressure drop (daily-min much lower).
  expect(daily[1].min).toBeCloseTo(1005.4, 5);
  expect(daily[1].max).toBeCloseTo(1010.0, 5);
});

test("parseOpenMeteoHourly throws when hourly.<field> is absent", async () => {
  const json = { hourly: { time: ["2024-06-14T00:00"] } };
  expect(() => parseOpenMeteoHourly(json, "pressure_msl")).toThrow(/missing hourly\.pressure_msl/);
});

test("parseOpenMeteoHourly throws when hourly.time is absent", () => {
  expect(() => parseOpenMeteoHourly({ hourly: {} }, "pressure_msl")).toThrow(/missing hourly\.time/);
});

test("aggregateHourly throws on a non-ISO timestamp (would silently never join)", () => {
  expect(() => aggregateHourly(["06/14/2024 00:00"], [1010])).toThrow(/not ISO/);
});

test("aggregateHourly returns [] for empty input", () => {
  expect(aggregateHourly([], [])).toEqual([]);
});
