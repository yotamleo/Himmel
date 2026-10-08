// Fleet grouping and fragment routing stay dependency-free, like the stream reducer.
export type Row = {
  run: string | null; pid: number | null; name: string; role: string; model: string | null; ticket: string | null; pr: number | null;
  state: "running" | "idle" | "waiting for GO" | "wrapped" | "unknown"; activity: { tool: string; summary: string; at: number } | null;
  lastEventAt: number | null; subagents: { total: number; running: number }; failures: number;
  parent: string | null; predecessor: string | null; agents: { name: string; role: string; state: string }[];
  usage: {
    calls: number; input: number; output: number; cacheRead: number; cacheCreate: number; costEq: number;
    resident: number | null; ceiling: number; ceilingFrom: "autocompact" | "window"; fill: number | null;
  } | null;
  cloud: { url: string | null; phase: "working" | "done" | "blocked" | "merged" | "closed" | "unknown" } | null;
  runtime?: { startedAt: number; endedAt: number | null; elapsedMs: number } | null;
  console?: string | null; live?: boolean; lock?: "held" | "released" | "unknown"; lane?: string;
  // HIMMEL-4925: read when the server sends them (the leg doc's last marker, the doc's last write, the PR's URL).
  marker?: string | null; lastSeenAt?: number | null; prUrl?: string | null;
};

export const runHash = (token: string, run: string) => `#${new URLSearchParams({ t: token, run })}`;
export const consoleHash = (token: string, name: string) => `#${new URLSearchParams({ t: token, console: name })}`;
export const consoleFromHash = (hash: string): string | null => {
  const p = new URLSearchParams(hash.replace(/^#/, ""));
  return p.get("run") ? null : p.get("console");
};
export function fleetToken(hash: string): string | null {
  const p = new URLSearchParams(hash.replace(/^#/, ""));
  return p.get("t") && !p.get("run") ? p.get("t") : null;
}

export const consoleName = (r: Row) => r.console === undefined ? r.parent : r.console;
export const isLive = (r: Row) => r.live !== false && r.state !== "wrapped" && r.lock !== "released";
export const rowHref = (token: string, r: Row) => r.run ? runHash(token, r.run) : r.cloud?.url ?? null;
export function orphanReason(r: Row, rows: Row[]): string | null {
  if (r.role === "console" || r.state === "wrapped") return null;
  if (r.role === "cloud" && !rows.some((s) => s.parent === r.name && isLive(s))) return "cloud session without a shepherd";
  const name = consoleName(r);
  if (!name) return "no console edge";
  const c = rows.find((s) => s.role === "console" && s.name === name);
  if (c?.state === "wrapped" || c?.lock === "released") return "console wrapped / lock released";
  return c && isLive(c) ? null : "console process gone";
}
export function visibleRows(rows: Row[]): Row[] {
  return rows.filter((r) => !(r.cloud?.phase === "merged" && !rows.some((c) => c.role === "console" && c.name === consoleName(r) && isLive(c))));
}
export function consoleGroups(rows: Row[]): { console: Row; rows: Row[] }[] {
  const shown = visibleRows(rows);
  return shown.filter((r) => r.role === "console")
    .sort((a, b) => Number(isLive(b)) - Number(isLive(a)) || a.name.localeCompare(b.name))
    .map((c) => ({ console: c, rows: shown.filter((r) => r.role !== "console" && consoleName(r) === c.name && !orphanReason(r, rows)) }));
}

// HIMMEL-4925: the page's three sections. Running = live sessions grouped under their live console (siblings by state,
// then newest activity); Finished = everything that ended, plus a cloud session whose console has; Needs attention =
// one line per session, by severity: a BLOCKED/FINDING marker, then context at 85 % or more, then orphans.
const RANK: Record<Row["state"], number> = { running: 0, "waiting for GO": 1, idle: 2, unknown: 3, wrapped: 4 };
const recency = (r: Row) => r.activity?.at ?? r.lastEventAt ?? r.runtime?.startedAt ?? null;
const byName = (a: Row, b: Row) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0);
// Newest first, an untimed row after every timed one.
const newest = (x: number | null, y: number | null) => (x === y ? 0 : x === null ? 1 : y === null ? -1 : y - x);
export const siblingOrder = (a: Row, b: Row) => RANK[a.state] - RANK[b.state] || newest(recency(a), recency(b)) || byName(a, b);
// Untimed finished rows fall back to name descending: console names carry their date and sequence letter.
const ended = (r: Row) => r.runtime?.endedAt ?? r.lastSeenAt ?? r.lastEventAt ?? null;
const finishedOrder = (a: Row, b: Row) => newest(ended(a), ended(b)) || byName(b, a);

export const CONTEXT_ATTENTION = 85;
export type Attention = { row: Row; why: string; stale: boolean };
export type FleetSections = {
  attention: Attention[]; running: { console: Row | null; rows: Row[] }[]; finished: Row[];
  counts: { running: number; waiting: number; attention: number; finished: number };
};

export function fleetSections(all: Row[], selected: string | null = null): FleetSections {
  const rows = visibleRows(all);
  const liveConsole = (name: string | null) => !!name && rows.some((c) => c.role === "console" && c.name === name && isLive(c));
  const finished = (r: Row) => !isLive(r) || (r.role === "cloud" && !liveConsole(consoleName(r)));
  const mine = (r: Row) => !selected || r.name === selected || consoleName(r) === selected;
  const running = rows.filter((r) => !finished(r) && mine(r)).sort(siblingOrder);
  const groups: FleetSections["running"] = running.filter((r) => r.role === "console")
    .sort((a, b) => newest(recency(a), recency(b)) || byName(a, b))
    .map((c) => ({ console: c, rows: running.filter((r) => r.role !== "console" && consoleName(r) === c.name) }));
  const rest = running.filter((r) => r.role !== "console" && !liveConsole(consoleName(r)));
  if (rest.length) groups.push({ console: null, rows: rest });
  const done = rows.filter((r) => finished(r) && mine(r)).sort(finishedOrder);
  const why = (r: Row): [number, string] | null => {
    if (r.marker === "BLOCKED" || r.marker === "FINDING") return [0, r.marker];
    if (!finished(r) && r.usage?.fill != null && r.usage.fill >= CONTEXT_ATTENTION) return [1, `context ${Math.round(r.usage.fill)}%`];
    // A cloud session whose GitHub read failed may be done or not: unknown is not an orphan.
    const o = r.cloud?.phase === "unknown" ? null : orphanReason(r, rows);
    return o ? [finished(r) ? 3 : 2, o] : null;
  };
  const attention = rows.filter(mine).flatMap((r) => { const w = why(r); return w ? [{ r, w }] : []; })
    .sort((a, b) => a.w[0] - b.w[0] || newest(recency(a.r), recency(b.r)) || byName(a.r, b.r))
    .map(({ r, w }) => ({ row: r, why: w[1], stale: finished(r) }));
  return {
    attention, running: groups, finished: done,
    counts: {
      running: running.filter((r) => r.state === "running").length, waiting: running.filter((r) => r.state === "waiting for GO").length,
      attention: attention.length, finished: done.length,
    },
  };
}

// A session name without its ticket and date: `HIMMEL-4912-N1497-sandbox-runner-2026-10-08` is `N1497 sandbox-runner`,
// a console `HIMMEL-nextleg-2026-10-08BU-roadmap-console` is `BU-roadmap-console`; anything else is kept whole.
export function shortName(name: string): string {
  const c = /-\d{4}-\d{2}-\d{2}([A-Z]+-.*-console)$/.exec(name);
  if (c) return c[1];
  const l = /^[A-Z][A-Z0-9]+-\d+-(N\d+[a-z]?)-(.+?)(?:-\d{4}-\d{2}-\d{2})?(-RESUME)?$/.exec(name);
  return l ? `${l[1]} ${l[2]}${l[3] ? " (resume)" : ""}` : name;
}
