import { test, expect } from "bun:test";
import { join } from "path";
import { tmpdir } from "os";
import { validateRow, readArtifact, writeArtifact, type ReviewArtifact } from "../src/types";

test("validateRow rejects non-ISO date, non-finite value, empty metric/source", () => {
  expect(() => validateRow({ metric: "migraine", date: "06/14/2024", value: 3, source: "x" })).toThrow(/ISO/);
  expect(() => validateRow({ metric: "migraine", date: "2024-06-14", value: NaN, source: "x" })).toThrow(/numeric/);
  expect(() => validateRow({ metric: "", date: "2024-06-14", value: 3, source: "x" })).toThrow(/metric/);
  expect(() => validateRow({ metric: "migraine", date: "2024-06-14", value: 3, source: "" })).toThrow(/source/);
  validateRow({ metric: "migraine", date: "2024-06-14", value: 3, source: "daily/2024-06-14.md" }); // ok
});

test("validateRow rejects ISO-shaped but impossible calendar dates", () => {
  expect(() => validateRow({ metric: "migraine", date: "2024-02-30", value: 1, source: "x" })).toThrow(/calendar date/);
  expect(() => validateRow({ metric: "migraine", date: "2024-13-01", value: 1, source: "x" })).toThrow(/calendar date/);
  validateRow({ metric: "migraine", date: "2024-02-29", value: 1, source: "x" }); // 2024 is a leap year — ok
});

test("readArtifact reports the path on a corrupt (non-JSON) artifact", async () => {
  const p = join(tmpdir(), "luna-vitals-corrupt-artifact.json");
  await Bun.write(p, "{ this is not json");
  await expect(readArtifact(p)).rejects.toThrow(/failed to read\/parse artifact at/);
});

test("readArtifact rejects an artifact missing the bucket field", async () => {
  const p = join(tmpdir(), "luna-vitals-nobucket-artifact.json");
  await Bun.write(p, JSON.stringify({ conflicts: [], rows: [] }));
  await expect(readArtifact(p)).rejects.toThrow(/bucket/);
});

test("writeArtifact then readArtifact round-trips and validates rows", async () => {
  const a: ReviewArtifact = {
    bucket: "2024", conflicts: [],
    rows: [{ metric: "migraine", date: "2024-06-14", value: 3, source: "daily/2024-06-14.md" }],
  };
  const p = join(tmpdir(), "luna-vitals-artifact-test.json");
  await writeArtifact(p, a);
  expect(await readArtifact(p)).toEqual(a);
});

test("readArtifact throws on an invalid row in the file", async () => {
  const p = join(tmpdir(), "luna-vitals-bad-artifact.json");
  await Bun.write(p, JSON.stringify({ bucket: "x", conflicts: [], rows: [{ metric: "m", date: "nope", value: 1, source: "s" }] }));
  await expect(readArtifact(p)).rejects.toThrow(/ISO/);
});
