import { test, expect } from "bun:test";
// @ts-ignore plain browser ES module, no types
import { render, renderNav } from "../public/render.js";

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
const html: string = render(feed, { open: new Set(), filt: { health: null, kind: null, q: "" } });
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
  const out: string = render(feed, { open: new Set([K]), filt: { health: null, kind: null, q: "" }, plans: { [K]: plan } });
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
