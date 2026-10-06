import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { createJournalMapper, mapFile, mapJournal } from "../agui/journal-mapper.ts";
import type { AguiEvent } from "../agui/events.ts";
import { aguiViolations } from "./agui-schema.ts";

const FIX = join(import.meta.dir, "fixtures", "agui");
const fixture = (name: string) => join(FIX, name);
const types = (events: AguiEvent[]) => events.map((e) => e.type);
const valid = (events: AguiEvent[]) => {
  const bad = events.flatMap((e) => aguiViolations(e as Record<string, unknown>));
  expect(bad).toEqual([]);
  // A tool call's parentMessageId names a message the stream already started.
  const started = new Set<string>();
  for (const e of events) {
    if (e.type === "TEXT_MESSAGE_START") started.add(e.messageId);
    if (e.type === "TOOL_CALL_START" && e.parentMessageId !== undefined) expect(started.has(e.parentMessageId)).toBe(true);
  }
};

describe("happy path", () => {
  const { events, stats } = mapFile(fixture("happy-path.jsonl"));

  test("emits the run, both messages and the tool call in journal order", () => {
    expect(types(events)).toEqual([
      "RUN_STARTED",
      "TEXT_MESSAGE_START", "TEXT_MESSAGE_CONTENT", "TEXT_MESSAGE_END", // the user prompt
      "TEXT_MESSAGE_START", "TEXT_MESSAGE_CONTENT", "TEXT_MESSAGE_END", // "Listing the root."
      "TOOL_CALL_START", "TOOL_CALL_ARGS", "TOOL_CALL_END",
      "TOOL_CALL_RESULT",
      "TEXT_MESSAGE_START", "TEXT_MESSAGE_CONTENT", "TEXT_MESSAGE_END",
      "RUN_FINISHED",
    ]);
  });

  test("every event validates against the pinned AG-UI schema", () => valid(events));

  test("ids, roles, args and timestamps come from the journal", () => {
    expect(events[0]).toEqual({ type: "RUN_STARTED", threadId: "sess-happy", runId: "u-prompt-1", timestamp: Date.parse("2026-10-06T10:00:00.000Z") });
    expect(events[1]).toMatchObject({ messageId: "u-prompt-1", role: "user" });
    expect(events[2]).toMatchObject({ messageId: "u-prompt-1", delta: "List the files in the repo root." });
    expect(events[4]).toMatchObject({ messageId: "a-text-1", role: "assistant" });
    expect(events[7]).toMatchObject({ toolCallId: "toolu_ls", toolCallName: "Bash", parentMessageId: "a-text-1" });
    expect(JSON.parse((events[8] as { delta: string }).delta)).toEqual({ command: "ls", description: "List files" });
    expect(events[10]).toEqual({
      type: "TOOL_CALL_RESULT", messageId: "toolu_ls:result", toolCallId: "toolu_ls", role: "tool",
      content: "README.md\nscripts", timestamp: Date.parse("2026-10-06T10:00:03.000Z"),
    });
    expect(events[14]).toMatchObject({ type: "RUN_FINISHED", threadId: "sess-happy", runId: "u-prompt-1", outcome: { type: "success" } });
  });

  test("known non-event records are ignored, not counted as unknown", () => {
    expect(stats).toEqual({ lines: 9, events: 15, ignored: 3, unknown: 0, malformed: 0 });
  });
});

describe("interleaved parallel tool calls", () => {
  const { events } = mapFile(fixture("parallel-tools.jsonl"));

  test("results pair with their own call even when they arrive out of order", () => {
    const results = events.filter((e) => e.type === "TOOL_CALL_RESULT");
    expect(results.map((r) => r.toolCallId)).toEqual(["toolu_two", "toolu_one"]);
    expect(results[0]).toMatchObject({ content: '{"b": 2}' });
    expect(results[0]).not.toHaveProperty("isError");
    expect(results[1]).toMatchObject({ content: "File does not exist.", isError: true });
  });

  test("calls whose API message emitted no text carry no parentMessageId", () => {
    const starts = events.filter((e) => e.type === "TOOL_CALL_START");
    expect(starts.map((s) => [s.toolCallId, s.parentMessageId])).toEqual([["toolu_one", undefined], ["toolu_two", undefined]]);
  });

  test("a user interrupt finishes the run as cancelled", () => {
    expect(events.at(-1)).toMatchObject({ type: "RUN_FINISHED", runId: "u-prompt-1", outcome: { type: "cancelled" } });
    expect(events.filter((e) => e.type === "TEXT_MESSAGE_START")).toHaveLength(1); // the interrupt is not a prompt
  });

  test("every event validates", () => valid(events));
});

describe("tolerance", () => {
  const { events, stats } = mapFile(fixture("tolerant.jsonl"));

  test("a truncated last line, an unknown type and malformed records are counted, never thrown", () => {
    expect(stats).toEqual({ lines: 10, events: 12, ignored: 1, unknown: 1, malformed: 4 });
  });

  test("an API error ends the run with RUN_ERROR and the next prompt opens a new run", () => {
    expect(types(events)).toEqual([
      "RUN_STARTED", "TEXT_MESSAGE_START", "TEXT_MESSAGE_CONTENT", "TEXT_MESSAGE_END",
      "RUN_ERROR",
      "RUN_STARTED", "TEXT_MESSAGE_START", "TEXT_MESSAGE_CONTENT", "TEXT_MESSAGE_END",
      "TEXT_MESSAGE_START", "TEXT_MESSAGE_CONTENT", "TEXT_MESSAGE_END", // the duplicated record is emitted once
    ]);
    expect(events[4]).toEqual({ type: "RUN_ERROR", message: "API Error: 529 Overloaded.", code: "server_error", timestamp: Date.parse("2026-10-06T12:00:01.000Z") });
    expect(events[5]).toMatchObject({ runId: "u-prompt-2" });
  });

  test("every event validates", () => valid(events));
});

describe("incremental use", () => {
  test("chunks split anywhere give the same events as the whole file", () => {
    const text = readFileSync(fixture("happy-path.jsonl"), "utf8");
    const whole = mapFile(fixture("happy-path.jsonl")).events;
    const mapper = createJournalMapper();
    const got: AguiEvent[] = [];
    for (let i = 0; i < text.length; i += 37) got.push(...mapper.pushChunk(text.slice(i, i + 37)));
    got.push(...mapper.flush());
    expect(got).toEqual(whole);
  });

  test("a partial line waits for its newline instead of counting as malformed", () => {
    const mapper = createJournalMapper();
    const line = '{"type":"user","message":{"role":"user","content":"hi"},"uuid":"u1","sessionId":"s"}';
    expect(mapper.pushChunk(line.slice(0, 20))).toEqual([]);
    expect(mapper.stats.malformed).toBe(0);
    expect(types(mapper.pushChunk(line.slice(20) + "\n"))).toEqual(["RUN_STARTED", "TEXT_MESSAGE_START", "TEXT_MESSAGE_CONTENT", "TEXT_MESSAGE_END"]);
  });

  test("flush counts an unterminated tail as malformed exactly once", () => {
    const mapper = createJournalMapper();
    mapper.pushChunk('{"type":"user","mess');
    expect(mapper.flush()).toEqual([]);
    expect(mapper.flush()).toEqual([]);
    expect(mapper.stats.malformed).toBe(1);
  });

  test("an explicit threadId wins over the journal's sessionId", () => {
    const mapper = createJournalMapper({ threadId: "thread-x" });
    const [started] = mapper.pushLine('{"type":"user","message":{"role":"user","content":"hi"},"uuid":"u1","sessionId":"s"}');
    expect(started).toMatchObject({ type: "RUN_STARTED", threadId: "thread-x" });
  });

  test("assistant output with no prompt before it opens an implicit run", () => {
    const mapper = createJournalMapper();
    const evs = mapper.pushLine('{"type":"assistant","uuid":"a1","sessionId":"s","message":{"id":"m1","role":"assistant","content":[{"type":"text","text":"resumed"}]}}');
    expect(evs[0]).toEqual({ type: "RUN_STARTED", threadId: "s", runId: "a1" });
  });
});

// HIMMEL-4669: who did what, and what failed. START events carry `agent` (the session's own agent, or the
// subagent a sidechain record names); TOOL_CALL_RESULT and a BLOCKED text carry `failure`.
describe("agents and failures", () => {
  const { events, stats } = mapFile(fixture("agents.jsonl"));
  const starts = (id: string) => events.find((e) => e.type === "TOOL_CALL_START" && e.toolCallId === id) as any;
  const result = (id: string) => events.find((e) => e.type === "TOOL_CALL_RESULT" && e.toolCallId === id) as any;
  const texts = events.filter((e) => e.type === "TEXT_MESSAGE_START") as any[];
  const lead = { id: "main", name: "HIMMEL-4669-roadmap-console", role: "console", model: "claude-opus-5-5" };
  const critic = { id: "a1b2c3", name: "Review the diff", role: "critic", kind: "code-critic", model: "claude-sonnet-5-5", parentToolCallId: "toolu_agent" };

  test("the stream stays valid AG-UI and one run: sidechain prompts and turns are not run boundaries", () => {
    valid(events);
    expect(types(events).filter((t) => t.startsWith("RUN_"))).toEqual(["RUN_STARTED", "RUN_FINISHED"]);
    expect(stats.malformed).toBe(0);
  });

  test("the session's agent is named by its agent-name record, with its role and model", () => {
    expect(starts("toolu_agent").agent).toEqual(lead);
    // the prompt arrives before any assistant record, so its model is not known yet
    expect(texts[0].agent).toEqual({ id: "main", name: "HIMMEL-4669-roadmap-console", role: "console" });
  });

  test("a subagent is bound to the Agent call whose prompt it received", () => {
    expect(texts[2]).toMatchObject({ role: "user", agent: { ...critic, model: "sonnet" } }); // its brief: the spawn's model
    expect(starts("toolu_s1").agent).toEqual(critic); // its own records name the resolved model
    expect(texts[3].agent).toEqual(critic);
  });

  test("an unbound sidechain agent still gets an id and a placeholder name", () => {
    const mapper = createJournalMapper();
    const [, start] = mapper.pushLine('{"type":"assistant","isSidechain":true,"agentId":"zz9","uuid":"x1","sessionId":"s","message":{"id":"m","role":"assistant","content":[{"type":"text","text":"hi"}]}}');
    expect((start as any).agent).toEqual({ id: "zz9", name: "agent zz9", role: "subagent" });
  });

  test("a subagent record after its session's turn ended gets a run of its own, named for that agent", () => {
    const lines = readFileSync(fixture("agents.jsonl"), "utf8").split("\n").filter(Boolean);
    const sub = lines.filter((l) => JSON.parse(l).isSidechain === true);
    const evs = mapJournal([...lines.filter((l) => !sub.includes(l)), ...sub].join("\n") + "\n").events;
    const runs = evs.filter((e) => e.type.startsWith("RUN_")) as any[];
    expect(runs[2]).toMatchObject({ type: "RUN_STARTED", agent: { id: "a1b2c3", name: "Review the diff" } });
    expect(runs.at(-1)).toMatchObject({ type: "RUN_FINISHED", outcome: { type: "success" } });
    expect(runs.length % 2).toBe(0); // every run it opened is closed
    valid(evs);
  });

  test("failures are classified: suite, denied, blocked, error", () => {
    expect(result("toolu_s1").failure).toBeUndefined();
    expect(result("toolu_suite")).toMatchObject({ isError: true, failure: "suite" });
    expect(result("toolu_push")).toMatchObject({ isError: true, failure: "denied" });
    expect(result("toolu_msg")).toMatchObject({ failure: "blocked" });
    expect(result("toolu_msg").isError).toBeUndefined();
    expect(result("toolu_cat")).toMatchObject({ isError: true, failure: "error" });
    expect(texts.at(-1)).toMatchObject({ failure: "blocked" });
    expect(texts.filter((t) => t.failure).length).toBe(1);
  });
});
