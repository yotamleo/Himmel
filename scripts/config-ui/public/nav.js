// HIMMEL-4711: the one page list of the config console (/) and the AG-UI pages (/agui/), so both documents draw
// the same rail. app.js imports it as /nav.js; agui-web bundles it. The session token rides only the URL
// fragment (#t=<token>), never a path or query, so it never reaches a request line.
export const PAGES = [
  { id: "config", label: "Config" },
  { id: "health", label: "Health" },
  { id: "fleet", label: "Fleet" },
];
const CONSOLE = ["config", "health"];

const frag = (o) => "#" + new URLSearchParams(o).toString();

// here: "console" (the / document: its pages are #/<id> routes, the token is held in memory) or "agui".
export function pageHref({ here, token, id, run }) {
  if (id === "fleet") return "/agui/" + frag({ t: token });
  if (id === "run") return "/agui/" + frag({ t: token, run });
  return here === "console" ? "#/" + id : "/" + frag({ t: token, page: id });
}

// run: the session the run page shows, which adds a Run entry.
export function navLinks({ here, token, current, run }) {
  const pages = run ? [...PAGES, { id: "run", label: "Run" }] : PAGES;
  return pages.map((p) => ({ ...p, href: pageHref({ here, token, id: p.id, run }), current: p.id === current }));
}

// The console's landing fragment, #t=<hex>[&page=<id>]: the token and the console page to open; null otherwise.
export function parseLanding(hash) {
  const p = new URLSearchParams(hash.replace(/^#/, ""));
  const token = p.get("t");
  if (!token || !/^[0-9a-f]+$/.test(token)) return null;
  return { token, page: CONSOLE.includes(p.get("page")) ? p.get("page") : "config" };
}

// The Fleet entry's status dot, in app.css's ok / warn / fail: can the fleet be read in full right now?
export function fleetDot(fleet, error) {
  if (error) return { cls: "fail", title: `fleet: ${error}` };
  if (!fleet) return { cls: "off", title: "fleet: not read yet" };
  if (fleet.census === "unavailable") return { cls: "fail", title: "fleet: the process census failed" };
  if (fleet.census === "degraded") return { cls: "warn", title: "fleet: some sessions could not be read" };
  return { cls: "ok", title: "fleet: every session read" };
}
