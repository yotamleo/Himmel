// HIMMEL-4807: the feed's probe progress, background loading and stale-while-revalidate, over the real server
// with the stub reports (stub-himmelctl.js for the feed, stub-recorder.js + stub-cadence.sh for an action).
import { test, expect, afterEach } from "bun:test";
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, unlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startServer, type ServerOpts } from "../server";

const TOKEN = "t".repeat(64);
const H = { "X-Himmel-Token": TOKEN };
const STUB = join(import.meta.dir, "stub-himmelctl.js");
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const dirs: string[] = [];
const stops: (() => void)[] = [];
afterEach(() => { while (stops.length) stops.pop()!(); while (dirs.length) rmSync(dirs.pop()!, { recursive: true, force: true }); });

function boot(env: Record<string, string>, x: Partial<ServerOpts> & Record<string, unknown> = {}) {
  const dir = mkdtempSync(join(tmpdir(), "cfgui-bg-"));
  dirs.push(dir);
  mkdirSync(join(dir, "home"), { recursive: true });
  const count = join(dir, "count");
  const s = startServer({ port: 0, token: TOKEN, env: { PATH: process.env.PATH, HOME: join(dir, "home"), CONFIG_UI_IDLE_MS: "60000", CONFIG_UI_HIMMELCTL: STUB, STUB_FEED_COUNT: count, ...env }, ...x } as never);
  stops.push(() => s.stop());
  const runs = () => { try { return readFileSync(count, "utf8").split("\n").filter(Boolean).length; } catch { return 0; } };
  return { port: s.port, runs };
}
const feed = (port: number) => fetch(`http://127.0.0.1:${port}/api/feed`, { headers: H });
async function timed(port: number) {
  const t0 = Date.now();
  const r = await feed(port);
  return { r, ms: Date.now() - t0, j: await r.json() };
}
async function untilFeed(port: number) {
  for (;;) { const x = await timed(port); if (x.r.status !== 202) return x; }
}

test("a 202 names the step being probed, n of N, and comes back as soon as the step changes", async () => {
  // feedWaitMs is longer than the whole report: only a step change can answer a request early.
  const { port } = boot({ STUB_FEED_SLEEP: "3000", STUB_FEED_STEPS: "3", STUB_FEED_JUNK: "1" }, { feedWaitMs: 6000 });
  const seen: { i: number; n: number; source: string }[] = [];
  for (;;) {
    const { r, j, ms } = await timed(port);
    if (r.status !== 202) { expect(r.status).toBe(200); break; }
    expect(ms).toBeLessThan(5000);
    expect(j.state).toBe("running");
    expect("progress" in j).toBe(true);
    if (j.progress) seen.push(j.progress);
  }
  expect(seen.length).toBeGreaterThanOrEqual(2);
  for (const p of seen) {
    expect(p.n).toBe(3);
    expect(p.source).toBe(`stub step ${p.i}`); // the malformed lines (past n, markup, a fraction, not JSON) never land
  }
  const is = seen.map((p) => p.i);
  expect(is).toEqual([...is].sort((a, b) => a - b)); // it only moves forward
  expect(new Set(is).size).toBeGreaterThanOrEqual(2); // and it advances
}, 20_000);

test("backgroundFeed: the report starts at boot, so the first request finds it done (no 202)", async () => {
  const { port, runs } = boot({ STUB_FEED_SLEEP: "1200" }, { feedWaitMs: 200, backgroundFeed: true });
  await sleep(2000); // nobody asked yet; the prewarm has finished
  const { r, ms, j } = await timed(port);
  expect(r.status).toBe(200);
  expect(ms).toBeLessThan(800);
  expect(j.stubRun).toBe(1);
  expect(runs()).toBe(1);
}, 15_000);

test("backgroundFeed: refreshes on the refresh tick while the console is in use, not once it is closed", async () => {
  const { port, runs } = boot({ STUB_FEED_SLEEP: "50" }, { backgroundFeed: true, feedRefreshMs: 700 });
  await sleep(300);
  expect(runs()).toBe(1); // the prewarm
  expect((await untilFeed(port)).j.stubRun).toBe(1); // the console asks: it is in use
  await sleep(1000); // one tick inside the in-use window: a refresh
  expect(runs()).toBe(2);
  await sleep(1600); // no request since: later ticks find it closed and leave it be
  const n = runs();
  expect(n).toBeLessThanOrEqual(3);
  await sleep(1500);
  expect(runs()).toBe(n);
}, 15_000);

test("without backgroundFeed, nothing runs until the console asks", async () => {
  const { runs } = boot({ STUB_FEED_SLEEP: "50" }, { feedRefreshMs: 300 });
  await sleep(900);
  expect(runs()).toBe(0);
});

test("stale-while-revalidate: an expired cache answers the last report at once while a new one runs", async () => {
  let t = 1_000_000;
  const { port, runs } = boot({ STUB_FEED_SLEEP: "1500" }, { now: () => t });
  expect((await untilFeed(port)).j.stubRun).toBe(1);
  t += 31_000; // past the 30 s cache
  const stale = await timed(port);
  expect(stale.r.status).toBe(200);
  expect(stale.j.stubRun).toBe(1);
  expect(stale.ms).toBeLessThan(1000);
  await sleep(300);
  expect(runs()).toBe(2); // the refresh started
  await sleep(1600);
  expect((await timed(port)).j.stubRun).toBe(2); // and the next request gets it
}, 20_000);

// The /api/run path, as slow.test.ts drives it: stub-recorder.js answers the reports, stub-cadence.sh is the action.
function bootRun(x: Record<string, unknown> = {}) {
  const dir = mkdtempSync(join(tmpdir(), "cfgui-bgrun-"));
  dirs.push(dir);
  const [home, cad, state] = ["home", "cad", "state"].map((d) => { mkdirSync(join(dir, d), { recursive: true }); return join(dir, d); });
  mkdirSync(join(cad, "scripts/luna"), { recursive: true });
  copyFileSync(join(import.meta.dir, "stub-cadence.sh"), join(cad, "scripts/luna/graphmap-cadence.sh"));
  const repo = join(dir, "repo");
  mkdirSync(repo);
  const argv = join(dir, "argv");
  writeFileSync(argv, "");
  const s = startServer({ port: 0, token: TOKEN, root: repo, env: { PATH: process.env.PATH, HOME: home, CONFIG_UI_IDLE_MS: "60000",
    CONFIG_UI_HIMMELCTL: join(import.meta.dir, "stub-recorder.js"), HIMMEL_REPORT_CADENCE_ROOT: cad, STUB_ARGV: argv, STUB_STATE: state }, ...x } as never);
  stops.push(() => s.stop());
  const post = (path: string, body: unknown) => fetch(`http://127.0.0.1:${s.port}${path}`, { method: "POST", body: JSON.stringify(body),
    headers: { ...H, Origin: `http://127.0.0.1:${s.port}`, "Content-Type": "application/json" } });
  const ARM = { action: "cadence.arm", target: "graphmap" };
  const act = async () => {
    const pv = await (await post("/api/preview", ARM)).json();
    const r = await post("/api/run", { previewId: pv.previewId, ...ARM, consent: "graphmap" });
    expect(r.status).toBe(200);
  };
  // The argv line number of the real (non-dry-run) action.
  const actedAt = () => readFileSync(argv, "utf8").split("\n").filter(Boolean).indexOf("graphmap-cadence.sh arm") + 1;
  return { port: s.port, act, actedAt, sleepFile: join(state, "feed-sleep") };
}

test("after an action, the feed never answers the pre-action report", async () => {
  const { port, act, actedAt } = bootRun();
  const before = (await untilFeed(port)).j;
  await act();
  const after = await untilFeed(port);
  expect(after.r.status).toBe(200);
  expect(after.j.seq).toBeGreaterThan(actedAt()); // a report started after the action
  expect(after.j.seq).not.toBe(before.seq);
}, 20_000);

test("a refresh started before an action never becomes the cached report after it", async () => {
  let t = 1_000_000;
  const { port, act, actedAt, sleepFile } = bootRun({ now: () => t });
  expect((await untilFeed(port)).r.status).toBe(200);
  writeFileSync(sleepFile, "1500"); // the next full report is slow
  t += 31_000;
  expect((await timed(port)).r.status).toBe(200); // the stale report, and a (pre-action) refresh starts
  await act(); // lands while that refresh still runs
  await sleep(1800); // the pre-action refresh has finished by now
  unlinkSync(sleepFile);
  const after = await untilFeed(port);
  expect(after.j.seq).toBeGreaterThan(actedAt());
}, 20_000);
