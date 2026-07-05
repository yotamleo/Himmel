// scripts/ci-orchestrator/src/adapters/act-exec.ts
// HIMMEL-502 P3.5 — the act-exec backbone adapter (dispatched).
//
// Shells to scripts/ci-orchestrator/bin/act-run.sh (the P1.2 executor) to run one
// workflow job via nektos/act in Docker, GitHub-independently. `exec` is injected
// so this file is hermetic — the adapter test asserts the composed command +
// status parsing, never runs Docker. available() reflects Docker/act presence
// (injected probe) + the enforced per-lane cap.
import { type JobAttrs } from "../ledger.js";
import { type LaneAdapter, type ExecFn, type PollStatus } from "./types.js";

export type ActExecOptions = {
  exec: ExecFn;
  actRunPath: string; // absolute path to bin/act-run.sh
  cap?: number; // per-lane concurrency cap (default 1 — one VM)
  dockerAvailable: () => Promise<boolean>; // injected Docker/act probe
  inFlight?: () => number; // best-effort in-flight (scheduler recomputes from ledger)
};

// act-run.sh prints one JSON line: {"job","runId","status"}. poll reads the
// recorded exit-status file via act-run.sh's status subcommand.
export function makeActExecAdapter(opts: ActExecOptions): LaneAdapter {
  const cap = opts.cap ?? 1;
  return {
    name: "act-exec",
    async available() {
      const up = await opts.dockerAvailable();
      return { up, inFlight: opts.inFlight ? opts.inFlight() : 0, cap };
    },
    async dispatch(job: JobAttrs): Promise<{ runId: string }> {
      const { stdout, code } = await opts.exec(opts.actRunPath, [job.job, "--os", job.os]);
      if (code !== 0) throw new Error(`act-run.sh exited ${code} for ${job.job}`);
      const line = stdout.trim().split("\n").filter(Boolean).pop() ?? "{}";
      const parsed = JSON.parse(line) as { runId?: string };
      if (!parsed.runId) throw new Error(`act-run.sh returned no runId for ${job.job}`);
      return { runId: parsed.runId };
    },
    async poll(runId: string): Promise<{ status: PollStatus }> {
      const { stdout } = await opts.exec(opts.actRunPath, ["--status", runId]);
      return { status: parseActStatus(stdout.trim()) };
    },
  };
}

// act-run.sh --status prints one of: queued|running|success|failure|cancelled.
export function parseActStatus(s: string): PollStatus {
  const last = s.split("\n").filter(Boolean).pop() ?? "";
  if (last === "success" || last === "failure" || last === "cancelled" || last === "running" || last === "queued") {
    return last;
  }
  return "failure"; // unknown/garbled status → conservative failure (never silently green)
}
