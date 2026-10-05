// HIMMEL-4405 PR-b: GET /api/health — bank / legs / monitoring, each degrading alone.
import { test, expect, afterEach } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startServer } from "../server";

const STUB = join(import.meta.dir, "stub-himmelctl.js");
const TOKEN = "t".repeat(64);
const cleanups: (() => void)[] = [];
afterEach(() => { while (cleanups.length) cleanups.pop()!(); });

type Env = Record<string, string | undefined>;
// A scratch HOME (the ledger lives under it), an empty handover root, and monitoring pointed at a dead port.
function boot(env: Env = {}, opts: Record<string, unknown> = {}) {
  const dir = mkdtempSync(join(tmpdir(), "health-route-"));
  const home = join(dir, "home"), root = join(dir, "root");
  mkdirSync(home); mkdirSync(root);
  const s = startServer({
    port: 0, token: TOKEN, ...opts,
    env: { PATH: process.env.PATH, CONFIG_UI_HIMMELCTL: STUB, CONFIG_UI_IDLE_MS: "60000", HOME: home, HANDOVER_DIR: root, HIMMEL_PROMETHEUS_URL: "http://127.0.0.1:1", HIMMEL_FLOW_EXPORTER_PORT: "1", ...env },
  });
  cleanups.push(() => { s.stop(); rmSync(dir, { recursive: true, force: true }); });
  return { ...s, dir, home, root, ledger: join(home, ".himmel", "cadence-ledger.jsonl") };
}
const health = async (port: number, headers: Record<string, string> = { "X-Himmel-Token": TOKEN }) => fetch(`http://127.0.0.1:${port}/api/health`, { headers });
const body = async (port: number) => (await health(port)).json();
const writeLedger = (file: string, lines: string[]) => { mkdirSync(join(file, ".."), { recursive: true }); writeFileSync(file, lines.join("\n") + "\n"); };
const bankRow = (extra: Record<string, unknown> = {}) => JSON.stringify({ ts: "2026-10-05T02:00:00Z", leg: "l", verdict: "PROCEED", five_hour: "22.0", seven_day: "86.0", age: "12", degraded: false, ...extra });
const hold = () => Bun.serve({ port: 0, hostname: "127.0.0.1", fetch: () => new Promise<Response>(() => {}) });

test("I4: no token is 401 and POST is 405", async () => {
  const { port } = boot();
  expect((await health(port, {})).status).toBe(401);
  expect((await fetch(`http://127.0.0.1:${port}/api/health`, { method: "POST", headers: { "X-Himmel-Token": TOKEN } })).status).toBe(405);
  expect((await health(port)).status).toBe(200);
});

test("bank: absent without a ledger, ok with the newest row that carries bank numbers", async () => {
  const s = boot();
  expect((await body(s.port)).bank.state).toBe("absent");
  writeLedger(s.ledger, [bankRow({ verdict: "SKIPPED-BANK", seven_day: "10.0" }), bankRow(), bankRow({ five_hour: "", seven_day: "", verdict: "PROCEED" }), "not json"]);
  const b = (await body(s.port)).bank;
  expect(b.state).toBe("ok");
  expect(b.row).toMatchObject({ verdict: "PROCEED", five_hour: "22.0", seven_day: "86.0", age: "12", degraded: false, ts: "2026-10-05T02:00:00Z" });
});

test("bank: CADENCE_BANK_LEDGER overrides the default path", async () => {
  const own = boot();
  const alt = join(own.dir, "alt.jsonl");
  writeFileSync(alt, bankRow({ seven_day: "42.0" }) + "\n");
  const s = boot({ CADENCE_BANK_LEDGER: alt });
  expect((await body(s.port)).bank.row.seven_day).toBe("42.0");
});

test("bank: only the last 64 KiB is read (a 44k-line ledger; numbers only beyond the tail read as absent)", async () => {
  const s = boot();
  const empty = bankRow({ five_hour: "", seven_day: "" });
  writeLedger(s.ledger, [bankRow({ seven_day: "1.0" }), ...Array.from({ length: 44_000 }, () => empty)]);
  expect((await body(s.port)).bank.state).toBe("absent");
  writeLedger(s.ledger, [...Array.from({ length: 44_000 }, () => empty), bankRow({ seven_day: "2.0" })]);
  expect((await body(s.port)).bank.row.seven_day).toBe("2.0");
});

test("legs: absent with no manifest, ok with one (real fleet-manifest.sh and leg_tail_status)", async () => {
  const s = boot();
  expect((await body(s.port)).legs.state).toBe("absent");
  const doc = join(s.root, "HIMMEL-1-N1-x-RESUME.md");
  writeFileSync(doc, "## Results\n- 03:00 LIVE — x\n");
  writeFileSync(join(s.root, "c.fleet.json"), JSON.stringify({ schema: 1, legs: [{ doc }] }));
  const l = (await body(s.port)).legs;
  expect(l.state).toBe("ok");
  expect(l.legs).toEqual([{ doc, status: "LIVE" }]);
});

test("legs: a HANDOVER_DIR that is not a directory is absent, not an error page", async () => {
  const s = boot({ HANDOVER_DIR: "/nonexistent/health-route-root" });
  expect((await body(s.port)).legs.state).toBe("absent");
});

test("monitoring: absent when nothing answers; ok with Prometheus alerts (firing only) and the exporter", async () => {
  const none = boot();
  expect((await body(none.port)).monitoring).toMatchObject({ state: "absent", prometheus: { state: "absent" }, exporter: { state: "absent" } });
  const prom = Bun.serve({ port: 0, hostname: "127.0.0.1", fetch: (r) => new URL(r.url).pathname === "/api/v1/alerts"
    ? Response.json({ status: "success", data: { alerts: [
      { state: "firing", labels: { alertname: "A1", severity: "page" }, annotations: { summary: "s1" } },
      { state: "pending", labels: { alertname: "A2", severity: "warn" }, annotations: { summary: "s2" } }] } })
    : new Response("x") });
  const exp = Bun.serve({ port: 0, hostname: "127.0.0.1", fetch: () => new Response("# metrics") });
  cleanups.push(() => { prom.stop(true); exp.stop(true); });
  const s = boot({ HIMMEL_PROMETHEUS_URL: `http://127.0.0.1:${prom.port}`, HIMMEL_FLOW_EXPORTER_PORT: String(exp.port) });
  const m = (await body(s.port)).monitoring;
  expect(m.state).toBe("ok");
  expect(m.prometheus.alerts).toEqual([{ alertname: "A1", severity: "page", summary: "s1" }]);
  expect(m.exporter.state).toBe("ok");
});

test("monitoring: a Prometheus that answers 500 is an error, not absent", async () => {
  const prom = Bun.serve({ port: 0, hostname: "127.0.0.1", fetch: () => new Response("boom", { status: 500 }) });
  cleanups.push(() => prom.stop(true));
  const s = boot({ HIMMEL_PROMETHEUS_URL: `http://127.0.0.1:${prom.port}` });
  expect((await body(s.port)).monitoring.prometheus.state).toBe("error");
});

test("I7: a non-loopback HIMMEL_PROMETHEUS_URL is refused and never fetched", async () => {
  const s = boot({ HIMMEL_PROMETHEUS_URL: "http://example.com" });
  const m = (await body(s.port)).monitoring;
  expect(m.state).toBe("error");
  expect(m.reason).toBe("non-loopback URL refused");
});

test("hanging sources answer within the slowest budget, not the sum (parallel)", async () => {
  const slow = join(tmpdir(), `health-route-slow-${process.pid}.sh`);
  writeFileSync(slow, "#!/usr/bin/env bash\nsleep 30\n");
  cleanups.push(() => rmSync(slow, { force: true }));
  const prom = hold(), exp = hold();
  cleanups.push(() => { prom.stop(true); exp.stop(true); });
  const s = boot({ HIMMEL_PROMETHEUS_URL: `http://127.0.0.1:${prom.port}`, HIMMEL_FLOW_EXPORTER_PORT: String(exp.port) }, { legsScript: slow, legsTimeoutMs: 2500 });
  const t0 = Date.now();
  const j = await body(s.port);
  const took = Date.now() - t0;
  expect(j.legs.state).toBe("error");
  expect(j.monitoring.prometheus.state).toBe("error");
  expect(j.monitoring.exporter.state).toBe("error");
  expect(took).toBeLessThan(4500); // sequential would be 2 + 2 + 2.5 s
}, 15_000);
