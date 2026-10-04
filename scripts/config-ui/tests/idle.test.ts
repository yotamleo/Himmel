import { test, expect } from "bun:test";
import { join } from "node:path";

const SERVER = join(import.meta.dir, "..", "server.ts");
const STUB = join(import.meta.dir, "stub-himmelctl.js");
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// seams: CONFIG_UI_IDLE_MS (shortened), CONFIG_UI_HIMMELCTL (stub feed)
async function launch() {
  const t0 = Date.now();
  const p = Bun.spawn(["bun", SERVER, "--port", "0"], {
    env: { ...process.env, CONFIG_UI_IDLE_MS: "300", CONFIG_UI_HIMMELCTL: STUB }, stdout: "pipe", stderr: "ignore",
  });
  const reader = p.stdout.getReader();
  const line = new TextDecoder().decode((await reader.read()).value);
  const url = line.trim();
  expect(url).toMatch(/^http:\/\/127\.0\.0\.1:\d+\/#t=[0-9a-f]{64}$/);
  return { p, url, t0, started: Date.now() };
}

test("no requests: the process exits within 1 s of the idle window", async () => {
  const { p, started } = await launch();
  try {
    const code = await Promise.race([p.exited, sleep(1500).then(() => "alive")]);
    expect(code).toBe(0);
    expect(Date.now() - started).toBeLessThan(1000);
  } finally { p.kill(); }
});

test("a request with a foreign Host does not reset the idle timer", async () => {
  const { p, url, started } = await launch();
  try {
    const base = url.split("/#")[0];
    await sleep(Math.max(0, 200 - (Date.now() - started)));
    expect((await fetch(`${base}/`, { headers: { host: "evil.example" } })).status).toBe(403);
    const code = await Promise.race([p.exited, sleep(Math.max(1, 440 - (Date.now() - started))).then(() => "alive")]);
    expect(code).toBe(0); // exits ~300 ms; a reset by the rejected request would push it to ~500
  } finally { p.kill(); }
});

test("a request resets the idle timer (not a fixed lifetime)", async () => {
  const { p, url, started } = await launch();
  try {
    const base = url.split("/#")[0];
    await sleep(Math.max(0, 200 - (Date.now() - started)));
    expect((await fetch(`${base}/`)).status).toBe(200);
    await sleep(Math.max(0, 400 - (Date.now() - started)));
    expect(p.exitCode).toBeNull(); // still up at 400 ms
    const code = await Promise.race([p.exited, sleep(Math.max(1, 700 - (Date.now() - started))).then(() => "alive")]);
    expect(code).toBe(0); // exits by 700 ms (request at 200 + 300 idle)
  } finally { p.kill(); }
});
