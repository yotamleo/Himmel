// HIMMEL-4816: three seeded digests exercise the real ledger writer and server rate math.
import { test, expect, afterEach } from "bun:test";
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import * as sources from "../health-sources";
import { startServer } from "../server";
import { navLinks, parseLanding } from "../public/nav.js";

const dirs: string[] = [];
afterEach(() => { for (const d of dirs.splice(0)) rmSync(d, { recursive: true, force: true }); });
const agent = { id: "main", role: "agent", kind: null, model: "gpt-6.1-sol" };
function seed() {
  const dir = mkdtempSync(join(tmpdir(), "tool-health-")); dirs.push(dir);
  const evals = join(dir, "eval.jsonl"), failures = join(dir, "fail.jsonl");
  const samples = [
    { lane: "native", bash: 10, read: 10, errors: 2, denied: 1, recovered: true },
    { lane: "claudex", bash: 30, read: 10, errors: 1, denied: 3, recovered: false },
    { lane: "native", bash: 10, read: 0, errors: 0, denied: 1, recovered: null },
  ];
  for (const [i, s] of samples.entries()) {
    const session = `48160000-0000-4000-8000-00000000000${i}`;
    const row = (cls: string, count: number, recovered: boolean | null) => ({ session, agent, class: cls, failure: cls.split("/")[0], count, recovered, identical_retry: null, first_ts: Date.parse("2026-10-07T12:00:00Z"), last_ts: Date.parse("2026-10-07T12:00:01Z"), tool_call_ids: [`toolu_${i}`] });
    const digest = { digest_v: 2, mapper_v: 1, trajectory_v: 1, session, status: "ok", model: agent.model,
      lane: s.lane, started_ts: Date.parse("2026-10-07T12:00:00Z"), agents: [agent],
      metrics: { tool_calls: s.bash + s.read, turns: 1, tool_calls_by_tool: { Bash: s.bash, Read: s.read }, tool_failures_by_tool: { Bash: s.errors + s.denied } },
      tool_health: [{ agent, lane: s.lane, tool: "Bash", calls: s.bash, failures: s.errors + s.denied, errors: s.errors, denials: s.denied }, { agent, lane: s.lane, tool: "Read", calls: s.read, failures: 0, errors: 0, denials: 0 }],
      failures: [row("denied/read-clamp", s.denied, s.recovered), ...(s.errors ? [row("error/Bash", s.errors, null)] : [])] };
    const file = join(dir, `digest${i}.json`); writeFileSync(file, JSON.stringify(digest));
    const r = Bun.spawnSync(["python3", resolve(import.meta.dir, "../../eval/leg-digest/leg_ledger.py"), "record", "--digest", file, "--lane", s.lane, "--leg", `N${i + 1}`, "--failures-ledger", failures, "--eval-ledger", evals, "--state-dir", join(dir, "state")]);
    expect(r.exitCode).toBe(0);
  }
  return { HIMMEL_EVAL_RUNS_LEDGER: evals, HIMMEL_LEG_FAILURES_LEDGER: failures };
}
const read = (env: object, query = new URLSearchParams()) => (sources as any).readToolHealth(env, query, Date.parse("2026-10-07T23:59:00Z"));

test("three digests use weighted calls, not the mean of session percentages", () => {
  expect(typeof (sources as any).readToolHealth).toBe("function");
  const data = read(seed());
  expect(data.state).toBe("ok");
  expect(data.tools.find((r: any) => r.tool === "Bash")).toMatchObject({ calls: 50, failures: 8, rate: 0.16, error_rate: 0.06, recovery_rate: 0.25 });
  expect(data.hooks.find((r: any) => r.class === "denied/read-clamp")).toMatchObject({ calls: 50, failures: 5, rate: 0.1 });
  expect(data.daily.find((r: any) => r.lane === "native" && r.tool === "Bash")).toMatchObject({ day: "2026-10-07", calls: 20, failures: 4, rate: 0.2 });
  expect(data.tools.find((r: any) => r.tool === "Bash").trend).toHaveLength(7);
});

test("lane filters and comparisons use per-lane call totals; recovery excludes unknown rows", () => {
  const env = seed(), data = read(env, new URLSearchParams({ lane: "native", days: "30" }));
  expect(data.tools.find((r: any) => r.tool === "Bash")).toMatchObject({ calls: 20, failures: 4, rate: 0.2, recovery_rate: 1 });
  expect(data.tools.find((r: any) => r.tool === "Bash").trend).toHaveLength(30);
  const comparison = read(env).comparison.find((r: any) => r.metric === "calls_per_100" && r.key === "Bash");
  expect(comparison.values.native).toBeCloseTo(200 / 3);
  expect(comparison.values.claudex).toBe(75);
  expect(comparison.delta.claudex).toBeCloseTo(25 / 3);
  expect(read(env, new URLSearchParams({ model: "absent" })).tools).toEqual([]);
  expect(read(env, new URLSearchParams({ role: "console" })).tools).toEqual([]);
});

test("legacy digests keep failures visible without inventing a zero rate", () => {
  const env = seed();
  const lines = readFileSync(env.HIMMEL_EVAL_RUNS_LEDGER, "utf8").trim().split("\n").map((l: string) => JSON.parse(l));
  for (const r of lines) { delete r.meta.tool_health; r.config.digest_v = 1; }
  writeFileSync(env.HIMMEL_EVAL_RUNS_LEDGER, lines.map(JSON.stringify).join("\n") + "\n");
  const data = read(env);
  expect(data.tools.find((r: any) => r.tool === "Bash")).toMatchObject({ calls: null, failures: 8, rate: null });
  expect(data.hooks[0].rate).toBeNull();
});

test("recorded leg-doc lane overrides extractor provenance and stamps every persisted tool row", () => {
  const env = seed(), dir = dirs[dirs.length - 1];
  const doc = join(dir, "leg.md"), file = join(dir, "digest0.json"), evals = join(dir, "doc-eval.jsonl"), state = join(dir, "doc-state");
  writeFileSync(doc, "> Sibling N2 uses native lane.\n# N1 (gpt-6.1-sol, cloud lane, headed)\n");
  const r = Bun.spawnSync(["python3", resolve(import.meta.dir, "../../eval/leg-digest/leg_ledger.py"), "record", "--digest", file, "--doc", doc, "--leg", "N1", "--failures-ledger", join(dir, "doc-fail.jsonl"), "--eval-ledger", evals, "--state-dir", state]);
  expect(r.exitCode).toBe(0);
  const row = JSON.parse(readFileSync(evals, "utf8"));
  expect(row.lane).toBe("cloud");
  expect(row.meta.tool_health.every((h: any) => h.lane === "cloud")).toBe(true);
  const saved = JSON.parse(readFileSync(join(state, "48160000-0000-4000-8000-000000000000.json"), "utf8"));
  expect(saved.lane).toBe("cloud");
  expect(saved.tool_health.every((h: any) => h.lane === "cloud")).toBe(true);
  expect(read({ ...env, HIMMEL_EVAL_RUNS_LEDGER: evals }).daily[0].lane).toBe("cloud");
});

test("a mixed legacy population poisons incomplete denominators, not failure counts", () => {
  const env = seed();
  const rows = readFileSync(env.HIMMEL_EVAL_RUNS_LEDGER, "utf8").trim().split("\n").map((l: string) => JSON.parse(l));
  delete rows[0].meta.tool_health;
  writeFileSync(env.HIMMEL_EVAL_RUNS_LEDGER, rows.map(JSON.stringify).join("\n") + "\n");
  const data = read(env);
  expect(data.tools.find((r: any) => r.tool === "Bash")).toMatchObject({ calls: null, failures: 8, rate: null });
  expect(data.daily.find((r: any) => r.tool === "Bash" && r.lane === "native").rate).toBeNull();
  expect(read(env, new URLSearchParams({ lane: "claudex" })).tools.find((r: any) => r.tool === "Bash").calls).toBe(30);
});

test("a session spanning midnight assigns each call cohort to its actual UTC day", () => {
  const env = seed();
  const rows = readFileSync(env.HIMMEL_EVAL_RUNS_LEDGER, "utf8").trim().split("\n").map((l: string) => JSON.parse(l));
  for (const h of rows[0].meta.tool_health) h.day = "2026-10-06";
  writeFileSync(env.HIMMEL_EVAL_RUNS_LEDGER, rows.map(JSON.stringify).join("\n") + "\n");
  const data = read(env);
  expect(data.daily.find((r: any) => r.day === "2026-10-06" && r.tool === "Bash")).toMatchObject({ calls: 10, failures: 3 });
  expect(data.daily.find((r: any) => r.day === "2026-10-07" && r.lane === "native" && r.tool === "Bash")).toMatchObject({ calls: 10, failures: 1 });
});

test("since retains current-day tool cohorts from sessions started before the cutoff", () => {
  const env = seed();
  const rows = readFileSync(env.HIMMEL_EVAL_RUNS_LEDGER, "utf8").trim().split("\n").map((l: string) => JSON.parse(l));
  rows[0].meta.started_ts = Date.parse("2026-10-06T23:00:00Z");
  for (const h of rows[0].meta.tool_health) h.day = "2026-10-07";
  writeFileSync(env.HIMMEL_EVAL_RUNS_LEDGER, rows.map(JSON.stringify).join("\n") + "\n");
  const data = read(env, new URLSearchParams({ since: "2026-10-07T00:00:00Z" }));
  expect(data.tools.find((r: any) => r.tool === "Bash")).toMatchObject({ calls: 50, failures: 8 });
});

test("intraday since never presents whole-day calls as an exact shift denominator", () => {
  const data = read(seed(), new URLSearchParams({ since: "2026-10-07T13:00:00Z" }));
  expect(data.tools.find((r: any) => r.tool === "Bash")).toMatchObject({ calls: null, failures: 8, rate: null });
  expect(data.hooks[0]).toMatchObject({ calls: null, rate: null });
  expect(data.daily.find((r: any) => r.tool === "Bash").calls).toBeNull();
  expect(data.daily_hooks[0].calls).toBeNull();
});

test("v2 text-only subagent failures do not poison complete tool denominators", () => {
  const env = seed();
  const textFailure = { session: "48160000-0000-4000-8000-000000000000", agent: { ...agent, id: "child" }, class: "blocked/report", failure: "blocked", count: 1, recovered: null };
  writeFileSync(env.HIMMEL_LEG_FAILURES_LEDGER, readFileSync(env.HIMMEL_LEG_FAILURES_LEDGER, "utf8") + JSON.stringify(textFailure) + "\n");
  const data = read(env);
  expect(data.tools.find((r: any) => r.tool === "Bash")).toMatchObject({ calls: 50, rate: 0.16 });
  expect(data.hooks[0]).toMatchObject({ calls: 50, rate: 0.1 });
});

test("daily hook rates include successful sessions in the same lane population", () => {
  const data = read(seed());
  expect(data.daily_hooks.find((r: any) => r.lane === "native")).toMatchObject({ day: "2026-10-07", calls: 20, failures: 2, rate: 0.1 });
});

test("missing ledgers degrade to no data", () => {
  expect(read({ HIMMEL_EVAL_RUNS_LEDGER: "/no/evals", HIMMEL_LEG_FAILURES_LEDGER: "/no/failures" })).toMatchObject({ state: "absent", tools: [] });
});

test("authenticated read-only route renders the seeded rates and session drilldown", async () => {
  const token = "a".repeat(64), env = seed();
  const s = startServer({ port: 0, token, now: () => Date.parse("2026-10-07T23:59:00Z"), env: { PATH: process.env.PATH, CONFIG_UI_HIMMELCTL: join(import.meta.dir, "stub-himmelctl.js"), ...env } });
  try {
    const url = `http://127.0.0.1:${s.port}/api/tool-health`;
    const res = await fetch(url, { headers: { "X-Himmel-Token": token } });
    expect(res.status).toBe(200);
    expect((await fetch(url)).status).toBe(401);
    expect((await fetch(url, { method: "POST", headers: { "X-Himmel-Token": token } })).status).toBe(405);
    const { renderToolHealth } = await import("../public/tool-health.js");
    const data = await res.json();
    const html = renderToolHealth(data, token);
    expect(html).toContain("16.0 %");
    expect(html).toContain("10.0 %");
    expect(html).toContain("48160000-0000-4000-8000-000000000000");
    expect(html).toContain("page=toolhealth");
    expect(renderToolHealth(null, token)).toContain("No data");
    expect(renderToolHealth({ state: "absent", selected: { days: 7 } }, token)).toContain('value="30"');
    data.tools[0].tool = '<img src=x onerror=alert(1)>';
    const escaped = renderToolHealth(data, token);
    expect(escaped).not.toContain('<img');
    expect(escaped).toContain('&lt;img');
  } finally { s.stop(); }
});

test("Tool health navigation carries tokens only in fragments", () => {
  const token = "a".repeat(64);
  const link = navLinks({ here: "agui", token, current: "fleet" }).find((r: any) => r.id === "toolhealth");
  expect(link?.href).toBe(`/#t=${token}&page=toolhealth`);
  expect(parseLanding(`#t=${token}&page=toolhealth`)?.page).toBe("toolhealth");
});
