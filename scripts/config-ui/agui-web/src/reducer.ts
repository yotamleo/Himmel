// AG-UI events -> view state, as a pure fold: the page dispatches every event from @ag-ui/client
// here, and the suite (tests/agui-reducer.test.ts) drives it with the recorded fixture stream.
// No runtime imports, so the CI suite runs without `bun install`.
import type { BaseEvent } from "@ag-ui/core";

// HIMMEL-4669: every text and call belongs to an agent (the mapper's `agent` on START events; a stream without
// it is all one agent, "main"), and a failure is a call or text the mapper classified (`failure`), or a call a
// run error cut off.
export type Failure = "denied" | "suite" | "blocked" | "error";
export type Role = "console" | "leg" | "judge" | "critic" | "subagent" | "agent";
export type Agent = {
  id: string; name: string; role: Role; model?: string; kind?: string; parentToolCallId?: string;
  calls: number; failures: number; lanes: number; // lanes: its rows in the run strip
  last: number; // HIMMEL-4711: elapsed ms of the last event that touched it
};
export type Text = { id: string; text: string; open: boolean; agent: string; role?: "user" | "assistant"; failure?: Failure };
export type ToolStatus = "running" | "done" | "error";
export type Tool = {
  id: string; name: string; args: string; result?: string; status: ToolStatus; failure?: Failure;
  parentMessageId?: string; start: number; end?: number; lane: number; agent: string;
};
// A turn opens at each RUN_STARTED; texts and calls follow it in arrival order.
export type Entry = { kind: "turn"; id: string; n: number; at: number } | { kind: "text"; id: string } | { kind: "tools"; ids: string[] };
export type FailureRef = { kind: "tool" | "text"; id: string };
export type View = {
  status: "idle" | "running" | "finished" | "error";
  runId?: string; error?: string;
  t0?: number; elapsed: number; eventCount: number;
  entries: Entry[]; texts: Record<string, Text>; tools: Record<string, Tool>;
  agents: Record<string, Agent>; agentOrder: string[]; failures: FailureRef[];
  sideRun?: boolean; // the open run is a background subagent's one-record run, not a turn
  lanes: number; laneEnds: Record<string, (number | null)[]>; // lanes: the strip's rows, every agent's summed
  state: any;
};
type Ev = BaseEvent & Record<string, any>;

export const initialView = (): View => ({
  status: "idle", elapsed: 0, eventCount: 0, entries: [], texts: {}, tools: {},
  agents: {}, agentOrder: [], failures: [], lanes: 0, laneEnds: {}, state: {},
});

const ROLES = new Set<Role>(["console", "leg", "judge", "critic", "subagent", "agent"]);
const FAILURES = new Set<Failure>(["denied", "suite", "blocked", "error"]);

// The agent an event names, merged into the registry (later events may know its model or real name).
function withAgent(v: View, e: Ev): { v: View; id: string } {
  const a = e.agent && typeof e.agent === "object" && typeof e.agent.id === "string" ? e.agent : { id: "main" };
  const prev = v.agents[a.id];
  const pick = (k: string) => (typeof a[k] === "string" ? { [k]: a[k] } : {});
  const agent: Agent = {
    ...(prev ?? { id: a.id, name: "agent", role: "agent", calls: 0, failures: 0, lanes: 0, last: v.elapsed }),
    ...pick("name"), ...pick("model"), ...pick("kind"), ...pick("parentToolCallId"),
    ...(ROLES.has(a.role) ? { role: a.role } : {}),
  };
  return {
    id: a.id,
    v: { ...v, agents: { ...v.agents, [a.id]: agent }, agentOrder: prev ? v.agentOrder : [...v.agentOrder, a.id] },
  };
}

function addFailure(v: View, ref: FailureRef, agent: string): View {
  const a = v.agents[agent];
  return { ...v, failures: [...v.failures, ref], agents: a ? { ...v.agents, [agent]: { ...a, failures: a.failures + 1 } } : v.agents };
}
const failureOf = (e: Ev): Failure | undefined => (FAILURES.has(e.failure) ? e.failure : e.isError === true ? "error" : undefined);

// Milliseconds since RUN_STARTED; an event without a timestamp keeps the last known time.
function clock(v: View, e: Ev): { t0?: number; at: number } {
  if (typeof e.timestamp !== "number") return { t0: v.t0, at: v.elapsed };
  const t0 = v.t0 ?? e.timestamp;
  return { t0, at: Math.max(v.elapsed, e.timestamp - t0) };
}

// The first lane whose calls have all finished by `at`, so parallel calls stack and later ones reuse lanes.
function freeLane(ends: (number | null)[], at: number): number {
  const i = ends.findIndex((end) => end !== null && end <= at);
  return i === -1 ? ends.length : i;
}

function finish(v: View, id: string, at: number, patch: Partial<Tool>): View {
  const t = v.tools[id];
  const ends = (v.laneEnds[t.agent] ?? []).slice();
  ends[t.lane] = at;
  const out = { ...v, laneEnds: { ...v.laneEnds, [t.agent]: ends }, tools: { ...v.tools, [id]: { ...t, ...patch, end: at } } };
  // A call counts as one failure however many times it is failed (a result after a run error already failed it).
  return patch.failure && !t.failure ? addFailure(out, { kind: "tool", id }, t.agent) : out;
}

function closeTexts(v: View): View {
  const texts = Object.fromEntries(Object.entries(v.texts).map(([id, m]) => [id, m.open ? { ...m, open: false } : m]));
  return { ...v, texts };
}

// The page's live clock: `anchor` pairs the last elapsed with the wall time it was seen. It re-anchors
// when elapsed moves OR the status changes, so a run that starts (elapsed still 0) after an idle wait
// does not inherit the time spent idle.
export type ClockAnchor = { elapsed: number; status: View["status"]; wall: number };
export function runClock(
  anchor: ClockAnchor | undefined, view: { elapsed: number; status: View["status"] }, wall: number,
): { anchor: ClockAnchor; now: number } {
  const a = anchor && anchor.elapsed === view.elapsed && anchor.status === view.status
    ? anchor : { elapsed: view.elapsed, status: view.status, wall };
  return { anchor: a, now: view.status === "running" ? view.elapsed + (wall - a.wall) : view.elapsed };
}

// Every event that names an agent, or one of its calls or texts, marks that agent's last activity.
export function reduce(prev: View, e: Ev): View {
  const v = fold(prev, e);
  const id = e.agent?.id ?? v.tools[e.toolCallId]?.agent ?? v.texts[e.messageId]?.agent;
  const a = typeof id === "string" ? v.agents[id] : undefined;
  return a ? { ...v, agents: { ...v.agents, [a.id]: { ...a, last: v.elapsed } } } : v;
}

function fold(prev: View, e: Ev): View {
  const { t0, at } = clock(prev, e);
  let v: View = { ...prev, t0, elapsed: at, eventCount: prev.eventCount + 1 };
  switch (e.type) {
    case "RUN_STARTED": {
      // A run a background subagent opened for one late record is not a turn of the session.
      if (e.agent?.id && e.agent.id !== "main") return withAgent({ ...v, status: "running", runId: e.runId, sideRun: true }, e).v;
      const n = v.entries.filter((en) => en.kind === "turn").length + 1;
      return { ...v, status: "running", runId: e.runId, sideRun: false, entries: [...v.entries, { kind: "turn", id: String(e.runId ?? n), n, at }] };
    }
    // A turn that ends closes the session's own calls still open, as done with no result; a subagent's calls stay
    // open, since a background subagent outlives the turn and its results arrive later. A run that errors (the
    // stream itself failed) closes every open call as an error. Likewise a text message that never got
    // TEXT_MESSAGE_END stops being open. A background subagent's one-record run closes nothing.
    case "RUN_FINISHED": {
      if (v.sideRun) return { ...v, status: "finished", sideRun: false };
      for (const t of Object.values(v.tools)) if (t.status === "running" && t.agent === "main") v = finish(v, t.id, at, { status: "done" });
      return { ...closeTexts(v), status: "finished" };
    }
    case "RUN_ERROR": {
      for (const t of Object.values(v.tools)) if (t.status === "running") v = finish(v, t.id, at, { status: "error", failure: "error" });
      return { ...closeTexts(v), status: "error", error: e.message };
    }
    case "TEXT_MESSAGE_START": {
      if (v.texts[e.messageId]) return v;
      const { v: w, id: agent } = withAgent(v, e);
      const failure = failureOf(e);
      const text: Text = {
        id: e.messageId, text: "", open: true, agent,
        ...(e.role === "user" || e.role === "assistant" ? { role: e.role } : {}), ...(failure ? { failure } : {}),
      };
      const out = { ...w, entries: [...w.entries, { kind: "text" as const, id: e.messageId }], texts: { ...w.texts, [e.messageId]: text } };
      return failure ? addFailure(out, { kind: "text", id: e.messageId }, agent) : out;
    }
    case "TEXT_MESSAGE_CONTENT": {
      const m = v.texts[e.messageId];
      return m ? { ...v, texts: { ...v.texts, [m.id]: { ...m, text: m.text + (e.delta ?? "") } } } : v;
    }
    case "TEXT_MESSAGE_END": {
      const m = v.texts[e.messageId];
      return m ? { ...v, texts: { ...v.texts, [m.id]: { ...m, open: false } } } : v;
    }
    case "TOOL_CALL_START": {
      if (v.tools[e.toolCallId]) return v;
      const { v: w, id: agent } = withAgent(v, e);
      // Lanes are per agent: each agent is one band of the strip, its parallel calls stacked inside it.
      const ends = (w.laneEnds[agent] ?? []).slice();
      const lane = freeLane(ends, at);
      ends[lane] = null;
      const tool: Tool = {
        id: e.toolCallId, name: e.toolCallName ?? "tool", args: "", status: "running",
        parentMessageId: e.parentMessageId, start: at, lane, agent,
      };
      // A call that starts while a call of the same agent's last group is still running joins that group: they ran in parallel.
      const last = w.entries[w.entries.length - 1];
      const entries = last?.kind === "tools" && w.tools[last.ids[0]].agent === agent && last.ids.some((id) => w.tools[id].status === "running")
        ? [...w.entries.slice(0, -1), { kind: "tools" as const, ids: [...last.ids, tool.id] }]
        : [...w.entries, { kind: "tools" as const, ids: [tool.id] }];
      const a = w.agents[agent];
      const grown = Math.max(a.lanes, lane + 1);
      return {
        ...w, entries, laneEnds: { ...w.laneEnds, [agent]: ends }, lanes: w.lanes + grown - a.lanes,
        agents: { ...w.agents, [agent]: { ...a, calls: a.calls + 1, lanes: grown } }, tools: { ...w.tools, [tool.id]: tool },
      };
    }
    case "TOOL_CALL_ARGS": {
      const t = v.tools[e.toolCallId];
      return t ? { ...v, tools: { ...v.tools, [t.id]: { ...t, args: t.args + (e.delta ?? "") } } } : v;
    }
    case "TOOL_CALL_RESULT": {
      const t = v.tools[e.toolCallId];
      if (!t) return v;
      // An Agent call's result may be the first event to name the subagent it ran.
      if (e.subagent?.id) v = withAgent(v, { agent: e.subagent } as Ev).v;
      const failure = failureOf(e);
      return finish(v, t.id, at, { status: e.isError === true ? "error" : "done", result: String(e.content ?? ""), ...(failure ? { failure } : {}) });
    }
    case "STATE_SNAPSHOT":
      return { ...v, state: e.snapshot };
    case "STATE_DELTA":
      try { return { ...v, state: applyPatch(v.state, e.delta ?? []) }; }
      catch { return v; } // a patch that does not apply is dropped whole, as the AG-UI client does
    default:
      return v; // TOOL_CALL_END, steps, snapshots of messages and anything newer: counted, not rendered
  }
}

// HIMMEL-4711: what is running now. An agent runs while it has a call open, or while the Agent call that spawned
// it is open (a background subagent's Agent call returns at launch, so its own open calls still count); the
// session agent ("main") also while its turn is open. An agent whose parent call failed is failed, whatever it
// left open; otherwise a finished agent failed only if the run errored.
export type AgentState = "running" | "done" | "failed";
export function agentState(v: View, id: string): AgentState {
  const parent = v.tools[v.agents[id]?.parentToolCallId ?? ""];
  if (parent?.status === "error") return "failed";
  if (Object.values(v.tools).some((t) => t.agent === id && t.status === "running")) return "running";
  if (parent) return parent.status === "running" ? "running" : "done";
  if (v.status === "error") return "failed";
  return id === "main" && v.status === "running" && !v.sideRun ? "running" : "done";
}
export const runningCount = (v: View) => v.agentOrder.filter((id) => agentState(v, id) === "running").length;
// The agent's newest call still open, if any.
export const currentCall = (v: View, id: string): Tool | undefined =>
  Object.values(v.tools).filter((t) => t.agent === id && t.status === "running").sort((a, b) => b.start - a.start)[0];

// The top bar's state word. A live page keeps tailing the journal after a turn ends, so it is never "finished"
// until the stream itself closes: between turns it is idle, with the age of the last event.
export function liveness(v: View, src: { live: boolean; closed: boolean }, wall: number): { word: string; cls: View["status"] } {
  if (v.status === "error") return { word: "stopped", cls: "error" };
  if (v.status === "idle") return { word: "connecting", cls: "idle" };
  if (!src.live) return v.status === "running" ? { word: "streaming", cls: "running" } : { word: "finished", cls: "finished" };
  if (v.status === "running" || runningCount(v) > 0) return { word: "live", cls: "running" };
  if (src.closed) return { word: "finished", cls: "finished" };
  const s = Math.max(0, Math.round((wall - (v.t0 ?? wall) - v.elapsed) / 1000));
  return { word: `idle · last event ${s < 60 ? `${s}s` : `${Math.floor(s / 60)}m ${s % 60}s`} ago`, cls: "idle" };
}

export const reduceAll = (events: Ev[], from: View = initialView()): View => events.reduce(reduce, from);

// AG-UI timestamps are optional; a live event without one is stamped when it arrives, so durations and lane
// reuse stay real instead of collapsing to zero. Once the stream has carried its own timestamp, a bare event
// is placed on that clock (its last timestamp plus the wall time since), so a replayed historical run never
// jumps to the present.
export function makeStamper(now: () => number) {
  let last: { ts: number; wall: number } | undefined;
  return <E extends { timestamp?: number }>(e: E): E => {
    const wall = now();
    const ts = typeof e.timestamp === "number" ? e.timestamp : last ? last.ts + (wall - last.wall) : wall;
    last = { ts, wall };
    return ts === e.timestamp ? e : { ...e, timestamp: ts };
  };
}

// A finding is settled once it has a terminal verdict; conflict and unaddressed still need a decision.
const TERMINAL = new Set(["agreed", "fixed", "disproved", "deferred"]);
export const settledCount = (findings: { verdict?: string }[]) => findings.filter((f) => TERMINAL.has(f.verdict ?? "")).length;

// RFC 6902 add / remove / replace (the ops the mapper emits), copy-on-write: the input is never mutated.
type Op = { op: string; path: string; value?: unknown };
const unescape = (s: string) => s.replace(/~1/g, "/").replace(/~0/g, "~");

export function applyPatch<T>(doc: T, ops: Op[]): T {
  let out: any = doc;
  for (const o of ops) {
    if (typeof o.path !== "string" || (o.path !== "" && !o.path.startsWith("/"))) throw new Error(`not a JSON Pointer: ${o.path}`);
    out = applyOp(out, o.path.split("/").slice(1).map(unescape), o);
  }
  return out;
}

function applyOp(node: any, keys: string[], o: Op): any {
  if (keys.length === 0) {
    if (o.op === "add" || o.op === "replace") return o.value;
    throw new Error(`cannot ${o.op} the document root`);
  }
  if (node === null || typeof node !== "object") throw new Error(`no container at ${o.path}`);
  const [k, ...rest] = keys;
  if (Array.isArray(node)) {
    const copy = node.slice();
    const i = k === "-" ? copy.length : Number(k);
    if (!Number.isInteger(i) || i < 0 || i > copy.length) throw new Error(`bad index ${k} at ${o.path}`);
    if (rest.length) {
      if (i >= copy.length) throw new Error(`no element ${k} at ${o.path}`);
      copy[i] = applyOp(copy[i], rest, o);
    } else if (o.op === "add") copy.splice(i, 0, o.value);
    else if (i >= copy.length) throw new Error(`no element ${k} at ${o.path}`);
    else if (o.op === "remove") copy.splice(i, 1);
    else if (o.op === "replace") copy[i] = o.value;
    else throw new Error(`unsupported op ${o.op}`);
    return copy;
  }
  const copy = { ...node };
  if (rest.length) {
    if (!Object.hasOwn(copy, k)) throw new Error(`no member ${k} at ${o.path}`);
    copy[k] = applyOp(copy[k], rest, o);
  } else if (o.op === "add") copy[k] = o.value;
  else if (!Object.hasOwn(copy, k)) throw new Error(`no member ${k} at ${o.path}`);
  else if (o.op === "remove") delete copy[k];
  else if (o.op === "replace") copy[k] = o.value;
  else throw new Error(`unsupported op ${o.op}`);
  return copy;
}
