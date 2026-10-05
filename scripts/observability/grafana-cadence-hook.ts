// HIMMEL-4289: Grafana webhook contact point -> scripts/luna/cadence-alert.sh.
//
// WHY: the Linux Grafana tier must alert through the ONE existing sink
// (cadence-alert.sh: console-readable log + a deduped Telegram DM), not a second
// Telegram path of its own. Grafana can only POST a webhook, so this small
// receiver turns each alert of a webhook payload into one cadence-alert call:
//   firing   -> cadence-alert.sh fail grafana-<alertname> <alertname> <summary url>
//   resolved -> cadence-alert.sh clear grafana-<alertname>
// The leg is per alertname so a resolve re-arms only that alert's dedupe.
//
// It is a listening service, so: loopback only (the host is a constant, never
// configurable), POST /alert needs a bearer token read from a 0600 file (never
// logged), the body is size-capped and must be JSON, payload text only ever
// reaches cadence-alert as sanitized, length-capped argv (never a shell), and
// repeats are deduped and rate-limited.
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { timingSafeEqual } from "node:crypto";
import { join } from "node:path";

export const LISTEN_HOST = "127.0.0.1";
export const MAX_BODY_BYTES = 64 * 1024;
const DEDUPE_MS = 60_000;
const MAX_CALLS_PER_MINUTE = 60;

type GrafanaAlert = {
  status?: string;
  labels?: Record<string, string>;
  annotations?: Record<string, string>;
  generatorURL?: string;
};
type Runner = (args: string[]) => void;

// argv-only, but the leg name still lands in a log filename/sentinel: keep it to a safe charset.
const safeName = (s: unknown): string => String(s ?? "").replace(/[^A-Za-z0-9_.-]/g, "_").slice(0, 64) || "unknown";
const safeText = (s: unknown): string =>
  // eslint-disable-next-line no-control-regex
  String(s ?? "").replace(/[\u0000-\u001f\u007f]/g, " ").slice(0, 300);

export function alertCalls(body: { alerts?: GrafanaAlert[] }): string[][] {
  const calls: string[][] = [];
  for (const a of Array.isArray(body.alerts) ? body.alerts : []) {
    const name = safeName(a?.labels?.alertname);
    const leg = `grafana-${name}`;
    if (a?.status === "resolved") {
      calls.push(["clear", leg]);
    } else {
      const log = [a?.annotations?.summary, a?.generatorURL].filter(Boolean).map(safeText).join(" ").slice(0, 300);
      calls.push(["fail", leg, name, log]);
    }
  }
  return calls;
}

const tokenOk = (given: string, token: string): boolean => {
  const a = Buffer.from(given);
  const b = Buffer.from(token);
  return a.length === b.length && timingSafeEqual(a, b);
};

export function createHandler(opts: { token: string; run: Runner; now?: () => number }) {
  const now = opts.now ?? Date.now;
  const seen = new Map<string, number>();
  let windowStart = now();
  let windowCalls = 0;
  return async (req: Request): Promise<Response> => {
    const url = new URL(req.url);
    if (url.pathname === "/healthz") return new Response("ok");
    if (url.pathname !== "/alert" || req.method !== "POST") return new Response("not found", { status: 404 });
    const auth = req.headers.get("authorization") ?? "";
    if (!opts.token || !auth.startsWith("Bearer ") || !tokenOk(auth.slice(7), opts.token)) {
      return new Response("unauthorized", { status: 401 });
    }
    if (!(req.headers.get("content-type") ?? "").toLowerCase().startsWith("application/json")) {
      return new Response("json only", { status: 415 });
    }
    const declared = Number(req.headers.get("content-length") ?? 0);
    if (declared > MAX_BODY_BYTES) return new Response("too large", { status: 413 });
    const raw = await req.text();
    if (Buffer.byteLength(raw) > MAX_BODY_BYTES) return new Response("too large", { status: 413 });
    let body: { alerts?: GrafanaAlert[] };
    try {
      body = JSON.parse(raw);
    } catch {
      return new Response("bad json", { status: 400 });
    }
    if (body === null || typeof body !== "object" || Array.isArray(body)) return new Response("bad json", { status: 400 });

    const t = now();
    if (t - windowStart > 60_000) { windowStart = t; windowCalls = 0; }
    for (const [k, v] of seen) if (t - v >= DEDUPE_MS) seen.delete(k);
    try {
      for (const call of alertCalls(body)) {
        const key = call.join("\u0000");
        const prev = seen.get(key);
        if (prev !== undefined && t - prev < DEDUPE_MS) continue;
        if (++windowCalls > MAX_CALLS_PER_MINUTE) return new Response("rate limited", { status: 429 });
        opts.run(call); // a throw skips the dedupe record, so Grafana's retry runs it again
        // an opposite-state call for the same leg ends the old dedupe run
        const other = `${call[0] === "clear" ? "fail" : "clear"}\u0000${call[1]}`;
        for (const k of [...seen.keys()]) if (k === other || k.startsWith(`${other}\u0000`)) seen.delete(k);
        seen.set(key, t);
      }
    } catch {
      return new Response("sink failed", { status: 500 }); // Grafana retries a non-2xx
    }
    return new Response("", { status: 200 });
  };
}

export function startServer(opts: { port: number; token: string; run: Runner }) {
  return Bun.serve({
    hostname: LISTEN_HOST,
    port: opts.port,
    maxRequestBodySize: MAX_BODY_BYTES,
    fetch: createHandler({ token: opts.token, run: opts.run }),
  });
}

if (import.meta.main) {
  const sink = join(import.meta.dir, "..", "luna", "cadence-alert.sh");
  const run: Runner = (args) => {
    const r = spawnSync("bash", [sink, ...args], { stdio: "ignore", timeout: 30_000 });
    if (r.error) throw r.error;
    if (r.status !== 0) throw new Error(`cadence-alert exited ${r.status ?? r.signal}`);
  };
  const tokenFile = process.env.HIMMEL_GRAFANA_HOOK_TOKEN_FILE;
  if (!tokenFile) { console.error("HIMMEL_GRAFANA_HOOK_TOKEN_FILE is required"); process.exit(2); }
  const token = readFileSync(tokenFile, "utf8").trim();
  if (token.length < 16) { console.error("hook token too short"); process.exit(2); }
  startServer({ port: Number(process.env.HIMMEL_GRAFANA_HOOK_PORT || 9878), token, run });
}
