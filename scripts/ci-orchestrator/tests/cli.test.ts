import { describe, test, expect } from "vitest";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { mkdtempSync } from "node:fs";
import { runCli, type CliIo } from "../src/cli.js";
import { appendEvent, type JobAttrs } from "../src/ledger.js";

function io(ledgerPath?: string): CliIo & { stdout: string[]; stderr: string[] } {
  const stdout: string[] = [];
  const stderr: string[] = [];
  return { out: (s) => stdout.push(s), err: (s) => stderr.push(s), env: {}, ledgerPath, stdout, stderr };
}

describe("runCli", () => {
  test("state on an empty ledger → {} and exit 0", async () => {
    const p = join(mkdtempSync(join(tmpdir(), "ci-cli-")), "q.jsonl"); // does not exist yet
    const o = io(p);
    const code = await runCli(["state"], o);
    expect(code).toBe(0);
    expect(o.stdout).toEqual(["{}"]);
  });

  test("state reflects a submitted job", async () => {
    const p = join(mkdtempSync(join(tmpdir(), "ci-cli-")), "q.jsonl");
    const job: JobAttrs = {
      id: "j1", headSha: "H", runSha: "H", workflow: "ci", job: "lint", required: true,
      needsSecrets: false, publicSafe: false, os: "linux", heavy: false, deterministic: false,
      treeHash: "t", enqueuedAt: "2026-07-05T00:00:00Z",
    };
    appendEvent({ t: "submit", ts: "2026-07-05T00:00:00Z", job }, {}, p);
    const o = io(p);
    await runCli(["state"], o);
    expect(JSON.parse(o.stdout[0]).j1.status).toBe("queued");
  });

  test("tick/daemon report the wiring boundary (exit 2)", async () => {
    for (const cmd of ["tick", "daemon"]) {
      const o = io();
      const code = await runCli([cmd], o);
      expect(code).toBe(2);
      expect(o.stderr[0]).toContain("wiring");
    }
  });

  test("unknown command → usage + exit 1", async () => {
    const o = io();
    expect(await runCli(["bogus"], o)).toBe(1);
    expect(o.stderr[0]).toContain("unknown command");
  });
});
