import { describe, test, expect, vi } from "vitest";
import { makeLocalExecAdapter } from "../src/adapters/local-exec.js";
import { type ExecFn } from "../src/adapters/types.js";
import { type JobAttrs } from "../src/ledger.js";

const T0 = "2026-07-05T00:00:00Z";
function job(over: Partial<JobAttrs> = {}): JobAttrs {
  return {
    id: "j", headSha: "HEAD", runSha: "HEAD", workflow: "ci", job: "node-suites", required: false,
    needsSecrets: false, publicSafe: false, os: "windows", heavy: true, deterministic: false,
    treeHash: "t", enqueuedAt: T0, ...over,
  };
}

const quiet = () => ({ procCount: 2, load1: 0.1 });
const busy = () => ({ procCount: 40, load1: 8 });
// A drain window hour so a quiet host resolves to drain (not just shared).
const drainNow = () => new Date("2026-07-05T03:00:00"); // local 03:00 ∈ [1,7)

describe("local-exec adapter (work-profile-gated)", () => {
  test("available() up when the host is quiet in the drain window (protect-local off)", async () => {
    const a = makeLocalExecAdapter({ exec: async () => ({ stdout: "", stderr: "", code: 0 }), runnerPath: "/x/run.sh", sample: quiet, threshold: 4, now: drainNow });
    expect((await a.available()).up).toBe(true);
  });

  test("available() down when the host is busy (fail-to-focus)", async () => {
    const a = makeLocalExecAdapter({ exec: async () => ({ stdout: "", stderr: "", code: 0 }), runnerPath: "/x/run.sh", sample: busy, threshold: 4, now: drainNow });
    expect((await a.available()).up).toBe(false);
  });

  test("dispatch composes the local runner command", async () => {
    const exec = vi.fn<ExecFn>(async () => ({ stdout: "", stderr: "", code: 0 }));
    const a = makeLocalExecAdapter({ exec, runnerPath: "/x/run.sh", sample: quiet, threshold: 4 });
    const r = await a.dispatch(job());
    expect(r.runId).toBe("local-j");
    expect(exec.mock.calls[0]).toEqual(["/x/run.sh", ["node-suites", "--os", "windows"]]);
  });

  test("poll maps the runner status", async () => {
    const a = makeLocalExecAdapter({ exec: async () => ({ stdout: "running", stderr: "", code: 0 }), runnerPath: "/x", sample: quiet, threshold: 4 });
    expect((await a.poll("local-j")).status).toBe("running");
  });
});
