import { test, expect } from "bun:test";
import { join } from "path";
import { loadSeries, resolveSeriesDir } from "../src/loadSeries";

const FIXTURES = join(import.meta.dir, "fixtures");

test("loadSeries reads + parses a named series from an explicit dir", async () => {
  const pts = await loadSeries("pain-fixture", FIXTURES);
  expect(pts[0]).toEqual({ date: "2026-05-01", value: 2 });
  expect(pts.length).toBe(10);
});

test("loadSeries works for sleep + stress series", async () => {
  expect((await loadSeries("sleep-fixture", FIXTURES))[2]).toEqual({ date: "2026-05-03", value: 5.5 });
  expect((await loadSeries("stress-fixture", FIXTURES))[2]).toEqual({ date: "2026-05-03", value: 7 });
});

test("loadSeries throws a clear error for a missing series file", async () => {
  await expect(loadSeries("nope", FIXTURES)).rejects.toThrow(/series file not found/);
});

test("loadSeries rejects a name containing a path separator or ..", async () => {
  await expect(loadSeries("../secret", FIXTURES)).rejects.toThrow(/invalid series name/);
  await expect(loadSeries("a/b", FIXTURES)).rejects.toThrow(/invalid series name/);
});

test("resolveSeriesDir prefers the explicit dir, else LUNA_SERIES_DIR, else throws", () => {
  expect(resolveSeriesDir("/tmp/x")).toBe("/tmp/x");
  const saved = process.env.LUNA_SERIES_DIR;
  try {
    process.env.LUNA_SERIES_DIR = "/env/dir";
    expect(resolveSeriesDir()).toBe("/env/dir");
    delete process.env.LUNA_SERIES_DIR;
    expect(() => resolveSeriesDir()).toThrow(/LUNA_SERIES_DIR/);
  } finally {
    if (saved === undefined) delete process.env.LUNA_SERIES_DIR;
    else process.env.LUNA_SERIES_DIR = saved;
  }
});
