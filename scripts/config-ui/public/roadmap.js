// HIMMEL-4943: the Roadmap page. Pure rendering, no DOM: renderRoadmap(data, ui) → HTML.
// data = GET /api/roadmap (null while loading); ui = { version, theme }, indices into data.versions / data.themes or null.
// Everything shown is the server's live read; the page proposes only, and nothing here writes Jira.
import { esc } from "./render.js";

const COLS = [["todo", "To do"], ["prog", "In progress"], ["rev", "In review"], ["ci", "CI"], ["done", "Done"], ["wont", "Won't"]];
const section = (id, title, sub, body) => `<section id="${id}" aria-labelledby="h-${id}"><h2 id="h-${id}">${esc(title)}</h2><p class="sub">${esc(sub)}</p>${body}</section>`;
const jira = (argv) => "jira " + argv.map((a) => (/^[\w.,:@/=-]+$/.test(a) ? a : `"${a.replace(/(["\\$`])/g, "\\$1")}"`)).join(" ");

function releasesHtml(d) {
  if (!d.versions.length) return `<div class="empty">No train versions.</div>`;
  const note = d.releaseUnknown ? `<div class="nodata">release state unknown: no versions snapshot, so no version is shown as released</div>` : "";
  return note + d.versions.map((v, i) => {
    const c = v.counts, total = Object.values(c).reduce((a, b) => a + b, 0);
    const tag = v.rel ? `released${v.date ? " " + v.date : ""}` : i === d.cur ? "running" : i === d.next ? "next" : "planned";
    const alert = v.open.length ? `<div class="alert"><span class="st fail">open</span> ${v.open.length} still open on a released version: ${v.open.map((k) => `HIMMEL-${k}`).map(esc).join(", ")}</div>` : "";
    return `<div class="card rm-rel${i === d.cur ? " cur" : ""}"><h3>${esc(v.n)} <span class="ro">${esc(tag)}</span></h3>
      <div class="kv">${COLS.map(([b, l]) => `${esc(l)} ${c[b]}`).join(" · ")} · ${total} total</div>${alert}</div>`;
  }).join("");
}

function filters(d, ui) {
  const sel = (name, label, items, cur) => `<label>${label} <select data-rm-filter="${name}"><option value="">all</option>${items.map((x, i) =>
    `<option value="${i}"${cur === i ? " selected" : ""}>${esc(x)}</option>`).join("")}</select></label>`;
  return `<div class="rm-filters">${sel("version", "Version", d.versions.map((v) => v.n), ui.version)} ${sel("theme", "Theme", d.themes, ui.theme)}</div>`;
}

function cardHtml(t, d) {
  const lg = t.leg ? `<div class="rm-leg"><b>${esc(t.leg.label)} ${esc(t.leg.marker)}</b>${t.leg.reason ? " " + esc(t.leg.reason) : ""}</div>` : "";
  const dr = t.drift === 1 ? `<span class="st warn">drift</span> plan: ${esc(t.pv)}` : t.drift === 2 ? `<span class="st warn">unplanned</span>` : "";
  return `<div class="rm-card"><b>HIMMEL-${t.k}</b> <span class="ro">${esc(t.s)}</span><div>${esc(t.t)}</div>
    <div class="ro">${esc(d.themes[t.theme])} ${dr}</div>${lg}</div>`;
}

function kanbanHtml(d, ui) {
  const shown = d.tickets.filter((t) => (ui.version == null || t.v === ui.version) && (ui.theme == null || t.theme === ui.theme));
  const head = `<div class="rm-bar">${filters(d, ui)}<button class="btn" data-act="refresh-roadmap">refresh</button></div>`;
  if (!shown.length) return head + `<div class="empty">No tickets match.</div>`;
  const vers = [...new Set(shown.map((t) => t.v))].sort((a, b) => a - b);
  return head + vers.map((v) => `<h3 class="rm-ver">${esc(d.versions[v].n)}</h3><div class="rm-board">${COLS.map(([b, l]) => {
    const cards = shown.filter((t) => t.v === v && t.b === b);
    return `<div class="rm-col"><h4>${esc(l)} <span class="ro">${cards.length}</span></h4>${cards.map((t) => cardHtml(t, d)).join("")}</div>`;
  }).join("")}</div>`).join("");
}

function driftHtml(d) {
  const n = d.drift.now;
  const trend = d.drift.trend.length ? `<div class="ro">trend (drift/unplanned/unthemed, oldest first): ${d.drift.trend.map((r) => `${r[1]}/${r[2]}/${r[3]}`).map(esc).join(" → ")}</div>`
    : `<div class="nodata">no drift log rows</div>`;
  const plan = d.plan.state === "ok" ? "" : `<div class="nodata">plan absent: ${esc(d.plan.reason || "no plan dir")}; drift is not computed</div>`;
  return `<div class="kv">drift ${n.drift} · unplanned ${n.unplanned} · unthemed ${n.unthemed}</div>${plan}${trend}`;
}

// The version/theme filter narrows the sync and librarian lists too: a filtered-out ticket renders nowhere.
const shownKs = (d, ui) => new Set(d.tickets.filter((t) => (ui.version == null || t.v === ui.version) && (ui.theme == null || t.theme === ui.theme)).map((t) => t.k));

function syncHtml(d, ui) {
  const keep = shownKs(d, ui);
  const ops = (d.sync || []).filter((o) => keep.has(o.k));
  const body = ops.length ? ops.map((o) => `<tr><td>HIMMEL-${o.k}</td><td>${esc(o.marker)}</td><td>${esc(o.why)}</td>
      <td><code>${esc(jira(o.argv))}</code> <button class="btn" data-act="copy" data-cmd="${esc(jira(o.argv))}">copy</button></td></tr>`).join("")
    : `<tr><td colspan="4" class="empty">Jira already matches the legs.</td></tr>`;
  return `<p class="ro">Planned only: the console kit is the one writer, via the Jira CLI. Legs never write Jira and this page never does.</p>
    <table class="rm-sync"><thead><tr><th>Ticket</th><th>Leg</th><th>Why</th><th>Command</th></tr></thead><tbody>${body}</tbody></table>`;
}

function librarianHtml(d, ui) {
  const l = d.librarian, keep = shownKs(d, ui);
  const list = (title, all) => { const items = all.filter((p) => (p.keys ? p.keys.some((k) => keep.has(k)) : keep.has(p.k))); return `<div class="card"><h3>${esc(title)} <span class="ro">${items.length}</span></h3>${items.length ? items.map((p) =>
    `<div class="hrow"><span class="id">${p.keys ? p.keys.map((k) => `HIMMEL-${k}`).map(esc).join(" = ") : "HIMMEL-" + esc(p.k)}</span><span class="det">${esc(p.title)}</span><span>${esc(p.proposal)}</span></div>`).join("")
    : `<div class="empty">Nothing to propose.</div>`}</div>`; };
  return `<p class="ro">Proposals only: needs operator approval (or a recorded standing rule) before any fixVersion move or close.</p>`
    + list("Stale In Progress", l.staleInProgress) + list("Version drift", l.drift) + list("Unthemed", l.unthemed)
    + list("Released but open", l.releasedOpen) + list("Duplicate titles", l.duplicates);
}

export function renderRoadmap(data, ui) {
  if (!data) return `<p class="sub" id="status">loading…</p>`;
  if (data.state !== "ok") return `<div class="nodata">${esc(data.reason || "roadmap unavailable")}</div><button class="btn" data-act="refresh-roadmap">refresh</button>`;
  const u = ui || {};
  return [
    section("rm-releases", "Releases", `Live from the Jira mirror (${data.mirror.count} tickets, newest update ${data.mirror.newest || "unknown"}).`, releasesHtml(data)),
    section("rm-kanban", "Kanban", "Train tickets by version and status; the leg marker shows on the card.", kanbanHtml(data, u)),
    section("rm-drift", "Drift", "Jira's fixVersion against the plan's placement.", driftHtml(data)),
    section("rm-sync", "Leg to Jira sync", "What the legs say that Jira does not yet.", syncHtml(data, u)),
    section("rm-librarian", "Librarian", "Ready-to-approve cleanups.", librarianHtml(data, u)),
  ].join("\n");
}
