import { test, expect } from "bun:test";
import { join } from "node:path";

const SERVER = join(import.meta.dir, "..", "server.ts");
const STUB = join(import.meta.dir, "stub-himmelctl.js");
const IDLE = 1000; // HIMMEL-4350: wide enough that a loaded runner's jitter stays well inside each bound
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// seams: CONFIG_UI_IDLE_MS (shortened), CONFIG_UI_HIMMELCTL (stub feed)
async function launch() {
  const p = Bun.spawn(["bun", SERVER, "--port", "0"], {
    env: { ...process.env, CONFIG_UI_IDLE_MS: String(IDLE), CONFIG_UI_HIMMELCTL: STUB }, stdout: "pipe", stderr: "ignore",
  });
  const reader = p.stdout.getReader();
  const line = new TextDecoder().decode((await reader.read()).value);
  const url = line.trim();
  // HIMMEL-4711: the one URL lands on the fleet (/agui/) when its page is built, else on the console.
  expect(url).toMatch(/^http:\/\/127\.0\.0\.1:\d+\/(?:agui\/)?#t=[0-9a-f]{64}$/);
  const [base, frag] = url.split(/\/(?:agui\/)?#t=/);
  return { p, base, token: frag, started: Date.now() };
}
const exitedBy = (p: ReturnType<typeof Bun.spawn>, started: number, at: number) =>
  Promise.race([p.exited, sleep(Math.max(1, at - (Date.now() - started))).then(() => "alive")]);

test("no requests: the process exits soon after the idle window", async () => {
  const { p, started } = await launch();
  try {
    expect(await exitedBy(p, started, IDLE * 2)).toBe(0);
  } finally { p.kill(); }
});

// Requests that must NOT keep the server alive: a foreign Host, and (HIMMEL-4350)
// anything without the token, static pages included.
for (const [name, path, headers] of [
  ["a foreign Host", "/", { host: "evil.example" }],
  ["a static page without the token", "/", {}],
  ["an /api request with a wrong token", "/api/feed", { "X-Himmel-Token": "x".repeat(64) }],
] as const) {
  test(`${name} does not reset the idle timer`, async () => {
    const { p, base, started } = await launch();
    try {
      await sleep(Math.max(0, IDLE * 0.6 - (Date.now() - started)));
      await fetch(`${base}${path}`, { headers });
      // exits ~IDLE after launch; a reset would push it to ~1.6 x IDLE
      expect(await exitedBy(p, started, IDLE * 1.45)).toBe(0);
    } finally { p.kill(); }
  });
}

test("an authenticated request resets the idle timer (not a fixed lifetime)", async () => {
  const { p, base, token, started } = await launch();
  try {
    await sleep(Math.max(0, IDLE * 0.6 - (Date.now() - started)));
    expect((await fetch(`${base}/api/feed`, { headers: { "X-Himmel-Token": token } })).status).toBe(200);
    await sleep(Math.max(0, IDLE * 1.3 - (Date.now() - started)));
    expect(p.exitCode).toBeNull(); // still up past the first window
    expect(await exitedBy(p, started, IDLE * 2.6)).toBe(0); // exits by ~1.6 x IDLE plus slack
  } finally { p.kill(); }
});
