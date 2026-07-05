// scripts/ci-orchestrator/src/routing.ts
// HIMMEL-502 P2.3 — the pure routing decision function (the heart of the system).
//
// PURE: no I/O. Given a job, live lane availability, host work-profile, private-
// minute headroom, the act matrix, and github reachability, it returns the chosen
// lane or `defer`. There is NO "skip" return — the never-skip constraint is
// enforced at the type level (a job is only ever routed or deferred).
import { type JobAttrs } from "./ledger.js";
import { type ActMatrix } from "./act-matrix.js";

export type LaneName =
  | "self-hosted-runner"
  | "private-gha-hosted"
  | "act-exec"
  | "public-fork"
  | "local-exec";

// Native lanes (self-hosted-runner, private-gha-hosted) are GitHub-SCHEDULED, not
// orchestrator-dispatched: their up/inFlight come from runner + native-run status
// and `cap` is informational (GitHub schedules, we observe). Dispatched lanes
// (act-exec, public-fork, local-exec) enforce `cap` in the scheduler.
export type LaneAvailability = Record<LaneName, { up: boolean; inFlight: number; cap: number; native?: boolean }>;

export type RoutingInputs = {
  job: JobAttrs;
  lanes: LaneAvailability;
  workProfile: "focus" | "shared" | "drain";
  loadBelowThreshold: boolean;
  privateMinutesHeadroom: boolean; // from quota.ts: below the ≤70% cap target
  actMatrix: ActMatrix;
  githubUp: boolean;
};

export type RoutingDecision = { lane: LaneName; reason: string } | { lane: "defer"; reason: string };

// act-exec is eligible for a job iff: the job's OS leg is linux, the matrix entry
// exists and is not gha-only, the lane is up, and it is under its concurrency cap.
function actEligible(inp: RoutingInputs): boolean {
  const { job, lanes, actMatrix } = inp;
  if (job.os !== "linux") return false;
  const entry = actMatrix[`${job.workflow}:${job.job}`];
  if (!entry || entry.fidelity === "gha-only") return false;
  const lane = lanes["act-exec"];
  return lane.up && lane.inFlight < lane.cap;
}

function underCap(l: { up: boolean; inFlight: number; cap: number }): boolean {
  return l.up && l.inFlight < l.cap;
}

// Routing order (spec §Guard, encoded as an ordered guard). Earlier rules win.
export function route(inp: RoutingInputs): RoutingDecision {
  const { job, lanes, workProfile, loadBelowThreshold, privateMinutesHeadroom, githubUp } = inp;

  // 1. Required LIGHT gate: runner ▸ private-gha-hosted (fallback) ▸ act-exec
  //    (only if github is down). Never depends on capped hosted minutes here.
  if (job.required && !job.heavy) {
    if (lanes["self-hosted-runner"].up) {
      return { lane: "self-hosted-runner", reason: "required light gate → self-hosted runner (up)" };
    }
    if (githubUp && lanes["private-gha-hosted"].up) {
      return { lane: "private-gha-hosted", reason: "required light gate → hosted GHA (runner down)" };
    }
    if (!githubUp && actEligible(inp)) {
      return { lane: "act-exec", reason: "required light gate → act backbone (github down)" };
    }
    // else fall through (runner+hosted down but github up, or act ineligible)
  }

  // 2. Everything else → act-exec if linux, not gha-only, under cap.
  if (actEligible(inp)) {
    return { lane: "act-exec", reason: "linux, act-faithful, under cap → act backbone" };
  }

  // 3. publicSafe post-merge (non-required) → public-fork if github is up.
  //    NEVER a pre-merge required check.
  if (job.publicSafe && !job.required && githubUp && underCap(lanes["public-fork"])) {
    return { lane: "public-fork", reason: "public-safe non-required, github up → public fork" };
  }

  // 4. required && needsSecrets, backbone saturated/down, with headroom →
  //    private-gha-hosted. Also the ONLY pre-merge win/mac path.
  if (job.required && job.needsSecrets && privateMinutesHeadroom && lanes["private-gha-hosted"].up) {
    return { lane: "private-gha-hosted", reason: "required+secrets, backbone unavailable, headroom → hosted GHA" };
  }

  // 5. local-exec only if the host is shared/drain AND load is below threshold.
  if (
    (workProfile === "shared" || workProfile === "drain") &&
    loadBelowThreshold &&
    underCap(lanes["local-exec"])
  ) {
    return { lane: "local-exec", reason: `local-exec (workProfile=${workProfile}, load below threshold)` };
  }

  // 6. else defer (never skip — backpressure, the job stays queued).
  return { lane: "defer", reason: "no eligible lane under cap → defer (never skipped)" };
}
