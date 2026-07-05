// scripts/ci-orchestrator/src/adapters/types.ts
// HIMMEL-502 P3.1 — the lane adapter interface (one seam for all five lanes).
//
// Every lane is driven behind ONE interface so the scheduler (P3.2) routes and
// dispatches lane-agnostically. Adapter↔lane cardinality is 1:1 with the five
// LaneNames (I3), so `name` stays a single LaneName and type-checks. A `native`
// adapter (self-hosted-runner) is GitHub-SCHEDULED, not orchestrator-dispatched:
// its dispatch() is an observe-only no-op (the native `on: pull_request` run is
// already scheduled by GitHub; the adapter only observes via poll).
import { type JobAttrs } from "../ledger.js";
import { type LaneName } from "../routing.js";

// The terminal + in-flight statuses a poll can report. Maps onto the ledger
// verdict conclusions for terminal states (success/failure/cancelled).
export type PollStatus = "queued" | "running" | "success" | "failure" | "cancelled";

export function isTerminal(s: PollStatus): boolean {
  return s === "success" || s === "failure" || s === "cancelled";
}

export interface LaneAdapter {
  name: LaneName; // the production lane this adapter drives (1:1)
  native?: boolean; // observe-only path (I2): dispatch() is a no-op
  available(): Promise<{ up: boolean; inFlight: number; cap: number }>;
  dispatch(job: JobAttrs): Promise<{ runId: string }>; // no-op for native adapters
  poll(runId: string): Promise<{ status: PollStatus }>;
}

// Injected shell-out for the real adapters (act-run.sh, gh). Kept injectable so
// every adapter test asserts the composed command + status parsing WITHOUT real
// execution (hermetic rule). Returns the captured stdout/stderr + exit code.
export type ExecFn = (
  file: string,
  args: string[],
) => Promise<{ stdout: string; stderr: string; code: number }>;
