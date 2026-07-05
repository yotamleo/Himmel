// scripts/ci-orchestrator/src/reporter.ts
// HIMMEL-502 P3.6 — the required-check reporter (resolves OQ3).
//
// Writes a job's verdict to the GitHub Checks / commit-status API at
// `job.headSha` — ALWAYS the PR head, NEVER `runSha` (M2). Because a public-fork
// verdict has runSha = the propagated commit ≠ headSha, posting to headSha means
// a fork verdict can never masquerade as a private required check BY
// CONSTRUCTION (no verbal contract needed). Compute never waits on GitHub: when
// the status writer throws the verdict is kept `verdict-known, status-unposted`
// and re-attempted on the next scheduler pass (OQ3). V1 BOUNDARY: every throw is
// treated as transient (retry) and there is no attempt cap / backoff / dead-letter
// yet — a PERMANENT error (bad sha, auth, 4xx) would re-attempt every pass until
// the job is otherwise resolved. Error classification + bounded backoff + a
// dead-letter are a tracked follow-up (HIMMEL-502 P3 hardening), not wired here.
import { type JobAttrs, type JobState } from "./ledger.js";

// Injected GitHub status writer. The real caller passes a `gh api ...` shell-out;
// tests pass a spy. Throwing signals GitHub-unreachable (→ status-unposted).
export type GhStatusFn = (args: {
  sha: string;
  conclusion: string;
  context: string;
}) => Promise<void>;

export type PostResult = { posted: boolean };

export type Reporter = {
  // Post ONE verdict to job.headSha. Returns {posted:false} (never throws) when
  // GitHub is unreachable so the scheduler can keep the verdict and retry.
  postVerdict(job: JobAttrs, conclusion: string, gh: GhStatusFn): Promise<PostResult>;
  // Drain the backlog: post every verdict-known, required, still-unposted job.
  // Returns the jobIds successfully posted this pass.
  retryUnposted(state: Map<string, JobState>, gh: GhStatusFn): Promise<{ posted: string[] }>;
};

// The Checks context string for a job — stable per (workflow, job, os) so the
// posted status maps 1:1 to a required-check name.
export function checkContext(job: JobAttrs): string {
  return `ci-orch/${job.workflow}:${job.job} (${job.os})`;
}

export function makeReporter(): Reporter {
  async function postVerdict(job: JobAttrs, conclusion: string, gh: GhStatusFn): Promise<PostResult> {
    try {
      await gh({ sha: job.headSha, conclusion, context: checkContext(job) });
      return { posted: true };
    } catch {
      // GitHub unreachable — keep the verdict, retry later (OQ3). Never throw.
      return { posted: false };
    }
  }

  async function retryUnposted(state: Map<string, JobState>, gh: GhStatusFn): Promise<{ posted: string[] }> {
    const posted: string[] = [];
    for (const js of state.values()) {
      if (js.status !== "verdict-known") continue;
      if (!js.attrs.required || js.statusPosted) continue;
      const res = await postVerdict(js.attrs, js.conclusion ?? "failure", gh);
      if (res.posted) posted.push(js.attrs.id);
    }
    return { posted };
  }

  return { postVerdict, retryUnposted };
}
