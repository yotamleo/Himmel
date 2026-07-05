// scripts/ci-orchestrator/src/server.ts
// HIMMEL-502 P3.3 — the VM-owned queue HTTP API (resolves OQ1 transport).
//
// The VM daemon is the SINGLE writer (OQ1 B2/B3). Its one Node event loop
// SERIALIZES /submit and /claim, so claim exclusivity is a property of
// server-side sequential handling — not a distributed CAS over a shared file. The
// /claim handler parses the body (async), then runs its read→pick→grantClaim
// section FULLY SYNCHRONOUSLY (no await in between): Node runs each callback to
// completion, so two concurrent /claim requests can never both see the same job
// free. That guarantee is proven by the P3.3 Promise.all race test.
//
// Auth = a shared bearer token (HIMMEL_CI_QUEUE_TOKEN, env only, never committed).
// Bind localhost/LAN; the local daemon reaches it at the vmsdk-resolved address.
import { createServer, type IncomingMessage, type ServerResponse, type Server } from "node:http";
import { appendEvent, readState, type JobAttrs, type JobState } from "./ledger.js";
import { grantClaim } from "./lease.js";

export type ServerOptions = {
  token: string; // required bearer token
  env?: Record<string, string | undefined>;
  ledgerPath?: string;
  leaseTtlMs?: number; // default 15 min
  now?: () => number;
};

// The published /state response. `localWorkProfile` is the last profile the local
// claiming client published on a /claim (P3.4) — surfaced so /state (and the
// future C&C board) can display the machine the VM cannot itself observe.
export type StateResponse = {
  jobs: Record<string, JobState>;
  localWorkProfile?: string;
};

// Pick the next claimable jobId (highest-priority queued or time-expired-claimed
// job). Kept minimal: earliest-enqueued first (a fuller score lives in the
// scheduler; the server just needs a deterministic pick). Returns null if none.
function nextClaimable(state: Map<string, JobState>, now: number): string | null {
  let best: JobState | null = null;
  for (const js of state.values()) {
    const free =
      js.status === "queued" || (js.status === "claimed" && (!js.lease || Date.parse(js.lease) <= now));
    if (!free) continue;
    if (!best || Date.parse(js.attrs.enqueuedAt) < Date.parse(best.attrs.enqueuedAt)) best = js;
  }
  return best ? best.attrs.id : null;
}

async function readBody(req: IncomingMessage): Promise<unknown> {
  const chunks: Buffer[] = [];
  for await (const c of req) chunks.push(c as Buffer);
  const raw = Buffer.concat(chunks).toString("utf8");
  return raw ? JSON.parse(raw) : {};
}

function send(res: ServerResponse, code: number, body: unknown): void {
  const payload = JSON.stringify(body);
  res.writeHead(code, { "content-type": "application/json" });
  res.end(payload);
}

export function createQueueServer(opts: ServerOptions): Server {
  const env = opts.env ?? {};
  const path = opts.ledgerPath;
  const ttl = opts.leaseTtlMs ?? 15 * 60_000;
  const clock = opts.now ?? Date.now;
  let localWorkProfile: string | undefined;

  return createServer((req, res) => {
    // Auth first — 401 on a missing/wrong bearer token (never leak the token).
    const auth = req.headers["authorization"];
    if (auth !== `Bearer ${opts.token}`) {
      send(res, 401, { error: "unauthorized" });
      return;
    }
    const url = req.url ?? "";
    const method = req.method ?? "GET";

    if (method === "GET" && url === "/state") {
      const state = readState(env, path);
      const jobs: Record<string, JobState> = {};
      for (const [id, js] of state) jobs[id] = js;
      send(res, 200, { jobs, localWorkProfile } satisfies StateResponse);
      return;
    }

    if (method === "POST" && url === "/submit") {
      readBody(req)
        .then((body) => {
          const job = (body as { job?: JobAttrs }).job;
          if (!job || !job.id) {
            send(res, 400, { error: "missing job" });
            return;
          }
          appendEvent({ t: "submit", ts: new Date(clock()).toISOString(), job }, env, path);
          send(res, 200, { ok: true });
        })
        .catch(() => send(res, 400, { error: "bad request" }));
      return;
    }

    if (method === "POST" && url === "/claim") {
      readBody(req)
        .then((body) => {
          const { daemon, workProfile } = body as { daemon?: string; workProfile?: string };
          if (workProfile) localWorkProfile = workProfile; // publish local profile (P3.4)
          // --- SYNCHRONOUS critical section (no await): serialized by the loop ---
          const now = clock();
          const state = readState(env, path);
          const jobId = nextClaimable(state, now);
          if (!jobId) {
            send(res, 200, { job: null });
            return;
          }
          const grant = grantClaim(jobId, daemon ?? "local", ttl, now, env, path);
          if (!grant.ok) {
            send(res, 200, { job: null });
            return;
          }
          send(res, 200, { job: state.get(jobId)!.attrs, lease: grant.lease });
          // --- end synchronous critical section ---
        })
        .catch(() => send(res, 400, { error: "bad request" }));
      return;
    }

    if (method === "POST" && url === "/complete") {
      readBody(req)
        .then((body) => {
          const { jobId, conclusion } = body as {
            jobId?: string;
            conclusion?: "success" | "failure" | "cancelled";
          };
          if (!jobId || !conclusion) {
            send(res, 400, { error: "missing jobId/conclusion" });
            return;
          }
          const ts = new Date(clock()).toISOString();
          appendEvent({ t: "verdict", ts, jobId, conclusion }, env, path);
          appendEvent({ t: "complete", ts, jobId }, env, path);
          send(res, 200, { ok: true });
        })
        .catch(() => send(res, 400, { error: "bad request" }));
      return;
    }

    send(res, 404, { error: "not found" });
  });
}
