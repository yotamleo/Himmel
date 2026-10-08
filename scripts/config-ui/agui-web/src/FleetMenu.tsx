// HIMMEL-4808: console pages and session drill-ins use the same fleet snapshot and run links.
// HIMMEL-4925: the menu is one collapsible block, closed by default at phone width so the fleet is the first screen;
// finished consoles fold into their own closed list under the live ones.
import { consoleGroups, orphanReason, rowHref, useOpen, visibleRows, type FleetState, type Row } from "./Fleet";
import { isLive } from "./fleet-model";
import { consoleHash } from "./stream";

function SessionLink({ row, token }: { row: Row; token: string }) {
  const href = rowHref(token, row);
  return href ? <a href={href}>{row.name}</a> : <span>{row.name} (no journal)</span>;
}

const phone = () => { try { return window.matchMedia("(max-width: 760px)").matches; } catch { return false; } };

export function FleetMenu({ state, token, selected }: { state: FleetState; token: string; selected: string | null }) {
  const [open, setOpen] = useOpen(phone() ? "menu:phone" : "menu", !phone());
  const rows = visibleRows(state.fleet?.sessions ?? []);
  const orphans = rows.filter((r) => orphanReason(r, rows));
  const groups = consoleGroups(rows);
  const live = groups.filter((g) => isLive(g.console)), done = groups.filter((g) => !isLive(g.console));
  const ungroupedWrapped = rows.filter((r) => r.state === "wrapped" && r.role !== "console" && !groups.some((g) => g.rows.includes(r)));
  const group = (g: (typeof groups)[number]) => <details key={g.console.name} open={isLive(g.console)}>
    <summary><a className="console-page" href={consoleHash(token, g.console.name)} aria-current={selected === g.console.name ? "page" : undefined}>{g.console.name}</a></summary>
    <SessionLink row={g.console} token={token} />
    <ul>{g.rows.filter((r) => r.state !== "wrapped").map((r) => <li key={r.name}><SessionLink row={r} token={token} /><small>{r.role} · {r.lane ?? "native"}</small></li>)}</ul>
    {g.rows.some((r) => r.state === "wrapped") && <details className="fleet-menu-wrapped"><summary>Wrapped</summary>
      <ul>{g.rows.filter((r) => r.state === "wrapped").map((r) => <li key={r.name}><SessionLink row={r} token={token} /></li>)}</ul>
    </details>}
  </details>;
  return <nav className="fleet-menu" aria-label="Consoles">
    <details className="fleet-menu-all" open={open} onToggle={(e) => setOpen(e.currentTarget.open)}>
      <summary><h2>{`Consoles (${live.length} running · ${done.length} finished)`}</h2></summary>
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
