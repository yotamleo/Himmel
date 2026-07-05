// scripts/ci-orchestrator/src/reporter.ts
// HIMMEL-502 P3.6 — the required-check reporter (resolves OQ3).
//
// Writes a job's verdict to the GitHub Checks / commit-status API at
// `job.headSha` — ALWAYS the PR head, NEVER `runSha` (M2). Because a public-fork
// verdict has runSha = the propagated commit ≠ headSha, posting to headSha means
// a fork verdict can never masquerade as a private required check BY
// CONSTRUCTION (no verbal contract needed). Compute never waits on GitHub: when
// the status writer throws the verdict is kept `verdict-known, status-unposted`
// and re-attempted on a later scheduler pass (OQ3).
//
// HIMMEL-714 (P3 hardening) wires the error classification + bounded backoff +
// dead-letter the P3 V1 boundary deferred:
//   - classifyGhError: a PERMANENT gh error (4xx — bad sha, auth, not-found) can
//     never be fixed by retrying, so it dead-letters immediately and is surfaced
//     rather than re-attempted every pass forever. TRANSIENT (5xx / network /
//     429 rate-limit / unknown shape) retries with bounded exponential backoff.
//   - dead-letter after `maxAttempts` transient failures so a poison verdict
//     cannot wedge the scheduler re-attempting a required check indefinitely.
// The attempt/backoff/dead-letter state is IN-MEMORY in the reporter closure
// (never the append-only ledger — the single ledger writer is the VM daemon).
// INVARIANT: the caller MUST construct the reporter ONCE and reuse the instance
// across passes (the scheduler injects it as a persistent dep) — a per-pass
// reporter would reset the counters and defeat backoff + dead-letter.
import { type JobAttrs, type JobState } from "./ledger.js";

// Injected GitHub status writer. The real caller passes a `gh api ...` shell-out;
// tests pass a spy. Throwing signals a failed post; the thrown error MAY carry a
// numeric `status`/`httpStatus` (HTTP status) or an explicit `permanent` boolean
// so the reporter can tell a retryable outage from a permanent 4xx.
export type GhStatusFn = (args: {
  sha: string;
  conclusion: string;
  context: string;
}) => Promise<void>;

export type PostResult = { posted: boolean; deadLettered?: boolean };

export type Reporter = {
  // Post ONE verdict to job.headSha. Returns {posted:false} (never throws) when
  // the post fails and is still retryable; {posted:false, deadLettered:true} when
  // the job is dead-lettered (permanent error or attempt cap reached).
  postVerdict(job: JobAttrs, conclusion: string, gh: GhStatusFn): Promise<PostResult>;
  // Drain the backlog: post every verdict-known, required, still-unposted job
  // that is neither dead-lettered nor in backoff. Returns the jobIds posted this
  // pass and the jobIds that are dead-lettered (surfaced so a wedged required
  // check is visible instead of silently retried forever).
  retryUnposted(state: Map<string, JobState>, gh: GhStatusFn): Promise<{ posted: string[]; deadLettered: string[] }>;
};

export type ReporterOptions = {
  now?: () => number; // injected clock (epoch ms); default Date.now
  maxAttempts?: number; // dead-letter after this many transient failures; default 5
  baseBackoffMs?: number; // first-retry backoff; default 1000
  maxBackoffMs?: number; // backoff ceiling; default 5 min
};

export type ErrorClass = "transient" | "permanent";

function extractStatus(err: unknown): number | undefined {
  if (err && typeof err === "object") {
    const o = err as Record<string, unknown>;
    if (typeof o.status === "number") return o.status;
    if (typeof o.httpStatus === "number") return o.httpStatus;
  }
  return undefined;
}

// Classify a failed-post error. PERMANENT = a 4xx the retry can never fix (bad
// sha 404/422, auth 401/403) — dead-letter + surface, don't wedge the pass.
// TRANSIENT = 5xx / network / 429 rate-limit / unknown shape — retry with
// backoff. Unknown shape defaults to TRANSIENT (fail-open to the prior behaviour:
// keep the verdict and retry rather than silently drop it).
export function classifyGhError(err: unknown): ErrorClass {
  if (err && typeof err === "object") {
    const p = (err as Record<string, unknown>).permanent;
    if (p === true) return "permanent";
    if (p === false) return "transient";
  }
  const status = extractStatus(err);
  if (status === undefined) return "transient";
  if (status === 429) return "transient"; // rate-limited — back off, then retry
  if (status >= 400 && status < 500) return "permanent";
  return "transient"; // 5xx and anything else
}

// The Checks context string for a job — stable per (workflow, job, os) so the
// posted status maps 1:1 to a required-check name.
export function checkContext(job: JobAttrs): string {
  return `ci-orch/${job.workflow}:${job.job} (${job.os})`;
}

type AttemptRec = { attempts: number; nextRetryAt: number; deadLettered: boolean };

export function makeReporter(opts: ReporterOptions = {}): Reporter {
  const now = opts.now ?? Date.now;
  const maxAttempts = opts.maxAttempts ?? 5;
  const baseBackoffMs = opts.baseBackoffMs ?? 1000;
  const maxBackoffMs = opts.maxBackoffMs ?? 5 * 60_000;
  // In-memory per-job attempt state. Persists for the reporter's lifetime (the
  // scheduler reuses one instance across passes — see INVARIANT above).
  const attempts = new Map<string, AttemptRec>();

  function backoffMs(attempt: number): number {
    return Math.min(baseBackoffMs * 2 ** (attempt - 1), maxBackoffMs);
  }

  async function postVerdict(job: JobAttrs, conclusion: string, gh: GhStatusFn): Promise<PostResult> {
    const rec = attempts.get(job.id);
    if (rec?.deadLettered) return { posted: false, deadLettered: true };
    if (rec && rec.nextRetryAt > now()) return { posted: false }; // still in backoff — don't hit gh
    try {
      await gh({ sha: job.headSha, conclusion, context: checkContext(job) });
      attempts.delete(job.id); // recovered — clear the failure history
      return { posted: true };
    } catch (err) {
      const cur = rec ?? { attempts: 0, nextRetryAt: 0, deadLettered: false };
      if (classifyGhError(err) === "permanent") {
        cur.deadLettered = true;
        attempts.set(job.id, cur);
        return { posted: false, deadLettered: true };
      }
      cur.attempts += 1;
      if (cur.attempts >= maxAttempts) {
        cur.deadLettered = true;
        attempts.set(job.id, cur);
        return { posted: false, deadLettered: true };
      }
      cur.nextRetryAt = now() + backoffMs(cur.attempts);
      attempts.set(job.id, cur);
      return { posted: false };
    }
  }

  async function retryUnposted(
    state: Map<string, JobState>,
    gh: GhStatusFn,
  ): Promise<{ posted: string[]; deadLettered: string[] }> {
    const posted: string[] = [];
    const deadLettered: string[] = [];
    for (const js of state.values()) {
      if (js.status !== "verdict-known") continue;
      if (!js.attrs.required || js.statusPosted) continue;
      const res = await postVerdict(js.attrs, js.conclusion ?? "failure", gh);
      if (res.posted) posted.push(js.attrs.id);
      else if (res.deadLettered) deadLettered.push(js.attrs.id);
    }
    return { posted, deadLettered };
  }

  return { postVerdict, retryUnposted };
}
