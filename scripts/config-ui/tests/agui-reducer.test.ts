import { test, expect } from "bun:test";
import { initialView, reduce, reduceAll, applyPatch, stampMissing, settledCount, type View } from "../agui-web/src/reducer";
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
  expect(mid.texts.m1).toEqual({ id: "m1", text: "Reviewing the branch at `6c2bb12`. The diff touches the CI-check cap cases, ", open: true });
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

test("timeline: text, a lone call, a group of three parallel calls, text, a lone call", () => {
  expect(end.entries).toEqual([
    { kind: "text", id: "m1" },
    { kind: "tools", ids: ["t1"] },
    { kind: "tools", ids: ["t2", "t3", "t4"] },
    { kind: "text", id: "m2" },
    { kind: "tools", ids: ["t5"] },
  ]);
});

test("parallel calls take separate lanes; a later call reuses a free lane", () => {
  expect([end.tools.t2.lane, end.tools.t3.lane, end.tools.t4.lane]).toEqual([0, 1, 2]);
  expect(end.tools.t1.lane).toBe(0);
  expect(end.tools.t5.lane).toBe(0);
  expect(end.lanes).toBe(3);
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

test("stampMissing gives a timestamp-free event the receive time and keeps an existing one", () => {
  expect(stampMissing({ type: "TOOL_CALL_START" }, 42)).toEqual({ type: "TOOL_CALL_START", timestamp: 42 });
  expect(stampMissing({ type: "TOOL_CALL_START", timestamp: 7 }, 42).timestamp).toBe(7);
  const v = reduceAll([{ type: "RUN_STARTED", runId: "r" }, { type: "TOOL_CALL_START", toolCallId: "a", toolCallName: "Bash" },
    { type: "TOOL_CALL_RESULT", toolCallId: "a", content: "x" }].map((e, i) => stampMissing(e, 1000 + i * 500)));
  expect([v.tools.a.start, v.tools.a.end]).toEqual([500, 1000]);
});

test("settled counts only terminal verdicts", () => {
  const fs = ["agreed", "fixed", "disproved", "deferred", "conflict", "unaddressed", undefined].map((verdict) => ({ verdict }));
  expect(settledCount(fs)).toBe(4);
});

test("a fresh view is idle and empty", () => {
  expect(initialView()).toMatchObject({ status: "idle", entries: [], eventCount: 0, lanes: 0 });
});
