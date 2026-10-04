// HIMMEL-4254 P3/P4: `himmelctl ui` — config UI server.
// Loopback only (hostname hard-coded), per-launch token on /api/*, Host check,
// feed shelled from `himmelctl report --json` (execFile, no shell) and redacted.
// P4 adds the two-step writes (spec A12-A14b): POST /api/preview runs an
// action's dry-run and binds a single-use preview id; POST /api/run runs only
// that bound argv under the machine-wide write lock, re-probes the row and
// appends one audit line.
import { execFile } from "node:child_process";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { scrubProviderKeys } from "../fleet-control/server";
// redact.js is the shared CommonJS redactor (P2); imported, not copied.
import { redactDeep, envValues } from "../himmelctl/lib/redact.js";
import { parseDotEnv } from "../himmelctl/lib/probes.js";
import { ActionError, buildTable, loadRegistries, resolveAction, type Resolved } from "./actions";
import { acquireLock, runChild } from "./lock";
import { appendAudit } from "./audit";

const LOOPBACK = "127.0.0.1";
const DEFAULT_IDLE_MS = 30 * 60 * 1000;
const FEED_TIMEOUT_MS = 120_000;
const PREVIEW_TTL_MS = 5 * 60 * 1000;
export const REPROBE_BUDGET_MS = 60_000;
const MAX_BODY = 16 * 1024;
const CHECKOUT = resolve(import.meta.dir, "../..");
const SECURITY_HEADERS: Record<string, string> = { "content-security-policy": "default-src 'self'", "x-frame-options": "DENY" };
const STATIC: Record<string, [string, string]> = {
  "/": ["index.html", "text/html; charset=utf-8"],
  "/app.js": ["app.js", "application/javascript; charset=utf-8"],
  "/render.js": ["render.js", "application/javascript; charset=utf-8"],
  "/app.css": ["app.css", "text/css; charset=utf-8"],
};

type Env = Record<string, string | undefined>;
// root, now, actionTimeoutMs and reprobeBudgetMs are test seams on the function
// only; the CLI entry below never sets them.
export type ServerOpts = {
  port?: number; token?: string; hostname?: string; env?: Env; onIdle?: () => void;
  root?: string; now?: () => number; actionTimeoutMs?: number; reprobeBudgetMs?: number;
};
type Preview = Resolved & { expires: number };
type Probe = Record<string, { installed: string; health: string }>;

export function newToken(): string {
  return Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("hex");
}

function sameToken(a: string | null, b: string): boolean {
  if (a === null || a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

// Test seam CONFIG_UI_HIMMELCTL: the himmelctl entry the server shells.
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

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } });

export function startServer(opts: ServerOpts = {}): { server: import("bun").Server; port: number; token: string; stop: () => void } {
  if (opts.hostname !== undefined && opts.hostname !== LOOPBACK) throw new Error(`config-ui binds ${LOOPBACK} only (got ${opts.hostname})`);
  const env = opts.env ?? process.env;
  scrubProviderKeys(env);
  const token = opts.token ?? newToken();
  const idleMs = Number(env.CONFIG_UI_IDLE_MS) > 0 ? Number(env.CONFIG_UI_IDLE_MS) : DEFAULT_IDLE_MS;
  const now = opts.now ?? Date.now;
  const root = opts.root ?? CHECKOUT;
  const himmelctl = himmelctlBin(env);
  const stateDir = join(env.HOME || homedir(), ".himmel", "state", "config-ui");
  const lockPath = join(stateDir, "write.lock");
  const auditPath = join(stateDir, "actions.jsonl");
  const reprobeMs = opts.reprobeBudgetMs ?? REPROBE_BUDGET_MS;
  // Test seam HIMMEL_REPORT_CADENCE_ROOT (shared with `report`): a tree of stub
  // cadence scripts. In use the cadences run from the checkout.
  const table = buildTable({ root, cadenceRoot: env.HIMMEL_REPORT_CADENCE_ROOT ?? root, himmelctl, platform: process.platform, ...loadRegistries(root) });
  const previews = new Map<string, Preview>();
  const publicRoot = join(import.meta.dir, "public");

  // Every child output passes the same redactor as the feed, with the
  // checkout's .env values and the server env's secret values as literals.
  const redactOut = <T>(v: T): T => {
    let raw = "";
    try { raw = readFileSync(join(root, ".env"), "utf8"); } catch { /* no .env */ }
    return redactDeep(v, { literals: envValues(raw, parseDotEnv, env) });
  };
  const childOpts = (p: Resolved) => ({ cwd: p.cwd, env, timeoutMs: opts.actionTimeoutMs ?? p.timeoutMs });

  async function reprobe(rowIds: string[]): Promise<{ probe: Probe | null; state: string }> {
    if (rowIds.length === 0) return { probe: {}, state: "ok" };
    const r = await runChild(["node", himmelctl, "report", "--json", "--items", rowIds.join(",")], { cwd: root, env, timeoutMs: reprobeMs });
    if (r.timedOut) return { probe: null, state: "re-probe timed out" };
    if (r.rc !== 0) return { probe: null, state: "re-probe failed" };
    try {
      const probe: Probe = {};
      for (const row of JSON.parse(r.stdout).rows || []) if (rowIds.includes(row.id)) probe[row.id] = { installed: String(row.installed?.state ?? ""), health: String(row.health ?? "") };
      return { probe, state: "ok" };
    } catch { return { probe: null, state: "re-probe failed" }; }
  }
  const healthOf = (p: Probe | null) => p && Object.fromEntries(Object.entries(p).map(([k, v]) => [k, v.health]));

  async function previewRoute(b: Record<string, unknown>): Promise<Response> {
    let p: Resolved;
    try { p = resolveAction(table, b.action, b.target, b.value); }
    catch (e) { if (e instanceof ActionError) return json({ error: e.message }, 400); throw e; }
    const release = acquireLock(lockPath);
    if (!release) return json({ error: "another action is running" }, 409);
    let r;
    try { r = await runChild(p.dryArgv, childOpts(p)); } finally { release(); }
    const output = r.stdout + r.stderr;
    if (r.rc !== 0) return json(redactOut({ error: r.timedOut ? "dry-run timed out" : "dry-run failed", rc: r.rc, output }), 422);
    for (const [k, v] of previews) if (v.expires <= now()) previews.delete(k);
    const previewId = Buffer.from(crypto.getRandomValues(new Uint8Array(16))).toString("hex");
    previews.set(previewId, { ...p, expires: now() + PREVIEW_TTL_MS });
    return json({ previewId, ...redactOut({ command: p.dryArgv.join(" "), output, consent: p.consent, effect: p.effect, bank: p.bank }), expiresInMs: PREVIEW_TTL_MS });
  }

  async function runRoute(b: Record<string, unknown>): Promise<Response> {
    const id = typeof b.previewId === "string" ? b.previewId : "";
    const p = previews.get(id);
    if (!p || p.expires <= now()) { previews.delete(id); return json({ error: "preview id missing, expired or used" }, 409); }
    if (b.action !== p.action || b.target !== p.target || (b.value ?? null) !== p.value) return json({ error: "preview id is bound to a different action" }, 409);
    if (p.consent.kind === "typed" && b.consent !== p.consent.expect) return json({ error: "typed consent does not match" }, 403);
    const release = acquireLock(lockPath);
    if (!release) return json({ error: "another action is running" }, 409);
    previews.delete(id); // single-use from here on
    let before, r, after;
    try {
      before = await reprobe(p.rowIds);
      r = await runChild(p.argv, childOpts(p));
      after = await reprobe(p.rowIds);
    } finally { release(); }
    appendAudit(auditPath, { time: new Date(now()).toISOString(), action: p.action, target: p.target, value: p.value, argv: p.argv, rc: r.rc, before: healthOf(before.probe), after: healthOf(after.probe) });
    const reprobeState = before.state !== "ok" ? before.state : after.state;
    return json(redactOut({ rc: r.rc, timedOut: r.timedOut, command: p.argv.join(" "), output: r.stdout + r.stderr, before: before.probe, after: after.probe, reprobe: reprobeState }));
  }

  let idle: ReturnType<typeof setTimeout> | undefined;
  const bump = () => {
    clearTimeout(idle);
    idle = setTimeout(() => (opts.onIdle ?? (() => process.exit(0)))(), idleMs);
  };
  async function route(req: Request): Promise<Response> {
    const origin = `http://${LOOPBACK}:${server.port}`;
    if (req.headers.get("host") !== `${LOOPBACK}:${server.port}`) return new Response("bad host", { status: 403 });
    const path = new URL(req.url).pathname;
    if (path.startsWith("/api/")) {
      if (!sameToken(req.headers.get("x-himmel-token"), token)) return new Response("unauthorized", { status: 401 });
      bump(); // HIMMEL-4350: only an authenticated request keeps the server alive
      if (req.method === "GET" && path === "/api/feed") {
        try { return new Response(await runFeed(env), { headers: { "content-type": "application/json", "cache-control": "no-store" } }); }
        catch { return json({ error: "feed failed" }, 502); }
      }
      if (path !== "/api/preview" && path !== "/api/run") return new Response("not found", { status: 404 });
      if (req.method !== "POST") return new Response("method not allowed", { status: 405 });
      if (req.headers.get("origin") !== origin) return new Response("bad origin", { status: 403 });
      if ((req.headers.get("content-type") || "").split(";")[0].trim().toLowerCase() !== "application/json") return new Response("json only", { status: 415 });
      const text = await req.text();
      if (text.length > MAX_BODY) return json({ error: "body too large" }, 413);
      let b: unknown;
      try { b = JSON.parse(text); } catch { return json({ error: "bad json" }, 400); }
      if (!b || typeof b !== "object" || Array.isArray(b)) return json({ error: "bad json" }, 400);
      return path === "/api/preview" ? previewRoute(b as Record<string, unknown>) : runRoute(b as Record<string, unknown>);
    }
    const file = STATIC[path];
    if (req.method === "GET" && file) return new Response(readFileSync(join(publicRoot, file[0])), { headers: { "content-type": file[1], "cache-control": "no-store" } });
    return new Response("not found", { status: 404 });
  }
  const server = Bun.serve({
    hostname: LOOPBACK, // hard-coded: never configurable
    port: opts.port ?? 0,
    async fetch(req) {
      let res: Response;
      try { res = await route(req); } catch { res = json({ error: "internal error" }, 500); }
      for (const [k, v] of Object.entries(SECURITY_HEADERS)) res.headers.set(k, v);
      return res;
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
