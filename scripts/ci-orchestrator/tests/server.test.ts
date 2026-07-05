import { describe, test, expect, beforeEach, afterEach } from "vitest";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { mkdtempSync } from "node:fs";
import { request, type Server } from "node:http";
import { createQueueServer } from "../src/server.js";
import { type JobAttrs } from "../src/ledger.js";

const TOKEN = "test-token-abc";
const T0 = "2026-07-05T00:00:00Z";

function job(over: Partial<JobAttrs> = {}): JobAttrs {
  return {
    id: "j1", headSha: "HEAD", runSha: "HEAD", workflow: "ci", job: "lint", required: true,
    needsSecrets: false, publicSafe: false, os: "linux", heavy: false, deterministic: false,
    treeHash: "t", enqueuedAt: T0, ...over,
  };
}

let server: Server;
let port: number;
let ledger: string;

function call(
  method: string,
  path: string,
  body: unknown,
  token: string | null,
): Promise<{ status: number; json: any }> {
  return new Promise((resolve, reject) => {
    const payload = body === undefined ? "" : JSON.stringify(body);
    const headers: Record<string, string> = { "content-type": "application/json" };
    if (token) headers["authorization"] = `Bearer ${token}`;
    const req = request({ host: "127.0.0.1", port, method, path, headers }, (res) => {
      const chunks: Buffer[] = [];
      res.on("data", (c) => chunks.push(c as Buffer));
      res.on("end", () => {
        const raw = Buffer.concat(chunks).toString("utf8");
        resolve({ status: res.statusCode ?? 0, json: raw ? JSON.parse(raw) : null });
      });
    });
    req.on("error", reject);
    if (payload) req.write(payload);
    req.end();
  });
}

beforeEach(async () => {
  ledger = join(mkdtempSync(join(tmpdir(), "ci-server-")), "q.jsonl");
  server = createQueueServer({ token: TOKEN, env: {}, ledgerPath: ledger });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const addr = server.address();
  port = typeof addr === "object" && addr ? addr.port : 0;
});

afterEach(async () => {
  await new Promise<void>((r) => server.close(() => r()));
});

describe("VM queue HTTP API", () => {
  test("/claim without the bearer token → 401", async () => {
    const res = await call("POST", "/claim", { daemon: "local" }, null);
    expect(res.status).toBe(401);
  });

  test("/submit then /state round-trips the reduced state", async () => {
    const sub = await call("POST", "/submit", { job: job() }, TOKEN);
    expect(sub.status).toBe(200);
    const state = await call("GET", "/state", undefined, TOKEN);
    expect(state.status).toBe(200);
    expect(state.json.jobs.j1.status).toBe("queued");
  });

  test("THE real race: two concurrent /claim for one job → exactly one wins", async () => {
    await call("POST", "/submit", { job: job() }, TOKEN);
    const [a, b] = await Promise.all([
      call("POST", "/claim", { daemon: "d1" }, TOKEN),
      call("POST", "/claim", { daemon: "d2" }, TOKEN),
    ]);
    expect(a.status).toBe(200);
    expect(b.status).toBe(200);
    const gotJob = [a, b].filter((r) => r.json.job !== null);
    const gotNull = [a, b].filter((r) => r.json.job === null);
    expect(gotJob).toHaveLength(1); // exactly one carries the job
    expect(gotNull).toHaveLength(1); // the other carries none
    expect(gotJob[0].json.job.id).toBe("j1");
  });

  test("/claim publishes the local workProfile into /state", async () => {
    await call("POST", "/submit", { job: job() }, TOKEN);
    await call("POST", "/claim", { daemon: "local", workProfile: "drain" }, TOKEN);
    const state = await call("GET", "/state", undefined, TOKEN);
    expect(state.json.localWorkProfile).toBe("drain");
  });
});
