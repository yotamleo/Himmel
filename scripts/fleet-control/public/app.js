async function json(path) {
  const res = await fetch(path);
  if (!res.ok) throw new Error(`${path} returned ${res.status}`);
  return res.json();
}

function cell(text) {
  const td = document.createElement("td");
  td.textContent = text == null ? "" : String(text);
  return td;
}

function renderFleet(doc) {
  const body = document.querySelector("#fleet-table tbody");
  body.replaceChildren();
  const head = document.createElement("tr");
  for (const h of ["lane", "worker", "status", "branch", "last line", "artifacts"]) head.appendChild(cell(h));
  body.appendChild(head);
  for (const [lane, workers] of Object.entries(doc.lanes || {})) {
    for (const w of workers) {
      const tr = document.createElement("tr");
      tr.append(cell(lane), cell(w.name), cell(w.status), cell(w.branch), cell(w.lastOutboxLine ? JSON.stringify(w.lastOutboxLine) : ""), cell((w.artifacts || []).join("\n")));
      body.appendChild(tr);
    }
  }
  document.querySelector("#gauges").textContent = JSON.stringify(doc.feeds || {}, null, 2);
}

function renderEscalations(rows, parseErrors) {
  const body = document.querySelector("#escalations-table tbody");
  body.replaceChildren();
  const note = document.querySelector("#escalation-parse-errors");
  if (note) note.textContent = parseErrors > 0 ? `${parseErrors} unparsed escalation record(s) — grant view may be incomplete` : "";
  const head = document.createElement("tr");
  for (const h of ["id", "shape", "capability", "step", "actions"]) head.appendChild(cell(h));
  body.appendChild(head);
  for (const e of rows) {
    const tr = document.createElement("tr");
    tr.append(cell(e.escalation_id), cell(e.shape), cell(e.capability), cell(e.step));
    const td = document.createElement("td");
    const grant = document.createElement("button"); grant.textContent = "grant"; grant.disabled = true;
    const refuse = document.createElement("button"); refuse.textContent = "refuse"; refuse.disabled = true;
    td.append(grant, " ", refuse); tr.appendChild(td); body.appendChild(tr);
  }
}

async function refetch() {
  const [fleet, escalations] = await Promise.all([json("/fleet"), json("/escalations")]);
  renderFleet(fleet);
  renderEscalations((escalations && escalations.escalations) || [], (escalations && escalations.parseErrors) || 0);
}

refetch().catch((e) => { document.querySelector("#gauges").textContent = String(e); });
if (typeof EventSource !== "undefined") {
  const events = new EventSource("/events");
  events.addEventListener("refetch", () => refetch().catch(console.error));
  events.addEventListener("degraded", (ev) => {
    let reason = "live updates unavailable";
    try { reason = (JSON.parse(ev.data) || {}).reason || reason; } catch (_) { /* keep default */ }
    const banner = document.querySelector("#stale-banner");
    banner.textContent = "Live updates unavailable - view may be stale: " + reason;
    banner.style.display = "block";
  });
}
