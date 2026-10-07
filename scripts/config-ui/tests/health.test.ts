// HIMMEL-4405 PR-b: the one Health verdict (I6) and the page's escaping, as pure functions.
import { test, expect } from "bun:test";
// @ts-ignore plain browser ES module, no types
import { verdict, renderHealth } from "../public/health.js";

const r = (id: string, health: string, extra: Record<string, unknown> = {}) => ({
  id, source: "item", bundle: "guards", health, installed: { state: "present", detail: `d-${id}` }, fix: { remedy: `fix-${id}`, owner: "user" }, ...extra,
});
const feed = (...rows: object[]) => ({ rows });
const prom = (alerts: object[] | null) => ({ monitoring: { state: alerts ? "ok" : "absent", prometheus: alerts ? { state: "ok", alerts } : { state: "absent" }, exporter: { state: "absent" } } });
const page = { alertname: "A", severity: "page", summary: "s" }, warnAlert = { alertname: "W", severity: "warn", summary: "s" };

test("verdict truth table", () => {
  const cases: [string, unknown, unknown, string][] = [
    ["pending feed", null, prom([page]), "No data"],
    ["fail row", feed(r("a", "fail")), prom(null), "Act now"],
    ["page alert, clean feed", feed(r("a", "ok")), prom([page]), "Act now"],
    ["warn row", feed(r("a", "warn")), prom(null), "Needs a look"],
    ["warn-severity alert, clean feed", feed(r("a", "ok")), prom([warnAlert]), "Needs a look"],
    ["fail beats warn", feed(r("a", "warn"), r("b", "fail")), prom(null), "Act now"],
    ["clean, no alerts firing", feed(r("a", "ok"), r("b", "off")), prom([]), "All clear"],
    ["clean, Prometheus absent never raises it", feed(r("a", "ok")), prom(null), "All clear"],
    ["clean, health not loaded", feed(r("a", "ok")), null, "All clear"],
  ];
  for (const [name, f, h, want] of cases) expect([name, verdict(f, h).word]).toEqual([name, want]);
});

test("verdict counts and alert state come from their owners", () => {
  expect(verdict(feed(r("a", "fail"), r("b", "warn"), r("c", "warn")), prom([warnAlert]))).toMatchObject({ fail: 1, warn: 2, alerts: [warnAlert] });
  expect(verdict(feed(r("a", "ok")), prom(null)).alerts).toBeNull();
});

test("renderHealth escapes every feed, ledger, legs and alert string", () => {
  const evil = `<img src=x onerror=alert(1)>`;
  const f = feed(r(evil, "fail", { installed: { state: "present", detail: evil }, fix: { remedy: evil } }), r("job", "ok", { source: "cadence", id: `cadence:${evil}` }), r("q", "ok", { bundle: "search", id: evil }));
  const h = {
    bank: { state: "ok", row: { ts: evil, verdict: evil, five_hour: evil, seven_day: evil, age: evil, degraded: false } },
    legs: { state: "ok", manifest: "m", legs: [{ doc: `/x/${evil}`, status: evil }] },
    monitoring: { state: "ok", prometheus: { state: "ok", alerts: [{ alertname: evil, severity: evil, summary: evil }] }, exporter: { state: "absent" } },
  };
  const html = renderHealth(f, h);
  expect(html).not.toContain("<img");
  expect(html).toContain("&lt;img");
});

test("renderHealth with no feed and no health still renders all five sections", () => {
  const html = renderHealth(null, null);
  expect([...html.matchAll(/<h2 [^>]*>([^<]*)</g)].map((m) => m[1])).toEqual(
    ["Is himmel healthy?", "What is broken, and what do I do", "Scheduled jobs", "Legs and the usage bank", "Search and graph freshness"]);
  expect(html).toContain("No data");
});

// HIMMEL-4443: a responding exporter makes monitoring.state "ok", which must not hide a failing Prometheus.
test("each monitoring source's failure is rendered on its own, even when the other is ok", () => {
  const gone = { state: "absent" };
  const mon = (prometheus: object, exporter: object) => ({ bank: gone, legs: gone, monitoring: { state: "ok", prometheus, exporter } });
  const promDown = renderHealth(feed(r("a", "ok")), mon({ state: "error", reason: "HTTP 500" }, { state: "ok" }));
  expect(promDown).toContain("monitoring prometheus unreachable: HTTP 500");
  expect(promDown).not.toContain("monitoring exporter unreachable");
  const expDown = renderHealth(feed(r("a", "ok")), mon({ state: "ok", alerts: [] }, { state: "error", reason: "no answer" }));
  expect(expDown).toContain("monitoring exporter unreachable: no answer");
  expect(expDown).not.toContain("monitoring prometheus unreachable");
  const bothOk = renderHealth(feed(r("a", "ok")), mon({ state: "ok", alerts: [] }, { state: "ok" }));
  expect(bothOk).not.toContain("unreachable");
});

// HIMMEL-4767 (HIMMEL-4748 WP8): the resolver's tracker/forge answer is shown as one row.
test("renderHealth shows the project mode row from the resolver", () => {
  const gone = { state: "absent" };
  const mode = { state: "ok", tracker: "local", forge: "local-git", idRequired: "1" };
  const html = renderHealth(null, { bank: gone, legs: gone, monitoring: gone, mode });
  expect(html).toContain("tracker=local forge=local-git");
  expect(renderHealth(null, { bank: gone, legs: gone, monitoring: gone, mode: { state: "error", reason: "project-mode: invalid TRACKER='x'" } }))
    .toContain("project-mode: invalid TRACKER=&#39;x&#39;");
  expect(renderHealth(null, null)).toContain('id="mode"');
});
