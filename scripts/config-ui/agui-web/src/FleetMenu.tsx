// HIMMEL-4808: console pages and session drill-ins use the same fleet snapshot and run links.
import { consoleGroups, orphanReason, rowHref, visibleRows, type FleetState, type Row } from "./Fleet";
import { consoleHash } from "./stream";

function SessionLink({ row, token }: { row: Row; token: string }) {
  const href = rowHref(token, row);
  return href ? <a href={href}>{row.name}</a> : <span>{row.name} (no journal)</span>;
}

export function FleetMenu({ state, token, selected }: { state: FleetState; token: string; selected: string | null }) {
  const rows = visibleRows(state.fleet?.sessions ?? []);
  const orphans = rows.filter((r) => orphanReason(r, rows));
  const groups = consoleGroups(rows);
  const ungroupedWrapped = rows.filter((r) => r.state === "wrapped" && r.role !== "console" && !groups.some((g) => g.rows.includes(r)));
  return <nav className="fleet-menu" aria-label="Consoles">
    <h2>Consoles</h2>
    {groups.map((g) => <details key={g.console.name} open={g.console.live !== false && g.console.state !== "wrapped"}>
      <summary><a className="console-page" href={consoleHash(token, g.console.name)} aria-current={selected === g.console.name ? "page" : undefined}>{g.console.name}</a></summary>
      <SessionLink row={g.console} token={token} />
      <ul>{g.rows.filter((r) => r.state !== "wrapped").map((r) => <li key={r.name}><SessionLink row={r} token={token} /><small>{r.role} · {r.lane ?? "native"}</small></li>)}</ul>
      {g.rows.some((r) => r.state === "wrapped") && <details className="fleet-menu-wrapped"><summary>Wrapped</summary>
        <ul>{g.rows.filter((r) => r.state === "wrapped").map((r) => <li key={r.name}><SessionLink row={r} token={token} /></li>)}</ul>
      </details>}
    </details>)}
    {ungroupedWrapped.length > 0 && <details className="fleet-menu-wrapped"><summary>Wrapped</summary>
      <ul>{ungroupedWrapped.map((r) => <li key={r.name}><SessionLink row={r} token={token} /></li>)}</ul>
    </details>}
    {orphans.length > 0 && <section aria-label="Orphans"><h2>Orphans</h2><ul>{orphans.map((r) => <li key={r.name}>
      <SessionLink row={r} token={token} /><small>{orphanReason(r, rows)} — adopt via relay / close</small>
    </li>)}</ul></section>}
  </nav>;
}
