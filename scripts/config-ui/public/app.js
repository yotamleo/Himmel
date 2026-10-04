// HIMMEL-4254 P3/P4: thin DOM glue. All markup comes from render.js.
import { render, renderNav } from "/render.js";

const $ = (s) => document.querySelector(s);
const state = { open: new Set(), filt: { health: null, kind: null, q: "" }, plans: {} };
let feed = null;
let current = "triage";

// The token rides the URL fragment (never sent in a request line); keep it in
// memory only and clear it from the address bar.
const m = /#t=([0-9a-f]+)/.exec(location.hash);
const token = m ? m[1] : "";
if (m) history.replaceState(null, "", location.pathname + location.search);

function paint() {
  const keep = document.activeElement && document.activeElement.id === "q" ? document.activeElement.selectionStart : null;
  const focusK = document.activeElement && document.activeElement.matches && document.activeElement.matches(".row-head") ? document.activeElement.dataset.k : null;
  $("#main").innerHTML = render(feed, state);
  $("#nav").innerHTML = renderNav(feed, current);
  $("#probed").textContent = "probed " + String(feed.generatedAt || "").replace("T", " ").slice(0, 16);
  $("#where").textContent = `${location.host} · ${feed.target ? feed.target.scope : "?"} scope`;
  if (focusK !== null) { for (const h of document.querySelectorAll(".row-head")) if (h.dataset.k === focusK) { h.focus(); break; } }
  if (keep !== null) { const q = $("#q"); q.focus(); q.setSelectionRange(keep, keep); }
}

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
async function fetchFeed(onWait) {
  for (;;) {
    const r = await fetch("/api/feed", { headers: { "X-Himmel-Token": token } });
    if (r.status !== 202) return r;
    let j = {};
    try { j = await r.json(); } catch (_) { /* progress text only */ }
    onWait(Math.round((j.elapsedMs || 0) / 1000));
  }
}

// Only the newest call may paint: an older report can land after a newer one.
let feedGen = 0;
async function loadFeed() {
  const gen = ++feedGen;
  try {
    const r = await fetchFeed((s) => { if (gen === feedGen) toast(`re-probing… ${s}s`); });
    if (r.ok) { const f = await r.json(); if (gen === feedGen) { feed = f; paint(); } }
    else if (gen === feedGen) toast(`re-probe failed (${r.status})`);
  } catch (_) { if (gen === feedGen) toast("re-probe failed: server unreachable"); }
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

function go(id) {
  current = id;
  document.getElementById(id).scrollIntoView({ block: "start" });
  $("#nav").innerHTML = renderNav(feed, current);
}

document.addEventListener("click", (e) => {
  const b = e.target.closest("[data-act],[data-go],[data-f]");
  if (!b || !feed) return;
  if (b.dataset.go) return go(b.dataset.go);
  if (b.dataset.f) { state.filt[b.dataset.f] = state.filt[b.dataset.f] === b.dataset.v ? null : b.dataset.v; return paint(); }
  if (b.dataset.act === "copy") {
    e.stopPropagation();
    const t = b.dataset.cmd;
    try { navigator.clipboard.writeText(t).then(() => toast("Copied: " + t), () => toast(t)); } catch (_) { toast(t); }
    return;
  }
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
  if (["1", "2", "3"].includes(e.key)) return go(["triage", "controls", "inventory"][Number(e.key) - 1]);
  if ((e.key === "Enter" || e.key === " ") && e.target.matches(".row-head")) {
    e.preventDefault();
    const k = e.target.dataset.k;
    state.open.has(k) ? state.open.delete(k) : state.open.add(k);
    paint();
  }
});

(async () => {
  try {
    const r = await fetchFeed((s) => { $("#status").textContent = `probing the station… ${s}s (the first report can take a couple of minutes)`; });
    if (r.status === 401) { $("#status").textContent = "Not authorised: open the URL printed by `himmelctl ui` (it carries the session token)."; return; }
    if (!r.ok) {
      let why = "";
      try { why = (await r.json()).reason || ""; } catch (_) { /* status only */ }
      $("#status").textContent = `Feed failed (${r.status})${why ? ": " + why : ""}. Reload to retry.`;
      return;
    }
    feed = await r.json();
    paint();
  } catch (_) { $("#status").textContent = "Server unreachable (it exits after 30 min idle)."; }
})();
