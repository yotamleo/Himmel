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
// HIMMEL-4925: a cloud session is a lane, not an orphan (the operator does not keep a shepherd on every one), and an
// interactive session is the operator's own; neither is ever one.
export function orphanReason(r: Row, rows: Row[]): string | null {
  if (r.role === "console" || r.role === "cloud" || r.role === "interactive" || r.state === "wrapped") return null;
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

// HIMMEL-4925: the page's sections. Needs attention = one line per session that wants a console action, by severity;
// Orphans = live sessions no live console watches, plus the stale shell-tool wrappers tick also reports; Running = the
// rest of the live sessions, grouped under their live console (siblings by state, then newest activity); Finished =
// everything that ended, plus a cloud session whose console has, with a leg's or a console's chain folded into one entry.
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
export type Attention = { row: Row; why: string };
export type ProcessOrphan = { pid: number; owner: string; ageMin: number };
// Empty lists filter nothing. states: running | waiting | idle | attention | orphaned (a finished row is "finished").
export type Filters = { lanes: string[]; states: string[]; text: string };
export const NO_FILTERS: Filters = { lanes: [], states: [], text: "" };
export type FleetSections = {
  attention: Attention[]; orphans: Attention[]; processOrphans: ProcessOrphan[];
  running: { console: Row | null; showConsole: boolean; rows: Row[] }[];
  finished: { row: Row; hops: Row[] }[]; hops: Record<string, Row[]>;
  counts: { running: number; waiting: number; attention: number; orphaned: number; finished: number; shown: number; total: number };
};

// HIMMEL-4925: cloud is a lane like native and claudex.
export const laneOf = (r: Row) => (r.role === "cloud" || r.lane === "cloud" ? "cloud" : r.lane === "claudex" ? "claudex" : "native");
// A leg's hops share a ticket and a leg number: N1494, N1494b and their -RESUME docs are one chain.
export function chainKey(name: string): string | null {
  const m = /^([A-Z][A-Z0-9]+-\d+)-(N\d+)[a-z]?-/.exec(name);
  return m ? `${m[1]}-${m[2]}` : null;
}
const shepherded = (r: Row, rows: Row[]) => rows.some((s) => s.parent === r.name && isLive(s));
export function cloudPhase(r: Row, rows: Row[]): string {
  switch (r.cloud?.phase) {
    case "working": return shepherded(r, rows) ? "shepherded" : "working";
    case "done": return shepherded(r, rows) ? "shepherded" : "CLOUD-DONE";
    case "blocked": return "CLOUD-BLOCKED";
    case "merged": case "closed": return r.cloud.phase;
    default: return "unknown";
  }
}

export function fleetSections(all: Row[], selected: string | null = null, filters: Filters = NO_FILTERS, procs: ProcessOrphan[] = []): FleetSections {
  const rows = visibleRows(all);
  const liveConsole = (name: string | null) => !!name && rows.some((c) => c.role === "console" && c.name === name && isLive(c));
  const finished = (r: Row) => !isLive(r) || (r.role === "cloud" && !liveConsole(consoleName(r)));
  const mine = (r: Row) => !selected || r.name === selected || consoleName(r) === selected;
  const orphanOf = (r: Row) => (finished(r) ? null : orphanReason(r, rows));
  const why = (r: Row): [number, string] | null => {
    if (finished(r)) return null;
    if (r.marker === "BLOCKED" || r.marker === "FINDING") return [0, r.marker];
    const pr = r.pr !== null ? ` · PR ${r.pr}` : "";
    if (r.cloud?.phase === "blocked") return [0, `CLOUD-BLOCKED · a question on the PR${pr}`];
    if (r.usage?.fill != null && r.usage.fill >= CONTEXT_ATTENTION) return [1, `context ${Math.round(r.usage.fill)}%`];
    // A CLOUD-DONE PR with nobody shepherding it is the console's move; a cloud session still working alone is normal.
    if (r.cloud?.phase === "done" && !shepherded(r, rows)) return [2, `CLOUD-DONE · awaiting shepherd${pr}`];
    return null;
  };
  const text = filters.text.trim().toLowerCase();
  const states = (r: Row) => finished(r) ? ["finished"]
    : [r.state === "running" ? "running" : r.state === "waiting for GO" ? "waiting" : "idle", ...(why(r) ? ["attention"] : []), ...(orphanOf(r) ? ["orphaned"] : [])];
  const shown = (r: Row) => mine(r)
    && (!filters.lanes.length || filters.lanes.includes(laneOf(r)))
    && (!filters.states.length || states(r).some((s) => filters.states.includes(s)))
    && (!text || [r.name, r.ticket ?? "", shortName(r.name)].some((s) => s.toLowerCase().includes(text)));
  const byUrgency = (a: { r: Row; w: [number, string] }, b: { r: Row; w: [number, string] }) =>
    a.w[0] - b.w[0] || newest(recency(a.r), recency(b.r)) || byName(a.r, b.r);

  const running = rows.filter((r) => !finished(r) && !orphanOf(r) && mine(r)).sort(siblingOrder);
  const groups: FleetSections["running"] = running.filter((r) => r.role === "console")
    .sort((a, b) => newest(recency(a), recency(b)) || byName(a, b))
    .map((c) => ({ console: c, showConsole: shown(c), rows: running.filter((r) => r.role !== "console" && consoleName(r) === c.name && shown(r)) }))
    .filter((g) => g.showConsole || g.rows.length > 0);
  const rest = running.filter((r) => r.role !== "console" && !liveConsole(consoleName(r)) && shown(r));
  if (rest.length) groups.push({ console: null, showConsole: false, rows: rest });

  // Chains: a finished hop of a live leg rides on that leg's card; the rest fold into one Finished entry per chain
  // (a leg's by chainKey, finished consoles by their predecessor links), newest hop first, its earlier hops oldest first.
  const done = rows.filter((r) => finished(r) && shown(r)).sort(finishedOrder);
  const hops: Record<string, Row[]> = {};
  // Only a live hop that is shown can carry its earlier hops; a filtered-out one leaves them in Finished.
  const liveHop = new Map(groups.flatMap((g) => g.rows).flatMap((r) => { const k = chainKey(r.name); return k ? [[k, r.name] as const] : []; }));
  const consoles = new Set(done.filter((r) => r.role === "console").map((r) => r.name));
  const rootOf = (r: Row) => {
    let n = r.name;
    for (const seen = new Set<string>(); !seen.has(n); ) {
      seen.add(n);
      const p = rows.find((x) => x.name === n)?.predecessor;
      if (!p || !consoles.has(p)) break;
      n = p;
    }
    return `console:${n}`;
  };
  const chains = new Map<string, Row[]>();
  for (const r of done) {
    const k = r.role === "console" ? rootOf(r) : chainKey(r.name);
    const live = k && liveHop.get(k);
    if (live) (hops[live] ??= []).unshift(r);
    else if (!k) chains.set(`row:${r.name}`, [r]);
    else chains.set(k, [...(chains.get(k) ?? []), r]);
  }
  const finishedEntries = [...chains.values()].map(([row, ...rest]) => ({ row, hops: rest.reverse() }))
    .sort((a, b) => finishedOrder(a.row, b.row));

  const attention = rows.filter((r) => shown(r) && !orphanOf(r)).flatMap((r) => { const w = why(r); return w ? [{ r, w }] : []; })
    .sort(byUrgency).map(({ r, w }) => ({ row: r, why: w[1] }));
  const orphans = rows.filter(shown).flatMap((r) => { const o = orphanOf(r); return o ? [{ r, w: [0, o] as [number, string] }] : []; })
    .sort(byUrgency).map(({ r, w }) => ({ row: r, why: w[1] }));
  // A wrapper follows the same filters as its owning session; one with no live owner has no lane and matches by pid.
  const owners = new Set(rows.filter(mine).map((r) => r.name));
  const ownerOf = (p: ProcessOrphan) => rows.find((r) => r.name === p.owner);
  const processOrphans = procs.filter((p) => (!selected || p.owner === "orphan" || owners.has(p.owner))
    && (!filters.states.length || filters.states.includes("orphaned"))
    && (!filters.lanes.length || (!!ownerOf(p) && filters.lanes.includes(laneOf(ownerOf(p)!))))
    && (!text || [p.owner, shortName(p.owner), String(p.pid)].some((s) => s.toLowerCase().includes(text))));
  const live = groups.flatMap((g) => [...(g.showConsole && g.console ? [g.console] : []), ...g.rows]);
  return {
    attention, orphans, processOrphans, running: groups, finished: finishedEntries, hops,
    counts: {
      running: live.filter((r) => r.state === "running").length, waiting: live.filter((r) => r.state === "waiting for GO").length,
      attention: attention.length, orphaned: orphans.length + processOrphans.length, finished: finishedEntries.length,
      shown: rows.filter(shown).length, total: rows.filter(mine).length,
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
