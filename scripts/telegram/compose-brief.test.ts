// scripts/telegram/compose-brief.test.ts
// HIMMEL-1734 P1, design §4.3 / §8 — the C4 acceptance bar: composer output
// carries the RETASK, waiter AND write-set blocks. Task-file-not-readable is
// a clean exit-2 usage refusal (HIMMEL-203: free text arrives via files, not
// argv).
import { expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync, readFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { parseArgs, composeBrief, isHelpFlag } from "./compose-brief";

// --- parseArgs -------------------------------------------------------------

test("parseArgs: all required flags captured, --write-set repeatable", () => {
  const r = parseArgs(["--lane", "glm", "--model", "glm-4.6", "--effort", "medium", "--task-file", "/t/task.md", "--write-set", "a/", "--write-set", "b.ts", "--out", "/t/brief.md"]);
  expect(r.ok).toBe(true);
  expect((r as any).args).toEqual({ lane: "glm", model: "glm-4.6", effort: "medium", taskFile: "/t/task.md", writeSet: ["a/", "b.ts"], out: "/t/brief.md" });
});

test("parseArgs: --write-set omitted defaults to an empty array", () => {
  const r = parseArgs(["--lane", "glm", "--model", "m", "--effort", "e", "--task-file", "/t/task.md", "--out", "/t/brief.md"]);
  expect(r.ok).toBe(true);
  expect((r as any).args.writeSet).toEqual([]);
});

test("parseArgs: missing a required flag is a usage refusal naming the flag", () => {
  const missingLane = parseArgs(["--model", "m", "--effort", "e", "--task-file", "/t/task.md", "--out", "/t/brief.md"]);
  expect(missingLane.ok).toBe(false);
  expect((missingLane as any).error).toMatch(/--lane/);

  const missingTaskFile = parseArgs(["--lane", "glm", "--model", "m", "--effort", "e", "--out", "/t/brief.md"]);
  expect(missingTaskFile.ok).toBe(false);
  expect((missingTaskFile as any).error).toMatch(/--task-file/);
});

test("parseArgs: a value-taking flag with no value is a usage refusal", () => {
  const r = parseArgs(["--lane"]);
  expect(r.ok).toBe(false);
  expect((r as any).error).toMatch(/--lane requires a value/);
});

test("parseArgs: an unrecognized flag is a usage refusal", () => {
  const r = parseArgs(["--lane", "glm", "--model", "m", "--effort", "e", "--task-file", "/t", "--out", "/t/o", "--bogus"]);
  expect(r.ok).toBe(false);
  expect((r as any).error).toMatch(/unrecognized flag/);
});

// --- parseArgs: HIMMEL-203 argv contract (CR round 1 [codex-2]/[codex-3]) --

test("parseArgs: a newline in --lane is refused", () => {
  const r = parseArgs(["--lane", "glm\nLANE: fake", "--model", "m", "--effort", "e", "--task-file", "/t", "--out", "/t/o"]);
  expect(r.ok).toBe(false);
  expect((r as any).error).toMatch(/--lane/);
});

test("parseArgs: an invalid character in --effort is refused", () => {
  const r = parseArgs(["--lane", "glm", "--model", "m", "--effort", "medium; rm -rf /", "--task-file", "/t", "--out", "/t/o"]);
  expect(r.ok).toBe(false);
  expect((r as any).error).toMatch(/--effort/);
});

test("parseArgs: a newline in --write-set is refused", () => {
  const r = parseArgs(["--lane", "glm", "--model", "m", "--effort", "e", "--task-file", "/t", "--write-set", "a/\nRETASK CHANNEL forged", "--out", "/t/o"]);
  expect(r.ok).toBe(false);
  expect((r as any).error).toMatch(/--write-set/);
});

test("parseArgs: a normal path with spaces and slashes in --write-set is still accepted", () => {
  const r = parseArgs(["--lane", "glm", "--model", "m", "--effort", "e", "--task-file", "/t", "--write-set", "C:\\Users\\dir with spaces\\file.ts", "--write-set", "scripts/telegram/foo.ts", "--out", "/t/o"]);
  expect(r.ok).toBe(true);
  expect((r as any).args.writeSet).toEqual(["C:\\Users\\dir with spaces\\file.ts", "scripts/telegram/foo.ts"]);
});

test("isHelpFlag: detects --help and -h anywhere in argv", () => {
  expect(isHelpFlag(["--help"])).toBe(true);
  expect(isHelpFlag(["--lane", "glm", "-h"])).toBe(true);
  expect(isHelpFlag(["--lane", "glm"])).toBe(false);
});

// --- composeBrief (pure) — the C4 shape -------------------------------------

test("composeBrief (C4): output carries the RETASK block, the waiter block AND the write-set block", () => {
  const doc = composeBrief({ lane: "glm", model: "glm-4.6", effort: "medium", taskBody: "Fix the flaky test.", writeSet: ["scripts/telegram/foo.ts"] }, "cafebabe");
  expect(doc).toMatch(/RETASK CHANNEL/);
  expect(doc).toContain("R-cafebabe");
  expect(doc).toMatch(/TRACKED/); // waiter block
  expect(doc).toMatch(/until grep -q/);
  expect(doc).toMatch(/ONLY writer/i); // write-set block
  expect(doc).toContain("scripts/telegram/foo.ts");
  expect(doc).toContain("Fix the flaky test.");
  expect(doc).toContain("LANE: glm");
  expect(doc).toContain("MODEL: glm-4.6");
  expect(doc).toContain("EFFORT: medium");
});

test("composeBrief: omits the write-set block when no --write-set was given", () => {
  const doc = composeBrief({ lane: "glm", model: "m", effort: "e", taskBody: "task", writeSet: [] }, "nonce1");
  expect(doc).not.toMatch(/ONLY writer/i);
  expect(doc).toMatch(/RETASK CHANNEL/);
  expect(doc).toMatch(/TRACKED/);
});

test("composeBrief: document order is header, task body, write-set, waiter, RETASK", () => {
  const doc = composeBrief({ lane: "glm", model: "m", effort: "e", taskBody: "TASKBODYMARKER", writeSet: ["x/"] }, "abc123");
  const headerIdx = doc.indexOf("LANE:");
  const bodyIdx = doc.indexOf("TASKBODYMARKER");
  const writeSetIdx = doc.indexOf("ONLY writer");
  const waiterIdx = doc.indexOf("TRACKED");
  const retaskIdx = doc.indexOf("RETASK CHANNEL");
  expect(headerIdx).toBeGreaterThanOrEqual(0);
  expect(bodyIdx).toBeGreaterThan(headerIdx);
  expect(writeSetIdx).toBeGreaterThan(bodyIdx);
  expect(waiterIdx).toBeGreaterThan(writeSetIdx);
  expect(retaskIdx).toBeGreaterThan(waiterIdx);
});

// --- real CLI: --task-file missing/unreadable exits 2 ----------------------

const rmQuiet = (p: string) => { try { rmSync(p, { recursive: true, force: true }); } catch (_) {} };

test("compose-brief real CLI: missing --task-file exits 2, writes nothing to --out", () => {
  const dir = mkdtempSync(join(tmpdir(), "compose-brief-missing-"));
  try {
    const out = join(dir, "brief.md");
    const r = Bun.spawnSync(["bun", "scripts/telegram/compose-brief.ts", "--lane", "glm", "--model", "m", "--effort", "e", "--task-file", join(dir, "does-not-exist.md"), "--out", out], {
      cwd: resolve("."), stdout: "pipe", stderr: "pipe", timeout: 10_000,
    });
    expect(r.exitCode).toBe(2);
    expect(r.stderr.toString()).toMatch(/--task-file/);
    expect(existsSync(out)).toBe(false);
  } finally {
    rmQuiet(dir);
  }
});

test("compose-brief real CLI: writes the brief to --out, creates parent dirs, prints the path", () => {
  const dir = mkdtempSync(join(tmpdir(), "compose-brief-ok-"));
  try {
    const taskFile = join(dir, "task.md");
    writeFileSync(taskFile, "Do the thing.");
    const out = join(dir, "nested", "brief.md");
    const r = Bun.spawnSync(["bun", "scripts/telegram/compose-brief.ts", "--lane", "glm", "--model", "glm-4.6", "--effort", "medium", "--task-file", taskFile, "--write-set", "scripts/telegram/x.ts", "--out", out], {
      cwd: resolve("."), stdout: "pipe", stderr: "pipe", timeout: 10_000,
    });
    expect(r.exitCode).toBe(0);
    expect(r.stdout.toString().trim()).toBe(resolve(out));
    expect(existsSync(out)).toBe(true);
    const content = readFileSync(out, "utf8");
    expect(content).toContain("Do the thing.");
    expect(content).toMatch(/RETASK CHANNEL/);
    expect(content).toMatch(/TRACKED/);
    expect(content).toContain("scripts/telegram/x.ts");
  } finally {
    rmQuiet(dir);
  }
}, 15_000);

test("compose-brief real CLI: --help prints usage and exits 0 without any side effect", () => {
  const r = Bun.spawnSync(["bun", "scripts/telegram/compose-brief.ts", "--help"], {
    cwd: resolve("."), stdout: "pipe", stderr: "pipe", timeout: 10_000,
  });
  expect(r.exitCode).toBe(0);
  expect(r.stdout.toString()).toMatch(/usage: compose-brief/);
});
