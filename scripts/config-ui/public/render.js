// HIMMEL-4254 P3/P4: pure rendering, no DOM. render(feed, state) → HTML string.
// state: { open: Set<string>, bundles: { "<region>|<bundle>": { open, rank } }, filt: { health, kind, q, problems }, plans: { [k]: plan } }.
// A toggle in Controls opens a plan: preview (dry-run) → consent → run →
// before/after. Confirm stays disabled until a typed consent matches.
const ST = { ok: "● ok", warn: "◐ warn", fail: "✕ fail", off: "○ off", info: "· info" };
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
    const a = (v) => `data-act="plan" data-k="${esc(`${where}|${r.id}`)}" data-action="${esc(c.action)}" data-target="${esc(c.target)}"${v ? ` data-value="${v}"` : ""}`;
    // The feed does not know a lane's current value, so a lane offers both.
    if (c.action === "config.lanes") return `<button class="btn" ${a("on")}>on</button> <button class="btn" ${a("off")}>off</button>`;
    const v = c.action === "config.initiative" ? (on ? "off" : "on") : "";
    return `<button class="sw" role="switch" aria-checked="${on}" ${a(v)}>${on ? "on" : "off"} <span class="t"></span></button>`;
  }
  if (isCopy(r)) return `<button class="btn" data-act="copy" data-cmd="${esc(remedyOf(r))}">copy · runs in your terminal</button>`;
  return `<span class="ro">⊘ read-only · ${esc(READ_ONLY[c.reason] || c.reason || "probe")}</span>`;
}

function firesText(f) {
  if (!f) return "unverified";
  return f.state === "yes" ? `yes · ${esc(f.at)} · ${esc(f.evidence)}` : esc(f.state);
}

function planHtml(k, p) {
  const dk = `data-k="${esc(k)}"`;
  const cancel = `<button class="btn" data-act="close" ${dk}>${p.stage === "done" || p.stage === "error" ? "close" : "cancel"}</button>`;
  if (p.stage === "loading") return `<div class="plan"><span class="ro">running dry-run…</span></div>`;
  if (p.stage === "running") return `<div class="plan"><span class="ro">running ${esc(p.command)}…</span></div>`;
  if (p.stage === "error") return `<div class="plan"><b>${esc(p.error)}</b>${p.output ? `<pre>${esc(p.output)}</pre>` : ""}${cancel}</div>`;
  if (p.stage === "plan") {
    const typed = p.consent && p.consent.kind === "typed";
    const ok = !typed || p.typed === p.consent.expect;
    return `<div class="plan"><div class="ro">dry-run · nothing has changed</div><pre>$ ${esc(p.command)}\n${esc(p.output)}</pre>
      ${p.bank && p.bank !== "none" ? `<div class="ro">bank: ${esc(p.bank)}</div>` : ""}<div class="ro">takes effect: ${esc(p.effect)}</div>
      ${typed ? `<label>type <b>${esc(p.consent.expect)}</b> to confirm <input data-act="consent" ${dk} value="${esc(p.typed)}" autocomplete="off"></label>` : ""}
      <button class="btn primary" data-act="run" ${dk}${ok ? "" : " disabled"}>confirm</button>${cancel}
      <span class="ro">preview id expires in 5 min</span></div>`;
  }
  const ids = [...new Set([...Object.keys(p.before || {}), ...Object.keys(p.after || {})])];
  const ba = ids.map((id) => {
    const b = (p.before || {})[id] || {}, a = (p.after || {})[id] || {};
    return `<div class="ba"><b>${esc(id)}</b><span>installed ${esc(b.installed)} → ${esc(a.installed)}</span><span>health ${esc(b.health)} → ${esc(a.health)}</span></div>`;
  }).join("");
  return `<div class="plan"><div>${p.rc === 0 ? "✓" : "✕"} ran ${esc(p.command)} · rc=${esc(p.rc)}${p.timedOut ? " · timed out" : ""}</div>${ba}
    ${p.output ? `<pre>${esc(p.output)}</pre>` : ""}<div class="ro">${p.reprobe === "ok" ? "re-probed" : esc(p.reprobe)} · ${p.audit === "failed" ? "<b>audit log append FAILED</b>" : "logged to actions.jsonl"}</div>${cancel}</div>`;
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
  const plan = state.plans && state.plans[k];
  if (plan) h += planHtml(k, plan);
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

// HIMMEL-4379: bundles. Rank is worse-is-higher: fail > warn > ok > off > info
// (ok outranks off: an opt-in left off must not make a working bundle read off).
const ORDER = ["fail", "warn", "ok", "off", "info"];
const RANK = { fail: 4, warn: 3, ok: 2, off: 1, info: 0 };

export function rollup(rows) {
  const r = { fail: 0, warn: 0, ok: 0, off: 0, info: 0, total: rows.length };
  for (const x of rows) if (x.health in RANK) r[x.health]++;
  r.headline = ORDER.find((h) => r[h] > 0) || "info";
  r.rank = RANK[r.headline];
  return r;
}

// The one open/closed decision: Unsorted and a live search force open; else a
// non-stale click override; else open when the base set has a fail or warn.
// A stale override (the bundle got worse since the click) is deleted.
export function isOpen(region, bundleId, baseRows, state, q) {
  if (bundleId === "unsorted" || q) return true;
  const r = rollup(baseRows);
  const bundles = state.bundles || {};
  const k = `${region}|${bundleId}`;
  const o = bundles[k];
  if (o && r.rank > o.rank) delete bundles[k];
  else if (o) return o.open;
  return r.fail + r.warn > 0;
}

function bundleHead(where, b, open, r, shown) {
  const counts = ORDER.filter((h) => r[h] > 0).map((h) => `${r[h]} ${h}`).join(" · ");
  return `<div class="bhead" role="button" tabindex="0" aria-expanded="${open}" data-act="bundle" data-b="${esc(`${where}|${b.id}`)}" data-rank="${r.rank}">
    <span class="chev">${open ? "▾" : "▸"}</span><span class="st ${r.headline}">${ST[r.headline].split(" ")[0]}</span>
    <span class="bt">${esc(b.title)}</span><span class="bc">${counts}</span><span class="bn">${shown === r.total ? r.total : `${shown} of ${r.total}`}</span></div>`;
}

// list = rows the filters let through; base = the region's whole set (rollups
// and default-open read the base, never the filtered view).
function bundled(list, base, where, state, feed, q) {
  const known = feed.bundles ? feed.bundles.filter((b) => b.id !== "unsorted") : [{ id: "all", title: "All rows" }];
  const ids = new Set(known.map((b) => b.id));
  const of = (r) => (feed.bundles ? (ids.has(r.bundle) ? r.bundle : "unsorted") : "all");
  const order = feed.bundles && base.some((r) => of(r) === "unsorted") ? known.concat({ id: "unsorted", title: "Unsorted" }) : known;
  return order.map((b) => {
    const rs = list.filter((r) => of(r) === b.id);
    if (!rs.length) return "";
    const bs = base.filter((r) => of(r) === b.id);
    const open = isOpen(where, b.id, bs, state, q);
    return `<div class="bundle">${bundleHead(where, b, open, rollup(bs), rs.length)}${open ? rs.map((r) => rowHtml(r, where, state)).join("") : ""}</div>`;
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
  const inv = rows.filter((r) => (!filt.health || r.health === filt.health) && (!filt.kind || kindOf(r) === filt.kind) && (!q || r.id.toLowerCase().includes(q)) && (!filt.problems || isTriage(r)));
  const empty = !q && filt.problems && !filt.health && !filt.kind ? "Nothing failing or drifting." : "No rows match these filters.";
  const prob = `<button class="sw" role="switch" aria-checked="${filt.problems === true}" data-act="problems">show only problems <span class="t"></span></button>`;
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
  <p class="sub">Everything that can be switched. Every switch previews its dry-run first; nothing changes until you confirm.</p>
  ${bundled(controls, controls, "controls", state, feed, "")}
</section>
<section id="inventory" aria-labelledby="h-inv">
  <h2 id="h-inv">Inventory</h2>
  <p class="sub">Every item, check, flag and secret, grouped by feature.</p>
  <div class="filters"><input id="q" placeholder="filter by id" value="${esc(filt.q || "")}" aria-label="Filter by id">${prob}${chips}</div>
  ${inv.length ? bundled(inv, rows, "inventory", state, feed, q) : `<div class="empty">${empty}</div>`}
</section>`;
}
