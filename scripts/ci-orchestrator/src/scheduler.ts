// scripts/ci-orchestrator/src/scheduler.ts
// HIMMEL-502 P3.2 — the scheduler supervisor loop (one scheduling pass = tick()).
//
// One pass: discover git work → planSubmission (doc-only skip + content-hash
// dedup, P2.6) → submit the enqueue set → route each queued job (P2.3) → for a
// DISPATCHED lane grantClaim (P2.2) + adapter.dispatch + append `dispatch`; for a
// NATIVE lane append an observe-only `dispatch` (no real call) → poll running
// jobs → append `verdict` on terminal → post required-check verdicts via the
// reporter for DISPATCHED lanes ONLY (native lanes are already surfaced by the
// native `on: pull_request` run — re-posting would duplicate), then
// reporter.retryUnposted to drain any GitHub-was-down backlog.
//
// All I/O is injected (discover, adapters, clock, reporter, gh) so tick() is
// unit-testable with zero real minutes / VM / GitHub.
import { appendEvent, readState, type JobAttrs, type JobState } from "./ledger.js";
import { grantClaim } from "./lease.js";
import { route, type LaneAvailability, type LaneName } from "./routing.js";
import { planSubmission } from "./dedup.js";
import { type WorkProfile } from "./workprofile.js";
import { type ActMatrix } from "./act-matrix.js";
import { type LaneAdapter, type PollStatus, isTerminal } from "./adapters/types.js";
import { type Reporter, type GhStatusFn } from "./reporter.js";

// Priority score: required jobs get a head start, but a linear age term
// guarantees any queued job's score eventually exceeds a fixed-priority
// newcomer's — so an old non-required job cannot be starved forever (I4, true
// aging). Aging fixes QUEUE-ORDER fairness (an old job is SELECTED before a
// newcomer); it does NOT overcome lane-capacity starvation (an accepted v1
// boundary — if the only eligible lane is permanently saturated, no ordering
// helps).
export const W_REQUIRED = 100;
export const AGE_UNIT_MS = 60_000; // one age unit = 1 minute of wait

export function score(job: JobAttrs, now: number): number {
  const ageMs = Math.max(0, now - Date.parse(job.enqueuedAt));
  return (job.required ? W_REQUIRED : 0) + ageMs / AGE_UNIT_MS;
}

export type TickReport = {
  submitted: string[];
  reused: string[];
  dispatched: { jobId: string; lane: LaneName }[];
  deferred: string[];
  verdicts: { jobId: string; conclusion: string }[];
  posted: string[];
  deadLettered: string[]; // required verdicts the reporter gave up on (permanent error / attempt cap) — surfaced, not silently retried forever (HIMMEL-714)
};

export type SchedulerDeps = {
  discover: () => JobAttrs[]; // git poll → candidate jobs for this pass
  changedFiles: () => string[]; // for planSubmission (doc-only detection)
  adapters: LaneAdapter[];
  actMatrix: ActMatrix;
  reporter: Reporter;
  gh: GhStatusFn;
  workProfile: WorkProfile;
  loadBelowThreshold: boolean;
  privateMinutesHeadroom: boolean;
  githubUp: boolean;
  now: () => number; // injected clock (epoch ms)
  daemonId?: string; // default "vm"
  leaseTtlMs?: number; // default 15 min
  env?: Record<string, string | undefined>;
  ledgerPath?: string; // test override
};

function mapConclusion(s: PollStatus): "success" | "failure" | "cancelled" {
  return s === "success" ? "success" : s === "cancelled" ? "cancelled" : "failure";
}

// Count in-flight (running) jobs per lane from the reduced ledger state. This is
// the authoritative inFlight the scheduler enforces caps against (an adapter's
// own available().inFlight is best-effort; the ledger is the source of truth).
function countRunning(state: Map<string, JobState>): Record<string, number> {
  const counts: Record<string, number> = {};
  for (const js of state.values()) {
    if (js.status === "running" && js.lane) counts[js.lane] = (counts[js.lane] ?? 0) + 1;
  }
  return counts;
}

// One scheduling pass. Pure-ish: every side-effect goes through injected deps or
// the (test-overridable) ledger path.
export async function tick(deps: SchedulerDeps): Promise<TickReport> {
  const env = deps.env ?? {};
  const path = deps.ledgerPath;
  const now = deps.now();
  const nowIso = new Date(now).toISOString();
  const daemon = deps.daemonId ?? "vm";
  const ttl = deps.leaseTtlMs ?? 15 * 60_000;
  const byName = new Map<LaneName, LaneAdapter>(deps.adapters.map((a) => [a.name, a]));
  const report: TickReport = { submitted: [], reused: [], dispatched: [], deferred: [], verdicts: [], posted: [], deadLettered: [] };

  // 1. Discover + plan submission (doc-only skip + dedup). Only genuinely new
  //    jobs are submitted (a job already in the ledger is not re-submitted).
  const priorState = readState(env, path);
  const candidates = deps.discover();
  const { enqueue, reused } = planSubmission(candidates, deps.changedFiles(), priorState);
  for (const job of enqueue) {
    if (priorState.has(job.id)) continue;
    appendEvent({ t: "submit", ts: nowIso, job }, env, path);
    report.submitted.push(job.id);
  }
  for (const r of reused) report.reused.push(r.job.id);

  // 2. Assemble lane availability (up/cap from adapters; inFlight from the
  //    ledger, incremented in-tick as we dispatch so caps hold within one pass).
  const laneAvail = await buildLaneAvailability(deps.adapters, readState(env, path));

  // 3. Route each queued job, highest score first (required head start + aging).
  const queued = [...readState(env, path).values()].filter((js) => js.status === "queued");
  queued.sort((a, b) => score(b.attrs, now) - score(a.attrs, now));
  for (const js of queued) {
    const decision = route({
      job: js.attrs,
      lanes: laneAvail,
      workProfile: deps.workProfile,
      loadBelowThreshold: deps.loadBelowThreshold,
      privateMinutesHeadroom: deps.privateMinutesHeadroom,
      actMatrix: deps.actMatrix,
      githubUp: deps.githubUp,
    });
    if (decision.lane === "defer") {
      report.deferred.push(js.attrs.id);
      continue;
    }
    const adapter = byName.get(decision.lane);
    if (!adapter) {
      report.deferred.push(js.attrs.id); // no adapter wired for the chosen lane
      continue;
    }
    if (adapter.native) {
      // Observe-only: the native `on: pull_request` run is GitHub-scheduled; we
      // record a dispatch (status→running) and observe it via poll — no real call.
      const runId = `native-${decision.lane}-${js.attrs.id}`;
      appendEvent({ t: "dispatch", ts: nowIso, jobId: js.attrs.id, lane: decision.lane, runId }, env, path);
      report.dispatched.push({ jobId: js.attrs.id, lane: decision.lane });
      laneAvail[decision.lane].inFlight += 1;
      continue;
    }
    // Dispatched lane: claim first (single-writer lease), then fire.
    const claim = grantClaim(js.attrs.id, daemon, ttl, now, env, path);
    if (!claim.ok) continue; // already claimed elsewhere — leave queued
    const { runId } = await adapter.dispatch(js.attrs);
    appendEvent({ t: "dispatch", ts: nowIso, jobId: js.attrs.id, lane: decision.lane, runId }, env, path);
    report.dispatched.push({ jobId: js.attrs.id, lane: decision.lane });
    laneAvail[decision.lane].inFlight += 1; // enforce cap within the tick
  }

  // 4. Poll running jobs → append a verdict on a terminal poll.
  for (const js of readState(env, path).values()) {
    if (js.status !== "running" || !js.runId || !js.lane) continue;
    const adapter = byName.get(js.lane as LaneName);
    if (!adapter) continue;
    const { status } = await adapter.poll(js.runId);
    if (!isTerminal(status)) continue;
    const conclusion = mapConclusion(status);
    appendEvent({ t: "verdict", ts: nowIso, jobId: js.attrs.id, conclusion }, env, path);
    report.verdicts.push({ jobId: js.attrs.id, conclusion });
  }

  // 5. Report required-check verdicts for DISPATCHED lanes only, then complete.
  //    Native-lane verdicts are ALREADY surfaced as GitHub checks by the native
  //    run — re-posting would duplicate/conflict, so we NEVER post them (only
  //    complete them).
  for (const js of readState(env, path).values()) {
    if (js.status !== "verdict-known") continue;
    const adapter = js.lane ? byName.get(js.lane as LaneName) : undefined;
    const native = !!adapter?.native;
    let posted = js.statusPosted ?? false;
    if (js.attrs.required && !native && !posted) {
      const res = await deps.reporter.postVerdict(js.attrs, js.conclusion ?? "failure", deps.gh);
      if (res.posted) {
        appendEvent({ t: "status-posted", ts: nowIso, jobId: js.attrs.id }, env, path);
        report.posted.push(js.attrs.id);
        posted = true;
      }
    }
    // Complete once fully handled: native (GitHub reported it), non-required (no
    // gate to satisfy), or a posted required verdict. A required verdict that
    // could not be posted (GitHub down) stays verdict-known for retryUnposted.
    if (native || !js.attrs.required || posted) {
      appendEvent({ t: "complete", ts: nowIso, jobId: js.attrs.id }, env, path);
    }
  }

  // 6. Drain any still-unposted backlog (prior ticks where GitHub was down).
  //    Dead-lettered required verdicts (permanent error / attempt cap) are
  //    surfaced in the report so a wedged required check is visible rather than
  //    retried forever (HIMMEL-714).
  const drain = await deps.reporter.retryUnposted(readState(env, path), deps.gh);
  report.deadLettered = drain.deadLettered;

  return report;
}

// Build the LaneAvailability route() consumes: up/cap from each adapter's
// available(); inFlight recomputed from the ledger (authoritative) so the cap the
// scheduler enforces is the real running count, not an adapter's best estimate.
async function buildLaneAvailability(
  adapters: LaneAdapter[],
  state: Map<string, JobState>,
): Promise<LaneAvailability> {
  const running = countRunning(state);
  const all: LaneName[] = ["self-hosted-runner", "private-gha-hosted", "act-exec", "public-fork", "local-exec"];
  const byName = new Map<LaneName, LaneAdapter>(adapters.map((a) => [a.name, a]));
  const out = {} as LaneAvailability;
  for (const name of all) {
    const adapter = byName.get(name);
    if (!adapter) {
      out[name] = { up: false, inFlight: running[name] ?? 0, cap: 0, native: false };
      continue;
    }
    const a = await adapter.available();
    out[name] = { up: a.up, inFlight: running[name] ?? 0, cap: a.cap, native: adapter.native };
  }
  return out;
}
