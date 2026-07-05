// scripts/ci-orchestrator/src/adapters/local-exec.ts
// HIMMEL-502 P3.5 — the local-exec adapter (dispatched, work-profile-gated).
//
// Runs a job directly on the local host (last resort, load-gated). available()
// consults resolveProfile (P2.4): the lane is only "up" when the host is
// shared/drain AND load is below threshold — protect-local in `focus`. `exec`
// (a direct `npm test` / job runner) is injected for hermetic tests.
import { type JobAttrs } from "../ledger.js";
import { type LaneAdapter, type ExecFn, type PollStatus } from "./types.js";
import { resolveProfile, type LoadSample } from "../workprofile.js";

export type LocalExecOptions = {
  exec: ExecFn; // the local job runner (e.g. npm test)
  runnerPath: string; // absolute path to the local run script
  sample: () => LoadSample; // live load sampler
  threshold: number;
  now?: () => Date;
  manualToggle?: () => "focus" | "shared" | "drain" | null;
  cap?: number; // default 1
};

export function makeLocalExecAdapter(opts: LocalExecOptions): LaneAdapter {
  const cap = opts.cap ?? 1;
  return {
    name: "local-exec",
    async available() {
      const { profile } = resolveProfile({
        manualToggle: opts.manualToggle ? opts.manualToggle() : null,
        now: opts.now ? opts.now() : new Date(),
        sample: opts.sample(),
        threshold: opts.threshold,
      });
      // "up" only when the host will actually lend cycles (shared/drain).
      const up = profile === "shared" || profile === "drain";
      return { up, inFlight: 0, cap };
    },
    async dispatch(job: JobAttrs): Promise<{ runId: string }> {
      const { code } = await opts.exec(opts.runnerPath, [job.job, "--os", job.os]);
      if (code !== 0) throw new Error(`local runner failed to launch ${job.job}`);
      return { runId: `local-${job.id}` };
    },
    async poll(runId: string): Promise<{ status: PollStatus }> {
      const { stdout } = await opts.exec(opts.runnerPath, ["--status", runId]);
      const last = stdout.trim().split("\n").filter(Boolean).pop() ?? "";
      if (last === "success" || last === "failure" || last === "cancelled" || last === "running" || last === "queued") {
        return { status: last };
      }
      return { status: "failure" };
    },
  };
}
