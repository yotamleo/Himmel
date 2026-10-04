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

test("right slot: toggle is disabled and says available in P4", () => {
  const c = region("controls");
  expect(c).toContain("cadence-x");
  expect(c).toMatch(/<button[^>]*role="switch"[^>]*disabled/);
  expect(c).toContain("available in P4");
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
