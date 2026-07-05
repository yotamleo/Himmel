// scripts/ci-orchestrator/src/adapters/private-gha-native.ts
// HIMMEL-502 P3.5 — the self-hosted-runner adapter (OBSERVE-ONLY, native).
//
// The VM registered as a GitHub self-hosted runner runs native `on: pull_request`
// jobs — GitHub SCHEDULES them, we do not dispatch (I2). So dispatch() is a no-op:
// the adapter only OBSERVES. available() reports runner status from
// `gh api .../actions/runners`; poll() reads a native run's status via
// `gh run view`. `exec` (a `gh` shell-out) is injected for hermetic tests.
import { type JobAttrs } from "../ledger.js";
import { type LaneAdapter, type ExecFn, type PollStatus } from "./types.js";

export type PrivateGhaNativeOptions = {
  exec: ExecFn; // a `gh` shell-out
  repo: string; // owner/repo
  cap?: number; // informational (GitHub schedules; we observe) — default 1
};

export function makePrivateGhaNativeAdapter(opts: PrivateGhaNativeOptions): LaneAdapter {
  const cap = opts.cap ?? 1;
  return {
    name: "self-hosted-runner",
    native: true,
    async available() {
      // `gh api /repos/:repo/actions/runners` → runners[].status ("online").
      const { stdout, code } = await opts.exec("gh", [
        "api",
        `/repos/${opts.repo}/actions/runners`,
        "--jq",
        ".runners[] | select(.status==\"online\") | .id",
      ]);
      const up = code === 0 && stdout.trim().length > 0;
      return { up, inFlight: 0, cap };
    },
    async dispatch(_job: JobAttrs): Promise<{ runId: string }> {
      // Observe-only: NEVER shells a dispatch (I2). The native run is already
      // scheduled by GitHub; the scheduler records an observe-only dispatch and
      // polls. Returning a marker runId keeps the interface total.
      throw new Error("self-hosted-runner is observe-only: native GHA schedules the run; dispatch is a no-op");
    },
    async poll(runId: string): Promise<{ status: PollStatus }> {
      const { stdout, code } = await opts.exec("gh", ["run", "view", runId, "--json", "status,conclusion"]);
      if (code !== 0) return { status: "running" }; // transient — keep observing
      return { status: parseGhRunStatus(stdout) };
    },
  };
}

// Map a `gh run view --json status,conclusion` payload to a PollStatus.
export function parseGhRunStatus(json: string): PollStatus {
  let parsed: { status?: string; conclusion?: string | null };
  try {
    parsed = JSON.parse(json) as { status?: string; conclusion?: string | null };
  } catch {
    return "running";
  }
  if (parsed.status !== "completed") return parsed.status === "queued" ? "queued" : "running";
  if (parsed.conclusion === "success") return "success";
  if (parsed.conclusion === "cancelled") return "cancelled";
  return "failure";
}
