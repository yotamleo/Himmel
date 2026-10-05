// HIMMEL-4405 PR-b: the Health page. Pure rendering, no DOM: renderHealth(feed, health) → HTML.
// feed = the doctor feed (null until it lands); health = GET /api/health ({bank, legs, monitoring}),
// null while loading. Every value shown comes from its owner (I1): the feed's rows, the bank ledger
// row, legs.sh, Prometheus. The one verdict lives here (I6) and only counts what those sources say.
import { esc } from "./render.js";

const isTriage = (r) => r.health === "fail" || r.health === "warn";
const ok = (s) => s && s.state === "ok";

// The firing alerts, or null when Prometheus was not reachable (alerts not checked, never a verdict input).
const alertsOf = (health) => (health && health.monitoring && ok(health.monitoring.prometheus) ? health.monitoring.prometheus.alerts || [] : null);

// feed null = pending: "No data". fail or a firing page alert: "Act now". warn or any firing alert:
// "Needs a look". Else "All clear". An absent Prometheus never raises it.
export function verdict(feed, health) {
  if (!feed) return { word: "No data", cls: "off", fail: 0, warn: 0, alerts: alertsOf(health) };
  const rows = feed.rows || [];
  const fail = rows.filter((r) => r.health === "fail").length;
  const warn = rows.filter((r) => r.health === "warn").length;
  const alerts = alertsOf(health);
  const page = (alerts || []).some((a) => a.severity === "page");
  const word = fail > 0 || page ? "Act now" : warn > 0 || (alerts || []).length > 0 ? "Needs a look" : "All clear";
  return { word, cls: { "Act now": "fail", "Needs a look": "warn", "All clear": "ok" }[word], fail, warn, alerts };
}

const nodata = (what) => `<div class="nodata">No data: ${esc(what)}</div>`;
const section = (id, title, sub, body) => `<section id="${id}" aria-labelledby="h-${id}"><h2 id="h-${id}">${esc(title)}</h2><p class="sub">${esc(sub)}</p>${body}</section>`;

function verdictHtml(feed, health) {
  const v = verdict(feed, health);
  const inputs = !feed ? "the doctor feed is still running" : `${v.fail} fail · ${v.warn} warn · ${v.alerts ? `alerts: ${v.alerts.length} firing` : "alerts not checked"}`;
  const m = health && health.monitoring;
  // Each source's failure shows on its own: a responding exporter makes the roll-up "ok" while Prometheus errors.
  const srcErrs = ["prometheus", "exporter"].filter((k) => m && m[k] && m[k].state === "error")
    .map((k) => `<div class="nodata">monitoring ${k} unreachable: ${esc(m[k].reason || "no answer")}</div>`).join("");
  const mon = m && m.state === "absent" ? `<div class="nodata">monitoring tier not running</div>`
    : srcErrs || (m && m.state === "error" ? `<div class="nodata">monitoring unreachable: ${esc(m.reason || "no answer")}</div>` : "");
  return `<div class="vhead"><span class="word st ${v.cls}">${esc(v.word)}</span><span class="inputs">${esc(inputs)}</span>
    <button class="btn" data-act="refresh-health">refresh</button></div>${mon}`;
}

function brokenHtml(feed, health) {
  if (!feed) return nodata("the doctor feed is still running");
  const rows = (feed.rows || []).filter(isTriage).sort((a, b) => (a.health === "fail" ? 0 : 1) - (b.health === "fail" ? 0 : 1));
  const alerts = alertsOf(health) || [];
  const rowsHtml = rows.map((r) => {
    const remedy = (r.fix && r.fix.remedy) || "";
    return `<div class="hrow"><span class="st ${esc(r.health)}">${esc(r.health)}</span><span class="id">${esc(r.id)}</span>
      <span class="det">${esc(r.installed && r.installed.detail)}</span>
      ${remedy ? `<code class="remedy">${esc(remedy)}</code><button class="btn" data-act="copy" data-cmd="${esc(remedy)}">copy · runs in your terminal</button>` : ""}
      <button class="btn" data-act="open-config" data-id="${esc(r.id)}">Open in Config</button></div>`;
  }).join("");
  const alertsHtml = alerts.map((a) => `<div class="alert"><span class="st ${a.severity === "page" ? "fail" : "warn"}">${esc(a.severity || "alert")}</span><b>${esc(a.alertname)}</b> <span class="det">${esc(a.summary)}</span></div>`).join("");
  return rowsHtml + alertsHtml || `<div class="empty">Nothing broken.</div>`;
}

function jobsHtml(feed) {
  if (!feed) return nodata("the doctor feed is still running");
  const jobs = (feed.rows || []).filter((r) => r.source === "cadence");
  if (!jobs.length) return `<div class="empty">No scheduled jobs are declared.</div>`;
  return jobs.map((r) => {
    const f = r.fires;
    return `<div class="hrow"><span class="st ${esc(r.health)}">${esc(r.health)}</span><span class="id">${esc(r.id.replace(/^cadence:/, ""))}</span>
      <span class="det">${esc(r.installed && r.installed.detail)}</span>
      <span class="ro">${f && f.state === "yes" ? `last fired ${esc(f.at)} · ${esc(f.evidence)}` : esc(f ? f.state : "unverified")}</span></div>`;
  }).join("");
}

function bankHtml(health) {
  const b = health && health.bank;
  let body;
  if (!health) body = nodata("loading");
  else if (b.state === "ok") {
    const r = b.row;
    body = `<div class="kv"><b>${esc(r.verdict)}</b> · five_hour ${esc(r.five_hour)} % · seven_day ${esc(r.seven_day)} %${r.degraded ? " · degraded" : ""}</div>
      <div class="ro">${esc(r.ts)}${r.age !== "" && r.age != null ? ` · ${esc(r.age)} min old` : ""} · read from the bank-preflight ledger, never re-measured here</div>`;
  } else body = nodata(b.reason || "no bank-preflight ledger");
  return `<div class="card" id="bank"><h3>Last bank preflight</h3>${body}</div>`;
}

function legsHtml(health) {
  const l = health && health.legs;
  let body;
  if (!health) body = nodata("loading");
  else if (l.state === "ok") {
    body = l.legs.length ? l.legs.map((x) => `<div class="leg"><span class="mk">${esc(x.status)}</span><span class="doc" title="${esc(x.doc)}">${esc(String(x.doc).split("/").pop())}</span></div>`).join("") : `<div class="empty">The fleet manifest lists no legs.</div>`;
  } else body = nodata(l.state === "absent" ? `no fleet manifest (${l.reason || "none found"})` : l.reason || "legs view failed");
  return `<div class="card" id="legs"><h3>Legs</h3>${body}</div>`;
}

function searchHtml(feed) {
  if (!feed) return nodata("the doctor feed is still running");
  const rows = (feed.rows || []).filter((r) => r.bundle === "search");
  if (!rows.length) return nodata("doctor reports no search rows");
  return rows.map((r) => `<div class="hrow"><span class="st ${esc(r.health)}">${esc(r.health)}</span><span class="id">${esc(r.id)}</span><span class="det">${esc(r.installed && r.installed.detail)}</span></div>`).join("");
}

export function renderHealth(feed, health) {
  return [
    section("verdict", "Is himmel healthy?", "One word, from the doctor feed and any firing alerts.", verdictHtml(feed, health)),
    section("broken", "What is broken, and what do I do", "Failing and drifting rows, worst first, with the fix to run in your terminal.", brokenHtml(feed, health)),
    section("jobs", "Scheduled jobs", "Cadence jobs as the doctor reports them.", jobsHtml(feed)),
    section("legs-bank", "Legs and the usage bank", "Read-only: the newest bank-preflight ledger row and each leg's last marker.", bankHtml(health) + legsHtml(health)),
    section("search", "Search and graph freshness", "From the doctor's search rows.", searchHtml(feed)),
  ].join("\n");
}
