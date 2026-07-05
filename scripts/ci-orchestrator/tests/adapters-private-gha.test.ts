import { describe, test, expect, vi } from "vitest";
import { makePrivateGhaNativeAdapter, parseGhRunStatus } from "../src/adapters/private-gha-native.js";
import { makePrivateGhaHostedAdapter } from "../src/adapters/private-gha-hosted.js";
import { type ExecFn } from "../src/adapters/types.js";
import { type JobAttrs } from "../src/ledger.js";

const T0 = "2026-07-05T00:00:00Z";
function job(over: Partial<JobAttrs> = {}): JobAttrs {
  return {
    id: "j", headSha: "HEADSHA", runSha: "HEADSHA", workflow: "ci", job: "shell-unit", required: true,
    needsSecrets: true, publicSafe: false, os: "windows", heavy: true, deterministic: false,
    treeHash: "t", enqueuedAt: T0, ...over,
  };
}

describe("private-gha-native (observe-only)", () => {
  test("dispatch is a NO-OP that never shells a run (I2)", async () => {
    const exec = vi.fn<ExecFn>(async () => ({ stdout: "", stderr: "", code: 0 }));
    const a = makePrivateGhaNativeAdapter({ exec, repo: "o/r" });
    expect(a.native).toBe(true);
    await expect(a.dispatch(job())).rejects.toThrow(/observe-only/);
    expect(exec).not.toHaveBeenCalled(); // never dispatched
  });

  test("available() reports up when a runner is online", async () => {
    const a = makePrivateGhaNativeAdapter({ exec: async () => ({ stdout: "42\n", stderr: "", code: 0 }), repo: "o/r" });
    expect((await a.available()).up).toBe(true);
    const down = makePrivateGhaNativeAdapter({ exec: async () => ({ stdout: "", stderr: "", code: 0 }), repo: "o/r" });
    expect((await down.available()).up).toBe(false);
  });

  test("poll maps a completed/success native run", async () => {
    const a = makePrivateGhaNativeAdapter({ exec: async () => ({ stdout: '{"status":"completed","conclusion":"success"}', stderr: "", code: 0 }), repo: "o/r" });
    expect((await a.poll("99")).status).toBe("success");
  });
});

describe("parseGhRunStatus", () => {
  test("maps status/conclusion pairs", () => {
    expect(parseGhRunStatus('{"status":"completed","conclusion":"success"}')).toBe("success");
    expect(parseGhRunStatus('{"status":"completed","conclusion":"failure"}')).toBe("failure");
    expect(parseGhRunStatus('{"status":"completed","conclusion":"cancelled"}')).toBe("cancelled");
    expect(parseGhRunStatus('{"status":"in_progress"}')).toBe("running");
    expect(parseGhRunStatus('{"status":"queued"}')).toBe("queued");
    expect(parseGhRunStatus("garbage")).toBe("running");
  });
});

describe("private-gha-hosted (dispatched, sparing)", () => {
  test("observes an existing native run for the head SHA → no workflow_dispatch", async () => {
    const exec = vi.fn<ExecFn>(async (_file, args) => {
      if (args.includes("list")) return { stdout: "555\n", stderr: "", code: 0 }; // native run exists
      throw new Error("workflow_dispatch must not be called");
    });
    const a = makePrivateGhaHostedAdapter({ exec, repo: "o/r" });
    const r = await a.dispatch(job());
    expect(r.runId).toBe("555");
  });

  test("no native run → issues a workflow_dispatch (win/mac pre-merge path)", async () => {
    const calls: string[][] = [];
    const exec: ExecFn = async (_file, args) => {
      calls.push(args);
      if (args.includes("list")) return { stdout: "", stderr: "", code: 0 }; // no native run
      return { stdout: "", stderr: "", code: 0 }; // workflow run ok
    };
    const a = makePrivateGhaHostedAdapter({ exec, repo: "o/r" });
    const r = await a.dispatch(job());
    expect(r.runId).toContain("dispatch-HEADSHA-shell-unit-windows");
    expect(calls.some((c) => c.includes("workflow"))).toBe(true);
  });
});
