import { describe, test, expect } from "vitest";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { mkdtempSync } from "node:fs";
import { appendEvent, readState, reduce, ledgerPath, type JobAttrs } from "../src/ledger.js";

function jobAttrs(over: Partial<JobAttrs> = {}): JobAttrs {
  return {
    id: "j1", headSha: "head1", runSha: "head1", workflow: "ci", job: "security-scan",
    required: true, needsSecrets: true, publicSafe: false, os: "linux", heavy: true,
    deterministic: true, treeHash: "tree1", enqueuedAt: "2026-07-05T00:00:00Z", ...over,
  };
}

describe("ledgerPath", () => {
  test("override wins", () => {
    expect(ledgerPath({ HIMMEL_CI_QUEUE_LEDGER: "/tmp/x.jsonl" })).toBe("/tmp/x.jsonl");
  });
  test("default is $HOME/.himmel/ci-queue.jsonl", () => {
    expect(ledgerPath({ HOME: "/home/u" }).replace(/\\/g, "/")).toBe("/home/u/.himmel/ci-queue.jsonl");
  });
});

describe("reduce", () => {
  const J = jobAttrs();
  test("submit→claim→dispatch→verdict→complete yields done", () => {
    const st = reduce([
      { t: "submit", ts: "t", job: J },
      { t: "claim", ts: "t", jobId: J.id, daemon: "vm", lease: "2026-07-05T01:00:00Z" },
      { t: "dispatch", ts: "t", jobId: J.id, lane: "act-exec", runId: "r1" },
      { t: "verdict", ts: "t", jobId: J.id, conclusion: "success" },
      { t: "complete", ts: "t", jobId: J.id },
    ]);
    expect(st.get(J.id)!.status).toBe("done");
    expect(st.get(J.id)!.conclusion).toBe("success");
  });

  test("expired lease makes a claimed job re-claimable", () => {
    const st = reduce([
      { t: "submit", ts: "t", job: J },
      { t: "claim", ts: "t", jobId: J.id, daemon: "vm", lease: "2026-07-05T00:00:00Z" },
      { t: "lease-expire", ts: "t", jobId: J.id },
    ]);
    expect(st.get(J.id)!.status).toBe("queued");
    expect(st.get(J.id)!.lease).toBeUndefined();
  });

  test("lease-expire AFTER a verdict does not resurrect the job", () => {
    const st = reduce([
      { t: "submit", ts: "t", job: J },
      { t: "claim", ts: "t", jobId: J.id, daemon: "vm", lease: "x" },
      { t: "dispatch", ts: "t", jobId: J.id, lane: "act-exec", runId: "r" },
      { t: "verdict", ts: "t", jobId: J.id, conclusion: "failure" },
      { t: "lease-expire", ts: "t", jobId: J.id },
    ]);
    expect(st.get(J.id)!.status).toBe("verdict-known");
  });

  test("events for an unknown job are ignored", () => {
    const st = reduce([{ t: "claim", ts: "t", jobId: "ghost", daemon: "vm", lease: "x" }]);
    expect(st.size).toBe(0);
  });
});

describe("appendEvent + readState round-trip", () => {
  test("persists then reduces from a temp ledger", () => {
    const p = join(mkdtempSync(join(tmpdir(), "ci-ledger-")), "q.jsonl");
    const J = jobAttrs();
    appendEvent({ t: "submit", ts: "t", job: J }, {}, p);
    appendEvent({ t: "claim", ts: "t", jobId: J.id, daemon: "vm", lease: "2026-07-05T00:00:00Z" }, {}, p);
    const st = readState({}, p);
    expect(st.get(J.id)!.status).toBe("claimed");
    expect(st.get(J.id)!.claimant).toBe("vm");
  });

  test("missing ledger file yields empty state", () => {
    const st = readState({}, join(tmpdir(), "ci-nope-" + Date.now() + ".jsonl"));
    expect(st.size).toBe(0);
  });
});
