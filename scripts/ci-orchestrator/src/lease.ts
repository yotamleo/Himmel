// scripts/ci-orchestrator/src/lease.ts
// HIMMEL-502 P2.2 — VM-internal claim/lease grant.
//
// grantClaim runs ONLY inside the VM daemon, called by the HTTP /claim handler
// (P3.3). Because the VM's single Node event loop handles /claim SEQUENTIALLY,
// grantClaim sees a consistent state and appends at most one winning `claim` per
// pass — there is no second writer and no shared-file CAS (OQ1 B2/B3). The real
// two-clients-racing guarantee is tested at the HTTP layer (P3.3); here we unit-
// test the sequential grant logic + deterministic tiebreak.
//
// LOAD-BEARING INVARIANT: readState + appendEvent (P2.1) are SYNCHRONOUS, so
// grantClaim's read→check→append is one synchronous critical section the single
// event loop cannot interleave. grantClaim MUST stay fully synchronous (no await
// between read-state and append) — an async readState would open an interleaving
// hole where two /claim handlers both see the job free. The P3.3 Promise.all race
// test is what would catch a regression here.
import { appendEvent, readState, type JobState } from "./ledger.js";

export type ClaimResult =
  | { ok: true; lease: string }
  | { ok: false; heldBy?: string };

// A job is claimable iff it is queued, OR it is claimed but its lease has expired
// by time `now` (a time-expired lease frees the job even without an explicit
// lease-expire event). Terminal / in-flight states (running/verdict-known/done)
// are never claimable.
function claimable(js: JobState, now: number): boolean {
  if (js.status === "queued") return true;
  if (js.status === "claimed") {
    if (!js.lease) return true;
    return Date.parse(js.lease) <= now;
  }
  return false;
}

// Grant a claim on `jobId` to `claimant` for `ttlMs`, as of `now` (epoch ms).
// Returns {ok:true, lease} on success (a `claim` event is appended), else
// {ok:false, heldBy} where heldBy is the daemon holding the live lease (if any).
// The tiebreak for same-instant claims is deterministic: the first grantClaim
// call to append wins (sequential event-loop order), so a second call while the
// lease is live always loses — behavior is defined, not undefined.
export function grantClaim(
  jobId: string,
  claimant: string,
  ttlMs: number,
  now: number,
  env: Record<string, string | undefined> = process.env,
  path?: string,
): ClaimResult {
  const js = readState(env, path).get(jobId);
  if (!js) return { ok: false }; // not submitted — nothing to claim
  if (!claimable(js, now)) {
    return { ok: false, heldBy: js.claimant };
  }
  const lease = new Date(now + ttlMs).toISOString();
  appendEvent({ t: "claim", ts: new Date(now).toISOString(), jobId, daemon: claimant, lease }, env, path);
  return { ok: true, lease };
}
