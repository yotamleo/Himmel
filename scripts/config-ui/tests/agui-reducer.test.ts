import { describe, test, expect } from "bun:test";
import { join } from "node:path";
import { mapFile } from "../agui/journal-mapper.ts";
import { initialView, reduce, reduceAll, applyPatch, makeStamper, settledCount, runClock, type View } from "../agui-web/src/reducer";
import fixture from "../agui-web/src/fixture.json";

// HIMMEL-4480 PR3: the page is a pure fold of AG-UI events into view state; these cases pin it on the
// hand-written review-panel stream (src/fixture.json), which follows the state contract agreed with the mapper.
const events = fixture as Array<Record<string, any>>;
const upTo = (pred: (e: Record<string, any>) => boolean) => reduceAll(events.slice(0, events.findIndex(pred) + 1));
const end: View = reduceAll(events);

test("the full stream ends finished with every event counted", () => {
  expect(end.status).toBe("finished");
  expect(end.runId).toBe("run-7f3a");
  expect(end.eventCount).toBe(events.length);
});

test("text deltas concatenate per message, open until TEXT_MESSAGE_END", () => {
  const mid = upTo((e) => e.type === "TEXT_MESSAGE_CONTENT" && e.delta.startsWith("The diff"));
  expect(mid.texts.m1).toEqual({
    id: "m1", text: "Reviewing the branch at `6c2bb12`. The diff touches the CI-check cap cases, ", open: true, agent: "main", role: "assistant",
  });
  expect(end.texts.m1.open).toBe(false);
  expect(end.texts.m1.text.endsWith("in parallel.")).toBe(true);
});

test("tool args stream in, then the result flips running to done", () => {
  const mid = upTo((e) => e.type === "TOOL_CALL_END" && e.toolCallId === "t1");
  expect(mid.tools.t1).toMatchObject({ name: "Bash", args: '{"command":"git diff origin/main...HEAD --stat"}', status: "running" });
  expect(end.tools.t1.status).toBe("done");
  expect(end.tools.t1.result).toContain("2 files changed");
});

test("an isError result marks the call errored", () => {
  expect(end.tools.t4.status).toBe("error");
  expect(end.tools.t4.result).toBe("Agent timed out after 300s");
});

test("timeline: the turn, text, a lone call, three parallel calls, the critics' own work, text, a lone call", () => {
  const main = end.entries.filter((en) => en.kind !== "text" || end.texts[en.id].agent === "main")
    .filter((en) => en.kind !== "tools" || end.tools[en.ids[0]].agent === "main");
  expect(main).toEqual([
    { kind: "turn", id: "run-7f3a", n: 1, at: 0 },
    { kind: "text", id: "m1" },
    { kind: "tools", ids: ["t1"] },
    { kind: "tools", ids: ["t2", "t3", "t4"] },
    { kind: "text", id: "m2" },
    { kind: "tools", ids: ["t5"] },
  ]);
  // A subagent's call that starts while the leg's Agent calls run is its own entry, never joined to theirs.
  expect(end.entries).toContainEqual({ kind: "tools", ids: ["c3a"] });
});

test("parallel calls take separate lanes within their agent's band; a later call reuses a free lane", () => {
  expect([end.tools.t2.lane, end.tools.t3.lane, end.tools.t4.lane]).toEqual([0, 1, 2]);
  expect(end.tools.t1.lane).toBe(0);
  expect(end.tools.t5.lane).toBe(0);
  expect(end.agents.main.lanes).toBe(3);
  expect(end.tools.c1a.lane).toBe(0); // a critic's first call: lane 0 of its own band
  expect(end.lanes).toBe(Object.values(end.agents).reduce((n, a) => n + a.lanes, 0));
});

test("times are relative to RUN_STARTED", () => {
  expect(end.tools.t1.start).toBe(1300);
  expect(end.tools.t1.end).toBe(1900);
  expect(end.elapsed).toBe(26600);
});

test("STATE_SNAPSHOT replaces state, STATE_DELTA patches it", () => {
  const snap = upTo((e) => e.type === "STATE_SNAPSHOT");
  expect(snap.state.review.findings.map((f: any) => f.verdict)).toEqual([undefined, undefined, undefined]);
  expect(end.state.review.findings.map((f: any) => [f.severity, f.verdict, f.ticket])).toEqual([
    ["crit", "agreed", undefined], ["imp", "deferred", "HIMMEL-4650"], ["sug", "disproved", undefined],
  ]);
  expect(snap.state).not.toBe(end.state); // a delta never mutates an earlier view
});

test("RUN_ERROR ends the run and errors every call still running", () => {
  const cut = events.slice(0, events.findIndex((e) => e.type === "TOOL_CALL_RESULT" && e.toolCallId === "t2") + 1);
  const v = reduceAll([...cut, { type: "RUN_ERROR", message: "stream lost", timestamp: 1759770010000 }]);
  expect(v.status).toBe("error");
  expect(v.error).toBe("stream lost");
  expect([v.tools.t2.status, v.tools.t3.status, v.tools.t4.status]).toEqual(["done", "error", "error"]);
});

test("unknown events, orphan deltas and a bad patch never throw and never lose state", () => {
  const snap = upTo((e) => e.type === "STATE_SNAPSHOT");
  let v = reduce(snap, { type: "SOMETHING_NEW" } as any);
  v = reduce(v, { type: "TEXT_MESSAGE_CONTENT", messageId: "nope", delta: "x" } as any);
  v = reduce(v, { type: "TOOL_CALL_RESULT", toolCallId: "nope", content: "x" } as any);
  v = reduce(v, { type: "STATE_DELTA", delta: [{ op: "replace", path: "/missing/deep", value: 1 }] } as any);
  expect(v.state).toEqual(snap.state);
  expect(v.entries).toEqual(snap.entries);
  expect(v.eventCount).toBe(snap.eventCount + 4);
});

test("applyPatch: add/replace/remove on objects and arrays, '-' appends, escaped pointers", () => {
  const doc = { a: [1, 2], "b/c": { "~d": 1 } };
  expect(applyPatch(doc, [{ op: "add", path: "/a/-", value: 3 }])).toEqual({ a: [1, 2, 3], "b/c": { "~d": 1 } });
  expect(applyPatch(doc, [{ op: "add", path: "/a/0", value: 0 }]).a).toEqual([0, 1, 2]);
  expect(applyPatch(doc, [{ op: "remove", path: "/a/1" }]).a).toEqual([1]);
  expect(applyPatch(doc, [{ op: "replace", path: "/b~1c/~0d", value: 9 }])["b/c"]).toEqual({ "~d": 9 });
  expect(doc).toEqual({ a: [1, 2], "b/c": { "~d": 1 } });
});

test("a stamper gives timestamp-free events the receive time, on the stream's own clock once it has one", () => {
  let wall = 1000;
  const stamp = makeStamper(() => wall);
  expect(stamp({ type: "RUN_STARTED" })).toEqual({ type: "RUN_STARTED", timestamp: 1000 });
  wall = 1500;
  expect(stamp({ type: "TOOL_CALL_START" }).timestamp).toBe(1500);
  // A historical stream: its own timestamp wins, and a later bare event lands 200 ms after it, not at wall time.
  expect(stamp({ type: "TOOL_CALL_ARGS", timestamp: 7 }).timestamp).toBe(7);
  wall = 1700;
  expect(stamp({ type: "TOOL_CALL_END" }).timestamp).toBe(207);
  const s2 = makeStamper((() => { let t = 0; return () => (t += 500); })());
  const v = reduceAll([{ type: "RUN_STARTED", runId: "r" }, { type: "TOOL_CALL_START", toolCallId: "a", toolCallName: "Bash" },
    { type: "TOOL_CALL_RESULT", toolCallId: "a", content: "x" }].map(s2));
  expect([v.tools.a.start, v.tools.a.end]).toEqual([500, 1000]);
});

test("RUN_FINISHED closes calls that never reported a result", () => {
  const v = reduceAll([{ type: "RUN_STARTED", runId: "r", timestamp: 0 }, { type: "TOOL_CALL_START", toolCallId: "a", toolCallName: "Bash", timestamp: 100 },
    { type: "RUN_FINISHED", timestamp: 400 }]);
  expect(v.status).toBe("finished");
  expect([v.tools.a.status, v.tools.a.end, v.tools.a.result]).toEqual(["done", 400, undefined]);
});

test("applyPatch rejects a path that is not a JSON Pointer instead of replacing the document", () => {
  expect(() => applyPatch({ a: 1 }, [{ op: "replace", path: "a", value: 2 }])).toThrow();
  expect(applyPatch({ a: 1 }, [{ op: "replace", path: "", value: 2 }])).toBe(2);
});

test("settled counts only terminal verdicts", () => {
  const fs = ["agreed", "fixed", "disproved", "deferred", "conflict", "unaddressed", undefined].map((verdict) => ({ verdict }));
  expect(settledCount(fs)).toBe(4);
});

test("a fresh view is idle and empty", () => {
  expect(initialView()).toMatchObject({ status: "idle", entries: [], eventCount: 0, lanes: 0 });
});

// HIMMEL-4646: three /pr-check Suggestions deferred from #1961.
test("RUN_FINISHED and RUN_ERROR close a text message that never got TEXT_MESSAGE_END", () => {
  const open = [{ type: "RUN_STARTED", runId: "r", timestamp: 0 }, { type: "TEXT_MESSAGE_START", messageId: "m", timestamp: 10 },
    { type: "TEXT_MESSAGE_CONTENT", messageId: "m", delta: "half", timestamp: 20 }];
  expect(reduceAll([...open, { type: "RUN_FINISHED", timestamp: 30 }]).texts.m).toEqual({ id: "m", text: "half", open: false, agent: "main" });
  expect(reduceAll([...open, { type: "RUN_ERROR", message: "x", timestamp: 30 }]).texts.m.open).toBe(false);
});

test("the run clock re-anchors to the wall clock when the run starts, even though elapsed is still zero", () => {
  const a0 = runClock(undefined, { elapsed: 0, status: "idle" }, 1000).anchor;
  // The page sat idle for 5s, then RUN_STARTED arrived: elapsed 0, status running.
  const started = runClock(a0, { elapsed: 0, status: "running" }, 6000);
  expect(started.now).toBe(0);
  expect(runClock(started.anchor, { elapsed: 0, status: "running" }, 6500).now).toBe(500);
  // A new event moves elapsed: re-anchor there.
  const next = runClock(started.anchor, { elapsed: 800, status: "running" }, 7000);
  expect(next.now).toBe(800);
  // Not running: the clock is frozen at elapsed.
  expect(runClock(next.anchor, { elapsed: 800, status: "finished" }, 9000).now).toBe(800);
});

test("applyPatch rejects inherited member names instead of traversing or replacing them", () => {
  for (const k of ["constructor", "__proto__", "toString"]) {
    expect(() => applyPatch({ a: 1 }, [{ op: "replace", path: `/${k}`, value: 1 }])).toThrow();
    expect(() => applyPatch({ a: 1 }, [{ op: "remove", path: `/${k}` }])).toThrow();
    expect(() => applyPatch({ a: 1 }, [{ op: "replace", path: `/${k}/x`, value: 1 }])).toThrow();
  }
  expect(applyPatch({ a: 1 }, [{ op: "add", path: "/constructor", value: 2 }])).toHaveProperty("constructor", 2);
});

// HIMMEL-4669: which agent did what, and where it failed. Driven by the mapper's own output for the
// agents.jsonl journal, so the reducer is pinned to the fields the mapper emits.
describe("agents and failures", () => {
  const { events: mapped } = mapFile(join(import.meta.dir, "fixtures", "agui", "agents.jsonl"));
  const v = reduceAll(mapped as any);

  test("agents register in order of appearance with name, role and model", () => {
    expect(v.agentOrder).toEqual(["main", "a1b2c3"]);
    expect(v.agents.main).toMatchObject({ name: "HIMMEL-4669-roadmap-console", role: "console", model: "claude-opus-5-5" });
    expect(v.agents.a1b2c3).toMatchObject({ name: "Review the diff", role: "critic", kind: "code-critic", model: "claude-sonnet-5-5", parentToolCallId: "toolu_agent" });
  });

  test("every call and text is attributed, and calls are counted per agent", () => {
    expect(v.tools.toolu_s1.agent).toBe("a1b2c3");
    expect(v.tools.toolu_agent.agent).toBe("main");
    expect(Object.values(v.texts).filter((t) => t.agent === "a1b2c3").map((t) => t.role)).toEqual(["user", "assistant"]);
    expect([v.agents.main.calls, v.agents.a1b2c3.calls]).toEqual([5, 1]);
  });

  test("failures keep their kind, in stream order, and count against their agent", () => {
    expect(v.failures).toEqual([
      { kind: "tool", id: "toolu_suite" }, { kind: "tool", id: "toolu_push" }, { kind: "tool", id: "toolu_msg" },
      { kind: "tool", id: "toolu_cat" }, { kind: "text", id: expect.any(String) },
    ]);
    expect([v.tools.toolu_suite.failure, v.tools.toolu_push.failure, v.tools.toolu_msg.failure, v.tools.toolu_cat.failure])
      .toEqual(["suite", "denied", "blocked", "error"]);
    expect(v.tools.toolu_msg.status).toBe("done"); // a BLOCKED report is a failure, but the call itself worked
    expect(v.texts[v.failures[4].id].failure).toBe("blocked");
    expect([v.agents.main.failures, v.agents.a1b2c3.failures]).toEqual([5, 0]);
  });

  test("a bare isError result still counts as a failure; a stream with no agent is one agent", () => {
    const w = reduceAll([{ type: "RUN_STARTED", runId: "r", timestamp: 0 }, { type: "TOOL_CALL_START", toolCallId: "a", toolCallName: "Bash", timestamp: 1 },
      { type: "TOOL_CALL_RESULT", toolCallId: "a", content: "boom", isError: true, timestamp: 2 }]);
    expect(w.tools.a).toMatchObject({ status: "error", failure: "error", agent: "main" });
    expect(w.agentOrder).toEqual(["main"]);
    expect(w.agents.main).toMatchObject({ name: "agent", role: "agent", calls: 1, failures: 1 });
  });

  test("RUN_ERROR fails the calls it cuts off", () => {
    const w = reduceAll([{ type: "RUN_STARTED", runId: "r", timestamp: 0 }, { type: "TOOL_CALL_START", toolCallId: "a", toolCallName: "Bash", timestamp: 1 },
      { type: "RUN_ERROR", message: "lost", timestamp: 2 }]);
    expect(w.failures).toEqual([{ kind: "tool", id: "a" }]);
  });

  test("a later START with a better name or model updates the agent, keeping its counts", () => {
    const w = reduceAll([{ type: "RUN_STARTED", runId: "r", timestamp: 0 },
      { type: "TOOL_CALL_START", toolCallId: "a", toolCallName: "Read", agent: { id: "x", name: "agent x", role: "subagent" }, timestamp: 1 },
      { type: "TOOL_CALL_START", toolCallId: "b", toolCallName: "Read", agent: { id: "x", name: "tests", role: "critic", model: "m" }, timestamp: 2 }]);
    expect(w.agents.x).toMatchObject({ name: "tests", role: "critic", model: "m", calls: 2 });
  });

  test("each RUN_STARTED opens a numbered turn", () => {
    const w = reduceAll([{ type: "RUN_STARTED", runId: "a", timestamp: 0 }, { type: "RUN_FINISHED", timestamp: 5 },
      { type: "RUN_STARTED", runId: "b", timestamp: 9 }]);
    expect(w.entries).toEqual([{ kind: "turn", id: "a", n: 1, at: 0 }, { kind: "turn", id: "b", n: 2, at: 9 }]);
  });

  test("a run a background subagent opened is not a turn", () => {
    const w = reduceAll([{ type: "RUN_STARTED", runId: "a", timestamp: 0 }, { type: "RUN_FINISHED", timestamp: 5 },
      { type: "RUN_STARTED", runId: "x:1", agent: { id: "x", name: "late", role: "subagent" }, timestamp: 6 }, { type: "RUN_FINISHED", timestamp: 7 }]);
    expect(w.entries.filter((en) => en.kind === "turn").length).toBe(1);
    expect(w.agentOrder).toEqual(["x"]);
    expect(w.status).toBe("finished");
  });
});
