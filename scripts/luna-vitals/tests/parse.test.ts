import { test, expect } from "bun:test";
import { join } from "path";
import { parseStructured } from "../src/parse";

const FX = join(import.meta.dir, "fixtures");
const METRICS = ["migraine", "skin_flare", "sleep_hours", "hrv_ms", "rhr_bpm"];

test("parses Obsidian inline fields against the note date", async () => {
  const text = await Bun.file(join(FX, "daily-2024-06-14.md")).text();
  const rows = parseStructured(text, { source: "daily-2024-06-14.md", metrics: METRICS, noteDate: "2024-06-14" });
  expect(rows).toEqual([
    { metric: "migraine", date: "2024-06-14", value: 3, source: "daily-2024-06-14.md" },
    { metric: "sleep_hours", date: "2024-06-14", value: 6.5, source: "daily-2024-06-14.md" },
  ]); // `mood` ignored (not a tracked metric)
});

test("parses a vitals table, skipping blank cells", async () => {
  const text = await Bun.file(join(FX, "vitals-table.md")).text();
  const rows = parseStructured(text, { source: "vitals-table.md", metrics: METRICS });
  expect(rows).toEqual([
    { metric: "migraine", date: "2024-06-15", value: 1, source: "vitals-table.md" },
    { metric: "rhr_bpm", date: "2024-06-15", value: 58, source: "vitals-table.md" },
    { metric: "rhr_bpm", date: "2024-06-16", value: 60, source: "vitals-table.md" },
  ]); // migraine blank on 06-16 skipped
});

test("parses dated bullets", () => {
  const rows = parseStructured("- 2024-06-20 migraine 2\n- 2024-06-21 hrv_ms 45\n", { source: "n.md", metrics: METRICS });
  expect(rows).toEqual([
    { metric: "migraine", date: "2024-06-20", value: 2, source: "n.md" },
    { metric: "hrv_ms", date: "2024-06-21", value: 45, source: "n.md" },
  ]);
});

test("inline fields without a note date are skipped (no date to anchor)", () => {
  expect(parseStructured("migraine:: 3\n", { source: "n.md", metrics: ["migraine"] })).toEqual([]);
});

test("parses a table that omits the |---| separator row (first data row not dropped)", () => {
  const rows = parseStructured("| date | migraine |\n| 2024-06-15 | 1 |\n", { source: "n.md", metrics: METRICS });
  expect(rows).toEqual([{ metric: "migraine", date: "2024-06-15", value: 1, source: "n.md" }]);
});

test("a prose line with a pipe and the word date is not mistaken for a table header", () => {
  const rows = parseStructured("Pick a date | maybe tomorrow\n- 2024-06-20 migraine 2\n", { source: "n.md", metrics: METRICS });
  expect(rows).toEqual([{ metric: "migraine", date: "2024-06-20", value: 2, source: "n.md" }]);
});

test("a `-`/`*` bullet line is not mistaken for a table header even with a `date` cell and >=2 cells", () => {
  // Without the bullet guard this would be read as a header (date col 0) and the
  // next line parsed as a data row → a spurious migraine=0 row. The guard rejects it.
  const rows = parseStructured("- x | date | migraine | extra\n| 2024-06-15 | 0 | 9\n", { source: "n.md", metrics: METRICS });
  expect(rows).toEqual([]);
});

test("date-header match is case-sensitive: an uppercase `Date` column is not parsed as a table", () => {
  const rows = parseStructured("| Date | migraine |\n|---|---|\n| 2024-06-15 | 1 |\n", { source: "n.md", metrics: METRICS });
  expect(rows).toEqual([]);
});

test("parses a decimal value in a dated bullet", () => {
  const rows = parseStructured("- 2024-06-14 sleep_hours 7.5\n", { source: "n.md", metrics: METRICS });
  expect(rows).toEqual([{ metric: "sleep_hours", date: "2024-06-14", value: 7.5, source: "n.md" }]);
});
