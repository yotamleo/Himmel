// fleet.ts — every live session on one page (HIMMEL-4712), for GET /api/agui/fleet.
//
// The census is fleet.sh's (claude_sessions + each session's leg doc and its leg_tail_status); this joins each
// census pid to the harness's ~/.claude/sessions/<pid>.json (its sessionId and busy/idle status), finds the
// session's journal with sse.ts's resolveJournal, and folds the journal and its subagent transcripts through the
// same mapper and reducer the per-run page uses, so a row's subagents and failures are the counts that page shows.
// A session whose journal has not been written for RECENT_MS is not live and is left out; one with no journal
// yet is listed bare. Read-only: nothing here writes.
//
// ponytail: each request re-folds every journal that grew since the last one (cached on the files' sizes), so a
// fleet of very long journals costs a full read per poll (measured 2026-10-07 on 9 live sessions: 278 ms cold,
// 202 ms warm); upgrade path: a per-file incremental fold (the SSE tail's offsets) once a fleet poll is slow.
import { execFile } from "node:child_process";
import { readFile, stat } from "node:fs/promises";
import { join } from "node:path";
import { agentState, initialView, reduce, type View } from "../agui-web/src/reducer.ts";
import { createJournalMapper } from "./journal-mapper.ts";
import { mergeJournalFiles, sessionFiles } from "./journal-merge.ts";
import { resolveJournal } from "./sse.ts";

export const RECENT_MS = 60 * 60 * 1000;
const SCRIPT_TIMEOUT_MS = 30_000;

export type FleetState = "running" | "idle" | "waiting for GO" | "wrapped";
export type FleetRow = {
  run: string | null; pid: number; name: string; role: "console" | "leg" | "judge" | "interactive"; model: string | null;
  ticket: string | null; pr: number | null; state: FleetState;
  activity: { tool: string; summary: string; at: number } | null; lastEventAt: number | null;
  subagents: { total: number; running: number }; failures: number;
};
export type Fleet = { census: "ok" | "degraded" | "unavailable"; generatedAt: number; sessions: FleetRow[] };
type CensusRow = { pid: string; name: string; model: string; doc: string; status: string };

function runScript(script: string, env: Record<string, string | undefined>): Promise<{ census: Fleet["census"]; sessions: CensusRow[] }> {
  return new Promise((ok) => {
    execFile("bash", [script], { env: env as NodeJS.ProcessEnv, timeout: SCRIPT_TIMEOUT_MS, maxBuffer: 4 * 1024 * 1024 }, (err, stdout) => {
      try { if (!err) return ok(JSON.parse(stdout)); } catch { /* fall through */ }
      ok({ census: "unavailable", sessions: [] });
    });
  });
}

const roleOf = (name: string, doc: string): FleetRow["role"] =>
  /-console$/.test(name) ? "console" : /(^|-)judge(-|$)|(^|-)J\d+(-|$)/i.test(name) ? "judge" : doc ? "leg" : "interactive";

// The PR a leg doc names last: `READY <pr> ...` or `PR <n>` / `PR #<n>` in its bullets.
async function prOf(doc: string): Promise<number | null> {
  if (!doc) return null;
  let text: string;
  try { text = await readFile(doc, "utf8"); } catch { return null; }
  let pr: number | null = null;
  for (const m of text.matchAll(/^- .*?\b(?:READY|PR) #?(\d+)\b/gm)) pr = Number(m[1]);
  return pr;
}

function stateOf(status: string, busy: boolean): FleetState {
  if (status === "WRAPPED") return "wrapped";
  if (status === "READY") return "waiting for GO";
  return busy ? "running" : "idle";
}

// The one argument that says what a call is doing (App.tsx's summarize, on the server side).
function summarize(args: string): string {
  let a: Record<string, unknown> | null = null;
  try { const v = JSON.parse(args); a = v && typeof v === "object" ? v : null; } catch { /* streaming */ }
  if (!a) return args.slice(0, 120);
  for (const k of ["description", "command", "file_path", "pattern", "url", "query"]) if (typeof a[k] === "string") return (a[k] as string).slice(0, 120);
  const first = Object.values(a).find((x) => typeof x === "string");
  return typeof first === "string" ? first.slice(0, 120) : "";
}

const folds = new Map<string, { key: string; view: View }>();
async function fold(journal: string): Promise<View> {
  const { paths } = await sessionFiles(journal);
  const sizes = await Promise.all(paths.map((p) => stat(p).then((s) => s.size, () => -1)));
  const key = paths.map((p, i) => `${p}:${sizes[i]}`).join("|");
  const hit = folds.get(journal);
  if (hit?.key === key) return hit.view;
  const { lines } = await mergeJournalFiles(paths);
  const mapper = createJournalMapper();
  let view = initialView();
  for (const l of lines) for (const e of mapper.pushLine(l)) view = reduce(view, e as never);
  folds.set(journal, { key, view });
  return view;
}

export async function readFleet(opts: { script: string; env: Record<string, string | undefined>; home: string; now: number; redact: (s: string) => string }): Promise<Fleet> {
  const census = await runScript(opts.script, opts.env);
  const rows = await Promise.all(census.sessions.map(async (c): Promise<FleetRow | null> => {
    let rec: { sessionId?: unknown; status?: unknown; name?: unknown } = {};
    try { rec = JSON.parse(await readFile(join(opts.home, ".claude", "sessions", `${c.pid}.json`), "utf8")); } catch { /* not yet written */ }
    const run = typeof rec.sessionId === "string" ? rec.sessionId : null;
    const found = run ? await resolveJournal(opts.home, run) : null;
    const journal = found && "path" in found ? found.path : null;
    let view: View | null = null;
    if (journal) {
      const mtime = await stat(journal).then((s) => s.mtimeMs, () => 0);
      if (opts.now - mtime > RECENT_MS) return null;
      view = await fold(journal);
    }
    const tools = view ? Object.values(view.tools).sort((a, b) => b.start - a.start) : [];
    const subs = view ? view.agentOrder.filter((id) => id !== "main") : [];
    const t0 = view?.t0;
    // A session started without -n still has the name the harness gave it.
    const name = c.name || (typeof rec.name === "string" ? rec.name : "") || `pid ${c.pid}`;
    const role = roleOf(name, c.doc);
    return {
      run, pid: Number(c.pid), name, role, model: c.model || null,
      ticket: /^([A-Z][A-Z0-9]+-\d+)\b/.exec(name)?.[1] ?? null, pr: role === "leg" ? await prOf(c.doc) : null,
      state: stateOf(c.status, rec.status === "busy"),
      activity: tools[0] && t0 !== undefined ? { tool: tools[0].name, summary: opts.redact(summarize(tools[0].args)), at: t0 + tools[0].start } : null,
      lastEventAt: view && t0 !== undefined ? t0 + view.elapsed : null,
      subagents: { total: subs.length, running: view ? subs.filter((id) => agentState(view!, id) === "running").length : 0 },
      failures: view?.failures.length ?? 0,
    };
  }));
  return { census: census.census, generatedAt: opts.now, sessions: rows.filter((r): r is FleetRow => r !== null) };
}
