import { describe, test, expect, vi } from "vitest";
import { makeActExecAdapter, parseActStatus } from "../src/adapters/act-exec.js";
import { type ExecFn } from "../src/adapters/types.js";
import { type JobAttrs } from "../src/ledger.js";

const T0 = "2026-07-05T00:00:00Z";
function job(over: Partial<JobAttrs> = {}): JobAttrs {
  return {
    id: "sec", headSha: "HEAD", runSha: "HEAD", workflow: "ci", job: "security-scan", required: false,
    needsSecrets: false, publicSafe: false, os: "linux", heavy: true, deterministic: false,
    treeHash: "t", enqueuedAt: T0, ...over,
  };
}

describe("act-exec adapter", () => {
  test("available() reflects the injected Docker/act probe", async () => {
    const upA = makeActExecAdapter({ exec: async () => ({ stdout: "", stderr: "", code: 0 }), actRunPath: "/x/act-run.sh", dockerAvailable: async () => true });
    expect((await upA.available()).up).toBe(true);
    const downA = makeActExecAdapter({ exec: async () => ({ stdout: "", stderr: "", code: 0 }), actRunPath: "/x/act-run.sh", dockerAvailable: async () => false });
    expect((await downA.available()).up).toBe(false);
  });

  test("dispatch composes the act-run.sh command and parses the runId", async () => {
    const exec = vi.fn<ExecFn>(async () => ({ stdout: '{"job":"security-scan","runId":"act-123-security-scan","status":"queued"}', stderr: "", code: 0 }));
    const a = makeActExecAdapter({ exec, actRunPath: "/x/act-run.sh", dockerAvailable: async () => true });
    const r = await a.dispatch(job());
    expect(r.runId).toBe("act-123-security-scan");
    expect(exec.mock.calls[0]).toEqual(["/x/act-run.sh", ["security-scan", "--os", "linux"]]);
  });

  test("dispatch throws on a non-zero act-run.sh exit (never a silent green)", async () => {
    const a = makeActExecAdapter({ exec: async () => ({ stdout: "", stderr: "boom", code: 3 }), actRunPath: "/x", dockerAvailable: async () => true });
    await expect(a.dispatch(job())).rejects.toThrow();
  });

  test("poll maps the recorded status", async () => {
    const a = makeActExecAdapter({ exec: async () => ({ stdout: "success", stderr: "", code: 0 }), actRunPath: "/x", dockerAvailable: async () => true });
    expect((await a.poll("act-123")).status).toBe("success");
  });

  test("parseActStatus falls back to failure on a garbled status", () => {
    expect(parseActStatus("success")).toBe("success");
    expect(parseActStatus("weird-noise")).toBe("failure");
  });
});
