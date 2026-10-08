// HIMMEL-4751: the live rows render as a tree under the operator (a leg under its console, a console beside the one
// it succeeded), each with its subagents, context fill and token usage; a parent or successor name jumps to its row.
// HIMMEL-4791: a cloud session (no local process) is a row of role "cloud" under its console, with its local
// shepherd leg under it: its PR, its CLOUD-DONE phase and session link, and tokens said to be not measured.
// HIMMEL-4712: the fleet landing — /agui/ with a token and no run. Every live session (consoles, legs, judges,
// interactive sessions) from GET /api/agui/fleet, polled; a row opens that session's run stream. Wrapped legs sit
// in their own closed section and are never shown as running. HIMMEL-4711: a leg's row also links to the
// console's Health page, whose legs card reads the same handover docs.
import { useEffect, useState } from "react";
// @ts-expect-error: plain ES module shared with the console (no types).
import { pageHref } from "../../public/nav.js";
import { FLEET_URL } from "./stream";
import { consoleName, isLive, rowHref, orphanReason, visibleRows, consoleGroups, type Row } from "./fleet-model";
export { rowHref, orphanReason, visibleRows, consoleGroups, type Row } from "./fleet-model";
type Node = { row: Row; kids: Node[] };

// HIMMEL-4751: the live rows as a tree under the operator: a row whose parent is a live row sits under it, the
// rest are roots. A parent link that loops (two docs naming each other) still places every row exactly once.
function forest(rows: Row[]): Node[] {
  const live = new Set(rows.map((r) => r.name));
  const placed = new Set<Row>();
  const grow = (r: Row): Node => {
    placed.add(r);
    return { row: r, kids: rows.filter((k) => k.parent === r.name && !placed.has(k)).map(grow) };
  };
  const out = rows.filter((r) => !r.parent || !live.has(r.parent)).map(grow);
  for (const r of rows) if (!placed.has(r)) out.push(grow(r));
  return out;
}

const k = (n: number) => (n >= 1e6 ? `${(n / 1e6).toFixed(1)}M` : n >= 1e3 ? `${(n / 1e3).toFixed(1)}k` : String(n));
type Fleet = { census: "ok" | "degraded" | "unavailable"; generatedAt: number; sessions: Row[] };

const POLL_MS = 5000;
const ORDER: Record<string, number> = { console: 0, judge: 1, cloud: 2, leg: 2, interactive: 3 };
const CLS: Record<Row["state"], string> = { running: "running", idle: "idle", "waiting for GO": "waiting", wrapped: "finished", unknown: "idle" };

const ago = (ms: number) => {
  const s = Math.max(0, Math.round(ms / 1000));
  return s < 60 ? `${s}s ago` : s < 3600 ? `${Math.floor(s / 60)}m ago` : `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m ago`;
};

export type FleetState = { fleet: Fleet | null; error: string | null };

// HIMMEL-4711: polled once for the page (the rail's Fleet dot reads it on every page, the fleet list on this one).
export function useFleet(token: string | null): FleetState {
  const [st, setSt] = useState<FleetState>({ fleet: null, error: null });
  useEffect(() => {
    if (!token) return;
    let live = true, timer: ReturnType<typeof setTimeout> | undefined;
    const poll = async () => {
      try {
        const r = await fetch(FLEET_URL, { headers: { "X-Himmel-Token": token }, cache: "no-store" });
        if (!r.ok) throw new Error(r.status === 401 ? "the token was refused" : `the server answered ${r.status}`);
        const f = (await r.json()) as Fleet;
        if (live) setSt({ fleet: f, error: null });
      } catch (e) { if (live) setSt((s) => ({ ...s, error: String((e as Error).message ?? e) })); }
      if (live) timer = setTimeout(poll, POLL_MS);
    };
    poll();
    return () => { live = false; clearTimeout(timer); };
  }, [token]);
  return st;
}

export function FleetPage({ token, state, console: selected = null }: { token: string; state: FleetState; console?: string | null }) {
  const { fleet, error } = state;
  const [now, setNow] = useState(Date.now());

  useEffect(() => {
    const tick = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(tick);
  }, []);

  const all = visibleRows(fleet?.sessions ?? []);
  const rows = all.filter((r) => !selected || r.name === selected || consoleName(r) === selected)
    .sort((a, b) => (ORDER[a.role] ?? 9) - (ORDER[b.role] ?? 9) || a.name.localeCompare(b.name));
  const open = rows.filter(isLive);
  const wrapped = rows.filter((r) => r.state === "wrapped");
  const groups = consoleGroups(all).filter((g) => !selected || g.console.name === selected);
  const orphans = rows.filter((r) => orphanReason(r, all));
  return (
    <>
      <header className="top">
        <span className="brand">himmel</span>
        <span className="run">{selected ?? "fleet"}</span>
        <span className={`state ${error ? "error" : fleet ? "running" : "idle"}`} role="status">{error ? "stopped" : fleet ? "live" : "connecting"}</span>
        {fleet && <span className="meta">{`${open.length} live · ${wrapped.length} wrapped · updated ${ago(now - fleet.generatedAt)}`}</span>}
      </header>
      <main className="fleet" aria-label="Fleet">
        {error && <p className="run-error" role="alert">The fleet view stopped: {error}.</p>}
        {fleet?.census === "unavailable" && <p className="run-error" role="alert">The process census failed: this list is not the fleet.</p>}
        {fleet?.census === "degraded" && <p className="quiet">Some sessions could not be read; the list may be incomplete.</p>}
        {fleet && open.length === 0 && fleet.census !== "unavailable" && <p className="quiet">No live sessions.</p>}
        {selected && groups.length === 0 && <p className="quiet">Console not found: {selected}</p>}
        {groups.map((g) => (
          <section className="fleet-console" key={g.console.name} aria-label={g.console.name}>
            <h2>{g.console.name}</h2>
            <FleetRow row={g.console} live={all} token={token} now={now} />
            <FleetMembers rows={g.rows} live={all} token={token} now={now} />
          </section>
        ))}
        {orphans.length > 0 && <section className="fleet-orphans" aria-label="Orphans">
          <h2>Orphans</h2>
          <p className="quiet">Adopt via relay, or close the session.</p>
          <ul className="fleet-rows">{orphans.map((r) => <li key={r.name}>
            <span className="fleet-orphan-cause">{orphanReason(r, all)} — adopt via relay / close</span>
            <FleetRow row={r} live={all} token={token} now={now} />
          </li>)}</ul>
        </section>}
        <FleetMembers rows={wrapped.filter((r) => r.role !== "console" && !groups.some((g) => g.rows.includes(r)))} live={all} token={token} now={now} />
      </main>
    </>
  );
}

function FleetMembers({ rows, live, token, now }: { rows: Row[]; live: Row[]; token: string; now: number }) {
  const open = rows.filter((r) => r.state !== "wrapped");
  const wrapped = rows.filter((r) => r.state === "wrapped");
  return <>
    {open.length > 0 && <ul className="fleet-rows fleet-tree" aria-label="Live sessions">{forest(open).map((n) => <FleetNode key={n.row.name} node={n} live={live} token={token} now={now} />)}</ul>}
    {wrapped.length > 0 && <details className="fleet-closed">
      <summary>{`Wrapped (${wrapped.length})`}</summary>
      <ul className="fleet-rows" aria-label="Wrapped sessions">{wrapped.map((r) => <li key={r.name}><FleetRow row={r} live={live} token={token} now={now} /></li>)}</ul>
    </details>}
  </>;
}

function FleetNode({ node, live, token, now }: { node: Node; live: Row[]; token: string; now: number }) {
  return (
    <li className="fleet-node">
      <FleetRow row={node.row} live={live} token={token} now={now} />
      {node.kids.length > 0 && (
        <ul className="fleet-rows fleet-kids" aria-label={`Under ${node.row.name}`}>
          {node.kids.map((n) => <FleetNode key={n.row.name} node={n} live={live} token={token} now={now} />)}
        </ul>
      )}
    </li>
  );
}

// A row's anchor is its name (a cloud row has no pid); the census and cloud names are plain, id-safe text.
const rowId = (name: string) => `fleet-${name}`;

// A link to another session's row when it is live (the hash is the router's, so this scrolls instead), else its name.
function Rel({ name, live }: { name: string; live: Row[] }) {
  const r = live.find((x) => x.name === name);
  if (!r) return <span title="not a live session">{`${name} (not live)`}</span>;
  return (
    <button type="button" className="fleet-rel" onClick={() => {
      const el = document.getElementById(rowId(r.name));
      el?.scrollIntoView({ block: "center" });
      el?.focus();
    }}>{name}</button>
  );
}

// HIMMEL-4751: context fill against the session's ceiling, then the cumulative tokens and their cost-eq.
function usageText(u: NonNullable<Row["usage"]>): string {
  const fill = u.fill === null ? "context not measured" : `context ${u.fill}% of ${k(u.ceiling)} (${u.ceilingFrom === "autocompact" ? "autocompact" : "model window"})`;
  return `${fill} · ${u.calls} call${u.calls === 1 ? "" : "s"} · in ${k(u.input)} · out ${k(u.output)} · cache read ${k(u.cacheRead)} · cache write ${k(u.cacheCreate)} · cost-eq ${k(u.costEq)}`;
}

// HIMMEL-4791: what the cloud session last reported on its PR (the brief's CLOUD-DONE / CLOUD-BLOCKED comment).
const PHASE: Record<NonNullable<Row["cloud"]>["phase"], string> = {
  working: "no CLOUD-DONE yet", done: "CLOUD-DONE, shepherd's turn", blocked: "CLOUD-BLOCKED: a question on the PR",
  merged: "PR merged", closed: "PR closed", unknown: "GitHub status unknown (read failed or throttled)",
};

function FleetRow({ row, live, token, now }: { row: Row; live: Row[]; token: string; now: number }) {
  const head = (
    <>
      <span className="fleet-name">{row.name}</span>
      <span className="fleet-role">{[row.role, row.model, row.lane && `${row.lane} bank`].filter(Boolean).join(" · ")}</span>
      <span className={`state ${CLS[row.state]}`}>{row.state}</span>
    </>
  );
  return (
    <div className={`fleet-row ${CLS[row.state]}`} id={rowId(row.name)} tabIndex={-1}>
      {rowHref(token, row) ? <a className="fleet-head" href={rowHref(token, row)!}>{head}</a> : <span className="fleet-head">{head}</span>}
      <span className="fleet-runtime">{row.runtime ? `runtime ${Math.floor(Math.max(0, (row.runtime.endedAt ?? now) - row.runtime.startedAt) / 60000)}m${row.runtime.endedAt !== null ? " (ended)" : ""}` : "runtime not measured"}</span>
      {row.cloud ? (
        <span className="fleet-meta">
          {[row.ticket, row.pr !== null && `PR ${row.pr}`].filter(Boolean).join(" · ")}{` · ${PHASE[row.cloud.phase]}`}
          {row.cloud.url && <>{" · "}<a className="fleet-cloud" href={row.cloud.url} target="_blank" rel="noreferrer">cloud session</a></>}
        </span>
      ) : <span className="fleet-meta">
        {[row.ticket, row.pr !== null && `PR ${row.pr}`].filter(Boolean).join(" · ") || "no ticket"}
        {" · "}{row.subagents.total === 0 ? "no subagents" : `${row.subagents.running} of ${row.subagents.total} subagents running`}
        {row.failures > 0 ? <span className="fleet-fails">{` · ${row.failures} failure${row.failures === 1 ? "" : "s"}`}</span> : " · no failures"}
      </span>}
      <span className="fleet-graph">
        {row.parent ? <>under <Rel name={row.parent} live={live} /></> : "under the operator"}
        {row.predecessor && <>{" · successor to "}<Rel name={row.predecessor} live={live} /></>}
        {live.filter((x) => x.predecessor === row.name).map((x) => <span key={x.name}>{" · succeeded by "}<Rel name={x.name} live={live} /></span>)}
      </span>
      {row.agents.length > 0 && (
        <span className="fleet-agents">
          {row.agents.slice(0, 8).map((a, i) => <span key={i} className={`fleet-agent ${a.state}`}>{`${a.role}: ${a.name} (${a.state})`}</span>)}
          {row.agents.length > 8 && <span className="fleet-agent">{`+${row.agents.length - 8} more`}</span>}
        </span>
      )}
      <span className="fleet-usage">{row.usage ? usageText(row.usage) : row.cloud ? "tokens not measured: a cloud session keeps no local journal and no source exposes its usage" : "tokens not measured: no usage records in its journal"}</span>
      {row.role === "leg" && <a className="fleet-link" href={pageHref({ here: "agui", token, id: "health" })}>legs and bank on Health</a>}
      {!row.cloud && <span className="fleet-activity">
        {row.activity ? <><b>{row.activity.tool}</b> {row.activity.summary} <span className="fleet-age">{ago(now - row.activity.at)}</span></> : "no activity yet"}
      </span>}
    </div>
  );
}
