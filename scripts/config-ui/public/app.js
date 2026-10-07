// HIMMEL-4254 P3/P4: thin DOM glue. All markup comes from render.js.
import { render, renderNav, renderHeader, renderProbe } from "/render.js";
import { renderHealth } from "/health.js";
import { fleetDot, navLinks, parseLanding } from "/nav.js";

const $ = (s) => document.querySelector(s);
const state = { open: new Set(), bundles: {}, filt: { health: null, kind: null, q: "", problems: false }, plans: {} };
let feed = null;
let lastProbe = null; // HIMMEL-4807: the newest 202 body ({ elapsedMs, progress }) while the first report runs
let current = "triage";

// The token rides the URL fragment (never sent in a request line); keep it in
// memory only and clear it from the address bar. HIMMEL-4711: the AG-UI rail
// links here as #t=<token>&page=<id>, landing on that page.
const landing = parseLanding(location.hash);
const token = landing ? landing.token : "";
if (landing) history.replaceState(null, "", location.pathname + location.search + "#/" + landing.page);
// HIMMEL-4711: the Fleet link's status dot, read on load and on each page change (never polled: an open
// console must still let the server idle out).
let fleet = { data: null, error: null };

// Pages: one entry each (id = the `#/<id>` route). `regions` keeps the Config
// region nav and its 1/2/3 keys on that page only.
// Health renders without a feed (D2): its bank and legs cards do not wait for the doctor report.
let health = null; // GET /api/health, null while loading
let healthGen = 0; // declared before route() runs: a reload at #/health calls loadHealth() from it
const PAGES = [
  { id: "config", label: "Config", regions: true, render: (f) => render(f, state) },
  { id: "health", label: "Health", needsFeed: false, render: (f) => renderHealth(f, health), onVisit: () => { if (!health) loadHealth(); } },
];
let currentPage = PAGES[0];

function route() {
  const id = (/^#\/(\w+)/.exec(location.hash) || [])[1];
  currentPage = PAGES.find((p) => p.id === id) || PAGES[0];
  if (id !== currentPage.id) history.replaceState(null, "", location.pathname + location.search + "#/" + currentPage.id);
  renderPages();
  loadFleet();
  if (currentPage.onVisit) currentPage.onVisit();
  if (feed || currentPage.needsFeed === false) paint();
  else { $("#main").innerHTML = lastProbe ? renderProbe(lastProbe) : `<p class="sub" id="status">loading…</p>`; $("#nav").innerHTML = ""; } // no stale page under this tab
  // HIMMEL-4807: back on Config, pick up a newer report the server loaded in the background.
  if (feed && currentPage.needsFeed !== false) refreshFeed();
}
addEventListener("hashchange", route);
route();

// The rail (nav.js, shared with the AG-UI page): Config and Health are routes here, Fleet is /agui/.
function renderPages() {
  const dot = fleetDot(fleet.data, fleet.error);
  $("#pages").innerHTML = navLinks({ here: "console", token, current: currentPage.id }).map((l) =>
    `<a href="${l.href}"${l.current ? ' aria-current="page"' : ""}>${l.label}${l.id === "fleet" ? `<span class="st-dot ${dot.cls}" title="${dot.title}"></span>` : ""}</a>`).join("");
}

async function loadFleet() {
  try {
    const r = await fetch("/api/agui/fleet", { headers: { "X-Himmel-Token": token }, cache: "no-store" });
    fleet = r.ok ? { data: await r.json(), error: null } : { data: null, error: r.status === 401 ? "the token was refused" : `the server answered ${r.status}` };
  } catch (_) { fleet = { data: null, error: "server unreachable" }; }
  renderPages();
}

function paint() {
  const keep = document.activeElement && document.activeElement.id === "q" ? document.activeElement.selectionStart : null;
  const focusK = document.activeElement && document.activeElement.matches && document.activeElement.matches(".row-head") ? document.activeElement.dataset.k : null;
  const focusB = document.activeElement && document.activeElement.matches && document.activeElement.matches(".bhead") ? document.activeElement.dataset.b : null;
  $("#main").innerHTML = currentPage.render(feed);
  $("#nav").innerHTML = currentPage.regions && feed ? renderNav(feed, current) : "";
  $("#top").innerHTML = renderHeader(feed);
  $("#where").textContent = `${location.host} · ${feed && feed.target ? feed.target.scope : "?"} scope`;
  if (focusK !== null) { for (const h of document.querySelectorAll(".row-head")) if (h.dataset.k === focusK) { h.focus(); break; } }
  if (focusB !== null) { for (const h of document.querySelectorAll(".bhead")) if (h.dataset.b === focusB) { h.focus(); break; } }
  if (keep !== null) { const q = $("#q"); q.focus(); q.setSelectionRange(keep, keep); }
}

// #status lives in main and a page paint replaces it; fall back to the toast.
function setStatus(t) { const el = $("#status"); if (el) el.textContent = t; else toast(t); }

function toast(t) {
  const el = $("#toast");
  el.textContent = t; el.hidden = false;
  clearTimeout(toast.t);
  toast.t = setTimeout(() => { el.hidden = true; }, 2600);
}

async function post(path, body) {
  let r;
  try { r = await fetch(path, { method: "POST", headers: { "X-Himmel-Token": token, "Content-Type": "application/json" }, body: JSON.stringify(body) }); }
  catch (_) { return { ok: false, status: 0, j: { error: `${path} unreachable (is the server still running?)` } }; }
  let j = {};
  try { j = await r.json(); } catch (_) { j = { error: `${path} failed (${r.status})` }; }
  return { ok: r.ok, status: r.status, j };
}

// The server answers 202 while its one background report runs (it can take
// minutes); keep asking, with the token each time, until a terminal answer.
// HIMMEL-4807: a 202 answers as soon as the probe step changes; onWait gets its body ({ elapsedMs, progress }).
async function fetchFeed(onWait) {
  for (;;) {
    const r = await fetch("/api/feed", { headers: { "X-Himmel-Token": token } });
    if (r.status !== 202) return r;
    let j = {};
    try { j = await r.json(); } catch (_) { /* progress text only */ }
    lastProbe = j;
    onWait(j);
  }
}

// Only the newest call may paint: an older report can land after a newer one.
let feedGen = 0;
async function loadFeed() {
  const gen = ++feedGen;
  const say = (j) => {
    const s = Math.round((j.elapsedMs || 0) / 1000), p = j.progress;
    return p ? `re-probing ${p.source} (${p.i} of ${p.n})… ${s}s` : `re-probing… ${s}s`;
  };
  try {
    const r = await fetchFeed((j) => { if (gen === feedGen) toast(say(j)); });
    if (r.ok) { const f = await r.json(); if (gen === feedGen) { feed = f; paint(); } }
    else if (gen === feedGen) toast(`re-probe failed (${r.status})`);
  } catch (_) { if (gen === feedGen) toast("re-probe failed: server unreachable"); }
}

// HIMMEL-4807: one quiet look for a newer report (the server refreshes it in the background). Only a 200 with a
// new generatedAt repaints, and never over a loadFeed started since; a 202 or an error says nothing. Called on
// arriving at Config and when the tab becomes visible, never on a timer: an open console must still idle out.
async function refreshFeed() {
  if (!feed) return;
  const gen = feedGen;
  try {
    const r = await fetch("/api/feed", { headers: { "X-Himmel-Token": token } });
    if (r.status !== 200) return;
    const f = await r.json();
    if (gen === feedGen && feed && f.generatedAt !== feed.generatedAt) { feed = f; paint(); }
  } catch (_) { /* quiet */ }
}
document.addEventListener("visibilitychange", () => { if (document.visibilityState === "visible") refreshFeed(); });

// Only the newest call may paint, as with the feed.
async function loadHealth() {
  const gen = ++healthGen;
  let j;
  try {
    const r = await fetch("/api/health", { headers: { "X-Himmel-Token": token } });
    j = r.ok ? await r.json() : null;
    if (!j) toast(`health sources failed (${r.status})`);
  } catch (_) { j = null; toast("health sources: server unreachable"); }
  if (gen !== healthGen) return;
  const gone = { state: "error", reason: "health endpoint unreachable" };
  health = j || { bank: gone, legs: gone, monitoring: { state: "error", reason: "health endpoint unreachable" } };
  if (currentPage.needsFeed === false) paint();
}

// Two-step write: the dry-run binds a preview id; only confirm runs it.
async function preview(b) {
  const k = b.dataset.k;
  const busy = state.plans[k];
  if (busy && (busy.stage === "loading" || busy.stage === "running")) return; // one request per row at a time
  const req ={ action: b.dataset.action, target: b.dataset.target };
  if (b.dataset.value) req.value = b.dataset.value;
  state.plans[k] = { stage: "loading" }; paint();
  const { ok, j } = await post("/api/preview", req);
  state.plans[k] = ok ? { stage: "plan", req, typed: "", ...j } : { stage: "error", error: j.error || "preview failed", output: j.output };
  paint();
}

async function run(k) {
  const p = state.plans[k];
  if (!p || p.stage !== "plan") return;
  state.plans[k] = { stage: "running", command: p.command }; paint();
  const { ok, j } = await post("/api/run", { previewId: p.previewId, ...p.req, consent: p.typed });
  state.plans[k] = ok ? { stage: "done", ...j } : { stage: "error", error: j.error || "run failed", output: j.output };
  paint();
  if (ok) loadFeed();
}

// A header click records an override with the bundle's rank at click time; a
// later worse rank makes render.js drop it (isOpen).
function toggleBundle(h) {
  state.bundles[h.dataset.b] = { open: h.getAttribute("aria-expanded") !== "true", rank: Number(h.dataset.rank) };
  paint();
}

function go(id) {
  current = id;
  document.getElementById(id).scrollIntoView({ block: "start" });
  $("#nav").innerHTML = renderNav(feed, current);
}

document.addEventListener("click", (e) => {
  const b = e.target.closest("[data-act],[data-go],[data-f]");
  if (!b) return;
  if (b.dataset.act === "refresh-health") { loadHealth(); return void loadFeed(); } // the verdict reads the doctor feed too
  if (b.dataset.act === "open-config") {
    state.filt = { health: null, kind: null, q: b.dataset.id, problems: false };
    location.hash = "#/config";
    return;
  }
  if (!feed) return;
  if (b.dataset.go) return go(b.dataset.go);
  if (b.dataset.f) { state.filt[b.dataset.f] = state.filt[b.dataset.f] === b.dataset.v ? null : b.dataset.v; return paint(); }
  if (b.dataset.act === "copy") {
    e.stopPropagation();
    const t = b.dataset.cmd;
    try { navigator.clipboard.writeText(t).then(() => toast("Copied: " + t), () => toast(t)); } catch (_) { toast(t); }
    return;
  }
  if (b.dataset.act === "bundle") return toggleBundle(b);
  if (b.dataset.act === "problems") { state.filt.problems = !state.filt.problems; return paint(); }
  if (b.dataset.act === "plan") { e.stopPropagation(); return void preview(b); }
  if (b.dataset.act === "run") return void run(b.dataset.k);
  if (b.dataset.act === "close") { delete state.plans[b.dataset.k]; return paint(); }
  if (b.dataset.act === "toggle" && !e.target.closest(".slot")) {
    const k = b.dataset.k;
    state.open.has(k) ? state.open.delete(k) : state.open.add(k);
    paint();
  }
});
document.addEventListener("input", (e) => {
  if (e.target.id === "q") { state.filt.q = e.target.value; paint(); return; }
  if (e.target.dataset.act === "consent") {
    // No repaint: keep the caret; only flip the confirm button.
    const p = state.plans[e.target.dataset.k];
    if (!p) return;
    p.typed = e.target.value;
    const btn = e.target.closest(".plan").querySelector('[data-act="run"]');
    if (btn) btn.disabled = p.typed !== p.consent.expect;
  }
});
document.addEventListener("keydown", (e) => {
  if (!feed || e.target.matches("input")) return;
  if (currentPage.regions && ["1", "2", "3"].includes(e.key)) return go(["triage", "controls", "inventory"][Number(e.key) - 1]);
  if ((e.key === "Enter" || e.key === " ") && e.target.matches(".bhead")) {
    e.preventDefault();
    return toggleBundle(e.target);
  }
  if ((e.key === "Enter" || e.key === " ") && e.target.matches(".row-head")) {
    e.preventDefault();
    const k = e.target.dataset.k;
    state.open.has(k) ? state.open.delete(k) : state.open.add(k);
    paint();
  }
});

(async () => {
  try {
    // HIMMEL-4807: the probe status (step, n of N, a progress bar) replaces #status on a page that waits for the feed.
    const r = await fetchFeed((j) => { const el = $("#status"); if (el && currentPage.needsFeed !== false) el.outerHTML = renderProbe(j); });
    if (r.status === 401) { setStatus("Not authorised: open the URL printed by `himmelctl ui` (it carries the session token)."); return; }
    if (!r.ok) {
      let why = "";
      try { why = (await r.json()).reason || ""; } catch (_) { /* status only */ }
      setStatus(`Feed failed (${r.status})${why ? ": " + why : ""}. Reload to retry.`);
      return;
    }
    feed = await r.json();
    paint();
  } catch (_) { setStatus("Server unreachable (it exits after 30 min idle)."); }
})();
