import { describe, test, expect, vi } from "vitest";
import { makeReporter, checkContext, type GhStatusFn } from "../src/reporter.js";
import { reduce, type CiEvent, type JobAttrs } from "../src/ledger.js";

const T0 = "2026-07-05T00:00:00Z";

function job(over: Partial<JobAttrs> = {}): JobAttrs {
  return {
    id: "j", headSha: "HEAD_SHA", runSha: "PROPAGATED_SHA", workflow: "ci", job: "security-scan",
    required: true, needsSecrets: false, publicSafe: false, os: "linux", heavy: true,
    deterministic: false, treeHash: "t", enqueuedAt: T0, ...over,
  };
}

describe("reporter.postVerdict", () => {
  test("posts to job.headSha, NEVER runSha (M2), even when they differ", async () => {
    const gh = vi.fn<GhStatusFn>(async () => {});
    const r = makeReporter();
    const res = await r.postVerdict(job(), "success", gh);
    expect(res.posted).toBe(true);
    expect(gh).toHaveBeenCalledTimes(1);
    const arg = gh.mock.calls[0][0];
    expect(arg.sha).toBe("HEAD_SHA");
    expect(arg.sha).not.toBe("PROPAGATED_SHA");
    expect(arg.context).toBe(checkContext(job()));
  });

  test("GitHub unreachable → posted:false (never throws), verdict kept for retry", async () => {
    const gh: GhStatusFn = async () => {
      throw new Error("network down");
    };
    const r = makeReporter();
    const res = await r.postVerdict(job(), "failure", gh);
    expect(res.posted).toBe(false);
  });
});

describe("reporter.retryUnposted", () => {
  test("drains the verdict-known, required, unposted backlog when GitHub returns", async () => {
    // Build a state with one required verdict-known job (unposted).
    const J = job({ id: "backlog" });
    const events: CiEvent[] = [
      { t: "submit", ts: T0, job: J },
      { t: "dispatch", ts: T0, jobId: J.id, lane: "act-exec", runId: "r1" },
      { t: "verdict", ts: T0, jobId: J.id, conclusion: "success" },
    ];
    const state = reduce(events);
    const gh = vi.fn<GhStatusFn>(async () => {});
    const r = makeReporter();
    const out = await r.retryUnposted(state, gh);
    expect(out.posted).toEqual(["backlog"]);
    expect(gh.mock.calls[0][0].sha).toBe("HEAD_SHA");
  });

  test("a non-required verdict is not posted by retry", async () => {
    const J = job({ id: "nr", required: false });
    const state = reduce([
      { t: "submit", ts: T0, job: J },
      { t: "verdict", ts: T0, jobId: J.id, conclusion: "success" },
    ]);
    const gh = vi.fn<GhStatusFn>(async () => {});
    const out = await makeReporter().retryUnposted(state, gh);
    expect(out.posted).toEqual([]);
    expect(gh).not.toHaveBeenCalled();
  });
});
