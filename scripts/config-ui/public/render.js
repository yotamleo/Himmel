// HIMMEL-4254 P3: pure rendering, no DOM. render(feed, state) → HTML string.
// state: { open: Set<string>, filt: { health, kind, q } }. P3 is read-only:
// toggles render disabled with "available in P4".
const ST = { ok: "● ok", warn: "◐ warn", fail: "✕ fail", off: "○ off", info: "· info" };
const GROUPS = ["core", "vault", "cadence", "bridge", "lane", "guard"];
const READ_ONLY = {
  "launch-shell variable": "set in launching shell",
  "secrets are presence-only": "presence probe",
  "Windows only": "Windows only",
  "probe failure": "probe failure",
};

export const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

const kindOf = (r) => ({ doctor: "check", item: "item" }[r.source] || r.source);
const remedyOf = (r) => (r.fix && r.fix.remedy) || "";
const isTriage = (r) => r.health === "fail" || r.health === "warn";
const isCopy = (r) => r.control.class === "fix-command" || (isTriage(r) && remedyOf(r) && r.source !== "flag" && r.control.class !== "toggle");

function slot(r, where) {
  const c = r.control;
  if (c.class === "toggle") {
    if (where !== "controls") return `<span class="ro">control ↗</span>`;
    const on = r.installed && r.installed.state === "present";
    return `<button class="sw" role="switch" aria-checked="${on}" disabled>${on ? "on" : "off"} <span class="t"></span></button> <span class="ro">available in P4</span>`;
  }
  if (isCopy(r)) return `<button class="btn" data-act="copy" data-cmd="${esc(remedyOf(r))}">copy · runs in your terminal</button>`;
  return `<span class="ro">⊘ read-only · ${esc(READ_ONLY[c.reason] || c.reason || "probe")}</span>`;
}

function firesText(f) {
  if (!f) return "unverified";
  return f.state === "yes" ? `yes · ${esc(f.at)} · ${esc(f.evidence)}` : esc(f.state);
}

function rowHtml(r, where, state) {
  const k = `${where}|${r.id}`;
  const open = state.open.has(k);
  const d = r.declared || {};
  const i = r.installed || {};
  let h = `<div class="row"><div class="row-head" tabindex="0" role="button" aria-expanded="${open}" data-act="toggle" data-k="${esc(k)}">
    <span class="st ${esc(r.health)}">${ST[r.health] || esc(r.health)}</span><span class="kind">[${esc(kindOf(r))}]</span>
    <span class="id" title="${esc(r.id)}">${esc(r.id)}</span><span class="det">${esc(i.detail)}</span>
    <span class="slot">${slot(r, where)}</span></div>`;
  if (open) {
    h += `<div class="body">
      <div class="f"><b>declared</b><span>${esc(d.where)}${d.desired ? ` · ${esc(d.desired)}` : ""}${d.profile ? ` · profile ${esc(d.profile)}` : ""}</span></div>
      <div class="f"><b>installed</b><span>${esc(i.state)}</span></div>
      <div class="f"><b>fires</b><span>${firesText(r.fires)}</span></div>
      <div class="f"><b>fix</b><span>${esc(remedyOf(r) || "none needed")}</span></div>
      <div class="full">${esc(i.detail)}</div></div>`;
  }
  return h + `</div>`;
}

function grouped(list, where, state) {
  return GROUPS.map((g) => {
    const rs = list.filter((r) => r.group === g);
    return rs.length ? `<div class="grp">${g} · ${rs.length}</div>` + rs.map((r) => rowHtml(r, where, state)).join("") : "";
  }).join("");
}

const sets = (feed) => {
  const rows = feed.rows || [];
  const triage = rows.filter(isTriage).sort((a, b) => (a.health === "fail" ? 0 : 1) - (b.health === "fail" ? 0 : 1));
  return { rows, triage, controls: rows.filter((r) => r.control.class === "toggle") };
};

export function renderNav(feed, current) {
  const { rows, triage, controls } = sets(feed);
  return [["triage", "Triage", triage.length, 1], ["controls", "Controls", controls.length, 2], ["inventory", "Inventory", rows.length, 3]]
    .map(([id, label, n, key]) => `<button data-go="${id}" aria-current="${id === current}"><span>${label} ${n}</span><kbd>${key}</kbd></button>`).join("");
}

export function render(feed, state) {
  const { rows, triage, controls } = sets(feed);
  const filt = state.filt || {};
  const nf = triage.filter((r) => r.health === "fail").length;
  const okOf = (src) => { const l = rows.filter((r) => r.source === src); return `${l.filter((r) => r.health === "ok").length}/${l.length}`; };
  const q = (filt.q || "").toLowerCase();
  const inv = rows.filter((r) => (!filt.health || r.health === filt.health) && (!filt.kind || kindOf(r) === filt.kind) && (!q || r.id.toLowerCase().includes(q)));
  const kinds = [...new Set(rows.map(kindOf))];
  const chips = ["fail", "warn", "ok", "off", "info"].map((h) => `<button class="chip" data-f="health" data-v="${h}" aria-pressed="${filt.health === h}">${h}</button>`)
    .concat(kinds.map((k) => `<button class="chip" data-f="kind" data-v="${esc(k)}" aria-pressed="${filt.kind === k}">${esc(k)}</button>`)).join("");
  return `<section id="triage" aria-labelledby="h-triage">
  <h2 id="h-triage">Triage</h2>
  <p class="sub">Only rows that are failing or drifting. Opt-in items you left off are not listed.</p>
  <div class="summary"><span class="st fail">${nf} fail</span><span class="st warn">${triage.length - nf} warn</span><span class="ro">items ${okOf("item")} ok · doctor ${okOf("doctor")} ok</span></div>
  ${triage.length ? triage.map((r) => rowHtml(r, "triage", state)).join("") : `<div class="empty">Nothing wrong. ${okOf("item")} items ok, doctor ${okOf("doctor")}.</div>`}
</section>
<section id="controls" aria-labelledby="h-controls">
  <h2 id="h-controls">Controls</h2>
  <p class="sub">Everything that can be switched. Read-only in this version: switching arrives in P4.</p>
  ${grouped(controls, "controls", state)}
</section>
<section id="inventory" aria-labelledby="h-inv">
  <h2 id="h-inv">Inventory</h2>
  <p class="sub">Every item, check, flag and secret, grouped by feature.</p>
  <div class="filters"><input id="q" placeholder="filter by id" value="${esc(filt.q || "")}" aria-label="Filter by id">${chips}</div>
  ${inv.length ? grouped(inv, "inventory", state) : `<div class="empty">No rows match these filters.</div>`}
</section>`;
}
