import { test, expect } from "bun:test";
import { join } from "path";
import { mkdtempSync } from "fs";
import { tmpdir } from "os";
import { parseStructured } from "../src/parse";
import { mergeRows } from "../src/merge";
import { writeSeries } from "../src/writeSeries";

test("end-to-end: parse fixture -> merge -> write -> correlator-shaped CSV", async () => {
  const dir = mkdtempSync(join(tmpdir(), "luna-vitals-smoke-"));
  const text = "- 2024-06-14 migraine 3\n- 2024-06-15 migraine 1\n";
  const det = parseStructured(text, { source: "n.md", metrics: ["migraine"] });
  const artifact = mergeRows({ deterministic: det, llm: [], bucket: "smoke" });
  await writeSeries(artifact, dir);
  const csv = await Bun.file(join(dir, "migraine.csv")).text();
  // Exactly the date,value shape parseSeriesCsv in luna-correlate expects.
  expect(csv).toBe("date,value\n2024-06-14,3\n2024-06-15,1\n");
});
