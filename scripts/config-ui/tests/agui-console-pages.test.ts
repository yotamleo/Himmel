// HIMMEL-4808: actual fleet grouping and router functions over a two-console fixture.
import { expect, test } from "bun:test";
import * as page from "../agui-web/src/fleet-model";
import * as stream from "../agui-web/src/fleet-model";

const row = (name: string, role: string, console: string | null, extra: any = {}) => ({
  name, role, console, parent: console, live: true, lock: "unknown", lane: "native",
  state: "idle", run: `run-${name}`, pid: 1, model: null, ticket: null, pr: null,
  activity: null, lastEventAt: null, agents: [], subagents: { total: 0, running: 0 },
  failures: 0, usage: null, runtime: null, cloud: null, predecessor: null, ...extra,
});
const rows = [
  row("roadmap-console", "console", "roadmap-console"),
  row("project-console", "console", "project-console"),
  row("native-leg", "leg", "roadmap-console"),
  row("claudex-leg", "leg", "project-console", { lane: "claudex" }),
  row("judge", "judge", "project-console"),
  row("wrapped-console", "console", "wrapped-console", { state: "wrapped", live: false, lock: "released" }),
  row("wrapped-parent-leg", "leg", "wrapped-console"),
  row("dead-parent-leg", "leg", "gone-console"),
  row("no-edge-leg", "leg", null),
  row("cloud-unattended", "cloud", "roadmap-console", { run: null, cloud: { phase: "working", url: null } }),
  row("old-cloud", "cloud", "wrapped-console", { state: "wrapped", live: false, cloud: { phase: "merged", url: null } }),
  row("wrapped-leg", "leg", "roadmap-console", { state: "wrapped", live: false }),
];

test("two console groups retain native, claudex and judge children; recent consoles sort last", () => {
  const groups = (page as any).consoleGroups?.(rows);
  expect(groups?.map((g: any) => g.console.name)).toEqual(["project-console", "roadmap-console", "wrapped-console"]);
  expect(groups?.[0].rows.map((r: any) => r.name)).toEqual(["claudex-leg", "judge"]);
  expect(groups?.[1].rows.map((r: any) => r.name)).toEqual(["native-leg", "wrapped-leg"]);
});

test("orphans name released console, dead process, absent edge and missing cloud shepherd causes", () => {
  const orphan = (page as any).orphanReason;
  expect(orphan?.(rows[6], rows)).toBe("console wrapped / lock released");
  expect(orphan?.(rows[7], rows)).toBe("console process gone");
  expect(orphan?.(rows[8], rows)).toBe("no console edge");
  expect(orphan?.(rows[9], rows)).toBe("cloud session without a shepherd");
  expect(orphan?.(rows[2], rows)).toBeNull();
});

test("merged cloud under a retired console is dropped, wrapped legs remain collapsed", () => {
  const shown = (page as any).visibleRows?.(rows);
  expect(shown?.map((r: any) => r.name)).not.toContain("old-cloud");
  expect(shown?.map((r: any) => r.name)).toContain("wrapped-leg");
});

test("console deep link selects only its page; menu and fleet use identical run drill-in hashes", () => {
  const hash = (stream as any).consoleHash?.("token", "project-console");
  expect(hash).toBe("#t=token&console=project-console");
  expect((stream as any).consoleFromHash?.(hash)).toBe("project-console");
  expect(stream.fleetToken(hash ?? "")).toBe("token");
  expect((page as any).rowHref?.("token", rows[2])).toBe("#t=token&run=run-native-leg");
  expect((page as any).rowHref?.("token", rows[0])).toBe("#t=token&run=run-roadmap-console");
});
