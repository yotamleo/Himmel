import { test, expect } from "bun:test";
import { join } from "path";
import { tmpdir } from "os";
import { validateRow, validateConflict, readArtifact, writeArtifact, type ReviewArtifact } from "../src/types";

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

test("validateConflict requires a well-formed chosen provenance entry", () => {
  const good = { metric: "migraine", date: "2024-06-14", values: [{ value: 2, source: "a" }, { value: 3, source: "b" }], chosen: { value: 2, source: "a" } };
  expect(() => validateConflict(good)).not.toThrow();
  expect(() => validateConflict({ ...good, chosen: undefined as any })).toThrow(/chosen/);
  expect(() => validateConflict({ ...good, chosen: { value: NaN, source: "a" } })).toThrow(/chosen/);
});

test("validateConflict rejects a malformed values candidate (NaN/empty-source) and a too-short values list", () => {
  const base = { metric: "migraine", date: "2024-06-14", chosen: { value: 2, source: "a" } };
  expect(() => validateConflict({ ...base, values: [{ value: 2, source: "a" }, { value: NaN, source: "b" }] } as any)).toThrow(/values/);
  expect(() => validateConflict({ ...base, values: [{ value: 2, source: "a" }, { value: 3, source: "" }] } as any)).toThrow(/values/);
  expect(() => validateConflict({ ...base, values: [{ value: 2, source: "a" }] } as any)).toThrow(/at least two/);
});

test("validateConflict rejects a chosen that is not one of the recorded values", () => {
  const c = { metric: "migraine", date: "2024-06-14", values: [{ value: 2, source: "a" }, { value: 3, source: "b" }], chosen: { value: 9, source: "z" } };
  expect(() => validateConflict(c)).toThrow(/not one of/);
});

test("writeArtifact/readArtifact round-trips a conflict with its chosen provenance", async () => {
  const a: ReviewArtifact = {
    bucket: "x",
    rows: [{ metric: "migraine", date: "2024-06-14", value: 2, source: "a" }],
    conflicts: [{ metric: "migraine", date: "2024-06-14", values: [{ value: 2, source: "a" }, { value: 3, source: "b" }], chosen: { value: 2, source: "a" } }],
  };
  const p = join(tmpdir(), "luna-vitals-conflict-roundtrip.json");
  await writeArtifact(p, a);
  expect(await readArtifact(p)).toEqual(a);
});

test("readArtifact rejects a conflict missing the chosen field", async () => {
  const p = join(tmpdir(), "luna-vitals-conflict-nochosen.json");
  await Bun.write(p, JSON.stringify({ bucket: "x", rows: [], conflicts: [{ metric: "migraine", date: "2024-06-14", values: [{ value: 2, source: "a" }, { value: 3, source: "b" }] }] }));
  await expect(readArtifact(p)).rejects.toThrow(/chosen/);
});

test("writeArtifact/readArtifact round-trips an artifact that carries warnings", async () => {
  const a: ReviewArtifact = {
    bucket: "x",
    rows: [{ metric: "sleep_in_bed_hours", date: "2026-01-02", value: 8.0, source: "google-health:sleep:HEALTH_CONNECT" }],
    conflicts: [],
    warnings: ["sleep 2026-01-02: malformed stage timestamps - sleep_hours omitted (degraded stage data)"],
  };
  const p = join(tmpdir(), "luna-vitals-warnings-roundtrip.json");
  await writeArtifact(p, a);
  expect(await readArtifact(p)).toEqual(a);
});

test("readArtifact accepts an artifact with NO warnings field (pre-HIMMEL-794 artifact)", async () => {
  const p = join(tmpdir(), "luna-vitals-no-warnings-field.json");
  await Bun.write(p, JSON.stringify({ bucket: "x", conflicts: [], rows: [] }));
  const a = await readArtifact(p);
  expect(a.warnings).toBeUndefined();
});

test("readArtifact rejects a non-array warnings field", async () => {
  const p = join(tmpdir(), "luna-vitals-warnings-nonarray.json");
  await Bun.write(p, JSON.stringify({ bucket: "x", conflicts: [], rows: [], warnings: "x" }));
  await expect(readArtifact(p)).rejects.toThrow(/malformed artifact at.*"warnings"/);
});

test("readArtifact rejects a warnings entry that is not a non-empty string", async () => {
  const p = join(tmpdir(), "luna-vitals-warnings-nonstring.json");
  await Bun.write(p, JSON.stringify({ bucket: "x", conflicts: [], rows: [], warnings: [1] }));
  await expect(readArtifact(p)).rejects.toThrow(/malformed artifact at.*"warnings"/);
});

test("writeArtifact rejects a non-array warnings field", async () => {
  const a = { bucket: "x", conflicts: [], rows: [], warnings: "x" } as unknown as ReviewArtifact;
  await expect(writeArtifact(join(tmpdir(), "luna-vitals-warnings-write-reject.json"), a)).rejects.toThrow(/"warnings"/);
});

test("readArtifact rejects a warnings entry that is an empty string", async () => {
  // The `!w` branch of warningsError (as opposed to the `typeof w !== "string"` branch)
  // — untested before, so a regression dropping it would still pass every other test.
  const p = join(tmpdir(), "luna-vitals-warnings-emptystring.json");
  await Bun.write(p, JSON.stringify({ bucket: "x", conflicts: [], rows: [], warnings: [""] }));
  await expect(readArtifact(p)).rejects.toThrow(/malformed artifact at.*"warnings"/);
});

test("readArtifact rejects a present-but-empty warnings array (never [])", async () => {
  const p = join(tmpdir(), "luna-vitals-warnings-empty-array.json");
  await Bun.write(p, JSON.stringify({ bucket: "x", conflicts: [], rows: [], warnings: [] }));
  await expect(readArtifact(p)).rejects.toThrow(/absent when empty/);
});

test("writeArtifact rejects a present-but-empty warnings array (never [])", async () => {
  const a = { bucket: "x", conflicts: [], rows: [], warnings: [] } as unknown as ReviewArtifact;
  await expect(writeArtifact(join(tmpdir(), "luna-vitals-warnings-write-empty-reject.json"), a)).rejects.toThrow(/absent when empty/);
});
