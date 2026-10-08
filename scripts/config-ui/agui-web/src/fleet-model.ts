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
