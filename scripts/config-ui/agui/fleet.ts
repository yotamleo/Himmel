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
// HIMMEL-4791: cloud sessions join as rows of role "cloud" (fleet-cloud.ts: the console bucket's cloud-route.jsonl
// plus one cached GitHub read), each under the console its brief names, with its local shepherd leg under it.
//
// HIMMEL-4817: a row carries its lane and how it was found (laneOf: the launch record, never the model string), the
// backend model, a cost row (a claudex leg priced from the codex weekly bank delta, never at Claude weights) and an
// eval row (the per-lane quality measure); the fleet carries the one codex bank reading they were priced against.
//
// ponytail: each request re-folds every journal that grew since the last one (cached on the files' sizes), so a
// fleet of very long journals costs a full read per poll (measured 2026-10-07 on 9 live sessions: 278 ms cold,
// 202 ms warm); upgrade path: a per-file incremental fold (the SSE tail's offsets) once a fleet poll is slow.
import { execFile } from "node:child_process";
import { readFile, stat } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import { agentState, initialView, reduce, type View } from "../agui-web/src/reducer.ts";
import { cloudRoutes, consoleOf, GH_WAIT_MS, readCloudPrs, type CloudPhase, type CloudRoute } from "./fleet-cloud.ts";
import { createJournalMapper } from "./journal-mapper.ts";
import { mergeJournalFiles, sessionFiles } from "./journal-merge.ts";
import { backendModelOf, codexStartOf, costRowOf, evalRowOf, laneOf, readCodexBank, W, type CodexBank, type CostRow, type EvalRow, type Lane, type LaneFrom } from "./lane.ts";
import { resolveJournal } from "./sse.ts";

export const RECENT_MS = 60 * 60 * 1000;
const SCRIPT_TIMEOUT_MS = 30_000;

export type FleetState = "running" | "idle" | "waiting for GO" | "wrapped" | "unknown";
export type FleetRow = {
  run: string | null; pid: number | null; name: string; role: "console" | "leg" | "judge" | "consult" | "interactive" | "cloud"; model: string | null;
  ticket: string | null; pr: number | null; state: FleetState;
  activity: { tool: string; summary: string; at: number } | null; lastEventAt: number | null;
  subagents: { total: number; running: number }; failures: number;
  parent: string | null; predecessor: string | null; agents: { name: string; role: string; state: string }[];
  usage: Usage | null;
  cloud: { url: string | null; phase: CloudPhase } | null;
  runtime: { startedAt: number; endedAt: number | null; elapsedMs: number } | null;
  console: string | null; live: boolean; lock: "held" | "released" | "unknown";
  lane: Lane; laneFrom: LaneFrom | null; backendModel: string | null; cost: CostRow | null; eval: EvalRow | null;
  // HIMMEL-4925: the doc's last Results marker (leg_tail_status), the doc's last write, and the PR's URL.
  marker: string | null; lastSeenAt: number | null; prUrl: string | null;
};
export type ProcessOrphan = { pid: number; owner: string; ageMin: number };
export type Usage = {
  calls: number; input: number; output: number; cacheRead: number; cacheCreate: number; costEq: number | null;
  resident: number | null; ceiling: number; ceilingFrom: "autocompact" | "window"; fill: number | null;
};
// processOrphans (HIMMEL-4925): tick's stale shell-tool wrappers; null when the inventory could not be read.
export type Fleet = { census: "ok" | "degraded" | "unavailable"; generatedAt: number; sessions: FleetRow[]; processOrphans: ProcessOrphan[] | null; banks: { codex: CodexBank | null } };
type CensusRow = { pid: string; name: string; model: string; doc: string; status: string; autocompact?: string; startedAt?: number | null };
type Census = { census: Fleet["census"]; sessions: CensusRow[]; cloudRoutes?: string[]; manifests?: string[]; consoleDocs?: string[] };

// A session name as the launchers write it; anything else in a doc is text, never a link.
const SESSION = /^[A-Za-z0-9._+-]{1,160}$/;
const plain = (s: string | undefined) => (s && SESSION.test(s) ? s : null);

// Where a session sits, read from its own doc only. A leg's console is the one its brief names, or the newest
// console it accepted in a `SUCCESSION accepted: <new> replaces <old>` bullet; a judge's is the console that
// dispatched it; a console hangs under the operator (parent null) and names the console it succeeded.
export function graphOf(role: FleetRow["role"], doc: string): { parent: string | null; predecessor: string | null } {
  if (role === "console") return { parent: null, predecessor: plain(/successor to `?([^\s`]+?)(?:\.md)?`?[\s(]/.exec(doc)?.[1]) };
  let parent = plain(/your console is\W*`([^`]+)`/i.exec(doc)?.[1]);
  if (role === "judge" || role === "consult") parent ??= plain(/dispatched by\s*(?:>\s*)?`([^`]+)`/.exec(doc)?.[1]);
  if (role === "leg" || role === "judge" || role === "consult") {
    for (const m of doc.matchAll(/^- (?:[\d:]+ )?(?:LIVE — )?SUCCESSION accepted: `?([^\s`]+)`? replaces/gm)) parent = plain(m[1]) ?? parent;
  }
  return { parent, predecessor: null };
}

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

// The ceiling is the window the launch declared (HIMMEL-4925: claude-codex's CLAUDE_CODE_MAX_CONTEXT_TOKENS, which a
// claudex session honours over --autocompact); else the session's numeric --autocompact; else a Claude model's window.
// A non-Claude model nobody declared a window for, or a fill past 100 % (so the ceiling is wrong), is not measured.
const num = (s: string | undefined) => (s && /^\d+$/.test(s) ? Number(s) : 0);
function finish(t: Tally | null, c: { autocompact: string; model: string; window?: string; priced?: boolean }): Usage | null {
  if (!t) return null;
  const declared = num(c.window), ac = num(c.autocompact);
  const claude = /claude|opus|sonnet|haiku|fable/i.test(c.model) || c.model === "";
  const ceiling = declared || ac || (/\[1m\]$/i.test(c.model) ? WINDOW_1M : WINDOW);
  const fill = t.resident === null || (!declared && !ac && !claude) ? null : Math.round((t.resident / ceiling) * 1000) / 10;
  return {
    ...t, costEq: c.priced === false ? null : Math.round(t.input * W.input + t.cacheRead * W.cacheRead + t.cacheCreate * W.cacheCreate + t.output * W.output),
    ceiling, ceilingFrom: !declared && ac ? "autocompact" : "window",
    fill: fill !== null && fill > 100 ? null : fill,
  };
}
export const usageOf = (lines: string[], c: { autocompact: string; model: string; window?: string; priced?: boolean }) => finish(tallyOf(lines), c);

function runScript(script: string, env: Record<string, string | undefined>): Promise<Census> {
  return new Promise((ok) => {
    execFile("bash", [script], { env: env as NodeJS.ProcessEnv, timeout: SCRIPT_TIMEOUT_MS, maxBuffer: 4 * 1024 * 1024 }, (err, stdout) => {
      try { if (!err) return ok(JSON.parse(stdout)); } catch { /* fall through */ }
      ok({ census: "unavailable", sessions: [] });
    });
  });
}

// HIMMEL-4925: the shell-tool wrappers tick reports as orphans, from the console kit's own inventory (`--list`: one
// `pid=<pid> owner=<session> age=<n>m` row each); read-only, and null when it failed rather than an empty list.
async function processOrphansOf(opts: { script: string; env: Record<string, string | undefined> }): Promise<ProcessOrphan[] | null> {
  const script = opts.env.CONFIG_UI_ORPHAN_LOOPS || join(dirname(opts.script), "../handover/console-kit/orphan-loops.sh");
  return new Promise((ok) => {
    execFile("bash", [script, "--list"], { env: opts.env as NodeJS.ProcessEnv, timeout: 10_000, maxBuffer: 256 * 1024 }, (err, stdout) => {
      if (err) return ok(null);
      ok(stdout.split("\n").flatMap((l) => {
        const m = /^pid=(\d+) owner=(\S+) age=(\d+)m$/.exec(l.trim());
        const owner = m && plain(m[2]);
        return m && owner ? [{ pid: Number(m[1]), owner, ageMin: Number(m[3]) }] : [];
      }));
    });
  });
}

// HIMMEL-4925: the GitHub repo a PR number belongs to — CONFIG_UI_GITHUB_REPO (owner/name), else this checkout's
// origin. ponytail: every leg's PR is linked into this checkout's repo; a leg working another repo's PR gets a wrong
// link, upgrade path: resolve the repo per handover bucket from the registry once legs routinely ship elsewhere.
const slugs = new Map<string, string | null>();
async function repoSlugOf(checkout: string, env: Record<string, string | undefined>): Promise<string | null> {
  const SLUG = /^[\w.-]+\/[\w.-]+$/;
  if (env.CONFIG_UI_GITHUB_REPO) return SLUG.test(env.CONFIG_UI_GITHUB_REPO) ? env.CONFIG_UI_GITHUB_REPO : null;
  if (!slugs.has(checkout)) slugs.set(checkout, await new Promise<string | null>((ok) => {
    execFile("git", ["-C", checkout, "remote", "get-url", "origin"], { timeout: 3000 }, (err, stdout) => {
      const s = !err && /github\.com[:/]([^/\s]+\/[^/\s]+?)(?:\.git)?\s*$/.exec(stdout)?.[1];
      ok(s && SLUG.test(s) ? s : null);
    });
  }));
  return slugs.get(checkout) ?? null;
}
const prUrlOf = (slug: string | null, pr: number | null) => (slug && pr !== null ? `https://github.com/${slug}/pull/${pr}` : null);

// The cloud sessions the console buckets' routing logs name, each a row under the console its brief names; a GitHub
// read that failed leaves every one unknown (no PR, no URL) rather than failing the fleet.
const CLOUD_STATE: Record<CloudPhase, FleetState> = { working: "running", done: "idle", blocked: "idle", merged: "wrapped", closed: "wrapped", unknown: "unknown" };
async function cloudRows(logs: string[], env: Record<string, string | undefined>, now: number): Promise<FleetRow[]> {
  const read: { lines: string[]; bucket: string }[] = [];
  for (const log of logs) {
    try { read.push({ lines: (await readFile(log, "utf8")).split("\n"), bucket: dirname(log) }); } catch { /* unreadable: skip */ }
  }
  const routes: CloudRoute[] = cloudRoutes(read, now);
  if (!routes.length) return [];
  const prs = await readCloudPrs(routes.map((r) => r.ticket), { gh: env.CONFIG_UI_GH || "gh", env, now, waitMs: GH_WAIT_MS });
  return Promise.all(routes.map(async (r): Promise<FleetRow> => {
    const p = prs?.get(r.ticket) ?? { pr: null, phase: "unknown" as const, url: null };
    return {
      run: null, pid: null, name: `cloud-${r.ticket}`, role: "cloud", model: null, ticket: r.ticket, pr: p.pr, state: CLOUD_STATE[p.phase],
      activity: null, lastEventAt: null, subagents: { total: 0, running: 0 }, failures: 0,
      parent: await consoleOf(r), predecessor: null, agents: [], usage: null, cloud: { url: p.url, phase: p.phase },
      runtime: p.phase === "merged" || p.phase === "closed" ? null : { startedAt: r.at, endedAt: null, elapsedMs: Math.max(0, now - r.at) },
      console: await consoleOf(r), live: p.phase !== "merged" && p.phase !== "closed", lock: "unknown", lane: "cloud", laneFrom: null, backendModel: null, cost: null, eval: null,
      marker: null, lastSeenAt: null, prUrl: null,
    };
  }));
}

const roleOf = (name: string, doc: string): FleetRow["role"] =>
  /-console$/.test(name) ? "console" : /(^|-)consult(-|$)/i.test(name) ? "consult" : /(^|-)judge(-|$)|(^|-)J\d+(-|$)/i.test(name) ? "judge" : doc ? "leg" : "interactive";

// The PR a leg doc names last: `READY <pr> ...` or `PR <n>` / `PR #<n>` in its bullets.
function prOf(text: string): number | null {
  let pr: number | null = null;
  for (const m of text.matchAll(/^- .*?\b(?:READY|PR) #?(\d+)\b/gm)) pr = Number(m[1]);
  return pr;
}

function runtimeOf(start: unknown, fallback: number | undefined, doc: string, wrapped: boolean, now: number, docAt: number): FleetRow["runtime"] {
  const parsed = typeof start === "string" ? Date.parse(start) : typeof start === "number" ? start : NaN;
  const startedAt = Number.isFinite(parsed) ? parsed : fallback;
  if (startedAt === undefined || !Number.isFinite(startedAt)) return null;
  let endedAt: number | null = null;
  if (wrapped) {
    const time = [...doc.matchAll(/^- (\d\d):(\d\d) WRAPPED\b/gm)].at(-1);
    if (!time) return null; // Unknown end is not a running clock.
    // ponytail: Results markers carry HH:MM only, so the doc's write-day supplies
    // the date; upgrade to an explicit WRAPPED timestamp when the writer records one.
    const end = new Date(docAt);
    end.setHours(Number(time[1]), Number(time[2]), 0, 0);
    endedAt = end.getTime();
    if (endedAt < startedAt || endedAt > now) return null;
  }
  return { startedAt, endedAt, elapsedMs: Math.max(0, (endedAt ?? now) - startedAt) };
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

type Folded = { view: View; tally: Tally | null; rounds: number[] };
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
  const rounds: number[] = []; // HIMMEL-4817: the findings count of every critic-panel report, in order
  for (const l of lines) for (const e of mapper.pushLine(l)) {
    const review = e.type === "STATE_SNAPSHOT" ? (e.snapshot as { review?: { findings?: unknown[] } } | undefined)?.review : undefined;
    if (review) rounds.push(review.findings?.length ?? 0);
    view = reduce(view, e as never);
  }
  const out = { key, view, tally: tallyOf(lines), rounds };
  folds.set(journal, out);
  return out;
}

export async function readFleet(opts: { script: string; env: Record<string, string | undefined>; home: string; now: number; redact: (s: string) => string }): Promise<Fleet> {
  const census = await runScript(opts.script, opts.env);
  // HIMMEL-4817: the codex probe's cache, read once per request; unreadable, stale or reset is null.
  const ttl = Number(opts.env.CODEX_BANK_CACHE_TTL_SECONDS);
  let codex: CodexBank | null = null;
  try {
    codex = readCodexBank(await readFile(opts.env.CODEX_BANK_CACHE || join(opts.home, ".himmel", "cache", "codex-bank.json"), "utf8"), opts.now, ttl > 0 ? ttl : undefined);
  } catch { /* no probe cache: unmeasured */ }
  const banks = { codex };
  if (census.census === "unavailable") return { census: "unavailable", generatedAt: opts.now, sessions: [], processOrphans: await processOrphansOf(opts), banks };
  const lockOf = (file: string, doc: string, wrapped: boolean): Promise<FleetRow["lock"]> => {
    if (wrapped) return Promise.resolve("released");
    if (!/^- .*\b(?:lock|release-token)\b.*`[^`]+`/m.test(doc)) return Promise.resolve("unknown");
    return new Promise((ok) => {
      // The lock owner resolves legacy keys and distinguishes free from corrupt or unreadable.
      execFile("bash", [join(dirname(opts.script), "../handover/queue-lock.sh"), "status", file],
        { env: opts.env as NodeJS.ProcessEnv, timeout: 3000, maxBuffer: 64 * 1024 }, (err, stdout) => {
          if (!err && stdout.trim() === "free") return ok("released");
          ok(/status: FRESH/.test(stdout) ? "held" : "unknown");
        });
    });
  };
  const edges = new Map<string, { console: string; at: number | undefined }>();
  for (const file of census.manifests ?? []) {
    const console = plain(basename(file, ".fleet.json"));
    if (!console) continue;
    try {
      const m = JSON.parse(await readFile(file, "utf8"));
      if (m.schema !== 1 || !Array.isArray(m.legs)) continue;
      for (const l of m.legs) if (typeof l.doc === "string") {
        const at = Date.parse(l.added);
        edges.set(l.doc, { console, at: Number.isFinite(at) ? at : undefined });
      }
    } catch { /* malformed or unreadable manifest: no edge */ }
  }
  const seen = new Set<string>();
  const rows = await Promise.all(census.sessions.map(async (c): Promise<FleetRow | null> => {
    let launch: Record<string, string> = {};
    try {
      const env = (await readFile(join(opts.env.CLAUDE_SESSIONS_PROC || "/proc", c.pid, "environ"), "utf8")).split("\0");
      launch = Object.fromEntries(env.filter((v) => v.includes("=")).map((v) => { const i = v.indexOf("="); return [v.slice(0, i), v.slice(i + 1)]; }));
    } catch { /* unavailable launch record: use doc or manifest */ }
    let rec: { sessionId?: unknown; status?: unknown; name?: unknown; startedAt?: unknown } = {};
    const configs = launch.CLAUDE_CONFIG_DIR ? [launch.CLAUDE_CONFIG_DIR] : [join(opts.home, ".claude"), join(opts.home, ".claude-codex")];
    for (const config of configs) {
      try { rec = JSON.parse(await readFile(join(config, "sessions", `${c.pid}.json`), "utf8")); break; } catch { /* not yet written in this lane */ }
    }
    const run = typeof rec.sessionId === "string" ? rec.sessionId : null;
    const found = run ? await resolveJournal(opts.home, run) : null;
    const journal = found && "path" in found ? found.path : null;
    let view: View | null = null, tally: Tally | null = null, rounds: number[] = [];
    if (journal) {
      // Live if any of its files was written recently: a subagent can be busy while the main journal is quiet.
      const { paths } = await sessionFiles(journal);
      const mtimes = await Promise.all(paths.map((p) => stat(p).then((s) => s.mtimeMs, () => 0)));
      if (opts.now - Math.max(0, ...mtimes) > RECENT_MS && roleOf(c.name, c.doc) === "interactive") return null;
      // Only a listed session keeps its fold: a quiet one left off the page drops out of the cache below.
      seen.add(journal);
      ({ view, tally, rounds } = await fold(journal));
    }
    let doc = "", docAt = opts.now;
    if (c.doc) try { doc = await readFile(c.doc, "utf8"); docAt = (await stat(c.doc)).mtimeMs; } catch { /* moved or gone: no doc */ }
    const { lane, laneFrom } = laneOf(launch, doc);
    const backendModel = backendModelOf(lane, launch, c.model || null);
    const tools = view ? Object.values(view.tools).sort((a, b) => b.start - a.start) : [];
    const subs = view ? view.agentOrder.filter((id) => id !== "main") : [];
    const t0 = view?.t0;
    // A session started without -n still has the name the harness gave it.
    const name = c.name || (typeof rec.name === "string" ? rec.name : "") || `pid ${c.pid}`;
    const role = roleOf(name, c.doc);
    const ticket = /^([A-Z][A-Z0-9]+-\d+)\b/.exec(name)?.[1] ?? null;
    // A wrapped leg's window is closed: its codex price must not grow with later account usage (priced only while live).
    const ids = { session: run ?? `pid ${c.pid}`, leg: name, ticket, model: backendModel };
    const graph = graphOf(role, doc);
    // Accepted succession in the doc overrides the original launch environment.
    const parent = role === "console" ? null : graph.parent ?? plain(launch.HIMMEL_CONSOLE_NAME) ?? edges.get(c.doc)?.console ?? null;
    return {
      run, pid: Number(c.pid), name, role, model: c.model || null,
      ticket, pr: role === "leg" ? prOf(doc) : null,
      state: stateOf(c.status, rec.status === "busy"),
      activity: tools[0] && t0 !== undefined ? { tool: tools[0].name, summary: opts.redact(summarize(tools[0].args)).slice(0, 120), at: t0 + tools[0].start } : null,
      lastEventAt: view && t0 !== undefined ? t0 + view.elapsed : null,
      subagents: { total: subs.length, running: view ? subs.filter((id) => agentState(view!, id) === "running").length : 0 },
      failures: view?.failures.length ?? 0,
      ...graph, parent, console: role === "console" ? name : parent, live: c.status !== "WRAPPED", lock: role === "console" ? await lockOf(c.doc, doc, c.status === "WRAPPED") : "unknown",
      lane, laneFrom, backendModel, marker: c.status || null, lastSeenAt: c.doc && doc ? docAt : null, prUrl: null,
      agents: subs.map((id) => ({ name: opts.redact(view!.agents[id]?.name ?? id).slice(0, 80), role: view!.agents[id]?.role ?? "subagent", state: agentState(view!, id) })),
      usage: finish(tally, { autocompact: c.autocompact ?? "", model: c.model, window: launch.CLAUDE_CODE_MAX_CONTEXT_TOKENS, priced: lane === "native" }), cloud: null,
      cost: tally ? costRowOf({ ...ids, lane, tally, codexStart: codexStartOf(launch), codexNow: lane === "claudex" && c.status !== "WRAPPED" ? codex : null }) : null,
      eval: role === "leg" || role === "judge" ? evalRowOf({ ...ids, lane, rounds, view, doc }) : null,
      runtime: runtimeOf(rec.startedAt ?? c.startedAt, edges.get(c.doc)?.at ?? t0, doc, c.status === "WRAPPED", opts.now, docAt),
    };
  }));
  for (const file of census.consoleDocs ?? []) {
    const name = plain(basename(file, ".md"));
    if (!name || rows.some((r) => r?.name === name)) continue;
    try {
      const s = await stat(file);
      if (opts.now - s.mtimeMs > 72 * RECENT_MS) continue;
      const doc = await readFile(file, "utf8");
      const wrapped = /^- (?:[\d:]+ )?WRAPPED\b/m.test(doc);
      rows.push({
        name, role: "console", pid: null, run: null, model: null, ticket: null, pr: null,
        state: wrapped ? "wrapped" : "unknown", activity: null, lastEventAt: null,
        subagents: { total: 0, running: 0 }, failures: 0, ...graphOf("console", doc),
        agents: [], usage: null, cloud: null, runtime: null, console: name, live: false,
        lock: await lockOf(file, doc, wrapped), lane: "native", laneFrom: null, backendModel: null, cost: null, eval: null,
        marker: wrapped ? "WRAPPED" : null, lastSeenAt: s.mtimeMs, prUrl: null,
      });
    } catch { /* archived console moved or unreadable */ }
  }
  const cloud = await cloudRows(census.cloudRoutes ?? [], opts.env, opts.now);
  // A local leg on a cloud session's ticket is its shepherd: it hangs under the cloud node, not the console.
  for (const r of rows) {
    const c = r?.role === "leg" && cloud.find((x) => x.ticket === r.ticket);
    if (r && c && r.console === c.console) r.parent = c.name;
  }
  // Drop the folds of sessions that left the fleet, so the cache does not grow with every session ever seen.
  for (const journal of folds.keys()) if (!seen.has(journal)) folds.delete(journal);
  const sessions = [...rows.filter((r): r is FleetRow => r !== null), ...cloud];
  const slug = await repoSlugOf(join(dirname(opts.script), "../.."), opts.env);
  for (const r of sessions) r.prUrl = prUrlOf(slug, r.pr);
  return { census: census.census, generatedAt: opts.now, sessions, processOrphans: await processOrphansOf(opts), banks };
}
