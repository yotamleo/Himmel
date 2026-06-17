import { test, expect } from "bun:test";
import { parseSeriesCsv } from "../src/series";

test("parses date,value csv", () => {
  const pts = parseSeriesCsv("date,value\n2026-05-01,1\n2026-05-02,0\n");
  expect(pts).toEqual([{ date: "2026-05-01", value: 1 }, { date: "2026-05-02", value: 0 }]);
});

test("throws on empty / comment-only csv", () => {
  expect(() => parseSeriesCsv("")).toThrow(/no header/);
  expect(() => parseSeriesCsv("# only a comment\n")).toThrow(/no header/);
});

test("throws on missing date/value header (no silent NaN rows)", () => {
  expect(() => parseSeriesCsv("day,migraine\n2026-05-01,1\n")).toThrow(/missing date\/value header/);
});

test("throws on a row with a non-numeric value (no silent NaN)", () => {
  expect(() => parseSeriesCsv("date,value\n2026-05-01,1\n2026-05-02,abc\n")).toThrow(/non-numeric value/);
});

test("throws on a row with an empty date cell", () => {
  expect(() => parseSeriesCsv("date,value\n,1\n")).toThrow(/empty date/);
});

test("throws on a non-ISO date (would silently never join)", () => {
  expect(() => parseSeriesCsv("date,value\n05/01/2026,1\n")).toThrow(/non-ISO/);
  expect(() => parseSeriesCsv("date,value\n2026-5-1,1\n")).toThrow(/non-ISO/);
});

test("resolves date/value by header name regardless of column order", () => {
  expect(parseSeriesCsv("value,date\n1,2026-05-01\n")).toEqual([{ date: "2026-05-01", value: 1 }]);
});
