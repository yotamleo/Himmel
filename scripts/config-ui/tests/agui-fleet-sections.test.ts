// HIMMEL-4925: the fleet page's three sections (needs attention, running per live console, finished), their order,
// and the short names, over plain rows: the model is dependency-free, so this runs without an install.
import { expect, test } from "bun:test";
import { fleetSections, shortName, siblingOrder } from "../agui-web/src/fleet-model";

const row = (name: string, role: string, console: string | null, extra: any = {}) => ({
  name, role, console, parent: console, live: true, lock: "unknown", lane: "native",
  state: "idle", run: `run-${name}`, pid: 1, model: null, ticket: null, pr: null,
  activity: null, lastEventAt: null, agents: [], subagents: { total: 0, running: 0 },
  failures: 0, usage: null, runtime: null, cloud: null, predecessor: null, ...extra,
});
const at = (t: number) => ({ activity: { tool: "Bash", summary: "x", at: t } });
const fill = (f: number) => ({ usage: { calls: 1, input: 0, output: 0, cacheRead: 0, cacheCreate: 0, costEq: 0, resident: 0, ceiling: 200000, ceilingFrom: "autocompact", fill: f } });

const BU = "HIMMEL-nextleg-2026-10-08BU-roadmap-console";
const BT = "HIMMEL-nextleg-2026-10-08BT-roadmap-console";
const BS = "HIMMEL-nextleg-2026-10-08BS-roadmap-console";
const rows: any[] = [
  row(BU, "console", BU, { state: "running", ...at(50) }),
  row(BT, "console", BT, { state: "wrapped", live: false, lock: "released" }),
  row(BS, "console", BS, { state: "unknown", live: false, pid: null, run: null }),
  row("idle-old", "leg", BU, { ...at(10) }),
  row("idle-new", "leg", BU, { ...at(40) }),
  row("waiting", "leg", BU, { state: "waiting for GO", ...at(5) }),
  row("running-old", "leg", BU, { state: "running", ...at(20) }),
  row("running-new", "leg", BU, { state: "running", ...at(30), ...fill(93) }),
  row("blocked", "leg", BU, { state: "idle", marker: "BLOCKED", ...at(1) }),
  row("cloud-HIMMEL-1", "cloud", BU, { pid: null, run: null, cloud: { phase: "done", url: null } }),
  row("cloud-HIMMEL-2", "cloud", BT, { pid: null, run: null, cloud: { phase: "done", url: null } }),
  row("cloud-HIMMEL-3", "cloud", BU, { pid: null, run: null, state: "unknown", cloud: { phase: "unknown", url: null } }),
  row("wrapped-leg", "leg", BU, { state: "wrapped", live: false, runtime: { startedAt: 0, endedAt: 100, elapsedMs: 100 } }),
  row("orphan-leg", "leg", "gone-console", { state: "running", ...at(3) }),
];

test("running: one group per live console, siblings by state rank then recency, the rest in a last group", () => {
  const s = fleetSections(rows);
  expect(s.running.map((g) => g.console?.name ?? null)).toEqual([BU, null]);
  expect(s.running[0].rows.map((r) => r.name)).toEqual([
    "running-new", "running-old", "waiting", "idle-new", "idle-old", "blocked", "cloud-HIMMEL-1", "cloud-HIMMEL-3",
  ]);
  expect(s.running[1].rows.map((r) => r.name)).toEqual(["orphan-leg"]);
});

test("finished: wrapped and dead consoles, wrapped legs, cloud rows under a finished console; timed first, then name descending", () => {
  const s = fleetSections(rows);
  expect(s.finished.map((r) => r.name)).toEqual(["wrapped-leg", "cloud-HIMMEL-2", BT, BS]);
});

test("needs attention: BLOCKED/FINDING, then context at 85 % or more, then orphans; stale ones (finished console) flagged", () => {
  const s = fleetSections(rows);
  expect(s.attention.map((a) => [a.row.name, a.why, a.stale])).toEqual([
    ["blocked", "BLOCKED", false],
    ["running-new", "context 93%", false],
    ["orphan-leg", "console process gone", false],
    ["cloud-HIMMEL-1", "cloud session without a shepherd", false],
    ["cloud-HIMMEL-2", "cloud session without a shepherd", true],
  ]);
});

test("a cloud session with a live shepherd is not an orphan, and the shepherd sorts under it", () => {
  const withShepherd = [...rows, row("HIMMEL-1-N1-shepherd-2026-10-08", "leg", BU, { parent: "cloud-HIMMEL-1", ticket: "HIMMEL-1", state: "running", ...at(2) })];
  const s = fleetSections(withShepherd);
  expect(s.attention.map((a) => a.row.name)).not.toContain("cloud-HIMMEL-1");
  expect(s.running[0].rows.map((r) => r.name)).toContain("HIMMEL-1-N1-shepherd-2026-10-08");
});

test("counts: running and waiting are by state (the console included), so a cloud row whose GitHub read failed is neither", () => {
  const s = fleetSections(rows);
  expect(s.counts).toEqual({ running: 4, waiting: 1, attention: 5, finished: 4 });
});

test("a console filter scopes all three sections to that console", () => {
  const s = fleetSections(rows, BT);
  expect(s.running).toEqual([]);
  expect(s.attention.map((a) => a.row.name)).toEqual(["cloud-HIMMEL-2"]);
  expect(s.finished.map((r) => r.name)).toEqual(["cloud-HIMMEL-2", BT]);
});

test("sibling order: running, waiting, idle, unknown; newest first; then name", () => {
  const order = [row("u", "leg", BU, { state: "unknown" }), row("b", "leg", BU), row("a", "leg", BU), row("w", "leg", BU, { state: "waiting for GO" })];
  expect(order.sort(siblingOrder as any).map((r) => r.name)).toEqual(["w", "a", "b", "u"]);
});

test("short names drop the ticket and date: a leg keeps its id and slug, a console its sequence", () => {
  expect(shortName("HIMMEL-4912-N1497-sandbox-runner-2026-10-08")).toBe("N1497 sandbox-runner");
  expect(shortName("HIMMEL-4904-N1494b-api-lane-core-2026-10-08-RESUME")).toBe("N1494b api-lane-core (resume)");
  expect(shortName("HIMMEL-4643-N1466b-backend-tier-live-connector-RESUME")).toBe("N1466b backend-tier-live-connector (resume)");
  expect(shortName(BU)).toBe("BU-roadmap-console");
  expect(shortName("cloud-HIMMEL-4728")).toBe("cloud-HIMMEL-4728");
  expect(shortName("scratch-session")).toBe("scratch-session");
});
