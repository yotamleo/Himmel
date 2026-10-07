// HIMMEL-4816: rendering only. Counts, rates, trend geometry and lane deltas are server-owned.
import { esc } from "./render.js";
const pct = (v) => typeof v === "number" ? `${(v * 100).toFixed(1)} %` : "—";
const count = (v) => typeof v === "number" ? String(v) : "—";
const table = (head, rows) => `<div style="overflow-x:auto"><table><thead><tr>${head.map((h) => `<th>${esc(h)}</th>`).join("")}</tr></thead><tbody>${rows.join("")}</tbody></table></div>`;
function spark(t) {
  return `<svg width="120" height="28" viewBox="0 0 120 28" role="img" aria-label="Daily failure rate; gaps mean no denominator">${(t || []).map((p) => p.height == null ? "" : `<rect x="${p.x}" y="${26 - p.height}" width="2" height="${Math.max(1, p.height)}" fill="currentColor"><title>${esc(p.day)}: ${pct(p.rate)}</title></rect>`).join("")}</svg>`;
}
function drill(r, token) {
  const links = (r.sessions || []).filter((s) => /^[0-9a-f-]{36}$/.test(s)).map((s) => `<a href="/agui/#${esc(new URLSearchParams({ t: token, run: s }).toString())}">${esc(s)}</a>`);
  return `<details><summary>${links.length} sessions</summary>${links.join("<br>")}<p>Tool call ids: ${(r.tool_call_ids || []).map(esc).join(", ") || "—"}</p></details>`;
}
function filters(data) {
  return ["model", "lane", "role", "days"].map((name) => {
    const values = name === "days" ? ["7", "30"] : data.filters?.[{ model: "models", lane: "lanes", role: "roles" }[name]] || [];
    const selected = String(data.selected?.[name] || "");
    return `<label>${esc(name)} <select data-tool-filter="${name}">${name === "days" ? "" : '<option value="">All</option>'}${values.map((v) => `<option value="${esc(v)}"${String(v) === selected ? " selected" : ""}>${esc(v)}</option>`).join("")}</select></label>`;
  }).join(" ");
}
export function renderToolHealth(data, token = "") {
  const header = `<h2>Tool health</h2><p class="sub">Read-only · daily model / lane / leg-vs-console rollups · missing denominators are —, never 0 %. <a href="#/toolhealth">Tool health</a> · <a href="/#${esc(new URLSearchParams({ t: token, page: "toolhealth" }).toString())}">Link to this page</a></p>`;
  if (!data || data.state !== "ok") return `<section>${header}<div>${filters(data || { selected: { days: 7 } })}</div><p class="nodata">${data?.state === "error" ? "Tool health unavailable: endpoint unreachable" : "No data: no leg digest ledger rows in this period"}</p><button data-act="refresh-toolhealth">Refresh</button></section>`;
  const tools = (data.tools || []).map((r) => `<tr><td>${esc(r.tool)}</td><td>${count(r.calls)}</td><td>${count(r.failures)}</td><td>${pct(r.rate)}</td><td>${pct(r.error_rate)}</td><td>${pct(r.recovery_rate)}</td><td>${spark(r.trend)}</td><td>${(r.classes || []).slice(0, 3).map((c) => `${esc(c.class)} (${count(c.count)})`).join("<br>") || "—"}</td><td>${drill(r, token)}</td></tr>`);
  const hooks = (data.hooks || []).map((r) => `<tr><td>${esc(r.class)}</td><td>${count(r.calls)}</td><td>${count(r.failures)}</td><td>${pct(r.rate)}</td><td>${pct(r.recovery_rate)}</td><td>${drill(r, token)}</td></tr>`);
  const lanes = data.filters?.lanes || [];
  const comparison = (data.comparison || []).map((r) => `<tr><td>${esc(r.metric)} · ${esc(r.key)}</td>${lanes.map((lane) => {
    const n = r.values[lane], delta = r.delta[lane];
    const fmt = (v) => r.metric === "calls_per_100" ? typeof v === "number" ? v.toFixed(1) : "—" : pct(v);
    return `<td>${fmt(n)}</td><td>${fmt(delta)}</td>`;
  }).join("")}</tr>`);
  return `<section>${header}<div>${filters(data)} <button data-act="refresh-toolhealth">Refresh</button></div><p class="sub">Recovery: count-weighted known class outcomes only; unknown outcomes are excluded. Trend gaps have no call denominator.</p>${table(["Tool", "Calls", "Failures", "Rate", "Error rate", "Recovery", `${data.selected.days}-day trend`, "Top failure classes", "Drill-down"], tools)}<h3>Deny hooks ÷ Bash calls</h3>${table(["Hook", "Bash calls", "Denials", "Rate", "Recovery", "Sessions"], hooks)}<h3>Lane comparison</h3><p class="sub">All lanes for the selected model and role. Δ is relative to native; rate deltas are percentage points. No native denominator means no delta.</p>${table(["Metric / tool", ...lanes.flatMap((l) => [l, "Δ native"])], comparison)}</section>`;
}
