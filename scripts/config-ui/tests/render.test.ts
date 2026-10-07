import { test, expect } from "bun:test";
// @ts-ignore plain browser ES module, no types
import { render, renderNav, renderHeader, renderProbe, rollup, isOpen } from "../public/render.js";

const row = (id: string, health: string, source = "item", control: Record<string, unknown> = { class: "display-only" }, extra: Record<string, unknown> = {}) => ({
  id, source, group: "core", title: id, health,
  declared: { where: "w", desired: "required", profile: "all" },
  installed: { state: health === "off" ? "absent" : "present", detail: `detail-${id}` },
  fires: { state: "unverified", evidence: null, at: null },
  fix: { remedy: `remedy-${id}`, owner: "user" }, probedAt: "2026-10-04T14:02:00Z", control, sensitive: false, ...extra,
});
const feed = {
  schema: "himmel-config-feed/1", generatedAt: "2026-10-04T14:02:00Z", target: { scope: "user", path: "/x" },
  rows: [
    row("r-fail", "fail"), row("r-warn", "warn", "doctor"), row("r-ok", "ok"), row("r-off", "off"),
    row("cadence-x", "off", "cadence", { class: "toggle", action: "cadence.arm", target: "x", consent: "typed" }),
    row("flag:F_OK", "info", "flag", { class: "display-only", reason: "launch-shell variable" }),
    row("secret:S", "ok", "secret", { class: "display-only", reason: "secrets are presence-only" }),
  ],
  summary: { total: 7, ok: 2, warn: 1, fail: 1, off: 2, info: 1 },
};
// The fixture has no `bundles`, so rows fall into one "All rows" bundle per region; its Controls bundle (one off
// toggle) is collapsed by default, so these cases open it the way an operator's click does.
const openControls = { "controls|all": { open: true, rank: 4 } };
const html: string = render(feed, { open: new Set(), bundles: openControls, filt: { health: null, kind: null, q: "" } });
const region = (id: string) => html.slice(html.indexOf(`id="${id}"`), html.indexOf("</section>", html.indexOf(`id="${id}"`)));

test("three regions in order: Triage, Controls, Inventory", () => {
  const at = ["triage", "controls", "inventory"].map((id) => html.indexOf(`<section id="${id}"`));
  expect(at.every((n) => n >= 0)).toBe(true);
  expect([...at].sort((a, b) => a - b)).toEqual(at);
});

test("Triage is the landing region (first in the page, current in the nav)", () => {
  expect(html.indexOf('id="triage"')).toBeLessThan(html.indexOf('id="controls"'));
  expect(renderNav(feed, "triage")).toMatch(/aria-current="true"[^>]*>\s*<span>Triage/);
});

test("Triage lists fail then warn rows and omits off, ok and info rows", () => {
  const t = region("triage");
  expect(t).toContain("r-fail");
  expect(t).toContain("r-warn");
  expect(t.indexOf("r-fail")).toBeLessThan(t.indexOf("r-warn"));
  for (const id of ["r-off", "r-ok", "cadence-x", "F_OK"]) expect(t).not.toContain(id);
});

test("right slot: a toggle in Controls is an enabled switch that opens a plan", () => {
  const c = region("controls");
  expect(c).toContain("cadence-x");
  expect(c).toMatch(/<button[^>]*role="switch"[^>]*data-act="plan"/);
  expect(c).not.toMatch(/<button[^>]*role="switch"[^>]*disabled/);
  expect(c).not.toContain("available in P4");
});

// T4.7: preview → typed consent → run → before/after.
const K = "controls|cadence-x";
const withPlan = (plan: Record<string, unknown>) => {
  const out: string = render(feed, { open: new Set([K]), bundles: openControls, filt: { health: null, kind: null, q: "" }, plans: { [K]: plan } });
  return out.slice(out.indexOf('<div class="plan"'), out.indexOf("</section>", out.indexOf('<div class="plan"')));
};
const planned = { stage: "plan", previewId: "p", command: "bash /c/x-cadence.sh arm --dry-run", output: "would arm x", consent: { kind: "typed", expect: "x" }, bank: "draws the bank", effect: "at the next scheduled fire" };
const confirm = (h: string) => /<button[^>]*data-act="run"[^>]*>/.exec(h)![0];

test("plan: the dry-run command and output are shown, with the bank cost", () => {
  const h = withPlan({ ...planned, typed: "" });
  expect(h).toContain("bash /c/x-cadence.sh arm --dry-run");
  expect(h).toContain("would arm x");
  expect(h).toContain("draws the bank");
});

test("plan: an empty or wrong typed consent leaves confirm disabled", () => {
  expect(confirm(withPlan({ ...planned, typed: "" }))).toContain("disabled");
  expect(confirm(withPlan({ ...planned, typed: "y" }))).toContain("disabled");
});

test("plan: the matching typed consent enables confirm", () => {
  expect(confirm(withPlan({ ...planned, typed: "x" }))).not.toContain("disabled");
});

test("plan: plain consent needs no typing", () => {
  const h = withPlan({ ...planned, consent: { kind: "plain", expect: null }, typed: "" });
  expect(h).not.toContain("<input");
  expect(confirm(h)).not.toContain("disabled");
});

test("done: renders the before → after text from the re-probe", () => {
  const h = withPlan({ stage: "done", command: "bash /c/x-cadence.sh arm", rc: 0, reprobe: "ok",
    before: { "cadence-x": { installed: "absent", health: "off" } }, after: { "cadence-x": { installed: "present", health: "ok" } } });
  expect(h).toContain("rc=0");
  expect(h).toContain("absent → present");
  expect(h).toContain("off → ok");
});

test("done: a timed-out re-probe says so", () => {
  const h = withPlan({ stage: "done", command: "c", rc: 0, reprobe: "re-probe timed out", before: null, after: null });
  expect(h).toContain("re-probe timed out");
});

test("done: a failed audit append is shown, never `logged`", () => {
  const h = withPlan({ stage: "done", command: "c", rc: 0, reprobe: "ok", audit: "failed", before: {}, after: {} });
  expect(h).toContain("audit log append FAILED");
  expect(h).not.toContain("logged to actions.jsonl");
});

test("plan text from the server is escaped", () => {
  expect(withPlan({ ...planned, output: "<img src=x onerror=1>", typed: "" })).not.toContain("<img");
});

test("right slot: fix rows say copy · runs in your terminal", () => {
  expect(region("triage")).toContain("copy · runs in your terminal");
});

test("right slot: read-only rows say why, in words", () => {
  const i = region("inventory");
  expect(i).toContain("read-only · set in launching shell");
  expect(i).toContain("read-only · presence probe");
});

test("a toggle outside Controls links back instead of switching", () => {
  expect(region("inventory")).toContain("control ↗");
});

test("rows are escaped (no markup from the feed reaches the page)", () => {
  const bad = { ...feed, rows: [row("<img src=x onerror=1>", "fail")] };
  const out: string = render(bad, { open: new Set(), filt: { health: null, kind: null, q: "" } });
  expect(out).not.toContain("<img");
});

test("nav counts: Triage 2 · Controls 1 · Inventory 7", () => {
  const n = renderNav(feed, "triage");
  expect(n).toContain("Triage 2");
  expect(n).toContain("Controls 1");
  expect(n).toContain("Inventory 7");
});

// HIMMEL-4379: bundles. A feed with `bundles` + per-row `bundle`; the fixture above has neither.
const B = (id: string, health: string, bundle: string, source = "item", control: Record<string, unknown> = { class: "display-only" }) =>
  row(id, health, source, control, { bundle });
const bfeed = {
  ...feed,
  bundles: [{ id: "alpha", title: "Alpha" }, { id: "beta", title: "Beta" }, { id: "gamma", title: "Gamma" }, { id: "delta", title: "Delta" }],
  rows: [
    B("a-fail", "fail", "alpha"), B("a-warn", "warn", "alpha", "doctor"), B("a-ok", "ok", "alpha"),
    B("b-ok1", "ok", "beta"), B("b-ok2", "ok", "beta", "secret"), B("b-off", "off", "beta"),
    B("g-off1", "off", "gamma", "flag"), B("g-off2", "off", "gamma", "flag"),
    B("d-tog", "ok", "delta", "cadence", { class: "toggle", action: "cadence.arm", target: "d", consent: "typed" }),
    B("d-fail", "fail", "delta"),
    B("orphan", "ok", "not-in-the-table"),
  ],
};
const bst = (o: Record<string, unknown> = {}, filt: Record<string, unknown> = {}) =>
  ({ open: new Set(), bundles: {}, plans: {}, ...o, filt: { health: null, kind: null, q: "", problems: false, ...filt } });
const bhtml = (o?: Record<string, unknown>, filt?: Record<string, unknown>, f: any = bfeed): string => render(f, bst(o, filt));
const inv = (h: string) => h.slice(h.indexOf('id="inventory"'), h.indexOf("</section>", h.indexOf('id="inventory"')));
const ctl = (h: string) => h.slice(h.indexOf('id="controls"'), h.indexOf("</section>", h.indexOf('id="controls"')));
// one bundle's header plus its rows, up to the next header
const bun = (region: string, id: string, h: string) => {
  const hit = h.indexOf(`data-b="${region}|${id}"`);
  if (hit < 0) return "";
  const at = h.lastIndexOf("<div", hit);
  const next = h.indexOf('data-act="bundle"', hit + 10);
  return h.slice(at, next < 0 ? h.indexOf("</section>", at) : next);
};
const rr = (...hs: string[]) => hs.map((h, i) => row(`r${i}`, h));

test("rollup: counts every health separately and the headline is the worst", () => {
  const r = rollup(rr("fail", "warn", "ok", "ok", "off", "info"));
  expect([r.fail, r.warn, r.ok, r.off, r.info, r.total]).toEqual([1, 1, 2, 1, 1, 6]);
  expect(r.headline).toBe("fail");
});

test("rollup: headline ranks fail > warn > ok > off > info (ok outranks off)", () => {
  const sets = [["fail", "ok"], ["warn", "ok", "off"], ["ok", "off", "info"], ["off", "info"], ["info"]];
  const out = sets.map((s) => rollup(rr(...s)));
  expect(out.map((o: any) => o.headline)).toEqual(["fail", "warn", "ok", "off", "info"]);
  const ranks = out.map((o: any) => o.rank);
  expect([...ranks].sort((a: number, b: number) => b - a)).toEqual(ranks);
  expect(new Set(ranks).size).toBe(5);
  expect(rollup([]).headline).toBe("info");
});

test("isOpen: default from the base set (fail or warn opens), an override wins", () => {
  const bad = rr("warn", "ok"), good = rr("ok", "off");
  expect(isOpen("inventory", "x", bad, bst(), "")).toBe(true);
  expect(isOpen("inventory", "x", good, bst(), "")).toBe(false);
  const rank = rollup(bad).rank;
  expect(isOpen("inventory", "x", bad, bst({ bundles: { "inventory|x": { open: false, rank } } }), "")).toBe(false);
  expect(isOpen("inventory", "x", good, bst({ bundles: { "inventory|x": { open: true, rank: rollup(good).rank } } }), "")).toBe(true);
  // an override is per region
  expect(isOpen("controls", "x", bad, bst({ bundles: { "inventory|x": { open: false, rank } } }), "")).toBe(true);
});

test("isOpen: an override goes stale when the rank worsens, and holds when it improves", () => {
  const okRank = rollup(rr("ok")).rank;
  const collapsedWhileOk = { bundles: { "inventory|x": { open: false, rank: okRank } } };
  expect(isOpen("inventory", "x", rr("ok", "fail"), bst(collapsedWhileOk), "")).toBe(true);
  const failRank = rollup(rr("fail")).rank;
  const s: any = bst({ bundles: { "inventory|x": { open: true, rank: failRank } } });
  expect(isOpen("inventory", "x", rr("ok"), s, "")).toBe(true);
  expect(s.bundles["inventory|x"]).toBeDefined();
  // stale = deleted, so it cannot come back when the rank improves again
  const t: any = bst(collapsedWhileOk);
  isOpen("inventory", "x", rr("fail"), t, "");
  expect(t.bundles["inventory|x"]).toBeUndefined();
  expect(isOpen("inventory", "x", rr("ok"), t, "")).toBe(false);
});

test("isOpen: a non-empty query forces open, clearing it returns the override, a click during search survives", () => {
  const good = rr("ok");
  const rank = rollup(good).rank;
  const closed = bst({ bundles: { "inventory|x": { open: false, rank } } });
  expect(isOpen("inventory", "x", good, closed, "abc")).toBe(true);
  expect(isOpen("inventory", "x", good, closed, "")).toBe(false);
  const clicked = bst({ bundles: { "inventory|x": { open: true, rank } } });
  expect(isOpen("inventory", "x", good, clicked, "abc")).toBe(true);
  expect(isOpen("inventory", "x", good, clicked, "")).toBe(true);
});

test("isOpen: Unsorted is always open", () => {
  const s = bst({ bundles: { "inventory|unsorted": { open: false, rank: 99 } } });
  expect(isOpen("inventory", "unsorted", rr("ok"), s, "")).toBe(true);
});

test("bundles: a fail/warn bundle renders open with its rows; an all-ok bundle collapsed with no row markup", () => {
  const h = inv(bhtml());
  expect(h.match(/data-act="bundle"/g)!.length).toBeGreaterThanOrEqual(4);
  const a = bun("inventory", "alpha", h), b = bun("inventory", "beta", h);
  expect(a).toContain('aria-expanded="true"');
  expect(a).toContain("a-fail");
  expect(b).toContain('aria-expanded="false"');
  expect(b).not.toContain("b-ok1");
  expect(b).not.toContain('class="row"');
  expect(h).toMatch(/<div[^>]*role="button"[^>]*tabindex="0"[^>]*data-act="bundle"[^>]*data-b="inventory\|alpha"/);
});

test("bundles: header carries title, whole-bundle counts of only the non-zero healths, and the row count", () => {
  const h = inv(bhtml());
  const a = bun("inventory", "alpha", h).slice(0, 400);
  expect(a).toContain("Alpha");
  expect(a).toContain("1 fail · 1 warn · 1 ok");
  expect(a).not.toContain("off");
  const g = bun("inventory", "gamma", h).slice(0, 400);
  expect(g).toContain("2 off");
  expect(g).not.toMatch(/0 (fail|warn|ok)/);
});

test("bundles: header order follows feed.bundles, Unsorted is last, always open, and titled Unsorted", () => {
  const h = inv(bhtml({ bundles: { "inventory|unsorted": { open: false, rank: 0 } } }));
  const at = ["alpha", "beta", "gamma", "delta", "unsorted"].map((id) => h.indexOf(`data-b="inventory|${id}"`));
  expect(at.every((n) => n >= 0)).toBe(true);
  expect([...at].sort((a, b) => a - b)).toEqual(at);
  const u = bun("inventory", "unsorted", h);
  expect(u).toContain("Unsorted");
  expect(u).toContain('aria-expanded="true"');
  expect(u).toContain("orphan");
});

test("bundles: no Unsorted header when every row has a known bundle", () => {
  const f = { ...bfeed, rows: bfeed.rows.filter((r: any) => r.id !== "orphan") };
  expect(inv(bhtml({}, {}, f))).not.toContain("inventory|unsorted");
});

test("problems-only hides ok rows and empty bundles; header counts stay whole-bundle with n of N", () => {
  const h = inv(bhtml({}, { problems: true }));
  expect(h).toContain("a-fail");
  expect(h).toContain("a-warn");
  expect(h).not.toContain("a-ok");
  expect(h).not.toContain("inventory|beta");
  expect(h).not.toContain("inventory|gamma");
  const a = bun("inventory", "alpha", h).slice(0, 400);
  expect(a).toContain("1 fail · 1 warn · 1 ok");
  expect(a).toContain("2 of 3");
});

test("problems-only is a switch in the Inventory filter bar", () => {
  expect(inv(bhtml())).toMatch(/<button[^>]*role="switch"[^>]*aria-checked="false"[^>]*data-act="problems"/);
  expect(inv(bhtml({}, { problems: true }))).toMatch(/<button[^>]*role="switch"[^>]*aria-checked="true"[^>]*data-act="problems"/);
});

test("no filter active: the row count is plain N, no n of N", () => {
  expect(inv(bhtml())).not.toContain(" of ");
});

test("search spans every bundle and opens a collapsed one; filters intersect", () => {
  const h = inv(bhtml({}, { q: "b-ok" }));
  const b = bun("inventory", "beta", h);
  expect(b).toContain('aria-expanded="true"');
  expect(b).toContain("b-ok1");
  expect(b).not.toContain("b-off");
  expect(b.slice(0, 400)).toContain("2 of 3");
  expect(h).not.toContain("inventory|alpha");
  // search AND a kind chip: only rows passing both
  const k = inv(bhtml({}, { q: "b-ok", kind: "secret" }));
  expect(k).toContain("b-ok2");
  expect(k).not.toContain("b-ok1");
});

test("search plus problems-only with no problem match says no rows match", () => {
  const h = inv(bhtml({}, { q: "b-ok", problems: true }));
  expect(h).toContain("No rows match these filters.");
  expect(h).not.toContain("Nothing failing or drifting.");
});

test("empty states: problems-only with nothing failing vs any other empty filter", () => {
  const healthy = { ...bfeed, rows: bfeed.rows.filter((r: any) => r.health === "ok" || r.health === "off") };
  expect(inv(bhtml({}, { problems: true }, healthy))).toContain("Nothing failing or drifting.");
  expect(inv(bhtml({}, { problems: true, kind: "check" }, healthy))).toContain("No rows match these filters.");
  expect(inv(bhtml({}, { q: "zzz-nothing" }))).toContain("No rows match these filters.");
});

test("Controls: a failing non-toggle row neither opens nor counts in the bundle; no n of N unfiltered", () => {
  const c = ctl(bhtml());
  const d = bun("controls", "delta", c);
  expect(d).toContain('aria-expanded="false"');
  expect(d).not.toContain("d-fail");
  expect(d.slice(0, 400)).toContain("1 ok");
  expect(d.slice(0, 400)).not.toContain("fail");
  expect(c).not.toContain(" of ");
  expect(c).not.toContain("a-fail");
  expect(c).not.toContain('data-act="problems"');
});

test("a header override is per region and keyed by bundle", () => {
  const rank = rollup([row("x", "fail")]).rank;
  const h = bhtml({ bundles: { "inventory|delta": { open: false, rank } } });
  expect(bun("inventory", "delta", inv(h))).toContain('aria-expanded="false"');
  expect(bun("controls", "delta", ctl(h))).toContain('aria-expanded="false"');
  const o = bhtml({ bundles: { "controls|delta": { open: true, rank } } });
  expect(bun("controls", "delta", ctl(o))).toContain('aria-expanded="true"');
  expect(bun("inventory", "delta", inv(o))).toContain('aria-expanded="true"');
});

test("a feed without bundles renders one All rows bundle", () => {
  const h = inv(html);
  expect(h.match(/data-act="bundle"/g)!.length).toBe(1);
  expect(h).toContain("All rows");
  expect(h).not.toContain("Unsorted");
});

test("bundle titles from the feed are escaped", () => {
  const f = { ...bfeed, bundles: [{ id: "alpha", title: "<img src=x onerror=1>" }] };
  expect(bhtml({}, {}, f)).not.toContain("<img");
});

// HIMMEL-4405: the shared header.
const ident = { version: "0.9.9", describe: "v0.9.9-3-gabc", commit: "0123456789abcdef0123456789abcdef01234567", checkout: "/srv/himmel-wt" };
test("renderHeader shows describe, the 12-char commit, checkout and feed time", () => {
  const h = renderHeader({ ...feed, himmel: ident });
  expect(h).toContain("himmel 0.9.9 · v0.9.9-3-gabc");
  expect(h).toContain("0123456789ab<");
  expect(h).toContain(`title="${ident.commit}"`);
  expect(h).toContain("/srv/himmel-wt");
  expect(h).toContain("2026-10-04 14:02");
});
test("renderHeader without feed.himmel says version unknown, keeps the feed time", () => {
  const h = renderHeader(feed);
  expect(h).toContain("version unknown (feed has no himmel identity)");
  expect(h).toContain("2026-10-04 14:02");
});
test("renderHeader escapes every identity field", () => {
  const x = "<img src=x onerror=1>";
  const h = renderHeader({ ...feed, himmel: { version: x, describe: x, commit: x, checkout: x } });
  expect(h).not.toContain("<img");
});

// HIMMEL-4807: the probe status while the first report runs.
test("renderProbe names the step, n of N, with a determinate native progress bar", () => {
  const h = renderProbe({ elapsedMs: 12_400, progress: { i: 3, n: 8, source: "pipeline cadence" } });
  expect(h).toMatch(/^<div class="probe" id="status" role="status" aria-live="polite">/);
  expect(h).toContain("probing pipeline cadence (3 of 8) · 12s");
  expect(h).toMatch(/<progress max="8" value="3" aria-label="station probe"><\/progress>/);
  expect(h).toContain("couple of minutes");
  expect(h).not.toContain("style=");
});
test("renderProbe before the first step: the station, an indeterminate bar", () => {
  for (const j of [{ elapsedMs: 900, progress: null }, { elapsedMs: 900 }, null]) {
    const h = renderProbe(j);
    expect(h).toContain("probing the station · ");
    expect(h).toMatch(/<progress aria-label="station probe"><\/progress>/);
    expect(h).not.toContain("value=");
    expect(h).not.toContain("style=");
  }
});
test("renderProbe escapes the source and only takes integer steps", () => {
  const h = renderProbe({ elapsedMs: 0, progress: { i: 1, n: 2, source: "<img src=x onerror=1>" } });
  expect(h).not.toContain("<img");
  expect(h).toContain("&lt;img");
  const bad = renderProbe({ elapsedMs: 0, progress: { i: '1" onclick="x', n: 2, source: "s" } });
  expect(bad).not.toContain("onclick");
});
