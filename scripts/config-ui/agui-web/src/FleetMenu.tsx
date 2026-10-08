// HIMMEL-4808: console pages and session drill-ins use the same fleet snapshot and run links.
// HIMMEL-4925: the menu is one collapsible block, closed by default at phone width so the fleet is the first screen.
// Its filters (lane, state, text, finished inline) narrow every section of the fleet page and are kept per viewer;
// each live console shows its running / waiting / attention / orphan counts, and finished consoles fold under them.
import { consoleGroups, EMPTY_FILTERS, filtering, orphanReason, rowHref, useFilters, useOpen, visibleRows, type FleetState, type Row, type ViewFilters } from "./Fleet";
import { fleetSections, isLive, laneOf, NO_FILTERS, type ProcessOrphan } from "./fleet-model";
import { consoleHash } from "./stream";

function SessionLink({ row, token }: { row: Row; token: string }) {
  const href = rowHref(token, row);
  return href ? <a href={href}>{row.name}</a> : <span>{row.name} (no journal)</span>;
}

const phone = () => { try { return window.matchMedia("(max-width: 760px)").matches; } catch { return false; } };
const LANES = ["native", "claudex", "cloud"];
const STATES: [string, string][] = [["running", "running"], ["waiting", "waiting"], ["idle", "idle"], ["attention", "attention"], ["orphaned", "orphaned"]];
const toggle = (list: string[], v: string) => (list.includes(v) ? list.filter((x) => x !== v) : [...list, v]);

function FilterBlock({ rows, procs }: { rows: Row[]; procs: ProcessOrphan[] | null | undefined }) {
  const [f, set] = useFilters();
  const all = fleetSections(rows, null, NO_FILTERS, procs ?? []);
  const live = rows.filter((r) => isLive(r));
  const n: Record<string, number> = {
    native: live.filter((r) => laneOf(r) === "native").length, claudex: live.filter((r) => laneOf(r) === "claudex").length, cloud: live.filter((r) => laneOf(r) === "cloud").length,
    running: all.counts.running, waiting: all.counts.waiting, attention: all.counts.attention, orphaned: all.counts.orphaned,
    idle: all.running.flatMap((g) => g.rows).filter((r) => r.state === "idle" || r.state === "unknown").length,
  };
  const chip = (v: string, label: string, on: boolean, flip: (f: ViewFilters) => ViewFilters) =>
    <button type="button" key={v} className={`fleet-chip-btn${on ? " on" : ""}`} aria-pressed={on} onClick={() => set(flip(f))}>{label}{v in n && <span className="fleet-count">{n[v]}</span>}</button>;
  return <div className="fleet-filters" role="group" aria-label="Filters">
    <h2>Filter</h2>
    <input className="fleet-search" type="search" value={f.text} placeholder="ticket, leg id or slug" aria-label="Filter by ticket, leg id or slug"
      onChange={(e) => set({ ...f, text: e.currentTarget.value })} />
    <div className="fleet-chips" aria-label="Lane">{LANES.map((l) => chip(l, l, f.lanes.includes(l), (x) => ({ ...x, lanes: toggle(x.lanes, l) })))}</div>
    <div className="fleet-chips" aria-label="State">{STATES.map(([v, label]) => chip(v, label, f.states.includes(v), (x) => ({ ...x, states: toggle(x.states, v) })))}</div>
    <div className="fleet-chips">{chip("finished-inline", "show finished inline", f.finished, (x) => ({ ...x, finished: !x.finished }))}</div>
    {(filtering(f) || f.finished) && <button type="button" className="fleet-clear" onClick={() => set(EMPTY_FILTERS)}>clear filters</button>}
  </div>;
}

export function FleetMenu({ state, token, selected }: { state: FleetState; token: string; selected: string | null }) {
  const [open, setOpen] = useOpen(phone() ? "menu:phone" : "menu", !phone());
  const sessions = state.fleet?.sessions ?? [];
  const rows = visibleRows(sessions);
  const orphans = rows.filter((r) => orphanReason(r, rows));
  const groups = consoleGroups(rows);
  const live = groups.filter((g) => isLive(g.console)), done = groups.filter((g) => !isLive(g.console));
  const ungroupedWrapped = rows.filter((r) => r.state === "wrapped" && r.role !== "console" && !groups.some((g) => g.rows.includes(r)));
  const all = fleetSections(sessions, null, NO_FILTERS, state.fleet?.processOrphans ?? []);
  const counts = (name: string) => {
    const c = fleetSections(sessions, name, NO_FILTERS, state.fleet?.processOrphans ?? []).counts;
    return [`${c.running} running`, c.waiting > 0 && `${c.waiting} waiting`, c.attention > 0 && `${c.attention} attention`, c.orphaned > 0 && `${c.orphaned} orphaned`].filter(Boolean).join(" · ");
  };
  const group = (g: (typeof groups)[number]) => <details key={g.console.name} open={isLive(g.console)}>
    <summary><a className="console-page" href={consoleHash(token, g.console.name)} aria-current={selected === g.console.name ? "page" : undefined}>{g.console.name}</a></summary>
    {isLive(g.console) && <small className="fleet-console-counts">{counts(g.console.name)}</small>}
    <SessionLink row={g.console} token={token} />
    <ul>{g.rows.filter((r) => r.state !== "wrapped").map((r) => <li key={r.name}><SessionLink row={r} token={token} /><small>{r.role} · {r.lane ?? "native"}</small></li>)}</ul>
    {g.rows.some((r) => r.state === "wrapped") && <details className="fleet-menu-wrapped"><summary>Wrapped</summary>
      <ul>{g.rows.filter((r) => r.state === "wrapped").map((r) => <li key={r.name}><SessionLink row={r} token={token} /></li>)}</ul>
    </details>}
  </details>;
  return <nav className="fleet-menu" aria-label="Consoles">
    <details className="fleet-menu-all" open={open} onToggle={(e) => setOpen(e.currentTarget.open)}>
      <summary><h2>{`Filters · Consoles (${live.length} running · ${done.length} finished)`}</h2>
        {all.counts.orphaned > 0 && <span className="fleet-orphan-count">{` · ${all.counts.orphaned} orphaned`}</span>}</summary>
      <FilterBlock rows={sessions} procs={state.fleet?.processOrphans} />
      <h2>Consoles</h2>
      {live.map(group)}
      {done.length > 0 && <details className="fleet-menu-finished"><summary>{`Finished consoles (${done.length})`}</summary>{done.map(group)}</details>}
      {ungroupedWrapped.length > 0 && <details className="fleet-menu-wrapped"><summary>Wrapped</summary>
        <ul>{ungroupedWrapped.map((r) => <li key={r.name}><SessionLink row={r} token={token} /></li>)}</ul>
      </details>}
      {orphans.length > 0 && <section aria-label="Orphans"><h2>Orphans</h2><ul>{orphans.map((r) => <li key={r.name}>
        <SessionLink row={r} token={token} /><small>{orphanReason(r, rows)} — adopt via relay / close</small>
      </li>)}</ul></section>}
    </details>
  </nav>;
}
