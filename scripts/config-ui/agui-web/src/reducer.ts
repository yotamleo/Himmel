// AG-UI events -> view state, as a pure fold: the page dispatches every event from @ag-ui/client
// here, and the suite (tests/agui-reducer.test.ts) drives it with the recorded fixture stream.
// No runtime imports, so the CI suite runs without `bun install`.
import type { BaseEvent } from "@ag-ui/core";

export type Text = { id: string; text: string; open: boolean };
export type ToolStatus = "running" | "done" | "error";
export type Tool = {
  id: string; name: string; args: string; result?: string; status: ToolStatus;
  parentMessageId?: string; start: number; end?: number; lane: number;
};
export type Entry = { kind: "text"; id: string } | { kind: "tools"; ids: string[] };
export type View = {
  status: "idle" | "running" | "finished" | "error";
  runId?: string; error?: string;
  t0?: number; elapsed: number; eventCount: number;
  entries: Entry[]; texts: Record<string, Text>; tools: Record<string, Tool>;
  lanes: number; laneEnds: (number | null)[];
  state: any;
};
type Ev = BaseEvent & Record<string, any>;

export const initialView = (): View => ({
  status: "idle", elapsed: 0, eventCount: 0, entries: [], texts: {}, tools: {}, lanes: 0, laneEnds: [], state: {},
});

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
  const laneEnds = v.laneEnds.slice();
  laneEnds[t.lane] = at;
  return { ...v, laneEnds, tools: { ...v.tools, [id]: { ...t, ...patch, end: at } } };
}

export function reduce(prev: View, e: Ev): View {
  const { t0, at } = clock(prev, e);
  let v: View = { ...prev, t0, elapsed: at, eventCount: prev.eventCount + 1 };
  switch (e.type) {
    case "RUN_STARTED":
      return { ...v, status: "running", runId: e.runId };
    // A run that ends closes every call still open: finished ones as done (with no result), failed ones as errors.
    case "RUN_FINISHED": {
      for (const t of Object.values(v.tools)) if (t.status === "running") v = finish(v, t.id, at, { status: "done" });
      return { ...v, status: "finished" };
    }
    case "RUN_ERROR": {
      for (const t of Object.values(v.tools)) if (t.status === "running") v = finish(v, t.id, at, { status: "error" });
      return { ...v, status: "error", error: e.message };
    }
    case "TEXT_MESSAGE_START":
      if (v.texts[e.messageId]) return v;
      return {
        ...v, entries: [...v.entries, { kind: "text", id: e.messageId }],
        texts: { ...v.texts, [e.messageId]: { id: e.messageId, text: "", open: true } },
      };
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
      const lane = freeLane(v.laneEnds, at);
      const laneEnds = v.laneEnds.slice();
      laneEnds[lane] = null;
      const tool: Tool = {
        id: e.toolCallId, name: e.toolCallName ?? "tool", args: "", status: "running",
        parentMessageId: e.parentMessageId, start: at, lane,
      };
      // A call that starts while a call of the last group is still running joins that group: they ran in parallel.
      const last = v.entries[v.entries.length - 1];
      const entries = last?.kind === "tools" && last.ids.some((id) => v.tools[id].status === "running")
        ? [...v.entries.slice(0, -1), { kind: "tools" as const, ids: [...last.ids, tool.id] }]
        : [...v.entries, { kind: "tools" as const, ids: [tool.id] }];
      return { ...v, entries, laneEnds, lanes: Math.max(v.lanes, lane + 1), tools: { ...v.tools, [tool.id]: tool } };
    }
    case "TOOL_CALL_ARGS": {
      const t = v.tools[e.toolCallId];
      return t ? { ...v, tools: { ...v.tools, [t.id]: { ...t, args: t.args + (e.delta ?? "") } } } : v;
    }
    case "TOOL_CALL_RESULT": {
      const t = v.tools[e.toolCallId];
      if (!t) return v;
      return finish(v, t.id, at, { status: e.isError === true ? "error" : "done", result: String(e.content ?? "") });
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
    if (!(k in copy)) throw new Error(`no member ${k} at ${o.path}`);
    copy[k] = applyOp(copy[k], rest, o);
  } else if (o.op === "add") copy[k] = o.value;
  else if (!(k in copy)) throw new Error(`no member ${k} at ${o.path}`);
  else if (o.op === "remove") delete copy[k];
  else if (o.op === "replace") copy[k] = o.value;
  else throw new Error(`unsupported op ${o.op}`);
  return copy;
}
