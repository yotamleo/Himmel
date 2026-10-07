// HIMMEL-4712: GET /api/agui/fleet — every live session on one page. Drives the REAL fleet.sh (claude_sessions,
// leg_tail_status) through claude-sessions.sh's own seams: a stub pgrep and a fake /proc whose cmdlines carry -n.
import { test, expect, afterEach } from "bun:test";
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startServer } from "../server";
import { CLOUD, fleetFixture, FLEET, PRIOR_CONSOLE } from "./agui-fleet-fixture";

const STUB = join(import.meta.dir, "stub-himmelctl.js");
const TOKEN = "t".repeat(64);
const cleanups: (() => void)[] = [];
afterEach(() => { while (cleanups.length) cleanups.pop()!(); });

function boot(extra: Record<string, string> = {}, opts: { cloud?: boolean } = {}) {
  const dir = mkdtempSync(join(tmpdir(), "agui-fleet-"));
  const fx = fleetFixture(dir, opts);
  const s = startServer({ port: 0, token: TOKEN, env: { PATH: process.env.PATH, CONFIG_UI_HIMMELCTL: STUB, CONFIG_UI_IDLE_MS: "60000", ...fx.env, ...extra } });
  cleanups.push(() => { s.stop(); rmSync(dir, { recursive: true, force: true }); });
  return { ...s, ...fx };
}
const fleet = (port: number, headers: Record<string, string> = { "X-Himmel-Token": TOKEN }, method = "GET") =>
  fetch(`http://127.0.0.1:${port}/api/agui/fleet`, { headers, method });

test("token-gated and read-only: no token is 401, POST is 405", async () => {
  const { port } = boot();
  expect((await fleet(port, {})).status).toBe(401);
  expect((await fleet(port, { "X-Himmel-Token": TOKEN }, "POST")).status).toBe(405);
  expect((await fleet(port)).status).toBe(200);
});

test("3 live sessions and 1 wrapped: roles, tickets, PR, state, activity, subagents, failures", async () => {
  const { port } = boot();
  const b = await (await fleet(port)).json();
  expect(b.census).toBe("ok");
  const by = Object.fromEntries(b.sessions.map((s: any) => [s.name, s]));
  expect(Object.keys(by).sort()).toEqual([FLEET.console.name, FLEET.idle.name, FLEET.leg.name, FLEET.wrapped.name].sort());

  const c = by[FLEET.console.name];
  expect(c).toMatchObject({ run: FLEET.console.run, role: "console", state: "running", ticket: null });
  expect(c.activity).toMatchObject({ tool: "Bash", summary: "Tick the fleet" });
  expect(typeof c.activity.at).toBe("number");

  const l = by[FLEET.leg.name];
  expect(l).toMatchObject({ run: FLEET.leg.run, role: "leg", state: "running", ticket: "HIMMEL-901", pr: 1901, failures: 1, model: "opus" });
  expect(l.subagents).toEqual({ total: 1, running: 1 });
  expect(l.activity).toMatchObject({ tool: "Grep" }); // the newest call is the subagent's

  expect(by[FLEET.idle.name]).toMatchObject({ role: "interactive", state: "idle", subagents: { total: 0, running: 0 }, failures: 0 });

  // A wrapped leg is wrapped whatever its process says, never running.
  expect(by[FLEET.wrapped.name]).toMatchObject({ role: "leg", state: "wrapped", ticket: "HIMMEL-903" });
});

test("a session whose journal went quiet past the window is not listed; one with no journal is listed bare", async () => {
  const s = boot();
  const old = (Date.now() - 2 * 60 * 60 * 1000) / 1000;
  utimesSync(s.journal(FLEET.idle), old, old);
  rmSync(s.journal(FLEET.console));
  const b = await (await fleet(s.port)).json();
  const names = b.sessions.map((x: any) => x.name);
  expect(names).not.toContain(FLEET.idle.name);
  expect(b.sessions.find((x: any) => x.name === FLEET.console.name)).toMatchObject({ run: FLEET.console.run, activity: null, failures: 0 });
});

test("the census failing is reported, not read as an empty fleet", async () => {
  const s = boot();
  writeFileSync(s.pgrep, "#!/bin/sh\nexit 2\n");
  chmodSync(s.pgrep, 0o755);
  const b = await (await fleet(s.port)).json();
  expect(b).toMatchObject({ census: "unavailable", sessions: [] });
});

test("secrets in the latest call's summary pass the redactor; names are kept", async () => {
  const s = boot();
  const secret = "sk-ant-api03-" + "A".repeat(60);
  s.append(FLEET.console, { type: "assistant", message: { id: "m-s", role: "assistant", stop_reason: "tool_use", content: [{ type: "tool_use", id: "toolu_s", name: "Bash", input: { command: `curl -H 'x-api-key: ${secret}' https://x` } }] } });
  const b = await (await fleet(s.port)).json();
  const c = b.sessions.find((x: any) => x.name === FLEET.console.name);
  expect(c.activity.tool).toBe("Bash");
  expect(JSON.stringify(c)).not.toContain(secret);
  expect(c.name).toBe(FLEET.console.name);
});

test("a session started without a name keeps its model and takes the harness's name (empty census columns do not shift)", async () => {
  const s = boot();
  writeFileSync(join(s.dir, "proc", String(FLEET.idle.pid), "cmdline"), ["claude", "--model", "sonnet", ""].join("\0"));
  const b = await (await fleet(s.port)).json();
  expect(b.sessions.find((x: any) => x.pid === FLEET.idle.pid)).toMatchObject({ name: FLEET.idle.name, model: "sonnet", role: "interactive" });
});

test("a quiet main journal with a subagent still writing stays listed", async () => {
  const s = boot();
  const old = (Date.now() - 2 * 60 * 60 * 1000) / 1000;
  utimesSync(s.journal(FLEET.leg), old, old);
  const b = await (await fleet(s.port)).json();
  expect(b.sessions.map((x: any) => x.name)).toContain(FLEET.leg.name);
});

test("a secret straddling the summary cut is redacted whole, not left as a fragment", async () => {
  // Not token-shaped, so only the env literal catches it — and only while it is whole.
  const secret = "plainvalue" + "q".repeat(40);
  const s = boot({ FLEET_TEST_SECRET: secret });
  s.append(FLEET.console, { type: "assistant", message: { id: "m-t", role: "assistant", stop_reason: "tool_use", content: [{ type: "tool_use", id: "toolu_t", name: "Bash", input: { command: "x".repeat(100) + secret } }] } });
  const b = await (await fleet(s.port)).json();
  const c = b.sessions.find((x: any) => x.name === FLEET.console.name);
  expect(c.activity.summary).not.toContain(secret.slice(0, 20));
});

// HIMMEL-4751: each row's place in the graph and its token usage, from the census's own sources.
test("graph: the leg hangs under its console, the console names its predecessor, the rest sit under the operator", async () => {
  const { port } = boot();
  const by = Object.fromEntries((await (await fleet(port)).json()).sessions.map((s: any) => [s.name, s]));
  expect(by[FLEET.leg.name]).toMatchObject({ parent: FLEET.console.name, predecessor: null });
  expect(by[FLEET.console.name]).toMatchObject({ parent: null, predecessor: PRIOR_CONSOLE });
  expect(by[FLEET.idle.name]).toMatchObject({ parent: null, predecessor: null });
  // The leg's in-process children: its one subagent, still running.
  expect(by[FLEET.leg.name].agents).toEqual([expect.objectContaining({ state: "running" })]);
  expect(by[FLEET.idle.name].agents).toEqual([]);
});

test("usage: summed per API call across the journal and its subagents, filled against the session's own ceiling", async () => {
  const { port } = boot();
  const by = Object.fromEntries((await (await fleet(port)).json()).sessions.map((s: any) => [s.name, s]));
  // Leg: 2 main calls + 1 subagent call, each 10 in / 100 out / 40000 cache read; --autocompact 200000.
  expect(by[FLEET.leg.name].usage).toEqual({
    calls: 3, input: 30, output: 300, cacheRead: 120000, cacheCreate: 0, costEq: Math.round(30 + 12000 + 1500),
    resident: 40010, ceiling: 200000, ceilingFrom: "autocompact", fill: 20,
  });
  // Console: --autocompact auto on a [1m] model runs against the 1m window.
  expect(by[FLEET.console.name].usage).toMatchObject({ calls: 1, ceiling: 1000000, ceilingFrom: "window", fill: 4 });
  // The idle session's journal carries no usage record: not measured, not zero.
  expect(by[FLEET.idle.name].usage).toBeNull();
});

// HIMMEL-4791: a cloud session has no local process, so its node comes from the console bucket's cloud-route.jsonl
// plus the CLOUD-DONE comment on its PR (one batched, cached GitHub read through the stub gh), and its local
// shepherd leg hangs under it. Its tokens are not measured, never zero.
test("cloud: each recent CLOUD-OK route is a node under its console, from its PR and CLOUD-DONE comment; its shepherd hangs under it", async () => {
  const { port } = boot({}, { cloud: true });
  const b = await (await fleet(port)).json();
  const by = Object.fromEntries(b.sessions.map((s: any) => [s.name, s]));
  expect(b.sessions.filter((s: any) => s.role === "cloud").map((s: any) => s.name).sort()).toEqual(["cloud-HIMMEL-905", "cloud-HIMMEL-906", "cloud-HIMMEL-907"]);
  expect(by["cloud-HIMMEL-905"]).toMatchObject({
    pid: null, run: null, role: "cloud", model: null, ticket: "HIMMEL-905", pr: 1905, state: "idle",
    parent: FLEET.console.name, predecessor: null, agents: [], usage: null, cloud: { url: CLOUD.url, phase: "done" },
  });
  expect(by["cloud-HIMMEL-906"]).toMatchObject({ pr: null, state: "running", parent: FLEET.console.name, cloud: { url: null, phase: "working" } });
  expect(by["cloud-HIMMEL-907"]).toMatchObject({ pr: 1907, state: "wrapped", cloud: { phase: "merged" } });
  // The shepherd's brief names the console; as the cloud session's local shepherd it hangs under the cloud node.
  expect(by[CLOUD.shepherd.name]).toMatchObject({ role: "leg", ticket: "HIMMEL-905", parent: "cloud-HIMMEL-905", cloud: null });
  expect(by[FLEET.leg.name]).toMatchObject({ parent: FLEET.console.name, cloud: null });
});

test("cloud: GitHub is read once per cache window, in one batched query naming only the routed tickets", async () => {
  const s = boot({}, { cloud: true });
  await fleet(s.port);
  await fleet(s.port);
  const calls = readFileSync(s.gh.calls, "utf8").trim().split("\n");
  expect(calls).toHaveLength(1);
  expect(calls[0]).toMatch(/^api graphql /);
  for (const t of ["HIMMEL-905", "HIMMEL-906", "HIMMEL-907"]) expect(calls[0]).toContain(t);
  for (const t of ["HIMMEL-908", "HIMMEL-909", "HIMMEL-910"]) expect(calls[0]).not.toContain(t);
});

test("cloud: a failed GitHub read degrades every cloud node to unknown and still serves the fleet", async () => {
  const s = boot({}, { cloud: true });
  writeFileSync(s.gh.rc, "1");
  const r = await fleet(s.port);
  expect(r.status).toBe(200);
  const b = await r.json();
  expect(b.census).toBe("ok");
  const cloud = b.sessions.filter((x: any) => x.role === "cloud");
  expect(cloud).toHaveLength(3);
  for (const c of cloud) expect(c).toMatchObject({ pr: null, state: "unknown", usage: null, cloud: { url: null, phase: "unknown" } });
  expect(b.sessions.find((x: any) => x.name === CLOUD.shepherd.name).parent).toBe("cloud-HIMMEL-905");
});

test("cloud: no routed cloud ticket, no GitHub read", async () => {
  const s = boot();
  const b = await (await fleet(s.port)).json();
  expect(b.sessions.some((x: any) => x.role === "cloud")).toBe(false);
  expect(existsSync(s.gh.calls)).toBe(false);
});
