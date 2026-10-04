// HIMMEL-4254 P3: thin DOM glue. All markup comes from render.js.
import { render, renderNav } from "/render.js";

const $ = (s) => document.querySelector(s);
const state = { open: new Set(), filt: { health: null, kind: null, q: "" } };
let feed = null;
let current = "triage";

// The token rides the URL fragment (never sent in a request line); keep it in
// memory only and clear it from the address bar.
const m = /#t=([0-9a-f]+)/.exec(location.hash);
const token = m ? m[1] : "";
if (m) history.replaceState(null, "", location.pathname + location.search);

function paint() {
  const keep = document.activeElement && document.activeElement.id === "q" ? document.activeElement.selectionStart : null;
  $("#main").innerHTML = render(feed, state);
  $("#nav").innerHTML = renderNav(feed, current);
  $("#probed").textContent = "probed " + String(feed.generatedAt || "").replace("T", " ").slice(0, 16);
  $("#where").textContent = `${location.host} · ${feed.target ? feed.target.scope : "?"} scope`;
  if (keep !== null) { const q = $("#q"); q.focus(); q.setSelectionRange(keep, keep); }
}

function toast(t) {
  const el = $("#toast");
  el.textContent = t; el.hidden = false;
  clearTimeout(toast.t);
  toast.t = setTimeout(() => { el.hidden = true; }, 2600);
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
  if (b.dataset.act === "toggle" && !e.target.closest(".slot")) {
    const k = b.dataset.k;
    state.open.has(k) ? state.open.delete(k) : state.open.add(k);
    paint();
  }
});
document.addEventListener("input", (e) => { if (e.target.id === "q") { state.filt.q = e.target.value; paint(); } });
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
    const r = await fetch("/api/feed", { headers: { "X-Himmel-Token": token } });
    if (r.status === 401) { $("#status").textContent = "Not authorised: open the URL printed by `himmelctl ui` (it carries the session token)."; return; }
    if (!r.ok) { $("#status").textContent = `Feed failed (${r.status}).`; return; }
    feed = await r.json();
    paint();
  } catch (_) { $("#status").textContent = "Server unreachable (it exits after 30 min idle)."; }
})();
