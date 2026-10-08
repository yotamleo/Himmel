// HIMMEL-4751: the live rows render as a tree under the operator (a leg under its console, a console beside the one
// it succeeded), each with its subagents, context fill and token usage; a parent or successor name jumps to its row.
// HIMMEL-4791: a cloud session (no local process) is a row of role "cloud" under its console, with its local
// shepherd leg under it: its PR, its CLOUD-DONE phase and session link, and tokens said to be not measured.
// HIMMEL-4712: the fleet landing — /agui/ with a token and no run. Every live session (consoles, legs, judges,
// interactive sessions) from GET /api/agui/fleet, polled; a row opens that session's run stream. HIMMEL-4711: a
// leg's row also links to the console's Health page, whose legs card reads the same handover docs.
// HIMMEL-4925: three sections (fleet-model's fleetSections): Needs attention, Running per live console, and Finished
// (closed by default); a card keeps its current status (left) apart from its lineage (right).
import { useEffect, useState, type ReactNode } from "react";
// @ts-expect-error: plain ES module shared with the console (no types).
import { pageHref } from "../../public/nav.js";
import { FLEET_URL } from "./stream";
import { fleetSections, rowHref, shortName, type Row } from "./fleet-model";
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
const CLS: Record<Row["state"], string> = { running: "running", idle: "idle", "waiting for GO": "waiting", wrapped: "finished", unknown: "idle" };
const plural = (n: number, one: string) => `${n} ${one}${n === 1 ? "" : "s"}`;

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

// HIMMEL-4925: a section's open state survives the 5 s poll and, per viewer, a reload. Storage can throw (private
// window, blocked site data): the page then just uses the default.
export function useOpen(key: string, initial: boolean): [boolean, (open: boolean) => void] {
  const [open, setOpen] = useState(() => {
    try { const v = localStorage.getItem(`fleet-open:${key}`); return v === null ? initial : v === "1"; } catch { return initial; }
  });
  return [open, (o) => { setOpen(o); try { localStorage.setItem(`fleet-open:${key}`, o ? "1" : "0"); } catch { /* not kept */ } }];
}

function Section({ id, title, count, initial, className, children }: { id: string; title: string; count: number; initial: boolean; className?: string; children: ReactNode }) {
  const [open, setOpen] = useOpen(id, initial);
  return (
    <details className={`fleet-sec ${className ?? ""}`} id={`fleet-sec-${id}`} open={open} onToggle={(e) => setOpen(e.currentTarget.open)} aria-label={title}>
      <summary><span>{title}</span> <span className="fleet-count">{count}</span></summary>
      {children}
    </details>
  );
}

export function FleetPage({ token, state, console: selected = null }: { token: string; state: FleetState; console?: string | null }) {
  const { fleet, error } = state;
  const [now, setNow] = useState(Date.now());

  useEffect(() => {
    const tick = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(tick);
  }, []);

  const all = fleet?.sessions ?? [];
  const s = fleetSections(all, selected);
  const { counts } = s;
  const unavailable = fleet?.census === "unavailable";
  const known = !selected || all.some((r) => r.name === selected || r.console === selected || r.parent === selected);
  return (
    <>
      <header className="top">
        <span className="brand">himmel</span>
        <span className="run">{selected ?? "fleet"}</span>
        <span className={`state ${error ? "error" : fleet ? "running" : "idle"}`} role="status">{error ? "stopped" : fleet ? "live" : "connecting"}</span>
        {fleet && !unavailable && <span className={`meta${error ? " stale" : ""}`}>
          <Jump to="running">{`${counts.running} running`}</Jump>
          {` · ${counts.waiting} waiting for GO · `}
          {counts.attention > 0 ? <Jump to="attention" className="fleet-attn-count">{`${counts.attention} need attention`}</Jump> : "0 need attention"}
          {" · "}<Jump to="finished">{`${counts.finished} finished`}</Jump>
          {` · updated ${ago(now - fleet.generatedAt)}`}
        </span>}
      </header>
      <main className="fleet" aria-label="Fleet">
        {error && (fleet
          ? <p className="run-error fleet-stale" role="alert">The fleet view stopped: {error}. Showing the snapshot from {ago(now - fleet.generatedAt)}.</p>
          : <p className="run-error" role="alert">The fleet view stopped: {error}.</p>)}
        {unavailable && <p className="run-error" role="alert">The process census failed: this list is not the fleet.</p>}
        {fleet?.census === "degraded" && <p className="quiet">Some sessions could not be read; the list may be incomplete.</p>}
        {!fleet && !error && <div className="fleet-skel" aria-hidden="true"><i /><i /><i /></div>}
        {selected && fleet && !known && <p className="quiet">Console not found: {selected}. <a href={`#t=${encodeURIComponent(token)}`}>The whole fleet</a></p>}
        {s.attention.length > 0 && <Section id="attention" title="Needs attention" count={counts.attention} initial={true} className="fleet-attention">
          <Attention items={s.attention} token={token} now={now} />
        </Section>}
        {fleet && !unavailable && <Section id="running" title="Running" count={s.running.reduce((n, g) => n + g.rows.length + (g.console ? 1 : 0), 0)} initial={true}>
          {s.running.length === 0 && <p className="quiet">{`No running sessions.${counts.finished > 0 ? ` ${counts.finished} finished below.` : ""}`}</p>}
          {s.running.map((g) => <ConsoleGroup key={g.console?.name ?? "-"} group={g} all={all} token={token} now={now} />)}
        </Section>}
        {s.finished.length > 0 && <Section id="finished" title="Finished" count={counts.finished} initial={false} className="fleet-closed">
          <Finished rows={s.finished} token={token} now={now} />
        </Section>}
      </main>
    </>
  );
}

// The header counts jump to their section and open it (a button: the fragment is the router's, never an anchor's).
function Jump({ to, className, children }: { to: string; className?: string; children: ReactNode }) {
  return <button type="button" className={`fleet-jump ${className ?? ""}`} onClick={() => {
    const el = document.getElementById(`fleet-sec-${to}`) as HTMLDetailsElement | null;
    if (!el) return;
    el.open = true;
    el.scrollIntoView({ block: "start" });
  }}>{children}</button>;
}

function ConsoleGroup({ group, all, token, now }: { group: { console: Row | null; rows: Row[] }; all: Row[]; token: string; now: number }) {
  const name = group.console?.name ?? "Not under a live console";
  const [open, setOpen] = useOpen(`console:${name}`, true);
  const cloud = group.rows.filter((r) => r.role === "cloud").length;
  return (
    <details className="fleet-console" open={open} onToggle={(e) => setOpen(e.currentTarget.open)} aria-label={name}>
      <summary><h2>{name}</h2><span className="fleet-count">{[plural(group.rows.length - cloud, "session"), cloud > 0 && `${cloud} cloud`].filter(Boolean).join(" · ")}</span></summary>
      <ul className="fleet-rows fleet-tree" aria-label="Live sessions">
        {group.console
          ? <FleetNode node={{ row: group.console, kids: forest(group.rows) }} live={all} token={token} now={now} />
          : forest(group.rows).map((n) => <FleetNode key={n.row.name} node={n} live={all} token={token} now={now} />)}
      </ul>
    </details>
  );
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

// One line per item, by severity; the orphans of finished consoles fold into "+ N more".
function Attention({ items, token, now }: { items: ReturnType<typeof fleetSections>["attention"]; token: string; now: number }) {
  const line = (a: (typeof items)[number]) => {
    const href = rowHref(token, a.row);
    const label = shortName(a.row.name);
    const at = a.row.activity?.at;
    return <li key={a.row.name} className="fleet-attn">
      <span className="fleet-why">{a.why}</span>
      {" · "}{href ? <a href={href}>{label}</a> : label}
      {a.row.ticket && !label.includes(a.row.ticket) && ` · ${a.row.ticket}`}
      {a.row.pr !== null && ` · PR ${a.row.pr}`}
      {a.row.console && a.row.console !== a.row.name && ` · ${shortName(a.row.console)}`}
      {at !== undefined && <span className="fleet-age">{` · ${ago(now - at)}`}</span>}
      {a.row.usage?.fill != null && a.why.startsWith("context") && <Meter fill={a.row.usage.fill} />}
    </li>;
  };
  const fresh = items.filter((a) => !a.stale), stale = items.filter((a) => a.stale);
  const consoles = [...new Set(stale.map((a) => a.row.console).filter((c): c is string => !!c))].map(shortName);
  return <ul className="fleet-attn-list" aria-label="Needs attention">
    {fresh.map(line)}
    {stale.length > 0 && <li><details className="fleet-stale-orphans">
      <summary>{`+ ${stale.length} more under finished consoles${consoles.length ? ` (${consoles.join(", ")})` : ""}`}</summary>
      <ul className="fleet-attn-list">{stale.map(line)}</ul>
    </details></li>}
  </ul>;
}

const FINISHED_PAGE = 20;
function Finished({ rows, token, now }: { rows: Row[]; token: string; now: number }) {
  const [all, setAll] = useState(false);
  const shown = all ? rows : rows.slice(0, FINISHED_PAGE);
  return <>
    <ul className="fleet-rows fleet-finished" aria-label="Finished sessions">{shown.map((r) => {
      const href = rowHref(token, r);
      const end = r.runtime?.endedAt ?? r.lastSeenAt ?? null;
      const how = r.cloud ? PHASE[r.cloud.phase] : r.state === "wrapped" ? "wrapped" : r.lock === "released" ? "ended · lock released" : "ended";
      const name = <><span className="fleet-name" title={r.name}>{shortName(r.name)}</span><span className="fleet-role">{[r.role, r.ticket].filter(Boolean).join(" · ")}</span></>;
      return <li key={r.name} className={`fleet-row finished ${CLS[r.state]}`} id={rowId(r.name)} tabIndex={-1}>
        {href ? <a className="fleet-head" href={href}>{name}</a> : <span className="fleet-head">{name}</span>}
        <span className="fleet-meta">
          {how}{end !== null && ` ${ago(now - end)}`}
          {r.pr !== null && <>{" · "}{r.prUrl?.startsWith("https://") ? <a href={r.prUrl} target="_blank" rel="noreferrer">{`PR ${r.pr}`}</a> : `PR ${r.pr}`}</>}
        </span>
      </li>;
    })}</ul>
    {!all && rows.length > FINISHED_PAGE && <button type="button" className="fleet-more-btn" onClick={() => setAll(true)}>{`Show all ${rows.length}`}</button>}
  </>;
}

// A row's anchor is its name (a cloud row has no pid); the census and cloud names are plain, id-safe text.
const rowId = (name: string) => `fleet-${name}`;

// A link to another session's row when it is live (the hash is the router's, so this scrolls instead), else its name.
function Rel({ name, live }: { name: string; live: Row[] }) {
  const r = live.find((x) => x.name === name);
  if (!r || r.live === false || r.state === "wrapped") return <span title={name}>{`${shortName(name)} (${r ? "finished" : "not live"})`}</span>;
  return (
    <button type="button" className="fleet-rel" title={name} onClick={() => {
      const el = document.getElementById(rowId(r.name));
      el?.scrollIntoView({ block: "center" });
      el?.focus();
    }}>{shortName(name)}</button>
  );
}

// HIMMEL-4925: where a row hangs, root first: operator › console › … › this row. A parent loop stops at a repeat.
function Lineage({ row, live }: { row: Row; live: Row[] }) {
  const up: string[] = [];
  for (let p = row.parent; p && !up.includes(p) && p !== row.name && up.length < 8; p = live.find((x) => x.name === p)?.parent ?? null) up.unshift(p);
  return <span className="fleet-graph">
    {"operator"}
    {up.map((p) => <span key={p}>{" › "}<Rel name={p} live={live} /></span>)}
    {" › "}<b>{shortName(row.name)}</b>
  </span>;
}

// Context fill against the session's ceiling, as a bar: warn from 75 %, fail from 90 % (the leg context guard's marks).
function Meter({ fill }: { fill: number }) {
  return <span className={`fleet-meter ${fill >= 90 ? "fail" : fill >= 75 ? "warn" : "ok"}`} aria-hidden="true"><i style={{ width: `${Math.min(100, fill)}%` }} /></span>;
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
      <span className="fleet-name" title={row.name}>{shortName(row.name)}</span>
      {row.ticket && <span className="fleet-chip">{row.ticket}</span>}
      <span className="fleet-role">{[row.role, row.model, row.lane && `${row.lane} bank`].filter(Boolean).join(" · ")}</span>
      <span className={`state ${CLS[row.state]}`}>{row.marker && row.marker !== "WRAPPED" ? `${row.state} · ${row.marker}` : row.state}</span>
    </>
  );
  const failed = row.agents.filter((a) => a.state === "failed").length;
  const runtime = row.runtime ? `runtime ${Math.floor(Math.max(0, (row.runtime.endedAt ?? now) - row.runtime.startedAt) / 60000)}m${row.runtime.endedAt !== null ? " (ended)" : ""}` : "runtime not measured";
  const successors = live.filter((x) => x.predecessor === row.name);
  return (
    <div className={`fleet-row ${CLS[row.state]}`} id={rowId(row.name)} tabIndex={-1}>
      {rowHref(token, row) ? <a className="fleet-head" href={rowHref(token, row)!}>{head}</a> : <span className="fleet-head">{head}</span>}
      <div className="fleet-status">
        {row.cloud ? (
          <span className="fleet-activity fleet-cloud-phase">
            {[row.pr !== null && `PR ${row.pr}`, PHASE[row.cloud.phase]].filter(Boolean).join(" · ")}
            {row.cloud.url && <>{" · "}<a className="fleet-cloud" href={row.cloud.url} target="_blank" rel="noreferrer">cloud session</a></>}
          </span>
        ) : <span className="fleet-activity">
          {row.activity ? <><b>{row.activity.tool}</b> {row.activity.summary} <span className="fleet-age">{ago(now - row.activity.at)}</span></> : "no activity yet"}
        </span>}
        <span className="fleet-meta">
          {runtime}
          {!row.cloud && ` · ${row.pr !== null ? `PR ${row.pr}` : "no PR"}`}
          {!row.cloud && ` · ${row.subagents.total === 0 ? "no subagents" : `${row.subagents.running} of ${row.subagents.total} subagents running`}`}
          {failed > 0 && <span className="fleet-fails">{` · ${failed} failed`}</span>}
          {row.failures > 0 && ` · ${plural(row.failures, "tool error")}`}
        </span>
      </div>
      <div className="fleet-lineage">
        <Lineage row={row} live={live} />
        {(row.predecessor || successors.length > 0) && <span className="fleet-succession">
          {row.predecessor && <>{"succeeds "}<Rel name={row.predecessor} live={live} /></>}
          {successors.map((x, i) => <span key={x.name}>{row.predecessor || i > 0 ? " · " : ""}{"succeeded by "}<Rel name={x.name} live={live} /></span>)}
        </span>}
        {row.usage?.fill != null
          ? <span className="fleet-context">{`context ${row.usage.fill}% of ${k(row.usage.ceiling)}`}<Meter fill={row.usage.fill} /></span>
          : <span className="fleet-context">{row.cloud ? "tokens not measured (cloud)" : row.usage ? "context unknown (no trusted window)" : "context not measured"}</span>}
        {row.role === "leg" && <a className="fleet-link" href={pageHref({ here: "agui", token, id: "health" })}>legs and bank on Health</a>}
        <details className="fleet-more">
          <summary>{[row.agents.length > 0 && plural(row.agents.length, "subagent"), "usage"].filter(Boolean).join(" · ")}</summary>
          {row.agents.length > 0 && (
            <span className="fleet-agents">
              {row.agents.slice(0, 8).map((a, i) => <span key={i} className={`fleet-agent ${a.state}`}>{`${a.role}: ${a.name} (${a.state})`}</span>)}
              {row.agents.length > 8 && <span className="fleet-agent">{`+${row.agents.length - 8} more`}</span>}
            </span>
          )}
          <span className="fleet-usage">{row.usage ? usageText(row.usage) : row.cloud ? "tokens not measured: a cloud session keeps no local journal and no source exposes its usage" : "tokens not measured: no usage records in its journal"}</span>
        </details>
      </div>
    </div>
  );
}
