import { expect, test } from "bun:test";
import { splitEra, GALAXY_BOUNDARY } from "../src/era";

const pts = [
  { date: "2024-06-01", value: 7 },
  { date: "2024-12-31", value: 6 },
  { date: "2025-02-01", value: 8 },
  { date: "2025-03-01", value: 7.5 },
];

test("splits at the Galaxy boundary into two named eras", () => {
  const eras = splitEra("sleep_hours", pts);
  expect(eras).toHaveLength(2);
  expect(eras[0].name).toBe(`sleep_hours (pre ${GALAXY_BOUNDARY})`);
  expect(eras[0].points.map(p => p.date)).toEqual(["2024-06-01", "2024-12-31"]);
  expect(eras[1].name).toBe(`sleep_hours (${GALAXY_BOUNDARY}+)`);
  expect(eras[1].points.map(p => p.date)).toEqual(["2025-02-01", "2025-03-01"]);
});

test("a single-era series yields one entry (no empty era)", () => {
  const galaxyOnly = [{ date: "2025-02-01", value: 40 }, { date: "2025-03-01", value: 42 }];
  const eras = splitEra("hrv_ms", galaxyOnly);
  expect(eras).toHaveLength(1);
  expect(eras[0].name).toBe(`hrv_ms (${GALAXY_BOUNDARY}+)`);
});
