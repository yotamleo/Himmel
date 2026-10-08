// HIMMEL-4817: a session's lane comes from its launch record, never its model string; a claudex leg is priced
// from the codex bank, never at Claude weights; and every leg gets a quality row with a lane dimension.
import { test, expect } from "bun:test";
import { backendModelOf, codexStartOf, costRowOf, evalRowOf, laneOf, laneOfJournal, readCodexBank } from "../agui/lane";
import { createJournalMapper } from "../agui/journal-mapper";
import { initialView, reduce } from "../agui-web/src/reducer";

const NOW = Date.parse("2026-10-08T12:00:00Z");
const cache = (pct: number, at = NOW, resetsAt = NOW / 1000 + 86400) =>
  JSON.stringify({ capturedAt: new Date(at).toISOString(), planType: "pro", limits: [
    { limitId: "codex/primary", usedPercent: pct, windowDurationMins: 10080, resetsAt },
    { limitId: "codex_bengalfox/primary", usedPercent: 3, windowDurationMins: 10080, resetsAt },
    { limitId: "codex/secondary", usedPercent: 90, windowDurationMins: 300, resetsAt },
  ] });

test("lane precedence: LEG_LANE, then the launcher's record, then the config dir, then the leg doc, else native", () => {
  expect(laneOf({ LEG_LANE: "openrouter", HIMMEL_SESSION_LANE: "claudex" }, "")).toEqual({ lane: "openrouter", laneFrom: "LEG_LANE" });
  expect(laneOf({ LEG_LANE: "bogus", HIMMEL_SESSION_LANE: "claudex" }, "")).toEqual({ lane: "claudex", laneFrom: "launcher" });
  expect(laneOf({ CLAUDE_CONFIG_DIR: "/h/.claude-codex" }, "")).toEqual({ lane: "claudex", laneFrom: "config-dir" });
  expect(laneOf({ CLAUDE_CONFIG_DIR: "/h/.claude-openrouter/" }, "")).toEqual({ lane: "openrouter", laneFrom: "config-dir" });
  expect(laneOf({}, "---\nlane: claudex\n---\n# leg")).toEqual({ lane: "claudex", laneFrom: "doc" });
  expect(laneOf({}, "launched with `headed-arm-leg.sh --lane openrouter`")).toEqual({ lane: "openrouter", laneFrom: "doc" });
  expect(laneOf({}, "")).toEqual({ lane: "native", laneFrom: "default" });
  // A gpt-* model on a native launch is still native: the lane is never guessed from the model.
  expect(laneOf({ ANTHROPIC_MODEL: "gpt-6.1-sol" }, "")).toEqual({ lane: "native", laneFrom: "default" });
});

test("backend model: the launcher's record, else a non-native lane's ANTHROPIC_MODEL, else the census model", () => {
  expect(backendModelOf("claudex", { HIMMEL_SESSION_MODEL: "gpt-6.1-sol", ANTHROPIC_MODEL: "x" }, "opus")).toBe("gpt-6.1-sol");
  expect(backendModelOf("openrouter", { ANTHROPIC_MODEL: "anthropic/claude-sonnet-5.5" }, "sonnet")).toBe("anthropic/claude-sonnet-5.5");
  expect(backendModelOf("native", { ANTHROPIC_MODEL: "ignored" }, "claude-opus-5-5")).toBe("claude-opus-5-5");
  expect(backendModelOf("native", {}, null)).toBeNull();
});

test("journal lane from the config dir its transcript lives under", () => {
  expect(laneOfJournal("/h/.claude-codex/projects/p/r.jsonl")).toBe("claudex");
  expect(laneOfJournal("/h/.claude-openrouter/projects/p/r.jsonl")).toBe("openrouter");
  expect(laneOfJournal("/h/.claude/projects/p/r.jsonl")).toBe("native");
});

test("codex bank: the governing weekly reading; stale, reset or unparseable is null", () => {
  expect(readCodexBank(cache(46), NOW)).toEqual({ weeklyPct: 46, capturedAt: NOW, resetsAt: NOW + 86400_000 });
  expect(readCodexBank(cache(46, NOW - 7 * 3600_000), NOW)).toBeNull();
  expect(readCodexBank(cache(46, NOW, NOW / 1000 - 1), NOW)).toBeNull();
  expect(readCodexBank("{nope", NOW)).toBeNull();
  expect(codexStartOf({ HIMMEL_CODEX_BANK_START: `40@${NOW - 3600_000}` })).toEqual({ pct: 40, at: NOW - 3600_000 });
  expect(codexStartOf({ HIMMEL_CODEX_BANK_START: "garbage" })).toBeNull();
  expect(codexStartOf({})).toBeNull();
});

const TALLY = { calls: 3, input: 30, output: 300, cacheRead: 120000, cacheCreate: 0 };
const ID = { session: "s1", leg: "HIMMEL-901-N9001-leg", ticket: "HIMMEL-901", model: "gpt-6.1-sol" };

test("a claudex cost row is priced from the codex bank delta, never at Claude weights", () => {
  const bank = readCodexBank(cache(46), NOW)!;
  const row = costRowOf({ ...ID, lane: "claudex", tally: TALLY, codexStart: { pct: 40, at: NOW - 3600_000 }, codexNow: bank });
  expect(row).toMatchObject({ lane: "claudex", bank: "codex", priced_by: "codex-bank", cost_eq: null, calls: 3, output: 300,
    codex_used_pct_start: 40, codex_used_pct_end: 46, codex_used_pct_delta: 6 });
  // No start reading, or an end reading older than the start, or a window that reset: unpriced, still not Claude-priced.
  expect(costRowOf({ ...ID, lane: "claudex", tally: TALLY, codexStart: null, codexNow: bank })).toMatchObject({ priced_by: "unpriced", cost_eq: null, codex_used_pct_delta: null });
  expect(costRowOf({ ...ID, lane: "claudex", tally: TALLY, codexStart: { pct: 40, at: NOW + 1 }, codexNow: bank })).toMatchObject({ priced_by: "unpriced", codex_used_pct_delta: null });
  expect(costRowOf({ ...ID, lane: "claudex", tally: TALLY, codexStart: { pct: 60, at: NOW - 1 }, codexNow: bank })).toMatchObject({ priced_by: "unpriced", codex_used_pct_delta: null });
  // The start reading predates the current weekly window (it reset, then usage passed the old start): unpriced.
  const week = 7 * 86400_000;
  expect(costRowOf({ ...ID, lane: "claudex", tally: TALLY, codexStart: { pct: 10, at: NOW - 2 * week }, codexNow: bank })).toMatchObject({ priced_by: "unpriced", codex_used_pct_delta: null });
  // native keeps the leg-burn weights.
  expect(costRowOf({ ...ID, lane: "native", tally: TALLY, codexStart: null, codexNow: bank })).toMatchObject({ lane: "native", bank: "claude", priced_by: "claude-weights", cost_eq: 30 + 12000 + 1500, codex_used_pct_delta: null });
});

test("an eval row carries the lane and the quality measures from the journal and the leg doc", () => {
  const rec = (o: Record<string, unknown>, i: number) => JSON.stringify({ sessionId: "s1", uuid: `u${i}`, timestamp: new Date(NOW + i * 1000).toISOString(), ...o });
  const call = (id: string, name: string, input: unknown) => ({ type: "assistant", message: { id: `m-${id}`, role: "assistant", content: [{ type: "tool_use", id, name, input }] } });
  const res = (id: string, content: string, is_error = false) => ({ type: "user", message: { role: "user", content: [{ type: "tool_result", tool_use_id: id, content, is_error }] } });
  const lines = [
    { type: "user", message: { role: "user", content: "go" } },
    call("t1", "Bash", { command: "bun test scripts/x" }), res("t1", "1 fail", true),
    call("t2", "Bash", { command: "bun test scripts/x" }), res("t2", "1 pass"),
    call("t3", "Bash", { command: "git push origin main" }), res("t3", "PreToolUse:Bash hook error: denied", true),
    call("t4", "Bash", { command: "git push origin HEAD" }), res("t4", "ok"),
    call("t5", "Bash", { command: "bash scripts/cr/pr-check.sh" }), res("t5", "# Critic Panel Review (3/3 critics responded)\n## Critical Issues (2 found)\n- [c1]: a\n- [c2]: b\n"),
    call("t6", "Bash", { command: "bash scripts/cr/pr-check.sh" }), res("t6", "# Critic Panel Review (3/3 critics responded)\n## Critical Issues (0 found)\n"),
  ].map(rec);
  const mapper = createJournalMapper();
  let view = initialView();
  const rounds: number[] = [];
  for (const l of lines) for (const e of mapper.pushLine(l)) {
    if (e.type === "STATE_SNAPSHOT") rounds.push((e.snapshot as any).review.findings.length);
    view = reduce(view, e as never);
  }
  const doc = "- 09:00 LIVE — started\n- 09:30 NO-GO for head abc\n- 09:50 GO for head def\n- 10:15 READY 1901 def GREEN\n";
  expect(evalRowOf({ ...ID, lane: "claudex", rounds, view, doc })).toEqual({
    ...ID, lane: "claudex", cr_rounds: 2, cr_findings_per_round: [2, 0], rounds_to_clean: 2,
    judge_verdicts: 2, judge_no_go: 1, judge_no_go_rate: 0.5, red_before_green: true,
    live_to_ready_ms: 75 * 60_000, denials: 1, denials_recovered: 1,
  });
  // Nothing measured is null, never zero-as-success.
  expect(evalRowOf({ ...ID, lane: "native", rounds: [], view: null, doc: "" })).toMatchObject({
    lane: "native", cr_rounds: 0, rounds_to_clean: null, judge_no_go_rate: null, red_before_green: null, live_to_ready_ms: null, denials: 0,
  });
});

test("a mapper given the lane stamps it on RUN_STARTED; without it the event is unchanged", () => {
  const line = JSON.stringify({ type: "user", sessionId: "s", uuid: "a1", message: { role: "user", content: "hi" } });
  expect(createJournalMapper({ lane: "claudex" }).pushLine(line)[0]).toEqual({ type: "RUN_STARTED", threadId: "s", runId: "a1", metadata: { lane: "claudex" } });
  expect(createJournalMapper().pushLine(line)[0]).toEqual({ type: "RUN_STARTED", threadId: "s", runId: "a1" });
});
