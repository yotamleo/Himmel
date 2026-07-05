import { describe, test, expect, vi } from "vitest";
import { makeReporter, checkContext, classifyGhError, type GhStatusFn } from "../src/reporter.js";
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

// HIMMEL-714 — error classification + bounded backoff + dead-letter.
describe("classifyGhError", () => {
  test("4xx (except 429) is permanent; 5xx / 429 / unknown-shape is transient", () => {
    expect(classifyGhError(Object.assign(new Error(), { status: 404 }))).toBe("permanent");
    expect(classifyGhError(Object.assign(new Error(), { status: 403 }))).toBe("permanent");
    expect(classifyGhError(Object.assign(new Error(), { httpStatus: 422 }))).toBe("permanent");
    expect(classifyGhError(Object.assign(new Error(), { status: 429 }))).toBe("transient"); // rate-limit retries
    expect(classifyGhError(Object.assign(new Error(), { status: 503 }))).toBe("transient");
    expect(classifyGhError(new Error("network down, no status"))).toBe("transient");
    expect(classifyGhError(Object.assign(new Error(), { permanent: true }))).toBe("permanent");
    expect(classifyGhError(Object.assign(new Error(), { status: 404, permanent: false }))).toBe("transient");
  });
});

describe("reporter dead-letter + backoff (HIMMEL-714)", () => {
  test("a permanent (4xx) error dead-letters immediately and never retries gh", async () => {
    const gh = vi.fn<GhStatusFn>(async () => {
      throw Object.assign(new Error("not found"), { status: 404 });
    });
    const r = makeReporter({ now: () => 0 });
    const res = await r.postVerdict(job(), "failure", gh);
    expect(res.posted).toBe(false);
    expect(res.deadLettered).toBe(true);
    expect(gh).toHaveBeenCalledTimes(1);
    // dead-lettered → subsequent calls short-circuit without hitting gh
    await r.postVerdict(job(), "failure", gh);
    expect(gh).toHaveBeenCalledTimes(1);
  });

  test("transient failures dead-letter after maxAttempts, then stop hitting gh", async () => {
    const gh = vi.fn<GhStatusFn>(async () => {
      throw new Error("network down"); // no status → transient
    });
    const r = makeReporter({ now: () => 0, baseBackoffMs: 0, maxAttempts: 3 });
    const j = job();
    expect((await r.postVerdict(j, "failure", gh)).deadLettered).toBeUndefined(); // attempt 1
    expect((await r.postVerdict(j, "failure", gh)).deadLettered).toBeUndefined(); // attempt 2
    expect((await r.postVerdict(j, "failure", gh)).deadLettered).toBe(true); // attempt 3 → cap
    expect(gh).toHaveBeenCalledTimes(3);
    await r.postVerdict(j, "failure", gh); // dead-lettered — no further gh
    expect(gh).toHaveBeenCalledTimes(3);
  });

  test("bounded backoff: an in-window retry does not hit gh; retries again once backoff elapses", async () => {
    let t = 1000;
    const failing = vi.fn<GhStatusFn>(async () => {
      throw new Error("outage");
    });
    const r = makeReporter({ now: () => t, baseBackoffMs: 1000, maxAttempts: 10 });
    const j = job();
    expect((await r.postVerdict(j, "success", failing)).posted).toBe(false); // attempt 1 → nextRetryAt = 2000
    expect(failing).toHaveBeenCalledTimes(1);
    await r.postVerdict(j, "success", failing); // still t=1000 < 2000 → in backoff, no gh
    expect(failing).toHaveBeenCalledTimes(1);
    t = 2000; // backoff elapsed
    const recovered = vi.fn<GhStatusFn>(async () => {});
    expect((await r.postVerdict(j, "success", recovered)).posted).toBe(true);
    expect(recovered).toHaveBeenCalledTimes(1);
  });

  test("a successful post clears prior failure state (fresh attempt budget after recovery)", async () => {
    let fail = true;
    const gh = vi.fn<GhStatusFn>(async () => {
      if (fail) throw new Error("down");
    });
    const r = makeReporter({ now: () => 0, baseBackoffMs: 0, maxAttempts: 2 });
    const j = job();
    await r.postVerdict(j, "failure", gh); // attempt 1 (attempts=1)
    fail = false;
    expect((await r.postVerdict(j, "failure", gh)).posted).toBe(true); // recovers → clears
    fail = true;
    const res = await r.postVerdict(j, "failure", gh); // fresh attempt 1, NOT immediately dead-lettered
    expect(res.deadLettered).toBeUndefined();
  });

  test("per-job attempt state is isolated — one job dead-lettering does not affect another", async () => {
    // The in-memory attempt map is keyed by job.id; a poison verdict on job A must
    // not consume job B's attempt budget or dead-letter it.
    const poison = job({ id: "poison", job: "scan-a" });
    const healthy = job({ id: "healthy", job: "scan-b" });
    const gh = vi.fn<GhStatusFn>(async (arg) => {
      if (arg.context === checkContext(poison)) {
        throw Object.assign(new Error("bad sha"), { status: 422 }); // A: permanent
      }
      // B (scan-b): succeeds
    });
    const r = makeReporter({ now: () => 0 });
    const a = await r.postVerdict(poison, "failure", gh);
    const b = await r.postVerdict(healthy, "success", gh);
    expect(a.deadLettered).toBe(true);
    expect(b.posted).toBe(true);
    expect(b.deadLettered).toBeUndefined();
  });

  test("retryUnposted surfaces dead-lettered jobs (poison verdict is visible, not silently retried)", async () => {
    const J = job({ id: "poison" });
    const state = reduce([
      { t: "submit", ts: T0, job: J },
      { t: "verdict", ts: T0, jobId: J.id, conclusion: "failure" },
    ]);
    const gh: GhStatusFn = async () => {
      throw Object.assign(new Error("bad sha"), { status: 422 });
    };
    const out = await makeReporter({ now: () => 0 }).retryUnposted(state, gh);
    expect(out.posted).toEqual([]);
    expect(out.deadLettered).toEqual(["poison"]);
  });
});
