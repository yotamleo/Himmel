import { test, expect } from "bun:test";
import { join } from "path";
import { mkdtempSync } from "fs";
import { tmpdir } from "os";
import { writeSeries } from "../src/writeSeries";
import type { ReviewArtifact } from "../src/types";

const tmp = () => mkdtempSync(join(tmpdir(), "luna-vitals-"));

test("writes one CSV per metric, sorted, header date,value", async () => {
  const dir = tmp();
  const a: ReviewArtifact = {
    bucket: "x", conflicts: [],
    rows: [
      { metric: "migraine", date: "2024-06-15", value: 1, source: "s" },
      { metric: "migraine", date: "2024-06-14", value: 3, source: "s" },
      { metric: "rhr_bpm", date: "2024-06-14", value: 58, source: "s" },
    ],
  };
  const res = await writeSeries(a, dir);
  expect(res.find(r => r.metric === "migraine")!.n).toBe(2);
  expect(await Bun.file(join(dir, "migraine.csv")).text()).toBe("date,value\n2024-06-14,3\n2024-06-15,1\n");
  expect(await Bun.file(join(dir, "rhr_bpm.csv")).text()).toBe("date,value\n2024-06-14,58\n");
});

test("merges with an existing CSV (union by date, new wins on same date)", async () => {
  const dir = tmp();
  await Bun.write(join(dir, "migraine.csv"), "date,value\n2024-06-14,2\n2024-06-13,0\n");
  const a: ReviewArtifact = { bucket: "x", conflicts: [], rows: [{ metric: "migraine", date: "2024-06-14", value: 3, source: "s" }] };
  await writeSeries(a, dir);
  expect(await Bun.file(join(dir, "migraine.csv")).text()).toBe("date,value\n2024-06-13,0\n2024-06-14,3\n");
});

test("refuses to write a metric that has an unresolved conflict", async () => {
  const dir = tmp();
  const a: ReviewArtifact = {
    bucket: "x",
    conflicts: [{ metric: "migraine", date: "2024-06-14", values: [{ value: 2, source: "a" }, { value: 3, source: "b" }] }],
    rows: [{ metric: "migraine", date: "2024-06-14", value: 2, source: "a" }],
  };
  await expect(writeSeries(a, dir)).rejects.toThrow(/unresolved conflict/);
});

test("allowConflicts:true bypasses the conflict guard and writes", async () => {
  const dir = tmp();
  const a: ReviewArtifact = {
    bucket: "x",
    conflicts: [{ metric: "migraine", date: "2024-06-14", values: [{ value: 2, source: "a" }, { value: 3, source: "b" }] }],
    rows: [{ metric: "migraine", date: "2024-06-14", value: 2, source: "a" }],
  };
  await writeSeries(a, dir, { allowConflicts: true });
  expect(await Bun.file(join(dir, "migraine.csv")).text()).toBe("date,value\n2024-06-14,2\n");
});

test("skips malformed rows in an existing CSV (no NaN / misaligned values seeded)", async () => {
  const dir = tmp();
  // bad rows: missing value, extra column, non-numeric value — none must survive
  await Bun.write(join(dir, "migraine.csv"), "date,value\n2024-06-10\n2024-06-11,1,extra\n2024-06-12,oops\n2024-06-13,0\n");
  const a: ReviewArtifact = { bucket: "x", conflicts: [], rows: [{ metric: "migraine", date: "2024-06-14", value: 3, source: "s" }] };
  await writeSeries(a, dir);
  expect(await Bun.file(join(dir, "migraine.csv")).text()).toBe("date,value\n2024-06-13,0\n2024-06-14,3\n");
});
