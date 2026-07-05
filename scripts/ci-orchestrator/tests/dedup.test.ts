import { describe, test, expect } from "vitest";
import { planSubmission } from "../src/dedup.js";
import { type JobAttrs, type JobState } from "../src/ledger.js";

let seq = 0;
function job(over: Partial<JobAttrs>): JobAttrs {
  return {
    id: "j" + seq++, headSha: "h", runSha: "h", workflow: "ci", job: "node-suites",
    required: false, needsSecrets: false, publicSafe: false, os: "linux", heavy: false,
    deterministic: true, treeHash: "t", enqueuedAt: "t", ...over,
  };
}
function priorWithSuccess(treeHash: string): Map<string, JobState> {
  const a = job({ treeHash });
  return new Map([[a.id, { attrs: a, status: "done", conclusion: "success" }]]);
}

describe("planSubmission", () => {
  test("doc-only diff drops the code matrix, keeps the doc-safe gate", () => {
    const cands = [
      job({ job: "secret-scan", deterministic: false }),
      job({ job: "lint", deterministic: false }),
      job({ job: "node-suites" }),
      job({ job: "security-scan" }),
    ];
    const { enqueue } = planSubmission(cands, ["docs/x.md", "README.md"], new Map());
    const names = enqueue.map((e) => e.job);
    expect(names).toContain("secret-scan");
    expect(names).toContain("lint");
    expect(names).not.toContain("node-suites");
    expect(names).not.toContain("security-scan");
  });

  test("a non-doc diff enqueues the code matrix", () => {
    const cands = [job({ job: "node-suites", deterministic: false })];
    const { enqueue } = planSubmission(cands, ["src/x.ts"], new Map());
    expect(enqueue.map((e) => e.job)).toContain("node-suites");
  });

  test("a deterministic job with a matching prior success is reused, not enqueued", () => {
    const prior = priorWithSuccess("abc");
    const { enqueue, reused } = planSubmission([job({ treeHash: "abc", deterministic: true })], ["src/x.ts"], prior);
    expect(reused).toHaveLength(1);
    expect(reused[0].fromTreeHash).toBe("abc");
    expect(enqueue).toHaveLength(0);
  });

  test("deterministic:false is never dedup-reused (always enqueued)", () => {
    const prior = priorWithSuccess("abc");
    const { enqueue, reused } = planSubmission([job({ treeHash: "abc", deterministic: false })], ["src/x.ts"], prior);
    expect(reused).toHaveLength(0);
    expect(enqueue).toHaveLength(1);
  });

  test("a DIFFERENT job with the same treeHash does not lend its verdict (identity-keyed dedup)", () => {
    // prior success is job "node-suites" on tree "abc".
    const prior = priorWithSuccess("abc"); // priorWithSuccess builds a node-suites job
    // candidate is a DIFFERENT job (security-scan) on the SAME tree — must NOT reuse.
    const { enqueue, reused } = planSubmission(
      [job({ job: "security-scan", treeHash: "abc", deterministic: true })],
      ["src/x.ts"],
      prior,
    );
    expect(reused).toHaveLength(0);
    expect(enqueue).toHaveLength(1);
  });

  test("os leg is part of dedup identity (same job, different os → not reused)", () => {
    const a = job({ job: "shell-unit", os: "linux", treeHash: "abc" });
    const prior = new Map([[a.id, { attrs: a, status: "done" as const, conclusion: "success" }]]);
    const { enqueue, reused } = planSubmission(
      [job({ job: "shell-unit", os: "windows", treeHash: "abc", deterministic: true })],
      ["src/x.ts"],
      prior,
    );
    expect(reused).toHaveLength(0);
    expect(enqueue).toHaveLength(1);
  });
});
