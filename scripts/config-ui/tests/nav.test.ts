import { test, expect, afterEach } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fleetDot, navLinks, pageHref, parseLanding } from "../public/nav.js";
import { LANDING, launchUrl, startServer } from "../server";

// HIMMEL-4711: the config console and the AG-UI pages are one app with one rail. These pin the page list, the
// token-in-fragment rule, the landing switch and the status dot.
const TOKEN = "a".repeat(64);
const RUN = "0b6e1c2a-3f4d-4e5f-8a9b-0c1d2e3f4a5b";
const BASE = "http://127.0.0.1:4242";

// Only a fragment carries the token: never the path or the query, so it never reaches a request line.
const tokenOnlyInFragment = (href: string) => {
  const u = new URL(href, BASE);
  return !u.pathname.includes(TOKEN) && !u.search.includes(TOKEN);
};

test("the rail lists Config, Health and Fleet on every page, plus Run when a run is open", () => {
  expect(navLinks({ here: "console", token: TOKEN, current: "config" }).map((l) => l.label)).toEqual(["Config", "Health", "Fleet"]);
  expect(navLinks({ here: "agui", token: TOKEN, current: "fleet" }).map((l) => l.label)).toEqual(["Config", "Health", "Fleet"]);
  expect(navLinks({ here: "agui", token: TOKEN, current: "run", run: RUN }).map((l) => l.label)).toEqual(["Config", "Health", "Fleet", "Run"]);
});

test("exactly the current page is marked current", () => {
  const links = navLinks({ here: "agui", token: TOKEN, current: "run", run: RUN });
  expect(links.filter((l) => l.current).map((l) => l.id)).toEqual(["run"]);
});

test("from the console, its own pages are in-document routes and the AG-UI pages carry the token in the fragment", () => {
  const by = Object.fromEntries(navLinks({ here: "console", token: TOKEN, current: "config" }).map((l) => [l.id, l.href]));
  expect(by.config).toBe("#/config");
  expect(by.health).toBe("#/health");
  expect(by.fleet).toBe(`/agui/#t=${TOKEN}`);
});

test("from the AG-UI page, every link carries the token in the fragment and nowhere else", () => {
  const links = navLinks({ here: "agui", token: TOKEN, current: "run", run: RUN });
  const by = Object.fromEntries(links.map((l) => [l.id, l.href]));
  expect(by.config).toBe(`/#t=${TOKEN}&page=config`);
  expect(by.health).toBe(`/#t=${TOKEN}&page=health`);
  expect(by.fleet).toBe(`/agui/#t=${TOKEN}`);
  expect(by.run).toBe(`/agui/#t=${TOKEN}&run=${RUN}`);
  for (const l of links) expect(tokenOnlyInFragment(l.href)).toBe(true);
  expect(pageHref({ here: "agui", token: TOKEN, id: "health" })).toBe(by.health);
});

test("the console reads its landing fragment: the token and the page, never an unknown page", () => {
  expect(parseLanding(`#t=${TOKEN}`)).toEqual({ token: TOKEN, page: "config" });
  expect(parseLanding(`#t=${TOKEN}&page=health`)).toEqual({ token: TOKEN, page: "health" });
  expect(parseLanding(`#t=${TOKEN}&page=fleet`)).toEqual({ token: TOKEN, page: "config" }); // fleet is not a console route
  expect(parseLanding(`#t=${TOKEN}&page=nope`)).toEqual({ token: TOKEN, page: "config" });
  expect(parseLanding("#/health")).toBeNull();
  expect(parseLanding("#t=not-hex")).toBeNull();
});

test("the Fleet status dot: ok, warn when degraded, fail when the fleet cannot be read", () => {
  expect(fleetDot({ census: "ok" }, null).cls).toBe("ok");
  expect(fleetDot({ census: "degraded" }, null).cls).toBe("warn");
  expect(fleetDot({ census: "unavailable" }, null).cls).toBe("fail");
  expect(fleetDot(null, "the token was refused").cls).toBe("fail");
  expect(fleetDot(null, null).cls).toBe("off"); // not read yet
  for (const d of [fleetDot({ census: "ok" }, null), fleetDot(null, "x")]) expect(d.title.length).toBeGreaterThan(0);
});

test("himmelctl ui prints ONE URL: the landing switch picks the fleet or the console", () => {
  expect(["fleet", "config"]).toContain(LANDING);
  expect(launchUrl(BASE, TOKEN, { landing: "fleet", built: true })).toBe(`${BASE}/agui/#t=${TOKEN}`);
  expect(launchUrl(BASE, TOKEN, { landing: "config", built: true })).toBe(`${BASE}/#t=${TOKEN}`);
  // An unbuilt page cannot be the landing: the console, which links to the fleet's build steps.
  expect(launchUrl(BASE, TOKEN, { landing: "fleet", built: false })).toBe(`${BASE}/#t=${TOKEN}`);
  // --agui asks for the AG-UI page outright: the fleet, or one run.
  expect(launchUrl(BASE, TOKEN, { landing: "config", built: true, agui: "fleet" })).toBe(`${BASE}/agui/#t=${TOKEN}`);
  expect(launchUrl(BASE, TOKEN, { landing: "config", built: false, agui: RUN })).toBe(`${BASE}/agui/#t=${TOKEN}&run=${RUN}`);
});

let stops: (() => void)[] = [];
afterEach(() => { for (const f of stops) f(); stops = []; });

test("the shared rail files are served like every other page: same headers, no token", async () => {
  const home = mkdtempSync(join(tmpdir(), "nav-home-"));
  const s = startServer({ port: 0, token: TOKEN, env: { PATH: process.env.PATH, HOME: home, CONFIG_UI_HIMMELCTL: join(import.meta.dir, "stub-himmelctl.js"), CONFIG_UI_IDLE_MS: "60000" } });
  stops.push(() => { s.stop(); rmSync(home, { recursive: true, force: true }); });
  for (const [path, type] of [["/nav.js", "application/javascript; charset=utf-8"], ["/theme.css", "text/css; charset=utf-8"]]) {
    const r = await fetch(`http://127.0.0.1:${s.port}${path}`);
    expect(r.status).toBe(200);
    expect(r.headers.get("content-type")).toBe(type);
    expect(r.headers.get("content-security-policy")).toBe("default-src 'self'");
    expect(r.headers.get("x-frame-options")).toBe("DENY");
  }
});
