// scripts/ci-orchestrator/src/ledger.ts
// HIMMEL-502 P2.1 — the CI queue event ledger.
//
// A single-writer, append-only JSONL event log, reduced to current state. Mirrors
// the quota-gauge.jsonl model the codebase already ships and hardened on Windows
// (atomic single-line O_APPEND). Leases are events in the SAME log (claim /
// lease-renew / lease-expire / complete) — no lockfile, no sqlite.
//
// The single writer is the VM daemon (OQ1 B2/B3): the local daemon never appends
// directly; all mutations go through the VM's HTTP API (P3.3), whose single Node
// event loop serializes them. The path resolver has a byte-identical bash twin at
// scripts/lib/ci-queue-ledger-path.sh (parity-tested).
import { appendFileSync, existsSync, mkdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { homedir } from "node:os";

// A CI job to run. `headSha` vs `runSha` exists so the reporter (P3.6) posts the
// required check to the PR head BY CONSTRUCTION, and a public-fork verdict
// (runSha = propagated commit ≠ headSha) can never be mistaken for a private
// required check (M2 / P4.1).
export type JobAttrs = {
  id: string;                 // stable per (headSha, workflow, job, os)
  headSha: string;            // the PR head — where the required check MUST be posted
  runSha: string;             // the SHA actually executed; == headSha except public-fork
  workflow: string;           // ci.yml file basename, e.g. "ci"
  job: string;                // e.g. "security-scan"
  required: boolean;
  needsSecrets: boolean;
  publicSafe: boolean;
  os: "linux" | "windows" | "macos";
  heavy: boolean;
  deterministic: boolean;     // eligible for content-hash dedup
  treeHash: string;           // for dedup
  enqueuedAt: string;         // ISO
};

export type CiEvent =
  | { t: "submit"; ts: string; job: JobAttrs }
  | { t: "claim"; ts: string; jobId: string; daemon: string; lease: string /*ISO expiry*/ }
  | { t: "lease-renew"; ts: string; jobId: string; lease: string }
  | { t: "lease-expire"; ts: string; jobId: string }
  | { t: "dispatch"; ts: string; jobId: string; lane: string; runId: string }
  | { t: "verdict"; ts: string; jobId: string; conclusion: "success" | "failure" | "cancelled" }
  | { t: "status-posted"; ts: string; jobId: string }
  | { t: "complete"; ts: string; jobId: string };

export type JobStatus = "queued" | "claimed" | "running" | "verdict-known" | "done";

export type JobState = {
  attrs: JobAttrs;
  status: JobStatus;
  lane?: string;
  runId?: string;
  lease?: string;
  claimant?: string;          // the daemon holding the live claim (from the claim event)
  conclusion?: string;
  statusPosted?: boolean;
};

// Ledger path resolver. $HIMMEL_CI_QUEUE_LEDGER if set, else
// <HOME>/.himmel/ci-queue.jsonl. PURE — the dir is created on append, not on
// resolve. Byte-identical to scripts/lib/ci-queue-ledger-path.sh. `env` injectable.
export function ledgerPath(env: Record<string, string | undefined> = process.env): string {
  const override = env.HIMMEL_CI_QUEUE_LEDGER;
  if (override && override.trim()) return override;
  // Fall back to the OS home dir when HOME is unset OR set-but-empty — `??` alone
  // would let HOME="" through and resolve to a filesystem-root path
  // ("/.himmel/ci-queue.jsonl"). The bash twin cannot portably resolve the OS
  // home, so it fails closed on empty HOME instead (real hook callers always set
  // HOME; the byte-identical contract holds for any HOME-set env).
  const home = env.HOME && env.HOME.trim() ? env.HOME : homedir();
  return join(home, ".himmel", "ci-queue.jsonl");
}

// Append one canonical single-line JSON event (atomic single-line O_APPEND).
// Creates the parent dir on append. `path` override is for tests.
export function appendEvent(e: CiEvent, env: Record<string, string | undefined> = process.env, path?: string): void {
  const p = path ?? ledgerPath(env);
  const dir = dirname(p);
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
  appendFileSync(p, JSON.stringify(e) + "\n", "utf8");
}

// Pure reduction: event log → current state per job. A lease-expire reverts a
// still-CLAIMED job to queued (re-claimable); it is ignored once the job has
// progressed past claim (running/verdict-known/done) so a late expiry cannot
// resurrect finished work.
export function reduce(events: CiEvent[]): Map<string, JobState> {
  const state = new Map<string, JobState>();
  for (const e of events) {
    if (e.t === "submit") {
      state.set(e.job.id, { attrs: e.job, status: "queued", statusPosted: false });
      continue;
    }
    const js = state.get(e.jobId);
    if (!js) continue; // event for an unknown/not-yet-submitted job — skip
    switch (e.t) {
      case "claim":
        js.status = "claimed";
        js.lease = e.lease;
        js.claimant = e.daemon;
        break;
      case "lease-renew":
        if (js.status === "claimed") js.lease = e.lease;
        break;
      case "lease-expire":
        if (js.status === "claimed") {
          js.status = "queued";
          js.lease = undefined;
          js.claimant = undefined;
        }
        break;
      case "dispatch":
        js.status = "running";
        js.lane = e.lane;
        js.runId = e.runId;
        break;
      case "verdict":
        js.status = "verdict-known";
        js.conclusion = e.conclusion;
        break;
      case "status-posted":
        js.statusPosted = true;
        break;
      case "complete":
        js.status = "done";
        break;
    }
  }
  return state;
}

// Read + reduce the ledger. Missing file → empty state. Blank lines skipped.
export function readState(env: Record<string, string | undefined> = process.env, path?: string): Map<string, JobState> {
  const p = path ?? ledgerPath(env);
  if (!existsSync(p)) return new Map();
  const raw = readFileSync(p, "utf8");
  const events: CiEvent[] = [];
  for (const line of raw.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    events.push(JSON.parse(trimmed) as CiEvent);
  }
  return reduce(events);
}
