// HIMMEL-4712: GET /api/agui/fleet — every live session on one page. Drives the REAL fleet.sh (claude_sessions,
// leg_tail_status) through claude-sessions.sh's own seams: a stub pgrep and a fake /proc whose cmdlines carry -n.
import { test, expect, afterEach } from "bun:test";
import { chmodSync, mkdtempSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startServer } from "../server";
import { fleetFixture, FLEET } from "./agui-fleet-fixture";

const STUB = join(import.meta.dir, "stub-himmelctl.js");
const TOKEN = "t".repeat(64);
const cleanups: (() => void)[] = [];
afterEach(() => { while (cleanups.length) cleanups.pop()!(); });

function boot() {
  const dir = mkdtempSync(join(tmpdir(), "agui-fleet-"));
  const fx = fleetFixture(dir);
  const s = startServer({ port: 0, token: TOKEN, env: { PATH: process.env.PATH, CONFIG_UI_HIMMELCTL: STUB, CONFIG_UI_IDLE_MS: "60000", ...fx.env } });
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
