// lane.ts — a session's lane, what it is priced against, and how it scored (HIMMEL-4817).
//
// The lane comes from the launch record (LEG_LANE, the launcher's HIMMEL_SESSION_LANE, the config dir, the leg doc),
// never guessed from the model string. A claudex session is priced from the codex weekly bank (the used% delta across
// the leg's window), never at Claude leg-burn weights; the eval row is the per-lane quality measure (CR rounds, judge
// NO-GO rate, red-before-green, LIVE→READY, denials). Read-only: nothing here writes.
import type { View } from "../agui-web/src/reducer.ts";
import { readCodexBankCache } from "../../lanes/bank-status-core.mjs";
import { SUITE } from "./journal-mapper.ts";

export type Lane = "native" | "claudex" | "openrouter" | "cloud";
export const LANES: readonly Lane[] = ["native", "claudex", "openrouter", "cloud"];
export type LaneFrom = "LEG_LANE" | "launcher" | "config-dir" | "doc" | "default";

const REAL = ["native", "claudex", "openrouter"] as const;
const real = (s: string | undefined): Lane | null => ((REAL as readonly string[]).includes(s ?? "") ? (s as Lane) : null);

export function laneOf(launch: Record<string, string>, doc: string): { lane: Lane; laneFrom: LaneFrom } {
  const leg = real(launch.LEG_LANE);
  if (leg) return { lane: leg, laneFrom: "LEG_LANE" };
  const launcher = real(launch.HIMMEL_SESSION_LANE);
  if (launcher) return { lane: launcher, laneFrom: "launcher" };
  const dir = (launch.CLAUDE_CONFIG_DIR ?? "").replace(/\/+$/, "").split("/").pop();
  if (dir === ".claude-codex") return { lane: "claudex", laneFrom: "config-dir" };
  if (dir === ".claude-openrouter") return { lane: "openrouter", laneFrom: "config-dir" };
  const front = /^---\r?\n([\s\S]*?)\r?\n---/.exec(doc)?.[1];
  const fromDoc = real(front ? /^lane:\s*(\S+)\s*$/m.exec(front)?.[1] : undefined) ?? real(/--lane[ =](\w+)/.exec(doc)?.[1]);
  return fromDoc ? { lane: fromDoc, laneFrom: "doc" } : { lane: "native", laneFrom: "default" };
}

export function backendModelOf(lane: Lane, launch: Record<string, string>, model: string | null): string | null {
  return launch.HIMMEL_SESSION_MODEL || (lane !== "native" ? launch.ANTHROPIC_MODEL : undefined) || model || null;
}

export const laneOfJournal = (path: string): Lane =>
  path.includes("/.claude-codex/") ? "claudex" : path.includes("/.claude-openrouter/") ? "openrouter" : "native";

export type CodexBank = { weeklyPct: number; capturedAt: number; resetsAt: number | null };
export function readCodexBank(text: string, now: number, ttlSeconds = 6 * 3600): CodexBank | null {
  const r = readCodexBankCache(text, now, ttlSeconds);
  if (r.kind !== "measured") return null;
  const w = r.readings.find((x: { window: string }) => x.window === "weekly");
  let at: unknown;
  try { at = JSON.parse(text).capturedAt; } catch { return null; }
  const ms = typeof at === "string" ? Date.parse(at) : typeof at === "number" ? (at > 1e12 ? at : at * 1000) : NaN;
  return w && Number.isFinite(ms) ? { weeklyPct: w.usedPct, capturedAt: ms, resetsAt: Number.isFinite(w.resetsAt) ? w.resetsAt : null } : null;
}

// claude-codex's launch reading: `<used %>@<epoch ms>`.
export function codexStartOf(launch: Record<string, string>): { pct: number; at: number } | null {
  const m = /^(\d+(?:\.\d+)?)@(\d+)$/.exec(launch.HIMMEL_CODEX_BANK_START ?? "");
  const pct = m ? Number(m[1]) : NaN, at = m ? Number(m[2]) : NaN;
  return m && Number.isFinite(pct) && pct <= 100 && Number.isSafeInteger(at) && at > 0 ? { pct, at } : null;
}

// scripts/lanes/lib/burn-weights.sh's defaults: the price-weighted token-equivalent leg-burn.sh reports.
export const W = { input: 1, cacheRead: 0.1, cacheCreate: 1.25, output: 5 };
type Ids = { session: string; leg: string; ticket: string | null; model: string | null };
export type Tally = { calls: number; input: number; output: number; cacheRead: number; cacheCreate: number };
export type CostRow = Ids & {
  lane: Lane; bank: "claude" | "codex" | "openrouter"; priced_by: "claude-weights" | "codex-bank" | "unpriced";
  calls: number; input: number; output: number; cache_read: number; cache_create: number; cost_eq: number | null;
  codex_used_pct_start: number | null; codex_used_pct_end: number | null; codex_used_pct_delta: number | null;
};
const BANK = { native: "claude", cloud: "claude", claudex: "codex", openrouter: "openrouter" } as const;

export function costRowOf(a: Ids & { lane: Lane; tally: Tally; codexStart: { pct: number; at: number } | null; codexNow: CodexBank | null }): CostRow {
  const { session, leg, ticket, model, lane, tally: t, codexStart: s, codexNow: n } = a;
  const base = { session, leg, ticket, model, lane, bank: BANK[lane] };
  const counts = { calls: t.calls, input: t.input, output: t.output, cache_read: t.cacheRead, cache_create: t.cacheCreate };
  const none = { codex_used_pct_start: null, codex_used_pct_end: null, codex_used_pct_delta: null };
  if (lane === "native" || lane === "cloud") {
    const cost_eq = Math.round(t.input * W.input + t.cacheRead * W.cacheRead + t.cacheCreate * W.cacheCreate + t.output * W.output);
    return { ...base, priced_by: "claude-weights", ...counts, cost_eq, ...none };
  }
  if (lane === "openrouter") return { ...base, priced_by: "unpriced", ...counts, cost_eq: null, ...none };
  // A lower end reading means the weekly window reset under the leg: no delta, rather than a negative burn.
  const start = s?.pct ?? null, end = n?.weeklyPct ?? null;
  const delta = s && n && start !== null && end !== null && n.capturedAt >= s.at && end >= start ? Math.round((end - start) * 100) / 100 : null;
  return { ...base, priced_by: delta !== null ? "codex-bank" : "unpriced", ...counts, cost_eq: null,
    codex_used_pct_start: start, codex_used_pct_end: end, codex_used_pct_delta: delta };
}

export type EvalRow = Ids & {
  lane: Lane; cr_rounds: number; cr_findings_per_round: number[]; rounds_to_clean: number | null;
  judge_verdicts: number; judge_no_go: number; judge_no_go_rate: number | null; red_before_green: boolean | null;
  live_to_ready_ms: number | null; denials: number; denials_recovered: number;
};

export function evalRowOf(a: Ids & { lane: Lane; rounds: number[]; view: View | null; doc: string }): EvalRow {
  const { session, leg, ticket, model, lane, rounds, view, doc } = a;
  const clean = rounds.indexOf(0);
  let verdicts = 0, noGo = 0;
  for (const m of doc.matchAll(/^- (.*)$/gm)) {
    const v = /(?<![\w-])(NO-GO|GO)(?![\w-])/.exec(m[1]);
    if (v) { verdicts++; if (v[1] === "NO-GO") noGo++; }
  }
  const tools = view ? Object.values(view.tools).sort((x, y) => x.start - y.start) : [];
  const suite = tools.filter((t) => {
    if (t.name !== "Bash") return false;
    try { return SUITE.test(String(JSON.parse(t.args)?.command ?? "")); } catch { return false; }
  });
  const redAt = suite.findIndex((t) => t.status === "error");
  const red_before_green = suite.length === 0 ? null : redAt >= 0 && suite.slice(redAt + 1).some((t) => t.status === "done");
  const mark = (re: RegExp, from = 0) => { const m = re.exec(doc.slice(from)); return m ? { min: Number(m[1]) * 60 + Number(m[2]), end: from + m.index + m[0].length } : null; };
  const live = mark(/^- (\d\d):(\d\d) LIVE\b/m), ready = live && mark(/^- (\d\d):(\d\d) READY\b/m, live.end);
  let l2r = live && ready ? (ready.min - live.min) * 60_000 : null;
  if (l2r !== null && l2r < 0) l2r += 24 * 3600_000;
  const denied = tools.filter((t) => t.failure === "denied");
  return {
    session, leg, ticket, model, lane, cr_rounds: rounds.length, cr_findings_per_round: rounds, rounds_to_clean: clean >= 0 ? clean + 1 : null,
    judge_verdicts: verdicts, judge_no_go: noGo, judge_no_go_rate: verdicts ? noGo / verdicts : null, red_before_green,
    live_to_ready_ms: l2r, denials: denied.length,
    denials_recovered: denied.filter((d) => tools.some((t) => t.start > d.start && t.name === d.name && t.status === "done")).length,
  };
}
