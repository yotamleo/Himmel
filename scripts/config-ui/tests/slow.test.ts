// HIMMEL-4369: Bun.serve cuts any request slower than 10 s by default, and every
// other config-ui test answers instantly. These rows use a stub that is slower.
import { test, expect, afterEach } from "bun:test";
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startServer } from "../server";

const TOKEN = "t".repeat(64);
const H = { "X-Himmel-Token": TOKEN };
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const dirs: string[] = [];
const stops: (() => void)[] = [];
afterEach(() => { while (stops.length) stops.pop()!(); while (dirs.length) rmSync(dirs.pop()!, { recursive: true, force: true }); });

function boot(env: Record<string, string>, x: Record<string, unknown> = {}) {
  const dir = mkdtempSync(join(tmpdir(), "cfgui-slow-"));
  dirs.push(dir);
  mkdirSync(join(dir, "home"), { recursive: true });
  const s = startServer({ port: 0, token: TOKEN, env: { PATH: process.env.PATH, HOME: join(dir, "home"), CONFIG_UI_IDLE_MS: "60000", ...env }, ...x } as never);
  stops.push(() => s.stop());
  return { port: s.port, dir };
}
const feed = (port: number) => fetch(`http://127.0.0.1:${port}/api/feed`, { headers: H });
const STUB = join(import.meta.dir, "stub-himmelctl.js");

// Poll like the page does: 202 means "still probing", keep asking.
async function untilFeed(port: number) {
  const seen: number[] = [];
  for (;;) {
    const r = await feed(port);
    seen.push(r.status);
    if (r.status !== 202) return { r, seen };
  }
}

test("a feed slower than Bun's 10 s default still arrives: 202 while probing, then the 200 feed", async () => {
  const { port } = boot({ CONFIG_UI_HIMMELCTL: STUB, STUB_FEED_SLEEP: "11500" }, { feedWaitMs: 3000 });
  const { r, seen } = await untilFeed(port);
  expect(seen[0]).toBe(202);
  expect(r.status).toBe(200);
  expect((await r.json()).schema).toBe("himmel-config-feed/1");
}, 30_000);

test("concurrent feed requests share one report run, and the result is cached", async () => {
  const count = join(mkdtempSync(join(tmpdir(), "cfgui-cnt-")), "n");
  dirs.push(join(count, ".."));
  const { port } = boot({ CONFIG_UI_HIMMELCTL: STUB, STUB_FEED_SLEEP: "600", STUB_FEED_COUNT: count });
  const rs = await Promise.all([feed(port), feed(port), feed(port)]);
  expect(rs.map((r) => r.status)).toEqual([200, 200, 200]);
  expect((await feed(port)).status).toBe(200); // cached
  expect(readFileSync(count, "utf8").split("\n").filter(Boolean).length).toBe(1);
});

test("a failed report is a terminal error, is not cached, and the next request retries it", async () => {
  const count = join(mkdtempSync(join(tmpdir(), "cfgui-cnt-")), "n");
  dirs.push(join(count, ".."));
  const { port } = boot({ CONFIG_UI_HIMMELCTL: STUB, STUB_FEED_SLEEP: "5000", STUB_FEED_COUNT: count }, { feedTimeoutMs: 300 });
  const r = await feed(port);
  expect(r.status).toBe(502);
  expect((await r.json()).state).toBe("error");
  expect((await feed(port)).status).toBe(502);
  expect(readFileSync(count, "utf8").split("\n").filter(Boolean).length).toBe(2); // a fresh run each time, no cached failure
});

test("a slow /api/run (over 10 s) still returns its result to the client", async () => {
  const dir = mkdtempSync(join(tmpdir(), "cfgui-run-"));
  dirs.push(dir);
  const [home, cad, state] = ["home", "cad", "state"].map((d) => { mkdirSync(join(dir, d), { recursive: true }); return join(dir, d); });
  const rel = "scripts/luna/graphmap-cadence.sh";
  mkdirSync(join(cad, "scripts/luna"), { recursive: true });
  copyFileSync(join(import.meta.dir, "stub-cadence.sh"), join(cad, rel));
  const repo = join(dir, "repo");
  mkdirSync(repo);
  const argv = join(dir, "argv");
  writeFileSync(argv, "");
  const s = startServer({ port: 0, token: TOKEN, root: repo, env: { PATH: process.env.PATH, HOME: home, CONFIG_UI_IDLE_MS: "60000",
    CONFIG_UI_HIMMELCTL: join(import.meta.dir, "stub-recorder.js"), HIMMEL_REPORT_CADENCE_ROOT: cad, STUB_ARGV: argv, STUB_STATE: state, STUB_RUN_SLEEP: "11" } } as never);
  stops.push(() => s.stop());
  const post = (path: string, body: unknown) => fetch(`http://127.0.0.1:${s.port}${path}`, { method: "POST", body: JSON.stringify(body),
    headers: { ...H, Origin: `http://127.0.0.1:${s.port}`, "Content-Type": "application/json" } });
  const ARM = { action: "cadence.arm", target: "graphmap" };
  expect((await feed(s.port)).status).toBe(200);
  const pv = await (await post("/api/preview", ARM)).json();
  const r = await post("/api/run", { previewId: pv.previewId, ...ARM, consent: "graphmap" });
  expect(r.status).toBe(200);
  expect((await r.json()).rc).toBe(0);
  // The action changed the station: the next feed re-probes instead of serving the 30 s cache.
  expect((await feed(s.port)).status).toBe(200);
  const feedRuns = readFileSync(argv, "utf8").split("\n").filter((l) => /^himmelctl report\b/.test(l) && !l.includes("--items"));
  expect(feedRuns.length).toBe(2);
}, 40_000);

test("a /api/run rejected before it starts leaves the shared feed run alone", async () => {
  const count = join(mkdtempSync(join(tmpdir(), "cfgui-cnt-")), "n");
  dirs.push(join(count, ".."));
  const { port } = boot({ CONFIG_UI_HIMMELCTL: STUB, STUB_FEED_SLEEP: "300", STUB_FEED_COUNT: count });
  expect((await feed(port)).status).toBe(200);
  const r = await fetch(`http://127.0.0.1:${port}/api/run`, { method: "POST", body: JSON.stringify({ previewId: "nope", action: "cadence.arm", target: "graphmap" }),
    headers: { ...H, Origin: `http://127.0.0.1:${port}`, "Content-Type": "application/json" } });
  expect(r.status).toBe(409);
  expect((await feed(port)).status).toBe(200); // still the cached run
  expect(readFileSync(count, "utf8").split("\n").filter(Boolean).length).toBe(1);
});

// app.js is a browser module; run it against stubs and drive loadFeed directly.
test("page: a slower, older feed load never repaints over a newer one", async () => {
  const src = readFileSync(join(import.meta.dir, "../public/app.js"), "utf8")
    .replace(/^import .*$/gm, "").concat("\nglobalThis.__loadFeed = loadFeed;\n");
  const painted: string[] = [];
  const el = () => ({ textContent: "", innerHTML: "", hidden: false, focus() {}, setSelectionRange() {} });
  const waiting: ((b: string) => void)[] = [];
  let first = true;
  const g = globalThis as Record<string, unknown>;
  const names = ["render", "renderNav", "renderHeader", "document", "location", "history", "fetch", "__loadFeed"];
  const saved = Object.fromEntries(names.map((n) => [n, g[n]]));
  Object.assign(g, {
    render: (f: { id?: string } | null) => { if (f) painted.push(f.id ?? "?"); return ""; }, renderNav: () => "", renderHeader: () => "",
    document: { querySelector: el, querySelectorAll: () => [], getElementById: el, activeElement: null, addEventListener() {} },
    location: { hash: "", pathname: "/", search: "" }, history: { replaceState() {} },
    fetch: () => new Promise((res) => {
      const ok = (b: string) => res({ status: 200, ok: true, json: async () => ({ id: b }) });
      if (first) { first = false; ok("initial"); } else waiting.push(ok);
    }),
  });
  try {
    new Function(src)();
    await sleep(20);
    const load = g.__loadFeed as () => Promise<void>;
    const a = load(), b = load(); // two actions each start a re-probe
    await sleep(20);
    waiting[1]("newer"); await b;
    waiting[0]("older"); await a; // the older report lands last
  } finally { for (const n of names) { if (saved[n] === undefined) delete g[n]; else g[n] = saved[n]; } }
  expect(painted).toEqual(["initial", "newer"]);
});

test("the server refuses to start when a route budget would outlast idleTimeout", () => {
  const env = { PATH: process.env.PATH, HOME: tmpdir() };
  expect(() => startServer({ port: 0, token: TOKEN, env, reprobeBudgetMs: 120_000 } as never)).toThrow(/idleTimeout/);
  const ok = startServer({ port: 0, token: TOKEN, env });
  stops.push(() => ok.stop());
});

test("a server idle after a feed still exits on time (an in-flight report does not leak the idle guard)", async () => {
  let idled = false;
  const { port } = boot({ CONFIG_UI_HIMMELCTL: STUB, CONFIG_UI_IDLE_MS: "800", STUB_FEED_SLEEP: "300" }, { onIdle: () => { idled = true; } });
  expect((await feed(port)).status).toBe(200);
  await sleep(2000);
  expect(idled).toBe(true);
});
