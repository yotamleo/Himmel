import { test, expect } from "bun:test";
import { join } from "path";
import { parseKpText, parseKpGfz, parseKpAuto, KP_CACHE } from "../src/kp";
import { fetchKpToCache } from "../src/fetchKp";

const FIXTURES = join(import.meta.dir, "fixtures");
// One real-format GFZ row (synthetic): max(Kp1..Kp8)=2.333 for 2024-06-14.
const GFZ_ROW =
  "2024 06 14 33768 33768.5 2603  1  0.333  0.667  2.000  1.667  1.000  0.667  1.667  2.333    2    3    7    6    4    3    6    9     5 158    169.0    174.3 2";

test("parses date + daily kp", () => {
  const txt = "2026-05-01 2.0 3.0 1.0\n2026-05-02 5.0 4.0 6.0\n";
  const pts = parseKpText(txt);
  expect(pts).toEqual([
    { date: "2026-05-01", kp: 3.0 },
    { date: "2026-05-02", kp: 6.0 },
  ]);
});

test("skips rows with no numeric columns (no -Infinity kp)", () => {
  const pts = parseKpText("2026-05-01 2.0 3.0\n2026-05-02 x y\n2026-05-03 5.0\n");
  expect(pts).toEqual([
    { date: "2026-05-01", kp: 3.0 },
    { date: "2026-05-03", kp: 5.0 },
  ]);
});

test("parseKpGfz: YYYY MM DD cols -> ISO date, daily-max over Kp1..Kp8", () => {
  const pts = parseKpGfz(GFZ_ROW + "\n");
  expect(pts).toEqual([{ date: "2024-06-14", kp: 2.333 }]);
});

test("parseKpGfz: skips rows where all Kp values are the -1.000 sentinel", async () => {
  const txt = await Bun.file(join(FIXTURES, "kp-gfz-sample.txt")).text();
  const pts = parseKpGfz(txt);
  // 5 data rows, 2024-06-17 is all-sentinel -> 4 points; dates ISO-formatted.
  expect(pts).toEqual([
    { date: "2024-06-14", kp: 2.333 },
    { date: "2024-06-15", kp: 3.333 },
    { date: "2024-06-16", kp: 5.0 },
    { date: "2024-06-18", kp: 2.0 },
  ]);
});

test("parseKpAuto: routes GFZ rows to parseKpGfz, simplified rows to parseKpText", () => {
  expect(parseKpAuto(GFZ_ROW + "\n")).toEqual([{ date: "2024-06-14", kp: 2.333 }]);
  expect(parseKpAuto("2026-05-01 2.0 3.0 1.0\n")).toEqual([{ date: "2026-05-01", kp: 3.0 }]);
});

test("parseKpAuto: empty / comment-only input yields no points", () => {
  expect(parseKpAuto("")).toEqual([]);
  expect(parseKpAuto("# header only\n")).toEqual([]);
});

test("parseKpGfz: mixed sentinel + valid Kp in one row -> max over valid only", () => {
  const row =
    "2024 06 19 33773 33773.5 2603  6 -1.000  3.000 -1.000  4.667 -1.000 -1.000 -1.000 -1.000   -1   12   -1   39   -1   -1   -1   -1     6 150    167.0    172.0 0";
  expect(parseKpGfz(row + "\n")).toEqual([{ date: "2024-06-19", kp: 4.667 }]);
});

test("parseKpGfz: skips a too-short (ragged) row", () => {
  expect(parseKpGfz("2024 06 20 33774 33774.5 2603 7 1.0\n")).toEqual([]);
});

test("fetchKpToCache throws on non-ok response", async () => {
  const fake = async () => new Response("not found", { status: 404 });
  await expect(fetchKpToCache({ fetchImpl: fake as unknown as typeof fetch })).rejects.toThrow(/HTTP 404/);
});

test("fetchKpToCache parses + writes cache via injected fetch", async () => {
  const fake = async () => new Response("2026-05-01 1 2 3\n");
  const n = await fetchKpToCache({ fetchImpl: fake as unknown as typeof fetch });
  expect(n).toBe(1);
});

test("fetchKpToCache parses real GFZ-format text (ISO dates) via injected fetch", async () => {
  const fake = async () => new Response(GFZ_ROW + "\n");
  const n = await fetchKpToCache({ fetchImpl: fake as unknown as typeof fetch });
  expect(n).toBe(1);
  const cached = await Bun.file(KP_CACHE).json();
  expect(cached).toEqual([{ date: "2024-06-14", kp: 2.333 }]);
});

test("fetchKpToCache throws when a non-empty body parses to 0 points", async () => {
  // A body that survives the # filter but matches no known format -> 0 points.
  const fake = async () => new Response("garbage line with no parseable kp data here\n");
  await expect(
    fetchKpToCache({ fetchImpl: fake as unknown as typeof fetch }),
  ).rejects.toThrow(/0 points/);
});
