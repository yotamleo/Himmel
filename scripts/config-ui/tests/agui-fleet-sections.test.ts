// HIMMEL-4925: the fleet page's sections (needs attention, orphans, running per live console, finished), their order,
// leg and console chains, the filters, and the short names, over plain rows: the model is dependency-free, so this runs
// without an install.
import { expect, test } from "bun:test";
import { chainKey, cloudPhase, fleetSections, laneOf, NO_FILTERS, orphanReason, shortName, siblingOrder } from "../agui-web/src/fleet-model";

const row = (name: string, role: string, console: string | null, extra: any = {}) => ({
  name, role, console, parent: console, live: true, lock: "unknown", lane: "native",
  state: "idle", run: `run-${name}`, pid: 1, model: null, ticket: null, pr: null,
  activity: null, lastEventAt: null, agents: [], subagents: { total: 0, running: 0 },
  failures: 0, usage: null, runtime: null, cloud: null, predecessor: null, ...extra,
});
const at = (t: number) => ({ activity: { tool: "Bash", summary: "x", at: t } });
const fill = (f: number) => ({ usage: { calls: 1, input: 0, output: 0, cacheRead: 0, cacheCreate: 0, costEq: 0, resident: 0, ceiling: 200000, ceilingFrom: "autocompact", fill: f } });
const cloud = (phase: string, extra: any = {}) => ({ pid: null, run: null, lane: "cloud", cloud: { phase, url: null }, ...extra });

const BU = "HIMMEL-nextleg-2026-10-08BU-roadmap-console";
const BT = "HIMMEL-nextleg-2026-10-08BT-roadmap-console";
const BS = "HIMMEL-nextleg-2026-10-08BS-roadmap-console";
const rows: any[] = [
  row(BU, "console", BU, { state: "running", predecessor: BT, ...at(50) }),
  row(BT, "console", BT, { state: "wrapped", live: false, lock: "released", predecessor: BS }),
  row(BS, "console", BS, { state: "unknown", live: false, pid: null, run: null }),
  row("idle-old", "leg", BU, { ...at(10) }),
  row("idle-new", "leg", BU, { ...at(40) }),
  row("waiting", "leg", BU, { state: "waiting for GO", ...at(5) }),
  row("running-old", "leg", BU, { state: "running", lane: "claudex", ...at(20) }),
  row("running-new", "leg", BU, { state: "running", ...at(30), ...fill(93) }),
  row("blocked", "leg", BU, { state: "idle", marker: "BLOCKED", ...at(1) }),
  row("cloud-HIMMEL-1", "cloud", BU, cloud("done", { state: "idle", pr: 11 })),
  row("cloud-HIMMEL-2", "cloud", BT, cloud("done", { state: "idle" })),
  row("cloud-HIMMEL-3", "cloud", BU, cloud("unknown", { state: "unknown" })),
  row("cloud-HIMMEL-4", "cloud", BU, cloud("working", { state: "running" })),
  row("wrapped-leg", "leg", BU, { state: "wrapped", live: false, marker: "WRAPPED", runtime: { startedAt: 0, endedAt: 100, elapsedMs: 100 } }),
  row("orphan-leg", "leg", "gone-console", { state: "running", ...at(3) }),
  row("scratch-session", "interactive", null, { state: "idle", ...at(4) }),
];

test("running: one group per live console, siblings by state rank then recency; orphans are not running rows", () => {
  const s = fleetSections(rows);
  expect(s.running.map((g) => g.console?.name ?? null)).toEqual([BU, null]);
  expect(s.running[0].rows.map((r) => r.name)).toEqual([
    "running-new", "running-old", "cloud-HIMMEL-4", "waiting", "idle-new", "idle-old", "blocked", "cloud-HIMMEL-1", "cloud-HIMMEL-3",
  ]);
  // The operator's own interactive session is not an orphan: it sits in the last group.
  expect(s.running[1].rows.map((r) => r.name)).toEqual(["scratch-session"]);
});

test("orphans: live sessions no live console watches, with their reason; a cloud session never is one", () => {
  const s = fleetSections(rows);
  expect(s.orphans.map((o) => [o.row.name, o.why])).toEqual([["orphan-leg", "console process gone"]]);
  expect(orphanReason(rows.find((r) => r.name === "cloud-HIMMEL-1"), rows)).toBeNull();
  expect(orphanReason(rows.find((r) => r.name === "scratch-session"), rows)).toBeNull();
});

test("finished: wrapped and dead consoles fold into one chain, wrapped legs, cloud rows under a finished console", () => {
  const s = fleetSections(rows);
  expect(s.finished.map((e) => [e.row.name, e.hops.map((h) => h.name)])).toEqual([
    ["wrapped-leg", []],
    ["cloud-HIMMEL-2", []],
    [BT, [BS]],
  ]);
});

test("needs attention: BLOCKED/FINDING, then context at 85 % or more, then a CLOUD-DONE PR awaiting its shepherd", () => {
  const s = fleetSections(rows);
  expect(s.attention.map((a) => [a.row.name, a.why])).toEqual([
    ["blocked", "BLOCKED"],
    ["running-new", "context 93%"],
    ["cloud-HIMMEL-1", "CLOUD-DONE · awaiting shepherd · PR 11"],
  ]);
});

test("a cloud session with a live shepherd is shepherded, not awaiting one; its shepherd sorts under it", () => {
  const withShepherd = [...rows, row("HIMMEL-1-N1-shepherd-2026-10-08", "leg", BU, { parent: "cloud-HIMMEL-1", ticket: "HIMMEL-1", state: "running", ...at(2) })];
  const s = fleetSections(withShepherd);
  expect(s.attention.map((a) => a.row.name)).not.toContain("cloud-HIMMEL-1");
  expect(cloudPhase(withShepherd.find((r) => r.name === "cloud-HIMMEL-1"), withShepherd)).toBe("shepherded");
  expect(cloudPhase(rows.find((r) => r.name === "cloud-HIMMEL-1"), rows)).toBe("CLOUD-DONE");
  expect(cloudPhase(rows.find((r) => r.name === "cloud-HIMMEL-4"), rows)).toBe("working");
  expect(s.running[0].rows.map((r) => r.name)).toContain("HIMMEL-1-N1-shepherd-2026-10-08");
});

test("counts: running and waiting are by state; orphaned counts session and process orphans", () => {
  const s = fleetSections(rows, null, NO_FILTERS, [{ pid: 7, owner: "orphan", ageMin: 45 }]);
  expect(s.counts).toEqual({ running: 4, waiting: 1, attention: 3, orphaned: 2, finished: 3, shown: 16, total: 16 });
  expect(s.processOrphans).toEqual([{ pid: 7, owner: "orphan", ageMin: 45 }]);
});

test("a console filter scopes every section, and its process orphans, to that console", () => {
  const procs = [{ pid: 7, owner: "idle-new", ageMin: 45 }, { pid: 8, owner: "orphan", ageMin: 90 }, { pid: 9, owner: "elsewhere", ageMin: 31 }];
  const s = fleetSections(rows, BT, NO_FILTERS, procs);
  expect(s.running).toEqual([]);
  expect(s.attention).toEqual([]);
  expect(s.finished.map((e) => e.row.name)).toEqual(["cloud-HIMMEL-2", BT]);
  expect(fleetSections(rows, BU, NO_FILTERS, procs).processOrphans.map((p) => p.pid)).toEqual([7, 8]);
});

test("filters: lane, state and text narrow every section; the counts say how many are shown", () => {
  const claudex = fleetSections(rows, null, { lanes: ["claudex"], states: [], text: "" });
  expect(claudex.running.flatMap((g) => g.rows.map((r) => r.name))).toEqual(["running-old"]);
  expect(claudex.counts.shown).toBe(1);
  expect(fleetSections(rows, null, { lanes: ["cloud"], states: [], text: "" }).running[0].rows.map((r) => r.name))
    .toEqual(["cloud-HIMMEL-4", "cloud-HIMMEL-1", "cloud-HIMMEL-3"]);
  const attention = fleetSections(rows, null, { lanes: [], states: ["attention"], text: "" });
  expect(attention.running.flatMap((g) => g.rows.map((r) => r.name)).sort()).toEqual(["blocked", "cloud-HIMMEL-1", "running-new"]);
  expect(attention.finished).toEqual([]);
  const orphaned = fleetSections(rows, null, { lanes: [], states: ["orphaned"], text: "" });
  expect(orphaned.orphans.map((o) => o.row.name)).toEqual(["orphan-leg"]);
  expect(orphaned.running).toEqual([]);
  expect(fleetSections(rows, null, { lanes: [], states: [], text: "IDLE-N" }).running.flatMap((g) => g.rows.map((r) => r.name))).toEqual(["idle-new"]);
  expect(laneOf(rows.find((r) => r.name === "cloud-HIMMEL-4"))).toBe("cloud");
});

test("leg chains: the live hop carries its finished hops, which leave the Finished list", () => {
  const chain = [
    row(BU, "console", BU, { state: "running" }),
    row("HIMMEL-4904-N1494-api-lane-core-2026-10-08", "leg", BU, { state: "wrapped", live: false, runtime: { startedAt: 0, endedAt: 10, elapsedMs: 10 } }),
    row("HIMMEL-4904-N1494b-api-lane-core-2026-10-08", "leg", BU, { state: "wrapped", live: false, runtime: { startedAt: 11, endedAt: 20, elapsedMs: 9 } }),
    row("HIMMEL-4904-N1494b-api-lane-core-2026-10-08-RESUME", "leg", BU, { state: "running" }),
    row("HIMMEL-4910-N1495-dotenv-allowlist-2026-10-08", "leg", BU, { state: "wrapped", live: false, runtime: { startedAt: 0, endedAt: 30, elapsedMs: 30 } }),
    row("HIMMEL-4910-N1495b-dotenv-allowlist-2026-10-08", "leg", BU, { state: "wrapped", live: false, runtime: { startedAt: 31, endedAt: 40, elapsedMs: 9 } }),
  ];
  const s = fleetSections(chain);
  const live = "HIMMEL-4904-N1494b-api-lane-core-2026-10-08-RESUME";
  expect(s.hops[live].map((r) => r.name)).toEqual(["HIMMEL-4904-N1494-api-lane-core-2026-10-08", "HIMMEL-4904-N1494b-api-lane-core-2026-10-08"]);
  expect(s.finished.map((e) => [e.row.name, e.hops.map((h) => h.name)])).toEqual([
    ["HIMMEL-4910-N1495b-dotenv-allowlist-2026-10-08", ["HIMMEL-4910-N1495-dotenv-allowlist-2026-10-08"]],
  ]);
  expect(chainKey(live)).toBe("HIMMEL-4904-N1494");
  expect(chainKey("scratch-session")).toBeNull();
});

test("filters apply to every section alike: a hidden live hop leaves its finished hops in Finished; process orphans follow lane and text", () => {
  const chain = [
    row(BU, "console", BU, { state: "running" }),
    row("HIMMEL-4904-N1494-api-lane-core-2026-10-08", "leg", BU, { state: "wrapped", live: false }),
    row("HIMMEL-4904-N1494b-api-lane-core-2026-10-08-RESUME", "leg", BU, { state: "running", lane: "claudex" }),
  ];
  const s = fleetSections(chain, null, { lanes: [], states: [], text: "N1494-api" });
  expect(s.running).toEqual([]);
  expect(s.finished.map((e) => e.row.name)).toEqual(["HIMMEL-4904-N1494-api-lane-core-2026-10-08"]);

  const procs = [{ pid: 7, owner: "running-old", ageMin: 45 }, { pid: 8, owner: "orphan", ageMin: 90 }, { pid: 9, owner: "idle-new", ageMin: 31 }];
  expect(fleetSections(rows, null, { lanes: ["claudex"], states: [], text: "" }, procs).processOrphans.map((p) => p.pid)).toEqual([7]);
  expect(fleetSections(rows, null, { lanes: [], states: [], text: "idle-n" }, procs).processOrphans.map((p) => p.pid)).toEqual([9]);
  expect(fleetSections(rows, null, { lanes: [], states: [], text: "8" }, procs).processOrphans.map((p) => p.pid)).toEqual([8]);
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
