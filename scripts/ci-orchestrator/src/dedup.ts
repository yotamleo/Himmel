// scripts/ci-orchestrator/src/dedup.ts
// HIMMEL-502 P2.6 — submit-time reductions (resolves B5).
//
// The two trivially-safe reductions the spec §Guard explicitly allows. These are
// ROUTING, not skips: a reduced job is either not-enqueued (its check reuses a
// prior verdict) or replaced by the doc-check subset — never dropped silently.
//   (1) doc-only diff → keep only the doc-safe light gate, drop the code matrix.
//   (2) content-hash dedup: a `deterministic` job whose treeHash matches a prior
//       success verdict is reused, not re-run. `deterministic:false` is ALWAYS
//       enqueued (never reused).
import { type JobAttrs, type JobState } from "./ledger.js";

// The doc-safe light gate — these ALWAYS run (they are marked deterministic:false
// by discovery so rule (2) never dedup-reuses them). Named constants, not inferred.
export const DOC_SAFE_JOBS = new Set<string>(["secret-scan", "commit-lint", "lint"]);
// The heavy code-matrix jobs dropped on a doc-only diff.
export const CODE_MATRIX_JOBS = new Set<string>(["node-suites", "bun-suites", "security-scan", "shell-unit"]);

export type SubmissionPlan = {
  enqueue: JobAttrs[];
  reused: { job: JobAttrs; fromTreeHash: string }[];
};

// A changed file is a doc file iff it is a top-level/any *.md or lives under docs/.
function isDocFile(f: string): boolean {
  return /\.md$/i.test(f) || f.startsWith("docs/");
}

// True iff there is at least one changed file and EVERY changed file is a doc.
function isDocOnly(changedFiles: string[]): boolean {
  return changedFiles.length > 0 && changedFiles.every(isDocFile);
}

// Find a prior successful verdict for THIS job on THIS tree content. Dedup must
// match job IDENTITY (job name + os), not just the tree hash — otherwise a
// different deterministic job that passed on the same tree would lend its verdict,
// silently skipping a real check (a never-skip violation). treeHash is the content
// key; (job, os) is the identity key.
function priorSuccess(prior: Map<string, JobState>, job: JobAttrs): boolean {
  for (const js of prior.values()) {
    if (
      js.attrs.job === job.job &&
      js.attrs.os === job.os &&
      js.attrs.treeHash === job.treeHash &&
      js.conclusion === "success"
    ) {
      return true;
    }
  }
  return false;
}

// Plan which candidate jobs to enqueue vs reuse. NEVER drops a job silently: a
// doc-only diff keeps the doc-safe gate (only the code matrix is reduced), and a
// dedup match moves a job to `reused` (its prior verdict is reapplied).
export function planSubmission(
  candidates: JobAttrs[],
  changedFiles: string[],
  prior: Map<string, JobState>,
): SubmissionPlan {
  const docOnly = isDocOnly(changedFiles);
  const pool = docOnly ? candidates.filter((c) => DOC_SAFE_JOBS.has(c.job)) : candidates;

  const enqueue: JobAttrs[] = [];
  const reused: { job: JobAttrs; fromTreeHash: string }[] = [];
  for (const job of pool) {
    if (job.deterministic && priorSuccess(prior, job)) {
      reused.push({ job, fromTreeHash: job.treeHash });
      continue;
    }
    enqueue.push(job);
  }
  return { enqueue, reused };
}
