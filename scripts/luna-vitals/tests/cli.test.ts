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
  // clean merge (no input carried warnings) → warnings key ABSENT (byte-identical to pre-HIMMEL-794)
  expect(m.warnings).toBeUndefined();
});

test("merge preserves warnings from inputs (deduped) when an input carries them", async () => {
  const dir = mkdtempSync(join(tmpdir(), "luna-vitals-cli-warnings-"));
  const a = join(dir, "a.json");
  const b = join(dir, "b.json");
  const merged = join(dir, "merged.json");
  const w1 = "sleep 2026-01-02: malformed stage timestamps - sleep_hours omitted (degraded stage data)";
  const w2 = "sleep 2026-01-03: malformed stage timestamps - sleep_hours omitted (degraded stage data)";
  await Bun.write(a, JSON.stringify({ bucket: "a", conflicts: [], rows: [{ metric: "migraine", date: "2024-06-14", value: 3, source: "a.md" }], warnings: [w1, w2] }));
  // b re-mentions w1 (a duplicate across inputs) and brings its own row.
  await Bun.write(b, JSON.stringify({ bucket: "b", conflicts: [], rows: [{ metric: "migraine", date: "2024-06-15", value: 1, source: "b.md" }], warnings: [w1] }));
  const p = Bun.spawn(["bun", "run", "cli.ts", "merge", a, b, "--out", merged], { cwd: ROOT, stderr: "pipe" });
  expect(await p.exited).toBe(0);
  const m = await readJson(merged);
  // deduped (w1 appears once despite being in both inputs), input order preserved
  expect(m.warnings).toEqual([w1, w2]);
  expect(m.rows).toContainEqual({ metric: "migraine", date: "2024-06-14", value: 3, source: "a.md" });
  expect(m.rows).toContainEqual({ metric: "migraine", date: "2024-06-15", value: 1, source: "b.md" });
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

test("merge of a single warnings-only artifact (rows: []) exits 0 and carries the warnings through (CR round 3)", async () => {
  // A valid degraded pull can produce ZERO rows but non-empty warnings (every sleep
  // session dropped) — the no-input guard must key on artifacts READ, not row counts.
  const dir = mkdtempSync(join(tmpdir(), "luna-vitals-cli-warnonly-"));
  const a = join(dir, "a.json");
  const merged = join(dir, "merged.json");
  const w = "sleep dataPoint 0: missing interval startTime/endTime - session dropped";
  await Bun.write(a, JSON.stringify({ bucket: "2026-01-01..2026-01-31", conflicts: [], rows: [], warnings: [w] }));
  const p = Bun.spawn(["bun", "run", "cli.ts", "merge", a, "--out", merged], { cwd: ROOT, stderr: "pipe" });
  expect(await p.exited).toBe(0);
  const m = await readJson(merged);
  expect(m.rows).toEqual([]);
  expect(m.warnings).toEqual([w]);
});

test("merge keeps two distinct dropped-session warnings (indexed texts never collapse under Set dedup) (CR round 4)", async () => {
  // Two dropped sessions used to share the identical static missing-interval text,
  // so merge's exact-text dedup collapsed N events into 1. The dataPoint index in
  // the text keeps them distinct through merge.
  const dir = mkdtempSync(join(tmpdir(), "luna-vitals-cli-idx-warn-"));
  const a = join(dir, "a.json");
  const merged = join(dir, "merged.json");
  const w0 = "sleep dataPoint 0: missing interval startTime/endTime - session dropped";
  const w1 = "sleep dataPoint 1: missing interval startTime/endTime - session dropped";
  await Bun.write(a, JSON.stringify({ bucket: "2026-01-01..2026-01-31", conflicts: [], rows: [], warnings: [w0, w1] }));
  const p = Bun.spawn(["bun", "run", "cli.ts", "merge", a, "--out", merged], { cwd: ROOT, stderr: "pipe" });
  expect(await p.exited).toBe(0);
  expect((await readJson(merged)).warnings).toEqual([w0, w1]);
});

test("merge of a single rows-empty, warnings-free artifact exits 1 (total extraction failure stays fail-fast) (CR round 5)", async () => {
  // The warnings-only relaxation must not mask a total extraction failure: an
  // artifact with zero rows AND zero warnings has nothing to merge — error out.
  const dir = mkdtempSync(join(tmpdir(), "luna-vitals-cli-empty-"));
  const a = join(dir, "a.json");
  await Bun.write(a, JSON.stringify({ bucket: "2026-01-01..2026-01-31", conflicts: [], rows: [] }));
  const p = Bun.spawn(["bun", "run", "cli.ts", "merge", a, "--out", join(dir, "merged.json")], { cwd: ROOT, stderr: "pipe" });
  const err = await new Response(p.stderr).text();
  expect(await p.exited).toBe(1);
  expect(err).toContain("no input artifacts found");
});

test("merge with NO artifact inputs at all still exits 1 with the usage message", async () => {
  const dir = mkdtempSync(join(tmpdir(), "luna-vitals-cli-noinput-"));
  const p = Bun.spawn(["bun", "run", "cli.ts", "merge", "--out", join(dir, "merged.json")], { cwd: ROOT, stderr: "pipe" });
  const err = await new Response(p.stderr).text();
  expect(await p.exited).toBe(1);
  expect(err).toContain("no input artifacts found");
});

test("write on an artifact carrying warnings: exit 0, series written, warnings surfaced on stderr and harmlessly ignored (HIMMEL-794 Fix E)", async () => {
  const dir = mkdtempSync(join(tmpdir(), "luna-vitals-cli-write-warnings-"));
  const artifact = join(dir, "a.json");
  const w = "sleep 2026-01-02: malformed stage timestamps - sleep_hours omitted (degraded stage data)";
  await Bun.write(artifact, JSON.stringify({
    bucket: "2026-01-02..2026-01-02",
    conflicts: [],
    rows: [{ metric: "sleep_in_bed_hours", date: "2026-01-02", value: 8.0, source: "google-health:sleep:HEALTH_CONNECT" }],
    warnings: [w],
  }));
  const p = Bun.spawn(["bun", "run", "cli.ts", "write", artifact, "--dir", dir], { cwd: ROOT, stderr: "pipe" });
  const err = await new Response(p.stderr).text();
  expect(await p.exited).toBe(0);
  expect(err).toContain(`[luna-vitals] artifact warning: ${w}`);
  expect(await Bun.file(join(dir, "sleep_in_bed_hours.csv")).text()).toContain("2026-01-02,8");
});

test("CLI exits non-zero (not 0) when the parse input file is missing", async () => {
  const p = Bun.spawn(["bun", "run", "cli.ts", "parse", join(tmpdir(), "does-not-exist-xyz.md"), "--out", join(tmpdir(), "o.json")], { cwd: ROOT, stderr: "pipe" });
  expect(await p.exited).toBe(1);
});

async function readJson(p: string): Promise<any> { return JSON.parse(await Bun.file(p).text()); }
