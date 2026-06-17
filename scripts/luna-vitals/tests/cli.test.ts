import { test, expect } from "bun:test";
import { join } from "path";
import { mkdtempSync } from "fs";
import { tmpdir } from "os";

const ROOT = join(import.meta.dir, "..");
const FX = join(import.meta.dir, "fixtures");

test("parse -> write round-trip via CLI produces a 50-Vitals CSV", async () => {
  const dir = mkdtempSync(join(tmpdir(), "luna-vitals-cli-"));
  const artifact = join(dir, "a.json");
  const p1 = Bun.spawn(["bun", "run", "cli.ts", "parse", join(FX, "vitals-table.md"), "--out", artifact], { cwd: ROOT, stderr: "pipe" });
  expect(await p1.exited).toBe(0);
  const p2 = Bun.spawn(["bun", "run", "cli.ts", "write", artifact, "--dir", dir], { cwd: ROOT, stderr: "pipe" });
  expect(await p2.exited).toBe(0);
  expect(await Bun.file(join(dir, "migraine.csv")).text()).toContain("2024-06-15,1");
});

test("CLI exits non-zero on an unknown command", async () => {
  const p = Bun.spawn(["bun", "run", "cli.ts", "frobnicate"], { cwd: ROOT, stderr: "pipe" });
  expect(await p.exited).toBe(1);
});

test("parse --note-date anchors inline fields, then merge --det/--llm keeps deterministic over llm", async () => {
  const dir = mkdtempSync(join(tmpdir(), "luna-vitals-cli-merge-"));
  const det = join(dir, "det.json");
  const llm = join(dir, "llm.json");
  const merged = join(dir, "merged.json");
  // deterministic parse of a daily note via --note-date → migraine=3 on 2024-06-14
  const p1 = Bun.spawn(["bun", "run", "cli.ts", "parse", join(FX, "daily-2024-06-14.md"), "--note-date", "2024-06-14", "--out", det], { cwd: ROOT, stderr: "pipe" });
  expect(await p1.exited).toBe(0);
  expect((await readJson(det)).rows).toContainEqual({ metric: "migraine", date: "2024-06-14", value: 3, source: join(FX, "daily-2024-06-14.md") });
  // an LLM artifact disagreeing on the SAME (metric,date)
  await Bun.write(llm, JSON.stringify({ bucket: "2024-06-14..2024-06-14", conflicts: [], rows: [{ metric: "migraine", date: "2024-06-14", value: 1, source: "prose.md: bad day" }] }));
  const p2 = Bun.spawn(["bun", "run", "cli.ts", "merge", "--det", det, "--llm", llm, "--out", merged], { cwd: ROOT, stderr: "pipe" });
  expect(await p2.exited).toBe(0);
  const m = await readJson(merged);
  // deterministic value (3) wins; no conflict raised across the det/llm boundary
  expect(m.rows).toContainEqual({ metric: "migraine", date: "2024-06-14", value: 3, source: join(FX, "daily-2024-06-14.md") });
  expect(m.conflicts).toEqual([]);
});

test("merge warns on stderr (naming the file) for a positional arg that is not a .json artifact", async () => {
  const dir = mkdtempSync(join(tmpdir(), "luna-vitals-cli-warn-"));
  const det = join(dir, "det.json");
  await Bun.write(det, JSON.stringify({ bucket: "x", conflicts: [], rows: [{ metric: "migraine", date: "2024-06-14", value: 3, source: "s" }] }));
  const merged = join(dir, "merged.json");
  const p = Bun.spawn(["bun", "run", "cli.ts", "merge", det, "notes.md", "--out", merged], { cwd: ROOT, stderr: "pipe" });
  const err = await new Response(p.stderr).text();
  expect(await p.exited).toBe(0);
  expect(err).toContain("notes.md");
  // the ignored positional must not corrupt the real merge — det.json's row survives
  expect((await readJson(merged)).rows).toContainEqual({ metric: "migraine", date: "2024-06-14", value: 3, source: "s" });
});

test("CLI exits non-zero (not 0) when the parse input file is missing", async () => {
  const p = Bun.spawn(["bun", "run", "cli.ts", "parse", join(tmpdir(), "does-not-exist-xyz.md"), "--out", join(tmpdir(), "o.json")], { cwd: ROOT, stderr: "pipe" });
  expect(await p.exited).toBe(1);
});

async function readJson(p: string): Promise<any> { return JSON.parse(await Bun.file(p).text()); }
