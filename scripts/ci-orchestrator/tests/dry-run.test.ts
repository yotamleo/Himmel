import { describe, test, expect } from "vitest";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { mkdtempSync } from "node:fs";
import { makeDryRunAdapter } from "../src/adapters/dry-run.js";
import { tick } from "../src/scheduler.js";
import { type JobAttrs } from "../src/ledger.js";
import { type LaneAdapter } from "../src/adapters/types.js";
import { type ActMatrix } from "../src/act-matrix.js";
import { makeReporter } from "../src/reporter.js";

const MATRIX: ActMatrix = { "ci:security-scan": { fidelity: "needs-shim", os: ["linux"], heavy: true } };
const T0 = Date.parse("2026-07-05T00:00:00Z");

function job(over: Partial<JobAttrs> = {}): JobAttrs {
  return {
    id: "sec", headSha: "HEAD", runSha: "HEAD", workflow: "ci", job: "security-scan", required: false,
    needsSecrets: false, publicSafe: false, os: "linux", heavy: true, deterministic: false,
    treeHash: "t", enqueuedAt: new Date(T0).toISOString(), ...over,
  };
}

// A minimal "real" adapter whose dispatch would throw if actually called — proves
// the dry-run wrapper intercepts dispatch and never touches the real lane.
const realActExec: LaneAdapter = {
  name: "act-exec",
  available: async () => ({ up: true, inFlight: 0, cap: 4 }),
  dispatch: async () => {
    throw new Error("real dispatch must not run under dry-run");
  },
  poll: async () => ({ status: "success" }),
};

describe("dry-run adapter", () => {
  test("records the wrapped lane name + jobId and never fires the real dispatch", async () => {
    const dry = makeDryRunAdapter(realActExec);
    const r = await dry.dispatch(job());
    expect(r.runId).toContain("dry-act-exec-sec");
    expect(dry.recorded).toEqual([{ lane: "act-exec", jobId: "sec" }]);
  });

  test("a scheduler tick with only the dry-run adapter records 'would dispatch' and touches no real lane", async () => {
    const p = join(mkdtempSync(join(tmpdir(), "ci-dry-")), "q.jsonl");
    const dry = makeDryRunAdapter(realActExec, "running");
    const report = await tick({
      discover: () => [job()],
      changedFiles: () => ["src/x.ts"],
      adapters: [dry],
      actMatrix: MATRIX,
      reporter: makeReporter(),
      gh: async () => {},
      workProfile: "focus",
      loadBelowThreshold: false,
      privateMinutesHeadroom: true,
      githubUp: true,
      now: () => T0,
      env: {},
      ledgerPath: p,
    });
    expect(report.dispatched).toEqual([{ jobId: "sec", lane: "act-exec" }]);
    expect(dry.recorded).toEqual([{ lane: "act-exec", jobId: "sec" }]);
  });
});
