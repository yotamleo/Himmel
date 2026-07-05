// scripts/ci-orchestrator/src/adapters/private-gha-hosted.ts
// HIMMEL-502 P3.5 — the private-gha-hosted adapter (dispatched, sparing).
//
// The only PRE-MERGE win/mac path (act/VM are Linux-only) — used sparingly under
// the private-minute cap. dispatch() first checks for an EXISTING native
// `on: pull_request` run for (headSha, job): if present it OBSERVES that run
// (no new spend); else it issues a `workflow_dispatch`. `exec` (a `gh` shell-out)
// is injected for hermetic tests.
import { type JobAttrs } from "../ledger.js";
import { type LaneAdapter, type ExecFn, type PollStatus } from "./types.js";
import { parseGhRunStatus } from "./private-gha-native.js";

export type PrivateGhaHostedOptions = {
  exec: ExecFn; // a `gh` shell-out
  repo: string; // owner/repo
  workflowFile?: string; // default "ci.yml"
  cap?: number; // default 2
};

export function makePrivateGhaHostedAdapter(opts: PrivateGhaHostedOptions): LaneAdapter {
  const cap = opts.cap ?? 2;
  const workflow = opts.workflowFile ?? "ci.yml";
  return {
    name: "private-gha-hosted",
    async available() {
      // Hosted GHA is "up" whenever the API answers (the scheduler gates real use
      // behind privateMinutesHeadroom; this only reports reachability).
      const { code } = await opts.exec("gh", ["api", `/repos/${opts.repo}`, "--jq", ".id"]);
      return { up: code === 0, inFlight: 0, cap };
    },
    async dispatch(job: JobAttrs): Promise<{ runId: string }> {
      // 1. Observe an existing native run for this head SHA + THIS workflow, if
      //    any. Scoping to the workflow (HIMMEL-714) matters: a repo with >1
      //    workflow can have several runs at the same head SHA, and observing the
      //    wrong one attributes a sibling workflow's conclusion to this job. We
      //    scope server-side with `--workflow <file>` rather than a jq
      //    `.workflowName==<job.workflow>` filter because job.workflow is the
      //    workflow FILE basename (e.g. "ci") while the JSON `workflowName` is the
      //    display name (e.g. "CI") — they don't match, so a jq name filter would
      //    drop every run and break the observe path. `--workflow` accepts the
      //    file name and filters to exactly this adapter's workflow.
      const existing = await opts.exec("gh", [
        "run",
        "list",
        "--repo",
        opts.repo,
        "--workflow",
        workflow,
        "--json",
        "databaseId,headSha,workflowName,status",
        "--jq",
        `[.[] | select(.headSha=="${job.headSha}")] | .[0].databaseId // empty`,
      ]);
      const nativeRunId = existing.stdout.trim();
      if (existing.code === 0 && nativeRunId) {
        return { runId: nativeRunId }; // observe the native run — no new dispatch/spend
      }
      // 2. No native run → issue a workflow_dispatch (win/mac pre-merge path).
      const { code } = await opts.exec("gh", [
        "workflow",
        "run",
        workflow,
        "--repo",
        opts.repo,
        "--ref",
        job.headSha,
        "-f",
        `job=${job.job}`,
        "-f",
        `os=${job.os}`,
      ]);
      if (code !== 0) throw new Error(`workflow_dispatch failed for ${job.job} (${job.os})`);
      return { runId: `dispatch-${job.headSha}-${job.job}-${job.os}` };
    },
    async poll(runId: string): Promise<{ status: PollStatus }> {
      const { stdout, code } = await opts.exec("gh", ["run", "view", runId, "--json", "status,conclusion"]);
      if (code !== 0) return { status: "running" };
      return { status: parseGhRunStatus(stdout) };
    },
  };
}
