// HIMMEL-4712: the fleet landing — /agui/ with a token and no run. Every live session (consoles, legs, judges,
// interactive sessions) from GET /api/agui/fleet, polled; a row opens that session's run stream. Wrapped legs sit
// in their own closed section and are never shown as running. HIMMEL-4711: a leg's row also links to the
// console's Health page, whose legs card reads the same handover docs.
import { useEffect, useState } from "react";
// @ts-expect-error: plain ES module shared with the console (no types).
import { pageHref } from "../../public/nav.js";
import { FLEET_URL, runHash } from "./stream";

type Row = {
  run: string | null; pid: number; name: string; role: string; model: string | null; ticket: string | null; pr: number | null;
  state: "running" | "idle" | "waiting for GO" | "wrapped"; activity: { tool: string; summary: string; at: number } | null;
  lastEventAt: number | null; subagents: { total: number; running: number }; failures: number;
};
type Fleet = { census: "ok" | "degraded" | "unavailable"; generatedAt: number; sessions: Row[] };

const POLL_MS = 5000;
const ORDER: Record<string, number> = { console: 0, judge: 1, leg: 2, interactive: 3 };
const CLS: Record<Row["state"], string> = { running: "running", idle: "idle", "waiting for GO": "waiting", wrapped: "finished" };

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

export function FleetPage({ token, state }: { token: string; state: FleetState }) {
  const { fleet, error } = state;
  const [now, setNow] = useState(Date.now());

  useEffect(() => {
    const tick = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(tick);
  }, []);

  const rows = (fleet?.sessions ?? []).slice().sort((a, b) => (ORDER[a.role] ?? 9) - (ORDER[b.role] ?? 9) || a.name.localeCompare(b.name));
  const open = rows.filter((r) => r.state !== "wrapped");
  const wrapped = rows.filter((r) => r.state === "wrapped");
  return (
    <>
      <header className="top">
        <span className="brand">himmel</span>
        <span className="run">fleet</span>
        <span className={`state ${error ? "error" : fleet ? "running" : "idle"}`} role="status">{error ? "stopped" : fleet ? "live" : "connecting"}</span>
        {fleet && <span className="meta">{`${open.length} live · ${wrapped.length} wrapped · updated ${ago(now - fleet.generatedAt)}`}</span>}
      </header>
      <main className="fleet" aria-label="Fleet">
        {error && <p className="run-error" role="alert">The fleet view stopped: {error}.</p>}
        {fleet?.census === "unavailable" && <p className="run-error" role="alert">The process census failed: this list is not the fleet.</p>}
        {fleet?.census === "degraded" && <p className="quiet">Some sessions could not be read; the list may be incomplete.</p>}
        {fleet && open.length === 0 && fleet.census !== "unavailable" && <p className="quiet">No live sessions.</p>}
        {open.length > 0 && <ul className="fleet-rows" aria-label="Live sessions">{open.map((r) => <FleetRow key={r.pid} row={r} token={token} now={now} />)}</ul>}
        {wrapped.length > 0 && (
          <details className="fleet-closed">
            <summary>{`Wrapped (${wrapped.length})`}</summary>
            <ul className="fleet-rows" aria-label="Wrapped sessions">{wrapped.map((r) => <FleetRow key={r.pid} row={r} token={token} now={now} />)}</ul>
          </details>
        )}
      </main>
    </>
  );
}

function FleetRow({ row, token, now }: { row: Row; token: string; now: number }) {
  const head = (
    <>
      <span className="fleet-name">{row.name}</span>
      <span className="fleet-role">{[row.role, row.model].filter(Boolean).join(" · ")}</span>
      <span className={`state ${CLS[row.state]}`}>{row.state}</span>
    </>
  );
  return (
    <li className={`fleet-row ${CLS[row.state]}`}>
      {row.run ? <a className="fleet-head" href={runHash(token, row.run)}>{head}</a> : <span className="fleet-head">{head}</span>}
      <span className="fleet-meta">
        {[row.ticket, row.pr !== null && `PR ${row.pr}`].filter(Boolean).join(" · ") || "no ticket"}
        {" · "}{row.subagents.total === 0 ? "no subagents" : `${row.subagents.running} of ${row.subagents.total} subagents running`}
        {row.failures > 0 ? <span className="fleet-fails">{` · ${row.failures} failure${row.failures === 1 ? "" : "s"}`}</span> : " · no failures"}
      </span>
      {row.role === "leg" && <a className="fleet-link" href={pageHref({ here: "agui", token, id: "health" })}>legs and bank on Health</a>}
      <span className="fleet-activity">
        {row.activity ? <><b>{row.activity.tool}</b> {row.activity.summary} <span className="fleet-age">{ago(now - row.activity.at)}</span></> : "no activity yet"}
      </span>
    </li>
  );
}
