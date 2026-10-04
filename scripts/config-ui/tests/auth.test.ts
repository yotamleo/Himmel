import { test, expect, afterEach } from "bun:test";
import { join } from "node:path";
import { startServer } from "../server";

const STUB = join(import.meta.dir, "stub-himmelctl.js");
const TOKEN = "t".repeat(64);
let stop: (() => void) | null = null;
afterEach(() => { stop?.(); stop = null; });

// seams: CONFIG_UI_HIMMELCTL (stub feed script), CONFIG_UI_IDLE_MS (long, never fires here).
// PATH is passed through: the server shells `node`, which a PATH-less env finds only where it
// lives in the default search path (not on a runner that installs node via setup-node).
const baseEnv = (): Record<string, string | undefined> => ({ PATH: process.env.PATH, CONFIG_UI_HIMMELCTL: STUB, CONFIG_UI_IDLE_MS: "60000" });
function boot(env: Record<string, string | undefined> = baseEnv()) {
  const s = startServer({ port: 0, token: TOKEN, env });
  stop = () => s.stop();
  return s;
}
const feed = (port: number, headers: Record<string, string> = {}) => fetch(`http://127.0.0.1:${port}/api/feed`, { headers });

test("GET /api/feed without the token is 401", async () => {
  const { port } = boot();
  expect((await feed(port)).status).toBe(401);
});

test("GET /api/feed with a wrong token is 401", async () => {
  const { port } = boot();
  expect((await feed(port, { "X-Himmel-Token": "x".repeat(64) })).status).toBe(401);
});

test("GET /api/feed with the token is 200 and carries the stub rows", async () => {
  const { port } = boot();
  const r = await feed(port, { "X-Himmel-Token": TOKEN });
  expect(r.status).toBe(200);
  expect((await r.json()).rows[0].id).toBe("stub-row-one");
});

test("a foreign Host header is refused", async () => {
  const { port } = boot();
  expect((await feed(port, { "X-Himmel-Token": TOKEN, Host: "evil.test" })).status).toBe(403);
});

test("GET / needs no token and its body holds no row id", async () => {
  const { port } = boot();
  const r = await fetch(`http://127.0.0.1:${port}/`);
  expect(r.status).toBe(200);
  expect(await r.text()).not.toContain("stub-row-one");
});

test("the feed is redacted before it leaves the server", async () => {
  const canary = "ghp_" + "A1b2".repeat(8);
  const { port } = boot({ ...baseEnv(), STUB_LEAK: canary });
  const body = await (await feed(port, { "X-Himmel-Token": TOKEN })).text();
  expect(body).not.toContain(canary);
  expect(body).toContain("stub-row-one");
});

test("startServer refuses a non-loopback hostname", () => {
  expect(() => startServer({ hostname: "0.0.0.0", port: 0, token: TOKEN } as never)).toThrow();
});

test("provider keys are scrubbed from the server env", () => {
  const env = { ...baseEnv(), ANTHROPIC_API_KEY: "k" };
  boot(env);
  expect(env.ANTHROPIC_API_KEY).toBeUndefined();
});
