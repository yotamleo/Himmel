// HIMMEL-4943: the Roadmap page. GET /api/roadmap reads the Jira mirror, the plan dir and the legs live (no static
// render, no republish); the page draws the kanban by version and theme, the release panels and the drift trend, the
// leg -> Jira sync plan the console kit writes, and the librarian's ready-to-approve lists. Read-only throughout.
import { test, expect, afterEach } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { legSync, readRoadmap, SYNC_LABEL } from "../roadmap";
import { renderRoadmap } from "../public/roadmap.js";
import { navLinks, parseLanding } from "../public/nav.js";
import { startServer } from "../server";

const TOKEN = "a".repeat(64); // hex: parseLanding only accepts a hex token
const cleanups: (() => void)[] = [];
afterEach(() => { while (cleanups.length) cleanups.pop()!(); });

const issue = (n: number, status: string, cat: string, fv: string[], title: string, labels: string[] = [], body = "") =>
  ["---", `key: "HIMMEL-${n}"`, `type: "Story"`, `status: ${JSON.stringify(status)}`, `statusCategory: ${JSON.stringify(cat)}`,
    `priority: "Medium"`, `labels: ${JSON.stringify(labels)}`, `fixVersions: ${JSON.stringify(fv)}`, `parent: null`,
    `created: "2026-10-01T00:00:00.000+0000"`, `updated: "2026-10-0${Math.min(n, 9)}T10:00:00.000+0000"`, `resolution: null`,
    "links:", "  blocks: []", "  blocked_by: []", "  relates: []", "---", "", `# HIMMEL-${n}: ${title}`, "", "## Description", "", "x", "",
    "## Comments", "", body || "_(none)_", ""].join("\n");

// A scratch station: mirror + versions snapshot, a plan dir, a drift log and two leg docs.
function station() {
  const d = mkdtempSync(join(tmpdir(), "roadmap-"));
  cleanups.push(() => rmSync(d, { recursive: true, force: true }));
  const mirror = join(d, "jira-mirror", "HIMMEL");
  mkdirSync(mirror, { recursive: true });
  const put = (n: number, s: string) => writeFileSync(join(mirror, `HIMMEL-${n}.md`), s);
  put(1, issue(1, "In Progress", "In Progress", ["v1.1.2"], "Roadmap in the ui"));
  put(2, issue(2, "In Progress", "In Progress", ["v1.1.2"], "Orphaned work"));
  put(3, issue(3, "Done", "Done", ["v1.1.1"], "Shipped thing"));
  put(4, issue(4, "To Do", "To Do", ["v1.1.1"], "Left behind"));
  put(5, issue(5, "To Do", "To Do", ["v1.1.2"], "Resumed work", ["product", SYNC_LABEL]));
  put(6, issue(6, "To Do", "To Do", ["v1.1.3"], "Roadmap in the UI!"));
  put(7, issue(7, "In Review", "In Progress", ["v1.1.2"], "Ready work", [], "### bot — 2026-10-08\n\n[leg-sync] N3 READY: PR #9\n"));
  writeFileSync(join(d, "jira-mirror", "HIMMEL.versions.tsv"), "v1.1.1\ttrue\t2026-10-01\nv1.1.2\tfalse\t\nv1.1.3\tfalse\t\n");
  const plan = join(d, "plan");
  mkdirSync(join(plan, "stage3"), { recursive: true }); mkdirSync(join(plan, "stage1"), { recursive: true });
  writeFileSync(join(plan, "stage3", "placement.tsv"), "key\tversion\tlayer\nHIMMEL-1\tv1.1.2\tfeatures\nHIMMEL-6\tv1.1.2\tfeatures\nHIMMEL-7\tv1.1.2\tbugs\n");
  writeFileSync(join(plan, "stage1", "C01.tsv"), "key\ttheme\timpact\nHIMMEL-1\ttracker\t3\nHIMMEL-6\ttracker\t2\nHIMMEL-7\tfleet\t1\n");
  const drift = join(d, "roadmap-drift.tsv");
  writeFileSync(drift, "utc\tdrift\tunplanned\tunthemed\n2026-10-07T00:00:00Z\t4\t3\t2\n2026-10-08T00:00:00Z\t1\t2\t2\n");
  const legsDir = join(d, "handovers");
  mkdirSync(legsDir);
  const blocked = join(legsDir, "HIMMEL-1-N1466b-roadmap-RESUME.md");
  writeFileSync(blocked, "# leg\n\n## Results\n- 03:00 LIVE — started\n- 04:32 BLOCKED — classifier permission hold\n");
  const live = join(legsDir, "HIMMEL-5-N2-resumed-RESUME.md");
  writeFileSync(live, "## Results\n- 03:00 BLOCKED — waiting\n- 05:00 RESUMED — going again\n");
  const ready = join(legsDir, "HIMMEL-7-N3-ready-RESUME.md");
  writeFileSync(ready, "## Results\n- 06:00 READY: PR #9\n");
  const legs = { state: "ok" as const, manifest: join(legsDir, "x.fleet.json"), legs: [
    { doc: blocked, status: "BLOCKED" }, { doc: live, status: "RESUMED" }, { doc: ready, status: "READY" }] };
  return { d, mirror, plan, drift, legs };
}
const read = (s: ReturnType<typeof station>, o: Record<string, unknown> = {}) =>
  readRoadmap({ mirrorDir: s.mirror, planDir: s.plan, driftLog: s.drift, legs: s.legs, ...o });
const byKey = (r: ReturnType<typeof readRoadmap>) => Object.fromEntries(r.tickets.map((t) => [t.k, t]));

test("the kanban: every train ticket sits in its Jira version and its status column, themed from the plan", () => {
  const r = read(station());
  expect(r.state).toBe("ok");
  expect(r.versions.map((v) => v.n)).toEqual(["v1.1.1", "v1.1.2", "v1.1.3"]);
  expect(r.releaseUnknown).toBe(false);
  const t = byKey(r);
  expect(r.versions[t[1].v].n).toBe("v1.1.2");
  expect(t[1].b).toBe("prog");
  expect(t[7].b).toBe("rev");
  expect(t[3].b).toBe("done");
  expect(r.themes[t[1].theme]).toBe("tracker");
  expect(r.themes[t[2].theme]).toBe("(no theme)");
  // the running version is the earliest unreleased one with open work; the release panel counts its columns
  expect(r.versions[r.cur].n).toBe("v1.1.2");
  expect(r.versions[1].counts).toEqual({ todo: 1, prog: 2, rev: 1, ci: 0, done: 0, wont: 0 });
});

test("release panels: a released version lists its still-open tickets", () => {
  const r = read(station());
  expect(r.versions[0].rel).toBe(true);
  expect(r.versions[0].date).toBe("2026-10-01");
  expect(r.versions[0].open).toEqual([4]);
});

test("drift: live counts from mirror vs plan, and the trend from the tracker's drift log (read, never written)", () => {
  const s = station();
  const r = read(s);
  const t = byKey(r);
  expect(t[6].drift).toBe(1); // planned v1.1.2, Jira says v1.1.3
  expect(t[2].drift).toBe(2); // in a train version, not in the plan
  expect(t[1].drift).toBe(0);
  expect(r.drift.now).toEqual({ drift: 1, unplanned: 3, unthemed: 3 });
  expect(r.drift.trend.map((x) => x[1])).toEqual([4, 1]);
});

test("no plan dir: the kanban still renders from Jira, and the plan says why it is missing", () => {
  const r = read(station(), { planDir: undefined });
  expect(r.state).toBe("ok");
  expect(r.plan.state).toBe("absent");
  expect(r.tickets.every((t) => t.drift === 0)).toBe(true);
});

test("no mirror: absent, with the command that makes one", () => {
  const r = readRoadmap({ mirrorDir: "/nonexistent/mirror", legs: { state: "absent" } });
  expect(r.state).toBe("absent");
  expect(r.reason).toContain("mirror");
});

test("legs join their tickets with the marker and the reason line", () => {
  const t = byKey(read(station()));
  expect(t[1].leg).toEqual({ label: "N1466b", marker: "BLOCKED", reason: "classifier permission hold" });
  expect(t[2].leg).toBeNull();
});

test("leg -> Jira sync: flag a stuck leg with the reason, clear the flag on resume, note READY once", () => {
  const ops = legSync(read(station()).tickets);
  const of = (k: number) => ops.filter((o) => o.k === k);
  expect(of(1).map((o) => o.argv)).toEqual([
    ["edit", "HIMMEL-1", "--add-labels", SYNC_LABEL],
    ["comment", "HIMMEL-1", "[leg-sync] N1466b BLOCKED: classifier permission hold"],
  ]);
  // resume: the flag goes, every other label stays (--labels is a full replace)
  expect(of(5).map((o) => o.argv)).toEqual([["edit", "HIMMEL-5", "--labels", "product"]]);
  // READY was already noted on the ticket: nothing to write
  expect(of(7)).toEqual([]);
  // the planner never moves a status
  expect(ops.some((o) => o.argv.includes("transition"))).toBe(false);
});

test("librarian: stale In Progress, drift, unthemed, released-but-open and duplicate titles, as proposals", () => {
  const l = read(station()).librarian;
  expect(l.staleInProgress.map((p) => p.k)).toEqual([2]);
  expect(l.drift.map((p) => p.k)).toEqual([6]);
  expect(l.drift[0].proposal).toContain("v1.1.2");
  expect(l.unthemed.map((p) => p.k)).toEqual([2, 4, 5]);
  expect(l.releasedOpen.map((p) => p.k)).toEqual([4]);
  expect(l.releasedOpen[0].proposal).toContain("v1.1.2");
  expect(l.duplicates.map((p) => p.keys)).toEqual([[1, 6]]);
  for (const list of Object.values(l)) for (const p of list) expect(p.needsApproval).toBe(true);
});

test("the page renders every section and escapes ticket text", () => {
  const r = read(station());
  r.tickets[0].t = "<script>x</script>";
  const html = renderRoadmap(r, { version: null, theme: null });
  for (const id of ["rm-releases", "rm-kanban", "rm-drift", "rm-sync", "rm-librarian"]) expect(html).toContain(`id="${id}"`);
  expect(html).not.toContain("<script>x");
  expect(html).toContain("classifier permission hold");
  // a theme filter narrows the board
  const tracker = renderRoadmap(r, { version: null, theme: r.themes.indexOf("tracker") });
  expect(tracker).not.toContain("Orphaned work");
  expect(renderRoadmap(null, {})).toContain("loading");
  expect(renderRoadmap({ state: "absent", reason: "no Jira mirror" }, {})).toContain("no Jira mirror");
});

test("the rail lists Roadmap next to Fleet, and it is a console route", () => {
  const labels = navLinks({ here: "console", token: TOKEN, current: "roadmap" }).map((l) => l.label);
  expect(labels.slice(labels.indexOf("Fleet"))).toEqual(["Fleet", "Roadmap"]);
  expect(parseLanding(`#t=${TOKEN}&page=roadmap`)).toEqual({ token: TOKEN, page: "roadmap" });
});

test("GET /api/roadmap: token-gated, GET-only, served live from the mirror the env names", async () => {
  const s = station();
  const home = join(s.d, "home"); mkdirSync(home);
  const srv = startServer({
    port: 0, token: TOKEN, legsScript: join(s.d, "no-legs.sh"),
    env: { PATH: process.env.PATH, HOME: home, CONFIG_UI_HIMMELCTL: join(import.meta.dir, "stub-himmelctl.js"), CONFIG_UI_IDLE_MS: "60000",
      HIMMEL_JIRA_MIRROR: s.mirror, HIMMEL_ROADMAP_PLAN_DIR: s.plan, HIMMEL_ROADMAP_DRIFT_LOG: s.drift },
  });
  cleanups.push(() => srv.stop());
  const url = `http://127.0.0.1:${srv.port}/api/roadmap`;
  expect((await fetch(url)).status).toBe(401);
  expect((await fetch(url, { method: "POST", headers: { "X-Himmel-Token": TOKEN } })).status).toBe(405);
  const r1 = await (await fetch(url, { headers: { "X-Himmel-Token": TOKEN } })).json();
  expect(r1.state).toBe("ok");
  expect(r1.tickets.length).toBe(7);
  // live: a mirror refresh shows on the next read, with no render step
  writeFileSync(join(s.mirror, "HIMMEL-8.md"), issue(8, "To Do", "To Do", ["v1.1.3"], "New ticket"));
  const r2 = await (await fetch(url, { headers: { "X-Himmel-Token": TOKEN } })).json();
  expect(r2.tickets.length).toBe(8);
  expect((await fetch(`http://127.0.0.1:${srv.port}/roadmap.js`)).status).toBe(200);
});
