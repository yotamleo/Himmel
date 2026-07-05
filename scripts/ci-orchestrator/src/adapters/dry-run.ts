// scripts/ci-orchestrator/src/adapters/dry-run.ts
// HIMMEL-502 P3.1 — the dry-run adapter (the integration test seam).
//
// Wraps a real adapter and RECORDS its dispatch calls to an in-memory array
// instead of firing them, so the whole scheduler loop is testable with no real
// minutes / VM / GitHub. It reuses the wrapped adapter's valid `name` rather than
// inventing a "dry-run" LaneName (which wouldn't type-check). available() +
// poll() delegate to the wrapped adapter so routing sees real up/cap; only
// dispatch() is intercepted.
import { type JobAttrs } from "../ledger.js";
import { type LaneAdapter, type PollStatus } from "./types.js";
import { type LaneName } from "../routing.js";

export type DryRunAdapter = LaneAdapter & {
  recorded: { lane: LaneName; jobId: string }[];
};

// Wrap `inner`. `pollStatus` (default "success") is what the recorded run reports
// so the loop can drive a job to a terminal verdict in tests without real work.
export function makeDryRunAdapter(inner: LaneAdapter, pollStatus: PollStatus = "success"): DryRunAdapter {
  const recorded: { lane: LaneName; jobId: string }[] = [];
  return {
    name: inner.name,
    native: inner.native,
    recorded,
    available: () => inner.available(),
    async dispatch(job: JobAttrs): Promise<{ runId: string }> {
      recorded.push({ lane: inner.name, jobId: job.id });
      return { runId: `dry-${inner.name}-${job.id}` };
    },
    async poll(_runId: string): Promise<{ status: PollStatus }> {
      return { status: pollStatus };
    },
  };
}
