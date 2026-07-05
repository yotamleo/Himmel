import { describe, test, expect } from "vitest";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { mkdtempSync } from "node:fs";
import { appendEvent, type JobAttrs } from "../src/ledger.js";
import { grantClaim } from "../src/lease.js";

function freshLedger(): string {
  return join(mkdtempSync(join(tmpdir(), "ci-lease-")), "q.jsonl");
}
function jobAttrs(): JobAttrs {
  return {
    id: "j1", headSha: "h", runSha: "h", workflow: "ci", job: "lint", required: true,
    needsSecrets: false, publicSafe: false, os: "linux", heavy: false, deterministic: false,
    treeHash: "t", enqueuedAt: "t",
  };
}
const T0 = Date.parse("2026-07-05T00:00:00Z");

describe("grantClaim", () => {
  test("first claim wins; a second while the lease is live loses (deterministic)", () => {
    const p = freshLedger();
    const J = jobAttrs();
    appendEvent({ t: "submit", ts: "t", job: J }, {}, p);
    const a = grantClaim(J.id, "vm", 60000, T0, {}, p);
    const b = grantClaim(J.id, "vm", 60000, T0, {}, p);
    expect(a.ok).toBe(true);
    expect(b.ok).toBe(false);
  });

  test("a time-expired lease frees the job for a new claimant", () => {
    const p = freshLedger();
    const J = jobAttrs();
    appendEvent({ t: "submit", ts: "t", job: J }, {}, p);
    expect(grantClaim(J.id, "vm", 60000, T0, {}, p).ok).toBe(true);
    // 60s + 1ms later the first lease has expired.
    expect(grantClaim(J.id, "vm2", 60000, T0 + 60001, {}, p).ok).toBe(true);
  });

  test("heldBy reports the live holder; an explicit lease-expire re-opens it", () => {
    const p = freshLedger();
    const J = jobAttrs();
    appendEvent({ t: "submit", ts: "t", job: J }, {}, p);
    grantClaim(J.id, "vmA", 60000, T0, {}, p);
    const held = grantClaim(J.id, "vmB", 60000, T0, {}, p);
    expect(held.ok).toBe(false);
    if (held.ok === false) expect(held.heldBy).toBe("vmA");
    appendEvent({ t: "lease-expire", ts: "t", jobId: J.id }, {}, p);
    expect(grantClaim(J.id, "vmB", 60000, T0, {}, p).ok).toBe(true);
  });

  test("an unsubmitted job cannot be claimed", () => {
    expect(grantClaim("ghost", "vm", 1000, T0, {}, freshLedger()).ok).toBe(false);
  });
});
