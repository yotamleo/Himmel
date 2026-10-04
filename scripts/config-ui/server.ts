// HIMMEL-4254 P3: `himmelctl ui` — read-only config UI server.
// Loopback only (hostname hard-coded), per-launch token on /api/*, Host check,
// feed shelled from `himmelctl report --json` (execFile, no shell) and redacted.
import { execFile } from "node:child_process";
import { readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { scrubProviderKeys } from "../fleet-control/server";
// redact.js is the shared CommonJS redactor (P2); imported, not copied.
import { redactDeep } from "../himmelctl/lib/redact.js";

const LOOPBACK = "127.0.0.1";
const DEFAULT_IDLE_MS = 30 * 60 * 1000;
const FEED_TIMEOUT_MS = 120_000;
const STATIC: Record<string, [string, string]> = {
  "/": ["index.html", "text/html; charset=utf-8"],
  "/app.js": ["app.js", "application/javascript; charset=utf-8"],
  "/render.js": ["render.js", "application/javascript; charset=utf-8"],
  "/app.css": ["app.css", "text/css; charset=utf-8"],
};

type Env = Record<string, string | undefined>;
export type ServerOpts = { port?: number; token?: string; hostname?: string; env?: Env; onIdle?: () => void };

export function newToken(): string {
  return Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("hex");
}

function sameToken(a: string | null, b: string): boolean {
  if (a === null || a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

function himmelctlBin(env: Env): string {
  return env.CONFIG_UI_HIMMELCTL ?? resolve(import.meta.dir, "../himmelctl/bin.js");
}

function runFeed(env: Env): Promise<string> {
  return new Promise((ok, fail) => {
    execFile("node", [himmelctlBin(env), "report", "--json"], { env: env as NodeJS.ProcessEnv, timeout: FEED_TIMEOUT_MS, maxBuffer: 64 * 1024 * 1024 }, (err, stdout) => {
      if (err) return fail(err);
      try { ok(JSON.stringify(redactDeep(JSON.parse(stdout)))); } catch (e) { fail(e); }
    });
  });
}

export function startServer(opts: ServerOpts = {}): { server: import("bun").Server; port: number; token: string; stop: () => void } {
  if (opts.hostname !== undefined && opts.hostname !== LOOPBACK) throw new Error(`config-ui binds ${LOOPBACK} only (got ${opts.hostname})`);
  const env = opts.env ?? process.env;
  scrubProviderKeys(env);
  const token = opts.token ?? newToken();
  const idleMs = Number(env.CONFIG_UI_IDLE_MS) > 0 ? Number(env.CONFIG_UI_IDLE_MS) : DEFAULT_IDLE_MS;
  const publicRoot = join(import.meta.dir, "public");
  let idle: ReturnType<typeof setTimeout> | undefined;
  const bump = () => {
    clearTimeout(idle);
    idle = setTimeout(() => (opts.onIdle ?? (() => process.exit(0)))(), idleMs);
  };
  const server = Bun.serve({
    hostname: LOOPBACK, // hard-coded: never configurable
    port: opts.port ?? 0,
    async fetch(req) {
      bump();
      if (req.headers.get("host") !== `${LOOPBACK}:${server.port}`) return new Response("bad host", { status: 403 });
      const path = new URL(req.url).pathname;
      if (path.startsWith("/api/")) {
        if (!sameToken(req.headers.get("x-himmel-token"), token)) return new Response("unauthorized", { status: 401 });
        if (req.method !== "GET") return new Response("method not allowed", { status: 405 });
        if (path === "/api/feed") {
          try { return new Response(await runFeed(env), { headers: { "content-type": "application/json", "cache-control": "no-store" } }); }
          catch { return new Response(JSON.stringify({ error: "feed failed" }), { status: 502, headers: { "content-type": "application/json" } }); }
        }
        return new Response("not found", { status: 404 });
      }
      const file = STATIC[path];
      if (req.method === "GET" && file) return new Response(readFileSync(join(publicRoot, file[0])), { headers: { "content-type": file[1], "cache-control": "no-store" } });
      return new Response("not found", { status: 404 });
    },
  });
  bump();
  return { server, port: server.port, token, stop: () => { clearTimeout(idle); server.stop(true); } };
}

if (import.meta.main) {
  const i = process.argv.indexOf("--port");
  const { port, token } = startServer({ port: i > 0 ? Number(process.argv[i + 1]) : 0 });
  console.log(`http://${LOOPBACK}:${port}/#t=${token}`);
  process.on("SIGINT", () => process.exit(0));
  process.on("SIGTERM", () => process.exit(0));
}
