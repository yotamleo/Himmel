// fleet.ts — every live session on one page (HIMMEL-4712), for GET /api/agui/fleet.
//
// The census is fleet.sh's (claude_sessions + each session's leg doc and its leg_tail_status); this joins each
// census pid to the harness's ~/.claude/sessions/<pid>.json (its sessionId and busy/idle status), finds the
// session's journal with sse.ts's resolveJournal, and folds the journal and its subagent transcripts through the
// same mapper and reducer the per-run page uses, so a row's subagents and failures are the counts that page shows.
// A session whose journal has not been written for RECENT_MS is not live and is left out; one with no journal
// yet is listed bare. Read-only: nothing here writes.
//
// HIMMEL-4751: a row also carries its place in the agent graph (graphOf: the parent console its own handover doc
// names, and a console's predecessor) with its in-process subagents, and its token usage (usageOf: the journal's
// API usage records, per call, priced with the leg-burn weights and filled against its --autocompact ceiling).
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
  parent: string | null; predecessor: string | null; agents: { name: string; role: string; state: string }[];
  usage: Usage | null;
};
export type Usage = {
  calls: number; input: number; output: number; cacheRead: number; cacheCreate: number; costEq: number;
  resident: number | null; ceiling: number; ceilingFrom: "autocompact" | "window"; fill: number | null;
};
export type Fleet = { census: "ok" | "degraded" | "unavailable"; generatedAt: number; sessions: FleetRow[] };
type CensusRow = { pid: string; name: string; model: string; doc: string; status: string; autocompact?: string };

// A session name as the launchers write it; anything else in a doc is text, never a link.
const SESSION = /^[A-Za-z0-9._+-]{1,160}$/;
const plain = (s: string | undefined) => (s && SESSION.test(s) ? s : null);

// Where a session sits, read from its own doc only. A leg's console is the one its brief names, or the newest
// console it accepted in a `SUCCESSION accepted: <new> replaces <old>` bullet; a judge's is the console that
// dispatched it; a console hangs under the operator (parent null) and names the console it succeeded.
export function graphOf(role: FleetRow["role"], doc: string): { parent: string | null; predecessor: string | null } {
  if (role === "console") return { parent: null, predecessor: plain(/successor to `?([^\s`]+?)(?:\.md)?`?[\s(]/.exec(doc)?.[1]) };
  let parent: string | null = null;
  if (role === "leg") {
    parent = plain(/your console is\W*`([^`]+)`/i.exec(doc)?.[1]);
    for (const m of doc.matchAll(/^- (?:[\d:]+ )?SUCCESSION accepted: `?([^\s`]+)`? replaces/gm)) parent = plain(m[1]) ?? parent;
  } else if (role === "judge") parent = plain(/dispatched by\s*(?:>\s*)?`([^`]+)`/.exec(doc)?.[1]);
  return { parent, predecessor: null };
}

// scripts/lanes/lib/burn-weights.sh's defaults: the price-weighted token-equivalent leg-burn.sh reports.
const W = { input: 1, cacheRead: 0.1, cacheCreate: 1.25, output: 5 };
const WINDOW_1M = 1_000_000, WINDOW = 200_000;
type Tally = Omit<Usage, "costEq" | "ceiling" | "ceilingFrom" | "fill">;
const count = (x: unknown) => (Number.isSafeInteger(x) && (x as number) >= 0 ? (x as number) : 0);

// One API call writes one record per content block, all with its message id and usage: each id counts once.
// resident = the input side of the newest main-thread call (input + cache read + cache create), the tokens in
// the window on that turn (context-fill.sh's per-turn count); subagent calls run in their own windows.
function tallyOf(lines: string[]): Tally | null {
  const t: Tally = { calls: 0, input: 0, output: 0, cacheRead: 0, cacheCreate: 0, resident: null };
  const seen = new Set<string>();
  for (const line of lines) {
    let r: any;
    try { r = JSON.parse(line); } catch { continue; }
    const u = r?.type === "assistant" ? r.message?.usage : undefined, id = r?.message?.id;
    if (!u || typeof u !== "object" || typeof id !== "string" || seen.has(id)) continue;
    seen.add(id);
    t.calls++;
    t.input += count(u.input_tokens); t.output += count(u.output_tokens);
    t.cacheRead += count(u.cache_read_input_tokens); t.cacheCreate += count(u.cache_creation_input_tokens);
    if (r.isSidechain !== true) t.resident = count(u.input_tokens) + count(u.cache_read_input_tokens) + count(u.cache_creation_input_tokens);
  }
  return t.calls ? t : null;
}

// The ceiling is the session's numeric --autocompact; without one (absent or `auto`) it is the model's window.
function finish(t: Tally | null, c: { autocompact: string; model: string }): Usage | null {
  if (!t) return null;
  const ac = /^\d+$/.test(c.autocompact) ? Number(c.autocompact) : 0;
  const ceiling = ac > 0 ? ac : /\[1m\]$/i.test(c.model) ? WINDOW_1M : WINDOW;
  return {
    ...t, costEq: Math.round(t.input * W.input + t.cacheRead * W.cacheRead + t.cacheCreate * W.cacheCreate + t.output * W.output),
    ceiling, ceilingFrom: ac > 0 ? "autocompact" : "window",
    fill: t.resident === null ? null : Math.round((t.resident / ceiling) * 1000) / 10,
  };
}
export const usageOf = (lines: string[], c: { autocompact: string; model: string }) => finish(tallyOf(lines), c);

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
function prOf(text: string): number | null {
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
  if (!a) return args;
  for (const k of ["description", "command", "file_path", "pattern", "url", "query"]) if (typeof a[k] === "string") return a[k] as string;
  const first = Object.values(a).find((x) => typeof x === "string");
  return typeof first === "string" ? first : "";
}

type Folded = { view: View; tally: Tally | null };
const folds = new Map<string, { key: string } & Folded>();
async function fold(journal: string): Promise<Folded> {
  const { paths } = await sessionFiles(journal);
  const sizes = await Promise.all(paths.map((p) => stat(p).then((s) => s.size, () => -1)));
  const key = paths.map((p, i) => `${p}:${sizes[i]}`).join("|");
  const hit = folds.get(journal);
  if (hit?.key === key) return hit;
  const { lines } = await mergeJournalFiles(paths);
  const mapper = createJournalMapper();
  let view = initialView();
  for (const l of lines) for (const e of mapper.pushLine(l)) view = reduce(view, e as never);
  const out = { key, view, tally: tallyOf(lines) };
  folds.set(journal, out);
  return out;
}

export async function readFleet(opts: { script: string; env: Record<string, string | undefined>; home: string; now: number; redact: (s: string) => string }): Promise<Fleet> {
  const census = await runScript(opts.script, opts.env);
  const seen = new Set<string>();
  const rows = await Promise.all(census.sessions.map(async (c): Promise<FleetRow | null> => {
    let rec: { sessionId?: unknown; status?: unknown; name?: unknown } = {};
    try { rec = JSON.parse(await readFile(join(opts.home, ".claude", "sessions", `${c.pid}.json`), "utf8")); } catch { /* not yet written */ }
    const run = typeof rec.sessionId === "string" ? rec.sessionId : null;
    const found = run ? await resolveJournal(opts.home, run) : null;
    const journal = found && "path" in found ? found.path : null;
    let view: View | null = null, tally: Tally | null = null;
    if (journal) {
      seen.add(journal);
      // Live if any of its files was written recently: a subagent can be busy while the main journal is quiet.
      const { paths } = await sessionFiles(journal);
      const mtimes = await Promise.all(paths.map((p) => stat(p).then((s) => s.mtimeMs, () => 0)));
      if (opts.now - Math.max(0, ...mtimes) > RECENT_MS) return null;
      ({ view, tally } = await fold(journal));
    }
    let doc = "";
    if (c.doc) try { doc = await readFile(c.doc, "utf8"); } catch { /* moved or gone: no doc */ }
    const tools = view ? Object.values(view.tools).sort((a, b) => b.start - a.start) : [];
    const subs = view ? view.agentOrder.filter((id) => id !== "main") : [];
    const t0 = view?.t0;
    // A session started without -n still has the name the harness gave it.
    const name = c.name || (typeof rec.name === "string" ? rec.name : "") || `pid ${c.pid}`;
    const role = roleOf(name, c.doc);
    return {
      run, pid: Number(c.pid), name, role, model: c.model || null,
      ticket: /^([A-Z][A-Z0-9]+-\d+)\b/.exec(name)?.[1] ?? null, pr: role === "leg" ? prOf(doc) : null,
      state: stateOf(c.status, rec.status === "busy"),
      activity: tools[0] && t0 !== undefined ? { tool: tools[0].name, summary: opts.redact(summarize(tools[0].args)).slice(0, 120), at: t0 + tools[0].start } : null,
      lastEventAt: view && t0 !== undefined ? t0 + view.elapsed : null,
      subagents: { total: subs.length, running: view ? subs.filter((id) => agentState(view!, id) === "running").length : 0 },
      failures: view?.failures.length ?? 0,
      ...graphOf(role, doc),
      agents: subs.map((id) => ({ name: opts.redact(view!.agents[id]?.name ?? id).slice(0, 80), role: view!.agents[id]?.role ?? "subagent", state: agentState(view!, id) })),
      usage: finish(tally, { autocompact: c.autocompact ?? "", model: c.model }),
    };
  }));
  // Drop the folds of sessions that left the fleet, so the cache does not grow with every session ever seen.
  for (const journal of folds.keys()) if (!seen.has(journal)) folds.delete(journal);
  return { census: census.census, generatedAt: opts.now, sessions: rows.filter((r): r is FleetRow => r !== null) };
}
